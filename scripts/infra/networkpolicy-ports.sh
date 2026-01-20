#!/usr/bin/env bash
# Check NetworkPolicy uses correct container ports (10080/10443)
# NOT service ports (80/443)
#
# Envoy Gateway maps: svc:80->container:10080, svc:443->container:10443
# NetworkPolicies filter at container level!
#
# Exit codes:
#   0 - PASS: NetworkPolicy uses correct container ports
#   1 - FAIL: NetworkPolicy uses wrong service ports
#   2 - ERROR: kubectl command failed
#   3 - SKIP: No Envoy NetworkPolicy found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

print_header "NetworkPolicy Port Check"

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

    # Check if using wrong service ports (80, 443)
    HAS_WRONG_PORTS=$(echo "${NP}" | base64 -d | jq '[.spec.ingress[].ports[]?.port] | map(select(. == 80 or . == 443)) | length > 0')

    # Check if using correct container ports (10080, 10443)
    HAS_CORRECT_PORTS=$(echo "${NP}" | base64 -d | jq '[.spec.ingress[].ports[]?.port] | map(select(. == 10080 or . == 10443)) | length > 0')

    if [[ "${HAS_WRONG_PORTS}" == "true" ]]; then
        print_fail "NetworkPolicy ${NAME} uses SERVICE ports (80, 443)"
        echo "    NetworkPolicies filter at container level!"
        echo "    Envoy Gateway maps: svc:80 -> container:10080"
        echo "    Envoy Gateway maps: svc:443 -> container:10443"
        echo "    Fix: Change ports 80/443 to 10080/10443"
        FAILED=$((FAILED + 1))
    elif [[ "${HAS_CORRECT_PORTS}" == "true" ]]; then
        print_ok "NetworkPolicy ${NAME} uses correct container ports"
    else
        print_warn "NetworkPolicy ${NAME} has no HTTP/HTTPS ports defined"
    fi
done

echo ""
if [[ "${FAILED}" -gt 0 ]]; then
    echo "${FAILED} NetworkPolicy(ies) with wrong ports"
    exit "${EXIT_FAILURE}"
fi

exit "${EXIT_SUCCESS}"
