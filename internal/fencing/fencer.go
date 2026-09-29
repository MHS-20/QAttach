package fencing

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/MHS-20/QAttach/internal/etcd"
	"github.com/MHS-20/QAttach/internal/lock"
	"github.com/MHS-20/QAttach/internal/netlink"
	"github.com/MHS-20/QAttach/pkg/protocol"
)

// Fence modes.
const (
	// ModeEC2 force-stops the failed instance, falling back to a forced
	// EBS detach.  The node ID must be the EC2 instance ID (the agent's
	// default when --node-id is not given).
	ModeEC2 = "ec2"
	// ModeNone fences nothing: whoever runs the cluster guarantees a
	// failed node is dead before its lease expires.  Only for test
	// harnesses that kill the node themselves, such as scripts/docker.
	ModeNone = "none"
)

const (
	scanInterval    = 2 * time.Second
	fenceTimeout    = 90 * time.Second
	recoveryTimeout = 60 * time.Second
)

// Fencer fences failed nodes and drives the replay of their journals.
type Fencer struct {
	etcdCli  *etcd.Client
	ec2Cli   *ec2.Client // nil in ModeNone
	nlSrv    *netlink.Server
	nodeID   string
	volumeID string
}

// NewFencer creates a fencer for the given mode.
func NewFencer(ec *etcd.Client, nodeID, volumeID, mode string) (*Fencer, error) {
	f := &Fencer{etcdCli: ec, nodeID: nodeID, volumeID: volumeID}
	switch mode {
	case ModeEC2:
		awsCfg, err := config.LoadDefaultConfig(context.Background())
		if err != nil {
			return nil, fmt.Errorf("aws config: %w", err)
		}
		f.ec2Cli = ec2.NewFromConfig(awsCfg)
	case ModeNone:
		log.Printf("fencing disabled (--fence-mode=none): failed nodes are assumed dead")
	default:
		return nil, fmt.Errorf("unknown fence mode %q", mode)
	}
	return f, nil
}

// SetNetlink sets the netlink server reference.
func (f *Fencer) SetNetlink(srv *netlink.Server) {
	f.nlSrv = srv
}

// Run recovers the journals of failed nodes until ctx ends.  It is level
// triggered: every pass recomputes what needs recovery from etcd, so a
// whole-cluster restart, or a recoverer dying mid-recovery, is picked up
// the same way as a fresh member deletion — which only makes it prompt.
func (f *Fencer) Run(ctx context.Context, lm *lock.Manager) {
	deletions := f.etcdCli.WatchMemberDeletions(ctx)
	tick := time.NewTicker(scanInterval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-deletions:
		case <-tick.C:
		}
		f.reconcile(ctx, lm)
	}
}

// reconcile recovers every orphaned journal.  Only a node with the
// filesystem mounted can replay a journal, so an unmounted node does nothing.
func (f *Fencer) reconcile(ctx context.Context, lm *lock.Manager) {
	own := lm.MountedJID()
	if own < 0 {
		return
	}
	orphans, err := f.etcdCli.OrphanJournals(ctx, own)
	if err != nil {
		log.Printf("recovery scan: %v", err)
		return
	}
	for jid, owner := range orphans {
		f.recover(ctx, lm, jid, owner)
	}
}

// recover fences owner and replays journal jid, the same sequence DLM and
// lock_dlm run: block new grants, drop the dead node's locks, let only
// recovery's NOEXP requests through, replay, then unblock.
func (f *Fencer) recover(ctx context.Context, lm *lock.Manager, jid int32, owner string) {
	won, err := f.etcdCli.CASFencing(ctx, owner, f.nodeID)
	if err != nil || !won {
		return
	}
	defer f.etcdCli.ReleaseFencing(context.Background(), owner, f.nodeID)
	log.Printf("recovering jid=%d of %s", jid, owner)

	if err := f.Fence(ctx, owner); err != nil {
		// Without a successful fence the dead node's lock entries
		// stay and keep blocking; that is the safe failure.
		log.Printf("fencing %s failed, will retry: %v", owner, err)
		return
	}

	// Barrier before purge: the purge removes the only thing blocking
	// requests that conflict with the dead node.
	if err := f.etcdCli.BeginRecovery(ctx, jid, owner); err != nil {
		log.Printf("recovery barrier jid=%d: %v", jid, err)
		return
	}
	if err := f.etcdCli.PurgeHolder(ctx, owner); err != nil {
		log.Printf("purge locks of %s: %v", owner, err)
		return
	}

	if f.nlSrv == nil {
		return
	}
	if err := f.nlSrv.SendRecoveryOk(protocol.RecoveryOk{JID: uint32(jid)}); err != nil {
		log.Printf("send recovery request jid=%d: %v", jid, err)
		return
	}
	timeout := time.After(recoveryTimeout)
	for {
		select {
		case <-ctx.Done():
			return
		case <-timeout:
			log.Printf("recovery jid=%d timed out, will retry", jid)
			return
		case done := <-lm.RecoveryResults():
			if int32(done.JID) != jid {
				continue
			}
			if done.Result != protocol.RecoverySuccess {
				log.Printf("recovery jid=%d gave up (%d), will retry", jid, done.Result)
				return
			}
			if err := f.etcdCli.FinishRecovery(ctx, jid, owner); err != nil {
				log.Printf("finish recovery jid=%d: %v", jid, err)
				return
			}
			// A fenced node that comes back must not reuse its old view.
			if _, err := f.etcdCli.IncrementEpoch(ctx); err != nil {
				log.Printf("increment epoch error: %v", err)
			}
			log.Printf("recovered jid=%d of %s", jid, owner)
			return
		}
	}
}

// Fence makes sure the failed node can no longer write to the volume.
func (f *Fencer) Fence(ctx context.Context, nodeID string) error {
	if f.ec2Cli == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, fenceTimeout)
	defer cancel()

	log.Printf("fencing: stopping instance %s", nodeID)
	_, err := f.ec2Cli.StopInstances(ctx, &ec2.StopInstancesInput{
		InstanceIds: []string{nodeID},
		Force:       aws.Bool(true),
	})
	if err == nil {
		err = ec2.NewInstanceStoppedWaiter(f.ec2Cli).Wait(ctx,
			&ec2.DescribeInstancesInput{InstanceIds: []string{nodeID}}, fenceTimeout)
		if err == nil {
			return nil
		}
	}
	log.Printf("stop %s failed: %v — force-detaching volume", nodeID, err)
	return f.detachVolume(ctx, nodeID)
}

// detachVolume force-detaches the EBS volume from the instance and waits
// until the detach is complete.
func (f *Fencer) detachVolume(ctx context.Context, instanceID string) error {
	_, err := f.ec2Cli.DetachVolume(ctx, &ec2.DetachVolumeInput{
		VolumeId:   aws.String(f.volumeID),
		InstanceId: aws.String(instanceID),
		Force:      aws.Bool(true),
	})
	if err != nil {
		return fmt.Errorf("detach volume: %w", err)
	}
	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("detach of %s not confirmed: %w", f.volumeID, ctx.Err())
		case <-time.After(5 * time.Second):
		}
		resp, err := f.ec2Cli.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{
			VolumeIds: []string{f.volumeID},
		})
		if err != nil {
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
			return nil
		}
	}
}
