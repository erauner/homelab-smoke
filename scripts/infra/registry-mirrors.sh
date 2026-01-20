#!/usr/bin/env bash
# Verify containerd registry mirrors are accessible via Nexus ClusterIP
#
# Tests that the Nexus Docker proxies are reachable at their ClusterIP endpoints.
# This validates the containerd registry mirror configuration in Talos/Omni.
#
# Background:
# Containerd runs on the host network and uses Cilium's Socket LB to access
# Kubernetes services. With DSR mode, the LoadBalancer VIP (10.10.0.2) can
# experience intermittent timeouts. Using ClusterIP directly bypasses this.
#
# See: https://github.com/erauner12/omni/issues/2
#
# Exit codes:
#   0 - PASS: All registry mirrors accessible
#   1 - FAIL: One or more mirrors unreachable
#   3 - SKIP: curl not available or not running in cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Nexus ClusterIP - this is the stable internal IP for nexus-nexus3 service
NEXUS_CLUSTER_IP="10.102.86.160"

# Registry mirror endpoints (port -> registry name)
declare -A REGISTRIES=(
    [5000]="docker.io (Docker Hub)"
    [5001]="ghcr.io (GitHub Container Registry)"
    [5002]="quay.io"
    [5003]="lscr.io (LinuxServer.io)"
    [5004]="registry.k8s.io (Kubernetes)"
    [5005]="public.ecr.aws (AWS ECR Public)"
    [5010]="docker.nexus.erauner.dev (Homelab hosted)"
)

# Check if we're running inside the cluster (can reach ClusterIP)
# Note: /v2/ returns 401 Unauthorized without auth, which is expected
check_cluster_access() {
    # Try to reach the Nexus ClusterIP - accept any HTTP response (including 401)
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://${NEXUS_CLUSTER_IP}:5000/v2/" 2>/dev/null) || true
    if [[ "${http_code}" == "000" || -z "${http_code}" ]]; then
        echo "Cannot reach Nexus ClusterIP - must run from inside cluster" >&2
        return 1
    fi
    return 0
}

# Main
if ! command -v curl &>/dev/null; then
    print_skip "curl not available"
    exit "${EXIT_SKIP}"
fi

# Check cluster access
if ! check_cluster_access; then
    print_skip "Not running inside cluster (cannot reach ClusterIP)"
    exit "${EXIT_SKIP}"
fi

failed=0
passed=0

print_header "Registry Mirror Health Check"
echo "Nexus ClusterIP: ${NEXUS_CLUSTER_IP}"
echo ""

for port in "${!REGISTRIES[@]}"; do
    registry="${REGISTRIES[$port]}"
    url="http://${NEXUS_CLUSTER_IP}:${port}/v2/"

    # Check if endpoint responds (200 or 401 both indicate reachability)
    # 401 is expected for /v2/ without authentication
    start_time=$(date +%s%3N)
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "${url}" 2>/dev/null) || true
    end_time=$(date +%s%3N)
    latency=$((end_time - start_time))

    if [[ "${http_code}" == "200" || "${http_code}" == "401" ]]; then
        print_ok "${registry} (port ${port}) - ${latency}ms [${http_code}]"
        passed=$((passed + 1))
    elif [[ "${http_code}" == "000" || -z "${http_code}" ]]; then
        print_fail "${registry} (port ${port}) - connection failed"
        failed=$((failed + 1))
    else
        print_fail "${registry} (port ${port}) - HTTP ${http_code}"
        failed=$((failed + 1))
    fi
done

echo ""
echo "${passed} passed, ${failed} failed"

if [[ ${failed} -gt 0 ]]; then
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check Nexus pod: kubectl get pods -n registry -l app.kubernetes.io/name=nexus3"
    echo "  2. Check Nexus service: kubectl get svc nexus-nexus3 -n registry"
    echo "  3. Verify ClusterIP hasn't changed: kubectl get svc nexus-nexus3 -n registry -o jsonpath='{.spec.clusterIP}'"
    echo ""
    echo "If ClusterIP changed, update omni/patches/machine-registries.yaml"
    exit "${EXIT_FAILURE}"
fi

exit "${EXIT_SUCCESS}"
