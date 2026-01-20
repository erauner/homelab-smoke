#!/usr/bin/env bash
# Verify Envoy Gateway DSR-compatible configuration
#
# This check validates the configuration required for DSR (Direct Server Return)
# mode to work correctly with Cilium BGP:
#
#   1. externalTrafficPolicy: Local (ensures traffic stays on local node)
#   2. nodeAffinity: bgp=enable (ensures pods only on BGP-advertising nodes)
#   3. Pod distribution: one pod per BGP node (guarantees local endpoint)
#
# This configuration pattern is the documented best practice for Cilium BGP + DSR:
#   - Each BGP node advertises the LoadBalancer IP
#   - externalTrafficPolicy: Local ensures traffic only goes to local pods
#   - nodeAffinity ensures pods are scheduled on BGP nodes
#   - Result: 1:1 mapping between advertising nodes and endpoints
#
# See:
#   - https://github.com/erauner12/homelab-k8s/issues/1217 (DSR fix)
#   - https://docs.cilium.io/en/stable/network/bgp-control-plane/
#
# Exit codes:
#   0 - PASS: DSR configuration is correct
#   1 - FAIL: Configuration issue detected
#   2 - ERROR: Script/tool error
#   3 - SKIP: Prerequisites not met

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "Envoy Gateway DSR Configuration Check"

RESULT="${EXIT_SUCCESS}"

# ============================================================
# Check 1: BGP nodes exist
# ============================================================
echo ""
echo "BGP node configuration:"

BGP_NODES=$(kubectl get nodes -l bgp=enable -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
BGP_NODE_COUNT=$(echo "${BGP_NODES}" | wc -w | tr -d ' ')

if [[ "${BGP_NODE_COUNT}" -ge 1 ]]; then
    print_ok "${BGP_NODE_COUNT} nodes with bgp=enable label: ${BGP_NODES}"
else
    print_fail "No nodes found with bgp=enable label"
    RESULT="${EXIT_FAILURE}"
fi

# ============================================================
# Check 2: EnvoyProxy configuration
# ============================================================
echo ""
echo "EnvoyProxy configuration:"

for proxy in envoy-homelab envoy-internal-proxy; do
    if ! kubectl get envoyproxy -n network "${proxy}" &>/dev/null; then
        print_warn "${proxy}: EnvoyProxy resource not found"
        continue
    fi

    # Check externalTrafficPolicy
    POLICY=$(kubectl get envoyproxy -n network "${proxy}" \
        -o jsonpath='{.spec.provider.kubernetes.envoyService.patch.value.spec.externalTrafficPolicy}' 2>/dev/null || echo "not-set")

    if [[ "${POLICY}" == "Local" ]]; then
        print_ok "${proxy}: externalTrafficPolicy=Local"
    else
        print_fail "${proxy}: externalTrafficPolicy=${POLICY} (must be Local for DSR)"
        RESULT="${EXIT_FAILURE}"
    fi

    # Check nodeAffinity for bgp label
    AFFINITY_KEY=$(kubectl get envoyproxy -n network "${proxy}" \
        -o jsonpath='{.spec.provider.kubernetes.envoyDeployment.pod.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key}' 2>/dev/null || echo "")
    AFFINITY_VAL=$(kubectl get envoyproxy -n network "${proxy}" \
        -o jsonpath='{.spec.provider.kubernetes.envoyDeployment.pod.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null || echo "")

    if [[ "${AFFINITY_KEY}" == "bgp" && "${AFFINITY_VAL}" == "enable" ]]; then
        print_ok "${proxy}: nodeAffinity requires bgp=enable"
    else
        print_fail "${proxy}: nodeAffinity not configured for bgp=enable"
        RESULT="${EXIT_FAILURE}"
    fi
done

# ============================================================
# Check 3: Service externalTrafficPolicy (actual runtime config)
# ============================================================
echo ""
echo "LoadBalancer service configuration:"

for gateway in envoy-public envoy-internal; do
    SVC_JSON=$(kubectl get svc -n envoy-gateway-system \
        -l "gateway.envoyproxy.io/owning-gateway-name=${gateway}" \
        -o json 2>/dev/null)

    SVC_COUNT=$(echo "${SVC_JSON}" | jq '.items | length')

    if [[ "${SVC_COUNT}" -eq 0 ]]; then
        print_warn "${gateway}: No LoadBalancer service found"
        continue
    fi

    SVC_NAME=$(echo "${SVC_JSON}" | jq -r '.items[0].metadata.name')
    SVC_POLICY=$(echo "${SVC_JSON}" | jq -r '.items[0].spec.externalTrafficPolicy // "not-set"')

    if [[ "${SVC_POLICY}" == "Local" ]]; then
        print_ok "${gateway} (${SVC_NAME}): externalTrafficPolicy=Local"
    else
        print_fail "${gateway} (${SVC_NAME}): externalTrafficPolicy=${SVC_POLICY} (must be Local)"
        RESULT="${EXIT_FAILURE}"
    fi
done

# ============================================================
# Check 4: Pod distribution on BGP nodes
# ============================================================
echo ""
echo "Pod distribution on BGP nodes:"

for gateway in envoy-public envoy-internal; do
    PODS_JSON=$(kubectl get pods -n envoy-gateway-system \
        -l "gateway.envoyproxy.io/owning-gateway-name=${gateway}" \
        --field-selector=status.phase=Running \
        -o json 2>/dev/null)

    POD_COUNT=$(echo "${PODS_JSON}" | jq '.items | length')

    if [[ "${POD_COUNT}" -eq 0 ]]; then
        print_fail "${gateway}: No running pods found"
        RESULT="${EXIT_FAILURE}"
        continue
    fi

    # Get nodes where pods are running
    POD_NODES=$(echo "${PODS_JSON}" | jq -r '[.items[].spec.nodeName] | unique | .[]')
    UNIQUE_NODE_COUNT=$(echo "${POD_NODES}" | wc -l | tr -d ' ')

    # Check if all pods are on BGP nodes
    NON_BGP_NODES=""
    for node in ${POD_NODES}; do
        HAS_BGP=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.bgp}' 2>/dev/null || echo "")
        if [[ "${HAS_BGP}" != "enable" ]]; then
            NON_BGP_NODES="${NON_BGP_NODES} ${node}"
        fi
    done

    if [[ -n "${NON_BGP_NODES}" ]]; then
        print_fail "${gateway}: Pods on non-BGP nodes:${NON_BGP_NODES}"
        RESULT="${EXIT_FAILURE}"
    else
        print_ok "${gateway}: All ${POD_COUNT} pods on BGP-enabled nodes"
    fi

    # Check spread - should have one pod per BGP node for optimal DSR
    if [[ "${UNIQUE_NODE_COUNT}" -eq "${BGP_NODE_COUNT}" ]]; then
        print_ok "${gateway}: Pods spread across all ${BGP_NODE_COUNT} BGP nodes"
    elif [[ "${UNIQUE_NODE_COUNT}" -lt "${BGP_NODE_COUNT}" ]]; then
        print_warn "${gateway}: Pods on ${UNIQUE_NODE_COUNT}/${BGP_NODE_COUNT} BGP nodes (skew detected)"
    fi
done

# ============================================================
# Summary
# ============================================================
echo ""
if [[ "${RESULT}" -eq "${EXIT_SUCCESS}" ]]; then
    print_ok "DSR configuration is correct"
    echo ""
    echo "Configuration pattern:"
    echo "  - externalTrafficPolicy: Local ensures traffic stays on local node"
    echo "  - nodeAffinity: bgp=enable ensures pods only on BGP-advertising nodes"
    echo "  - Result: Each BGP node has a local endpoint → DSR return path works"
else
    print_fail "DSR configuration issues detected"
    echo ""
    echo "Fix: Ensure both gateways use externalTrafficPolicy: Local"
    echo "     and nodeAffinity for bgp=enable label"
    echo "See: https://github.com/erauner12/homelab-k8s/issues/1217"
fi

exit "${RESULT}"
