#!/usr/bin/env bash
# Check that Envoy LoadBalancer services have IPs assigned
#
# Exit codes:
#   0 - PASS: All services have IPs and correct configuration
#   1 - FAIL: One or more services missing IPs or misconfigured
#   2 - ERROR: kubectl command failed
#   3 - SKIP: No Envoy LoadBalancer services found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "Envoy LoadBalancer Services Check"

# Get Envoy-managed services
ENVOY_SVCS=$(kubectl_json get svc -n envoy-gateway-system -l app.kubernetes.io/managed-by=envoy-gateway)
LB_SVCS=$(echo "${ENVOY_SVCS}" | jq '[.items[] | select(.spec.type=="LoadBalancer")]')
LB_COUNT=$(echo "${LB_SVCS}" | jq 'length')

if [[ "${LB_COUNT}" -eq 0 ]]; then
    print_skip "No Envoy LoadBalancer services found"
    exit "${EXIT_SKIP}"
fi

echo "Found ${LB_COUNT} LoadBalancer service(s)"
echo ""

FAILED=0

for SVC in $(echo "${LB_SVCS}" | jq -r '.[] | @base64'); do
    NAME=$(echo "${SVC}" | base64 -d | jq -r '.metadata.name')
    EXTERNAL_IP=$(echo "${SVC}" | base64 -d | jq -r '.status.loadBalancer.ingress[0].ip // "pending"')
    LB_POOL=$(echo "${SVC}" | base64 -d | jq -r '.metadata.labels["lb-pool"] // "missing"')
    ETP=$(echo "${SVC}" | base64 -d | jq -r '.spec.externalTrafficPolicy // "missing"')

    # Check if IP is assigned
    if [[ "${EXTERNAL_IP}" == "pending" || "${EXTERNAL_IP}" == "null" ]]; then
        print_fail "Service ${NAME}: IP pending"
        echo "    lb-pool: ${LB_POOL}"
        FAILED=$((FAILED + 1))
    else
        print_ok "Service ${NAME}: ${EXTERNAL_IP}"
    fi

    # Check lb-pool label
    if [[ "${LB_POOL}" == "missing" ]]; then
        print_warn "  Missing lb-pool label"
    fi

    # Check externalTrafficPolicy
    if [[ "${ETP}" != "Local" ]]; then
        print_warn "  externalTrafficPolicy=${ETP} (should be Local)"
    fi
done

echo ""
if [[ "${FAILED}" -gt 0 ]]; then
    echo "${FAILED} service(s) missing IPs"
    exit "${EXIT_FAILURE}"
fi

echo "All LoadBalancer services have IPs"
exit "${EXIT_SUCCESS}"
