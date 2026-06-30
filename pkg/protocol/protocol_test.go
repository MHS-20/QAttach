package protocol

import (
	"encoding/binary"
	"bytes"
	"testing"
)

func TestLockModeToEtcd(t *testing.T) {
	tests := []struct {
		mode   uint32
		expect string
	}{
		{LockModeExclusive, EtcdModeEX},
		{LockModeShared, EtcdModePR},
		{LockModeDeferred, EtcdModeCW},
		{LockModeUnlocked, ""},
		{99, ""},
	}

	for _, tt := range tests {
		got := LockModeToEtcd(tt.mode)
		if got != tt.expect {
			t.Errorf("LockModeToEtcd(%d) = %q, want %q", tt.mode, got, tt.expect)
		}
	}
}

func TestLockModeName(t *testing.T) {
	tests := []struct {
		mode   uint32
		expect string
	}{
		{LockModeUnlocked, "UN"},
		{LockModeExclusive, "EX"},
		{LockModeDeferred, "DF"},
		{LockModeShared, "SH"},
		{99, "??"},
	}

	for _, tt := range tests {
		got := LockModeName(tt.mode)
		if got != tt.expect {
			t.Errorf("LockModeName(%d) = %q, want %q", tt.mode, got, tt.expect)
		}
	}
}

func TestLockRequestEncoding(t *testing.T) {
	req := LockRequest{
		RequestID:     42,
		GlockNumber:   12345,
		GlockType:     LockTypeInode,
		RequestedMode: LockModeExclusive,
	}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, req); err != nil {
		t.Fatal(err)
	}

	var decoded LockRequest
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded != req {
		t.Errorf("round-trip failed: got %+v, want %+v", decoded, req)
	}
}

func TestLockGrantEncoding(t *testing.T) {
	grant := LockGrant{
		RequestID:    7,
		GrantedMode:  LockModeExclusive,
		EtcdRevision: 123456789,
	}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, grant); err != nil {
		t.Fatal(err)
	}

	var decoded LockGrant
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded != grant {
		t.Errorf("round-trip failed: got %+v, want %+v", decoded, grant)
	}
}

func TestLockDenyEncoding(t *testing.T) {
	deny := LockDeny{
		RequestID: 99,
		Reason:    DenyReasonStale,
	}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, deny); err != nil {
		t.Fatal(err)
	}

	var decoded LockDeny
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded != deny {
		t.Errorf("round-trip failed: got %+v, want %+v", decoded, deny)
	}
}

func TestBastNotificationEncoding(t *testing.T) {
	bast := BastNotification{
		GlockNumber: 999,
		GlockType:   LockTypeJournal,
		TargetMode:  LockModeUnlocked,
	}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, bast); err != nil {
		t.Fatal(err)
	}

	var decoded BastNotification
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded != bast {
		t.Errorf("round-trip failed: got %+v, want %+v", decoded, bast)
	}
}

func TestLockReleaseEncoding(t *testing.T) {
	rel := LockRelease{
		GlockNumber: 555,
		GlockType:   LockTypeRgrp,
	}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, rel); err != nil {
		t.Fatal(err)
	}

	var decoded LockRelease
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded != rel {
		t.Errorf("round-trip failed: got %+v, want %+v", decoded, rel)
	}
}

func TestRecoveryOkEncoding(t *testing.T) {
	rok := RecoveryOk{JID: 3}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, rok); err != nil {
		t.Fatal(err)
	}

	var decoded RecoveryOk
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded != rok {
		t.Errorf("round-trip failed: got %+v, want %+v", decoded, rok)
	}
}

func TestMountRequestEncoding(t *testing.T) {
	req := MountRequest{}
	copy(req.ClusterName[:], "mycluster")
	copy(req.FilesystemName[:], "sharedfs")

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, req); err != nil {
		t.Fatal(err)
	}

	var decoded MountRequest
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	gotCluster := string(bytes.TrimRight(decoded.ClusterName[:], "\x00"))
	gotFS := string(bytes.TrimRight(decoded.FilesystemName[:], "\x00"))

	if gotCluster != "mycluster" || gotFS != "sharedfs" {
		t.Errorf("round-trip failed: cluster=%q fs=%q", gotCluster, gotFS)
	}
}

func TestMountResponseEncoding(t *testing.T) {
	resp := MountResponse{
		RequestID: 1,
		JID:       5,
	}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, resp); err != nil {
		t.Fatal(err)
	}

	var decoded MountResponse
	if err := binary.Read(&buf, binary.LittleEndian, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded != resp {
		t.Errorf("round-trip failed: got %+v, want %+v", decoded, resp)
	}
}

func TestDenyReasons(t *testing.T) {
	if DenyReasonContended == DenyReasonStale {
		t.Error("deny reasons must be distinct")
	}
	if DenyReasonContended == DenyReasonError {
		t.Error("deny reasons must be distinct")
	}
}

func TestMessageTypes(t *testing.T) {
	types := []uint32{
		MsgLockReq, MsgLockGrant, MsgLockDeny, MsgLockWait,
		MsgBast, MsgLockRel, MsgRecoveryOk, MsgUnmount,
		MsgMountReq, MsgMountResp,
	}
	seen := make(map[uint32]bool)
	for _, mt := range types {
		if seen[mt] {
			t.Errorf("duplicate message type %d", mt)
		}
		seen[mt] = true
	}
}

func TestEtcdKeyPrefixes(t *testing.T) {
	if PrefixMembers == "" {
		t.Error("PrefixMembers must not be empty")
	}
	if PrefixFencing == "" {
		t.Error("PrefixFencing must not be empty")
	}
	if KeyEpoch == "" {
		t.Error("KeyEpoch must not be empty")
	}
	if PrefixLocks == "" {
		t.Error("PrefixLocks must not be empty")
	}
}

func TestSessionConstants(t *testing.T) {
	if SessionTTL <= 0 {
		t.Error("SessionTTL must be positive")
	}
	if KeepaliveInterval <= 0 || KeepaliveInterval >= SessionTTL {
		t.Error("KeepaliveInterval must be between 1 and SessionTTL")
	}
	if FencingLeaseTTL <= 0 {
		t.Error("FencingLeaseTTL must be positive")
	}
}

func TestNetlinkSizes(t *testing.T) {
	// Verify struct sizes are within protocol limit
	if binary.Size(LockRequest{}) > LetcdMaxPayload {
		t.Error("LockRequest exceeds max payload")
	}
	if binary.Size(LockGrant{}) > LetcdMaxPayload {
		t.Error("LockGrant exceeds max payload")
	}
	if binary.Size(BastNotification{}) > LetcdMaxPayload {
		t.Error("BastNotification exceeds max payload")
	}
	if binary.Size(MountRequest{}) > LetcdMaxPayload {
		t.Error("MountRequest exceeds max payload")
	}
}

func TestGlockTypeValues(t *testing.T) {
	// Must match Linux kernel LM_TYPE_* values exactly
	expected := map[string]uint32{
		"nondisk": LockTypeNondisk,
		"inode":   LockTypeInode,
		"rgrp":    LockTypeRgrp,
		"meta":    LockTypeMeta,
		"iopen":   LockTypeIopen,
		"flock":   LockTypeFlock,
		"plock":   LockTypePlock,
		"quota":   LockTypeQuota,
		"journal": LockTypeJournal,
	}

	for name, val := range expected {
		switch name {
		case "nondisk":
			if val != 1 {
				t.Errorf("LM_TYPE_NONDISK must be 1, got %d", val)
			}
		case "inode":
			if val != 2 {
				t.Errorf("LM_TYPE_INODE must be 2, got %d", val)
			}
		case "journal":
			if val != 9 {
				t.Errorf("LM_TYPE_JOURNAL must be 9, got %d", val)
			}
		}
	}
}
