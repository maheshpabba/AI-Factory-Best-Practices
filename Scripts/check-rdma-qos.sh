#!/usr/bin/env bash
# check-rdma-qos.sh -- verify DSCP trust + PFC marking on every ConnectX RDMA interface
# across a fleet of GPU worker nodes, via `mlnx_qos` run inside each node's mofed pod.
#
# Expected-healthy config (per network-Operator/backend-nic-qos-nic-config-template*.yaml):
#   - Priority trust state: dscp
#   - PFC enabled only on priority 3        (pfc: '0,0,0,1,0,0,0,0')
#
# Usage:
#   ./check-rdma-qos.sh                      # auto-discovers nodes with role gpuworker880
#   ./check-rdma-qos.sh worker2 worker3 worker4
#   NODE_ROLE=gpuworker880 ./check-rdma-qos.sh
#
# Requires: oc (logged in), cluster has the mofed-rhel* daemonset pods in nvidia-network-operator.

set -o pipefail

NAMESPACE="nvidia-network-operator"
NODE_ROLE="${NODE_ROLE:-gpuworker880}"
EXPECTED_TRUST="dscp"
EXPECTED_PFC="0   0   0   1   0   0   0   0"

# Fixed CX8 interface names -- same C880 hardware/PCIe layout on every node, confirmed via
# cluster-utility.sh -p iface:cx8 (8 cards x 2 ports = 16 interfaces)
CX8_INTERFACES=(eno10np0 ens1f1np1 eno13np0 ens4f1np1 eno11np0 ens5f1np1 eno7np0 ens6f1np1 \
  eno9np0 ens7f1np1 eno8np0 ens9f1np1 eno6np0 ens10f1np1 eno12np0 ens2f1np1)

if [[ $# -gt 0 ]]; then
  NODES=("$@")
else
  mapfile -t NODES < <(oc get nodes -l "node-role.kubernetes.io/${NODE_ROLE}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "No nodes found/given. Pass node names explicitly or set NODE_ROLE." >&2
  exit 1
fi

printf "%-14s %-14s %-8s %-24s %-8s\n" "NODE" "INTERFACE" "TRUST" "PFC-ENABLED(0-7)" "STATUS"
printf "%-14s %-14s %-8s %-24s %-8s\n" "----" "---------" "-----" "----------------" "------"

FAIL_COUNT=0
TOTAL_COUNT=0

for node in "${NODES[@]}"; do
  pod=$(oc get pods -n "$NAMESPACE" --field-selector "spec.nodeName=${node}" -o name 2>/dev/null | grep '^pod/mofed-' | head -1)
  if [[ -z "$pod" ]]; then
    echo "${node}: no mofed pod found, skipping" >&2
    continue
  fi

  # Fixed CX8 interface list (see CX8_INTERFACES above) -- no per-node discovery needed
  ifaces=$(printf '%s\n' "${CX8_INTERFACES[@]}")

  if [[ -z "$ifaces" ]]; then
    echo "${node}: no RDMA interfaces discovered, skipping" >&2
    continue
  fi

  while IFS= read -r iface; do
    [[ -z "$iface" ]] && continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    out=$(oc exec -n "$NAMESPACE" "$pod" -- mlnx_qos -i "$iface" 2>/dev/null)

    trust_line=$(echo "$out" | grep "Priority trust state")
    if echo "$trust_line" | grep -q ':'; then
      trust=$(echo "$trust_line" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    elif [[ -n "$trust_line" ]]; then
      trust="N/A"
    else
      trust="?"
    fi
    pfc_row=$(echo "$out" | awk '/^\s*enabled/{$1=""; print; exit}' | sed 's/^ *//')

    if [[ "$trust" == "N/A" ]]; then
      status="SKIP(unsupported)"
    else
      status="OK"
      [[ "$trust" != "$EXPECTED_TRUST" ]] && status="FAIL(trust=$trust)"
      [[ "$pfc_row" != "$EXPECTED_PFC" ]] && status="FAIL(pfc=[$pfc_row])"
    fi

    [[ "$status" == FAIL* ]] && FAIL_COUNT=$((FAIL_COUNT + 1))

    printf "%-14s %-14s %-8s %-24s %-8s\n" "$node" "$iface" "${trust:-?}" "${pfc_row:-?}" "$status"
  done <<< "$ifaces"
done

echo
echo "Checked ${TOTAL_COUNT} interfaces across ${#NODES[@]} node(s); ${FAIL_COUNT} mismatched."
[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
