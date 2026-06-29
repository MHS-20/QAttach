package signal

import (
	"testing"
	"time"
)

func TestContextCancellation(t *testing.T) {
	ctx, cancel := Context()
	defer cancel()

	// Context should start alive
	select {
	case <-ctx.Done():
		t.Fatal("context should not be done initially")
	default:
	}

	// Manual cancel should work
	cancel()

	select {
	case <-ctx.Done():
		// expected
	case <-time.After(time.Second):
		t.Fatal("context should be done after cancel")
	}
}
