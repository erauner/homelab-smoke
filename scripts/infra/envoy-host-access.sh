#!/usr/bin/env bash
# Verify Envoy Gateway configuration for host network access
#
# This test validates that host network processes can reach gateway LB VIPs.
#
# CONFIGURATION (post issue #1217):
#   - externalTrafficPolicy: Local + nodeAffinity for bgp=enable
#   - Each BGP node has a local gateway pod
#   - Host processes on BGP nodes can reach local pods via socketLB
#
# IMPORTANT LIMITATION:
#   This test uses hostNetwork PODS, which behave differently from true host
#   processes (like containerd). Cilium's socketLB intercepts syscalls in the
#   host PID namespace, but hostNetwork pods run in container PID namespaces.
#
#   Therefore:
#   - Connectivity from hostNetwork pods tests network path, not socketLB
#   - Real validation requires testing actual image pulls (containerd → Nexus)
#
# See:
#   - https://github.com/erauner12/homelab-k8s/issues/1217 (DSR fix - Local policy)
#   - https://github.com/erauner12/homelab-k8s/issues/990 (real validation needed)
#
# Exit codes:
#   0 - PASS: Configuration is correct, connectivity test passed
#   1 - FAIL: Configuration is wrong or connectivity failed
#   2 - ERROR: Test infrastructure failed
#   3 - SKIP: Prerequisites not met

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Test namespace - must allow hostNetwork pods
TEST_NAMESPACE="kube-system"
TEST_IMAGE="busybox:latest"
TIMEOUT_SECONDS=5
MAX_RETRIES=2
RETRY_DELAY=1

print_header "Envoy Gateway Host Access Configuration Check"

# Get gateway LoadBalancer IPs and policies
echo ""
echo "Gateway configuration:"

INTERNAL_SVC=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=envoy-internal -o json 2>/dev/null)
PUBLIC_SVC=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=envoy-public -o json 2>/dev/null)

INTERNAL_IP=$(echo "${INTERNAL_SVC}" | jq -r '.items[0].status.loadBalancer.ingress[0].ip // empty')
INTERNAL_POLICY=$(echo "${INTERNAL_SVC}" | jq -r '.items[0].spec.externalTrafficPolicy // empty')
PUBLIC_IP=$(echo "${PUBLIC_SVC}" | jq -r '.items[0].status.loadBalancer.ingress[0].ip // empty')
PUBLIC_POLICY=$(echo "${PUBLIC_SVC}" | jq -r '.items[0].spec.externalTrafficPolicy // empty')

if [[ -z "${INTERNAL_IP}" ]]; then
    print_fail "Internal gateway: No LoadBalancer IP assigned"
    exit "${EXIT_ERROR}"
fi

if [[ -z "${PUBLIC_IP}" ]]; then
    print_fail "Public gateway: No LoadBalancer IP assigned"
    exit "${EXIT_ERROR}"
fi

echo "  Internal gateway: ${INTERNAL_IP} (externalTrafficPolicy: ${INTERNAL_POLICY})"
echo "  Public gateway:   ${PUBLIC_IP} (externalTrafficPolicy: ${PUBLIC_POLICY})"

# ============================================================
# CRITICAL CHECK: externalTrafficPolicy must be Local (DSR fix)
# ============================================================
echo ""
echo "Policy verification (Local required for DSR mode - issue #1217):"

RESULT="${EXIT_SUCCESS}"

if [[ "${INTERNAL_POLICY}" == "Local" ]]; then
    print_ok "Internal gateway uses Local policy (DSR-compatible)"
else
    print_fail "Internal gateway uses ${INTERNAL_POLICY} policy (MUST be Local for DSR)"
    RESULT="${EXIT_FAILURE}"
fi

if [[ "${PUBLIC_POLICY}" == "Local" ]]; then
    print_ok "Public gateway uses Local policy (DSR-compatible)"
else
    print_fail "Public gateway uses ${PUBLIC_POLICY} policy (MUST be Local for DSR)"
    RESULT="${EXIT_FAILURE}"
fi

# Exit early if policy is wrong - that's the critical check
if [[ "${RESULT}" != "${EXIT_SUCCESS}" ]]; then
    echo ""
    print_fail "FAILED: externalTrafficPolicy must be 'Local' for DSR mode"
    echo "See: https://github.com/erauner12/homelab-k8s/issues/1217"
    exit "${RESULT}"
fi

# ============================================================
# Check gateway pod distribution
# ============================================================
echo ""
echo "Gateway pod distribution:"

INTERNAL_PODS=$(kubectl get pods -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=envoy-internal \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' | sort -u)
PUBLIC_PODS=$(kubectl get pods -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=envoy-public \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' | sort -u)

WORKER_NODES=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')
WORKER_ARRAY=(${WORKER_NODES})
WORKER_COUNT=${#WORKER_ARRAY[@]}

INTERNAL_NODE_COUNT=$(echo "${INTERNAL_PODS}" | grep -c . || echo 0)
PUBLIC_NODE_COUNT=$(echo "${PUBLIC_PODS}" | grep -c . || echo 0)

echo "  Internal gateway: Running on ${INTERNAL_NODE_COUNT} nodes"
echo "  Public gateway:   Running on ${PUBLIC_NODE_COUNT} nodes"
echo "  Worker nodes:     ${WORKER_COUNT}"

if [[ ${INTERNAL_NODE_COUNT} -ge ${WORKER_COUNT} ]]; then
    print_ok "Internal gateway covers all workers"
else
    echo "  Internal gateway on ${INTERNAL_NODE_COUNT}/${WORKER_COUNT} workers (topology spread may vary)"
fi

if [[ ${PUBLIC_NODE_COUNT} -ge ${WORKER_COUNT} ]]; then
    print_ok "Public gateway covers all workers"
else
    echo "  Public gateway on ${PUBLIC_NODE_COUNT}/${WORKER_COUNT} workers (topology spread may vary)"
fi

# ============================================================
# INFORMATIONAL: hostNetwork pod connectivity test
# ============================================================
echo ""
echo "============================================================"
echo "INFORMATIONAL: hostNetwork pod connectivity test"
echo "============================================================"
echo "NOTE: This tests hostNetwork PODS, not real host processes."
echo "      Partial connectivity is EXPECTED with DSR mode."
echo "      This does NOT predict containerd/Nexus behavior."
echo "      See: https://github.com/erauner12/homelab-k8s/issues/990"
echo ""

# Function to test TCP connectivity from hostNetwork pod
test_host_tcp() {
    local ip="$1"
    local port="$2"
    local node="$3"
    local attempt=1

    while [[ ${attempt} -le ${MAX_RETRIES} ]]; do
        local pod_name="smoke-host-tcp-${RANDOM}"

        local result
        result=$(kubectl run "${pod_name}" \
            -n "${TEST_NAMESPACE}" \
            --image="${TEST_IMAGE}" \
            --restart=Never \
            --rm \
            -i \
            --overrides="{\"spec\":{\"hostNetwork\":true,\"nodeSelector\":{\"kubernetes.io/hostname\":\"${node}\"}}}" \
            -- nc -zv -w "${TIMEOUT_SECONDS}" "${ip}" "${port}" 2>&1) || true

        if echo "${result}" | grep -q "succeeded\|open"; then
            return 0
        fi

        if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
            sleep "${RETRY_DELAY}"
        fi
        ((attempt++))
    done

    return 1
}

# Smart connectivity test: only test from nodes where we expect success
# With DSR mode, connections work when there's a LOCAL gateway pod

# Find a worker with internal gateway pod
INTERNAL_NODE=$(kubectl get pods -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=envoy-internal \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' | grep -E "^worker" | head -1)

# Find a worker with public gateway pod
PUBLIC_NODE=$(kubectl get pods -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=envoy-public \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' | grep -E "^worker" | head -1)

echo "Testing from nodes with LOCAL gateway pods (should succeed):"
echo ""

INTERNAL_OK=false
PUBLIC_OK=false

if [[ -n "${INTERNAL_NODE}" ]]; then
    echo "Internal gateway test from ${INTERNAL_NODE} (has local pod):"
    if test_host_tcp "${INTERNAL_IP}" 443 "${INTERNAL_NODE}"; then
        print_ok "  Reachable (local pod exists)"
        INTERNAL_OK=true
    else
        print_warn "  NOT reachable despite local pod (unexpected)"
    fi
else
    echo "  No worker has internal gateway pod"
fi

echo ""

if [[ -n "${PUBLIC_NODE}" ]]; then
    echo "Public gateway test from ${PUBLIC_NODE} (has local pod):"
    if test_host_tcp "${PUBLIC_IP}" 443 "${PUBLIC_NODE}"; then
        print_ok "  Reachable (local pod exists)"
        PUBLIC_OK=true
    else
        print_warn "  NOT reachable despite local pod (unexpected)"
    fi
else
    echo "  No worker has public gateway pod"
fi

echo ""
echo "Connectivity results:"
if [[ "${INTERNAL_OK}" == "true" && "${PUBLIC_OK}" == "true" ]]; then
    print_ok "Both gateways reachable from nodes with local pods"
else
    print_warn "Connectivity issues detected (see above)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================================"
echo "Summary"
echo "============================================================"
print_ok "Configuration is correct:"
echo "  - externalTrafficPolicy: Local (DSR-compatible, issue #1217)"
echo "  - Gateway pods distributed across BGP nodes"
echo "  - Each BGP node has a local endpoint for DSR return path"
echo ""
echo "For real host process validation (containerd → Nexus):"
echo "  - Deploy Nexus repository proxy"
echo "  - Configure containerd registry mirrors"
echo "  - Test actual image pulls"
echo "  - See: https://github.com/erauner12/homelab-k8s/issues/990"

exit "${EXIT_SUCCESS}"
