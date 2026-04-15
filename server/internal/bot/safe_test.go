package bot

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestSafeRun_PassesThroughSuccess(t *testing.T) {
	err := safeRun(context.Background(), "testbot", func(ctx context.Context) error {
		return nil
	})
	assert.NoError(t, err)
}

func TestSafeRun_PassesThroughError(t *testing.T) {
	sentinel := errors.New("downstream boom")
	err := safeRun(context.Background(), "testbot", func(ctx context.Context) error {
		return sentinel
	})
	assert.ErrorIs(t, err, sentinel)
}

func TestSafeRun_RecoversFromPanic(t *testing.T) {
	err := safeRun(context.Background(), "testbot", func(ctx context.Context) error {
		panic("synthetic explosion")
	})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "panic")
	assert.Contains(t, err.Error(), "synthetic explosion")
}

func TestSafeRun_RecoversFromNilDereference(t *testing.T) {
	// A realistic panic mode: nil-pointer access during RSS parsing.
	err := safeRun(context.Background(), "testbot", func(ctx context.Context) error {
		var m map[string]string
		m["boom"] = "oops" // panics: assignment to entry in nil map
		return nil
	})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "panic")
}

func TestSafeRun_MultipleCallsAfterPanic(t *testing.T) {
	// The scheduler pattern: call safeRun repeatedly. A panic on one
	// call must not prevent subsequent calls from running cleanly.
	calls := 0
	for i := 0; i < 3; i++ {
		_ = safeRun(context.Background(), "testbot", func(ctx context.Context) error {
			calls++
			if calls == 2 {
				panic("one bad run")
			}
			return nil
		})
	}
	assert.Equal(t, 3, calls, "all three calls should have executed; panic must not short-circuit")
}
