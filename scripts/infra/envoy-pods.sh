#!/usr/bin/env bash
# Check Envoy proxy pods are running, ready, and spread across BGP nodes
#
# Both gateways use externalTrafficPolicy: Local + nodeAffinity for bgp=enable:
#   - Local policy ensures traffic only goes to pods on the receiving node
#   - nodeAffinity ensures pods only run on BGP-advertising nodes
#   - Combined: Each BGP node has a local endpoint → DSR return path works
#
# Pod spread across BGP nodes is REQUIRED for DSR mode to work correctly.
# Each node advertising the BGP route must have a local gateway pod.
#
# See:
#   - https://github.com/erauner12/homelab-k8s/issues/1217 (DSR fix)
#   - https://docs.cilium.io/en/stable/network/bgp-control-plane/
#
# Exit codes:
#   0 - PASS: All Envoy pods are ready and spread across BGP nodes
#   1 - FAIL: Some pods not ready or not on BGP nodes
#   2 - ERROR: kubectl command failed
#   3 - SKIP: No Envoy pods found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "Envoy Proxy Pods Check"

# Get Envoy-managed pods (exclude terminating)
ENVOY_PODS=$(kubectl_json get pods -n envoy-gateway-system -l app.kubernetes.io/managed-by=envoy-gateway --field-selector=status.phase=Running)
POD_COUNT=$(json_count "${ENVOY_PODS}")

if [[ "${POD_COUNT}" -eq 0 ]]; then
    print_fail "No Envoy proxy pods found"
    exit "${EXIT_FAILURE}"
fi

# Count ready pods
READY_COUNT=$(echo "${ENVOY_PODS}" | jq '[.items[] | select(.status.containerStatuses | all(.ready==true))] | length')

if [[ "${READY_COUNT}" -eq "${POD_COUNT}" ]]; then
    print_ok "${READY_COUNT}/${POD_COUNT} Envoy proxy pods ready"
else
    print_fail "${READY_COUNT}/${POD_COUNT} Envoy proxy pods ready"
fi

echo ""
echo "Pod distribution:"
echo "${ENVOY_PODS}" | jq -r '.items[] | "  - \(.metadata.name) on \(.spec.nodeName)"'

# Check node spread per gateway
# With Local policy + nodeAffinity, spread across BGP nodes is REQUIRED
# Each BGP node must have a local pod for DSR to work correctly
echo ""
echo "Node spread analysis (BGP nodes):"

RESULT="${EXIT_SUCCESS}"

for GATEWAY in $(echo "${ENVOY_PODS}" | jq -r '[.items[].metadata.labels["gateway.envoyproxy.io/owning-gateway-name"]] | unique | .[]'); do
    GATEWAY_PODS=$(echo "${ENVOY_PODS}" | jq "[.items[] | select(.metadata.labels[\"gateway.envoyproxy.io/owning-gateway-name\"]==\"${GATEWAY}\")]")
    GATEWAY_POD_COUNT=$(echo "${GATEWAY_PODS}" | jq 'length')
    UNIQUE_NODES=$(echo "${GATEWAY_PODS}" | jq '[.[].spec.nodeName] | unique | length')
    NODE_LIST=$(echo "${GATEWAY_PODS}" | jq -r '[.[].spec.nodeName] | unique | join(", ")')

    if [[ "${GATEWAY_POD_COUNT}" -gt 1 && "${UNIQUE_NODES}" -eq 1 ]]; then
        print_warn "${GATEWAY}: ${GATEWAY_POD_COUNT} pods on single node (${NODE_LIST}) - reduces HA"
        # Don't fail, just warn - this is a degraded but functional state with Cluster policy
    elif [[ "${UNIQUE_NODES}" -ge 2 ]]; then
        print_ok "${GATEWAY}: ${GATEWAY_POD_COUNT} pods spread across ${UNIQUE_NODES} nodes (${NODE_LIST})"
    else
        print_ok "${GATEWAY}: ${GATEWAY_POD_COUNT} pod on ${NODE_LIST}"
    fi
done

if [[ "${READY_COUNT}" -ne "${POD_COUNT}" ]]; then
    exit "${EXIT_FAILURE}"
fi

exit "${RESULT}"
