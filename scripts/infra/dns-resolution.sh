#!/usr/bin/env bash
# Verify DNS resolution for critical external services
#
# Tests that key external hostnames resolve via public DNS.
# This catches DNS misconfiguration (missing records, NXDOMAIN).
#
# Note: Services behind Cloudflare proxy will resolve to Cloudflare IPs,
# not the gateway IP directly. That's expected and correct.
#
# Exit codes:
#   0 - PASS: All hostnames resolve
#   1 - FAIL: One or more hostnames failed to resolve
#   3 - SKIP: dig command not available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Check dependencies
if ! command -v dig &>/dev/null; then
    echo "dig command not available" >&2
    exit "${EXIT_SKIP}"
fi

# Critical external services to verify (keep this list SHORT - it's a smoke test)
# These are services that MUST be accessible externally
HOSTNAMES=(
    "argocd.erauner.dev"
    "grafana.erauner.dev"
)

# DNS server to use (Cloudflare for external resolution)
DNS_SERVER="1.1.1.1"

failed=0
passed=0

for hostname in "${HOSTNAMES[@]}"; do
    resolved_ip=$(dig +short "${hostname}" @"${DNS_SERVER}" 2>/dev/null | head -1) || true

    if [[ -n "${resolved_ip}" ]]; then
        echo "OK: ${hostname} -> ${resolved_ip}"
        passed=$((passed + 1))
    else
        echo "FAIL: ${hostname} - no DNS record" >&2
        failed=$((failed + 1))
    fi
done

echo ""
echo "${passed} passed, ${failed} failed"

if [[ ${failed} -gt 0 ]]; then
    exit "${EXIT_FAILURE}"
fi

exit "${EXIT_SUCCESS}"
