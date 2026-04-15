package bot

import (
	"context"
	"fmt"
	"log"
	"runtime/debug"
)

// runOnceFunc is the signature of a bot's RunOnce method. Defined as a
// function type so safeRun works with any bot without a shared interface.
type runOnceFunc func(context.Context) error

// safeRun invokes fn and converts any panic into an error. The panic
// message and stack trace are logged so the underlying bug is visible,
// but the caller (typically the scheduler loop) is not taken down.
//
// A panic in RunOnce used to crash the whole API process because both
// bots previously ran inside the API container. Now the scheduler keeps
// running and the next tick gets another attempt.
func safeRun(ctx context.Context, botName string, fn runOnceFunc) (err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := debug.Stack()
			log.Printf("[%s] PANIC recovered in RunOnce: %v\n%s", botName, r, stack)
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return fn(ctx)
}
