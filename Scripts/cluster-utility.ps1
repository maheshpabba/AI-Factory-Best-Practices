#!/usr/bin/env pwsh
<#
.SYNOPSIS
  cluster-utility.ps1 -- OpenShift cluster NIC inventory + YAML artifact
  generator (Windows/PowerShell twin of cluster-utility.sh; kept functionally
  in sync).

.NOTES
  Author:  Mahesh Pabba
  Email:   mpabba@cisco.com
  Version: 0.6.0

.DESCRIPTION
  For each selected node, inspects host networking via `oc debug node/<node>`:
    - RDMA (mlx5_*) devices: device name, PCIe address, netdev interface,
      host-level IP (if any), and adapter model (ConnectX-7/8, BlueField, etc).
    - ALL host network interfaces: type, bond/bridge master, driver, PCIe
      adapter model, and IP address.
    - Bond member interfaces.
    - br-ex (OVN-Kubernetes external bridge) port membership.

  It can also generate, per the interfaces it finds:
    - NodeNetworkConfigurationPolicy (NNCP) YAMLs

  Two modes:
    1) Non-interactive / scriptable: pass -Nodes/-Print/-Generate (and
       optional tuning parameters) and it runs silently, no prompts.
    2) Interactive wizard: run with none of those and it walks you through
       node selection, then an hdblcm-style "Print / Generate" menu.

  Before anything else, this script verifies cluster connectivity with
  `oc get nodes` and errors out (telling you to `oc login`) if that fails.

.PARAMETER Nodes
  Comma-separated node names, or "all" for every cluster node.

.PARAMETER Roles
  Comma-separated node-role names, matched against the
  "node-role.kubernetes.io/<role>" label (what 'oc get nodes' shows under
  ROLES). Combines with -Nodes (union of both, deduped).

.PARAMETER Print
  Comma-separated print codes: pcie, rdma, table, cx8, cx7, net, bond, br-ex, all

.PARAMETER Generate
  Comma-separated artifact codes to generate: nncp

.PARAMETER Family
  Which interfaces to use for generation: cx8 (default), cx7, all

.PARAMETER Ifaces
  Custom space/comma separated interface list (overrides -Family)

.PARAMETER Mtu
  MTU for generated YAMLs (default 9000)

.PARAMETER NncpDir
  NNCP output directory (default "NNCP")

.EXAMPLE
  ./cluster-utility.ps1

.EXAMPLE
  ./cluster-utility.ps1 -Nodes all -Print pcie,cx8

.EXAMPLE
  ./cluster-utility.ps1 -Roles gpuworker880 -Print pcie,cx8

.EXAMPLE
  ./cluster-utility.ps1 -Nodes worker3,worker4 -Print all -Generate nncp -Family cx8

#>
[CmdletBinding()]
param(
  [string]$Nodes = "",
  [string]$Roles = "",
  [string]$Print = "",
  [string]$Generate = "",
  [string]$Family = "cx8",
  [string]$Ifaces = "",
  [string]$Mtu = "9000",
  [string]$NncpDir = "NNCP",
  [string]$TestPrep = "",
  [string]$NvcreNamespace = "default",
  [switch]$NvcreAirgapped,
  [switch]$NvcreArpFix,
  [string]$NvcreImage = "registry.redhat.io/ubi9/python-312-minimal:latest",
  [string]$NvcreWorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) "nvcre-wh"),
  [Alias("h")][switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
@"
Usage: cluster-utility.ps1 [-Nodes <list>] [-Print <codes>] [-Generate <codes>] [options]

Inventories host networking on one or more OpenShift nodes (via
'oc debug node/<node>'), and optionally generates NodeNetworkConfigurationPolicy
(NNCP) YAML artifacts from the interfaces it finds.

Before doing anything, it verifies cluster connectivity by running
'oc get nodes'; if that fails, it errors out and tells you to 'oc login' first.

NON-INTERACTIVE MODE (any of -Nodes/-Roles/-Print/-Generate given -> runs silently, no prompts):
  -Nodes <list>     Comma-separated node names, or "all" for every cluster node.
                    e.g. -Nodes all   or   -Nodes worker3,worker4
  -Roles <list>     Comma-separated node-role names, matched against the
                    "node-role.kubernetes.io/<role>" label (what 'oc get nodes'
                    shows under ROLES). e.g. -Roles gpuworker880
                    Combines with -Nodes (union of both, deduped).
  -Print <codes>    Comma-separated print codes (any combination). device,
                    pcie and iface accept an optional ":<family>" sub-code
                    (family is one of cx7, cx8, bf, all; default: all):
                      device[:family]   RDMA device names (comma list, e.g. mlx5_0)
                      pcie[:family]     PCIe addresses (comma list)
                      iface[:family]    Interface names (comma list, e.g. eno10np0)
                      table             Full RDMA device table (always unfiltered)
                      net               All host network interfaces (bonds/br-ex/IPs)
                      bond              Bond membership
                      br-ex             br-ex (OVN-Kubernetes) port membership
                      all               Everything above (device/pcie/iface with
                                        family=all, plus table/net/bond/br-ex)
                    families: cx7 = standalone ConnectX-7, cx8 = ConnectX-8,
                    bf = BlueField (any generation, e.g. BlueField-3/ConnectX-7),
                    all = no filter.
                    e.g. -Print device:cx8,pcie:bf,iface:cx7,table,bond
  -Generate <codes> Comma-separated artifact codes to generate:
                      nncp        NodeNetworkConfigurationPolicy YAMLs

  Tuning parameters for -Generate (all optional):
  -Family <cx8|cx7|all>   Which interfaces to use (default: cx8)
  -Ifaces "<names>"       Custom space/comma separated interface list (overrides -Family)
  -Mtu <n>                MTU (default: 9000)
  -NncpDir <dir>          NNCP output directory (default: NNCP)

  -TestPrep <mode>  Nvidia Cluster Readiness test prepare/check. Runs standalone
                    (ignores -Nodes/-Roles/-Print/-Generate). Installs (or removes)
                    everything needed for nvcrectl's WorkloadRun/Certification
                    "node" pods to get a privileged security context and the
                    macvlan RDMA networks attached, via a small mutating
                    admission webhook -- so users only ever have to run
                    nvcrectl itself, never touch certs/webhooks/SCCs by hand.
                    Modes:
                      prepare   Generate a self-signed TLS cert, create the
                                Secret/ConfigMap/Deployment/Service, register
                                the MutatingWebhookConfiguration with a fresh
                                caBundle, label the namespace, grant the SCCs,
                                and run a smoke test pod to confirm it works.
                      cleanup   Reverse everything prepare did (webhook config,
                                Deployment/Service/Secret/ConfigMap, namespace
                                label, SCC grants) once testing is finished.
                      status    Show whether prepare's objects are currently
                                present, without changing anything.
                    e.g. -TestPrep prepare   or   -TestPrep cleanup

  Tuning parameters for -TestPrep (all optional):
  -NvcreNamespace <ns>   Namespace nvcrectl runs test pods in (default: default)
  -NvcreAirgapped        Force the air-gapped webhook variant (injects Cisco proxy
                         env vars into test pods). Auto-detected by default via
                         'oc get proxy cluster' -- only needed to override that.
  -NvcreArpFix           Also apply the ARP/RPF sysctl postStart fix for
                         multi-homed RoCE NICs (default: off)
  -NvcreImage <image>    Webhook server base image
                         (default: registry.redhat.io/ubi9/python-312-minimal:latest)
  -NvcreWorkDir <dir>    Scratch dir for generated TLS material (default: temp dir)

INTERACTIVE MODE (none of -Nodes/-Roles/-Print/-Generate given):
  Walks you through node selection (discover from cluster, select by role
  label, or enter manually), then an hdblcm-style menu: 1) Print information
  to console  2) Generate YAML artifacts -- each with its own numbered
  sub-menu -- followed by a summary and confirmation before anything runs.

Examples:
  ./cluster-utility.ps1
  ./cluster-utility.ps1 -Nodes all -Print pcie:cx8,device:cx8
  ./cluster-utility.ps1 -Roles gpuworker880 -Print iface:bf,table
  ./cluster-utility.ps1 -Nodes worker3,worker4 -Print all -Generate nncp -Family cx8
  ./cluster-utility.ps1 -TestPrep prepare -NvcreNamespace default
  ./cluster-utility.ps1 -TestPrep cleanup -NvcreNamespace default
"@ | Write-Host
  exit 0
}

$CliModeActive = ($Nodes -ne "") -or ($Roles -ne "") -or ($Print -ne "") -or ($Generate -ne "")

# ---------------------------------------------------------------------------
# Small hdblcm-style prompt helpers
# ---------------------------------------------------------------------------
function Write-Hr { Write-Host ("-" * 76) }

function Write-StepTitle([string]$Title) {
  Write-Host ""
  Write-Hr
  Write-Host "  $Title"
  Write-Hr
}

function Confirm-OcLogin {
  if (-not $CliModeActive) {
    Write-StepTitle "Cluster connectivity check"
    Write-Host "Running 'oc get nodes' ..."
  }
  & oc get nodes *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Error "'oc get nodes' failed -- you are not logged in to an OpenShift cluster (or your current context/token is invalid or lacks permissions). Run 'oc login ...' first, then re-run this script."
    exit 1
  }
  if (-not $CliModeActive) { Write-Host "OK -- cluster is reachable." }
}

# Ask-YesNo "<prompt>" "<y|n default>" -> returns "y" or "n"
function Ask-YesNo([string]$Prompt, [string]$Default = "y") {
  $suffix = if ($Default -eq "n") { "[y/N]" } else { "[Y/n]" }
  while ($true) {
    $ans = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
    if ($ans -match '^[Yy]') { return "y" }
    if ($ans -match '^[Nn]') { return "n" }
    Write-Host "Please answer y or n."
  }
}

# Ask-Value "<prompt>" "<default>" -> returns the entered (or default) value
function Ask-Value([string]$Prompt, [string]$Default) {
  $ans = Read-Host "$Prompt [$Default]"
  if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
  return $ans
}

# Ask-SingleChoice "<prompt>" <defaultNumber> <options[]> -> returns 1-based index (int)
function Ask-SingleChoice([string]$Prompt, [int]$Default, [string[]]$Options) {
  Write-Host ""
  Write-Host $Prompt
  for ($i = 0; $i -lt $Options.Count; $i++) {
    "{0,3}) {1}" -f ($i + 1), $Options[$i] | Write-Host
  }
  while ($true) {
    $ans = Read-Host "Select [1-$($Options.Count)] (default $Default)"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
    if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $Options.Count) {
      return [int]$ans
    }
    Write-Host "Invalid selection, try again."
  }
}

# Ask-MultiChoice "<prompt>" <options[]> -> returns int[] of 1-based picks
function Ask-MultiChoice([string]$Prompt, [string[]]$Options) {
  Write-Host ""
  Write-Host $Prompt
  for ($i = 0; $i -lt $Options.Count; $i++) {
    "{0,3}) {1}" -f ($i + 1), $Options[$i] | Write-Host
  }
  Write-Host "  (comma-separated numbers, e.g. 1,3,4)"
  while ($true) {
    $ans = Read-Host "Select"
    if ([string]::IsNullOrWhiteSpace($ans)) {
      Write-Host "Please select at least one option."
      continue
    }
    $picks = $ans -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $ok = $true
    foreach ($p in $picks) {
      if ($p -notmatch '^\d+$' -or [int]$p -lt 1 -or [int]$p -gt $Options.Count) { $ok = $false; break }
    }
    if ($ok) { return [int[]]($picks | ForEach-Object { [int]$_ }) }
    Write-Host "Invalid selection, try again."
  }
}

function Test-MultiHas([int[]]$Picks, [int]$Target) {
  return ($Picks -contains $Target)
}

# ---------------------------------------------------------------------------
# CLI-mode resolvers: turn comma-separated codes into the same flags/vars the
# interactive wizard would have produced.
# ---------------------------------------------------------------------------

function Resolve-NodesFromArg([string]$Csv) {
  $items = $Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
  $wantAll = $false
  $result = New-Object System.Collections.Generic.List[string]
  foreach ($item in $items) {
    if ($item.ToLower() -eq "all") {
      $wantAll = $true
    } elseif (-not $result.Contains($item)) {
      $result.Add($item)
    }
  }
  if ($wantAll) {
    $discovered = & oc get nodes -o custom-columns=NAME:.metadata.name --no-headers 2>$null |
      Where-Object { $_ -ne "" } | Sort-Object
    if (-not $discovered) {
      Write-Error "'oc get nodes' returned nothing; cannot resolve '-Nodes all'."
      exit 1
    }
    return @($discovered)
  }
  return @($result)
}

function Resolve-RolesFromArg([string]$Csv) {
  $roles = $Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
  $result = New-Object System.Collections.Generic.List[string]
  foreach ($role in $roles) {
    $matched = @(& oc get nodes -l "node-role.kubernetes.io/$role" -o custom-columns=NAME:.metadata.name --no-headers 2>$null |
      Where-Object { $_ -ne "" })
    if ($matched.Count -eq 0) {
      Write-Warning "no nodes found with role '$role' (label node-role.kubernetes.io/$role)."
      continue
    }
    foreach ($n in $matched) {
      if (-not $result.Contains($n)) { $result.Add($n) }
    }
  }
  return @($result)
}

function Resolve-Family([string]$Raw) {
  switch ($Raw.ToLower()) {
    "" { return "all" }
    "cx7" { return "cx7" }
    "connectx-7" { return "cx7" }
    "connectx7" { return "cx7" }
    "cx8" { return "cx8" }
    "connectx-8" { return "cx8" }
    "connectx8" { return "cx8" }
    "bf" { return "bf" }
    "bluefield" { return "bf" }
    "all" { return "all" }
    default { Write-Warning "unknown family '$Raw', defaulting to 'all'."; return "all" }
  }
}

function Resolve-PrintFlagsFromArg([string]$Csv) {
  $items = $Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
  foreach ($item in $items) {
    $parts = $item -split ':', 2
    $code = $parts[0].ToLower()
    $fam = if ($parts.Count -gt 1) { Resolve-Family $parts[1] } else { "all" }
    switch ($code) {
      "device" { $script:PrintDevice = $true; $script:PrintDeviceFamily = $fam }
      "devices" { $script:PrintDevice = $true; $script:PrintDeviceFamily = $fam }
      "rdma" { $script:PrintDevice = $true; $script:PrintDeviceFamily = $fam }
      "pcie" { $script:PrintPcie = $true; $script:PrintPcieFamily = $fam }
      "iface" { $script:PrintIface = $true; $script:PrintIfaceFamily = $fam }
      "interface" { $script:PrintIface = $true; $script:PrintIfaceFamily = $fam }
      "interfaces" { $script:PrintIface = $true; $script:PrintIfaceFamily = $fam }
      "cx8" { $script:PrintIface = $true; $script:PrintIfaceFamily = "cx8" }
      "cx7" { $script:PrintIface = $true; $script:PrintIfaceFamily = "cx7" }
      "bf" { $script:PrintIface = $true; $script:PrintIfaceFamily = "bf" }
      "table" { $script:PrintTable = $true }
      "net" { $script:PrintAllNet = $true }
      "allnet" { $script:PrintAllNet = $true }
      "bond" { $script:PrintBond = $true }
      "bonds" { $script:PrintBond = $true }
      "br-ex" { $script:PrintOvs = $true }
      "brex" { $script:PrintOvs = $true }
      "ovs" { $script:PrintOvs = $true }
      "all" {
        $script:PrintDevice = $true; $script:PrintDeviceFamily = "all"
        $script:PrintPcie = $true; $script:PrintPcieFamily = "all"
        $script:PrintIface = $true; $script:PrintIfaceFamily = "all"
        $script:PrintTable = $true; $script:PrintAllNet = $true
        $script:PrintBond = $true; $script:PrintOvs = $true
      }
      "everything" {
        $script:PrintDevice = $true; $script:PrintDeviceFamily = "all"
        $script:PrintPcie = $true; $script:PrintPcieFamily = "all"
        $script:PrintIface = $true; $script:PrintIfaceFamily = "all"
        $script:PrintTable = $true; $script:PrintAllNet = $true
        $script:PrintBond = $true; $script:PrintOvs = $true
      }
      default { Write-Warning "unknown -Print code '$item', ignoring." }
    }
  }
}

function Resolve-GenerateFlagsFromArg([string]$Csv) {
  $items = $Csv -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne "" }
  foreach ($item in $items) {
    switch ($item) {
      "nncp" { $script:GenNncp = $true }
      "all" { $script:GenNncp = $true }
      "both" { $script:GenNncp = $true }
      default { Write-Warning "unknown -Generate code '$item', ignoring." }
    }
  }
}

# ---------------------------------------------------------------------------
# YAML-writing functions
# ---------------------------------------------------------------------------

# New-NncpYaml <outputDir> <mtu> <node> <iface[]>
# Writes one NodeNetworkConfigurationPolicy (nmstate.io/v1) per interface,
# named "<node>-<iface>-mtu<mtu>" (ethernet, up).
function New-NncpYaml([string]$OutDir, [string]$NncpMtu, [string]$Node, [string[]]$IfaceList) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  foreach ($iface in $IfaceList) {
    if ([string]::IsNullOrWhiteSpace($iface) -or $iface -eq "-") { continue }
    $name = "$Node-$iface-mtu$NncpMtu"
    $file = Join-Path $OutDir "$name.yaml"
    $content = @"
# Use this YAML as Template
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: $name
spec:
  desiredState:
    interfaces:
      - mtu: $NncpMtu
        name: $iface
        state: up
        type: ethernet
  nodeSelector:
    kubernetes.io/hostname: $Node
"@
    Set-Content -Path $file -Value $content -NoNewline:$false
    Write-Host "Wrote $file"
  }
}

# ---------------------------------------------------------------------------
# NVIDIA Cluster Readiness Engine (nvcrectl) test preparation / cleanup.
#
# nvcrectl's own WorkloadRun/Certification CRDs have no hook to request a
# privileged security context or attach extra macvlan RDMA networks on the
# "node" pods they launch. A small mutating admission webhook
# (privileged-injector) patches those pods on CREATE instead. This section
# creates (prepare) or tears down (cleanup) everything that webhook needs --
# self-signed TLS cert, Secret/ConfigMap, Deployment/Service, a
# MutatingWebhookConfiguration with a fresh caBundle, the nvcre-proxy-inject
# namespace label, and the SCC grants the patched pods need -- so a user only
# ever has to run nvcrectl itself.
#
# Embedded webhook source mirrors the current, actively-maintained copy under
# nvcre-workloadruns/results-10212026/nvls-reconciliation/webhook-source/
# (webhook.py / webhook_airgapped.py) -- not nvcre-workloadruns/webhook/ or
# lab.md, which may be out of date.
# ---------------------------------------------------------------------------

$WebhookPySrc = @'
#!/usr/bin/env python3
"""Minimal, stdlib-only mutating admission webhook for lab-only use.

Patches only pods whose metadata.generateName does NOT contain "launcher"
(i.e. NVCRE's MPI "node" worker pods):
  1. k8s.v1.cni.cncf.io/networks annotation listing all 16 macvlan NADs (one per
     GPU rail NIC, 2 per GPU via PXB) so RoCE GID/ARP resolution has a netdevice
     to resolve against for every HCA -- the RDMA shared-device-plugin exposes
     /dev/infiniband verbs devices but not a netdev in the pod netns, which
     ibv_create_ah needs.
  2. (optional, off by default) a postStart lifecycle hook that applies the
     ARP/RPF sysctl fix (arp_ignore/arp_announce/rp_filter) for multi-homed RoCE
     NICs on one subnet -- see INJECT_ARP_FIX below. Also sets securityContext.
     privileged=true, since CRI-O masks /proc/sys/net/* read-only otherwise
     regardless of capabilities granted -- this is a CRI-O constraint, not the
     SYS_CHROOT gap nvcrectl v0.7.0+ already fixes natively, so there is no
     separate INJECT_PRIVILEGED toggle.
Does NOT inject proxy env or mount /etc/nccl.conf -- neither is needed here.
"""
import base64
import json
import os
import ssl
from http.server import BaseHTTPRequestHandler, HTTPServer

# Toggle for reproducing the pre-fix failure on demand.
# Set INJECT_NAD=false on the Deployment to skip the NAD annotation while still
# patching privileged:true, isolating the "No such device" NIC issue from chroot.
INJECT_NAD = os.environ.get("INJECT_NAD", "true").lower() != "false"

# Off by default: applies the ARP/RPF fix (proven in nemotron-w3w4-1m's train.sh
# and the hand-rolled multi-node-nccl MPIJob) via a postStart hook on NVCRE's own
# node pods, since WorkloadRun/Certification have no init-container/script hook
# of their own. Also sets securityContext.privileged=true, since CRI-O masks
# /proc/sys/net/* read-only otherwise regardless of capabilities granted.
INJECT_ARP_FIX = os.environ.get("INJECT_ARP_FIX", "false").lower() == "true"

ARP_FIX_CMD = (
    "for d in /proc/sys/net/ipv4/conf/*/; do "
    "echo 1 > \"${d}arp_ignore\" 2>/dev/null || true; "
    "echo 2 > \"${d}arp_announce\" 2>/dev/null || true; "
    "echo 0 > \"${d}rp_filter\" 2>/dev/null || true; "
    "done"
)

PATCH_ARP_FIX_SECURITY_CONTEXT = {
    "op": "add",
    "path": "/spec/containers/0/securityContext",
    "value": {"privileged": True, "capabilities": {"add": ["IPC_LOCK"]}},
}

PATCH_ARP_FIX_LIFECYCLE = {
    "op": "add",
    "path": "/spec/containers/0/lifecycle",
    "value": {"postStart": {"exec": {"command": ["/bin/sh", "-c", ARP_FIX_CMD]}}},
}

# One NAD per GPU rail NIC, confirmed via sysfs on worker3
# (mlx5_X -> netdev) cross-referenced against `nvidia-smi topo -m` PXB pairs.
MACVLAN_NETWORKS = ",".join([
    "be-mac-vlan-network-eno10np0",  # GPU0 / mlx5_0
    "be-mac-vlan-network-ens1f1np1",  # GPU0 / mlx5_1
    "be-mac-vlan-network-eno12np0",  # GPU1 / mlx5_6
    "be-mac-vlan-network-ens2f1np1",  # GPU1 / mlx5_7
    "be-mac-vlan-network-eno13np0",  # GPU2 / mlx5_10
    "be-mac-vlan-network-ens4f1np1",  # GPU2 / mlx5_11
    "be-mac-vlan-network-eno11np0",  # GPU3 / mlx5_12
    "be-mac-vlan-network-ens5f1np1",  # GPU3 / mlx5_13
    "be-mac-vlan-network-eno7np0",  # GPU4 / mlx5_14
    "be-mac-vlan-network-ens6f1np1",  # GPU4 / mlx5_15
    "be-mac-vlan-network-eno9np0",  # GPU5 / mlx5_16
    "be-mac-vlan-network-ens7f1np1",  # GPU5 / mlx5_17
    "be-mac-vlan-network-eno8np0",  # GPU6 / mlx5_20
    "be-mac-vlan-network-ens9f1np1",  # GPU6 / mlx5_21
    "be-mac-vlan-network-eno6np0",  # GPU7 / mlx5_22
    "be-mac-vlan-network-ens10f1np1",  # GPU7 / mlx5_23
])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        review = json.loads(body)
        req = review["request"]
        pod = req["object"]
        metadata = pod.get("metadata", {})
        generate_name = metadata.get("generateName", "")

        patch_b64 = None
        labels = metadata.get("labels", {})
        is_self = labels.get("app") == "privileged-injector"
        if "launcher" not in generate_name and not is_self:
            patch = []
            if INJECT_ARP_FIX:
                patch.append(PATCH_ARP_FIX_SECURITY_CONTEXT)
                patch.append(PATCH_ARP_FIX_LIFECYCLE)
            if INJECT_NAD:
                if metadata.get("annotations"):
                    patch.append({
                        "op": "add",
                        "path": "/metadata/annotations/k8s.v1.cni.cncf.io~1networks",
                        "value": MACVLAN_NETWORKS,
                    })
                else:
                    patch.append({
                        "op": "add",
                        "path": "/metadata/annotations",
                        "value": {"k8s.v1.cni.cncf.io/networks": MACVLAN_NETWORKS},
                    })
            if patch:
                patch_b64 = base64.b64encode(json.dumps(patch).encode()).decode()

        response = {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": req["uid"],
                "allowed": True,
            },
        }
        if patch_b64:
            response["response"]["patchType"] = "JSONPatch"
            response["response"]["patch"] = patch_b64

        out = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


if __name__ == "__main__":
    httpd = HTTPServer(("0.0.0.0", 8443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile="/tls/tls.crt", keyfile="/tls/tls.key")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print("webhook listening on :8443")
    httpd.serve_forever()
'@

$WebhookAirgappedPySrc = @'
#!/usr/bin/env python3
"""Minimal, stdlib-only mutating admission webhook for lab-only use (air-gapped variant).

Same as webhook.py, plus injects the Cisco proxy env vars into "node" pods so
outbound registry/package pulls work from inside the air-gapped cluster.

Patches only pods whose metadata.generateName does NOT contain "launcher"
(i.e. NVCRE's MPI "node" worker pods):
  1. k8s.v1.cni.cncf.io/networks annotation listing all 16 macvlan NADs (one per
     GPU rail NIC, 2 per GPU via PXB) so RoCE GID/ARP resolution has a netdevice
     to resolve against for every HCA -- the RDMA shared-device-plugin exposes
     /dev/infiniband verbs devices but not a netdev in the pod netns, which
     ibv_create_ah needs.
  2. http_proxy/https_proxy/no_proxy (+ uppercase variants) env vars, appended
     to the container's existing env list (never replaces it).
  3. (optional, off by default) a postStart lifecycle hook that applies the
     ARP/RPF sysctl fix (arp_ignore/arp_announce/rp_filter) for multi-homed RoCE
     NICs on one subnet -- see INJECT_ARP_FIX below. Also sets securityContext.
     privileged=true, since CRI-O masks /proc/sys/net/* read-only otherwise
     regardless of capabilities granted -- this is a CRI-O constraint, not the
     SYS_CHROOT gap nvcrectl v0.7.0+ already fixes natively, so there is no
     separate INJECT_PRIVILEGED toggle.
Does NOT mount /etc/nccl.conf -- not needed here.
"""
import base64
import json
import os
import ssl
from http.server import BaseHTTPRequestHandler, HTTPServer

# Toggle for reproducing the pre-fix failure on demand.
# Set INJECT_NAD=false on the Deployment to skip the NAD annotation while still
# patching privileged:true, isolating the "No such device" NIC issue from chroot.
INJECT_NAD = os.environ.get("INJECT_NAD", "true").lower() != "false"

# Toggle for the proxy env injection this variant adds. Default on, since this
# file only exists to be deployed in the air-gapped setup.
INJECT_PROXY = os.environ.get("INJECT_PROXY", "true").lower() != "false"

# Off by default: applies the ARP/RPF fix (proven in nemotron-w3w4-1m's train.sh
# and the hand-rolled multi-node-nccl MPIJob) via a postStart hook on NVCRE's own
# node pods, since WorkloadRun/Certification have no init-container/script hook
# of their own. Also sets securityContext.privileged=true, since CRI-O masks
# /proc/sys/net/* read-only otherwise regardless of capabilities granted.
INJECT_ARP_FIX = os.environ.get("INJECT_ARP_FIX", "false").lower() == "true"

ARP_FIX_CMD = (
    "for d in /proc/sys/net/ipv4/conf/*/; do "
    "echo 1 > \"${d}arp_ignore\" 2>/dev/null || true; "
    "echo 2 > \"${d}arp_announce\" 2>/dev/null || true; "
    "echo 0 > \"${d}rp_filter\" 2>/dev/null || true; "
    "done"
)

PATCH_ARP_FIX_SECURITY_CONTEXT = {
    "op": "add",
    "path": "/spec/containers/0/securityContext",
    "value": {"privileged": True, "capabilities": {"add": ["IPC_LOCK"]}},
}

PATCH_ARP_FIX_LIFECYCLE = {
    "op": "add",
    "path": "/spec/containers/0/lifecycle",
    "value": {"postStart": {"exec": {"command": ["/bin/sh", "-c", ARP_FIX_CMD]}}},
}

# One NAD per GPU rail NIC, confirmed via sysfs on worker3
# (mlx5_X -> netdev) cross-referenced against `nvidia-smi topo -m` PXB pairs.
MACVLAN_NETWORKS = ",".join([
    "be-mac-vlan-network-eno10np0",  # GPU0 / mlx5_0
    "be-mac-vlan-network-ens1f1np1",  # GPU0 / mlx5_1
    "be-mac-vlan-network-eno12np0",  # GPU1 / mlx5_6
    "be-mac-vlan-network-ens2f1np1",  # GPU1 / mlx5_7
    "be-mac-vlan-network-eno13np0",  # GPU2 / mlx5_10
    "be-mac-vlan-network-ens4f1np1",  # GPU2 / mlx5_11
    "be-mac-vlan-network-eno11np0",  # GPU3 / mlx5_12
    "be-mac-vlan-network-ens5f1np1",  # GPU3 / mlx5_13
    "be-mac-vlan-network-eno7np0",  # GPU4 / mlx5_14
    "be-mac-vlan-network-ens6f1np1",  # GPU4 / mlx5_15
    "be-mac-vlan-network-eno9np0",  # GPU5 / mlx5_16
    "be-mac-vlan-network-ens7f1np1",  # GPU5 / mlx5_17
    "be-mac-vlan-network-eno8np0",  # GPU6 / mlx5_20
    "be-mac-vlan-network-ens9f1np1",  # GPU6 / mlx5_21
    "be-mac-vlan-network-eno6np0",  # GPU7 / mlx5_22
    "be-mac-vlan-network-ens10f1np1",  # GPU7 / mlx5_23
])

# Cisco air-gapped proxy -- see NewProposedDesign docs / cluster proxy config.
PROXY_URL = os.environ.get("PROXY_URL", "http://173.36.224.108:80/")
NO_PROXY_VALUE = os.environ.get(
    "NO_PROXY_VALUE", "localhost,127.0.0.1,.svc,.cluster.local,10.0.0.0/8"
)
PROXY_ENV = [
    {"name": "http_proxy", "value": PROXY_URL},
    {"name": "https_proxy", "value": PROXY_URL},
    {"name": "no_proxy", "value": NO_PROXY_VALUE},
    {"name": "HTTP_PROXY", "value": PROXY_URL},
    {"name": "HTTPS_PROXY", "value": PROXY_URL},
    {"name": "NO_PROXY", "value": NO_PROXY_VALUE},
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        review = json.loads(body)
        req = review["request"]
        pod = req["object"]
        metadata = pod.get("metadata", {})
        generate_name = metadata.get("generateName", "")

        patch_b64 = None
        labels = metadata.get("labels", {})
        is_self = labels.get("app") == "privileged-injector"
        if "launcher" not in generate_name and not is_self:
            patch = []
            if INJECT_ARP_FIX:
                patch.append(PATCH_ARP_FIX_SECURITY_CONTEXT)
                patch.append(PATCH_ARP_FIX_LIFECYCLE)
            if INJECT_NAD:
                if metadata.get("annotations"):
                    patch.append({
                        "op": "add",
                        "path": "/metadata/annotations/k8s.v1.cni.cncf.io~1networks",
                        "value": MACVLAN_NETWORKS,
                    })
                else:
                    patch.append({
                        "op": "add",
                        "path": "/metadata/annotations",
                        "value": {"k8s.v1.cni.cncf.io/networks": MACVLAN_NETWORKS},
                    })
            # Build ONE combined list of env vars to inject, then apply a single
            # add-or-append patch -- two separate "add" ops at the same path
            # would make the second silently overwrite the first when the pod
            # has no pre-existing env field (true for v0.7.0 catalog pods).
            extra_env = []
            if INJECT_PROXY:
                extra_env.extend(PROXY_ENV)
            if extra_env:
                containers = pod.get("spec", {}).get("containers", [{}])
                existing_env = containers[0].get("env") if containers else None
                if existing_env:
                    # Append each var individually so the container's own env
                    # (NCCL tuning, rank info, etc.) is never overwritten.
                    for var in extra_env:
                        patch.append({
                            "op": "add",
                            "path": "/spec/containers/0/env/-",
                            "value": var,
                        })
                else:
                    patch.append({
                        "op": "add",
                        "path": "/spec/containers/0/env",
                        "value": extra_env,
                    })
            if patch:
                patch_b64 = base64.b64encode(json.dumps(patch).encode()).decode()

        response = {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": req["uid"],
                "allowed": True,
            },
        }
        if patch_b64:
            response["response"]["patchType"] = "JSONPatch"
            response["response"]["patch"] = patch_b64

        out = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


if __name__ == "__main__":
    httpd = HTTPServer(("0.0.0.0", 8443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile="/tls/tls.crt", keyfile="/tls/tls.key")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print("webhook listening on :8443")
    httpd.serve_forever()
'@

function ConvertTo-NvcreMwcYaml([string]$Svc, [string]$Ns, [string]$CaBundle) {
  return @"
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: nvcre-privileged-injector
webhooks:
  - name: $Svc.$Ns.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Ignore
    timeoutSeconds: 5
    clientConfig:
      service:
        name: $Svc
        namespace: $Ns
        path: /mutate
        port: 443
      caBundle: $CaBundle
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "Namespaced"
    namespaceSelector:
      matchLabels:
        nvcre-proxy-inject: "true"
    objectSelector: {}
"@
}

function ConvertTo-NvcreDeploymentYaml([string]$Svc, [string]$Ns, [string]$Image, [string]$InjectArp) {
  return @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $Svc
  namespace: $Ns
  labels:
    app: $Svc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $Svc
  template:
    metadata:
      labels:
        app: $Svc
    spec:
      containers:
        - name: webhook
          image: $Image
          command: ["python3", "/code/webhook.py"]
          env:
            - name: INJECT_NAD
              value: "true"
            - name: INJECT_PROXY
              value: "true"
            - name: INJECT_ARP_FIX
              value: "$InjectArp"
          ports:
            - containerPort: 8443
          volumeMounts:
            - name: tls
              mountPath: /tls
              readOnly: true
            - name: code
              mountPath: /code
              readOnly: true
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
      volumes:
        - name: tls
          secret:
            secretName: webhook-tls
        - name: code
          configMap:
            name: webhook-code
---
apiVersion: v1
kind: Service
metadata:
  name: $Svc
  namespace: $Ns
  labels:
    app: $Svc
spec:
  selector:
    app: $Svc
  ports:
    - port: 443
      targetPort: 8443
"@
}

# Install-NvcrePrep -- installs everything nvcrectl's node pods need
# (TLS cert, Secret/ConfigMap, Deployment/Service, MutatingWebhookConfiguration,
# namespace label, SCC grants), then smoke-tests it.
function Install-NvcrePrep {
  $ns = $NvcreNamespace
  $workdir = $NvcreWorkDir
  $image = $NvcreImage
  $svc = "privileged-injector"
  $argFix = if ($NvcreArpFix) { "true" } else { "false" }

  Write-StepTitle "NVIDIA Cluster Readiness test preparation (namespace: $ns)"

  New-Item -ItemType Directory -Force -Path $workdir | Out-Null
  $srcFile = Join-Path $workdir "webhook.py"

  $useAirgapped = $NvcreAirgapped.IsPresent
  if (-not $PSBoundParameters.ContainsKey('NvcreAirgapped')) {
    # Auto-detect: a cluster-wide Proxy object with httpProxy/httpsProxy set means
    # outbound traffic (registry pulls, package installs) must go through a proxy --
    # the signature of an air-gapped cluster like this one.
    $proxyCfg = & oc get proxy cluster -o jsonpath='{.spec.httpProxy}{.spec.httpsProxy}' 2>$null
    if ($proxyCfg) {
      $useAirgapped = $true
      Write-Host "Detected a cluster-wide proxy (oc get proxy cluster) -- using the air-gapped webhook variant."
    } else {
      $useAirgapped = $false
    }
  }

  if ($useAirgapped) {
    if ($PSBoundParameters.ContainsKey('NvcreAirgapped')) { Write-Host "Using air-gapped webhook variant (forced via -NvcreAirgapped)." }
    Set-Content -Path $srcFile -Value $WebhookAirgappedPySrc -NoNewline:$false
  } else {
    Set-Content -Path $srcFile -Value $WebhookPySrc -NoNewline:$false
  }

  Write-Host "1/7 Generating self-signed TLS CA + server certificate (CN=$svc.$ns.svc) ..."
  $caKey = Join-Path $workdir "ca.key"; $caCrt = Join-Path $workdir "ca.crt"
  $tlsKey = Join-Path $workdir "tls.key"; $csr = Join-Path $workdir "server.csr"
  $tlsCrt = Join-Path $workdir "tls.crt"
  $extFile = Join-Path $workdir "san.ext"
  Set-Content -Path $extFile -Value "subjectAltName=DNS:$svc.$ns.svc,DNS:$svc.$ns.svc.cluster.local" -NoNewline

  & openssl req -x509 -newkey rsa:2048 -nodes -keyout $caKey -out $caCrt -days 3650 -subj "/CN=nvcre-webhook-ca" 2>$null
  & openssl req -newkey rsa:2048 -nodes -keyout $tlsKey -out $csr -subj "/CN=$svc.$ns.svc" 2>$null
  & openssl x509 -req -in $csr -CA $caCrt -CAkey $caKey -CAcreateserial -out $tlsCrt -days 3650 -extfile $extFile 2>$null
  if (-not (Test-Path $tlsCrt) -or (Get-Item $tlsCrt).Length -eq 0) {
    Write-Error "TLS certificate generation failed -- is 'openssl' installed and on PATH?"
    return 1
  }

  Write-Host "2/7 Creating Secret/ConfigMap and labeling namespace '$ns' ..."
  & oc create secret tls webhook-tls -n $ns --cert=$tlsCrt --key=$tlsKey --dry-run=client -o yaml | & oc apply -f - | Out-Null
  & oc create configmap webhook-code -n $ns --from-file="webhook.py=$srcFile" --dry-run=client -o yaml | & oc apply -f - | Out-Null
  & oc label namespace $ns nvcre-proxy-inject=true --overwrite | Out-Null

  Write-Host "3/7 Deploying the webhook server (Deployment/Service '$svc') ..."
  (ConvertTo-NvcreDeploymentYaml $svc $ns $image $argFix) | & oc apply -f -
  & oc rollout status "deployment/$svc" -n $ns --timeout=120s
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Webhook Deployment did not become ready -- check 'oc get pods -n $ns -l app=$svc' and its logs."
    return 1
  }

  Write-Host "4/7 Registering MutatingWebhookConfiguration (fresh caBundle) ..."
  $caBundle = [Convert]::ToBase64String([IO.File]::ReadAllBytes($caCrt))
  (ConvertTo-NvcreMwcYaml $svc $ns $caBundle) | & oc apply -f -

  Write-Host "5/7 Granting SCC (privileged, anyuid) to the '$ns' default service account ..."
  & oc adm policy add-scc-to-user privileged -z default -n $ns | Out-Null
  & oc adm policy add-scc-to-user anyuid -z default -n $ns | Out-Null

  Write-Host "6/7 Smoke test -- confirming the webhook actually patches new pods ..."
  $smoke = @"
apiVersion: v1
kind: Pod
metadata:
  generateName: webhook-smoketest-
  namespace: $ns
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: registry.redhat.io/ubi9/ubi-minimal:latest
      command: ["sleep", "5"]
"@
  $smoke | & oc create -f - 2>$null | Out-Null
  Start-Sleep -Seconds 3
  $podName = (& oc get pods -n $ns -o name 2>$null | Select-String "webhook-smoketest" | Select-Object -Last 1)
  if ($podName) {
    $podName = $podName.ToString()
    $networks = & oc get $podName -n $ns -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}' 2>$null
    if ($networks) {
      Write-Host "    OK -- smoke-test pod received the macvlan NAD annotation."
    } else {
      Write-Warning "smoke-test pod has no NAD annotation -- check 'oc logs deployment/$svc -n $ns'."
    }
    & oc delete $podName -n $ns --ignore-not-found 2>$null | Out-Null
  } else {
    Write-Warning "could not find the smoke-test pod to verify -- check manually."
  }

  Write-Host "7/7 Done."
  Write-Host ""
  Write-Host "Cluster is prepared -- users can now just run nvcrectl directly, e.g.:"
  Write-Host "  nvcrectl setup status"
  Write-Host "  nvcrectl workloadrun run --wait <file>.yaml"
  Write-Host "When finished, clean up with:"
  Write-Host "  ./cluster-utility.ps1 -TestPrep cleanup -NvcreNamespace $ns"
}

# Uninstall-NvcrePrep -- reverses everything Install-NvcrePrep did.
function Uninstall-NvcrePrep {
  $ns = $NvcreNamespace
  $svc = "privileged-injector"
  Write-StepTitle "NVIDIA Cluster Readiness test cleanup (namespace: $ns)"

  Write-Host "1/5 Deregistering the MutatingWebhookConfiguration ..."
  & oc delete mutatingwebhookconfiguration nvcre-privileged-injector --ignore-not-found

  Write-Host "2/5 Removing the webhook server (Deployment/Service/Secret/ConfigMap) ..."
  & oc delete deployment $svc -n $ns --ignore-not-found
  & oc delete service $svc -n $ns --ignore-not-found
  & oc delete secret webhook-tls -n $ns --ignore-not-found
  & oc delete configmap webhook-code -n $ns --ignore-not-found

  Write-Host "3/5 Removing the '$ns' namespace label ..."
  & oc label namespace $ns nvcre-proxy-inject- 2>$null | Out-Null

  Write-Host "4/5 Revoking SCC grants ..."
  & oc adm policy remove-scc-from-user privileged -z default -n $ns 2>$null | Out-Null
  & oc adm policy remove-scc-from-user anyuid -z default -n $ns 2>$null | Out-Null

  Write-Host "5/5 Verifying nothing is left ..."
  Write-Host "--- mutatingwebhookconfiguration ---"
  $mwc = & oc get mutatingwebhookconfiguration 2>$null | Select-String -Pattern "nvcre"
  if ($mwc) { $mwc } else { Write-Host "(none)" }
  Write-Host "--- namespace '$ns' resources ---"
  $res = & oc get all -n $ns 2>$null | Select-String -Pattern $svc
  if ($res) { $res } else { Write-Host "(none)" }
  Write-Host "--- namespace label ---"
  $lbl = & oc get namespace $ns --show-labels 2>$null | Select-String -Pattern "nvcre-proxy-inject"
  if ($lbl) { $lbl } else { Write-Host "(label removed)" }

  Write-Host ""
  Write-Host "Done. The cluster no longer auto-patches any pods for nvcrectl."
}

# Get-NvcrePrepStatus -- shows whether Install-NvcrePrep's objects are currently present.
function Get-NvcrePrepStatus {
  $ns = $NvcreNamespace
  $svc = "privileged-injector"
  Write-StepTitle "NVIDIA Cluster Readiness test prep status (namespace: $ns)"

  Write-Host "--- MutatingWebhookConfiguration ---"
  & oc get mutatingwebhookconfiguration nvcre-privileged-injector 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Host "(not present)" }
  Write-Host ""
  Write-Host "--- Webhook Deployment/Service in '$ns' ---"
  & oc get deployment,service -n $ns -l "app=$svc" 2>$null
  Write-Host ""
  Write-Host "--- Secret/ConfigMap in '$ns' ---"
  & oc get secret webhook-tls -n $ns 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Host "Secret/webhook-tls: (not present)" }
  & oc get configmap webhook-code -n $ns 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Host "ConfigMap/webhook-code: (not present)" }
  Write-Host ""
  Write-Host "--- Namespace label ---"
  $lbl = & oc get namespace $ns --show-labels 2>$null | Select-String -Pattern "nvcre-proxy-inject"
  if ($lbl) { $lbl } else { Write-Host "(label not set)" }
  Write-Host ""
  Write-Host "--- SCC grants (privileged/anyuid) for $ns/default ---"
  # 'oc adm policy add-scc-to-user' grants access via a RoleBinding to the
  # system:openshift:scc:<name> ClusterRole, not the SCC object's own .users
  # list (that field is legacy and stays empty for RBAC-based grants).
  & oc get rolebinding "system:openshift:scc:privileged" -n $ns 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "privileged: granted" } else { Write-Host "privileged: not granted" }
  & oc get rolebinding "system:openshift:scc:anyuid" -n $ns 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "anyuid: granted" } else { Write-Host "anyuid: not granted" }
}

# ---------------------------------------------------------------------------
# Step 1: cluster connectivity check (must pass before anything else runs)
# ---------------------------------------------------------------------------
Confirm-OcLogin

# -TestPrep is a standalone mode: dispatch and exit before any node-inventory logic.
if ($TestPrep -ne "") {
  switch ($TestPrep.ToLower()) {
    "prepare" { Install-NvcrePrep; exit $LASTEXITCODE }
    "cleanup" { Uninstall-NvcrePrep; exit 0 }
    "status" { Get-NvcrePrepStatus; exit 0 }
    default {
      Write-Error "Unknown -TestPrep value '$TestPrep' (expected prepare|cleanup|status)."
      exit 1
    }
  }
}

# ---------------------------------------------------------------------------
# Defaults for everything the wizard/CLI can set
# ---------------------------------------------------------------------------
$PrintDevice = $false; $PrintDeviceFamily = "all"
$PrintPcie = $false; $PrintPcieFamily = "all"
$PrintIface = $false; $PrintIfaceFamily = "all"
$PrintTable = $false; $PrintAllNet = $false; $PrintBond = $false; $PrintOvs = $false
$GenNncp = $false
$NncpFamily = "cx8"; $NncpMtu = "9000"; $NncpDirVal = "NNCP"; $NncpCustomIfaces = ""
$ActionPrint = "n"

if ($CliModeActive) {
  # -------------------------------------------------------------------------
  # Non-interactive / scriptable mode
  # -------------------------------------------------------------------------
  if ($Nodes -eq "" -and $Roles -eq "") {
    Write-Error "-Print/-Generate given without -Nodes <list> or -Roles <list>."
    exit 1
  }
  $NodeList = New-Object System.Collections.Generic.List[string]
  if ($Nodes -ne "") { foreach ($n in (Resolve-NodesFromArg $Nodes)) { if (-not $NodeList.Contains($n)) { $NodeList.Add($n) } } }
  if ($Roles -ne "") { foreach ($n in (Resolve-RolesFromArg $Roles)) { if (-not $NodeList.Contains($n)) { $NodeList.Add($n) } } }
  $NodeList = @($NodeList)
  if ($NodeList.Count -eq 0) {
    Write-Error "no valid nodes resolved from -Nodes '$Nodes' / -Roles '$Roles'."
    exit 1
  }
  if ($Print -ne "") { Resolve-PrintFlagsFromArg $Print }
  if ($Generate -ne "") { Resolve-GenerateFlagsFromArg $Generate }
  $ActionPrint = if ($Print -ne "") { "y" } else { "n" }

  if ($Ifaces -ne "") {
    $NncpFamily = "custom"; $NncpCustomIfaces = ($Ifaces -replace ',', ' ')
  } else {
    $NncpFamily = $Family
  }
  $NncpMtu = $Mtu; $NncpDirVal = $NncpDir
} else {
  # -------------------------------------------------------------------------
  # Interactive wizard: nodes first, then the Print/Generate menu.
  # -------------------------------------------------------------------------
  Write-StepTitle "Node selection"
  $choice = Ask-SingleChoice "How do you want to select nodes?" 1 @(
    "Discover nodes from the cluster (oc get nodes)",
    "Select nodes by role label (node-role.kubernetes.io/<role>)",
    "Enter node names manually"
  )
  $NodeList = @()
  if ($choice -eq 1) {
    $discovered = @(& oc get nodes -o custom-columns=NAME:.metadata.name --no-headers 2>$null |
      Where-Object { $_ -ne "" } | Sort-Object)
    if ($discovered.Count -eq 0) {
      Write-Error "No nodes returned by 'oc get nodes' -- check your oc login/context."
      exit 1
    }
    $allNodeNames = @($discovered) + @("All of the above")
    $picks = Ask-MultiChoice "Select node(s) (individually, comma-separated, or all):" $allNodeNames
    $lastIndex = $allNodeNames.Count
    if (Test-MultiHas $picks $lastIndex) {
      $NodeList = $discovered
    } else {
      $NodeList = $picks | ForEach-Object { $allNodeNames[$_ - 1] }
    }
  } elseif ($choice -eq 2) {
    $discoveredRoles = @(& oc get nodes --show-labels 2>$null |
      Select-String -Pattern 'node-role\.kubernetes\.io/([^=,\s]+)' -AllMatches |
      ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
      Sort-Object -Unique)
    if ($discoveredRoles.Count -eq 0) {
      Write-Error "No node-role labels found on the cluster."
      exit 1
    }
    $rolePicks = Ask-MultiChoice "Select role(s):" $discoveredRoles
    $selectedRoles = ($rolePicks | ForEach-Object { $discoveredRoles[$_ - 1] }) -join ','
    $NodeList = Resolve-RolesFromArg $selectedRoles
    if ($NodeList.Count -eq 0) {
      Write-Error "No nodes matched the selected role(s), aborting."
      exit 1
    }
  } else {
    $val = Ask-Value "Enter node names (space or comma separated)" ""
    if ([string]::IsNullOrWhiteSpace($val)) {
      Write-Error "No nodes entered, aborting."
      exit 1
    }
    $NodeList = @(($val -replace ',', ' ') -split '\s+' | Where-Object { $_ -ne "" })
  }

  if ($NodeList.Count -eq 0) {
    Write-Error "No nodes selected, aborting."
    exit 1
  }

  Write-StepTitle "What do you want to do?"
  $actionPicks = Ask-MultiChoice "Select action(s):" @(
    "Print information to console",
    "Generate YAML artifacts"
  )
  $ActionPrint = if (Test-MultiHas $actionPicks 1) { "y" } else { "n" }
  $ActionGenerate = if (Test-MultiHas $actionPicks 2) { "y" } else { "n" }

  if ($ActionPrint -eq "y") {
    $printPicks = Ask-MultiChoice "What do you want to print? (pick any combination)" @(
      "Device names (mlx5_*, comma-separated list)",
      "PCIe addresses (comma-separated list)",
      "Interface names (comma-separated list, e.g. eno10np0)",
      "Full RDMA device table (device/PCIe/iface/IP/adapter, always unfiltered)",
      "All host network interfaces (type/master/driver/PCIe/adapter/IP)",
      "Bond membership",
      "br-ex (OVN-Kubernetes) port membership",
      "Everything above"
    )
    if (Test-MultiHas $printPicks 8) {
      $PrintDevice = $true; $PrintDeviceFamily = "all"
      $PrintPcie = $true; $PrintPcieFamily = "all"
      $PrintIface = $true; $PrintIfaceFamily = "all"
      $PrintTable = $true; $PrintAllNet = $true; $PrintBond = $true; $PrintOvs = $true
    } else {
      if (Test-MultiHas $printPicks 1) { $PrintDevice = $true }
      if (Test-MultiHas $printPicks 2) { $PrintPcie = $true }
      if (Test-MultiHas $printPicks 3) { $PrintIface = $true }
      if (Test-MultiHas $printPicks 4) { $PrintTable = $true }
      if (Test-MultiHas $printPicks 5) { $PrintAllNet = $true }
      if (Test-MultiHas $printPicks 6) { $PrintBond = $true }
      if (Test-MultiHas $printPicks 7) { $PrintOvs = $true }
      if ($PrintDevice -or $PrintPcie -or $PrintIface) {
        $famChoice = Ask-SingleChoice "Device/PCIe/Interface: which adapter family should these use?" 4 @(
          "ConnectX-7 (standalone, excludes BlueField)",
          "ConnectX-8",
          "BlueField (any generation, e.g. BlueField-3/ConnectX-7)",
          "All adapters (no filter)"
        )
        $fam = switch ($famChoice) { 1 { "cx7" } 2 { "cx8" } 3 { "bf" } 4 { "all" } }
        $PrintDeviceFamily = $fam; $PrintPcieFamily = $fam; $PrintIfaceFamily = $fam
      }
    }
  }

  if ($ActionGenerate -eq "y") {
    $GenNncp = $true

    function Ask-IfaceFamily([string]$Which) {
      return Ask-SingleChoice "$Which which interfaces should be included?" 1 @(
        "ConnectX-8 RDMA interfaces (auto-detected)",
        "ConnectX-7 RDMA interfaces (auto-detected, excludes BlueField)",
        "BlueField RDMA interfaces (auto-detected, e.g. BlueField-3/ConnectX-7)",
        "All RDMA interfaces, any adapter (auto-detected)",
        "Custom list (enter interface names manually)"
      )
    }

    Write-StepTitle "NNCP options"
    $famChoice = Ask-IfaceFamily "NNCP:"
    switch ($famChoice) {
      1 { $NncpFamily = "cx8" }
      2 { $NncpFamily = "cx7" }
      3 { $NncpFamily = "bf" }
      4 { $NncpFamily = "all" }
      5 {
        $NncpFamily = "custom"
        $NncpCustomIfaces = Ask-Value "NNCP: enter interface names (space separated, applied per-node)" ""
      }
    }
    $NncpMtu = Ask-Value "NNCP: MTU" "9000"
    $NncpDirVal = Ask-Value "NNCP: output directory" "NNCP"
  }

  Write-StepTitle "Summary"
  Write-Host "Nodes            : $($NodeList -join ' ')"
  Write-Host "Print to console : $ActionPrint"
  if ($PrintDevice) { Write-Host "  - Device names (family=$PrintDeviceFamily)" }
  if ($PrintPcie) { Write-Host "  - PCIe addresses (family=$PrintPcieFamily)" }
  if ($PrintIface) { Write-Host "  - Interface names (family=$PrintIfaceFamily)" }
  if ($PrintTable) { Write-Host "  - Full RDMA device table" }
  if ($PrintAllNet) { Write-Host "  - All host network interfaces" }
  if ($PrintBond) { Write-Host "  - Bond membership" }
  if ($PrintOvs) { Write-Host "  - br-ex port membership" }
  Write-Host "Generate NNCP     : $(if ($GenNncp) { 'y' } else { 'n' })"
  if ($GenNncp) { Write-Host "  - family=$NncpFamily mtu=$NncpMtu dir=$NncpDirVal" }
  Write-Host ""
  $proceed = Ask-YesNo "Proceed with the above?" "y"
  if ($proceed -eq "n") {
    Write-Host "Aborted."
    exit 0
  }
}

# ---------------------------------------------------------------------------
# Data-collection scripts (run inside `oc debug node/<node> -- chroot /host`)
# ---------------------------------------------------------------------------
$RdmaScript = @'
for ibdev in /sys/class/infiniband/*; do
  [ -d "$ibdev" ] || continue
  dev=$(basename "$ibdev")
  iface=$(ls "$ibdev/device/net" 2>/dev/null | head -1)
  iface=${iface:-"-"}
  pcie=$(basename "$(readlink -f "$ibdev/device")" 2>/dev/null)
  pcie=${pcie:-"-"}
  ip="-"
  if [ "$iface" != "-" ]; then
    ip=$(ip -4 -o addr show "$iface" 2>/dev/null | awk "{print \$4}" | head -1)
    ip=${ip:-"-"}
  fi
  desc=$(lspci -s "$pcie" 2>/dev/null)
  adapter=$(echo "$desc" | sed -n "s/.*\[\(ConnectX[^]]*\)\].*/\1/p")
  if [ -z "$adapter" ]; then
    adapter=$(echo "$desc" | sed -n "s/.*\[\(BlueField[^]]*\)\].*/\1/p")
  fi
  if [ -z "$adapter" ]; then
    adapter=$(echo "$desc" | sed -n -E "s/.*(BlueField-[0-9]+) integrated (ConnectX-[0-9]+).*/\1\/\2/p")
  fi
  if [ -z "$adapter" ]; then
    adapter=$(echo "$desc" | sed -E "s/^[0-9a-fA-F]+:[0-9a-fA-F]+\.[0-9a-fA-F]+ [A-Za-z0-9 ]+: //")
  fi
  adapter=${adapter:-"unknown"}
  echo "${dev}|${pcie}|${iface}|${ip}|${adapter}"
done
'@

$AllNetScript = @'
for netdir in /sys/class/net/*; do
  iface=$(basename "$netdir")
  [ "$iface" = "lo" ] && continue
  [ "$iface" = "ovs-system" ] && continue
  type="physical"
  if [ -d "$netdir/bonding" ]; then
    type="bond"
  elif [ -d "/sys/class/net/$iface/bridge" ]; then
    type="bridge(linux)"
  fi
  master="-"
  if [ -L "$netdir/master" ]; then
    master=$(basename "$(readlink -f "$netdir/master")")
    [ "$type" = "physical" ] && type="slave"
  fi
  driver=$(ethtool -i "$iface" 2>/dev/null | awk -F": " "/^driver:/{print \$2}")
  driver=${driver:-"-"}
  if [ "$driver" = "openvswitch" ] || [ "$driver" = "veth" ]; then
    type="$driver"
  fi
  [ "$type" = "veth" ] && continue
  pcie="-"
  if [ -e "$netdir/device" ]; then
    pcie=$(basename "$(readlink -f "$netdir/device")" 2>/dev/null)
  fi
  adapter="-"
  if [ "$pcie" != "-" ]; then
    desc=$(lspci -s "$pcie" 2>/dev/null)
    adapter=$(echo "$desc" | sed -n "s/.*\[\(ConnectX[^]]*\)\].*/\1/p")
    [ -z "$adapter" ] && adapter=$(echo "$desc" | sed -n "s/.*\[\(BlueField[^]]*\)\].*/\1/p")
    if [ -z "$adapter" ]; then
      adapter=$(echo "$desc" | sed -n -E "s/.*(BlueField-[0-9]+) integrated (ConnectX-[0-9]+).*/\1\/\2/p")
    fi
    if [ -z "$adapter" ]; then
      adapter=$(echo "$desc" | sed -E "s/^[0-9a-fA-F]+:[0-9a-fA-F]+\.[0-9a-fA-F]+ [A-Za-z0-9 ]+: //")
    fi
    adapter=${adapter:-"unknown"}
  fi
  ip=$(ip -4 -o addr show "$iface" 2>/dev/null | awk "{print \$4}" | head -1)
  ip=${ip:-"-"}
  echo "${iface}|${type}|${master}|${driver}|${pcie}|${adapter}|${ip}"
done
'@

$BondScript = @'
for b in /sys/class/net/*/bonding; do
  [ -d "$b" ] || continue
  bond=$(basename "$(dirname "$b")")
  slaves=$(cat "$b/slaves" 2>/dev/null)
  echo "${bond}: ${slaves:-"(none)"}"
done
'@

$OvsScript = @'
if command -v ovs-vsctl >/dev/null 2>&1; then
  if ovs-vsctl br-exists br-ex 2>/dev/null; then
    ports=$(ovs-vsctl list-ports br-ex 2>/dev/null)
    echo "br-ex ports: ${ports:-"(none)"}"
  else
    echo "br-ex: bridge not found"
  fi
else
  echo "ovs-vsctl not available on this node"
fi
'@

foreach ($node in $NodeList) {
  Write-Host ""
  Write-Host "################################################################"
  Write-Host "### $node"
  Write-Host "################################################################"

  $rawRdma = & oc debug "node/$node" -- chroot /host bash -c "$RdmaScript" 2>&1 |
    Where-Object { $_ -match '^[a-z0-9_]+\|' }

  $allDevs = New-Object System.Collections.Generic.List[string]
  $allPcies = New-Object System.Collections.Generic.List[string]
  $allIfaces = New-Object System.Collections.Generic.List[string]
  $cx8Devs = New-Object System.Collections.Generic.List[string]
  $cx8Pcies = New-Object System.Collections.Generic.List[string]
  $cx8Ifaces = New-Object System.Collections.Generic.List[string]
  $cx7Devs = New-Object System.Collections.Generic.List[string]
  $cx7Pcies = New-Object System.Collections.Generic.List[string]
  $cx7Ifaces = New-Object System.Collections.Generic.List[string]
  $bfDevs = New-Object System.Collections.Generic.List[string]
  $bfPcies = New-Object System.Collections.Generic.List[string]
  $bfIfaces = New-Object System.Collections.Generic.List[string]

  foreach ($line in $rawRdma) {
    $parts = $line -split '\|'
    if ($parts.Count -lt 5) { continue }
    $dev = $parts[0]; $pcie = $parts[1]; $iface = $parts[2]; $ip = $parts[3]; $adapter = $parts[4]
    if ([string]::IsNullOrEmpty($dev)) { continue }
    $allDevs.Add($dev); $allPcies.Add($pcie)
    if ($iface -ne "-") { $allIfaces.Add($iface) }
    # Check BlueField first: a BlueField-3/ConnectX-7 adapter string also
    # contains "ConnectX-7", so it must not fall through to the cx7 bucket.
    if ($adapter -match 'BlueField') {
      $bfDevs.Add($dev); $bfPcies.Add($pcie)
      if ($iface -ne "-") { $bfIfaces.Add($iface) }
    } elseif ($adapter -match 'ConnectX-8') {
      $cx8Devs.Add($dev); $cx8Pcies.Add($pcie)
      if ($iface -ne "-") { $cx8Ifaces.Add($iface) }
    } elseif ($adapter -match 'ConnectX-7') {
      $cx7Devs.Add($dev); $cx7Pcies.Add($pcie)
      if ($iface -ne "-") { $cx7Ifaces.Add($iface) }
    }
  }

  function Get-FamilyValues([string]$Field, [string]$Fam) {
    switch ("$Fam.$Field") {
      "cx8.devs" { return $cx8Devs } "cx8.pcies" { return $cx8Pcies } "cx8.ifaces" { return $cx8Ifaces }
      "cx7.devs" { return $cx7Devs } "cx7.pcies" { return $cx7Pcies } "cx7.ifaces" { return $cx7Ifaces }
      "bf.devs" { return $bfDevs } "bf.pcies" { return $bfPcies } "bf.ifaces" { return $bfIfaces }
      default {
        switch ($Field) { "devs" { return $allDevs } "pcies" { return $allPcies } "ifaces" { return $allIfaces } }
      }
    }
  }

  if ($PrintTable) {
    Write-Host ""
    Write-Host "--- Full RDMA device table ---"
    "{0,-10} {1,-14} {2,-16} {3,-18} {4,-24}" -f "DEVICE","PCIE","INTERFACE","IP","ADAPTER" | Write-Host
    "{0,-10} {1,-14} {2,-16} {3,-18} {4,-24}" -f "------","----","---------","--","-------" | Write-Host
    foreach ($line in $rawRdma) {
      $parts = $line -split '\|'
      if ($parts.Count -lt 5 -or [string]::IsNullOrEmpty($parts[0])) { continue }
      "{0,-10} {1,-14} {2,-16} {3,-18} {4,-24}" -f $parts[0],$parts[1],$parts[2],$parts[3],$parts[4] | Write-Host
    }
  }

  if ($PrintDevice) {
    Write-Host ""
    Write-Host "Device names ($PrintDeviceFamily) : $((Get-FamilyValues 'devs' $PrintDeviceFamily) -join ',')"
  }
  if ($PrintPcie) {
    Write-Host "PCIe addresses ($PrintPcieFamily) : $((Get-FamilyValues 'pcies' $PrintPcieFamily) -join ',')"
  }
  if ($PrintIface) {
    Write-Host "Interface names ($PrintIfaceFamily) : $((Get-FamilyValues 'ifaces' $PrintIfaceFamily) -join ',')"
  }

  if ($PrintAllNet) {
    Write-Host ""
    Write-Host "--- All network interfaces ---"
    "{0,-14} {1,-14} {2,-10} {3,-10} {4,-14} {5,-30} {6,-18}" -f "INTERFACE","TYPE","MASTER","DRIVER","PCIE","ADAPTER","IP" | Write-Host
    "{0,-14} {1,-14} {2,-10} {3,-10} {4,-14} {5,-30} {6,-18}" -f "---------","----","------","------","----","-------","--" | Write-Host
    $rawAllNet = & oc debug "node/$node" -- chroot /host bash -c "$AllNetScript" 2>&1 |
      Where-Object { $_ -match '^[a-zA-Z0-9@._-]+\|' }
    foreach ($line in $rawAllNet) {
      $parts = $line -split '\|'
      if ($parts.Count -lt 7) { continue }
      "{0,-14} {1,-14} {2,-10} {3,-10} {4,-14} {5,-30} {6,-18}" -f $parts[0],$parts[1],$parts[2],$parts[3],$parts[4],$parts[5],$parts[6] | Write-Host
    }
  }

  if ($PrintBond) {
    Write-Host ""
    Write-Host "--- Bond membership ---"
    $bondOut = & oc debug "node/$node" -- chroot /host bash -c "$BondScript" 2>&1 |
      Where-Object { $_ -match '^[a-zA-Z0-9]+:' }
    if ($bondOut) { $bondOut | ForEach-Object { Write-Host $_ } } else { Write-Host "(no bonds found)" }
  }

  if ($PrintOvs) {
    Write-Host ""
    Write-Host "--- br-ex (OVN-Kubernetes) port membership ---"
    & oc debug "node/$node" -- chroot /host bash -c "$OvsScript" 2>&1 |
      Where-Object { $_ -match '^(br-ex|ovs-vsctl)' } | ForEach-Object { Write-Host $_ }
  }

  # --- NNCP generation (per node) ---
  if ($GenNncp) {
    Write-Host ""
    Write-Host "--- NNCP generation ($node) ---"
    $nncpIfaces = switch ($NncpFamily) {
      "cx8" { $cx8Ifaces }
      "cx7" { $cx7Ifaces }
      "bf" { $bfIfaces }
      "all" { $allIfaces }
      "custom" { @(($NncpCustomIfaces -replace ',', ' ') -split '\s+' | Where-Object { $_ -ne "" }) }
      default { @() }
    }
    if ($nncpIfaces.Count -gt 0) {
      New-NncpYaml $NncpDirVal $NncpMtu $node $nncpIfaces
    } else {
      Write-Host "(no matching interfaces for $node, nothing generated)"
    }
  }
}

Write-Host ""
Write-Host "Done."
