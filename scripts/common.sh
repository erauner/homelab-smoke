#!/usr/bin/env bash
# Common functions for smoke test scripts
#
# Source this file in your scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"

# Exit codes (contract)
export EXIT_SUCCESS=0  # PASS
export EXIT_FAILURE=1  # FAIL
export EXIT_ERROR=2    # ERROR
export EXIT_SKIP=3     # SKIP
export EXIT_WARN=4     # WARN

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export GRAY='\033[0;90m'
export NC='\033[0m' # No Color

# Print a header for the check
print_header() {
    local title="$1"
    echo "=== ${title} ==="
}

# Print a summary line
print_summary_line() {
    local label="$1"
    local value="$2"
    printf "  %-15s %s\n" "${label}:" "${value}"
}

# Print a separator
print_separator() {
    echo "----------------------------------------"
}

# Print OK status
print_ok() {
    local msg="$1"
    echo -e "${GREEN}✓${NC} ${msg}"
}

# Print FAIL status
print_fail() {
    local msg="$1"
    echo -e "${RED}✗${NC} ${msg}"
}

# Print WARN status
print_warn() {
    local msg="$1"
    echo -e "${YELLOW}!${NC} ${msg}"
}

# Print SKIP status
print_skip() {
    local msg="$1"
    echo -e "${GRAY}⊘${NC} ${msg}"
}

# Check if a kubectl context exists
context_exists() {
    local context="$1"
    kubectl config get-contexts -o name 2>/dev/null | grep -q "^${context}$"
}

# Check if a kubernetes resource exists
k8s_resource_exists() {
    local kind="$1"
    local name="$2"
    local namespace="$3"
    local context="${4:-}"

    local cmd="kubectl get ${kind} ${name}"
    [[ -n "${namespace}" ]] && cmd="${cmd} -n ${namespace}"
    [[ -n "${context}" ]] && cmd="${cmd} --context ${context}"

    ${cmd} >/dev/null 2>&1
}

# Get JSON output from kubectl
kubectl_json() {
    local args=("$@")
    kubectl "${args[@]}" -o json 2>/dev/null || echo '{"items":[]}'
}

# Count items in a JSON array
json_count() {
    local json="$1"
    echo "${json}" | jq '.items | length' 2>/dev/null || echo 0
}

# Retry a command with exponential backoff
retry_cmd() {
    local max_attempts="${1:-3}"
    local delay="${2:-2}"
    shift 2
    local cmd=("$@")

    local attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if "${cmd[@]}"; then
            return 0
        fi

        if [[ ${attempt} -lt ${max_attempts} ]]; then
            echo "  Retry ${attempt}/${max_attempts} in ${delay}s..."
            sleep "${delay}"
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    return 1
}
