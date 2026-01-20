#!/usr/bin/env bash
# Check for Kyverno policies affecting Gateway resources
#
# Exit codes:
#   0 - PASS: No blocking Kyverno policies found
#   3 - SKIP: No Kyverno policies affecting Gateway
#   4 - WARN: Found policies that might affect Gateway (informational)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "Kyverno Gateway Policies Check"

# Check if Kyverno CRDs exist
if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
    print_skip "Kyverno not installed"
    exit "${EXIT_SKIP}"
fi

# Get policies that match Gateway resources
GW_POLICIES=$(kubectl_json get clusterpolicy | jq '[.items[] | select(.spec.rules[].match.any[].resources.kinds | contains(["Gateway"]))]')
GW_POLICY_COUNT=$(echo "${GW_POLICIES}" | jq 'length')

if [[ "${GW_POLICY_COUNT}" -eq 0 ]]; then
    print_ok "No Kyverno policies affecting Gateway resources"
    exit "${EXIT_SUCCESS}"
fi

print_warn "Found ${GW_POLICY_COUNT} Kyverno policy(ies) affecting Gateway resources"
echo ""

for POL in $(echo "${GW_POLICIES}" | jq -r '.[] | @base64'); do
    NAME=$(echo "${POL}" | base64 -d | jq -r '.metadata.name')
    ACTION=$(echo "${POL}" | base64 -d | jq -r '.spec.validationFailureAction')
    echo "  - ${NAME} (action: ${ACTION})"
done

echo ""
echo "If Gateways aren't being created, check if these policies are blocking them."
echo "Run: kubectl get policyreport -A | grep -i gateway"

# Return WARN since this is informational
exit "${EXIT_WARN}"
