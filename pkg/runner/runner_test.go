package runner

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/erauner/homelab-smoke/pkg/config"
	"github.com/erauner/homelab-smoke/pkg/validate"
)

func TestNewRunner(t *testing.T) {
	cfg := &config.Config{
		Checks: []config.Check{
			{Name: "Test", Command: "echo hello"},
		},
	}
	vars := config.TemplateVars{Cluster: "test"}

	r := NewRunner(cfg, "/tmp", vars)

	if r.Config != cfg {
		t.Error("config not set correctly")
	}
	if r.ChecksDir != "/tmp" {
		t.Errorf("ChecksDir expected /tmp, got %s", r.ChecksDir)
	}
	if r.Vars.Cluster != "test" {
		t.Errorf("Cluster expected test, got %s", r.Vars.Cluster)
	}
	if r.DefaultTimeout != 30*time.Second {
		t.Errorf("DefaultTimeout expected 30s, got %v", r.DefaultTimeout)
	}
}

func TestRunnerRun(t *testing.T) {
	cfg := &config.Config{
		Checks: []config.Check{
			{Name: "Pass Check", Command: "echo hello", Layer: 1},
			{Name: "Fail Check", Command: "exit 1", Layer: 2},
		},
	}
	vars := config.TemplateVars{Cluster: "test"}

	r := NewRunner(cfg, "/tmp", vars)
	r.Output = &bytes.Buffer{} // Suppress output

	ctx := context.Background()
	result := r.Run(ctx)

	if result.TotalCount != 2 {
		t.Errorf("TotalCount expected 2, got %d", result.TotalCount)
	}
	if result.PassCount != 1 {
		t.Errorf("PassCount expected 1, got %d", result.PassCount)
	}
	// Fail check is gating by default, so it should cause GatingFails
	if result.GatingFails != 1 {
		t.Errorf("GatingFails expected 1, got %d", result.GatingFails)
	}
}

func TestRunnerWithNonGatingFail(t *testing.T) {
	gatingFalse := false
	cfg := &config.Config{
		Checks: []config.Check{
			{Name: "Pass Check", Command: "echo hello"},
			{
				Name:    "Non-Gating Fail",
				Command: "exit 1",
				Expect:  &config.ExpectConfig{Gating: &gatingFalse},
			},
		},
	}
	vars := config.TemplateVars{Cluster: "test"}

	r := NewRunner(cfg, "/tmp", vars)
	r.Output = &bytes.Buffer{}

	ctx := context.Background()
	result := r.Run(ctx)

	if result.FailCount != 1 {
		t.Errorf("FailCount expected 1, got %d", result.FailCount)
	}
	if result.GatingFails != 0 {
		t.Errorf("GatingFails expected 0 (non-gating), got %d", result.GatingFails)
	}
}

func TestRunnerWithScript(t *testing.T) {
	// Create a temp script
	tmpDir := t.TempDir()
	scriptPath := filepath.Join(tmpDir, "test.sh")

	scriptContent := `#!/bin/sh
echo "script output"
exit 0
`
	if err := os.WriteFile(scriptPath, []byte(scriptContent), 0755); err != nil { //nolint:gosec // Script needs execute permission
		t.Fatalf("failed to write script: %v", err)
	}

	cfg := &config.Config{
		Checks: []config.Check{
			{
				Name: "Script Check",
				Script: &config.ScriptConfig{
					Path: "test.sh",
				},
			},
		},
	}
	vars := config.TemplateVars{Cluster: "test"}

	r := NewRunner(cfg, tmpDir, vars)
	r.Output = &bytes.Buffer{}

	ctx := context.Background()
	result := r.Run(ctx)

	if result.PassCount != 1 {
		t.Errorf("PassCount expected 1, got %d", result.PassCount)
	}
}

func TestRunnerSortByLayer(t *testing.T) {
	cfg := &config.Config{
		Checks: []config.Check{
			{Name: "Layer 3", Layer: 3},
			{Name: "Layer 1", Layer: 1},
			{Name: "Layer 2", Layer: 2},
		},
	}
	vars := config.TemplateVars{}

	r := NewRunner(cfg, "/tmp", vars)
	sorted := r.sortByLayer(cfg.Checks)

	if sorted[0].Layer != 1 {
		t.Errorf("first check should be layer 1, got %d", sorted[0].Layer)
	}
	if sorted[1].Layer != 2 {
		t.Errorf("second check should be layer 2, got %d", sorted[1].Layer)
	}
	if sorted[2].Layer != 3 {
		t.Errorf("third check should be layer 3, got %d", sorted[2].Layer)
	}
}

func TestRunResultExitCode(t *testing.T) {
	tests := []struct {
		name     string
		result   RunResult
		expected int
	}{
		{
			name:     "all passed",
			result:   RunResult{PassCount: 3},
			expected: 0,
		},
		{
			name:     "gating failure",
			result:   RunResult{PassCount: 2, FailCount: 1, GatingFails: 1},
			expected: 1,
		},
		{
			name:     "error",
			result:   RunResult{PassCount: 2, ErrorCount: 1},
			expected: 2,
		},
		{
			name:     "error trumps gating failure",
			result:   RunResult{PassCount: 1, GatingFails: 1, ErrorCount: 1},
			expected: 2,
		},
		{
			name:     "non-gating failure is ok",
			result:   RunResult{PassCount: 2, FailCount: 1, GatingFails: 0},
			expected: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code := tt.result.ExitCode()
			if code != tt.expected {
				t.Errorf("expected %d, got %d", tt.expected, code)
			}
		})
	}
}

func TestShellQuote(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{input: "", expected: "''"},
		{input: "simple", expected: "simple"},
		{input: "with space", expected: "'with space'"},
		{input: "with'quote", expected: "'with'\"'\"'quote'"},
		{input: "special$var", expected: "'special$var'"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := shellQuote(tt.input)
			if result != tt.expected {
				t.Errorf("expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestRunnerWithValidation(t *testing.T) {
	cfg := &config.Config{
		Checks: []config.Check{
			{
				Name:    "With Regex",
				Command: "echo 'HTTP 200'",
				Validate: &validate.Validation{
					Regex: `^HTTP [23][0-9]{2}`,
				},
			},
		},
	}
	vars := config.TemplateVars{}

	r := NewRunner(cfg, "/tmp", vars)
	r.Output = &bytes.Buffer{}

	ctx := context.Background()
	result := r.Run(ctx)

	if result.PassCount != 1 {
		t.Errorf("PassCount expected 1, got %d", result.PassCount)
	}
}
