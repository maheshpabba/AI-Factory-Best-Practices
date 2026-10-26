#!/usr/bin/env bash
# cluster-utility.sh -- OpenShift cluster NIC inventory + YAML artifact
# generator. Single self-contained file (no helper scripts); everything is
# implemented as functions below. Has a Windows PowerShell twin,
# cluster-utility.ps1, kept functionally in sync.
#
# Author:  Mahesh Pabba
# Email:   mpabba@cisco.com
# Version: 0.6.0
#
# For each selected node, inspects host networking via `oc debug node/<node>`:
#   - RDMA (mlx5_*) devices: device name, PCIe address, netdev interface,
#     host-level IP (if any), and adapter model (ConnectX-7/8, BlueField, etc).
#   - ALL host network interfaces: type, bond/bridge master, driver, PCIe
#     adapter model, and IP address.
#   - Bond member interfaces.
#   - br-ex (OVN-Kubernetes external bridge) port membership.
#
# It can also generate, per the interfaces it finds:
#   - NodeNetworkConfigurationPolicy (NNCP) YAMLs
#
# Two modes:
#   1) Non-interactive / scriptable: pass -n/-p/-g (and optional tuning flags)
#      and it runs silently, no prompts.
#   2) Interactive wizard: run with no -n/-p/-g and it walks you through node
#      selection, then an hdblcm-style "Print / Generate" menu.
#
# Usage:
#   ./cluster-utility.sh [-h|--help]
#   ./cluster-utility.sh
#   ./cluster-utility.sh -n all -p pcie:cx8,device:cx8,bond -g nncp
#   ./cluster-utility.sh -n worker3,worker4 -p pcie,device,net,bond,br-ex
#   ./cluster-utility.sh -r gpuworker880 -p iface:bf,table
#
# Before anything else, this script verifies cluster connectivity with
# `oc get nodes` and errors out (telling you to `oc login`) if that fails.

set -o pipefail
# Note: deliberately no -e (interactive `[ cond ] && echo ...` one-liners below
# are expected to "fail" on false) and no -u (the macOS-default bash is 3.2,
# which treats expanding an empty array under `set -u` as an unbound-variable
# error -- fixed only in bash 4.4+).

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options] [node ...]

Inventories host networking on one or more OpenShift nodes (via
'oc debug node/<node>'), and optionally generates NodeNetworkConfigurationPolicy
(NNCP) YAML artifacts from the interfaces it finds.

Before doing anything, it verifies cluster connectivity by running
'oc get nodes'; if that fails, it errors out and tells you to 'oc login' first.

NON-INTERACTIVE MODE (any of -n/-r/-p/-g given -> runs silently, no prompts):
  -n <nodes>      Comma-separated node names, or "all" for every cluster node.
                  e.g. -n all   or   -n worker3,worker4
  -r <roles>      Comma-separated node-role names, matched against the
                  "node-role.kubernetes.io/<role>" label (what 'oc get nodes'
                  shows under ROLES). e.g. -r gpuworker880
                  Combines with -n (union of both, deduped).
  -p <codes>      Comma-separated print codes (any combination). device,
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
                  e.g. -p device:cx8,pcie:bf,iface:cx7,table,bond
  -g <codes>      Comma-separated artifact codes to generate:
                    nncp        NodeNetworkConfigurationPolicy YAMLs

  Tuning flags for -g (all optional):
  --family <cx8|cx7|all>   Which interfaces to use (default: cx8)
  --ifaces "<names>"       Custom space/comma separated interface list
                           (overrides --family)
  --mtu <n>                MTU (default: 9000)
  --nncp-dir <dir>         NNCP output directory (default: NNCP)

  -T <mode>       Nvidia Cluster Readiness test prepare/check. Runs standalone
                  (ignores -n/-r/-p/-g). Installs (or removes) everything
                  needed for nvcrectl's WorkloadRun/Certification "node" pods
                  to get a privileged security context and the macvlan RDMA
                  networks attached, via a small mutating admission webhook --
                  so users only ever have to run nvcrectl itself, never touch
                  certs/webhooks/SCCs by hand. Modes:
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
                  e.g. -T prepare   or   -T cleanup

  Tuning flags for -T (all optional):
  --nvcre-namespace <ns>   Namespace nvcrectl runs test pods in (default: default)
  --nvcre-airgapped        Force the air-gapped webhook variant (injects Cisco proxy
                           env vars into test pods). Auto-detected by default via
                           'oc get proxy cluster' -- only needed to override that.
  --nvcre-arp-fix          Also apply the ARP/RPF sysctl postStart fix for
                           multi-homed RoCE NICs (default: off)
  --nvcre-image <image>    Webhook server base image
                           (default: registry.redhat.io/ubi9/python-312-minimal:latest)
  --nvcre-workdir <dir>    Scratch dir for generated TLS material (default: /tmp/nvcre-wh)

INTERACTIVE MODE (no -n/-r/-p/-g given):
  Walks you through node selection (discover from cluster, select by role
  label, or enter manually), then an hdblcm-style menu: 1) Print information
  to console  2) Generate YAML artifacts -- each with its own numbered
  sub-menu -- followed by a summary and confirmation before anything runs.

Options:
  -h, --help      Show this help and exit.

Examples:
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} -n all -p pcie:cx8,device:cx8
  ./${SCRIPT_NAME} -r gpuworker880 -p iface:bf,table
  ./${SCRIPT_NAME} -n worker3,worker4 -p all -g nncp --family cx8
  ./${SCRIPT_NAME} -T prepare --nvcre-namespace default
  ./${SCRIPT_NAME} -T cleanup --nvcre-namespace default
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing (short flags -n/-p/-g trigger silent/non-interactive mode;
# bare positional args are treated as node names, same as the old CLI).
# ---------------------------------------------------------------------------
NODES_ARG=""; ROLES_ARG=""; PRINT_ARG=""; GENERATE_ARG=""
CLI_FAMILY="cx8"; CLI_IFACES=""; CLI_MTU="9000"
CLI_NNCP_DIR="NNCP"
TESTPREP_ARG=""
NVCRE_NAMESPACE="default"; NVCRE_AIRGAPPED="n"; NVCRE_AIRGAPPED_SET="n"; NVCRE_ARP_FIX="n"
NVCRE_IMAGE="registry.redhat.io/ubi9/python-312-minimal:latest"
NVCRE_WORKDIR="/tmp/nvcre-wh"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n) NODES_ARG="$2"; shift 2 ;;
    -r) ROLES_ARG="$2"; shift 2 ;;
    -p) PRINT_ARG="$2"; shift 2 ;;
    -g) GENERATE_ARG="$2"; shift 2 ;;
    --family) CLI_FAMILY="$2"; shift 2 ;;
    --ifaces) CLI_IFACES="$2"; shift 2 ;;
    --mtu) CLI_MTU="$2"; shift 2 ;;
    --nncp-dir) CLI_NNCP_DIR="$2"; shift 2 ;;
    -T) TESTPREP_ARG="$2"; shift 2 ;;
    --nvcre-namespace) NVCRE_NAMESPACE="$2"; shift 2 ;;
    --nvcre-airgapped) NVCRE_AIRGAPPED="y"; NVCRE_AIRGAPPED_SET="y"; shift ;;
    --nvcre-arp-fix) NVCRE_ARP_FIX="y"; shift ;;
    --nvcre-image) NVCRE_IMAGE="$2"; shift 2 ;;
    --nvcre-workdir) NVCRE_WORKDIR="$2"; shift 2 ;;
    --) shift ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -z "${NODES_ARG}" ]; then NODES_ARG="$1"; else NODES_ARG="${NODES_ARG},$1"; fi
      shift
      ;;
  esac
done

CLI_MODE_ACTIVE="n"
[ -n "${NODES_ARG}" ] && CLI_MODE_ACTIVE="y"
[ -n "${ROLES_ARG}" ] && CLI_MODE_ACTIVE="y"
[ -n "${PRINT_ARG}" ] && CLI_MODE_ACTIVE="y"
[ -n "${GENERATE_ARG}" ] && CLI_MODE_ACTIVE="y"

# ---------------------------------------------------------------------------
# Small hdblcm-style prompt helpers (bash-3.2-safe: no associative arrays).
# ---------------------------------------------------------------------------
hr() { printf '%s\n' "--------------------------------------------------------------------------"; }

step_title() {
  echo
  hr
  echo "  $1"
  hr
}

# check_oc_login -- verifies `oc get nodes` works, else errors out and exits.
check_oc_login() {
  if [ "${CLI_MODE_ACTIVE}" = "n" ]; then
    step_title "Cluster connectivity check"
    echo "Running 'oc get nodes' ..."
  fi
  if ! oc get nodes >/dev/null 2>&1; then
    echo "ERROR: 'oc get nodes' failed -- you are not logged in to an OpenShift cluster" >&2
    echo "(or your current context/token is invalid or lacks permissions)." >&2
    echo "Run 'oc login ...' first, then re-run this script." >&2
    exit 1
  fi
  [ "${CLI_MODE_ACTIVE}" = "n" ] && echo "OK -- cluster is reachable."
}

# ask_yesno "<prompt>" <y|n default> -> sets YESNO_RESULT to "y" or "n"
ask_yesno() {
  local prompt="$1" default="${2:-y}" ans suffix
  suffix="[Y/n]"
  [ "${default}" = "n" ] && suffix="[y/N]"
  while true; do
    read -r -p "${prompt} ${suffix}: " ans
    ans="${ans:-${default}}"
    case "${ans}" in
      [Yy]*) YESNO_RESULT="y"; return 0 ;;
      [Nn]*) YESNO_RESULT="n"; return 0 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# ask_value "<prompt>" "<default>" -> sets VALUE_RESULT
ask_value() {
  local prompt="$1" default="$2" ans
  read -r -p "${prompt} [${default}]: " ans
  VALUE_RESULT="${ans:-${default}}"
}

# ask_single_choice "<prompt>" <default_number> "opt1" "opt2" ...
# -> sets SINGLE_CHOICE_INDEX (1-based) and SINGLE_CHOICE_TEXT
ask_single_choice() {
  local prompt="$1" default="$2"; shift 2
  local opts=("$@") i ans
  echo
  echo "${prompt}"
  for i in "${!opts[@]}"; do
    printf "  %2d) %s\n" "$((i + 1))" "${opts[$i]}"
  done
  while true; do
    read -r -p "Select [1-${#opts[@]}] (default ${default}): " ans
    ans="${ans:-${default}}"
    if [[ "${ans}" =~ ^[0-9]+$ ]] && [ "${ans}" -ge 1 ] && [ "${ans}" -le "${#opts[@]}" ]; then
      SINGLE_CHOICE_INDEX="${ans}"
      SINGLE_CHOICE_TEXT="${opts[$((ans - 1))]}"
      return 0
    fi
    echo "Invalid selection, try again."
  done
}

# ask_multi_choice "<prompt>" "opt1" "opt2" ...
# -> sets MULTI_CHOICE_INDICES array (1-based numbers picked)
ask_multi_choice() {
  local prompt="$1"; shift
  local opts=("$@") i ans ok p picks
  echo
  echo "${prompt}"
  for i in "${!opts[@]}"; do
    printf "  %2d) %s\n" "$((i + 1))" "${opts[$i]}"
  done
  echo "  (comma-separated numbers, e.g. 1,3,4)"
  while true; do
    read -r -p "Select: " ans
    if [ -z "${ans}" ]; then
      echo "Please select at least one option."
      continue
    fi
    ok=1
    IFS=',' read -r -a picks <<< "${ans}"
    for p in "${picks[@]}"; do
      p="${p//[[:space:]]/}"
      if ! [[ "${p}" =~ ^[0-9]+$ ]] || [ "${p}" -lt 1 ] || [ "${p}" -gt "${#opts[@]}" ]; then
        ok=0
        break
      fi
    done
    if [ "${ok}" -eq 1 ]; then
      MULTI_CHOICE_INDICES=()
      for p in "${picks[@]}"; do
        p="${p//[[:space:]]/}"
        MULTI_CHOICE_INDICES+=("${p}")
      done
      return 0
    fi
    echo "Invalid selection, try again."
  done
}

# multi_has <n> -> 0 (true) if <n> is among the last ask_multi_choice result
multi_has() {
  local target="$1" idx
  for idx in "${MULTI_CHOICE_INDICES[@]}"; do
    [ "${idx}" = "${target}" ] && return 0
  done
  return 1
}

# dedup_append <array_name> <value> -- appends value to the named array only
# if it isn't already present. bash-3.2-safe (no namerefs): uses eval.
dedup_append() {
  local arr_name="$1" value="$2" i size cur
  eval "size=\${#${arr_name}[@]}"
  for ((i = 0; i < size; i++)); do
    eval "cur=\${${arr_name}[$i]}"
    [ "${cur}" = "${value}" ] && return 0
  done
  eval "${arr_name}+=(\"\${value}\")"
}

# ---------------------------------------------------------------------------
# CLI-mode resolvers: turn comma-separated codes into the same flags/vars the
# interactive wizard would have produced.
# ---------------------------------------------------------------------------

# resolve_nodes_from_arg <csv> -> merges into the (already-declared) NODES
# array, deduped. "all" expands via oc get nodes.
resolve_nodes_from_arg() {
  local csv="$1" cleaned items item want_all=0 discovered
  cleaned="$(echo "${csv}" | tr -d ' ')"
  IFS=',' read -r -a items <<< "${cleaned}"
  for item in "${items[@]}"; do
    [ -z "${item}" ] && continue
    if [ "$(echo "${item}" | tr '[:upper:]' '[:lower:]')" = "all" ]; then
      want_all=1
    else
      dedup_append NODES "${item}"
    fi
  done
  if [ "${want_all}" -eq 1 ]; then
    discovered=$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | sort)
    if [ -z "${discovered}" ]; then
      echo "ERROR: 'oc get nodes' returned nothing; cannot resolve '-n all'." >&2
      exit 1
    fi
    while IFS= read -r n; do
      [ -n "${n}" ] && dedup_append NODES "${n}"
    done <<< "${discovered}"
  fi
}

# resolve_roles_from_arg <csv> -- merges nodes matching
# node-role.kubernetes.io/<role> for each given role into the NODES array.
resolve_roles_from_arg() {
  local csv="$1" cleaned items role matched
  cleaned="$(echo "${csv}" | tr -d ' ')"
  IFS=',' read -r -a items <<< "${cleaned}"
  for role in "${items[@]}"; do
    [ -z "${role}" ] && continue
    matched=$(oc get nodes -l "node-role.kubernetes.io/${role}" -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null)
    if [ -z "${matched}" ]; then
      echo "WARNING: no nodes found with role '${role}' (label node-role.kubernetes.io/${role})." >&2
      continue
    fi
    while IFS= read -r n; do
      [ -n "${n}" ] && dedup_append NODES "${n}"
    done <<< "${matched}"
  done
}

# normalize_family <raw> -> echoes cx7|cx8|bf|all (defaults to "all", warns on junk)
normalize_family() {
  local raw
  raw="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "${raw}" in
    "") echo "all" ;;
    cx7|connectx-7|connectx7) echo "cx7" ;;
    cx8|connectx-8|connectx8) echo "cx8" ;;
    bf|bluefield|blue-field) echo "bf" ;;
    all) echo "all" ;;
    *) echo "WARNING: unknown family '$1', defaulting to 'all'." >&2; echo "all" ;;
  esac
}

# resolve_print_flags_from_arg <csv> -- sets the PRINT_* globals. device, pcie
# and iface accept an optional ":<family>" suffix (cx7|cx8|bf|all).
resolve_print_flags_from_arg() {
  local csv="$1" cleaned items item code fam
  cleaned="$(echo "${csv}" | tr -d ' ')"
  IFS=',' read -r -a items <<< "${cleaned}"
  for item in "${items[@]}"; do
    code="$(echo "${item%%:*}" | tr '[:upper:]' '[:lower:]')"
    fam="all"
    [[ "${item}" == *:* ]] && fam="$(normalize_family "${item#*:}")"
    case "${code}" in
      "") : ;;
      device|devices|rdma) PRINT_DEVICE="y"; PRINT_DEVICE_FAMILY="${fam}" ;;
      pcie) PRINT_PCIE="y"; PRINT_PCIE_FAMILY="${fam}" ;;
      iface|interface|interfaces) PRINT_IFACE="y"; PRINT_IFACE_FAMILY="${fam}" ;;
      cx8) PRINT_IFACE="y"; PRINT_IFACE_FAMILY="cx8" ;;
      cx7) PRINT_IFACE="y"; PRINT_IFACE_FAMILY="cx7" ;;
      bf) PRINT_IFACE="y"; PRINT_IFACE_FAMILY="bf" ;;
      table) PRINT_TABLE="y" ;;
      net|allnet) PRINT_ALLNET="y" ;;
      bond|bonds) PRINT_BOND="y" ;;
      br-ex|brex|ovs) PRINT_OVS="y" ;;
      all|everything)
        PRINT_DEVICE="y"; PRINT_DEVICE_FAMILY="all"
        PRINT_PCIE="y"; PRINT_PCIE_FAMILY="all"
        PRINT_IFACE="y"; PRINT_IFACE_FAMILY="all"
        PRINT_TABLE="y"; PRINT_ALLNET="y"; PRINT_BOND="y"; PRINT_OVS="y" ;;
      *) echo "WARNING: unknown -p code '${item}', ignoring." >&2 ;;
    esac
  done
}

# resolve_generate_flags_from_arg <csv> -- sets GEN_NNCP
resolve_generate_flags_from_arg() {
  local csv="$1" cleaned items item
  cleaned="$(echo "${csv}" | tr -d ' ')"
  IFS=',' read -r -a items <<< "${cleaned}"
  for item in "${items[@]}"; do
    case "$(echo "${item}" | tr '[:upper:]' '[:lower:]')" in
      "") : ;;
      nncp|all|both) GEN_NNCP="y" ;;
      *) echo "WARNING: unknown -g code '${item}', ignoring." >&2 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# YAML-writing functions
# ---------------------------------------------------------------------------

# generate_nncp_yaml <output_dir> <mtu> <node> <iface> [<iface> ...]
# Writes one NodeNetworkConfigurationPolicy (nmstate.io/v1) per interface,
# named "<node>-<iface>-mtu<mtu>" (ethernet, up).
generate_nncp_yaml() {
  local outdir="$1" mtu="$2" node="$3"; shift 3
  local iface name file
  mkdir -p "${outdir}"
  for iface in "$@"; do
    if [ -z "${iface}" ] || [ "${iface}" = "-" ]; then
      continue
    fi
    name="${node}-${iface}-mtu${mtu}"
    file="${outdir}/${name}.yaml"
    cat > "${file}" <<EOF
# Use this YAML as Template
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${name}
spec:
  desiredState:
    interfaces:
      - mtu: ${mtu}
        name: ${iface}
        state: up
        type: ethernet
  nodeSelector:
    kubernetes.io/hostname: ${node}
EOF
    echo "Wrote ${file}"
  done
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

WEBHOOK_PY_SRC=$(cat <<'PYEOF'
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
PYEOF
)

WEBHOOK_AIRGAPPED_PY_SRC=$(cat <<'PYEOF'
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
PYEOF
)

# nvcre_mwc_yaml <svc> <ns> <cabundle_b64> -> MutatingWebhookConfiguration YAML
nvcre_mwc_yaml() {
  local svc="$1" ns="$2" cabundle="$3"
  cat <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: nvcre-privileged-injector
webhooks:
  - name: ${svc}.${ns}.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Ignore
    timeoutSeconds: 5
    clientConfig:
      service:
        name: ${svc}
        namespace: ${ns}
        path: /mutate
        port: 443
      caBundle: ${cabundle}
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
EOF
}

# nvcre_deployment_yaml <svc> <ns> <image> <inject_arp_fix: true|false>
# -> Deployment + Service YAML for the webhook server
nvcre_deployment_yaml() {
  local svc="$1" ns="$2" image="$3" inject_arp="$4"
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${svc}
  namespace: ${ns}
  labels:
    app: ${svc}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${svc}
  template:
    metadata:
      labels:
        app: ${svc}
    spec:
      containers:
        - name: webhook
          image: ${image}
          command: ["python3", "/code/webhook.py"]
          env:
            - name: INJECT_NAD
              value: "true"
            - name: INJECT_PROXY
              value: "true"
            - name: INJECT_ARP_FIX
              value: "${inject_arp}"
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
  name: ${svc}
  namespace: ${ns}
  labels:
    app: ${svc}
spec:
  selector:
    app: ${svc}
  ports:
    - port: 443
      targetPort: 8443
EOF
}

# nvcre_prepare -- installs everything nvcrectl's node pods need
# (TLS cert, Secret/ConfigMap, Deployment/Service, MutatingWebhookConfiguration,
# namespace label, SCC grants), then smoke-tests it.
nvcre_prepare() {
  local ns="${NVCRE_NAMESPACE}" workdir="${NVCRE_WORKDIR}" image="${NVCRE_IMAGE}"
  local svc="privileged-injector" arp_fix="false" src_file cabundle test_pod pod_name networks

  [ "${NVCRE_ARP_FIX}" = "y" ] && arp_fix="true"

  step_title "NVIDIA Cluster Readiness test preparation (namespace: ${ns})"

  mkdir -p "${workdir}"
  src_file="${workdir}/webhook.py"

  local use_airgapped="${NVCRE_AIRGAPPED}"
  if [ "${NVCRE_AIRGAPPED_SET}" != "y" ]; then
    # Auto-detect: a cluster-wide Proxy object with httpProxy/httpsProxy set means
    # outbound traffic (registry pulls, package installs) must go through a proxy --
    # the signature of an air-gapped cluster like this one.
    local proxy_cfg
    proxy_cfg=$(oc get proxy cluster -o jsonpath='{.spec.httpProxy}{.spec.httpsProxy}' 2>/dev/null)
    if [ -n "${proxy_cfg}" ]; then
      use_airgapped="y"
      echo "Detected a cluster-wide proxy (oc get proxy cluster) -- using the air-gapped webhook variant."
    else
      use_airgapped="n"
    fi
  fi

  if [ "${use_airgapped}" = "y" ]; then
    [ "${NVCRE_AIRGAPPED_SET}" = "y" ] && echo "Using air-gapped webhook variant (forced via --nvcre-airgapped)."
    printf '%s\n' "${WEBHOOK_AIRGAPPED_PY_SRC}" > "${src_file}"
  else
    printf '%s\n' "${WEBHOOK_PY_SRC}" > "${src_file}"
  fi

  echo "1/7 Generating self-signed TLS CA + server certificate (CN=${svc}.${ns}.svc) ..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${workdir}/ca.key" -out "${workdir}/ca.crt" -days 3650 \
    -subj "/CN=nvcre-webhook-ca" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${workdir}/tls.key" -out "${workdir}/server.csr" \
    -subj "/CN=${svc}.${ns}.svc" 2>/dev/null
  openssl x509 -req -in "${workdir}/server.csr" \
    -CA "${workdir}/ca.crt" -CAkey "${workdir}/ca.key" -CAcreateserial \
    -out "${workdir}/tls.crt" -days 3650 \
    -extfile <(printf 'subjectAltName=DNS:%s.%s.svc,DNS:%s.%s.svc.cluster.local' "${svc}" "${ns}" "${svc}" "${ns}") \
    2>/dev/null
  if [ ! -s "${workdir}/tls.crt" ]; then
    echo "ERROR: TLS certificate generation failed -- is 'openssl' installed?" >&2
    return 1
  fi

  echo "2/7 Creating Secret/ConfigMap and labeling namespace '${ns}' ..."
  oc create secret tls webhook-tls -n "${ns}" \
    --cert="${workdir}/tls.crt" --key="${workdir}/tls.key" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc create configmap webhook-code -n "${ns}" \
    --from-file=webhook.py="${src_file}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label namespace "${ns}" nvcre-proxy-inject=true --overwrite >/dev/null

  echo "3/7 Deploying the webhook server (Deployment/Service '${svc}') ..."
  nvcre_deployment_yaml "${svc}" "${ns}" "${image}" "${arp_fix}" | oc apply -f -
  if ! oc rollout status "deployment/${svc}" -n "${ns}" --timeout=120s; then
    echo "ERROR: webhook Deployment did not become ready -- check 'oc get pods -n ${ns} -l app=${svc}' and its logs." >&2
    return 1
  fi

  echo "4/7 Registering MutatingWebhookConfiguration (fresh caBundle) ..."
  cabundle=$(base64 < "${workdir}/ca.crt" | tr -d '\n')
  nvcre_mwc_yaml "${svc}" "${ns}" "${cabundle}" | oc apply -f -

  echo "5/7 Granting SCC (privileged, anyuid) to the '${ns}' default service account ..."
  oc adm policy add-scc-to-user privileged -z default -n "${ns}" >/dev/null
  oc adm policy add-scc-to-user anyuid -z default -n "${ns}" >/dev/null

  echo "6/7 Smoke test -- confirming the webhook actually patches new pods ..."
  test_pod=$(cat <<SMOKEEOF
apiVersion: v1
kind: Pod
metadata:
  generateName: webhook-smoketest-
  namespace: ${ns}
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: registry.redhat.io/ubi9/ubi-minimal:latest
      command: ["sleep", "5"]
SMOKEEOF
  )
  echo "${test_pod}" | oc create -f - >/dev/null 2>&1
  sleep 3
  pod_name=$(oc get pods -n "${ns}" -o name 2>/dev/null | grep webhook-smoketest | tail -1)
  if [ -n "${pod_name}" ]; then
    networks=$(oc get "${pod_name}" -n "${ns}" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}' 2>/dev/null)
    if [ -n "${networks}" ]; then
      echo "    OK -- smoke-test pod received the macvlan NAD annotation."
    else
      echo "    WARNING: smoke-test pod has no NAD annotation -- check 'oc logs deployment/${svc} -n ${ns}'." >&2
    fi
    oc delete "${pod_name}" -n "${ns}" --ignore-not-found >/dev/null 2>&1
  else
    echo "    WARNING: could not find the smoke-test pod to verify -- check manually." >&2
  fi

  echo "7/7 Done."
  echo
  echo "Cluster is prepared -- users can now just run nvcrectl directly, e.g.:"
  echo "  nvcrectl setup status"
  echo "  nvcrectl workloadrun run --wait <file>.yaml"
  echo "When finished, clean up with:"
  echo "  ${SCRIPT_NAME} -T cleanup --nvcre-namespace ${ns}"
}

# nvcre_cleanup -- reverses everything nvcre_prepare did.
nvcre_cleanup() {
  local ns="${NVCRE_NAMESPACE}" svc="privileged-injector"
  step_title "NVIDIA Cluster Readiness test cleanup (namespace: ${ns})"

  echo "1/5 Deregistering the MutatingWebhookConfiguration ..."
  oc delete mutatingwebhookconfiguration nvcre-privileged-injector --ignore-not-found

  echo "2/5 Removing the webhook server (Deployment/Service/Secret/ConfigMap) ..."
  oc delete deployment "${svc}" -n "${ns}" --ignore-not-found
  oc delete service "${svc}" -n "${ns}" --ignore-not-found
  oc delete secret webhook-tls -n "${ns}" --ignore-not-found
  oc delete configmap webhook-code -n "${ns}" --ignore-not-found

  echo "3/5 Removing the '${ns}' namespace label ..."
  oc label namespace "${ns}" nvcre-proxy-inject- >/dev/null 2>&1 || true

  echo "4/5 Revoking SCC grants ..."
  oc adm policy remove-scc-from-user privileged -z default -n "${ns}" >/dev/null 2>&1 || true
  oc adm policy remove-scc-from-user anyuid -z default -n "${ns}" >/dev/null 2>&1 || true

  echo "5/5 Verifying nothing is left ..."
  echo "--- mutatingwebhookconfiguration ---"
  oc get mutatingwebhookconfiguration 2>/dev/null | grep -i nvcre || echo "(none)"
  echo "--- namespace '${ns}' resources ---"
  oc get all -n "${ns}" 2>/dev/null | grep -i "${svc}" || echo "(none)"
  echo "--- namespace label ---"
  oc get namespace "${ns}" --show-labels 2>/dev/null | grep -i nvcre-proxy-inject || echo "(label removed)"

  echo
  echo "Done. The cluster no longer auto-patches any pods for nvcrectl."
}

# nvcre_status -- shows whether nvcre_prepare's objects are currently present.
nvcre_status() {
  local ns="${NVCRE_NAMESPACE}" svc="privileged-injector"
  step_title "NVIDIA Cluster Readiness test prep status (namespace: ${ns})"

  echo "--- MutatingWebhookConfiguration ---"
  oc get mutatingwebhookconfiguration nvcre-privileged-injector 2>/dev/null || echo "(not present)"
  echo
  echo "--- Webhook Deployment/Service in '${ns}' ---"
  oc get deployment,service -n "${ns}" -l app="${svc}" 2>/dev/null || echo "(not present)"
  echo
  echo "--- Secret/ConfigMap in '${ns}' ---"
  oc get secret webhook-tls -n "${ns}" 2>/dev/null || echo "Secret/webhook-tls: (not present)"
  oc get configmap webhook-code -n "${ns}" 2>/dev/null || echo "ConfigMap/webhook-code: (not present)"
  echo
  echo "--- Namespace label ---"
  oc get namespace "${ns}" --show-labels 2>/dev/null | grep -i nvcre-proxy-inject || echo "(label not set)"
  echo
  echo "--- SCC grants (privileged/anyuid) for ${ns}/default ---"
  # 'oc adm policy add-scc-to-user' grants access via a RoleBinding to the
  # system:openshift:scc:<name> ClusterRole, not the SCC object's own .users
  # list (that field is legacy and stays empty for RBAC-based grants).
  if oc get rolebinding "system:openshift:scc:privileged" -n "${ns}" >/dev/null 2>&1; then
    echo "privileged: granted"
  else
    echo "privileged: not granted"
  fi
  if oc get rolebinding "system:openshift:scc:anyuid" -n "${ns}" >/dev/null 2>&1; then
    echo "anyuid: granted"
  else
    echo "anyuid: not granted"
  fi
}

# ---------------------------------------------------------------------------
# Step 1: cluster connectivity check (must pass before anything else runs)
# ---------------------------------------------------------------------------
check_oc_login

# -T is a standalone mode: dispatch and exit before any node-inventory logic.
if [ -n "${TESTPREP_ARG}" ]; then
  case "$(echo "${TESTPREP_ARG}" | tr '[:upper:]' '[:lower:]')" in
    prepare) nvcre_prepare; exit $? ;;
    cleanup) nvcre_cleanup; exit $? ;;
    status) nvcre_status; exit 0 ;;
    *)
      echo "ERROR: unknown -T value '${TESTPREP_ARG}' (expected prepare|cleanup|status)." >&2
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Defaults for everything the wizard/CLI can set, so the execution loop at
# the bottom always has them defined regardless of which path populated them.
# ---------------------------------------------------------------------------
PRINT_PCIE="n"; PRINT_PCIE_FAMILY="all"
PRINT_DEVICE="n"; PRINT_DEVICE_FAMILY="all"
PRINT_IFACE="n"; PRINT_IFACE_FAMILY="all"
PRINT_TABLE="n"; PRINT_ALLNET="n"; PRINT_BOND="n"; PRINT_OVS="n"
GEN_NNCP="n"
NNCP_FAMILY="cx8"; NNCP_MTU="9000"; NNCP_DIR="NNCP"; NNCP_CUSTOM_IFACES=""

if [ "${CLI_MODE_ACTIVE}" = "y" ]; then
  # -------------------------------------------------------------------------
  # Non-interactive / scriptable mode
  # -------------------------------------------------------------------------
  if [ -z "${NODES_ARG}" ] && [ -z "${ROLES_ARG}" ]; then
    echo "ERROR: -p/-g given without -n <nodes> or -r <roles>." >&2
    exit 1
  fi
  NODES=()
  [ -n "${NODES_ARG}" ] && resolve_nodes_from_arg "${NODES_ARG}"
  [ -n "${ROLES_ARG}" ] && resolve_roles_from_arg "${ROLES_ARG}"
  if [ ${#NODES[@]} -eq 0 ]; then
    echo "ERROR: no valid nodes resolved from -n '${NODES_ARG}' / -r '${ROLES_ARG}'." >&2
    exit 1
  fi
  [ -n "${PRINT_ARG}" ] && resolve_print_flags_from_arg "${PRINT_ARG}"
  [ -n "${GENERATE_ARG}" ] && resolve_generate_flags_from_arg "${GENERATE_ARG}"

  if [ -n "${CLI_IFACES}" ]; then
    NNCP_FAMILY="custom"; NNCP_CUSTOM_IFACES="${CLI_IFACES//,/ }"
  else
    NNCP_FAMILY="${CLI_FAMILY}"
  fi
  NNCP_MTU="${CLI_MTU}"; NNCP_DIR="${CLI_NNCP_DIR}"
else
  # -------------------------------------------------------------------------
  # Interactive wizard: nodes first, then the Print/Generate menu.
  # -------------------------------------------------------------------------
  step_title "Node selection"
  ask_single_choice "How do you want to select nodes?" 1 \
    "Discover nodes from the cluster (oc get nodes)" \
    "Select nodes by role label (node-role.kubernetes.io/<role>)" \
    "Enter node names manually"
  NODES=()
  if [ "${SINGLE_CHOICE_INDEX}" = "1" ]; then
    discovered_nodes=$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | sort)
    if [ -z "${discovered_nodes}" ]; then
      echo "No nodes returned by 'oc get nodes' -- check your oc login/context." >&2
      exit 1
    fi
    all_node_names=()
    while IFS= read -r n; do
      [ -n "$n" ] && all_node_names+=("$n")
    done <<< "${discovered_nodes}"
    all_node_names+=("All of the above")
    ask_multi_choice "Select node(s) (individually, comma-separated, or all):" "${all_node_names[@]}"
    last_index=${#all_node_names[@]}
    if multi_has "${last_index}"; then
      NODES=("${all_node_names[@]:0:$((last_index - 1))}")
    else
      for idx in "${MULTI_CHOICE_INDICES[@]}"; do
        NODES+=("${all_node_names[$((idx - 1))]}")
      done
    fi
  elif [ "${SINGLE_CHOICE_INDEX}" = "2" ]; then
    discovered_roles=$(oc get nodes --show-labels 2>/dev/null | tr ',' '\n' | grep '^node-role.kubernetes.io/' | sed -E 's#^node-role\.kubernetes\.io/([^=]+)=?$#\1#' | sort -u)
    if [ -z "${discovered_roles}" ]; then
      echo "No node-role labels found on the cluster." >&2
      exit 1
    fi
    all_role_names=()
    while IFS= read -r r; do
      [ -n "$r" ] && all_role_names+=("$r")
    done <<< "${discovered_roles}"
    ask_multi_choice "Select role(s):" "${all_role_names[@]}"
    for idx in "${MULTI_CHOICE_INDICES[@]}"; do
      resolve_roles_from_arg "${all_role_names[$((idx - 1))]}"
    done
    if [ ${#NODES[@]} -eq 0 ]; then
      echo "No nodes matched the selected role(s), aborting." >&2
      exit 1
    fi
  else
    ask_value "Enter node names (space or comma separated)" ""
    if [ -z "${VALUE_RESULT}" ]; then
      echo "No nodes entered, aborting." >&2
      exit 1
    fi
    read -r -a NODES <<< "${VALUE_RESULT//,/ }"
  fi

  if [ ${#NODES[@]} -eq 0 ]; then
    echo "No nodes selected, aborting." >&2
    exit 1
  fi

  step_title "What do you want to do?"
  ask_multi_choice "Select action(s):" \
    "Print information to console" \
    "Generate YAML artifacts"
  ACTION_PRINT="n"; ACTION_GENERATE="n"
  multi_has 1 && ACTION_PRINT="y"
  multi_has 2 && ACTION_GENERATE="y"

  if [ "${ACTION_PRINT}" = "y" ]; then
    ask_multi_choice "What do you want to print? (pick any combination)" \
      "Device names (mlx5_*, comma-separated list)" \
      "PCIe addresses (comma-separated list)" \
      "Interface names (comma-separated list, e.g. eno10np0)" \
      "Full RDMA device table (device/PCIe/iface/IP/adapter, always unfiltered)" \
      "All host network interfaces (type/master/driver/PCIe/adapter/IP)" \
      "Bond membership" \
      "br-ex (OVN-Kubernetes) port membership" \
      "Everything above"
    if multi_has 8; then
      PRINT_DEVICE="y"; PRINT_DEVICE_FAMILY="all"
      PRINT_PCIE="y"; PRINT_PCIE_FAMILY="all"
      PRINT_IFACE="y"; PRINT_IFACE_FAMILY="all"
      PRINT_TABLE="y"; PRINT_ALLNET="y"; PRINT_BOND="y"; PRINT_OVS="y"
    else
      multi_has 1 && PRINT_DEVICE="y"
      multi_has 2 && PRINT_PCIE="y"
      multi_has 3 && PRINT_IFACE="y"
      multi_has 4 && PRINT_TABLE="y"
      multi_has 5 && PRINT_ALLNET="y"
      multi_has 6 && PRINT_BOND="y"
      multi_has 7 && PRINT_OVS="y"
      if [ "${PRINT_DEVICE}" = "y" ] || [ "${PRINT_PCIE}" = "y" ] || [ "${PRINT_IFACE}" = "y" ]; then
        ask_single_choice "Device/PCIe/Interface: which adapter family should these use?" 4 \
          "ConnectX-7 (standalone, excludes BlueField)" \
          "ConnectX-8" \
          "BlueField (any generation, e.g. BlueField-3/ConnectX-7)" \
          "All adapters (no filter)"
        case "${SINGLE_CHOICE_INDEX}" in
          1) PRINT_DEVICE_FAMILY="cx7"; PRINT_PCIE_FAMILY="cx7"; PRINT_IFACE_FAMILY="cx7" ;;
          2) PRINT_DEVICE_FAMILY="cx8"; PRINT_PCIE_FAMILY="cx8"; PRINT_IFACE_FAMILY="cx8" ;;
          3) PRINT_DEVICE_FAMILY="bf"; PRINT_PCIE_FAMILY="bf"; PRINT_IFACE_FAMILY="bf" ;;
          4) PRINT_DEVICE_FAMILY="all"; PRINT_PCIE_FAMILY="all"; PRINT_IFACE_FAMILY="all" ;;
        esac
      fi
    fi
  fi

  if [ "${ACTION_GENERATE}" = "y" ]; then
    GEN_NNCP="y"
    step_title "NNCP options"
    ask_single_choice "NNCP: which interfaces should be included?" 1 \
      "ConnectX-8 RDMA interfaces (auto-detected)" \
      "ConnectX-7 RDMA interfaces (auto-detected, excludes BlueField)" \
      "BlueField RDMA interfaces (auto-detected, e.g. BlueField-3/ConnectX-7)" \
      "All RDMA interfaces, any adapter (auto-detected)" \
      "Custom list (enter interface names manually)"
    case "${SINGLE_CHOICE_INDEX}" in
      1) NNCP_FAMILY="cx8" ;;
      2) NNCP_FAMILY="cx7" ;;
      3) NNCP_FAMILY="bf" ;;
      4) NNCP_FAMILY="all" ;;
      5) NNCP_FAMILY="custom"
         ask_value "NNCP: enter interface names (space separated, applied per-node)" ""
         NNCP_CUSTOM_IFACES="${VALUE_RESULT}" ;;
    esac
    ask_value "NNCP: MTU" "9000"; NNCP_MTU="${VALUE_RESULT}"
    ask_value "NNCP: output directory" "NNCP"; NNCP_DIR="${VALUE_RESULT}"
  fi

  step_title "Summary"
  echo "Nodes            : ${NODES[*]}"
  echo "Print to console : ${ACTION_PRINT}"
  [ "${PRINT_DEVICE}" = "y" ] && echo "  - Device names (family=${PRINT_DEVICE_FAMILY})"
  [ "${PRINT_PCIE}" = "y" ] && echo "  - PCIe addresses (family=${PRINT_PCIE_FAMILY})"
  [ "${PRINT_IFACE}" = "y" ] && echo "  - Interface names (family=${PRINT_IFACE_FAMILY})"
  [ "${PRINT_TABLE}" = "y" ] && echo "  - Full RDMA device table"
  [ "${PRINT_ALLNET}" = "y" ] && echo "  - All host network interfaces"
  [ "${PRINT_BOND}" = "y" ] && echo "  - Bond membership"
  [ "${PRINT_OVS}" = "y" ] && echo "  - br-ex port membership"
  echo "Generate NNCP     : ${GEN_NNCP}"
  [ "${GEN_NNCP}" = "y" ] && echo "  - family=${NNCP_FAMILY} mtu=${NNCP_MTU} dir=${NNCP_DIR}"
  echo
  ask_yesno "Proceed with the above?" "y"
  if [ "${YESNO_RESULT}" = "n" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Data-collection scripts (run inside `oc debug node/<node> -- chroot /host`)
# ---------------------------------------------------------------------------
RDMA_SCRIPT='
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
'

ALLNET_SCRIPT='
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
'

BOND_SCRIPT='
for b in /sys/class/net/*/bonding; do
  [ -d "$b" ] || continue
  bond=$(basename "$(dirname "$b")")
  slaves=$(cat "$b/slaves" 2>/dev/null)
  echo "${bond}: ${slaves:-"(none)"}"
done
'

OVS_SCRIPT='
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
'

# family_values <field: devs|pcies|ifaces> <family: cx7|cx8|bf|all>
# -> sets FAMVALS array (bash-3.2-safe: eval, same trick as dedup_append)
family_values() {
  local field="$1" family="$2" src="${2}_${1}"
  eval "FAMVALS=(\"\${${src}[@]}\")"
}

for node in "${NODES[@]}"; do
  echo
  echo "################################################################"
  echo "### ${node}"
  echo "################################################################"

  raw_rdma=$(oc debug "node/${node}" -- chroot /host bash -c "${RDMA_SCRIPT}" 2>&1 | grep -E '^[a-z0-9_]+\|' || true)

  all_devs=(); all_pcies=(); all_ifaces=()
  cx8_devs=(); cx8_pcies=(); cx8_ifaces=()
  cx7_devs=(); cx7_pcies=(); cx7_ifaces=()
  bf_devs=(); bf_pcies=(); bf_ifaces=()
  while IFS='|' read -r dev pcie iface ip adapter; do
    [ -z "${dev}" ] && continue
    all_devs+=("${dev}"); all_pcies+=("${pcie}")
    [ "${iface}" != "-" ] && all_ifaces+=("${iface}")
    # Check BlueField first: a BlueField-3/ConnectX-7 adapter string also
    # contains "ConnectX-7", so it must not fall through to the cx7 bucket.
    if [[ "${adapter}" == *BlueField* ]]; then
      bf_devs+=("${dev}"); bf_pcies+=("${pcie}")
      [ "${iface}" != "-" ] && bf_ifaces+=("${iface}")
    elif [[ "${adapter}" == *ConnectX-8* ]]; then
      cx8_devs+=("${dev}"); cx8_pcies+=("${pcie}")
      [ "${iface}" != "-" ] && cx8_ifaces+=("${iface}")
    elif [[ "${adapter}" == *ConnectX-7* ]]; then
      cx7_devs+=("${dev}"); cx7_pcies+=("${pcie}")
      [ "${iface}" != "-" ] && cx7_ifaces+=("${iface}")
    fi
  done <<< "${raw_rdma}"

  if [ "${PRINT_TABLE}" = "y" ]; then
    echo
    echo "--- Full RDMA device table ---"
    printf "%-10s %-14s %-16s %-18s %-24s\n" "DEVICE" "PCIE" "INTERFACE" "IP" "ADAPTER"
    printf "%-10s %-14s %-16s %-18s %-24s\n" "------" "----" "---------" "--" "-------"
    while IFS='|' read -r dev pcie iface ip adapter; do
      [ -z "${dev}" ] && continue
      printf "%-10s %-14s %-16s %-18s %-24s\n" "${dev}" "${pcie}" "${iface}" "${ip}" "${adapter}"
    done <<< "${raw_rdma}"
  fi

  if [ "${PRINT_DEVICE}" = "y" ]; then
    family_values devs "${PRINT_DEVICE_FAMILY}"
    echo
    echo "Device names (${PRINT_DEVICE_FAMILY}) : $(IFS=,; echo "${FAMVALS[*]:-}")"
  fi
  if [ "${PRINT_PCIE}" = "y" ]; then
    family_values pcies "${PRINT_PCIE_FAMILY}"
    echo "PCIe addresses (${PRINT_PCIE_FAMILY}) : $(IFS=,; echo "${FAMVALS[*]:-}")"
  fi
  if [ "${PRINT_IFACE}" = "y" ]; then
    family_values ifaces "${PRINT_IFACE_FAMILY}"
    echo "Interface names (${PRINT_IFACE_FAMILY}) : $(IFS=,; echo "${FAMVALS[*]:-}")"
  fi

  if [ "${PRINT_ALLNET}" = "y" ]; then
    echo
    echo "--- All network interfaces ---"
    printf "%-14s %-14s %-10s %-10s %-14s %-30s %-18s\n" "INTERFACE" "TYPE" "MASTER" "DRIVER" "PCIE" "ADAPTER" "IP"
    printf "%-14s %-14s %-10s %-10s %-14s %-30s %-18s\n" "---------" "----" "------" "------" "----" "-------" "--"
    oc debug "node/${node}" -- chroot /host bash -c "${ALLNET_SCRIPT}" 2>&1 \
      | grep -E '^[a-zA-Z0-9@._-]+\|' \
      | while IFS='|' read -r iface type master driver pcie adapter ip; do
          printf "%-14s %-14s %-10s %-10s %-14s %-30s %-18s\n" "${iface}" "${type}" "${master}" "${driver}" "${pcie}" "${adapter}" "${ip}"
        done || true
  fi

  if [ "${PRINT_BOND}" = "y" ]; then
    echo
    echo "--- Bond membership ---"
    (oc debug "node/${node}" -- chroot /host bash -c "${BOND_SCRIPT}" 2>&1 | grep -E '^[a-zA-Z0-9]+:') || echo "(no bonds found)"
  fi

  if [ "${PRINT_OVS}" = "y" ]; then
    echo
    echo "--- br-ex (OVN-Kubernetes) port membership ---"
    (oc debug "node/${node}" -- chroot /host bash -c "${OVS_SCRIPT}" 2>&1 | grep -E '^(br-ex|ovs-vsctl)') || true
  fi

  # --- NNCP generation (per node) ---
  if [ "${GEN_NNCP}" = "y" ]; then
    echo
    echo "--- NNCP generation (${node}) ---"
    case "${NNCP_FAMILY}" in
      cx8) nncp_ifaces=("${cx8_ifaces[@]}") ;;
      cx7) nncp_ifaces=("${cx7_ifaces[@]}") ;;
      bf) nncp_ifaces=("${bf_ifaces[@]}") ;;
      all) nncp_ifaces=("${all_ifaces[@]}") ;;
      custom) read -r -a nncp_ifaces <<< "${NNCP_CUSTOM_IFACES}" ;;
      *) nncp_ifaces=() ;;
    esac
    if [ "${#nncp_ifaces[@]}" -gt 0 ]; then
      generate_nncp_yaml "${NNCP_DIR}" "${NNCP_MTU}" "${node}" "${nncp_ifaces[@]}"
    else
      echo "(no matching interfaces for ${node}, nothing generated)"
    fi
  fi
done

echo
echo "Done."
