package etcd

import "testing"

// DeleteBastRequest only deletes when the stored value equals
// bastValue(mode, waiter), so the encode/decode pair must round-trip.
func TestBastValueRoundTrip(t *testing.T) {
	for _, tc := range []struct {
		mode   uint32
		waiter string
	}{
		{0, "i-0f620a6db190e05ce"},
		{3, "node-1"},
		{5, "a,b"}, // node IDs never contain commas, but the split must not lose one
	} {
		ok, mode, waiter := parseBastValue(bastValue(tc.mode, tc.waiter))
		if !ok || mode != tc.mode || waiter != tc.waiter {
			t.Errorf("round-trip(%d, %q) = %v, %d, %q",
				tc.mode, tc.waiter, ok, mode, waiter)
		}
	}

	for _, bad := range []string{"", "0", "notamode,node", ",node", "0,"} {
		if ok, _, _ := parseBastValue(bad); ok {
			t.Errorf("parseBastValue(%q) accepted a malformed value", bad)
		}
	}
}
