#!/usr/bin/env bash
# Check NetworkPolicy allows internal cluster traffic
#
# In Cilium:
#   - ipBlock 0.0.0.0/0 -> reserved:world (external only)
#   - namespaceSelector {} -> all cluster pods
#
# We need BOTH for gateway traffic to work!
#
# Exit codes:
#   0 - PASS: NetworkPolicy allows internal cluster traffic
#   1 - FAIL: NetworkPolicy missing internal traffic rule
#   2 - ERROR: kubectl command failed
#   3 - SKIP: No Envoy NetworkPolicy found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "NetworkPolicy Internal Traffic Check"

# Get Envoy NetworkPolicies
ENVOY_NP=$(kubectl_json get networkpolicy -n envoy-gateway-system -l app.kubernetes.io/name=envoy-proxy-networkpolicy)
NP_COUNT=$(json_count "${ENVOY_NP}")

if [[ "${NP_COUNT}" -eq 0 ]]; then
    print_warn "No Envoy NetworkPolicy found (traffic is unrestricted)"
    exit "${EXIT_SKIP}"
fi

FAILED=0

for NP in $(echo "${ENVOY_NP}" | jq -r '.items[] | @base64'); do
    NAME=$(echo "${NP}" | base64 -d | jq -r '.metadata.name')

    # Check if internal cluster traffic is allowed (namespaceSelector: {})
    HAS_INTERNAL_ALLOW=$(echo "${NP}" | base64 -d | jq '[.spec.ingress[].from[]? | select(.namespaceSelector != null and (.namespaceSelector | keys | length == 0))] | length > 0')

    # Check if only using ipBlock (no namespaceSelector)
    HAS_ONLY_IPBLOCK=$(echo "${NP}" | base64 -d | jq '[.spec.ingress[] | select(.ports[].port == 10080 or .ports[].port == 10443)] | .[0].from | all(.ipBlock != null)' 2>/dev/null || echo "false")

    if [[ "${HAS_ONLY_IPBLOCK}" == "true" && "${HAS_INTERNAL_ALLOW}" != "true" ]]; then
        print_fail "NetworkPolicy ${NAME} missing internal cluster traffic rule"
        echo "    ipBlock 0.0.0.0/0 only matches EXTERNAL traffic in Cilium"
        echo "    Internal pod-to-pod traffic requires: namespaceSelector: {}"
        echo "    Fix: Add 'namespaceSelector: {}' to ingress.from[] for gateway ports"
        FAILED=$((FAILED + 1))
    elif [[ "${HAS_INTERNAL_ALLOW}" == "true" ]]; then
        print_ok "NetworkPolicy ${NAME} allows internal cluster traffic"
    else
        print_warn "NetworkPolicy ${NAME} has non-standard ingress configuration"
    fi
done

echo ""
if [[ "${FAILED}" -gt 0 ]]; then
    echo "${FAILED} NetworkPolicy(ies) missing internal traffic rules"
    exit "${EXIT_FAILURE}"
fi

exit "${EXIT_SUCCESS}"
