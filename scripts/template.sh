#!/usr/bin/env bash
# Template Smoke Check Script
#
# This is a template for creating new smoke test checks.
# Copy this file and customize for your specific check.
#
# Exit Code Contract:
#   0 - PASS: Check succeeded
#   1 - FAIL: Check failed (gating by default)
#   2 - ERROR: Script/tool error (always blocks)
#   3 - SKIP: Not applicable for this environment
#   4 - WARN: Warning (non-blocking)
#
# Usage: ./my-check.sh [ARGS...]

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# Configuration
# ============================================================

# Script metadata (for documentation)
SCRIPT_NAME="Template Check"
SCRIPT_DESCRIPTION="Template for creating new checks"

# ============================================================
# Argument handling
# ============================================================

if [[ $# -lt 1 ]]; then  # TODO: Adjust required arg count as needed
    cat >&2 << EOF
Usage: ${0##*/} [ARGS...]

${SCRIPT_DESCRIPTION}

Arguments:
  ARG1    Description of argument 1

Exit codes:
  0 - PASS: Check succeeded
  1 - FAIL: Check failed
  2 - ERROR: Script error
  3 - SKIP: Not applicable
  4 - WARN: Warning

Examples:
  ${0##*/} example-arg

EOF
    exit "${EXIT_ERROR}"
fi

# ============================================================
# Main Logic
# ============================================================

print_header "${SCRIPT_NAME}"

# Example: Check if a resource exists
# if ! k8s_resource_exists "deployment" "my-deployment" "my-namespace"; then
#     print_skip "Deployment not found - not applicable"
#     exit "${EXIT_SKIP}"
# fi

# Example: Get resource status
# STATUS=$(kubectl get deployment my-deployment -n my-namespace -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

# Example: Validate status
# if [[ "${STATUS}" -lt 1 ]]; then
#     print_fail "No ready replicas"
#     exit "${EXIT_FAILURE}"
# fi

# Example: Success
print_ok "All checks passed"
exit "${EXIT_SUCCESS}"
