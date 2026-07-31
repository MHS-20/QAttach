package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/MHS-20/QAttach/internal/config"
	"github.com/MHS-20/QAttach/internal/etcd"
	"github.com/MHS-20/QAttach/internal/fencing"
	"github.com/MHS-20/QAttach/internal/identity"
	"github.com/MHS-20/QAttach/internal/lifecycle"
	"github.com/MHS-20/QAttach/internal/lock"
	"github.com/MHS-20/QAttach/internal/membership"
	"github.com/MHS-20/QAttach/internal/netlink"
	"github.com/MHS-20/QAttach/internal/signal"
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

	// Bootstrap etcd membership (colocated mode).
	if !cfg.NoBootstrap && cfg.EtcdName != "" && cfg.PeerURL != "" {
		mm := membership.NewManager(cfg)
		if err := mm.Bootstrap(ctx); err != nil {
			log.Fatalf("membership bootstrap: %v", err)
		}
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

	// Ensure epoch key exists (first node to bootstrap creates it).
	if _, err := ec.InitEpoch(ctx); err != nil {
		log.Printf("epoch init warning: %v", err)
	}

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

	// A lapsed session lease deletes every lock key this node owns while
	// GFS2 still believes it holds those glocks — another node could then
	// take EX on the same inode and both would write.  Die immediately:
	// the kernel's netlink sends start failing with -ENODEV so GFS2
	// degrades to I/O errors, and peers fence us on the member deletion.
	go func() {
		select {
		case <-ec.Done():
			log.Fatalf("etcd session lease expired — all locks lost, exiting to be fenced")
		case <-ctx.Done():
		}
	}()

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

		// Remove self from etcd cluster membership (colocated mode).
		if !cfg.NoBootstrap && cfg.EtcdName != "" && cfg.PeerURL != "" {
			mm := membership.NewManager(cfg)
			if err := mm.Deregister(context.Background()); err != nil {
				log.Printf("membership deregister warning: %v", err)
			}
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

	// etcd colocation
	flag.StringVar(&cfg.PeerURL, "peer-url", "", "etcd peer URL (e.g. https://10.0.1.10:2380)")
	flag.StringVar(&cfg.EtcdName, "etcd-name", "", "etcd member name (e.g. etcd-0)")
	flag.StringVar(&cfg.EtcdDataDir, "etcd-data-dir", "/var/lib/etcd", "etcd data directory")
	flag.StringVar(&cfg.InitialCluster, "initial-cluster", "", "etcd initial cluster (name=peerURL,...)")
	flag.BoolVar(&cfg.NoBootstrap, "no-bootstrap", false, "skip etcd bootstrap (use existing remote etcd)")

	flag.Parse()

	cfg.EtcdEndpoints = strings.Split(*etcdEndpoints, ",")

	if cfg.VolumeID == "" {
		fmt.Fprintf(os.Stderr, "warning: --volume-id not set, fencing will be incomplete\n")
	}

	return cfg
}
