// Package exec provides command execution with timeout and retry support.
package exec

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// CommandResult holds the result of a command execution.
type CommandResult struct {
	Output   string
	ExitCode int
	Error    error
}

// RunCommand executes a shell command with the given timeout.
// Returns the combined stdout/stderr, exit code, and any execution error.
func RunCommand(ctx context.Context, command string, timeout time.Duration) CommandResult {
	if timeout <= 0 {
		timeout = 30 * time.Second
	}

	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Execute via shell for proper command parsing
	cmd := exec.CommandContext(ctx, "sh", "-c", command)

	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output

	err := cmd.Run()

	result := CommandResult{
		Output:   output.String(),
		ExitCode: 0,
	}

	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			result.Error = fmt.Errorf("command timed out after %v", timeout)
			result.ExitCode = -1
			return result
		}

		if exitErr, ok := err.(*exec.ExitError); ok {
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				result.ExitCode = status.ExitStatus()
			} else {
				result.ExitCode = 1
			}
		} else {
			result.Error = fmt.Errorf("command execution failed: %w", err)
			result.ExitCode = -1
		}
	}

	return result
}

// RunScript executes a script file with arguments.
// The scriptPath is relative to checksDir if not absolute.
func RunScript(ctx context.Context, scriptPath string, args []string, checksDir string, timeout time.Duration) CommandResult {
	// Resolve script path
	if !filepath.IsAbs(scriptPath) {
		scriptPath = filepath.Join(checksDir, scriptPath)
	}

	// Verify script exists and is executable
	info, err := os.Stat(scriptPath)
	if err != nil {
		return CommandResult{
			Error:    fmt.Errorf("script not found: %s", scriptPath),
			ExitCode: -1,
		}
	}

	if info.IsDir() {
		return CommandResult{
			Error:    fmt.Errorf("script path is a directory: %s", scriptPath),
			ExitCode: -1,
		}
	}

	// Build command with properly quoted arguments
	command := scriptPath
	for _, arg := range args {
		command += " " + shellQuote(arg)
	}

	return RunCommand(ctx, command, timeout)
}

// RunWithRetry executes a command with retry logic.
// Returns the result and the number of attempts made.
func RunWithRetry(ctx context.Context, command string, timeout time.Duration, maxRetries int, retryDelay time.Duration) (CommandResult, int) {
	if maxRetries < 0 {
		maxRetries = 0
	}
	if retryDelay <= 0 {
		retryDelay = 2 * time.Second
	}

	var result CommandResult
	attempts := 0

	for attempts <= maxRetries {
		attempts++
		result = RunCommand(ctx, command, timeout)

		// Check if we should retry
		if !shouldRetry(result) {
			return result, attempts
		}

		// Don't sleep after the last attempt
		if attempts <= maxRetries {
			select {
			case <-ctx.Done():
				result.Error = ctx.Err()
				return result, attempts
			case <-time.After(retryDelay):
			}
		}
	}

	return result, attempts
}

// shouldRetry determines if a command result warrants a retry.
// Only FAIL (exit 1) or execution errors should be retried.
func shouldRetry(result CommandResult) bool {
	// Execution error → retry
	if result.Error != nil {
		return true
	}
	// Exit code 1 (FAIL) → retry
	if result.ExitCode == 1 {
		return true
	}
	return false
}

// shellQuote quotes a string for safe shell usage.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	// If no special characters, return as-is
	if !strings.ContainsAny(s, " \t\n'\"\\$`!*?[]{}|<>&;()") {
		return s
	}
	// Use single quotes, escaping any single quotes in the string
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
