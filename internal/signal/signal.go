package signal

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
)

// Wait blocks until SIGTERM or SIGINT is received, then calls cleanup.
func Wait(ctx context.Context, cleanup func()) error {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	select {
	case <-ctx.Done():
		log.Println("context cancelled, shutting down")
	case sig := <-sigCh:
		log.Printf("received signal %s, shutting down", sig)
	}

	if cleanup != nil {
		cleanup()
	}

	return nil
}

// Context returns a context that is cancelled on SIGTERM/SIGINT.
func Context() (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		select {
		case sig := <-sigCh:
			log.Printf("received signal %s, cancelling context", sig)
			cancel()
		}
	}()

	return ctx, cancel
}
