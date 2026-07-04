package config

import (
	"time"

	"github.com/polarity/qattach/pkg/protocol"
)

// Config holds all cluster-agent configuration.
type Config struct {
	NodeID string

	EtcdEndpoints []string
	EtcdCertFile  string
	EtcdKeyFile   string
	EtcdCAFile    string

	// etcd colocation
	PeerURL        string // https://<node-ip>:2380
	EtcdName       string // etcd member name (e.g. etcd-0)
	EtcdDataDir    string // /var/lib/etcd
	InitialCluster string // full initial-cluster spec
	NoBootstrap    bool   // skip bootstrap (for testing with standalone etcd)

	ASGName     string
	ClusterName string
	VolumeID    string
	AZ          string

	SessionTTL         time.Duration
	KeepaliveInterval  time.Duration
	FencingLeaseTTL    time.Duration
	FencingTimeout     time.Duration
}

// Default returns a config with sensible defaults.
func Default() *Config {
	return &Config{
		SessionTTL:        protocol.SessionTTL * time.Second,
		KeepaliveInterval: protocol.KeepaliveInterval * time.Second,
		FencingLeaseTTL:   protocol.FencingLeaseTTL * time.Second,
		FencingTimeout:    60 * time.Second,
		EtcdDataDir:       "/var/lib/etcd",
	}
}

// EtcdKeyPrefix returns the etcd key prefix for this cluster's locks.
func (c *Config) EtcdKeyPrefix() string {
	return protocol.PrefixLocks
}
