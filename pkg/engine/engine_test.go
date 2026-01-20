package engine

import (
	"errors"
	"testing"
)

func TestOutcomeFromExitCode(t *testing.T) {
	tests := []struct {
		name     string
		exitCode int
		want     Outcome
	}{
		{"exit 0 is PASS", 0, OutcomePass},
		{"exit 1 is FAIL", 1, OutcomeFail},
		{"exit 2 is ERROR", 2, OutcomeError},
		{"exit 3 is SKIP", 3, OutcomeSkip},
		{"exit 4 is WARN", 4, OutcomeWarn},
		{"exit 5 is ERROR", 5, OutcomeError},
		{"exit -1 is ERROR", -1, OutcomeError},
		{"exit 127 is ERROR", 127, OutcomeError},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := OutcomeFromExitCode(tt.exitCode)
			if got != tt.want {
				t.Errorf("OutcomeFromExitCode(%d) = %v, want %v", tt.exitCode, got, tt.want)
			}
		})
	}
}

func TestOutcome_IsBlocking(t *testing.T) {
	tests := []struct {
		name    string
		outcome Outcome
		gating  bool
		want    bool
	}{
		{"PASS gating=true", OutcomePass, true, false},
		{"PASS gating=false", OutcomePass, false, false},
		{"FAIL gating=true", OutcomeFail, true, true},
		{"FAIL gating=false", OutcomeFail, false, false},
		{"ERROR gating=true", OutcomeError, true, true},
		{"ERROR gating=false", OutcomeError, false, true}, // ERROR always blocks
		{"SKIP gating=true", OutcomeSkip, true, false},
		{"WARN gating=true", OutcomeWarn, true, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.outcome.IsBlocking(tt.gating)
			if got != tt.want {
				t.Errorf("%v.IsBlocking(%v) = %v, want %v", tt.outcome, tt.gating, got, tt.want)
			}
		})
	}
}

func TestClassifyResult_CanonicalExitCodes(t *testing.T) {
	tests := []struct {
		name        string
		exitCode    int
		wantOutcome Outcome
	}{
		{"exit 0 → PASS", 0, OutcomePass},
		{"exit 1 → FAIL", 1, OutcomeFail},
		{"exit 2 → ERROR", 2, OutcomeError},
		{"exit 3 → SKIP", 3, OutcomeSkip},
		{"exit 4 → WARN", 4, OutcomeWarn},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ClassifyResult(tt.exitCode, nil, nil, true)
			if result.Outcome != tt.wantOutcome {
				t.Errorf("ClassifyResult(%d, nil, nil, true).Outcome = %v, want %v",
					tt.exitCode, result.Outcome, tt.wantOutcome)
			}
		})
	}
}

func TestClassifyResult_ExecutionError(t *testing.T) {
	execErr := errors.New("command not found")
	result := ClassifyResult(-1, execErr, nil, true)

	if result.Outcome != OutcomeError {
		t.Errorf("execution error should produce ERROR, got %v", result.Outcome)
	}
	if result.ExecutionError != execErr {
		t.Errorf("ExecutionError should be preserved")
	}
}

func TestClassifyResult_ValidationFailure(t *testing.T) {
	validationErrs := []error{errors.New("output missing 'healthy'")}
	result := ClassifyResult(0, nil, validationErrs, true)

	if result.Outcome != OutcomeFail {
		t.Errorf("exit 0 with validation errors should produce FAIL, got %v", result.Outcome)
	}
	if len(result.ValidationErrors) != 1 {
		t.Errorf("ValidationErrors should be preserved")
	}
}

func TestCheckResult_IsGatingFailure(t *testing.T) {
	tests := []struct {
		name    string
		outcome Outcome
		gating  bool
		want    bool
	}{
		{"FAIL + gating", OutcomeFail, true, true},
		{"FAIL + non-gating", OutcomeFail, false, false},
		{"ERROR + gating", OutcomeError, true, true},
		{"ERROR + non-gating", OutcomeError, false, true}, // ERROR always blocks
		{"PASS + gating", OutcomePass, true, false},
		{"WARN + gating", OutcomeWarn, true, false},
		{"SKIP + gating", OutcomeSkip, true, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := &CheckResult{Outcome: tt.outcome, Gating: tt.gating}
			got := result.IsGatingFailure()
			if got != tt.want {
				t.Errorf("IsGatingFailure() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestCheckResult_ShouldRetry(t *testing.T) {
	tests := []struct {
		name     string
		exitCode int
		execErr  error
		valErrs  []error
		want     bool
	}{
		{"exit 0 (PASS)", 0, nil, nil, false},
		{"exit 1 (FAIL)", 1, nil, nil, true},
		{"exit 2 (ERROR)", 2, nil, nil, false},
		{"exit 3 (SKIP)", 3, nil, nil, false},
		{"exit 4 (WARN)", 4, nil, nil, false},
		{"execution error", -1, errors.New("timeout"), nil, true},
		{"validation failure", 0, nil, []error{errors.New("missing text")}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := &CheckResult{
				ExitCode:         tt.exitCode,
				ExecutionError:   tt.execErr,
				ValidationErrors: tt.valErrs,
			}
			got := result.ShouldRetry()
			if got != tt.want {
				t.Errorf("ShouldRetry() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestCheckResult_AllErrors(t *testing.T) {
	execErr := errors.New("exec error")
	valErr1 := errors.New("val error 1")
	valErr2 := errors.New("val error 2")

	result := &CheckResult{
		ExecutionError:   execErr,
		ValidationErrors: []error{valErr1, valErr2},
	}

	errs := result.AllErrors()
	if len(errs) != 3 {
		t.Errorf("AllErrors() returned %d errors, want 3", len(errs))
	}
}
