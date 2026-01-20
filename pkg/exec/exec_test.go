package exec

import (
	"context"
	"testing"
	"time"
)

func TestRunCommand(t *testing.T) {
	ctx := context.Background()

	tests := []struct {
		name         string
		command      string
		timeout      time.Duration
		wantExitCode int
		wantError    bool
		wantOutput   string
	}{
		{
			name:         "simple echo",
			command:      "echo hello",
			timeout:      5 * time.Second,
			wantExitCode: 0,
			wantOutput:   "hello\n",
		},
		{
			name:         "exit code 1",
			command:      "exit 1",
			timeout:      5 * time.Second,
			wantExitCode: 1,
		},
		{
			name:         "exit code 2",
			command:      "exit 2",
			timeout:      5 * time.Second,
			wantExitCode: 2,
		},
		{
			name:         "command with output and exit code",
			command:      "echo 'test output' && exit 3",
			timeout:      5 * time.Second,
			wantExitCode: 3,
			wantOutput:   "test output\n",
		},
		{
			name:         "timeout",
			command:      "sleep 10",
			timeout:      100 * time.Millisecond,
			wantExitCode: -1,
			wantError:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := RunCommand(ctx, tt.command, tt.timeout)

			if result.ExitCode != tt.wantExitCode {
				t.Errorf("expected exit code %d, got %d", tt.wantExitCode, result.ExitCode)
			}

			if tt.wantError && result.Error == nil {
				t.Error("expected error, got nil")
			}

			if !tt.wantError && result.Error != nil {
				t.Errorf("unexpected error: %v", result.Error)
			}

			if tt.wantOutput != "" && result.Output != tt.wantOutput {
				t.Errorf("expected output %q, got %q", tt.wantOutput, result.Output)
			}
		})
	}
}

func TestRunCommandCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel immediately

	result := RunCommand(ctx, "sleep 10", 5*time.Second)

	if result.Error == nil {
		t.Error("expected error for canceled context")
	}

	if result.ExitCode != -1 {
		t.Errorf("expected exit code -1, got %d", result.ExitCode)
	}
}

func TestRunWithRetry(t *testing.T) {
	ctx := context.Background()

	// Test that retry returns correct attempt count
	t.Run("no retry needed on success", func(t *testing.T) {
		result, attempts := RunWithRetry(ctx, "echo success", 5*time.Second, 3, 10*time.Millisecond)
		if attempts != 1 {
			t.Errorf("expected 1 attempt, got %d", attempts)
		}
		if result.ExitCode != 0 {
			t.Errorf("expected exit code 0, got %d", result.ExitCode)
		}
	})

	t.Run("retry on failure", func(t *testing.T) {
		// This always fails, so should retry maxRetries times
		result, attempts := RunWithRetry(ctx, "exit 1", 5*time.Second, 2, 10*time.Millisecond)
		if attempts != 3 { // 1 initial + 2 retries
			t.Errorf("expected 3 attempts, got %d", attempts)
		}
		if result.ExitCode != 1 {
			t.Errorf("expected exit code 1, got %d", result.ExitCode)
		}
	})

	t.Run("no retry on exit 2 (ERROR)", func(t *testing.T) {
		result, attempts := RunWithRetry(ctx, "exit 2", 5*time.Second, 3, 10*time.Millisecond)
		if attempts != 1 {
			t.Errorf("expected 1 attempt (no retry on ERROR), got %d", attempts)
		}
		if result.ExitCode != 2 {
			t.Errorf("expected exit code 2, got %d", result.ExitCode)
		}
	})
}

func TestRetryBehavior(t *testing.T) {
	ctx := context.Background()

	// Test retry behavior through RunWithRetry for different exit codes
	tests := []struct {
		name            string
		command         string
		expectRetries   bool // whether retries should happen
		expectedAttempt int  // expected number of attempts
	}{
		{
			name:            "exit 0 - no retry",
			command:         "exit 0",
			expectRetries:   false,
			expectedAttempt: 1,
		},
		{
			name:            "exit 1 - retry (FAIL)",
			command:         "exit 1",
			expectRetries:   true,
			expectedAttempt: 3, // 1 initial + 2 retries
		},
		{
			name:            "exit 2 - no retry (ERROR)",
			command:         "exit 2",
			expectRetries:   false,
			expectedAttempt: 1,
		},
		{
			name:            "exit 3 - no retry (SKIP)",
			command:         "exit 3",
			expectRetries:   false,
			expectedAttempt: 1,
		},
		{
			name:            "exit 4 - no retry (WARN)",
			command:         "exit 4",
			expectRetries:   false,
			expectedAttempt: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, attempts := RunWithRetry(ctx, tt.command, 5*time.Second, 2, 10*time.Millisecond)
			if attempts != tt.expectedAttempt {
				t.Errorf("expected %d attempts, got %d", tt.expectedAttempt, attempts)
			}
		})
	}
}
