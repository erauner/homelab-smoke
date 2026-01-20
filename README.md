# Homelab Smoke Test Framework

Declarative smoke test framework for validating Kubernetes cluster health.

This repository contains the **framework** (Go CLI + runner). Cluster-specific tests live in the consuming repository (e.g., [homelab-k8s/smoke/](https://github.com/erauner12/homelab-k8s/tree/master/smoke)).

## Architecture

```
Pattern:
  homelab-smoke/          # This repo: Generic framework (reusable)
  homelab-k8s/smoke/      # Cluster-specific tests (checks.yaml + scripts)
```

This follows the same pattern as:
- `kyverno` CLI + `policies/kyverno/` tests
- `promtool` CLI + `alerts/` rules

## Installation

### Container Image (Recommended)

```bash
# Pull from registry
docker pull docker.nexus.erauner.dev/homelab/smoke:latest

# Run with external checks directory
docker run --rm \
    -v ~/.kube:/root/.kube:ro \
    -v /path/to/smoke:/checks:ro \
    docker.nexus.erauner.dev/homelab/smoke:latest \
    --checks=/checks/checks.yaml \
    --cluster=home \
    --context=home-admin
```

### Build from Source

```bash
go install github.com/erauner/homelab-smoke/cmd/smoke@latest
```

### Go Install

```bash
go install github.com/erauner/homelab-smoke/cmd/smoke@latest
```

## Usage

```bash
# Auto-discover checks.yaml (looks in ./checks.yaml, ./smoke/checks.yaml)
smoke --cluster=home --context=home-admin

# Explicit checks file
smoke --checks=/path/to/checks.yaml --cluster=home

# List configured checks
smoke --list-checks

# Verbose output
smoke -v
```

## CLI Options

```
-checks          Path to checks YAML file (auto-discovers if not set)
-cluster         Cluster name for template variables (default: home)
-namespace       Kubernetes namespace for template variables
-context         kubectl context for template variables
-timeout         Default timeout for checks (default: 30s)
-retries         Maximum retries for failing checks (default: 3)
-retry-delay     Delay between retries (default: 2s)
-v               Verbose output (show all check output)
-list-checks     List configured checks and exit
-version         Print version information and exit
```

## How It Works

1. **checks.yaml** - Declarative list of checks with commands/scripts
2. **Go Runner** - Executes checks with retry, timeout, and validation
3. **Bash Scripts** - Individual check implementations following exit code contract
4. **Layer-based Ordering** - Fail fast at infrastructure layer before checking apps

## Exit Code Contract

Scripts must return one of these exit codes:

| Code | Outcome | Meaning | Blocks Rollout |
|------|---------|---------|----------------|
| 0 | PASS | Check succeeded | Never |
| 1 | FAIL | Check failed | If gating=true |
| 2 | ERROR | Script/tool error | Always |
| 3 | SKIP | Not applicable | Never |
| 4 | WARN | Warning (non-ideal) | Never |

**Key points:**
- `expect.gating` only affects **FAIL**. ERROR always blocks; WARN/SKIP never block.
- Scripts should return **0–4**. Any other exit code is treated as **ERROR**.
- `validate` postconditions run only when the exit code is **0**.

## Check Configuration

Checks are defined in `checks.yaml`:

```yaml
checks:
  - name: "Gateway Resources Programmed"
    description: "Verify all Gateway resources are programmed"
    layer: 1
    script:
      path: "./scripts/infra/gateway-programmed.sh"
    expect:
      gating: true
    retry: true
    timeout: 30s
    validate:
      contains: "Programmed"
```

### Fields

- **name**: Display name for the check
- **description**: Optional description
- **layer**: Execution order (lower = earlier, fail fast)
- **command**: Inline shell command (alternative to script)
- **script**: External script with path and args
- **expect.gating**: Whether check blocks rollouts on FAIL (default: true)
- **retry**: Enable retry on failure (default: false)
- **timeout**: Per-check timeout override (e.g., "45s")
- **validate**: Output validation postconditions
  - `contains`: Text that must appear in output
  - `not_contains`: Text that must NOT appear in output
  - `regex`: Regular expression to match

### Template Variables

Use these in commands and script args:

- `{{.Cluster}}` - Cluster name (e.g., "home")
- `{{.Namespace}}` - Kubernetes namespace
- `{{.Context}}` - kubectl context

## CLI Exit Codes

- **0**: All checks passed (or only non-gating failures)
- **1**: One or more gating checks failed
- **2**: Error (tool error or ERROR outcome)

## Writing Checks

See [GUIDELINES.md](GUIDELINES.md) for detailed guidance on writing smoke test scripts.

## Directory Structure

```
homelab-smoke/
├── cmd/smoke/
│   └── main.go           # CLI entry point
├── pkg/
│   ├── engine/           # Outcome classification
│   ├── exec/             # Command execution
│   ├── validate/         # Output postconditions
│   ├── config/           # YAML config loader
│   └── runner/           # Check orchestration
├── Dockerfile            # Container image build
├── Jenkinsfile           # CI/CD pipeline
├── GUIDELINES.md         # Check authoring guide
└── README.md
```

## CI/CD

This repo uses Jenkins for CI:
- **On push to main**: Builds and pushes container image, creates pre-release tag (vX.Y.Z-rc.N)
- **Image registry**: `docker.nexus.erauner.dev/homelab/smoke`

## Security Considerations

**Trust Model**: This tool assumes the `checks.yaml` configuration file is trusted. Commands and scripts are executed via `sh -c` with template variable substitution. Do not load configuration files from untrusted sources.

**Permissions**: Checks use `kubectl` which requires appropriate cluster credentials. Ensure the tool runs with least-privilege service account credentials in CI/CD pipelines.

## Related

- [homelab-k8s/smoke/](https://github.com/erauner12/homelab-k8s/tree/master/smoke) - Example cluster-specific tests
- [Issue #1283](https://github.com/erauner12/homelab-k8s/issues/1283) - Framework/tests separation

## License

MIT
