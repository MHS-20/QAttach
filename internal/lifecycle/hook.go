package lifecycle

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/autoscaling"
)

// HookHandler watches for ASG lifecycle hooks targeting this instance and
// performs clean shutdown (unmount, deregister) before signaling completion.
type HookHandler struct {
	asgClient  *autoscaling.Client
	instanceID string
}

// CleanupFunc is called when a terminating lifecycle hook is detected.
// It should unmount GFS2, deregister from etcd, and return any error.
type CleanupFunc func(ctx context.Context) error

// NewHookHandler creates an ASG lifecycle hook handler.
func NewHookHandler(instanceID string) (*HookHandler, error) {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}

	return &HookHandler{
		asgClient:  autoscaling.NewFromConfig(cfg),
		instanceID: instanceID,
	}, nil
}

// PollTerminating polls the ASG API every interval until this instance enters
// the Terminating:Wait lifecycle state.  When it does, calls cleanup and then
// signals CONTINUE to the ASG so the instance can finish termination.
func (h *HookHandler) PollTerminating(ctx context.Context, asgName string,
	interval time.Duration, cleanup CleanupFunc) {

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		state, hookName, err := h.checkLifecycleState(ctx, asgName)
		if err != nil {
			log.Printf("lifecycle poll error: %v", err)
			continue
		}

		if state == "Terminating:Wait" {
			log.Printf("ASG lifecycle hook detected: %s (state=%s)",
				hookName, state)

			// Perform clean shutdown
			cleanupErr := cleanup(ctx)
			if cleanupErr != nil {
				log.Printf("cleanup error: %v — signaling ABANDON", cleanupErr)
				h.completeHook(ctx, hookName, asgName, "ABANDON")
			} else {
				log.Printf("cleanup complete — signaling CONTINUE")
				h.completeHook(ctx, hookName, asgName, "CONTINUE")
			}
			return
		}
	}
}

// checkLifecycleState queries the ASG for this instance's lifecycle state.
func (h *HookHandler) checkLifecycleState(ctx context.Context, asgName string) (string, string, error) {
	resp, err := h.asgClient.DescribeAutoScalingInstances(ctx,
		&autoscaling.DescribeAutoScalingInstancesInput{
			InstanceIds: []string{h.instanceID},
		})
	if err != nil {
		return "", "", err
	}

	for _, inst := range resp.AutoScalingInstances {
		if aws.ToString(inst.InstanceId) == h.instanceID {
			state := aws.ToString(inst.LifecycleState)
			hook := ""
			return state, hook, nil
		}
	}

	return "", "", fmt.Errorf("instance %s not found in ASG", h.instanceID)
}

// completeHook signals the ASG lifecycle hook result.
func (h *HookHandler) completeHook(ctx context.Context, hookName, asgName, result string) {
	// When the lifecycle state is Terminating:Wait, we call
	// CompleteLifecycleAction to proceed with termination.
	_, err := h.asgClient.CompleteLifecycleAction(ctx,
		&autoscaling.CompleteLifecycleActionInput{
			AutoScalingGroupName:  aws.String(asgName),
			InstanceId:            aws.String(h.instanceID),
			LifecycleActionResult: aws.String(result),
			LifecycleHookName:     aws.String(hookName),
		})
	if err != nil {
		log.Printf("CompleteLifecycleAction error: %v", err)
	}
}
