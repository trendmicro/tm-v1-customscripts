# Code Security · Jenkins Integration with Trend Micro Artifact Scanner (TMAS)

**Jenkins** pipeline that runs the **Trend AI Artifact Scanner (TMAS)** from **Trend Vision One** against a container image before deployment, applying **Code Security policies** to decide whether the build should be approved or blocked.

## Table of contents

- [How it works](#how-it-works)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Pipeline parameters](#pipeline-parameters)
- [Pipeline stages](#pipeline-stages)
- [TMAS exit codes](#tmas-exit-codes)
- [TMAS CLI quick reference](#tmas-cli-quick-reference)
- [Proxy configuration](#proxy-configuration)
- [Supported regions](#supported-regions)
- [Integration alternatives](#integration-alternatives)
- [Official references](#official-references)

---

## How it works

TMAS takes the artifact to be scanned, **generates an SBOM (Software Bill of Materials)** from it, **sends it to Trend Vision One** for processing, and returns a vulnerability report, malware and secrets findings, plus the evaluated security policy decision.

```
[Docker image]
      │
      ▼
[TMAS CLI on the Jenkins agent]
      │  generates SBOM
      ▼
[Trend Vision One] ── processes and returns ──▶ [Report + Policy decision]
      │
      ▼
[Pipeline approves (exit 0) or blocks (exit 2)]
```

When the `--evaluatePolicy` flag is used, TMAS runs the **Code Security** policies defined in the Vision One console and returns exit code **`2`** if the artifact violates them, which blocks the pipeline.

> **Note:** policy evaluation (`--evaluatePolicy`) is only supported on deployments with the **Code Security** add-on enabled in Vision One.

---

## Repository structure

| File | Description |
|------|-------------|
| [Jenkinsfile](Jenkinsfile) | Declarative pipeline definition. |
| [README.md](README.md) | This document. |

---

## Prerequisites

- **Jenkins** with the Pipeline plugin (or declarative pipelines enabled).
- A **Trend Micro Vision One API key**.
- The **Code Security** add-on active in the Vision One console (required for `--evaluatePolicy`).
- A Jenkins credential of type **Secret text** with ID `tmas-api-key` holding the API key.
- Internet access from the agent to download the TMAS CLI.

### Getting an API key

The API key is created from the Vision One console (see the [official link](https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-integrating-tmas-ci-cd-pipeline)). In Jenkins it is configured as a *Secret text* credential:

1. **Jenkins Dashboard → Manage Jenkins → Credentials → Global**.
2. Add a **Secret text** credential with ID `tmas-api-key`.
3. Paste the API key as the value.

### CLI versions

The TMAS CLI is downloaded and executed inside the build itself — **no prior installation on the agent is required**. The list of available installers and the current version can be checked at:

- `https://ast-cli.xdr.trendmicro.com/tmas-cli/metadata.json`

The pipeline uses the **Linux x86_64** installer:

```
https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/tmas-cli_Linux_x86_64.tar.gz
```

Installers are available for **Linux, Darwin (macOS) and Windows**, on `arm64`, `x86_64` (and `i386` in some cases). If the Jenkins agent runs on another platform/architecture, adjust the `curl` URL in the `Jenkinsfile` accordingly.

---

## Pipeline parameters

| Parameter | Default value | Description |
|-----------|---------------|-------------|
| `IMAGE` | `nginx:latest` | Image or artifact to scan, using the appropriate artifact type prefix (e.g. `registry:acme/app:1.2.3`). |
| `TMAS_REGION` | `us-east-1` | Vision One service region. |

---

## Pipeline stages

### `TrendAI Security Gate`

1. **TMAS CLI installation**

   Downloads the `tmas` binary into `tools/` and makes it executable:

   ```groovy
   mkdir -p tools
   curl -fsSL https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/tmas-cli_Linux_x86_64.tar.gz \
       | tar -xz -C tools tmas
   chmod +x tools/tmas
   ```

2. **Running the scan**

   The API key is injected as the `TMAS_API_KEY` environment variable through `withCredentials`, never exposing it in the build logs (`set +x` is used):

   ```bash
   ./tools/tmas scan "registry:${IMAGE}" \
       -VMS \
       --region "$TMAS_REGION" \
       --evaluatePolicy \
       --report-all-fixed-versions \
       --output json=tmas-results.json \
       > tmas-scan.log 2>&1
   ```

   | Flag | Effect |
   |------|--------|
   | `registry:<image>` | Scans a container image from a registry. |
   | `-V` / `--vulnerabilities` | Enables the vulnerability scan. |
   | `-M` / `--malware` | Enables the malware scan. |
   | `-S` / `--secrets` | Enables the secrets scan. |
   | `--region` | Service region (default `us-east-1`). |
   | `--evaluatePolicy` | Evaluates Code Security policies; exits with code **2** if any policy is violated. |
   | `--report-all-fixed-versions` | Reports all available fixed versions (by default only the first one). |
   | `--output json=<file>` | Saves the report in JSON (TMAS default format). |

   The full output (stdout + stderr) is redirected to `tmas-scan.log`.

3. **Applying the security gate**

   Based on the scan exit code (`rc`):

   ```groovy
   if (rc == 2)                          // → Blocks the build
       error('SECURITY GATE BLOCKED: Policy violation')
   if (rc != 0 || !fileExists('tmas-results.json'))
       error("TMAS scan failed: exit ${rc}")
   ```

   - `rc == 2` → the build **fails** with *SECURITY GATE BLOCKED*.
   - `rc != 0` → the build **fails** due to a scan error.
   - `rc == 0` → the build **continues and passes the gate**.

### `post { always }`

On every outcome (success or failure), the following files are **archived as build artifacts**:

- `tmas-results.json` — full JSON report.
- `tmas-scan.log` — CLI execution log.

---

## TMAS exit codes

| Code | Meaning | Pipeline action |
|------|---------|-----------------|
| `0` | Scan completed with no policy violations | ✅ Continues (gate passed) |
| `2` | A Code Security policy was violated (`--evaluatePolicy`) | 🛑 Build fails: *SECURITY GATE BLOCKED* |
| other (`1`, `3`, …) | Scan or infrastructure error | 🛑 Build fails: *TMAS scan failed* |

---

## TMAS CLI quick reference

General usage:

```
tmas [command] [flags]
```

Available commands: `scan`, `version`, `help` · Global flags: `--version`, `-v/--verbose`, `-h/--help`

### Supported artifact types (`tmas scan <artifact>`)

| Prefix | Description |
|--------|-------------|
| `docker:` | Local Docker image |
| `podman:` | Podman image |
| `registry:` | Image from a container registry |
| `docker-archive:` | Docker image archive (`docker save`) |
| `oci-archive:` | OCI image archive |
| `oci-dir:` | Directory with an OCI layout |
| `singularity:` | Singularity image |
| `dir:` | Directory with source code |
| `file:` | Binary file |

### Standalone scans

- `tmas scan vulnerabilities <artifact>` — `--saveSBOM`, `--distro`, `--report-all-fixed-versions`. SBOM limited to 15 MB.
- `tmas scan malware <artifact>` — image artifacts only; max file size 1 GB (max layer 512 MB; larger items are skipped).
- `tmas scan secrets <artifact>` — `--redacted` masks findings before sending them to the backend. Binary/ZIP files not supported; report must stay under 15 MB.

### Output formats

- `--output json` — default format, **recommended**: contains the full detail.
- `--output markdown` — summary; some results may be truncated.
- Multiple outputs can be combined: `--output json=results.json,markdown=report.md`.
- `--saveSBOM` — saves the generated SBOM locally.
- `--distro` — operating system distribution (e.g. `ol:8.4`) for `file:`/`dir:` artifacts.
- `--platform` — platform to scan (e.g. `linux/arm64`; default `linux/amd64`).

### Verbosity levels

- `-v` → info.
- `-vv` → debug.

> Note: using a scanner-specific flag without enabling that scanner produces no error — it simply has no effect.

---

## Proxy configuration

If the Jenkins agent needs a proxy, these environment variables can be set in the pipeline or on the agent:

| Variable | Description |
|----------|-------------|
| `HTTP_PROXY` | HTTP proxy URL (supports `socks5://`). |
| `HTTPS_PROXY` | HTTPS proxy URL. |
| `NO_PROXY` | Hostnames that bypass the proxy (comma-separated). Only `*` matches all hosts. |
| `PROXY_USER` | User for `Proxy-Authorization`. |
| `PROXY_PASS` | Proxy password (only used if `PROXY_USER` is set). |

---

## Supported regions

```
ap-southeast-2 · eu-central-1 · eu-west-2 · ca-central-1 · ap-south-1
ap-northeast-1 · ap-southeast-1 · us-east-1 · me-central-1
af-south-1 · ap-southeast-3
```

*(Malware scanning is not available in `af-south-1` or `ap-southeast-3`.)*

---

## Integration alternatives

In addition to the manual CLI integration, Trend Micro also offers a **GitHub Action** (`trendmicro/tmas-scan-action`) that:

- Scans repository source code, container images and build artifacts.
- Automatically posts pull request comments with the scan results.
- Installs the specified TMAS CLI version (or the latest one) on the runner.

To verify the installed version during the build, run `tools/tmas version`.

---

## Official references

- [Integrating TMAS into CI/CD pipelines (Trend Vision One)](https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-integrating-tmas-ci-cd-pipeline)
- [Vision One Artifact Scanner CLI](https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-artifact-scanner-cli)
- CLI version check: `https://ast-cli.xdr.trendmicro.com/tmas-cli/metadata.json`
- CLI download: `https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/tmas-cli_Linux_x86_64.tar.gz`
