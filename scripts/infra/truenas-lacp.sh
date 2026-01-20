#!/usr/bin/env bash
# TrueNAS LACP Bond Smoke Test
#
# Verifies TrueNAS LACP bond is operational by testing:
# - Basic connectivity to TrueNAS
# - NFS service availability
# - Parallel throughput from multiple Kubernetes nodes
#
# Exit Code Contract:
#   0 - PASS: All checks succeeded
#   1 - FAIL: One or more checks failed
#   2 - ERROR: Script/tool error
#   3 - SKIP: TrueNAS not reachable
#   4 - WARN: Warning (non-blocking)

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Configuration
SCRIPT_NAME="TrueNAS LACP Bond"
TRUENAS_IP="${TRUENAS_IP:-192.168.1.241}"
NFS_PATH="${NFS_PATH:-/mnt/tank/kubernetes}"
TEST_NAMESPACE="default"
CLEANUP_ON_FAIL="${CLEANUP_ON_FAIL:-true}"

# Test parameters
PARALLEL_PODS=4           # Number of parallel test pods (should match K8s node count)
WRITE_SIZE_MB=100         # Size of test file per pod
EXPECTED_MIN_THROUGHPUT=200  # Minimum expected MB/s aggregate (conservative)

# Track overall result
OVERALL_RESULT=0

# Generate unique test ID
TEST_ID="lacp-$(date +%s)"

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ "${CLEANUP_ON_FAIL}" == "true" ]] || [[ ${exit_code} -eq 0 ]]; then
        echo ""
        echo "Cleaning up test resources..."
        for i in $(seq 1 ${PARALLEL_PODS}); do
            kubectl delete pod "smoke-lacp-${TEST_ID}-${i}" -n "${TEST_NAMESPACE}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
        done
        kubectl delete pvc "smoke-lacp-pvc-${TEST_ID}" -n "${TEST_NAMESPACE}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

print_header "${SCRIPT_NAME}"

echo ""
echo "TrueNAS Configuration:"
print_summary_line "IP Address" "${TRUENAS_IP}"
print_summary_line "NFS Path" "${NFS_PATH}"
print_summary_line "Parallel Pods" "${PARALLEL_PODS}"
print_summary_line "Write Size" "${WRITE_SIZE_MB}MB per pod"

# ============================================================================
# Check 1: TrueNAS Connectivity
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Connectivity Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Checking TrueNAS connectivity..."
if ! ping -c 1 -W 2 "${TRUENAS_IP}" >/dev/null 2>&1; then
    print_skip "TrueNAS not reachable at ${TRUENAS_IP}"
    exit "${EXIT_SKIP}"
fi
print_ok "TrueNAS reachable at ${TRUENAS_IP}"

# Check 2: NFS port accessible
echo ""
echo "Checking NFS service (port 2049)..."
if ! nc -z -w 2 "${TRUENAS_IP}" 2049 2>/dev/null; then
    print_fail "NFS port 2049 not accessible on ${TRUENAS_IP}"
    OVERALL_RESULT=1
else
    print_ok "NFS service accessible on port 2049"
fi

# ============================================================================
# Check 3: Get Kubernetes Node Count
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Kubernetes Node Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Checking available Kubernetes nodes..."
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${NODE_COUNT}" -eq 0 ]]; then
    print_fail "No Kubernetes nodes found"
    exit "${EXIT_ERROR}"
fi
print_ok "Found ${NODE_COUNT} Kubernetes nodes"

# Adjust parallel pods to not exceed node count
if [[ "${PARALLEL_PODS}" -gt "${NODE_COUNT}" ]]; then
    PARALLEL_PODS="${NODE_COUNT}"
    echo "  Adjusted parallel pods to ${PARALLEL_PODS} (matching node count)"
fi

# Get node names for pod scheduling
NODE_NAMES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null))

# ============================================================================
# Check 4: Create Test PVC
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NFS Throughput Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Creating test PVC..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-lacp-pvc-${TEST_ID}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-truenas-delete
EOF

# Wait for PVC to bind
echo "  Waiting for PVC to bind..."
PVC_BOUND=false
for i in {1..30}; do
    PVC_STATUS=$(kubectl get pvc "smoke-lacp-pvc-${TEST_ID}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "${PVC_STATUS}" == "Bound" ]]; then
        PVC_BOUND=true
        break
    fi
    sleep 2
done

if [[ "${PVC_BOUND}" != "true" ]]; then
    print_fail "PVC failed to bind (status: ${PVC_STATUS})"
    exit "${EXIT_FAILURE}"
fi
print_ok "PVC bound successfully"

# ============================================================================
# Check 5: Run Parallel Write Test
# ============================================================================
echo ""
echo "Launching ${PARALLEL_PODS} parallel write pods on different nodes..."
echo "  Each pod will write ${WRITE_SIZE_MB}MB to NFS"

# Launch pods on different nodes
for i in $(seq 1 ${PARALLEL_PODS}); do
    NODE_INDEX=$((i - 1))
    NODE_NAME="${NODE_NAMES[$NODE_INDEX]}"

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: smoke-lacp-${TEST_ID}-${i}
  namespace: ${TEST_NAMESPACE}
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: Never
  containers:
  - name: writer
    image: busybox
    command:
    - sh
    - -c
    - |
      # Wait for sync signal (all pods ready)
      sleep 5
      START=\$(date +%s.%N)
      dd if=/dev/zero of=/data/test-${i}.bin bs=1M count=${WRITE_SIZE_MB} conv=fsync 2>/dev/null
      END=\$(date +%s.%N)
      DURATION=\$(echo "\$END - \$START" | bc)
      SPEED=\$(echo "scale=2; ${WRITE_SIZE_MB} / \$DURATION" | bc)
      echo "RESULT:${i}:\${SPEED}:MB/s"
      # Keep pod running briefly for log collection
      sleep 10
    volumeMounts:
    - name: nfs
      mountPath: /data
  volumes:
  - name: nfs
    persistentVolumeClaim:
      claimName: smoke-lacp-pvc-${TEST_ID}
EOF
    echo "  Pod ${i} scheduled on node ${NODE_NAME}"
done

# Wait for all pods to complete (image pulls can take 2-3 minutes)
echo ""
echo "Waiting for write tests to complete (this may take a few minutes for image pulls)..."
ALL_COMPLETED=false
for attempt in {1..90}; do
    COMPLETED=0
    for i in $(seq 1 ${PARALLEL_PODS}); do
        POD_PHASE=$(kubectl get pod "smoke-lacp-${TEST_ID}-${i}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "${POD_PHASE}" == "Succeeded" ]] || [[ "${POD_PHASE}" == "Failed" ]]; then
            COMPLETED=$((COMPLETED + 1))
        fi
    done

    if [[ "${COMPLETED}" -eq "${PARALLEL_PODS}" ]]; then
        ALL_COMPLETED=true
        break
    fi
    sleep 2
done

if [[ "${ALL_COMPLETED}" != "true" ]]; then
    print_fail "Not all test pods completed in time"
    OVERALL_RESULT=1
else
    # Collect results
    echo ""
    echo "Results:"
    TOTAL_THROUGHPUT=0
    SUCCESS_COUNT=0

    for i in $(seq 1 ${PARALLEL_PODS}); do
        POD_LOGS=$(kubectl logs "smoke-lacp-${TEST_ID}-${i}" -n "${TEST_NAMESPACE}" 2>/dev/null || echo "")
        RESULT_LINE=$(echo "${POD_LOGS}" | grep "^RESULT:" || echo "")

        if [[ -n "${RESULT_LINE}" ]]; then
            SPEED=$(echo "${RESULT_LINE}" | cut -d: -f3)
            NODE_NAME="${NODE_NAMES[$((i - 1))]}"
            printf "  Pod %d (%s): %s MB/s\n" "${i}" "${NODE_NAME}" "${SPEED}"
            TOTAL_THROUGHPUT=$(echo "${TOTAL_THROUGHPUT} + ${SPEED}" | bc)
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            printf "  Pod %d: Failed to get results\n" "${i}"
        fi
    done

    if [[ "${SUCCESS_COUNT}" -gt 0 ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "Aggregate Throughput: %.2f MB/s\n" "${TOTAL_THROUGHPUT}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Check if aggregate throughput indicates bond is working
        # With 2x 2.5Gbps links, theoretical max is ~500MB/s
        # Single link would max around 250-280MB/s
        THROUGHPUT_INT=${TOTAL_THROUGHPUT%.*}

        if [[ "${THROUGHPUT_INT}" -ge "${EXPECTED_MIN_THROUGHPUT}" ]]; then
            print_ok "Aggregate throughput (${TOTAL_THROUGHPUT} MB/s) meets minimum threshold (${EXPECTED_MIN_THROUGHPUT} MB/s)"

            # Check if we're seeing benefit of bond (> single link capacity)
            if [[ "${THROUGHPUT_INT}" -ge 280 ]]; then
                print_ok "Throughput exceeds single 2.5Gbps link capacity - LACP bond is providing aggregate bandwidth"
            else
                print_warn "Throughput within single link capacity - bond provides redundancy but parallel test may not have saturated both links"
            fi
        else
            print_warn "Aggregate throughput (${TOTAL_THROUGHPUT} MB/s) below expected minimum (${EXPECTED_MIN_THROUGHPUT} MB/s)"
            echo "  This could indicate:"
            echo "    - Disk I/O bottleneck on TrueNAS"
            echo "    - Network congestion"
            echo "    - LACP not fully operational"
        fi
    else
        print_fail "No successful write tests"
        OVERALL_RESULT=1
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${OVERALL_RESULT} -eq 0 ]]; then
    print_ok "TrueNAS LACP bond checks passed"
    exit "${EXIT_SUCCESS}"
else
    print_fail "Some TrueNAS LACP bond checks failed"
    exit "${EXIT_FAILURE}"
fi
