package netlink

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/polarity/qattach/pkg/protocol"
)

func TestDecodeLE(t *testing.T) {
	type testStruct struct {
		A uint64
		B uint32
		C uint32
	}

	original := testStruct{A: 42, B: 7, C: 99}

	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.LittleEndian, original); err != nil {
		t.Fatal(err)
	}

	var decoded testStruct
	if !decodeLE(buf.Bytes(), &decoded) {
		t.Fatal("decodeLE failed")
	}

	if decoded != original {
		t.Errorf("decodeLE: got %+v, want %+v", decoded, original)
	}
}

func TestDecodeLETruncated(t *testing.T) {
	var v protocol.LockRequest
	if decodeLE([]byte{0x01}, &v) {
		t.Error("decodeLE should fail on truncated data")
	}
}

func TestDecodeLEEmpty(t *testing.T) {
	var v protocol.LockGrant
	if decodeLE([]byte{}, &v) {
		t.Error("decodeLE should fail on empty data")
	}
}
