// Package runner provides the main orchestration for smoke test execution.
package runner

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/erauner/homelab-smoke/pkg/config"
	"github.com/erauner/homelab-smoke/pkg/engine"
	"github.com/erauner/homelab-smoke/pkg/exec"
	"github.com/erauner/homelab-smoke/pkg/validate"
)

// Runner executes smoke test checks.
type Runner struct {
	// Config is the loaded smoke test configuration.
	Config *config.Config

	// ChecksDir is the directory containing check scripts.
	ChecksDir string

	// Vars are the template variables for command substitution.
	Vars config.TemplateVars

	// DefaultTimeout is the default timeout for checks.
	DefaultTimeout time.Duration

	// MaxRetries is the maximum number of retries for failing checks.
	MaxRetries int

	// RetryDelay is the delay between retries.
	RetryDelay time.Duration

	// Verbose enables verbose output.
	Verbose bool

	// Output is the writer for check output.
	Output io.Writer
}

// CheckExecutionResult holds the result of a single check execution.
type CheckExecutionResult struct {
	Check  *config.Check
	Result *engine.CheckResult
}

// RunResult holds the result of running all checks.
type RunResult struct {
	Results     []CheckExecutionResult
	PassCount   int
	FailCount   int
	WarnCount   int
	SkipCount   int
	ErrorCount  int
	TotalCount  int
	GatingFails int
}

// NewRunner creates a new Runner with the given configuration.
func NewRunner(cfg *config.Config, checksDir string, vars config.TemplateVars) *Runner {
	return &Runner{
		Config:         cfg,
		ChecksDir:      checksDir,
		Vars:           vars,
		DefaultTimeout: 30 * time.Second,
		MaxRetries:     3,
		RetryDelay:     2 * time.Second,
		Verbose:        false,
		Output:         os.Stdout,
	}
}

// Run executes all checks and returns the aggregate result.
func (r *Runner) Run(ctx context.Context) *RunResult {
	result := &RunResult{
		TotalCount: len(r.Config.Checks),
	}

	// Sort checks by layer for fail-fast behavior
	checks := r.sortByLayer(r.Config.Checks)

	currentLayer := -1

	for i, check := range checks {
		// Print layer separator if layer changed
		if check.Layer != currentLayer && check.Layer > 0 {
			currentLayer = check.Layer
			_, _ = fmt.Fprintf(r.Output, "\n--- Layer %d ---\n", currentLayer)
		}

		// Print check progress
		_, _ = fmt.Fprintf(r.Output, "[%d/%d] %s... ", i+1, result.TotalCount, check.Name)

		// Execute the check
		execResult := r.executeCheck(ctx, &check)

		// Print result
		r.printResult(execResult)

		// Record result
		result.Results = append(result.Results, CheckExecutionResult{
			Check:  &check,
			Result: execResult,
		})

		// Update counts
		switch execResult.Outcome {
		case engine.OutcomePass:
			result.PassCount++
		case engine.OutcomeFail:
			result.FailCount++
			if execResult.Gating {
				result.GatingFails++
			}
		case engine.OutcomeWarn:
			result.WarnCount++
		case engine.OutcomeSkip:
			result.SkipCount++
		case engine.OutcomeError:
			result.ErrorCount++
		}

		// Fail fast on gating failure if enabled
		if execResult.IsGatingFailure() && r.shouldFailFast() {
			_, _ = fmt.Fprintf(r.Output, "\n[!] Gating check failed - stopping execution\n")
			break
		}
	}

	return result
}

// executeCheck runs a single check and returns the classified result.
func (r *Runner) executeCheck(ctx context.Context, check *config.Check) *engine.CheckResult {
	// Apply template variables
	templatedCheck, err := config.ApplyTemplateToCheck(check, r.Vars)
	if err != nil {
		return engine.ClassifyResult(-1, err, nil, check.IsGating())
	}

	timeout := check.GetTimeout(r.DefaultTimeout)

	// Determine command to run
	var cmdResult exec.CommandResult
	var attempts int

	if templatedCheck.Script != nil {
		// Script-based check
		command := r.buildScriptCommand(templatedCheck.Script)
		if check.Retry {
			cmdResult, attempts = exec.RunWithRetry(ctx, command, timeout, r.MaxRetries, r.RetryDelay)
		} else {
			cmdResult = exec.RunCommand(ctx, command, timeout)
			attempts = 1
		}
	} else if templatedCheck.Command != "" {
		// Inline command
		if check.Retry {
			cmdResult, attempts = exec.RunWithRetry(ctx, templatedCheck.Command, timeout, r.MaxRetries, r.RetryDelay)
		} else {
			cmdResult = exec.RunCommand(ctx, templatedCheck.Command, timeout)
			attempts = 1
		}
	} else {
		return engine.ClassifyResult(-1, fmt.Errorf("check has no command or script"), nil, check.IsGating())
	}

	// Validate output (only on exit 0)
	var validationErrors []error
	if cmdResult.ExitCode == 0 && cmdResult.Error == nil && check.Validate != nil {
		validationErrors = validate.Output(cmdResult.Output, check.Validate)
	}

	// Classify the result
	result := engine.ClassifyResult(cmdResult.ExitCode, cmdResult.Error, validationErrors, check.IsGating())
	result.Output = cmdResult.Output
	result.RetryCount = attempts - 1

	return result
}

// buildScriptCommand builds a command string from a script config.
func (r *Runner) buildScriptCommand(script *config.ScriptConfig) string {
	path := script.Path
	if !filepath.IsAbs(path) {
		path = filepath.Join(r.ChecksDir, path)
	}

	if len(script.Args) == 0 {
		return path
	}

	// Quote arguments for safe shell usage
	args := make([]string, len(script.Args))
	for i, arg := range script.Args {
		args[i] = shellQuote(arg)
	}

	return path + " " + strings.Join(args, " ")
}

// sortByLayer sorts checks by layer (ascending) for fail-fast behavior.
func (r *Runner) sortByLayer(checks []config.Check) []config.Check {
	sorted := make([]config.Check, len(checks))
	copy(sorted, checks)

	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].Layer < sorted[j].Layer
	})

	return sorted
}

// shouldFailFast returns true if execution should stop on gating failure.
// For now, always fail fast - can be made configurable later.
func (r *Runner) shouldFailFast() bool {
	return true
}

// printResult prints the check result with appropriate formatting.
func (r *Runner) printResult(result *engine.CheckResult) {
	color := result.Outcome.Color()
	reset := engine.ColorReset()

	_, _ = fmt.Fprintf(r.Output, "%s%s%s\n", color, result.Outcome, reset)

	if r.Verbose || result.Outcome == engine.OutcomeError || result.Outcome == engine.OutcomeFail {
		if result.OutcomeReason != "" {
			_, _ = fmt.Fprintf(r.Output, "  Reason: %s\n", result.OutcomeReason)
		}
		if result.RetryCount > 0 {
			_, _ = fmt.Fprintf(r.Output, "  Retries: %d\n", result.RetryCount)
		}
	}

	if r.Verbose && result.Output != "" {
		_, _ = fmt.Fprintf(r.Output, "  Output:\n")
		for _, line := range strings.Split(strings.TrimSpace(result.Output), "\n") {
			_, _ = fmt.Fprintf(r.Output, "    %s\n", line)
		}
	}
}

// PrintSummary prints the final summary of all checks.
// duration is an optional formatted duration string (pass empty string to omit).
func (r *Runner) PrintSummary(result *RunResult, duration string) {
	_, _ = fmt.Fprintf(r.Output, "\n")
	_, _ = fmt.Fprintf(r.Output, "========================================\n")
	_, _ = fmt.Fprintf(r.Output, "Summary: %d passed, %d failed, %d warnings, %d skipped, %d errors (out of %d total)\n",
		result.PassCount, result.FailCount, result.WarnCount, result.SkipCount, result.ErrorCount, result.TotalCount)

	if duration != "" {
		_, _ = fmt.Fprintf(r.Output, "Total time: %s\n", duration)
	}

	if result.GatingFails > 0 {
		_, _ = fmt.Fprintf(r.Output, "\n%s%d gating check(s) failed - deployment blocked%s\n",
			engine.OutcomeFail.Color(), result.GatingFails, engine.ColorReset())
	}
	_, _ = fmt.Fprintf(r.Output, "========================================\n")
}

// ExitCode returns the appropriate CLI exit code based on results.
// 0 = all passed, 1 = gating failures, 2 = errors
func (result *RunResult) ExitCode() int {
	if result.ErrorCount > 0 {
		return 2
	}
	if result.GatingFails > 0 {
		return 1
	}
	return 0
}

// shellQuote quotes a string for safe shell usage.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	if !strings.ContainsAny(s, " \t\n'\"\\$`!*?[]{}|<>&;()") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
