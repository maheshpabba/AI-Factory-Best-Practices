<#
.SYNOPSIS
  check-rdma-qos.ps1 -- verify DSCP trust + PFC marking on every ConnectX RDMA interface
  across a fleet of GPU worker nodes, via `mlnx_qos` run inside each node's mofed pod.

  Expected-healthy config (per network-Operator/backend-nic-qos-nic-config-template*.yaml):
    - Priority trust state: dscp
    - PFC enabled only on priority 3        (pfc: '0,0,0,1,0,0,0,0')

.PARAMETER Nodes
  Explicit list of node names to check. If omitted, auto-discovers nodes via -NodeRole.

.PARAMETER NodeRole
  Node role label to auto-discover nodes with (node-role.kubernetes.io/<role>). Default: gpuworker880

.PARAMETER Namespace
  Namespace the mofed-rhel* daemonset pods run in. Default: nvidia-network-operator

.EXAMPLE
  .\check-rdma-qos.ps1
.EXAMPLE
  .\check-rdma-qos.ps1 -Nodes worker2,worker3,worker4
.EXAMPLE
  .\check-rdma-qos.ps1 -NodeRole gpuworker880

  Requires: oc (logged in, available on PATH).
#>
param(
  [string[]]$Nodes,
  [string]$NodeRole = "gpuworker880",
  [string]$Namespace = "nvidia-network-operator"
)

$ExpectedTrust = "dscp"
$ExpectedPfc = "0   0   0   1   0   0   0   0"

# Fixed CX8 interface names -- same C880 hardware/PCIe layout on every node, confirmed via
# cluster-utility.sh -p iface:cx8 (8 cards x 2 ports = 16 interfaces)
$Cx8Interfaces = @(
  "eno10np0", "ens1f1np1", "eno13np0", "ens4f1np1",
  "eno11np0", "ens5f1np1", "eno7np0", "ens6f1np1",
  "eno9np0", "ens7f1np1", "eno8np0", "ens9f1np1",
  "eno6np0", "ens10f1np1", "eno12np0", "ens2f1np1"
)

if (-not $Nodes -or $Nodes.Count -eq 0) {
  $raw = & oc get nodes -l "node-role.kubernetes.io/$NodeRole" -o jsonpath='{.items[*].metadata.name}'
  $Nodes = $raw -split '\s+' | Where-Object { $_ -ne "" }
}

if (-not $Nodes -or $Nodes.Count -eq 0) {
  Write-Error "No nodes found/given. Pass -Nodes explicitly or set -NodeRole."
  exit 1
}

"{0,-14} {1,-14} {2,-8} {3,-24} {4,-8}" -f "NODE", "INTERFACE", "TRUST", "PFC-ENABLED(0-7)", "STATUS"
"{0,-14} {1,-14} {2,-8} {3,-24} {4,-8}" -f "----", "---------", "-----", "----------------", "------"

$failCount = 0
$totalCount = 0

foreach ($node in $Nodes) {
  $podLine = (& oc get pods -n $Namespace --field-selector "spec.nodeName=$node" -o name 2>$null) |
    Where-Object { $_ -match '^pod/mofed-' } | Select-Object -First 1

  if (-not $podLine) {
    Write-Warning "${node}: no mofed pod found, skipping"
    continue
  }
  $pod = $podLine -replace '^pod/', ''

  # Fixed CX8 interface list (see $Cx8Interfaces above) -- no per-node discovery needed
  $ifaces = $Cx8Interfaces

  foreach ($iface in $ifaces) {
    $iface = $iface.Trim()
    if ($iface -eq "") { continue }
    $totalCount++

    $out = & oc exec -n $Namespace $pod -- mlnx_qos -i $iface 2>$null

    $trustLine = ($out | Select-String "Priority trust state" | Select-Object -First 1).Line
    if ($trustLine -match 'Priority trust state:\s*(\S+)') {
      $trust = $Matches[1]
    } elseif ($trustLine) {
      $trust = "N/A"
    } else {
      $trust = "?"
    }

    $pfcLine = ($out | Select-String '^\s*enabled' | Select-Object -First 1)
    if ($pfcLine) {
      $pfcRow = ($pfcLine.Line.Trim() -replace '^enabled\s*', '').Trim()
    } else {
      $pfcRow = "?"
    }

    if ($trust -eq "N/A") {
      $status = "SKIP(unsupported)"
    } else {
      $status = "OK"
      if ($trust -ne $ExpectedTrust) { $status = "FAIL(trust=$trust)" }
      if ($pfcRow -ne $ExpectedPfc) { $status = "FAIL(pfc=[$pfcRow])" }
    }

    if ($status -like "FAIL*") { $failCount++ }

    "{0,-14} {1,-14} {2,-8} {3,-24} {4,-8}" -f $node, $iface, $trust, $pfcRow, $status
  }
}

""
"Checked $totalCount interfaces across $($Nodes.Count) node(s); $failCount mismatched."
if ($failCount -gt 0) { exit 1 }
exit 0
