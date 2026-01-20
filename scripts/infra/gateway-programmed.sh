#!/usr/bin/env bash
# Check that all Gateway resources are programmed
#
# Exit codes:
#   0 - PASS: All gateways are programmed with addresses
#   1 - FAIL: One or more gateways are not programmed
#   2 - ERROR: kubectl command failed
#   3 - SKIP: No Gateway resources found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "Gateway Resources Check"

# Get all gateways
GATEWAYS=$(kubectl_json get gateway -A)
GW_COUNT=$(json_count "${GATEWAYS}")

if [[ "${GW_COUNT}" -eq 0 ]]; then
    print_skip "No Gateway resources found"
    exit "${EXIT_SKIP}"
fi

echo "Found ${GW_COUNT} Gateway resource(s)"
echo ""

FAILED=0

for GW in $(echo "${GATEWAYS}" | jq -r '.items[] | @base64'); do
    NAME=$(echo "${GW}" | base64 -d | jq -r '.metadata.name')
    NS=$(echo "${GW}" | base64 -d | jq -r '.metadata.namespace')
    PROGRAMMED=$(echo "${GW}" | base64 -d | jq -r '.status.conditions[] | select(.type=="Programmed") | .status' 2>/dev/null || echo "Unknown")
    ADDRESS=$(echo "${GW}" | base64 -d | jq -r '.status.addresses[0].value // "none"' 2>/dev/null || echo "none")

    if [[ "${PROGRAMMED}" == "True" ]]; then
        print_ok "Gateway ${NS}/${NAME}: Programmed (IP: ${ADDRESS})"
    else
        MESSAGE=$(echo "${GW}" | base64 -d | jq -r '.status.conditions[] | select(.type=="Programmed") | .message' 2>/dev/null || echo "Unknown")
        print_fail "Gateway ${NS}/${NAME}: NOT Programmed"
        echo "    Reason: ${MESSAGE}"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [[ "${FAILED}" -gt 0 ]]; then
    echo "${FAILED} Gateway(s) not programmed"
    exit "${EXIT_FAILURE}"
fi

echo "All Gateways programmed successfully"
exit "${EXIT_SUCCESS}"
