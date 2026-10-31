# Cluster Utility Script — Usage Guide

[cluster-utility.sh](cluster-utility.sh) (bash) and [cluster-utility.ps1](cluster-utility.ps1) (PowerShell) are two functionally-equivalent variants of the same tool: an OpenShift cluster NIC inventory and YAML artifact generator, plus an `nvcrectl` test-prep helper. Pick whichever matches your shell — macOS/Linux use the `.sh`, Windows uses the `.ps1` — the flags below map 1:1 between them.

Both scripts are self-contained (no helper files) and verify cluster connectivity with `oc get nodes` before doing anything else; if that fails they tell you to `oc login` first.

## What It Does

For each selected node, it inspects host networking via `oc debug node/<node>`:

- **RDMA (`mlx5_*`) devices** — device name, PCIe address, netdev interface, host-level IP (if any), and adapter model (ConnectX-7, ConnectX-8, BlueField).
- **All host network interfaces** — type, bond/bridge master, driver, PCIe adapter model, and IP address.
- **Bond member interfaces.**
- **`br-ex` (OVN-Kubernetes external bridge) port membership.**

It can also generate `NodeNetworkConfigurationPolicy` (NNCP) YAMLs directly from the interfaces it finds, and separately, prepare/clean up everything an `nvcrectl` test run needs (privileged pods, macvlan RDMA network attachments) via a small mutating admission webhook.

## Two Modes

| Mode | How it's triggered | Behavior |
| --- | --- | --- |
| **Non-interactive / scriptable** | Any of `-n`/`-r`/`-p`/`-g` (bash) or `-Nodes`/`-Roles`/`-Print`/`-Generate` (PowerShell) is passed | Runs silently, no prompts — safe for scripting/CI |
| **Interactive wizard** | None of those flags are passed | Walks through node selection (discover from cluster, select by role label, or enter manually), then an hdblcm-style numbered menu: 1) Print information to console, 2) Generate YAML artifacts — each with its own sub-menu — followed by a summary and confirmation before anything runs |

`-T`/`-TestPrep` always runs standalone and ignores every other flag above.

## Flag Reference (bash → PowerShell)

| bash (`cluster-utility.sh`) | PowerShell (`cluster-utility.ps1`) | Purpose |
| --- | --- | --- |
| `-n <nodes>` | `-Nodes <list>` | Comma-separated node names, or `all` for every cluster node |
| `-r <roles>` | `-Roles <list>` | Comma-separated `node-role.kubernetes.io/<role>` labels (the `ROLES` column of `oc get nodes`). Combines with `-n`/`-Nodes` (union, deduped) |
| `-p <codes>` | `-Print <codes>` | What to print to console (see [Print Codes](#print-codes)) |
| `-g <codes>` | `-Generate <codes>` | What artifacts to generate (see [Generate Codes](#generate-codes)) |
| `--family <cx8\|cx7\|all>` | `-Family <cx8\|cx7\|all>` | Which interface family to use for `nncp`/`macvlan`/`nicnodepolicy` generation (default: `cx8`) |
| `--ifaces "<names>"` | `-Ifaces "<names>"` | Custom space/comma-separated interface list — overrides `--family`/`-Family` |
| `--mtu <n>` | `-Mtu <n>` | MTU, used by `nncp` and `macvlan` (default: `9000`) |
| `--nncp-dir <dir>` | `-NncpDir <dir>` | NNCP output directory (default: `NNCP`) |
| `--nncp-template <file>` | `-NncpTemplate <file>` | NNCP template to render (default: [Templates/nmstate/interface.yaml](../Templates/nmstate/interface.yaml)) |
| `--gpu-dir <dir>` | `-GpuDir <dir>` | `nvdriver` output directory (default: `GPU-Operator`) |
| `--network-dir <dir>` | `-NetworkDir <dir>` | `nicnodepolicy`/`macvlan`/`nicconfig-be`/`nicconfig-st` output directory (default: `Network-Operator`) |
| `--nvdriver-template <file>` | `-NvdriverTemplate <file>` | Template (default: [Templates/gpu-operator/nvidiadriver.yaml](../Templates/gpu-operator/nvidiadriver.yaml)) |
| `--nicnodepolicy-template <file>` | `-NicNodePolicyTemplate <file>` | Template (default: [Templates/network-operator/nicnodepolicy.yaml](../Templates/network-operator/nicnodepolicy.yaml)) |
| `--macvlan-template <file>` | `-MacvlanTemplate <file>` | Template (default: [Templates/network-operator/macvlan.yaml](../Templates/network-operator/macvlan.yaml)) |
| `--nicconfig-be-template <file>` | `-NicConfigBeTemplate <file>` | Template (default: [Templates/network-operator/nicconfig-be.yaml](../Templates/network-operator/nicconfig-be.yaml)) |
| `--nicconfig-st-template <file>` | `-NicConfigStTemplate <file>` | Template (default: [Templates/network-operator/nicconfig-st.yaml](../Templates/network-operator/nicconfig-st.yaml)) |
| `--nicconfig-be-family <cx8\|cx7\|bf\|all>` | `-NicConfigBeFamily <...>` | PCIe-address source family for `nicconfig-be` (default: `cx8`) |
| `--nicconfig-st-family <cx8\|cx7\|bf\|all>` | `-NicConfigStFamily <...>` | PCIe-address source family for `nicconfig-st` (default: `bf` — storage NICs on this fleet are BlueField-3/ConnectX-7, not standalone ConnectX-7) |
| `--clusterpolicy-template <file>` | `-ClusterPolicyTemplate <file>` | `ClusterPolicy` singleton template (default: [Templates/gpu-operator/clusterpolicy.yaml](../Templates/gpu-operator/clusterpolicy.yaml)) |
| `--nicclusterpolicy-template <file>` | `-NicClusterPolicyTemplate <file>` | `NicClusterPolicy` singleton template (default: [Templates/network-operator/nicclusterpolicy.yaml](../Templates/network-operator/nicclusterpolicy.yaml)) |
| `-T <mode>` | `-TestPrep <mode>` | `nvcrectl` test prepare/cleanup/status (see [Test-Prep Mode](#test-prep-mode-t--testprep)) |
| `--nvcre-namespace <ns>` | `-NvcreNamespace <ns>` | Namespace `nvcrectl` runs test pods in (default: `default`) |
| `--nvcre-airgapped` | `-NvcreAirgapped` | Force the air-gapped webhook variant (injects proxy env vars into test pods). Auto-detected via `oc get proxy cluster` otherwise |
| `--nvcre-arp-fix` | `-NvcreArpFix` | Also apply the ARP/RPF sysctl postStart fix for multi-homed RoCE NICs (default: off) |
| `--nvcre-image <image>` | `-NvcreImage <image>` | Webhook server base image (default: `registry.redhat.io/ubi9/python-312-minimal:latest`) |
| `--nvcre-workdir <dir>` | `-NvcreWorkDir <dir>` | Scratch directory for generated TLS material (default: `/tmp/nvcre-wh`, or the OS temp dir on PowerShell) |
| `-h`, `--help` | `-Help` (alias `-h`) | Show full help and exit |

## Print Codes

Pass any combination via `-p`/`-Print`. `device`, `pcie`, and `iface` accept an optional `:<family>` sub-code (`cx7`, `cx8`, `bf`, or `all` — default `all`):

| Code | Output |
| --- | --- |
| `device[:family]` | RDMA device names (comma list, e.g. `mlx5_0`) |
| `pcie[:family]` | PCIe addresses (comma list) |
| `iface[:family]` | Interface names (comma list, e.g. `eno10np0`) |
| `table` | Full RDMA device table (always unfiltered) |
| `net` | All host network interfaces (bonds/`br-ex`/IPs) |
| `bond` | Bond membership |
| `br-ex` | `br-ex` (OVN-Kubernetes) port membership |
| `all` | Everything above — `device`/`pcie`/`iface` with `family=all`, plus `table`/`net`/`bond`/`br-ex` |

Families: `cx7` = standalone ConnectX-7, `cx8` = ConnectX-8, `bf` = BlueField (any generation — note a BlueField adapter's string literally contains "ConnectX-7", which this family filter correctly distinguishes), `all` = no filter.

## Generate Codes

Each code renders its artifact from a template under [Templates/](../Templates/) — to support a new hardware model (e.g. a different NIC/driver bundle), drop in new templates (or point the matching `--*-template` flag at them) instead of editing the script.

| Code | Artifact | Scope | Template |
| --- | --- | --- | --- |
| `nncp` | `NodeNetworkConfigurationPolicy` | one per node × interface | [Templates/nmstate/interface.yaml](../Templates/nmstate/interface.yaml) |
| `nvdriver` | `NVIDIADriver` (GPU Operator) | one per node | [Templates/gpu-operator/nvidiadriver.yaml](../Templates/gpu-operator/nvidiadriver.yaml) |
| `nicnodepolicy` | `NicNodePolicy` (Network Operator) | one per node | [Templates/network-operator/nicnodepolicy.yaml](../Templates/network-operator/nicnodepolicy.yaml) |
| `macvlan` | `MacvlanNetwork` (Network Operator) | one per **unique interface** across all selected nodes, not per node | [Templates/network-operator/macvlan.yaml](../Templates/network-operator/macvlan.yaml) |
| `nicconfig-be` | `NicConfigurationTemplate` (backend) | one per node, PCIe addresses from the `cx8` family by default | [Templates/network-operator/nicconfig-be.yaml](../Templates/network-operator/nicconfig-be.yaml) |
| `nicconfig-st` | `NicConfigurationTemplate` (storage) | one per node, PCIe addresses from the `cx7` family by default | [Templates/network-operator/nicconfig-st.yaml](../Templates/network-operator/nicconfig-st.yaml) |
| `all` | Everything above | — | — |

`nncp`, `macvlan`, and `nicnodepolicy` all draw their interface list from the same `--family`/`--ifaces` selection (default `cx8`). `nicconfig-be`/`nicconfig-st` instead draw PCIe addresses from their own independent `--nicconfig-be-family`/`--nicconfig-st-family` (default `cx8`/`bf`), since they're QoS templates keyed on physical NIC placement rather than the RDMA interface set. The storage NICs (`nicType: a2dc` in [nicconfig-st.yaml](../Templates/network-operator/nicconfig-st.yaml)) are BlueField-3 integrated ConnectX-7 devices — their `lspci` string contains "ConnectX-7" but the script's adapter classifier checks for `BlueField` first, so they land in the `bf` bucket, not `cx7`.

### Cluster-wide singletons (ClusterPolicy / NicClusterPolicy)

`ClusterPolicy` and `NicClusterPolicy` are cluster-wide (one per cluster, no per-node fields), so they aren't looped per node/interface like the codes above. Instead, they're copied verbatim (overwriting any existing copy) whenever a generate request touches their operator, so the output directory is a complete, ready-to-apply set for GitOps/ArgoCD:

- Any `nvdriver` request also copies [Templates/gpu-operator/clusterpolicy.yaml](../Templates/gpu-operator/clusterpolicy.yaml) → `--gpu-dir`/`-GpuDir` as `clusterpolicy.yaml`.
- Any of `nicnodepolicy`/`macvlan`/`nicconfig-be`/`nicconfig-st` also copies [Templates/network-operator/nicclusterpolicy.yaml](../Templates/network-operator/nicclusterpolicy.yaml) → `--network-dir`/`-NetworkDir` as `nicclusterpolicy.yaml`.

Override the source template with `--clusterpolicy-template`/`-ClusterPolicyTemplate` and `--nicclusterpolicy-template`/`-NicClusterPolicyTemplate`.

## Test-Prep Mode (`-T` / `-TestPrep`)

`nvcrectl`'s `WorkloadRun`/`Certification` pods have no field to request a privileged security context or attach extra macvlan RDMA networks. This mode installs (or removes) a small mutating admission webhook that patches those pods automatically, so you never touch certs/webhooks/SCCs by hand — just run `nvcrectl` itself afterward.

| Mode | Effect |
| --- | --- |
| `prepare` | Generates a self-signed TLS CA + server cert, creates the Secret/ConfigMap, deploys the webhook server (Deployment/Service), registers the `MutatingWebhookConfiguration` with a fresh `caBundle`, labels the namespace, grants the `privileged`/`anyuid` SCCs, and runs a smoke-test pod to confirm it works |
| `cleanup` | Reverses everything `prepare` did (webhook config, Deployment/Service/Secret/ConfigMap, namespace label, SCC grants) |
| `status` | Shows whether `prepare`'s objects are currently present, without changing anything |

## Examples

```bash
# Interactive wizard
./cluster-utility.sh

# All nodes: print PCIe + device names for ConnectX-8 only
./cluster-utility.sh -n all -p pcie:cx8,device:cx8

# Select nodes by role label, print BlueField interfaces + full RDMA table
./cluster-utility.sh -r gpuworker880 -p iface:bf,table

# Generate NNCPs for two named nodes, ConnectX-8 family, MTU 9000 (default)
./cluster-utility.sh -n worker3,worker4 -p all -g nncp --family cx8

# Generate everything (NNCP, NVIDIADriver, NicNodePolicy, Macvlan, NicConfig be+st)
./cluster-utility.sh -n worker3,worker4 -g all

# Generate just the GPU/network-operator node-specific artifacts for a role
./cluster-utility.sh -r gpuworker880 -g nvdriver,nicnodepolicy,nicconfig-be,nicconfig-st

# Prepare / clean up the nvcrectl privileged-injector webhook
./cluster-utility.sh -T prepare --nvcre-namespace default
./cluster-utility.sh -T cleanup --nvcre-namespace default
```

```powershell
# Interactive wizard
./cluster-utility.ps1

# All nodes: print PCIe + device names for ConnectX-8 only
./cluster-utility.ps1 -Nodes all -Print pcie:cx8,device:cx8

# Select nodes by role label, print BlueField interfaces + full RDMA table
./cluster-utility.ps1 -Roles gpuworker880 -Print iface:bf,table

# Generate NNCPs for two named nodes, ConnectX-8 family, MTU 9000 (default)
./cluster-utility.ps1 -Nodes worker3,worker4 -Print all -Generate nncp -Family cx8

# Generate everything (NNCP, NVIDIADriver, NicNodePolicy, Macvlan, NicConfig be+st)
./cluster-utility.ps1 -Nodes worker3,worker4 -Generate all

# Generate just the GPU/network-operator node-specific artifacts for a role
./cluster-utility.ps1 -Roles gpuworker880 -Generate nvdriver,nicnodepolicy,nicconfig-be,nicconfig-st

# Prepare / clean up the nvcrectl privileged-injector webhook
./cluster-utility.ps1 -TestPrep prepare -NvcreNamespace default
./cluster-utility.ps1 -TestPrep cleanup -NvcreNamespace default
```

Run with `-h`/`--help` (bash) or `-Help` (PowerShell) at any time to see this same reference printed from the script itself — the flags are kept in sync between the two variants.

## Generated Artifacts

The YAMLs produced by `-g`/`-Generate` are what get applied to the cluster to configure each node's desired network/driver/QoS state.
