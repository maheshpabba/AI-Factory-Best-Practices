# AI-Factory Best Practices

Operational procedures, configuration examples, and validation workloads for GPU infrastructure and AI factories.

## Repository Layout

| Directory | Contents |
| --- | --- |
| `docs/` | Operational procedures and supporting documentation |
| `GPU-Operator/` | NVIDIA GPU Operator configuration |
| `network-Operator/` | Network Operator and NIC configuration |
| `nmstate/` | Node network state and policy manifests |
| `nccl-training-tests/` | NCCL and training test manifests |
| `nvcre-workloadruns/` | NVIDIA Cluster Readiness Engine workloads and results |
| `Scripts/` | Cluster utility scripts |
| `switch-configs/` | Switch configuration examples |
| `Misc/` | Supporting infrastructure manifests and commands |

The table describes the development collection. Only selected directories may be present on `main`.

## Branches And Publication

- `Dev` contains the working collection.
- `main` contains only explicitly selected, reviewed material.
- This is a public repository: **both branches and their commit histories are publicly readable**. Branch protection can restrict changes, not reading.
- Confidential development requires a separate private repository. Never push confidential content to either branch here.

Keep the initial `main` history independent of `Dev`. Publish approved file snapshots in a clean working tree based on `main`; do not merge `Dev` or cherry-pick commits that contain unapproved files. Review the staged diff before every publication. Deleting a file later does not remove it from public Git history.

## Before Using Or Publishing

These files include environment-specific examples, not universally applicable production defaults. Review node names, network interfaces, addresses, storage paths, image versions, and resource requirements before applying them. Follow the relevant procedure and your environment's change-control requirements.

Before pushing to either branch:

1. Review every staged file for credentials, private keys, tokens, customer identifiers, and confidential infrastructure details.
2. Sanitize configuration snapshots, logs, and test results where necessary. Ignore rules are not a security scan.
3. Validate changed manifests and commands in an appropriate test environment.
4. Confirm that documentation links and referenced files exist on the destination branch.

## Contribution Workflow

Develop on `Dev` or short-lived branches based on it. Use reviewed pull requests for changes. Publish to `main` only after the repository owner approves the exact files and their contents.

Configure GitHub rulesets for both branches to require pull requests and prevent force pushes and deletion where supported. Available enforcement depends on the account plan and repository settings; it does not make either branch private.