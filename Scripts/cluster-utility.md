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
| `-g <codes>` | `-Generate <codes>` | What artifacts to generate (currently: `nncp`) |
| `--family <cx8\|cx7\|all>` | `-Family <cx8\|cx7\|all>` | Which interface family to use for generation (default: `cx8`) |
| `--ifaces "<names>"` | `-Ifaces "<names>"` | Custom space/comma-separated interface list — overrides `--family`/`-Family` |
| `--mtu <n>` | `-Mtu <n>` | MTU for generated YAMLs (default: `9000`) |
| `--nncp-dir <dir>` | `-NncpDir <dir>` | NNCP output directory (default: `NNCP`) |
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

| Code | Artifact |
| --- | --- |
| `nncp` | `NodeNetworkConfigurationPolicy` YAMLs, one per selected node/interface, written to `--nncp-dir`/`-NncpDir` |

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

# Prepare / clean up the nvcrectl privileged-injector webhook
./cluster-utility.ps1 -TestPrep prepare -NvcreNamespace default
./cluster-utility.ps1 -TestPrep cleanup -NvcreNamespace default
```

Run with `-h`/`--help` (bash) or `-Help` (PowerShell) at any time to see this same reference printed from the script itself — the flags are kept in sync between the two variants.

## Generated NNCPs

The NNCP YAMLs produced by `-g nncp`/`-Generate nncp` are what get applied to the cluster to configure each node's desired network state — see [nmstate/](../nmstate/) for the set already applied on this cluster, and [docs/NewOrderOfOperations.md](../docs/NewOrderOfOperations.md) (local to this workspace) for where this step fits in the overall build sequence.
