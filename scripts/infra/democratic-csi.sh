#!/usr/bin/env bash
# Democratic CSI Smoke Test
#
# Verifies TrueNAS CSI drivers (NFS + iSCSI) are operational:
# - CSIDriver resources are registered
# - StorageClasses exist with correct provisioners
# - Controller pods are running
# - Node DaemonSets are healthy
# - Dynamic provisioning works (creates PVC, mounts, writes, cleans up)
#
# Exit Code Contract:
#   0 - PASS: All checks succeeded
#   1 - FAIL: One or more checks failed
#   2 - ERROR: Script/tool error
#   3 - SKIP: democratic-csi not installed
#   4 - WARN: Warning (non-blocking)

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Configuration
SCRIPT_NAME="Democratic CSI (TrueNAS NFS + iSCSI)"
NAMESPACE="democratic-csi"
TEST_NAMESPACE="default"
CLEANUP_ON_FAIL="${CLEANUP_ON_FAIL:-true}"

# Driver configurations
# Note: Use "-delete" StorageClasses for tests to auto-cleanup PVs
NFS_CSI_DRIVER="org.democratic-csi.nfs"
NFS_STORAGECLASS="nfs-truenas-delete"  # Delete policy for auto PV cleanup
NFS_TEST_PVC="smoke-test-nfs-pvc"
NFS_TEST_POD="smoke-test-nfs-mount"

ISCSI_CSI_DRIVER="org.democratic-csi.iscsi"
ISCSI_STORAGECLASS="iscsi-truenas-delete"  # Delete policy for auto PV cleanup
ISCSI_TEST_PVC="smoke-test-iscsi-pvc"
ISCSI_TEST_POD="smoke-test-iscsi-mount"

# Track overall result
OVERALL_RESULT=0

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ "${CLEANUP_ON_FAIL}" == "true" ]] || [[ ${exit_code} -eq 0 ]]; then
        # Delete test pods
        kubectl delete pod "${NFS_TEST_POD}" -n "${TEST_NAMESPACE}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
        kubectl delete pod "${ISCSI_TEST_POD}" -n "${TEST_NAMESPACE}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

        # Get PV names before deleting PVCs (for Retain policy cleanup)
        local iscsi_pv
        iscsi_pv=$(kubectl get pvc "${ISCSI_TEST_PVC}" -n "${TEST_NAMESPACE}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)

        # Delete test PVCs
        kubectl delete pvc "${NFS_TEST_PVC}" -n "${TEST_NAMESPACE}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
        kubectl delete pvc "${ISCSI_TEST_PVC}" -n "${TEST_NAMESPACE}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

        # Delete iSCSI PV (Retain policy doesn't auto-delete)
        if [[ -n "${iscsi_pv}" ]]; then
            kubectl delete pv "${iscsi_pv}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
        fi
    fi
}
trap cleanup EXIT

print_header "${SCRIPT_NAME}"

# Ensure iSCSI infrastructure exists (legacy workaround for TrueNAS < 25.04)
# TrueNAS 24.04 auto-deleted initiator groups when all targets were removed.
# Fixed in TrueNAS 25.04.1+ (PR #16220). This check is now optional but harmless.
if [[ -n "${TRUENAS_API_KEY:-}" ]]; then
    echo ""
    echo "Checking iSCSI infrastructure..."
    "${SCRIPT_DIR}/../../../../truenas/scripts/ensure-iscsi-infra.sh" 2>/dev/null || true
fi

# ============================================================================
# NFS Driver Tests
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NFS Driver Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check 1: NFS CSIDriver registered
echo ""
echo "Checking NFS CSIDriver..."
if ! kubectl get csidriver "${NFS_CSI_DRIVER}" >/dev/null 2>&1; then
    print_skip "CSIDriver ${NFS_CSI_DRIVER} not registered - democratic-csi NFS not installed"
    exit "${EXIT_SKIP}"
fi
print_ok "CSIDriver ${NFS_CSI_DRIVER} registered"

# Check 2: NFS Controller pod running
echo ""
echo "Checking NFS controller pod..."
NFS_CONTROLLER_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-nfs,app.kubernetes.io/csi-role=controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "${NFS_CONTROLLER_STATUS}" != "Running" ]]; then
    print_fail "NFS controller pod not running (status: ${NFS_CONTROLLER_STATUS})"
    OVERALL_RESULT=1
else
    print_ok "NFS controller pod running"
fi

# Check 3: NFS Node DaemonSet pods
echo ""
echo "Checking NFS node pods..."
NFS_NODE_READY=$(kubectl get ds -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-nfs,app.kubernetes.io/csi-role=node -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
NFS_NODE_DESIRED=$(kubectl get ds -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-nfs,app.kubernetes.io/csi-role=node -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
if [[ "${NFS_NODE_READY}" -eq 0 ]] || [[ "${NFS_NODE_READY}" -lt "${NFS_NODE_DESIRED}" ]]; then
    print_warn "NFS node pods not all ready (${NFS_NODE_READY}/${NFS_NODE_DESIRED})"
else
    print_ok "NFS node pods ready (${NFS_NODE_READY}/${NFS_NODE_DESIRED})"
fi

# Check 4: NFS StorageClass
echo ""
echo "Checking NFS StorageClass..."
if ! kubectl get storageclass "${NFS_STORAGECLASS}" >/dev/null 2>&1; then
    print_fail "StorageClass ${NFS_STORAGECLASS} not found"
    OVERALL_RESULT=1
else
    NFS_SC_PROVISIONER=$(kubectl get storageclass "${NFS_STORAGECLASS}" -o jsonpath='{.provisioner}' 2>/dev/null)
    if [[ "${NFS_SC_PROVISIONER}" != "${NFS_CSI_DRIVER}" ]]; then
        print_fail "StorageClass provisioner mismatch: expected ${NFS_CSI_DRIVER}, got ${NFS_SC_PROVISIONER}"
        OVERALL_RESULT=1
    else
        print_ok "StorageClass ${NFS_STORAGECLASS} exists (provisioner: ${NFS_SC_PROVISIONER})"
    fi
fi

# Check 5: NFS dynamic provisioning
echo ""
echo "Testing NFS dynamic provisioning..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NFS_TEST_PVC}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Mi
  storageClassName: ${NFS_STORAGECLASS}
EOF

echo "  Waiting for NFS PVC to bind..."
NFS_BOUND=false
for i in {1..30}; do
    NFS_PVC_STATUS=$(kubectl get pvc "${NFS_TEST_PVC}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "${NFS_PVC_STATUS}" == "Bound" ]]; then
        NFS_BOUND=true
        break
    fi
    sleep 2
done

if [[ "${NFS_BOUND}" != "true" ]]; then
    print_fail "NFS PVC failed to bind (status: ${NFS_PVC_STATUS})"
    kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-nfs,app.kubernetes.io/csi-role=controller -c csi-driver --tail=5 2>/dev/null | sed 's/^/    /' || true
    OVERALL_RESULT=1
else
    print_ok "NFS PVC bound successfully"

    # Test NFS mount and write
    echo ""
    echo "Testing NFS mount and write..."
    NFS_MOUNT_OUTPUT=$(kubectl run "${NFS_TEST_POD}" -n "${TEST_NAMESPACE}" --rm -i --restart=Never --image=busybox \
      --overrides='{
        "spec": {
          "containers": [{
            "name": "test",
            "image": "busybox",
            "command": ["sh", "-c", "echo nfs-smoke-test > /data/smoke.txt && cat /data/smoke.txt"],
            "volumeMounts": [{"name": "vol", "mountPath": "/data"}]
          }],
          "volumes": [{
            "name": "vol",
            "persistentVolumeClaim": {"claimName": "'"${NFS_TEST_PVC}"'"}
          }]
        }
      }' --timeout=60s 2>&1) || true

    if echo "${NFS_MOUNT_OUTPUT}" | grep -q "nfs-smoke-test"; then
        print_ok "NFS mount and write successful"
    else
        print_fail "Failed to mount or write to NFS volume"
        echo "  Output: ${NFS_MOUNT_OUTPUT}"
        OVERALL_RESULT=1
    fi
fi

# ============================================================================
# iSCSI Driver Tests
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "iSCSI Driver Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check 1: iSCSI CSIDriver registered
echo ""
echo "Checking iSCSI CSIDriver..."
if ! kubectl get csidriver "${ISCSI_CSI_DRIVER}" >/dev/null 2>&1; then
    print_warn "CSIDriver ${ISCSI_CSI_DRIVER} not registered - iSCSI driver not installed"
else
    print_ok "CSIDriver ${ISCSI_CSI_DRIVER} registered"

    # Check 2: iSCSI Controller pod running
    echo ""
    echo "Checking iSCSI controller pod..."
    ISCSI_CONTROLLER_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-iscsi,app.kubernetes.io/csi-role=controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "${ISCSI_CONTROLLER_STATUS}" != "Running" ]]; then
        print_fail "iSCSI controller pod not running (status: ${ISCSI_CONTROLLER_STATUS})"
        OVERALL_RESULT=1
    else
        print_ok "iSCSI controller pod running"
    fi

    # Check 3: iSCSI Node DaemonSet pods
    echo ""
    echo "Checking iSCSI node pods..."
    ISCSI_NODE_READY=$(kubectl get ds -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-iscsi,app.kubernetes.io/csi-role=node -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
    ISCSI_NODE_DESIRED=$(kubectl get ds -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-iscsi,app.kubernetes.io/csi-role=node -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    if [[ "${ISCSI_NODE_READY}" -eq 0 ]] || [[ "${ISCSI_NODE_READY}" -lt "${ISCSI_NODE_DESIRED}" ]]; then
        print_warn "iSCSI node pods not all ready (${ISCSI_NODE_READY}/${ISCSI_NODE_DESIRED})"
    else
        print_ok "iSCSI node pods ready (${ISCSI_NODE_READY}/${ISCSI_NODE_DESIRED})"
    fi

    # Check 4: iSCSI StorageClass
    echo ""
    echo "Checking iSCSI StorageClass..."
    if ! kubectl get storageclass "${ISCSI_STORAGECLASS}" >/dev/null 2>&1; then
        print_fail "StorageClass ${ISCSI_STORAGECLASS} not found"
        OVERALL_RESULT=1
    else
        ISCSI_SC_PROVISIONER=$(kubectl get storageclass "${ISCSI_STORAGECLASS}" -o jsonpath='{.provisioner}' 2>/dev/null)
        if [[ "${ISCSI_SC_PROVISIONER}" != "${ISCSI_CSI_DRIVER}" ]]; then
            print_fail "StorageClass provisioner mismatch: expected ${ISCSI_CSI_DRIVER}, got ${ISCSI_SC_PROVISIONER}"
            OVERALL_RESULT=1
        else
            print_ok "StorageClass ${ISCSI_STORAGECLASS} exists (provisioner: ${ISCSI_SC_PROVISIONER})"
        fi
    fi

    # Check 5: iSCSI dynamic provisioning
    echo ""
    echo "Testing iSCSI dynamic provisioning..."
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${ISCSI_TEST_PVC}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${ISCSI_STORAGECLASS}
EOF

    echo "  Waiting for iSCSI PVC to bind..."
    ISCSI_BOUND=false
    for i in {1..30}; do
        ISCSI_PVC_STATUS=$(kubectl get pvc "${ISCSI_TEST_PVC}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "${ISCSI_PVC_STATUS}" == "Bound" ]]; then
            ISCSI_BOUND=true
            break
        fi
        sleep 2
    done

    if [[ "${ISCSI_BOUND}" != "true" ]]; then
        print_fail "iSCSI PVC failed to bind (status: ${ISCSI_PVC_STATUS})"
        kubectl logs -n "${NAMESPACE}" -l app.kubernetes.io/instance=democratic-csi-iscsi,app.kubernetes.io/csi-role=controller -c csi-driver --tail=5 2>/dev/null | sed 's/^/    /' || true
        OVERALL_RESULT=1
    else
        print_ok "iSCSI PVC bound successfully"

        # Test iSCSI mount and write
        echo ""
        echo "Testing iSCSI mount and write..."
        ISCSI_MOUNT_OUTPUT=$(kubectl run "${ISCSI_TEST_POD}" -n "${TEST_NAMESPACE}" --rm -i --restart=Never --image=busybox \
          --overrides='{
            "spec": {
              "containers": [{
                "name": "test",
                "image": "busybox",
                "command": ["sh", "-c", "echo iscsi-smoke-test > /data/smoke.txt && cat /data/smoke.txt"],
                "volumeMounts": [{"name": "vol", "mountPath": "/data"}]
              }],
              "volumes": [{
                "name": "vol",
                "persistentVolumeClaim": {"claimName": "'"${ISCSI_TEST_PVC}"'"}
              }]
            }
          }' --timeout=90s 2>&1) || true

        if echo "${ISCSI_MOUNT_OUTPUT}" | grep -q "iscsi-smoke-test"; then
            print_ok "iSCSI mount and write successful"
        else
            print_fail "Failed to mount or write to iSCSI volume"
            echo "  Output: ${ISCSI_MOUNT_OUTPUT}"
            OVERALL_RESULT=1
        fi
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${OVERALL_RESULT} -eq 0 ]]; then
    print_ok "All democratic-csi checks passed"
    exit "${EXIT_SUCCESS}"
else
    print_fail "Some democratic-csi checks failed"
    exit "${EXIT_FAILURE}"
fi
