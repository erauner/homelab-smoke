package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/erauner/homelab-smoke/pkg/validate"
)

func TestLoadConfig(t *testing.T) {
	// Create a temp config file
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "checks.yaml")

	configContent := `
checks:
  - name: "Test Check"
    description: "A test check"
    layer: 1
    command: "echo hello"
    expect:
      gating: true
`
	if err := os.WriteFile(configPath, []byte(configContent), 0600); err != nil {
		t.Fatalf("failed to write config: %v", err)
	}

	cfg, err := LoadConfig(configPath)
	if err != nil {
		t.Fatalf("LoadConfig failed: %v", err)
	}

	if len(cfg.Checks) != 1 {
		t.Errorf("expected 1 check, got %d", len(cfg.Checks))
	}

	if cfg.Checks[0].Name != "Test Check" {
		t.Errorf("expected name 'Test Check', got %q", cfg.Checks[0].Name)
	}

	if cfg.Checks[0].Layer != 1 {
		t.Errorf("expected layer 1, got %d", cfg.Checks[0].Layer)
	}
}

func TestLoadConfigNotFound(t *testing.T) {
	_, err := LoadConfig("/nonexistent/path/checks.yaml")
	if err == nil {
		t.Error("expected error for nonexistent file")
	}
}

func TestLoadConfigInvalidYAML(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "checks.yaml")

	if err := os.WriteFile(configPath, []byte("invalid: yaml: content:"), 0600); err != nil {
		t.Fatalf("failed to write config: %v", err)
	}

	_, err := LoadConfig(configPath)
	if err == nil {
		t.Error("expected error for invalid YAML")
	}
}

func TestConfigValidate(t *testing.T) {
	tests := []struct {
		name    string
		config  Config
		wantErr bool
		errMsg  string
	}{
		{
			name:    "empty checks",
			config:  Config{Checks: []Check{}},
			wantErr: true,
			errMsg:  "no checks defined",
		},
		{
			name: "missing name",
			config: Config{Checks: []Check{
				{Command: "echo hello"},
			}},
			wantErr: true,
			errMsg:  "missing name",
		},
		{
			name: "missing command and script",
			config: Config{Checks: []Check{
				{Name: "Test"},
			}},
			wantErr: true,
			errMsg:  "must have command or script",
		},
		{
			name: "script missing path",
			config: Config{Checks: []Check{
				{Name: "Test", Script: &ScriptConfig{}},
			}},
			wantErr: true,
			errMsg:  "script missing path",
		},
		{
			name: "invalid regex",
			config: Config{Checks: []Check{
				{
					Name:    "Test",
					Command: "echo hello",
					Validate: &validate.Validation{Regex: "[invalid"},
				},
			}},
			wantErr: true,
			errMsg:  "invalid regex",
		},
		{
			name: "valid config with command",
			config: Config{Checks: []Check{
				{Name: "Test", Command: "echo hello"},
			}},
			wantErr: false,
		},
		{
			name: "valid config with script",
			config: Config{Checks: []Check{
				{Name: "Test", Script: &ScriptConfig{Path: "./test.sh"}},
			}},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.config.Validate()
			if tt.wantErr {
				if err == nil {
					t.Errorf("expected error containing %q, got nil", tt.errMsg)
				}
			} else {
				if err != nil {
					t.Errorf("unexpected error: %v", err)
				}
			}
		})
	}
}

func TestApplyTemplate(t *testing.T) {
	vars := TemplateVars{
		Cluster:   "home",
		Namespace: "default",
		Context:   "home-admin",
	}

	tests := []struct {
		name     string
		input    string
		expected string
		wantErr  bool
	}{
		{
			name:     "no template",
			input:    "echo hello",
			expected: "echo hello",
		},
		{
			name:     "cluster var",
			input:    "echo {{.Cluster}}",
			expected: "echo home",
		},
		{
			name:     "multiple vars",
			input:    "kubectl -n {{.Namespace}} --context={{.Context}} get pods",
			expected: "kubectl -n default --context=home-admin get pods",
		},
		{
			name:     "empty input",
			input:    "",
			expected: "",
		},
		{
			name:    "invalid template",
			input:   "{{.Invalid",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := ApplyTemplate(tt.input, vars)
			if tt.wantErr {
				if err == nil {
					t.Error("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result != tt.expected {
				t.Errorf("expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestCheckIsGating(t *testing.T) {
	boolTrue := true
	boolFalse := false

	tests := []struct {
		name     string
		check    Check
		expected bool
	}{
		{
			name:     "nil expect",
			check:    Check{},
			expected: true, // default is gating
		},
		{
			name:     "nil gating",
			check:    Check{Expect: &ExpectConfig{}},
			expected: true, // default is gating
		},
		{
			name:     "explicit true",
			check:    Check{Expect: &ExpectConfig{Gating: &boolTrue}},
			expected: true,
		},
		{
			name:     "explicit false",
			check:    Check{Expect: &ExpectConfig{Gating: &boolFalse}},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := tt.check.IsGating()
			if result != tt.expected {
				t.Errorf("expected %v, got %v", tt.expected, result)
			}
		})
	}
}
