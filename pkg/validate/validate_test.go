package validate

import (
	"testing"
)

func TestOutput(t *testing.T) {
	tests := []struct {
		name       string
		output     string
		validation *Validation
		wantErrs   int
	}{
		{
			name:       "nil validation",
			output:     "any output",
			validation: nil,
			wantErrs:   0,
		},
		{
			name:       "contains - pass",
			output:     "hello world",
			validation: &Validation{Contains: "world"},
			wantErrs:   0,
		},
		{
			name:       "contains - fail",
			output:     "hello world",
			validation: &Validation{Contains: "foo"},
			wantErrs:   1,
		},
		{
			name:       "not_contains - pass",
			output:     "hello world",
			validation: &Validation{NotContains: "foo"},
			wantErrs:   0,
		},
		{
			name:       "not_contains - fail",
			output:     "hello world",
			validation: &Validation{NotContains: "world"},
			wantErrs:   1,
		},
		{
			name:       "regex - pass",
			output:     "HTTP 200 OK",
			validation: &Validation{Regex: `^HTTP [23][0-9]{2}`},
			wantErrs:   0,
		},
		{
			name:       "regex - fail",
			output:     "HTTP 500 Error",
			validation: &Validation{Regex: `^HTTP [23][0-9]{2}`},
			wantErrs:   1,
		},
		{
			name:       "invalid regex",
			output:     "any output",
			validation: &Validation{Regex: "[invalid"},
			wantErrs:   1,
		},
		{
			name:   "multiple validations - all pass",
			output: "HTTP 200 - success",
			validation: &Validation{
				Contains:    "success",
				NotContains: "error",
				Regex:       `HTTP [0-9]+`,
			},
			wantErrs: 0,
		},
		{
			name:   "multiple validations - some fail",
			output: "HTTP 500 - error",
			validation: &Validation{
				Contains:    "success", // fails
				NotContains: "error",   // fails
				Regex:       `HTTP [0-9]+`,
			},
			wantErrs: 2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			errs := Output(tt.output, tt.validation)
			if len(errs) != tt.wantErrs {
				t.Errorf("expected %d errors, got %d: %v", tt.wantErrs, len(errs), errs)
			}
		})
	}
}

func TestValidationIsEmpty(t *testing.T) {
	tests := []struct {
		name       string
		validation *Validation
		expected   bool
	}{
		{
			name:       "nil",
			validation: nil,
			expected:   true,
		},
		{
			name:       "empty struct",
			validation: &Validation{},
			expected:   true,
		},
		{
			name:       "has contains",
			validation: &Validation{Contains: "foo"},
			expected:   false,
		},
		{
			name:       "has not_contains",
			validation: &Validation{NotContains: "foo"},
			expected:   false,
		},
		{
			name:       "has regex",
			validation: &Validation{Regex: ".*"},
			expected:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := tt.validation.IsEmpty()
			if result != tt.expected {
				t.Errorf("expected %v, got %v", tt.expected, result)
			}
		})
	}
}
