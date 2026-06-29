package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/polarity/qattach/internal/config"
	"github.com/polarity/qattach/internal/etcd"
	"github.com/polarity/qattach/internal/fencing"
	"github.com/polarity/qattach/internal/identity"
	"github.com/polarity/qattach/internal/lifecycle"
	"github.com/polarity/qattach/internal/lock"
	"github.com/polarity/qattach/internal/netlink"
	"github.com/polarity/qattach/internal/signal"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	cfg := parseFlags()

	ctx, cancel := signal.Context()
	defer cancel()

	// Discover identity.
	id, err := identity.Discover()
	if err != nil {
		log.Printf("identity discovery warning: %v", err)
	}
	log.Printf("node identity: id=%s ip=%s az=%s", id.InstanceID, id.PrivateIP, id.AZ)

	if cfg.NodeID == "" {
		cfg.NodeID = id.InstanceID
	}

	// Connect to etcd.
	log.Printf("connecting to etcd: %s", strings.Join(cfg.EtcdEndpoints, ","))
	ec, err := etcd.New(ctx, cfg)
	if err != nil {
		log.Fatalf("etcd connect: %v", err)
	}
	defer ec.Close()

	// Register node membership.
	if err := ec.RegisterNode(ctx, cfg.NodeID, id.InstanceID, id.PrivateIP, id.AZ); err != nil {
		log.Fatalf("register node: %v", err)
	}
	log.Printf("registered node %s in etcd", cfg.NodeID)

	// Create lock manager.
	lm := lock.NewManager(ec, cfg.NodeID)

	// Create netlink server (non-fatal — kernel module optional).
	nlSrv, err := netlink.ListenRaw()
	if err != nil {
		log.Printf("netlink server unavailable (kernel module not loaded?): %v", err)
		lm.SetNetlink(nil)
	} else {
		nlSrv.SetHandler(lm)
		lm.SetNetlink(nlSrv)
	}

	// Create fencer.
	f, err := fencing.NewFencer(ec, cfg.NodeID, cfg.VolumeID)
	if err != nil {
		log.Fatalf("fencer init: %v", err)
	}
	if nlSrv != nil {
		f.SetNetlink(nlSrv)
	}

	// Start fencer watch loop.
	go f.Run(ctx)

	// Start ASG lifecycle hook poll if configured.
	if cfg.ASGName != "" {
		lh, err := lifecycle.NewHookHandler(id.InstanceID)
		if err != nil {
			log.Printf("lifecycle hook init error: %v", err)
		} else {
			go lh.PollTerminating(ctx, cfg.ASGName, 5*time.Second, func(hookCtx context.Context) error {
				log.Printf("ASG terminating: deregistering node %s", cfg.NodeID)
				_ = ec.DeregisterNode(hookCtx, cfg.NodeID)
				nlSrv.Stop()
				return nil
			})
		}
	}

	// Start netlink receive loop and register with kernel (if available).
	if nlSrv != nil {
		if err := nlSrv.SendRegister(); err != nil {
			log.Printf("netlink register error: %v", err)
		} else {
			log.Printf("netlink: registered with kernel module")
		}
		go func() {
			if err := nlSrv.Serve(); err != nil {
				log.Printf("netlink serve: %v", err)
			}
		}()
	}

	log.Printf("cluster-agent ready — listening for lock_etcd requests")

	// Wait for shutdown signal.
	_ = signal.Wait(ctx, func() {
		log.Printf("clean shutdown: deregistering node %s", cfg.NodeID)
		if err := ec.DeregisterNode(context.Background(), cfg.NodeID); err != nil {
			log.Printf("deregister error: %v", err)
		}
		if nlSrv != nil {
			nlSrv.Stop()
		}
	})

	log.Printf("cluster-agent stopped")
}

func parseFlags() *config.Config {
	cfg := config.Default()

	flag.StringVar(&cfg.NodeID, "node-id", "", "unique node identifier (default: instance ID from IMDS)")

	etcdEndpoints := flag.String("etcd-endpoints", "http://localhost:2379",
		"comma-separated etcd endpoints")

	flag.StringVar(&cfg.EtcdCertFile, "etcd-cert", "", "etcd client certificate file")
	flag.StringVar(&cfg.EtcdKeyFile, "etcd-key", "", "etcd client key file")
	flag.StringVar(&cfg.EtcdCAFile, "etcd-ca", "", "etcd CA certificate file")

	flag.StringVar(&cfg.ASGName, "asg-name", "", "Auto Scaling Group name for lifecycle hook handling")
	flag.StringVar(&cfg.ClusterName, "cluster-name", "mycluster", "GFS2 cluster name")
	flag.StringVar(&cfg.VolumeID, "volume-id", "", "EBS volume ID for fencing")
	flag.StringVar(&cfg.AZ, "az", "us-east-1a", "availability zone")

	flag.Parse()

	cfg.EtcdEndpoints = strings.Split(*etcdEndpoints, ",")

	if cfg.VolumeID == "" {
		fmt.Fprintf(os.Stderr, "warning: --volume-id not set, fencing will be incomplete\n")
	}

	return cfg
}
