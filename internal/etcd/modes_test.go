package etcd

import "testing"

// The DLM matrix GFS2 assumes (may_grant in fs/gfs2/glock.c): EX excludes
// everything, PR and CW are compatible only with themselves.  PR/CW used
// to be treated as compatible, which let a direct-I/O holder and a reader
// hold the same object at once.
func TestModesConflict(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want bool
	}{
		{"EX", "EX", true},
		{"EX", "PR", true},
		{"EX", "CW", true},
		{"PR", "EX", true},
		{"PR", "CW", true},
		{"CW", "PR", true},
		{"PR", "PR", false},
		{"CW", "CW", false},
	} {
		if got := modesConflict(tc.a, tc.b); got != tc.want {
			t.Errorf("modesConflict(%q, %q) = %v, want %v",
				tc.a, tc.b, got, tc.want)
		}
	}
}
