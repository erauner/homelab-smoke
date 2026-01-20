// Package validate provides output validation for smoke test checks.
package validate

import (
	"fmt"
	"regexp"
	"strings"
)

// Validation holds the validation postconditions for a check.
type Validation struct {
	// Contains requires the output to contain this string.
	Contains string `yaml:"contains,omitempty"`

	// NotContains requires the output to NOT contain this string.
	NotContains string `yaml:"not_contains,omitempty"`

	// Regex requires the output to match this regular expression.
	Regex string `yaml:"regex,omitempty"`
}

// Output checks if the output satisfies all validation postconditions.
// Returns a slice of errors for each failed validation.
// An empty slice means all validations passed.
func Output(output string, v *Validation) []error {
	if v == nil {
		return nil
	}

	var errs []error

	// Check contains
	if v.Contains != "" {
		if !strings.Contains(output, v.Contains) {
			errs = append(errs, fmt.Errorf("output missing required text: %q", v.Contains))
		}
	}

	// Check not_contains
	if v.NotContains != "" {
		if strings.Contains(output, v.NotContains) {
			errs = append(errs, fmt.Errorf("output contains forbidden text: %q", v.NotContains))
		}
	}

	// Check regex
	if v.Regex != "" {
		re, err := regexp.Compile(v.Regex)
		if err != nil {
			errs = append(errs, fmt.Errorf("invalid regex %q: %v", v.Regex, err))
		} else if !re.MatchString(output) {
			errs = append(errs, fmt.Errorf("output does not match regex: %q", v.Regex))
		}
	}

	return errs
}

// IsEmpty returns true if no validation postconditions are set.
func (v *Validation) IsEmpty() bool {
	if v == nil {
		return true
	}
	return v.Contains == "" && v.NotContains == "" && v.Regex == ""
}
