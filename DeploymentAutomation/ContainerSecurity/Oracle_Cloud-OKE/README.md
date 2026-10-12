# Automated Container Security Deployment on OKE (OCI)

This folder mirrors the **OKE** process (`DeploymentAutomation/ContainerSecurity/Oracle Cloud-OKE/OKE-RunCommand`) for **Oracle Cloud Infrastructure (OCI) - Oracle Kubernetes Engine (OKE)**.

The goal is identical: automate the deployment of **Trend Vision One - Container Security** in large-scale OCI environments with a single script that **discovers every cluster across every region and every compartment** of the tenancy — and, equally important, can **uninstall in mass** the same chart from every cluster that has it.

## Objective

- **Full coverage in one pass**: one script scans the tenancy (or a subset) and deploys/upgrades Container Security on every matching OKE cluster.
- **Brownfield-friendly**: designed for existing clusters, without requiring protection at provisioning time.
- **Repeatable / auditable**: per-cluster logs, TSV summary, consolidated `deployment.log` per run.
- **Drift remediation**: re-running the script upgrades clusters already registered in Vision One and installs on the rest.

## How discovery works

1. **Tenancy** – the OCID is read from the OCI CLI config (or `TENANCY_OCID`).
2. **Regions** – one region per OCI CLI call; by default the tenancy's subscribed regions (`OCI_REGION` overrides to a single region).
3. **Compartments** – recursive list of all accessible compartments (including the tenancy root), with AD-local compartments excluded. `COMPARTMENTS` restricts to an explicit list.
4. **Clusters** – for every region x compartment combination, OKE clusters are listed and filtered by lifecycle state (default `ACTIVE`) and optional freeform tags (`OKE_TAG_FILTER`, e.g. `env=prod`).
5. **Deployment** – each cluster gets its own kubeconfig (generated via the OCI CLI) and a Vision One pre-check decides between **upgrade** (already registered) and **fresh install** (new registration).

## Requirements

| Requirement | Notes |
| --- | --- |
| OCI CLI (`oci`) | Authenticated. Works from Cloud Shell (default) or a machine with `~/.oci/config`. |
| `jq`, `git`, `curl` | Also required on the run machine. |
| `helm`, `kubectl` | Required on the run machine. |
| IAM policies on the caller | `read` on compartments, clusters and the tenancy; `use clusters` for `create-kubeconfig`. Example: `allow group <group> to read all-resources in tenancy` + `allow group <group> to use cluster-node-pools in tenancy`. |
| Vision One API key | Set `V1_API_KEY` (same key used by the OKE script; the registration secret `trendmicro-container-security-registration-key` is created automatically). |
| Network access to the API endpoint | Private-endpoint OKE clusters require running the script from a host with access to the cluster VCN (Cloud Shell with `--auth security_token` or a bastion). Unreachable clusters are reported as `FAILED_UNREACHABLE` and clearly marked. |

## Script

- **File:** [scripts/deploy-cs-oke.sh](scripts/deploy-cs-oke.sh)
- **Language:** Bash (`set -uo pipefail`), no external dependencies beyond the CLI/CLIs listed above.
- **Chart:** `trendmicro/visionone-container-security-helm` (GitHub tarball), latest stable tag by default (`TARGET_VERSION=latest`) or pinned (e.g. `TARGET_VERSION=3.5.1`).
- **Overrides:** generated per run as `overrides.yaml` (namespaces exclusions, scanning features on/off, resource limits, tolerations, image registry/project/tag). Adjust the variables at the top of the script to change the defaults.

## Usage

```bash
# 1. Discover + preview every cluster the script would touch (no changes)
DRY_RUN=true  V1_API_KEY=<your-key> ./scripts/deploy-cs-oke.sh

# 2. Deploy (interactive confirmation; skip it with AUTO_APPROVE=true)
V1_API_KEY=<your-key> AUTO_APPROVE=true ./scripts/deploy-cs-oke.sh

# 3. Mass uninstall Container Security from every cluster (no chart resolution)
UNINSTALL=true V1_API_KEY=<your-key> AUTO_APPROVE=true ./scripts/deploy-cs-oke.sh
```

The uninstall mode runs the exact same discovery, then on every cluster:
`kubectl` connectivity check → `helm uninstall <release>` → (optional, default off) delete the namespace → (optional, default on) deregister the cluster in Vision One via DELETE.

```bash
# Keep the namespace, do NOT deregister in Vision One
UNINSTALL=true UNINSTALL_DELETE_NAMESPACE=false V1_DEREGISTER_ON_UNINSTALL=false ./scripts/deploy-cs-oke.sh
```

Uninstall never resolves the Helm chart, so it does not need network access to GitHub and runs even when `TARGET_VERSION` is stale.

Expected output of step 1:

```
================================================================================
 DEPLOYMENT TARGET SUMMARY
================================================================================
#    REGION           COMPARTMENT              CLUSTER
---- ---------------- ------------------------ --------------------------------
1    us-ashburn-1     prod                      oke-prod-1
2    eu-frankfurt-1   prod                      oke-fra-1
...
================================================================================
```

## Configuration variables

| Variable | Default | Description |
| --- | --- | --- |
| `V1_API_KEY` | *(required)* | Container Security API key. |
| `GITHUB_REPO` | `trendmicro/visionone-container-security-helm` | Chart repository (GitHub) used to resolve the chart. |
| `TARGET_VERSION` | `latest` | `latest` resolves the newest stable tag; otherwise pin a version, e.g. `3.5.1`. |
| `CHART_URL` | auto | Override the chart URL (e.g. a private mirror). |
| `OCI_REGION` | tenancy subscriptions | Restrict to one region (ends with `-1`, e.g. `us-ashburn-1`). |
| `COMPARTMENTS` | all accessible | Comma-separated compartment OCIDs, or `root` for the tenancy root only. |
| `INCLUDE_ROOT_COMPARTMENT` | `true` | Also scan the tenancy root itself when scanning all compartments. |
| `TENANCY_OCID` | from CLI config | Explicit tenancy OCID (needed when the config cannot be parsed, e.g. instance principals). |
| `OCI_PROFILE` | CLI default | OCI CLI config profile to use. |
| `OCI_CLI_AUTH` | unset | Forwarded to every `oci` call: `instance_principal` (compute/Cloud Shell) or `security_token` (session tokens). |
| `OKE_STATE_FILTER` | `ACTIVE` | Comma-separated lifecycle states to deploy to. |
| `OKE_TAG_FILTER` | unset | Freeform tags, `Key=Value[,Key=Value]` (e.g. `env=prod`). |
| `NAMESPACE` | `trendmicro-system` | Kubernetes namespace for the Helm release. |
| `RELEASE` | `trendmicro` | Helm release name. |
| `TIMEOUT` | `10m` | Helm `--timeout` per cluster. |
| `MAX_PARALLEL` | `4` | Maximum concurrent cluster deployments. |
| `GROUP_ID` | `...000002` | Vision One group ID assigned to new clusters. |
| `IMAGE_REGISTRY` / `IMAGE_PROJECT` | `public.ecr.aws` / `trendmicro/container-security` | Image location. |
| `RUNTIME_SECURITY_ENABLED` | `true` | Enable runtime security. |
| `VULNERABILITY_SCAN_ENABLED` | `true` | Enable vulnerability scanning. |
| `MALWARE_SCAN_ENABLED` / `SECRET_SCAN_ENABLED` / `FIM_ENABLED` | `false` | Scan features. |
| `DRY_RUN` | `false` | Preview only, no changes. |
| `AUTO_APPROVE` | `false` | Skip the interactive confirmation gate. |
| `UNINSTALL` | `false` | Mass uninstall mode: remove Container Security from every matching cluster. |
| `V1_DEREGISTER_ON_UNINSTALL` | `true` | With `UNINSTALL=true`, also deregister the cluster in Vision One. |
| `UNINSTALL_DELETE_NAMESPACE` | `false` | With `UNINSTALL=true`, also delete the `trendmicro-system` namespace. |
| `V1_PRECHECK_ENABLED` | `true` | Query Vision One before each cluster to pick upgrade vs fresh install. |
| `V1_API_BASE_URL` | `api.xdr.trendmicro.com` | Vision One API endpoint. |
| `KUBECONFIG_AUTH` / `KUBECONFIG_TOKEN_VERSION` | `api_key` / `2.0.0` | OCI CLI `create-kubeconfig` options. |

## Outputs

Each run creates a timestamped directory (e.g. `trend-oke-run-20260923-183000/`):

- `deployment.log` – single consolidated log with per-cluster sections and final summary.
- `summary.tsv` – machine-readable per-cluster result (region, compartment, cluster, mode, status, duration...).
- `overrides.yaml` – the Helm values used for that run.

> The `.tmp-*` working directories (per-cluster logs, results, kubeconfigs) are cleaned up automatically at the end of the run.

## Contributing

This folder mirrors the Oracle Cloud OKE deployment scripts. Keep the two implementations aligned where it makes sense (same variable names, same summary format, same failure semantics).