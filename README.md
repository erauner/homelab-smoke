# Homelab Smoke Tests

Declarative smoke test framework for validating homelab cluster health.

Checks are defined in `checks.yaml` and run as shell commands or scripts with template variables. Each check reports one of: **PASS**, **FAIL**, **WARN**, **SKIP**, or **ERROR**.

## Installation

### Container Image (Recommended)

```bash
# Pull from registry
docker pull docker.nexus.erauner.dev/homelab/smoke:latest

# Run with kubeconfig mounted
docker run -v ~/.kube:/home/smoke/.kube:ro \
    docker.nexus.erauner.dev/homelab/smoke:latest \
    -cluster=home -context=home-admin
```

### Build from Source

```bash
# Clone and build
git clone https://github.com/erauner/homelab-smoke.git
cd homelab-smoke
go build -o smoke ./cmd/smoke

# Run smoke tests
./smoke -cluster=home -context=home-admin
```

## Quick Start

```bash
# Run smoke tests
./smoke -cluster=home -context=home-admin

# List configured checks
./smoke -list-checks

# Verbose output (show all check output)
./smoke -v
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

## CLI Options

```
-checks          Path to checks YAML file (default: checks.yaml)
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

## Check Layers

Checks are organized by dependency hierarchy (fail fast at lower layers):

| Layer | Category | Examples |
|-------|----------|----------|
| 1 | Gateway Infrastructure | Gateway programmed, LoadBalancer IPs |
| 2 | Network Policies | Correct ports, internal traffic allowed |
| 3 | Core Services | ArgoCD, DNS connectivity |
| 4 | Observability | Grafana, Prometheus |
| 5 | Application Services | Jenkins, other apps |

## Adding a New Check

### Option 1: Inline Command

```yaml
- name: "Pod Count"
  command: kubectl get pods -n my-namespace --no-headers | wc -l
  validate:
    regex: '^[1-9][0-9]*$'  # At least 1 pod
```

### Option 2: External Script

1. Create script in `scripts/`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "My Custom Check"

# Your check logic here
if some_condition; then
    print_ok "Check passed"
    exit "${EXIT_SUCCESS}"
else
    print_fail "Check failed"
    exit "${EXIT_FAILURE}"
fi
```

2. Add to `checks.yaml`:

```yaml
- name: "My Custom Check"
  script:
    path: "./scripts/my-check.sh"
    args:
      - "{{.Namespace}}"
  expect:
    gating: true
```

Use `scripts/template.sh` as a starting point.

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
├── scripts/
│   ├── common.sh         # Shared functions
│   ├── template.sh       # Template for new checks
│   ├── utils/
│   │   └── httpcheck     # HTTP endpoint testing
│   └── infra/
│       ├── gateway-programmed.sh
│       ├── loadbalancer-ips.sh
│       └── ...
├── checks.yaml           # Check definitions
├── Dockerfile            # Container image build
├── Jenkinsfile           # CI/CD pipeline
└── README.md
```

## CI/CD

This repo uses Jenkins for CI:
- **On push to main**: Builds and pushes container image, creates pre-release tag (vX.Y.Z-rc.N)
- **Image registry**: `docker.nexus.erauner.dev/homelab/smoke`

## CLI Exit Codes

- **0**: All checks passed (or only non-gating failures)
- **1**: One or more gating checks failed
- **2**: Error (tool error or ERROR outcome)

## Security Considerations

**Trust Model**: This tool assumes the `checks.yaml` configuration file is trusted. Commands and scripts are executed via `sh -c` with template variable substitution. Do not load configuration files from untrusted sources.

**Network Access**: Some checks make HTTP requests to verify service availability. The `httpcheck` script uses `curl -k` to accept self-signed certificates, which is appropriate for homelab environments.

**Permissions**: Checks use `kubectl` which requires appropriate cluster credentials. Ensure the tool runs with least-privilege service account credentials in CI/CD pipelines.

## License

MIT
