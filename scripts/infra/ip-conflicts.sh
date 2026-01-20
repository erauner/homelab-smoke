#!/usr/bin/env bash
# Check for IP conflicts across LoadBalancer services
#
# Exit codes:
#   0 - PASS: No IP conflicts detected
#   1 - FAIL: Duplicate IP assignments found
#   2 - ERROR: kubectl command failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "IP Conflict Check"

# Get all LoadBalancer services
ALL_LB_SVCS=$(kubectl_json get svc -A | jq '[.items[] | select(.spec.type=="LoadBalancer")]')

# Extract requested IPs from annotations
REQUESTED_IPS=$(echo "${ALL_LB_SVCS}" | jq -r '.[].metadata.annotations["lbipam.cilium.io/ips"] // empty' | sort)
DUPLICATES=$(echo "${REQUESTED_IPS}" | uniq -d)

if [[ -n "${DUPLICATES}" ]]; then
    print_fail "IP conflicts detected"
    echo ""

    for IP in ${DUPLICATES}; do
        echo "IP ${IP} requested by multiple services:"
        echo "${ALL_LB_SVCS}" | jq -r ".[] | select(.metadata.annotations[\"lbipam.cilium.io/ips\"] == \"${IP}\") | \"  - \\(.metadata.namespace)/\\(.metadata.name)\""
    done

    exit "${EXIT_FAILURE}"
fi

print_ok "No IP conflicts detected"
exit "${EXIT_SUCCESS}"
