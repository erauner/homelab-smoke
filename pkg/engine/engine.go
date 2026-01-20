package engine

import (
	"fmt"
	"strings"
)

// CheckResult holds the result of executing a single check.
type CheckResult struct {
	// Output is the stdout/stderr from the command.
	Output string

	// ExitCode is the command's exit code (-1 if execution failed).
	ExitCode int

	// ExecutionError is set if the command couldn't be executed.
	ExecutionError error

	// ValidationErrors are errors from validate postconditions (only on exit 0).
	ValidationErrors []error

	// RetryCount is the number of retries attempted (0 = no retries).
	RetryCount int

	// Outcome is the classified result (PASS, FAIL, WARN, SKIP, ERROR).
	Outcome Outcome

	// Gating indicates whether this check blocks rollouts on failure.
	Gating bool

	// OutcomeReason is a human-readable explanation of the outcome.
	OutcomeReason string
}

// IsPass returns true if the outcome is PASS.
func (r *CheckResult) IsPass() bool {
	return r.Outcome == OutcomePass
}

// IsGatingFailure returns true if this is a FAIL with gating=true,
// or any ERROR (which always blocks).
func (r *CheckResult) IsGatingFailure() bool {
	return r.Outcome.IsBlocking(r.Gating)
}

// AllErrors returns all errors (execution + validation).
func (r *CheckResult) AllErrors() []error {
	var errs []error
	if r.ExecutionError != nil {
		errs = append(errs, r.ExecutionError)
	}
	errs = append(errs, r.ValidationErrors...)
	return errs
}

// ClassifyResult determines the final Outcome based on exit code,
// execution errors, and validation results.
func ClassifyResult(exitCode int, execErr error, validationErrors []error, gating bool) *CheckResult {
	result := &CheckResult{
		ExitCode:         exitCode,
		ExecutionError:   execErr,
		ValidationErrors: validationErrors,
		Gating:           gating,
	}

	// Execution failures (timeout, unexecutable) → ERROR
	if execErr != nil {
		result.Outcome = OutcomeError
		result.OutcomeReason = fmt.Sprintf("execution failed: %v", execErr)
		return result
	}

	// Exit code 0 with failed validation → FAIL
	if exitCode == ExitPass && len(validationErrors) > 0 {
		result.Outcome = OutcomeFail
		result.OutcomeReason = formatValidationFailure(validationErrors)
		return result
	}

	// Map exit codes 0-4 to outcomes
	result.Outcome = OutcomeFromExitCode(exitCode)

	// Set reason based on outcome
	switch result.Outcome {
	case OutcomePass:
		result.OutcomeReason = "check passed"
	case OutcomeFail:
		result.OutcomeReason = "check failed (exit code 1)"
	case OutcomeError:
		if exitCode == ExitError {
			result.OutcomeReason = "script error (exit code 2)"
		} else {
			result.OutcomeReason = fmt.Sprintf("unexpected exit code %d (treated as ERROR)", exitCode)
		}
	case OutcomeSkip:
		result.OutcomeReason = "check skipped (not applicable)"
	case OutcomeWarn:
		result.OutcomeReason = "warning (non-blocking)"
	}

	return result
}

// formatValidationFailure creates a human-readable message for validation failures.
func formatValidationFailure(validationErrors []error) string {
	if len(validationErrors) == 1 {
		return fmt.Sprintf("validation failed: %v", validationErrors[0])
	}

	var msgs []string
	for _, err := range validationErrors {
		msgs = append(msgs, err.Error())
	}
	return fmt.Sprintf("validation failed: %s", strings.Join(msgs, "; "))
}

// ShouldRetry returns true if this result should trigger a retry.
// Only FAIL (exit 1) or execution errors should be retried.
// Validation failures (exit 0 + validate fails) are NOT retried.
func (r *CheckResult) ShouldRetry() bool {
	// Execution error → retry
	if r.ExecutionError != nil {
		return true
	}

	// Exit code 1 (FAIL) → retry
	if r.ExitCode == ExitFail {
		return true
	}

	// Validation failure (exit 0 but validate fails) → no retry
	// PASS, WARN, SKIP, ERROR → no retry
	return false
}
