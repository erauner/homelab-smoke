#!/usr/bin/env bash
# Verify manifest-service is running and API is functional
#
# Tests:
#   1. Pod is running in registry namespace
#   2. Health endpoint responds
#   3. API endpoints work (create/list components, create/list versions)
#   4. Database connectivity (implicit via API tests)
#
# Exit codes:
#   0 - PASS: All checks passed
#   1 - FAIL: One or more checks failed
#   3 - SKIP: manifest-service not deployed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Configuration
NAMESPACE="registry"
SERVICE_NAME="manifest-service"
LOCAL_PORT="18085"  # High port to avoid conflicts
TEST_COMPONENT="smoke-test-component-$$"  # Use PID for uniqueness

print_header "Manifest Service Smoke Test"

# Check if deployment exists
if ! k8s_resource_exists "deployment" "${SERVICE_NAME}" "${NAMESPACE}"; then
    print_skip "manifest-service deployment not found"
    exit "${EXIT_SKIP}"
fi

# Check if pod is running
POD_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${SERVICE_NAME}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")

if [[ "${POD_STATUS}" != "Running" ]]; then
    print_fail "manifest-service pod not running (status: ${POD_STATUS})"
    exit "${EXIT_FAILURE}"
fi
print_ok "Pod is Running"

# Start port-forward
cleanup() {
    pkill -f "port-forward.*${LOCAL_PORT}" 2>/dev/null || true
    # Clean up test data
    if [[ -n "${TEST_COMPONENT:-}" ]]; then
        curl -s -X DELETE "http://localhost:${LOCAL_PORT}/api/apps/${TEST_COMPONENT}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pkill -f "port-forward.*${LOCAL_PORT}" 2>/dev/null || true
kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE_NAME}" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
sleep 3

# Check if port-forward is working
if ! curl -s --connect-timeout 5 "http://localhost:${LOCAL_PORT}/health" >/dev/null 2>&1; then
    print_fail "Cannot connect to manifest-service via port-forward"
    exit "${EXIT_FAILURE}"
fi

# Test health endpoint
HEALTH_RESPONSE=$(curl -s "http://localhost:${LOCAL_PORT}/health")
if [[ "${HEALTH_RESPONSE}" == *'"status":"ok"'* ]]; then
    print_ok "Health endpoint responding"
else
    print_fail "Health endpoint returned unexpected response: ${HEALTH_RESPONSE}"
    exit "${EXIT_FAILURE}"
fi

# Test list components (should work even if empty)
LIST_RESPONSE=$(curl -s "http://localhost:${LOCAL_PORT}/api/apps")
if [[ "${LIST_RESPONSE}" == *'"items":'* ]]; then
    COMPONENT_COUNT=$(echo "${LIST_RESPONSE}" | jq -r '.total' 2>/dev/null || echo "0")
    print_ok "List components API working (${COMPONENT_COUNT} components)"
else
    print_fail "List components API failed: ${LIST_RESPONSE}"
    exit "${EXIT_FAILURE}"
fi

# Test create component
CREATE_RESPONSE=$(curl -s -X POST "http://localhost:${LOCAL_PORT}/api/apps" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${TEST_COMPONENT}\",\"type\":\"go-library\"}")

if [[ "${CREATE_RESPONSE}" == *"\"name\":\"${TEST_COMPONENT}\""* ]]; then
    print_ok "Create component API working"
else
    print_fail "Create component API failed: ${CREATE_RESPONSE}"
    exit "${EXIT_FAILURE}"
fi

# Test create version
VERSION_RESPONSE=$(curl -s -X POST "http://localhost:${LOCAL_PORT}/api/apps/${TEST_COMPONENT}/versions" \
    -H "Content-Type: application/json" \
    -d '{"version":"v0.0.1-smoke","status":"DEV","branch":"smoke-test","commit":"smoke123"}')

if [[ "${VERSION_RESPONSE}" == *'"version":"v0.0.1-smoke"'* ]]; then
    print_ok "Create version API working"
else
    print_fail "Create version API failed: ${VERSION_RESPONSE}"
    exit "${EXIT_FAILURE}"
fi

# Test list versions
VERSIONS_RESPONSE=$(curl -s "http://localhost:${LOCAL_PORT}/api/apps/${TEST_COMPONENT}/versions")
if [[ "${VERSIONS_RESPONSE}" == *'"items":'* ]] && [[ "${VERSIONS_RESPONSE}" == *'"v0.0.1-smoke"'* ]]; then
    print_ok "List versions API working"
else
    print_fail "List versions API failed: ${VERSIONS_RESPONSE}"
    exit "${EXIT_FAILURE}"
fi

# Clean up test component (best effort - delete endpoint may not exist yet)
curl -s -X DELETE "http://localhost:${LOCAL_PORT}/api/apps/${TEST_COMPONENT}" 2>/dev/null || true

echo ""
print_ok "All manifest-service checks passed"
exit "${EXIT_SUCCESS}"
