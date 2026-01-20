# Smoke Test Guidelines

## What is a Smoke Test?

A smoke test answers one question: **"Is the system fundamentally working?"**

Smoke tests are quick, lightweight checks that verify critical infrastructure is operational.
They run after deployments to catch catastrophic failures before they impact users.

### Characteristics of Good Smoke Tests

| Characteristic | Description |
|----------------|-------------|
| **Fast** | Completes in seconds, not minutes. Target: <5s per check, <60s total |
| **Non-destructive** | Read-only. Never modifies state or creates resources |
| **Deterministic** | Same environment = same result. No flaky tests |
| **Independent** | No dependencies between checks (except layer ordering) |
| **Binary outcome** | Clear pass/fail. Avoid "it depends" situations |
| **Minimal dependencies** | Uses kubectl, curl, basic tools. No special setup |
| **Actionable** | Failure points to a specific problem to investigate |

### What Smoke Tests Are NOT

| Anti-pattern | Why It Doesn't Belong |
|--------------|----------------------|
| **Integration tests** | Testing complex multi-step workflows belongs in CI |
| **Load tests** | Stress testing is a separate concern |
| **Feature tests** | Validating business logic belongs in application tests |
| **Configuration audits** | "Is this configured optimally?" is different from "is it working?" |
| **Remediation scripts** | Scripts that fix problems don't belong here |
| **Long-running monitors** | Smoke tests are point-in-time, not continuous |
| **Comprehensive validation** | We test critical paths, not every endpoint |

## The Smoke Test Pyramid

```
Layer 1: Infrastructure Foundation
         └─ Gateway, LoadBalancer, Network basics
         └─ If these fail, nothing else matters

Layer 2: Network Policies
         └─ Traffic can flow between components

Layer 3: Core Services
         └─ ArgoCD, DNS resolution, authentication

Layer 4: Observability
         └─ Grafana, Prometheus, logging

Layer 5: Applications
         └─ User-facing services respond

Layer 6: Policy Enforcement
         └─ Kyverno, admission controllers
```

**Fail-fast principle**: Lower layers run first. If Layer 1 fails, don't bother checking Layer 5.

## Guidelines for Writing Checks

### DO

```yaml
# Good: Simple, fast, clear outcome
- name: "Gateway Has IP"
  script:
    path: "./scripts/infra/gateway-ip.sh"
  expect:
    gating: true
```

- Test ONE thing per check
- Use descriptive names that explain what's being verified
- Return appropriate exit codes (see Exit Code Contract)
- Print minimal, actionable output on failure
- Keep scripts under 50 lines when possible

### DON'T

```yaml
# Bad: Too broad, slow, unclear outcome
- name: "Full System Health Check"
  command: "./scripts/check-everything.sh"
  timeout: 5m
```

- Don't test multiple unrelated things in one check
- Don't make network calls to external services (flaky)
- Don't require authentication tokens or secrets
- Don't parse complex output formats when simple checks suffice
- Don't add checks "just in case" - each check should prevent a real failure mode

## Exit Code Contract

| Code | Meaning | Behavior |
|------|---------|----------|
| 0 | **PASS** | Check succeeded |
| 1 | **FAIL** | Check failed (blocks if gating) |
| 2 | **ERROR** | Script/tool error (always blocks) |
| 3 | **SKIP** | Not applicable for this environment |
| 4 | **WARN** | Warning (never blocks) |

### When to Use Each

- **PASS (0)**: The thing you're checking is working correctly
- **FAIL (1)**: The thing you're checking is broken and needs attention
- **ERROR (2)**: The check itself couldn't run (missing tool, permission denied)
- **SKIP (3)**: Check doesn't apply (e.g., checking internal service from external network)
- **WARN (4)**: Something is degraded but functional (e.g., 1 of 3 replicas down)

## Gating vs Non-Gating

**Gating checks** (`gating: true`) block deployments on failure:
- Infrastructure fundamentals (Gateway, LoadBalancer)
- Network connectivity
- Core services (ArgoCD, DNS)

**Non-gating checks** (`gating: false`) log warnings but don't block:
- Nice-to-have services
- Services with known intermittent issues
- Checks that may fail from certain network locations

## Evaluating Existing Scripts

When considering whether to adapt an existing script into a smoke test, ask:

1. **Does it answer "is X working?" in under 5 seconds?**
   - Yes → Good candidate
   - No → Probably not a smoke test

2. **Is the outcome binary (working/not working)?**
   - Yes → Good candidate
   - "It's complicated" → Not a smoke test

3. **Does failure indicate something is actually broken?**
   - Yes → Good candidate
   - "It's just a warning" → Use WARN exit code or skip

4. **Would you want this blocking a 3am deployment?**
   - Yes → Gating smoke test
   - No → Non-gating or not a smoke test

### Examples from Existing Scripts

| Script | Smoke Test? | Reasoning |
|--------|-------------|-----------|
| `check-envoy-gateway-health.sh` | ✅ Decomposed | Core infrastructure checks |
| `dns-status.sh --verify` | ⚠️ Partial | DNS resolution is critical, but full audit is too slow |
| `lb-status.sh` | ⚠️ Partial | "Has IPs" is smoke test, "pool capacity" is monitoring |
| `prom-query.sh` | ❌ No | Query utility, not a health check |
| `fix-ssa-errors.sh` | ❌ No | Remediation, not detection |
| `unifi-config-check.sh` | ❌ No | Configuration audit, not operational check |

## Adding New Checks

Before adding a check, answer:

1. What failure mode does this catch?
2. Has this failure actually happened before?
3. Would catching it earlier have prevented an outage?
4. Can this be checked in under 5 seconds?
5. Is the check deterministic and non-flaky?

If you answered "yes" to all five, add the check. Otherwise, consider:
- Is this better as a Prometheus alert?
- Is this better as a CI validation?
- Is this better as a periodic audit script?
