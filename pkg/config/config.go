// Package config provides configuration loading for smoke tests.
package config

import (
	"bytes"
	"fmt"
	"os"
	"regexp"
	"text/template"
	"time"

	"github.com/erauner/homelab-smoke/pkg/validate"
	"gopkg.in/yaml.v3"
)

// Config holds the complete smoke test configuration.
type Config struct {
	Checks []Check `yaml:"checks"`
}

// Check defines a single smoke test check.
type Check struct {
	// Name is the display name for the check.
	Name string `yaml:"name"`

	// Description provides additional context about the check.
	Description string `yaml:"description,omitempty"`

	// Layer determines execution order (lower layers run first, fail fast).
	Layer int `yaml:"layer,omitempty"`

	// Command is the shell command to run (alternative to Script).
	Command string `yaml:"command,omitempty"`

	// Script defines an external script to run (alternative to Command).
	Script *ScriptConfig `yaml:"script,omitempty"`

	// Validate defines output validation postconditions.
	Validate *validate.Validation `yaml:"validate,omitempty"`

	// Expect defines expectations for the check result.
	Expect *ExpectConfig `yaml:"expect,omitempty"`

	// Retry enables retry on failure.
	Retry bool `yaml:"retry,omitempty"`

	// Timeout is the per-check timeout (overrides default).
	Timeout Duration `yaml:"timeout,omitempty"`
}

// ScriptConfig defines an external script to run.
type ScriptConfig struct {
	// Path is the path to the script file (relative to checks dir or absolute).
	Path string `yaml:"path"`

	// Args are the arguments to pass to the script.
	Args []string `yaml:"args,omitempty"`
}

// ExpectConfig defines expectations for check results.
type ExpectConfig struct {
	// Gating indicates whether FAIL blocks rollouts (default: true).
	Gating *bool `yaml:"gating,omitempty"`
}

// IsGating returns whether this check is gating (blocks on failure).
// Defaults to true if not explicitly set.
func (c *Check) IsGating() bool {
	if c.Expect == nil || c.Expect.Gating == nil {
		return true // Default: gating
	}
	return *c.Expect.Gating
}

// GetTimeout returns the check timeout, or the default if not set.
func (c *Check) GetTimeout(defaultTimeout time.Duration) time.Duration {
	if c.Timeout.Duration > 0 {
		return c.Timeout.Duration
	}
	return defaultTimeout
}

// Duration is a wrapper for time.Duration that supports YAML unmarshaling.
type Duration struct {
	time.Duration
}

// UnmarshalYAML implements yaml.Unmarshaler for Duration.
func (d *Duration) UnmarshalYAML(value *yaml.Node) error {
	var s string
	if err := value.Decode(&s); err != nil {
		return err
	}
	if s == "" {
		d.Duration = 0
		return nil
	}
	parsed, err := time.ParseDuration(s)
	if err != nil {
		return fmt.Errorf("invalid duration %q: %w", s, err)
	}
	d.Duration = parsed
	return nil
}

// TemplateVars holds template variables for command substitution.
type TemplateVars struct {
	// Cluster is the target cluster name (e.g., "home").
	Cluster string

	// Namespace is the target namespace.
	Namespace string

	// Context is the kubectl context.
	Context string

	// Custom allows for additional custom variables.
	Custom map[string]string
}

// LoadConfig loads a smoke test configuration from a YAML file.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path) //nolint:gosec // Path is user-provided config file
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config Config
	if err := yaml.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	return &config, nil
}

// Validate checks the configuration for errors.
// Returns an error if any check is invalid.
func (c *Config) Validate() error {
	if len(c.Checks) == 0 {
		return fmt.Errorf("no checks defined")
	}

	for i, check := range c.Checks {
		// Check must have a name
		if check.Name == "" {
			return fmt.Errorf("check %d: missing name", i)
		}

		// Check must have either command or script
		if check.Command == "" && check.Script == nil {
			return fmt.Errorf("check %d (%s): must have command or script", i, check.Name)
		}

		// Script must have a path
		if check.Script != nil && check.Script.Path == "" {
			return fmt.Errorf("check %d (%s): script missing path", i, check.Name)
		}

		// Validate regex syntax at load time
		if check.Validate != nil && check.Validate.Regex != "" {
			if _, err := regexp.Compile(check.Validate.Regex); err != nil {
				return fmt.Errorf("check %d (%s): invalid regex %q: %w", i, check.Name, check.Validate.Regex, err)
			}
		}
	}

	return nil
}

// ApplyTemplate applies template variables to a string.
func ApplyTemplate(input string, vars TemplateVars) (string, error) {
	if input == "" {
		return "", nil
	}

	tmpl, err := template.New("command").Parse(input)
	if err != nil {
		return "", fmt.Errorf("failed to parse template: %w", err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, vars); err != nil {
		return "", fmt.Errorf("failed to execute template: %w", err)
	}

	return buf.String(), nil
}

// ApplyTemplateToCheck applies template variables to a check's command/script args.
func ApplyTemplateToCheck(check *Check, vars TemplateVars) (*Check, error) {
	// Create a copy to avoid modifying the original
	result := *check

	// Apply template to command
	if result.Command != "" {
		cmd, err := ApplyTemplate(result.Command, vars)
		if err != nil {
			return nil, fmt.Errorf("failed to apply template to command: %w", err)
		}
		result.Command = cmd
	}

	// Apply template to script args
	if result.Script != nil {
		scriptCopy := *result.Script
		if len(scriptCopy.Args) > 0 {
			args := make([]string, len(scriptCopy.Args))
			for i, arg := range scriptCopy.Args {
				rendered, err := ApplyTemplate(arg, vars)
				if err != nil {
					return nil, fmt.Errorf("failed to apply template to script arg %d: %w", i, err)
				}
				args[i] = rendered
			}
			scriptCopy.Args = args
		}
		result.Script = &scriptCopy
	}

	return &result, nil
}
