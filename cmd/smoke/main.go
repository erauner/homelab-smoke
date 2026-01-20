// Package main provides the CLI entry point for the smoke test runner.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/erauner/homelab-go-utils/formatting"
	"github.com/erauner/homelab-smoke/pkg/config"
	"github.com/erauner/homelab-smoke/pkg/runner"
)

var (
	version = "dev"
	commit  = "unknown"
	date    = "unknown"
)

func main() {
	// Define flags
	checksFile := flag.String("checks", "", "Path to checks YAML file (default: checks.yaml in same dir as binary)")
	cluster := flag.String("cluster", "home", "Cluster name for template variables")
	namespace := flag.String("namespace", "", "Kubernetes namespace for template variables")
	kubeContext := flag.String("context", "", "kubectl context for template variables")
	timeout := flag.Duration("timeout", 30*time.Second, "Default timeout for checks")
	maxRetries := flag.Int("retries", 3, "Maximum retries for failing checks")
	retryDelay := flag.Duration("retry-delay", 2*time.Second, "Delay between retries")
	verbose := flag.Bool("v", false, "Verbose output (show all check output)")
	listChecks := flag.Bool("list-checks", false, "List configured checks and exit")
	showVersion := flag.Bool("version", false, "Print version information and exit")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Homelab Smoke Test Runner\n\n")
		fmt.Fprintf(os.Stderr, "Usage: %s [options]\n\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nTemplate Variables:\n")
		fmt.Fprintf(os.Stderr, "  {{.Cluster}}    - Cluster name (e.g., \"home\")\n")
		fmt.Fprintf(os.Stderr, "  {{.Namespace}}  - Kubernetes namespace\n")
		fmt.Fprintf(os.Stderr, "  {{.Context}}    - kubectl context\n")
		fmt.Fprintf(os.Stderr, "\nExit Codes:\n")
		fmt.Fprintf(os.Stderr, "  0  All checks passed (or non-gating failures only)\n")
		fmt.Fprintf(os.Stderr, "  1  One or more gating checks failed\n")
		fmt.Fprintf(os.Stderr, "  2  Error (resolution error, tool error, or ERROR outcome)\n")
		fmt.Fprintf(os.Stderr, "\nExamples:\n")
		fmt.Fprintf(os.Stderr, "  %s -cluster=home -context=home-admin\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s -checks=custom-checks.yaml -v\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s -list-checks\n", os.Args[0])
	}

	flag.Parse()

	// Handle version flag
	if *showVersion {
		fmt.Printf("smoke %s (commit: %s, built: %s)\n", version, commit, date)
		os.Exit(0)
	}

	// Find checks file
	checksPath := *checksFile
	if checksPath == "" {
		checksPath = findChecksFile()
		if checksPath == "" {
			fmt.Fprintf(os.Stderr, "Error: checks.yaml not found\n")
			fmt.Fprintf(os.Stderr, "Tried: ./checks.yaml, tools/smoke/checks.yaml\n")
			os.Exit(2)
		}
	}

	// Load configuration
	cfg, err := config.LoadConfig(checksPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading config: %v\n", err)
		os.Exit(2)
	}

	// Validate configuration
	if err := cfg.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "Invalid config: %v\n", err)
		os.Exit(2)
	}

	// Handle list-checks flag
	if *listChecks {
		listConfiguredChecks(cfg)
		os.Exit(0)
	}

	// Determine checks directory
	checksDir := filepath.Dir(checksPath)

	// Build template variables
	vars := config.TemplateVars{
		Cluster:   *cluster,
		Namespace: *namespace,
		Context:   *kubeContext,
	}

	// Print header
	fmt.Printf("Homelab Smoke Tests\n")
	fmt.Printf("  Cluster:   %s\n", vars.Cluster)
	if vars.Namespace != "" {
		fmt.Printf("  Namespace: %s\n", vars.Namespace)
	}
	if vars.Context != "" {
		fmt.Printf("  Context:   %s\n", vars.Context)
	}
	fmt.Printf("  Checks:    %d\n\n", len(cfg.Checks))

	// Create runner
	r := runner.NewRunner(cfg, checksDir, vars)
	r.DefaultTimeout = *timeout
	r.MaxRetries = *maxRetries
	r.RetryDelay = *retryDelay
	r.Verbose = *verbose

	// Set up context with signal handling
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		fmt.Println("\nInterrupted - stopping...")
		cancel()
	}()

	// Run checks with timing
	startTime := time.Now()
	result := r.Run(ctx)
	totalDuration := time.Since(startTime)

	// Print summary with duration
	r.PrintSummary(result, formatting.Duration(totalDuration))

	// Exit with appropriate code
	os.Exit(result.ExitCode())
}

// findChecksFile looks for checks.yaml in common locations.
func findChecksFile() string {
	candidates := []string{
		"checks.yaml",
		"tools/smoke/checks.yaml",
	}

	for _, path := range candidates {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}

	return ""
}

// listConfiguredChecks prints all configured checks.
func listConfiguredChecks(cfg *config.Config) {
	fmt.Printf("Configured Checks (%d total):\n\n", len(cfg.Checks))

	for i, check := range cfg.Checks {
		gating := "gating"
		if !check.IsGating() {
			gating = "non-gating"
		}

		layerStr := ""
		if check.Layer > 0 {
			layerStr = fmt.Sprintf("[Layer %d] ", check.Layer)
		}

		fmt.Printf("%2d. %s%s (%s)\n", i+1, layerStr, check.Name, gating)

		if check.Description != "" {
			fmt.Printf("    %s\n", check.Description)
		}
	}
}
