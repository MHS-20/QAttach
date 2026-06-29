package identity

import (
	"testing"
)

func TestDetectLocalIP(t *testing.T) {
	ip := detectLocalIP()
	if ip == "" {
		t.Error("detectLocalIP returned empty string")
	}
	if ip == "127.0.0.1" {
		t.Log("detectLocalIP returned loopback — expected in container/test environments")
	}
	// It should at least be parseable
	if ip != "127.0.0.1" && ip != "" {
		// Valid IP address format
		if len(ip) < 7 {
			t.Errorf("unexpected IP format: %s", ip)
		}
	}
}

func TestFallbackIdentity(t *testing.T) {
	id, err := fallbackIdentity(nil)
	if id.InstanceID == "" {
		t.Error("fallback InstanceID is empty")
	}
	if id.PrivateIP == "" {
		t.Error("fallback PrivateIP is empty")
	}
	// err is expected when not on EC2
	_ = err
}

func TestDiscoverFallback(t *testing.T) {
	// When not on EC2, Discover should fall back to hostname-based identity.
	id, err := Discover()
	if err != nil {
		t.Logf("Discover returned error (expected without IMDS): %v", err)
	}
	if id == nil {
		t.Fatal("Discover returned nil identity")
	}
	if id.InstanceID == "" {
		t.Error("identity InstanceID is empty")
	}
}
