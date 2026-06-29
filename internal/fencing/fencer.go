package fencing

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"

	clientv3 "go.etcd.io/etcd/client/v3"

	"github.com/polarity/qattach/internal/etcd"
	"github.com/polarity/qattach/internal/netlink"
	"github.com/polarity/qattach/pkg/protocol"
)

// Fencer monitors etcd for member failures and executes EC2 fencing.
type Fencer struct {
	etcdCli  *etcd.Client
	ec2Cli   *ec2.Client
	nlSrv    *netlink.Server
	nodeID   string
	volumeID string

	mu           sync.Mutex
	journalMap   map[string]uint32 // nodeID → jid
}

// NewFencer creates a new fencer.
func NewFencer(ec *etcd.Client, nodeID, volumeID string) (*Fencer, error) {
	awsCfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}

	return &Fencer{
		etcdCli:    ec,
		ec2Cli:     ec2.NewFromConfig(awsCfg),
		nodeID:     nodeID,
		volumeID:   volumeID,
		journalMap: make(map[string]uint32),
	}, nil
}

// SetNetlink sets the netlink server reference.
func (f *Fencer) SetNetlink(srv *netlink.Server) {
	f.nlSrv = srv
}

// RegisterJournal maps a node ID to its journal ID.
func (f *Fencer) RegisterJournal(nodeID string, jid uint32) {
	f.mu.Lock()
	f.journalMap[nodeID] = jid
	f.mu.Unlock()
}

// Run starts the member deletion watch loop. Blocks until context is cancelled.
func (f *Fencer) Run(ctx context.Context) {
	watchCh := f.etcdCli.WatchMemberDeletions(ctx)

	for resp := range watchCh {
		for _, ev := range resp.Events {
			if ev.Type == clientv3.EventTypeDelete {
				failedNodeID := keyToNodeID(string(ev.Kv.Key))
				if failedNodeID == "" || failedNodeID == f.nodeID {
					continue
				}

				var lastVal []byte
				if ev.PrevKv != nil {
					lastVal = ev.PrevKv.Value
				}

				go f.handlePeerFailure(ctx, failedNodeID, lastVal)
			}
		}
	}
}

// handlePeerFailure races to become the fencing coordinator.
func (f *Fencer) handlePeerFailure(ctx context.Context, failedNodeID string, lastVal []byte) {
	log.Printf("detected peer failure: %s", failedNodeID)

	// CAS race — only one winner
	won, err := f.etcdCli.CASFencing(ctx, failedNodeID, f.nodeID)
	if err != nil {
		log.Printf("fencing CAS error for %s: %v", failedNodeID, err)
		return
	}
	if !won {
		log.Printf("lost fencing race for %s — another node is handling it", failedNodeID)
		return
	}

	log.Printf("won fencing race for %s — executing EC2 fencing", failedNodeID)

	var info protocol.MemberInfo
	if lastVal != nil {
		if err := json.Unmarshal(lastVal, &info); err != nil {
			log.Printf("parse member info for %s: %v", failedNodeID, err)
			return
		}
	}

	f.executeFencing(ctx, info.InstanceID, failedNodeID)
}

// executeFencing stops the instance and detaches the volume if needed.
func (f *Fencer) executeFencing(ctx context.Context, instanceID, failedNodeID string) {
	fenceCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	// Step 1: Force-stop the instance.
	log.Printf("fencing: stopping instance %s", instanceID)
	_, err := f.ec2Cli.StopInstances(fenceCtx, &ec2.StopInstancesInput{
		InstanceIds: []string{instanceID},
		Force:       aws.Bool(true),
	})
	if err != nil {
		log.Printf("stop instances error for %s: %v — falling back to detach", instanceID, err)
		f.detachVolume(fenceCtx, instanceID)
		return
	}

	// Step 2: Poll until stopped.
	waiter := ec2.NewInstanceStoppedWaiter(f.ec2Cli)
	if err := waiter.Wait(fenceCtx,
		&ec2.DescribeInstancesInput{InstanceIds: []string{instanceID}},
		60*time.Second,
	); err != nil {
		log.Printf("instance stop wait error for %s: %v — detaching volume", instanceID, err)
		f.detachVolume(fenceCtx, instanceID)
	}

	// Step 3: Increment cluster epoch.
	if _, err := f.etcdCli.IncrementEpoch(ctx); err != nil {
		log.Printf("increment epoch error: %v", err)
	}

	// Step 4: Signal kernel — journal recovery safe.
	f.mu.Lock()
	jid, ok := f.journalMap[failedNodeID]
	f.mu.Unlock()
	if ok {
		f.signalRecoveryOk(jid)
	}

	// Step 5: Mark fencing complete so other nodes can observe it.
	if err := f.etcdCli.MarkFencingComplete(ctx, failedNodeID, "done"); err != nil {
		log.Printf("mark fencing complete error for %s: %v", failedNodeID, err)
	}

	log.Printf("fencing complete for node %s (instance %s)", failedNodeID, instanceID)
}

// detachVolume force-detaches the EBS volume from the instance.
func (f *Fencer) detachVolume(ctx context.Context, instanceID string) {
	// Force-detach only if instance ID matches fenced instance.
	log.Printf("fencing: force-detaching volume %s from instance %s", f.volumeID, instanceID)

	_, err := f.ec2Cli.DetachVolume(ctx, &ec2.DetachVolumeInput{
		VolumeId:   aws.String(f.volumeID),
		InstanceId: aws.String(instanceID),
		Force:      aws.Bool(true),
	})
	if err != nil {
		log.Printf("detach volume error: %v", err)
		return
	}

	// Poll until detached.
	for {
		select {
		case <-ctx.Done():
			log.Printf("detach poll timeout for volume %s", f.volumeID)
			return
		case <-time.After(5 * time.Second):
		}

		resp, err := f.ec2Cli.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{
			VolumeIds: []string{f.volumeID},
		})
		if err != nil {
			log.Printf("describe volumes error: %v", err)
			continue
		}

		detached := true
		for _, vol := range resp.Volumes {
			for _, att := range vol.Attachments {
				if aws.ToString(att.InstanceId) == instanceID &&
					att.State != types.VolumeAttachmentStateDetached {
					detached = false
				}
			}
		}

		if detached {
			log.Printf("volume %s detached from instance %s", f.volumeID, instanceID)
			return
		}
	}
}

// signalRecoveryOk notifies the kernel module that journal recovery is safe.
func (f *Fencer) signalRecoveryOk(jid uint32) {
	if f.nlSrv == nil {
		return
	}
	if err := f.nlSrv.SendRecoveryOk(protocol.RecoveryOk{JID: jid}); err != nil {
		log.Printf("send recovery ok error: %v", err)
	}
}

// keyToNodeID extracts the node ID from a member key path.
func keyToNodeID(key string) string {
	prefix := protocol.PrefixMembers
	if len(key) > len(prefix) {
		return key[len(prefix):]
	}
	return ""
}
