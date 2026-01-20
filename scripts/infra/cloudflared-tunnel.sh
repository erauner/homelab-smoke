#!/usr/bin/env bash
# Cloudflared Tunnel Smoke Check
#
# Validates the cloudflared tunnel configuration and connectivity:
# 1. cloudflared pods are running
# 2. envoy-public-tunnel ClusterIP service exists
# 3. ClusterIP service is reachable from within the cluster
# 4. Tunnel config uses DNS (not LB VIPs)
#
# Exit Code Contract:
#   0 - PASS: Tunnel is healthy
#   1 - FAIL: Critical issue (tunnel down or misconfigured)
#   2 - ERROR: Script/tool error
#   3 - SKIP: cloudflared not deployed
#   4 - WARN: Minor issue (e.g., stale config)
#
# Usage: ./cloudflared-tunnel.sh
#
# See: https://github.com/erauner12/homelab-k8s/issues/988

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# ============================================================
# Configuration
# ============================================================

SCRIPT_NAME="Cloudflared Tunnel"
SCRIPT_DESCRIPTION="Validates cloudflared tunnel health and DNS-based routing"

CLOUDFLARED_NAMESPACE="network"
CLOUDFLARED_LABEL="app=cloudflared-apps"
TUNNEL_SERVICE="envoy-public-tunnel"
TUNNEL_SERVICE_NS="envoy-gateway-system"
TEST_HOST="grafana.erauner.dev"

# ============================================================
# Main Logic
# ============================================================

print_header "${SCRIPT_NAME}"

# Track overall status
FAILURES=0
WARNINGS=0

# --- Check 1: cloudflared pods are running ---
echo ""
echo "Checking cloudflared pods..."

POD_STATUS=$(kubectl get pods -n "${CLOUDFLARED_NAMESPACE}" -l "${CLOUDFLARED_LABEL}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

if [[ "${POD_STATUS}" == "NotFound" ]]; then
    print_skip "cloudflared not deployed - skipping"
    exit "${EXIT_SKIP}"
elif [[ "${POD_STATUS}" == "Running" ]]; then
    POD_NAME=$(kubectl get pods -n "${CLOUDFLARED_NAMESPACE}" -l "${CLOUDFLARED_LABEL}" -o jsonpath='{.items[0].metadata.name}')
    print_ok "cloudflared pod running: ${POD_NAME}"
else
    print_fail "cloudflared pod not running: ${POD_STATUS}"
    FAILURES=$((FAILURES + 1))
fi

# --- Check 2: envoy-public-tunnel ClusterIP service exists ---
echo ""
echo "Checking envoy-public-tunnel ClusterIP service..."

if k8s_resource_exists "service" "${TUNNEL_SERVICE}" "${TUNNEL_SERVICE_NS}"; then
    CLUSTER_IP=$(kubectl get svc "${TUNNEL_SERVICE}" -n "${TUNNEL_SERVICE_NS}" -o jsonpath='{.spec.clusterIP}')
    SERVICE_TYPE=$(kubectl get svc "${TUNNEL_SERVICE}" -n "${TUNNEL_SERVICE_NS}" -o jsonpath='{.spec.type}')

    if [[ "${SERVICE_TYPE}" == "ClusterIP" ]]; then
        print_ok "envoy-public-tunnel service exists: ${CLUSTER_IP}"
    else
        print_warn "envoy-public-tunnel is ${SERVICE_TYPE}, expected ClusterIP"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    print_fail "envoy-public-tunnel service not found"
    echo "  This service should be created by the envoy-gateway ArgoCD app"
    echo "  Check: argocd app get envoy-gateway --grpc-web"
    FAILURES=$((FAILURES + 1))
fi

# --- Check 3: Tunnel config uses DNS names (not VIPs) ---
echo ""
echo "Checking tunnel configuration..."

# Get the latest config from cloudflared logs
CONFIG_LINE=$(kubectl logs -n "${CLOUDFLARED_NAMESPACE}" -l "${CLOUDFLARED_LABEL}" --tail=200 2>/dev/null | grep "Updated to new configuration" | tail -1 || echo "")

if [[ -n "${CONFIG_LINE}" ]]; then
    # Check if the config contains expected DNS name for the tunnel service
    # (JSON parsing is fragile due to escaped quotes, so we use grep)
    if echo "${CONFIG_LINE}" | grep -q "envoy-public-tunnel.envoy-gateway-system.svc.cluster.local"; then
        print_ok "Tunnel uses DNS: envoy-public-tunnel.envoy-gateway-system.svc.cluster.local"
    elif echo "${CONFIG_LINE}" | grep -qE "10\.10\.0\.[0-9]+:[0-9]+"; then
        print_fail "Tunnel appears to use LB VIP (found 10.10.0.x in config)"
        echo "  Expected: http://envoy-public-tunnel.envoy-gateway-system.svc.cluster.local:80"
        echo "  Run: terraform apply in terraform/cloudflare/"
        FAILURES=$((FAILURES + 1))
    else
        print_warn "Could not verify tunnel config (unexpected format)"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    print_warn "Could not find tunnel config in logs (may be stale pod)"
    WARNINGS=$((WARNINGS + 1))
fi

# --- Check 4: ClusterIP connectivity test ---
echo ""
echo "Testing ClusterIP connectivity..."

# Only run if service exists
if k8s_resource_exists "service" "${TUNNEL_SERVICE}" "${TUNNEL_SERVICE_NS}"; then
    # Run a test pod to curl the ClusterIP service
    # Capture full output and extract HTTP code
    TEST_OUTPUT=$(kubectl run tunnel-smoke-test --rm -i --restart=Never --image=curlimages/curl:latest \
        -- curl -s -o /dev/null -w "%{http_code}" \
        "http://${TUNNEL_SERVICE}.${TUNNEL_SERVICE_NS}.svc.cluster.local:80" \
        -H "Host: ${TEST_HOST}" \
        --connect-timeout 5 \
        --max-time 10 2>&1 || echo "error")

    # Extract the 3-digit HTTP code from the output
    HTTP_CODE=$(echo "${TEST_OUTPUT}" | grep -oE '[0-9]{3}' | head -1 || echo "000")

    # If no code found, default to 000
    [[ -z "${HTTP_CODE}" ]] && HTTP_CODE="000"

    # Any 2xx or 3xx response indicates the service is reachable
    if [[ "${HTTP_CODE}" =~ ^[23][0-9][0-9]$ ]]; then
        print_ok "ClusterIP reachable via test pod: HTTP ${HTTP_CODE}"
    elif [[ "${HTTP_CODE}" == "000" ]]; then
        print_fail "ClusterIP not reachable (timeout or DNS failure)"
        FAILURES=$((FAILURES + 1))
    elif [[ "${HTTP_CODE}" =~ ^4[0-9][0-9]$ ]]; then
        # 4xx might be expected (auth required) - still means service is reachable
        print_ok "ClusterIP reachable (HTTP ${HTTP_CODE} - auth may be required)"
    else
        print_warn "Unexpected HTTP response: ${HTTP_CODE}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    print_skip "Skipping connectivity test - service not found"
fi

# --- Summary ---
echo ""
print_separator

if [[ ${FAILURES} -gt 0 ]]; then
    print_fail "Cloudflared tunnel check failed with ${FAILURES} failure(s)"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check cloudflared logs: kubectl logs -n network -l app=cloudflared-apps"
    echo "  2. Check ArgoCD sync: argocd app get envoy-gateway --grpc-web"
    echo "  3. Verify Terraform: cd terraform/cloudflare && terraform plan"
    echo ""
    echo "Documentation: docs/networking/Tunnel-E2E-Validation.md"
    exit "${EXIT_FAILURE}"
elif [[ ${WARNINGS} -gt 0 ]]; then
    print_warn "Cloudflared tunnel check passed with ${WARNINGS} warning(s)"
    exit "${EXIT_WARN}"
else
    print_ok "Cloudflared tunnel check passed"
    exit "${EXIT_SUCCESS}"
fi
