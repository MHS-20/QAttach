package config

import (
	"testing"
	"time"
)

func TestDefaultConfig(t *testing.T) {
	cfg := Default()
	if cfg == nil {
		t.Fatal("Default() returned nil")
	}
	if cfg.SessionTTL != 15*time.Second {
		t.Errorf("SessionTTL = %v, want 15s", cfg.SessionTTL)
	}
	if cfg.KeepaliveInterval != 5*time.Second {
		t.Errorf("KeepaliveInterval = %v, want 5s", cfg.KeepaliveInterval)
	}
	if cfg.FencingLeaseTTL != 60*time.Second {
		t.Errorf("FencingLeaseTTL = %v, want 60s", cfg.FencingLeaseTTL)
	}
	if cfg.FencingTimeout != 60*time.Second {
		t.Errorf("FencingTimeout = %v, want 60s", cfg.FencingTimeout)
	}
}

func TestEtcdKeyPrefix(t *testing.T) {
	cfg := Default()
	prefix := cfg.EtcdKeyPrefix()
	if prefix == "" {
		t.Error("EtcdKeyPrefix must not be empty")
	}
}
