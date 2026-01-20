// Package engine provides outcome classification for smoke test checks.
package engine

// Outcome represents the result classification of a smoke test check.
type Outcome string

const (
	// OutcomePass indicates the check succeeded.
	OutcomePass Outcome = "PASS"
	// OutcomeFail indicates the check failed (gating by default).
	OutcomeFail Outcome = "FAIL"
	// OutcomeError indicates a script/tool error (always blocks).
	OutcomeError Outcome = "ERROR"
	// OutcomeSkip indicates the check was skipped (not applicable).
	OutcomeSkip Outcome = "SKIP"
	// OutcomeWarn indicates a warning (non-blocking).
	OutcomeWarn Outcome = "WARN"
)

// ExitCode constants matching the exit code contract.
const (
	ExitPass  = 0
	ExitFail  = 1
	ExitError = 2
	ExitSkip  = 3
	ExitWarn  = 4
)

// OutcomeFromExitCode maps an exit code to an Outcome.
// Exit codes 0-4 map to canonical outcomes; anything else is ERROR.
func OutcomeFromExitCode(code int) Outcome {
	switch code {
	case ExitPass:
		return OutcomePass
	case ExitFail:
		return OutcomeFail
	case ExitError:
		return OutcomeError
	case ExitSkip:
		return OutcomeSkip
	case ExitWarn:
		return OutcomeWarn
	default:
		return OutcomeError
	}
}

// IsBlocking returns true if this outcome should block rollouts.
// ERROR always blocks. FAIL blocks if gating=true.
// PASS, SKIP, and WARN never block.
func (o Outcome) IsBlocking(gating bool) bool {
	switch o {
	case OutcomeError:
		return true
	case OutcomeFail:
		return gating
	default:
		return false
	}
}

// Symbol returns a display symbol for the outcome.
func (o Outcome) Symbol() string {
	switch o {
	case OutcomePass:
		return "✓"
	case OutcomeFail:
		return "✗"
	case OutcomeError:
		return "!"
	case OutcomeSkip:
		return "⊘"
	case OutcomeWarn:
		return "⚠"
	default:
		return "?"
	}
}

// Color returns an ANSI color code for terminal output.
func (o Outcome) Color() string {
	switch o {
	case OutcomePass:
		return "\033[0;32m" // Green
	case OutcomeFail:
		return "\033[0;31m" // Red
	case OutcomeError:
		return "\033[0;31m" // Red
	case OutcomeSkip:
		return "\033[0;90m" // Gray
	case OutcomeWarn:
		return "\033[0;33m" // Yellow
	default:
		return "\033[0m" // Reset
	}
}

// ColorReset returns the ANSI reset code.
func ColorReset() string {
	return "\033[0m"
}
