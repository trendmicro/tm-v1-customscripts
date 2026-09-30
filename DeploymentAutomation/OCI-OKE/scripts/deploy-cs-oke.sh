#!/usr/bin/env bash

# Trend Vision One Container Security - Mass OKE Deployment
# ------------------------------------------------------------------------------
# Mirror of the AKS mass-deployment script (DeploymentAutomation/ContainerSecurity/
# Azure-AKS/AKS-RunCommand/Scripts/deploy-cs-aks.sh), adapted to Oracle Cloud
# Infrastructure Kubernetes Engine (OKE).
#
# - Multi-compartment discovery (recursive, tenancy root included)
# - Multi-region discovery (tenancy region subscriptions)
# - Optional OKE freeform tag filtering
# - Dry-run mode: preview the full target list before anything is applied
# - Interactive confirmation gate before deploying (skippable via AUTO_APPROVE)
# - Per-cluster kubeconfig generated through the OCI CLI (no shared context)
# - Automatic latest stable Helm chart tag resolution
# - Vision One-aware deployment: helm upgrade for existing clusters,
#   helm upgrade --install for new (unregistered) clusters
# - Existing Vision One clusters upgrade from the repository main branch chart
# - Helm operations use --atomic
# - Per-cluster timing
# - Single consolidated deployment log at the end
# - TSV summary
#
# Requirements
#   - OCI CLI authenticated (API key profile or instance principal). The tenancy
#     OCID is derived from the CLI config unless TENANCY_OCID is set.
#   - IAM permissions for the caller: read compartments, read OKE clusters,
#     and read the tenancy region subscriptions, e.g.
#       allow group <group> to read compartments in tenancy
#       allow group <group> to read clusters in tenancy
#       allow group <group> to use clusters in tenancy   (create-kubeconfig)
#   - Vision One Container Security API key in V1_API_KEY (same registration
#     payload as the AKS script: secret trendmicro-container-security-registration-key)
#   - Target clusters must have a publicly reachable API endpoint (or the
#     operator machine must have network access to the private endpoint),
#     otherwise the cluster is reported as FAILED_UNREACHABLE and skipped.
#
# Runtime dependencies on the machine running this script: bash 4+, awk, sed,
# jq, git, curl, oci, helm, kubectl.

set -uo pipefail

# ==============================================================================
# OPTIONAL VARIABLES / DEFAULTS
# ==============================================================================

GITHUB_REPO="${GITHUB_REPO:-trendmicro/visionone-container-security-helm}"

# Use "latest" to automatically resolve the highest stable semantic-version tag.
# You can also pin a specific version, for example: TARGET_VERSION=3.5.1
TARGET_VERSION="${TARGET_VERSION:-latest}"

NAMESPACE="${NAMESPACE:-trendmicro-system}"
RELEASE="${RELEASE:-trendmicro}"
TIMEOUT="${TIMEOUT:-10m}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
GROUP_ID="${GROUP_ID:-00000000-0000-0000-0000-000000000005}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-public.ecr.aws}"
IMAGE_PROJECT="${IMAGE_PROJECT:-trendmicro/container-security}"

# BASIC CONFIGURATION FOR CONTAINER SECURITY HELM CHART

# ============ TRENDAI DEPLOYMENT VARIABLES MINIMAL REQUIREMENTS ============= #
CPU_LIMIT="200m"
CPU_REQUEST="100m"
MEMORY_LIMIT="512Mi"
MEMORY_REQUEST="256Mi"
MAX_JOB_COUNT=3 # ==== This is the minimum number of concurrent jobs that can be run in the cluster.
RUNTIME_SECURITY_ENABLED="${RUNTIME_SECURITY_ENABLED:-true}"
VULNERABILITY_SCAN_ENABLED="${VULNERABILITY_SCAN_ENABLED:-true}"
MALWARE_SCAN_ENABLED="${MALWARE_SCAN_ENABLED:-false}"
SECRET_SCAN_ENABLED="${SECRET_SCAN_ENABLED:-false}"
FIM_ENABLED="${FIM_ENABLED:-false}"
CHART_URL="${CHART_URL:-}"

# ============ OCI CONFIGURATION ============= #
# OCI CLI profile used for every call (empty -> CLI default profile).
OCI_PROFILE="${OCI_PROFILE:-}"
# Restrict discovery to an explicit region instead of the tenancy subscriptions.
OCI_REGION="${OCI_REGION:-}"
# Tenancy OCID. When empty it is read from the OCI CLI configuration file.
TENANCY_OCID="${TENANCY_OCID:-}"
# Comma-separated compartment OCIDs. Empty -> every accessible compartment.
COMPARTMENTS="${COMPARTMENTS:-}"
# Individual clusters are only deployed to when the caller can actually see them;
# use COMPARTMENT_ACCESS_LEVEL=ANY only if a policy blocks ACCESSIBLE and you
# are sure clusters exist in compartments you cannot read directly.
COMPARTMENT_ACCESS_LEVEL="${COMPARTMENT_ACCESS_LEVEL:-ACCESSIBLE}"
# Include the tenancy root compartment itself as a discovery target.
INCLUDE_ROOT_COMPARTMENT="${INCLUDE_ROOT_COMPARTMENT:-true}"
# Only these OKE cluster lifecycle states are deployed to.
OKE_STATE_FILTER="${OKE_STATE_FILTER:-ACTIVE}"
# Optional freeform tag filter, same syntax as the AKS script: Key=Value[,Key=Value]
OKE_TAG_FILTER="${OKE_TAG_FILTER:-}"
# OKE kubeconfig generation options.
KUBECONFIG_AUTH="${KUBECONFIG_AUTH:-api_key}"
KUBECONFIG_TOKEN_VERSION="${KUBECONFIG_TOKEN_VERSION:-2.0.0}"

V1_API_BASE_URL="${V1_API_BASE_URL:-https://api.xdr.trendmicro.com}"
V1_K8S_CLUSTERS_ENDPOINT="${V1_API_BASE_URL%/}/v3.0/containerSecurity/kubernetesClusters"

# Cloud provider account ID registered in Vision One. For OCI this is the
# tenancy OCID, which is resolved automatically when this is left empty.
V1_CLOUD_ACCOUNT_ID="${V1_CLOUD_ACCOUNT_ID:-}"

V1_PRECHECK_ENABLED="${V1_PRECHECK_ENABLED:-true}"

DRY_RUN="${DRY_RUN:-false}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

# ==============================================================================
# HELPERS
# ==============================================================================

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

format_duration() {
    local total="${1:-0}"
    local hours=$((total / 3600))
    local minutes=$(((total % 3600) / 60))
    local seconds=$((total % 60))

    if (( hours > 0 )); then
        printf "%02dh:%02dm:%02ds" "$hours" "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf "%02dm:%02ds" "$minutes" "$seconds"
    else
        printf "%02ds" "$seconds"
    fi
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Validates a boolean-style env var and reports it as a bash return code
# (0 = true, 1 = false). Exits the script if the value is neither.
is_true() {
    case "$1" in
        [Tt][Rr][Uu][Ee]|1)
            return 0
            ;;
        [Ff][Aa][Ll][Ss][Ee]|0)
            return 1
            ;;
        *)
            echo "ERROR: Invalid boolean value: '$1' (expected true/false)" >&2
            exit 1
            ;;
    esac
}

# Wrapper around the OCI CLI. JSON is the CLI's default output format (there is
# no -o/--output json flag on most commands; --output is global and optional),
# and global options such as --profile/--region/--auth must precede the
# subcommand, which is why they are assembled here.
# OCI_CLI_AUTH is not injected: the CLI reads that env var natively (Cloud Shell
# exports it, e.g. instance_obo_user) and duplicating it is unnecessary.
oci_cli() {
    if [[ -n "$OCI_PROFILE" ]]; then
        oci --profile "$OCI_PROFILE" "$@"
    else
        oci "$@"
    fi
}

# Same as oci_cli but pins the region globally for commands that must target a
# specific region (ce cluster list, ce cluster create-kubeconfig).
oci_cli_region() {
    local region="$1"
    shift

    if [[ -n "$OCI_PROFILE" ]]; then
        oci --profile "$OCI_PROFILE" --region "$region" "$@"
    else
        oci --region "$region" "$@"
    fi
}

# ==============================================================================
# VALIDATION
# ==============================================================================

for cmd in oci jq git curl helm kubectl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ -z "${V1_API_KEY:-}" ]]; then
    echo "[ERROR] V1_API_KEY environment variable is not set."
    exit 1
fi

if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || (( MAX_PARALLEL < 1 )); then
    echo "ERROR: MAX_PARALLEL must be an integer >= 1" >&2
    exit 1
fi

# Fail fast on malformed DRY_RUN / AUTO_APPROVE values rather than
# silently treating a typo (e.g. "ture") as false.
is_true "$DRY_RUN"
is_true "$AUTO_APPROVE"
is_true "$V1_PRECHECK_ENABLED"
is_true "$INCLUDE_ROOT_COMPARTMENT"

if [[ -n "$OKE_TAG_FILTER" ]]; then
    IFS=',' read -r -a _tag_filters <<< "$OKE_TAG_FILTER"

    for _tag_filter in "${_tag_filters[@]}"; do
        _tag_filter="$(trim "$_tag_filter")"

        if [[ "$_tag_filter" != *=* ]]; then
            echo "ERROR: Invalid OKE_TAG_FILTER entry: '$_tag_filter'" >&2
            echo "Expected format: Key=Value[,Key=Value]" >&2
            exit 1
        fi

        _tag_key="$(trim "${_tag_filter%%=*}")"

        if [[ -z "$_tag_key" ]]; then
            echo "ERROR: OKE_TAG_FILTER contains an empty tag key." >&2
            exit 1
        fi
    done
fi

# Validate OCI authentication.
# Cloud Shell exports OCI_CLI_AUTH (e.g. instance_obo_user) and the CLI honors it
# natively, so this probe only needs the plain command. Failure modes are
# distinguished so the message is actionable: missing credentials vs. a
# locked-down IAM policy (os ns get still works) vs. a genuine API error.
_auth_probe() {
    local _args=()

    [[ -n "$OCI_PROFILE" ]] && _args+=(--profile "$OCI_PROFILE")

    oci "${_args[@]}" iam region-subscription list
}

if ! _auth_probe; then
    if [[ -z "${OCI_CLI_AUTH:-}" ]] \
        && oci --auth instance_principal iam region-subscription list >/dev/null 2>&1; then
        echo "[INFO] Default OCI CLI auth failed; switching to --auth instance_principal." >&2
        OCI_CLI_AUTH="instance_principal"
    else
        echo "ERROR: OCI CLI authentication failed." >&2
        echo >&2
        echo "Run this command manually and check its error:" >&2
        echo "  oci iam region-subscription list" >&2
        echo >&2
        echo "Common fixes:" >&2
        echo "  (a) missing credentials (local)      -> 'oci setup config'" >&2
        echo "  (b) Cloud Shell                      -> re-open the terminal or run the command above;" >&2
        echo "                                         OCI_CLI_AUTH is exported by Cloud Shell" >&2
        echo "                                         (e.g. instance_obo_user) and honored natively" >&2
        echo "  (c) compute instance principal       -> OCI_CLI_AUTH=instance_principal ./deploy-cs-oke.sh" >&2
        echo "                                         (or --auth instance_principal, tested above)" >&2
        echo "  (d) IAM policy                       -> the caller needs, at minimum, read access to" >&2
        echo "                                         compartments, clusters and the tenancy" >&2
        exit 1
    fi
fi

# ==============================================================================
# RESOLVE CONTAINER SECURITY CHART VERSION
# ==============================================================================

TARGET_TAG=""
RESOLVED_VERSION=""

resolve_target_version() {
    local repo_url="https://github.com/${GITHUB_REPO}.git"
    local latest_line=""
    local candidate=""

    if [[ "$TARGET_VERSION" == "latest" ]]; then
        echo "Resolving latest stable Container Security Helm chart tag..."

        latest_line="$(
            git ls-remote --tags --refs "$repo_url" 2>/dev/null \
            | awk -F/ '
                {
                    tag=$3
                    version=tag
                    sub(/^v/, "", version)

                    if (version ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
                        print version "\t" tag
                    }
                }
            ' \
            | sort -t $'\t' -k1,1V \
            | tail -n 1
        )"

        if [[ -z "$latest_line" ]]; then
            echo "ERROR: Unable to resolve the latest stable tag from $GITHUB_REPO." >&2
            exit 1
        fi

        RESOLVED_VERSION="${latest_line%%$'\t'*}"
        TARGET_TAG="${latest_line#*$'\t'}"
    else
        candidate="$TARGET_VERSION"

        if git ls-remote --exit-code --tags "$repo_url" "refs/tags/${candidate}" >/dev/null 2>&1; then
            TARGET_TAG="$candidate"
        elif [[ "$candidate" != v* ]] \
            && git ls-remote --exit-code --tags "$repo_url" "refs/tags/v${candidate}" >/dev/null 2>&1; then
            TARGET_TAG="v${candidate}"
        elif [[ "$candidate" == v* ]] \
            && git ls-remote --exit-code --tags "$repo_url" "refs/tags/${candidate#v}" >/dev/null 2>&1; then
            TARGET_TAG="${candidate#v}"
        else
            echo "ERROR: Tag '$TARGET_VERSION' was not found in $GITHUB_REPO." >&2
            exit 1
        fi

        RESOLVED_VERSION="${TARGET_TAG#v}"
    fi

    if [[ -z "$CHART_URL" ]]; then
        CHART_URL="https://github.com/${GITHUB_REPO}/archive/refs/tags/${TARGET_TAG}.tar.gz"
    fi
}

resolve_target_version

# ==============================================================================
# RUN DIRECTORY
# ==============================================================================

RUN_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${RUN_DIR:-./trend-oke-run-${RUN_TIMESTAMP}}"

TEMP_LOG_DIR="${RUN_DIR}/.tmp-logs"
RESULT_DIR="${RUN_DIR}/.tmp-results"
KUBECONFIG_DIR="${RUN_DIR}/.tmp-kubeconfigs"
TARGETS_FILE="${RUN_DIR}/.targets.tsv"

FINAL_LOG="${RUN_DIR}/deployment.log"
SUMMARY_FILE="${RUN_DIR}/summary.tsv"

OVERRIDES_FILE="${RUN_DIR}/overrides.yaml"

# TEMP_LOG_DIR / RESULT_DIR / KUBECONFIG_DIR are created later, only once
# discovery is confirmed and the deployment phase actually starts.
mkdir -p "$RUN_DIR"
: > "$TARGETS_FILE"

# ==============================================================================
# GENERATE SHARED OVERRIDES FILE
# ==============================================================================

generate_overrides_file() {
    cat > "$OVERRIDES_FILE" <<EOF
visionOne:
    endpoint: https://api.xdr.trendmicro.com/external/v2/direct/vcs/external/vcs
    exclusion:
        namespaces: [kube-system, ${NAMESPACE}]
    runtimeSecurity:
        enabled: ${RUNTIME_SECURITY_ENABLED}
    vulnerabilityScanning:
        enabled: ${VULNERABILITY_SCAN_ENABLED}
    malwareScanning:
        enabled: ${MALWARE_SCAN_ENABLED}
    secretScanning:
        enabled: ${SECRET_SCAN_ENABLED}
    fileIntegrityMonitoring:
        enabled: ${FIM_ENABLED}
    scanManager:
        maxJobCount: ${MAX_JOB_COUNT}
resources:
    falco:
        limits:
            cpu: ${CPU_LIMIT}
            memory: ${MEMORY_LIMIT}
        requests:
            cpu: ${CPU_REQUEST}
            memory: ${MEMORY_REQUEST}
    scout:
        limits:
            cpu: ${CPU_LIMIT}
            memory: ${MEMORY_LIMIT}
        requests:
            cpu: ${CPU_REQUEST}
            memory: ${MEMORY_REQUEST}
tolerations:
    defaults:
        - effect: NoSchedule
          key: nvidia.com/gpu
          operator: Exists
        - effect: NoExecute
          key: node.kubernetes.io/not-ready
          operator: Exists
images:
    defaults:
        registry: ${IMAGE_REGISTRY}
        project: ${IMAGE_PROJECT}
        tag: ${RESOLVED_VERSION}
        pullPolicy: IfNotPresent
EOF
}

# ==============================================================================
# OCI DISCOVERY
# ==============================================================================

# Tenancy OCID, taken from the CLI config when it is not provided explicitly.
resolve_tenancy() {
    local config_file="${OCI_CLI_CONFIG_FILE:-${OCI_CONFIG_FILE:-$HOME/.oci/config}}"
    local profile="${OCI_PROFILE:-${OCI_CLI_PROFILE:-DEFAULT}}"
    local tenancy=""

    if [[ -n "$TENANCY_OCID" ]]; then
        printf '%s' "$TENANCY_OCID"
        return 0
    fi

    if [[ ! -r "$config_file" ]]; then
        echo "ERROR: OCI config file not found or not readable: $config_file" >&2
        echo "Set TENANCY_OCID=<ocid> to skip config parsing (needed for instance" >&2
        echo "principal / Cloud Shell runs without ~/.oci/config)." >&2
        return 1
    fi

    tenancy="$(
        awk -v wanted="[$profile]" '
            $0 == wanted { in_section = 1; next }
            /^\[/ { in_section = 0 }
            in_section && /^[[:space:]]*tenancy[[:space:]]*=/ {
                sub(/^[[:space:]]*tenancy[[:space:]]*=[[:space:]]*/, "")
                gsub(/[[:space:]]+$/, "")
                print
                exit
            }
        ' "$config_file"
    )"

    if [[ -z "$tenancy" ]]; then
        echo "ERROR: Unable to read 'tenancy' from $config_file (profile: $profile)." >&2
        echo "Set TENANCY_OCID to skip config parsing." >&2
        return 1
    fi

    printf '%s' "$tenancy"
}

# Regions to scan: OCI_REGION override, otherwise the tenancy subscriptions.
resolve_regions() {
    local subscribed=""
    local all_regions=""

    if [[ -n "$OCI_REGION" ]]; then
        printf '%s\n' "$OCI_REGION"
        return 0
    fi

    # Raw JSON + jq instead of --query: JMESPath needs quoted identifiers for
    # hyphenated keys, and the CLI output keeps OCI's kebab-case field names.
    subscribed="$(
        oci_cli iam region-subscription list --all 2>/dev/null \
            | jq -r '.data[]? | (."region-name" // .regionName // empty)'
    )"

    if [[ -n "$(printf '%s' "$subscribed" | tr -d '[:space:]')" ]]; then
        printf '%s\n' "$subscribed"
        return 0
    fi

    # Fallback: compact tenancy with a locked-down policy may not expose the
    # subscriptions. First try the config region, then the global region list.
    if [[ -n "${OCI_REGION}" ]]; then
        printf '%s\n' "$OCI_REGION"
        return 0
    fi

    all_regions="$(
        oci_cli iam region list --all 2>/dev/null \
            | jq -r '.data[]? | (."name" // .name // empty)'
    )"

    if [[ -n "$(printf '%s' "$all_regions" | tr -d '[:space:]')" ]]; then
        printf '%s\n' "$all_regions"
        return 0
    fi

    return 1
}

# Compartments to scan: COMPARTMENTS override, otherwise every accessible
# compartment in the tenancy subtree, plus the tenancy root itself.
# Emits: compartment_id<TAB>compartment_name
resolve_compartments() {
    local tenancy="$1"
    local raw=""
    local rc=0

    if [[ -n "$COMPARTMENTS" ]]; then
        if [[ "$COMPARTMENTS" == "root" ]]; then
            printf '%s\t%s\n' "$tenancy" "tenancy-root"
            return 0
        fi

        # Explicit OCIDs are labelled "compartment"; the CLI resolves names.
        printf '%s\n' "$COMPARTMENTS" \
            | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | sed '/^$/d' \
            | awk '{ print $1 "\tcompartment" }'

        return 0
    fi

    if is_true "$INCLUDE_ROOT_COMPARTMENT"; then
        printf '%s\t%s\n' "$tenancy" "tenancy-root"
    fi

    # stdout + stderr are captured together: when the CLI fails, the real OCI
    # error message is shown to the user instead of an obscure jq parse error.
    raw="$(
        oci_cli iam compartment list \
            --compartment-id "$tenancy" \
            --compartment-id-in-subtree true \
            --access-level "$COMPARTMENT_ACCESS_LEVEL" \
            --all \
            2>&1
    )"
    rc=$?

    if (( rc != 0 )) || ! jq -e '.data? // empty' >/dev/null 2>&1 <<< "$raw"; then
        echo "ERROR: 'oci iam compartment list' did not return valid JSON." >&2
        echo "The OCI CLI reported:" >&2
        printf '%s' "$raw" | grep -v '^$' | head -c 600 | sed 's/^/  /' >&2
        echo >&2
        echo "Run the command manually to see the full error:" >&2
        echo "  oci iam compartment list --compartment-id '$tenancy'" >&2
        echo "    --compartment-id-in-subtree true --access-level $COMPARTMENT_ACCESS_LEVEL --all" >&2
        return 1
    fi

    jq -r '
        .data[]?
        | select((.lifecycleState // .["lifecycle-state"] // "ACTIVE") == "ACTIVE")
        | select((.availabilityDomain // .["availability-domain"] // "") == "")  # exclude AD-local compartments
        | [(.id // ""), (.name // "")]
        | @tsv
    ' <<< "$raw"
}

# OKE clusters of a compartment in a region.
# Emits: cluster_name<TAB>cluster_ocid<TAB>kubernetes_version
list_target_clusters() {
    local region="$1"
    local compartment_id="$2"
    local clusters_json=""

    if ! clusters_json="$(
        oci_cli_region "$region" ce cluster list \
            --compartment-id "$compartment_id" \
            --all \
            2>/dev/null
    )"; then
        return 1
    fi

    jq -r \
        --arg states "$OKE_STATE_FILTER" \
        --arg filters "$OKE_TAG_FILTER" '
        ($states | split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_upcase) | map(select(length > 0))) as $wantedStates
        | (
            $filters
            | split(",")
            | map(
                gsub("^\\s+|\\s+$"; "")
                | select(length > 0)
                | capture("^(?<key>[^=]+)=(?<value>.*)$")
                | .key |= gsub("^\\s+|\\s+$"; "")
                | .value |= gsub("^\\s+|\\s+$"; "")
              )
        ) as $requiredTags

        | .data[]?
        | select(
            ([(.lifecycleState // .["lifecycle-state"] // "") | ascii_upcase] | inside($wantedStates))
          )

        | . as $cluster
        | (($cluster["freeform-tags"] // $cluster.freeformTags) // {}) as $clusterTags
        | select(
            all(
                $requiredTags[];
                (($clusterTags[.key] // null) == .value)
            )
          )

        | [
            ($cluster.name // ""),
            ($cluster.id // ""),
            ($cluster["kubernetes-version"] // $cluster.kubernetesVersion // "unknown")
          ]
        | @tsv
    ' <<< "$clusters_json"
}

# ==============================================================================
# VISION ONE CLUSTER EXISTENCE CHECK
# ==============================================================================

# Return codes:
#   0 = cluster already exists in Vision One; first matching item is written to stdout as JSON
#   1 = cluster does not exist
#   2 = Vision One API lookup failed or returned an invalid response
vision_one_cluster_lookup() {
    local cloud_provider_account_id="$1"
    local cluster_name="$2"
    local filter
    local response
    local body
    local http_code
    local match_count

    # OCI tenancy OCIDs and the generated Vision One cluster names do not contain
    # single quotes, so they can be safely embedded in this TMV1-Filter expression.
    filter="cloudProviderAccountId eq '${cloud_provider_account_id}' and name eq '${cluster_name}'"

    if ! response="$(
        curl \
            --silent \
            --show-error \
            --connect-timeout 15 \
            --max-time 30 \
            --header "Authorization: Bearer ${V1_API_KEY}" \
            --header "Accept: application/json" \
            --header "TMV1-Filter: ${filter}" \
            --write-out $'\n%{http_code}' \
            "$V1_K8S_CLUSTERS_ENDPOINT"
    )"; then
        echo "[ERROR] Vision One API request failed for cluster '$cluster_name'." >&2
        return 2
    fi

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "[ERROR] Vision One API returned HTTP $http_code for cluster '$cluster_name'." >&2
        if [[ -n "$body" ]]; then
            echo "[ERROR] Response: $(printf '%s' "$body" | jq -c . 2>/dev/null || printf '%s' "$body")" >&2
        fi
        return 2
    fi

    if ! jq -e '.items | type == "array"' >/dev/null 2>&1 <<< "$body"; then
        echo "[ERROR] Vision One API response does not contain a valid 'items' array for '$cluster_name'." >&2
        return 2
    fi

    match_count="$(jq -r '.items | length' <<< "$body")"

    if (( match_count > 0 )); then
        jq -c '.items[0]' <<< "$body"
        return 0
    fi

    return 1
}

# ==============================================================================
# PARALLEL EXECUTION CONTROL
# ==============================================================================

wait_for_slot() {
    while (( $(jobs -pr | wc -l) >= MAX_PARALLEL )); do
        wait -n 2>/dev/null || true
    done
}

# ==============================================================================
# CLUSTER KUBECONFIG
# ==============================================================================

# Writes a kubeconfig for one cluster and guarantees the region is pinned inside
# the exec credential args, so parallel jobs never depend on the ambient CLI
# region. Returns non-zero when generation or the connectivity probe fails.
prepare_kubeconfig() {
    local region="$1"
    local cluster_ocid="$2"
    local cluster_name="$3"
    local kubeconfig="$4"
    local safe_name="$5"
    local patch_file="${kubeconfig}.patch"

    if ! oci_cli ce cluster create-kubeconfig \
        --region "$region" \
        --cluster-id "$cluster_ocid" \
        --file "$kubeconfig" \
        --token-version "$KUBECONFIG_TOKEN_VERSION" \
        --auth "$KUBECONFIG_AUTH" \
        --overwrite 2>&1; then
        return 1
    fi

    if [[ ! -s "$kubeconfig" ]]; then
        echo "kubeconfig was not written to $kubeconfig" >&2
        return 1
    fi

    # Some CLI versions omit --region from the generated exec args, which makes
    # multi-region runs pick up the wrong endpoint.
    if jq -e '.users[0].user.exec.args' "$kubeconfig" >/dev/null 2>&1 \
        && ! jq -e '.users[0].user.exec.args | index("--region")' "$kubeconfig" >/dev/null 2>&1; then
        if jq --arg r "$region" '.users[0].user.exec.args += ["--region", $r]' "$kubeconfig" > "$patch_file"; then
            mv "$patch_file" "$kubeconfig"
        else
            rm -f "$patch_file"
            echo "WARNING: unable to pin region '$region' in kubeconfig for $safe_name." >&2
        fi
    fi

    return 0
}

# --------------------------------------------------------------------------
# Existing cluster in Vision One: UPGRADE ONLY
# --------------------------------------------------------------------------
# Runs with KUBECONFIG already exported by the caller. Returns non-zero on the
# first failed step; each step is checked explicitly so a failure never aborts
# the surrounding job before it can record its result.
upgrade_existing_cluster() {
    local cluster_name="$1"
    local region="$2"
    local trend_cluster_name="$3"

    echo "============================================================"
    echo "Trend Vision One Container Security - Existing Cluster"
    echo "============================================================"
    echo "OKE Cluster   : $cluster_name"
    echo "Region        : $region"
    echo "Vision One    : $trend_cluster_name"
    echo "Action        : helm upgrade"
    echo "Chart         : $CHART_URL"
    echo

    echo "[1/3] Validating existing Helm release..."

    if ! helm status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "[ERROR] Vision One contains this cluster, but Helm release '$RELEASE' was not found in namespace '$NAMESPACE'."
        echo "[ERROR] Existing-cluster mode intentionally does not use --install."
        return 1
    fi

    echo "[INFO] Existing Helm release found."
    echo
    echo "[2/3] Upgrading Container Security..."

    if ! helm upgrade \
        --reuse-values \
        --values "$OVERRIDES_FILE" \
        --namespace "$NAMESPACE" \
        "$RELEASE" \
        "$CHART_URL" \
        --atomic \
        --timeout "$TIMEOUT"; then
        echo "[ERROR] helm upgrade failed for release '$RELEASE'."
        return 1
    fi

    echo
    echo "[3/3] Validating upgraded deployment..."
    echo
    echo "Helm status:"

    helm status "$RELEASE" --namespace "$NAMESPACE" || true

    echo
    echo "Trend Micro pods:"

    kubectl get pods --namespace "$NAMESPACE" -o wide || true

    return 0
}

# --------------------------------------------------------------------------
# New cluster: keep the existing registration + upgrade --install logic
# --------------------------------------------------------------------------
install_new_cluster() {
    local cluster_name="$1"
    local region="$2"
    local trend_cluster_name="$3"
    local cluster_ocid="$4"

    echo "============================================================"
    echo "Trend Vision One Container Security - New Cluster"
    echo "============================================================"
    echo "OKE Cluster   : $cluster_name"
    echo "Region        : $region"
    echo "Vision One    : $trend_cluster_name"
    echo "Target Version: $RESOLVED_VERSION"
    echo "Action        : helm upgrade --install"
    echo

    echo "[1/3] Creating namespace if required..."

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        if ! kubectl create namespace "$NAMESPACE"; then
            echo "[ERROR] Unable to create namespace '$NAMESPACE'."
            return 1
        fi
    else
        echo "[INFO] Namespace '$NAMESPACE' already exists."
    fi

    echo
    echo "[2/3] Applying Vision One registration secret..."

    if ! kubectl create secret generic trendmicro-container-security-registration-key \
        --from-literal=registration.key="$V1_API_KEY" \
        -n "$NAMESPACE" \
        --dry-run=client \
        -o yaml | kubectl apply -f -; then
        echo "[ERROR] Unable to apply secret trendmicro-container-security-registration-key."
        return 1
    fi

    if ! kubectl get secret trendmicro-container-security-registration-key -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "[ERROR] Required secret trendmicro-container-security-registration-key could not be created."
        return 1
    fi

    echo "[INFO] Secret trendmicro-container-security-registration-key is available."

    echo
    echo "[3/3] Installing / upgrading Container Security..."

    if ! helm upgrade --install \
        "$RELEASE" \
        "$CHART_URL" \
        --namespace "$NAMESPACE" \
        --values "$OVERRIDES_FILE" \
        --set visionOne.clusterRegistrationKey=true \
        --set-string visionOne.groupId="$GROUP_ID" \
        --set-string visionOne.clusterName="$trend_cluster_name" \
        --set-string visionOne.resourceId="$cluster_ocid" \
        --atomic \
        --timeout "$TIMEOUT"; then
        echo "[ERROR] helm upgrade --install failed for release '$RELEASE'."
        return 1
    fi

    echo
    echo "Helm status:"

    helm status "$RELEASE" --namespace "$NAMESPACE" || true

    echo
    echo "Trend Micro pods:"

    kubectl get pods --namespace "$NAMESPACE" -o wide || true

    return 0
}

# ==============================================================================
# CLUSTER DEPLOYMENT
# ==============================================================================

deploy_cluster() {
    local job_index="$1"
    local region="$2"
    local compartment_id="$3"
    local compartment_name="$4"
    local cluster_name="$5"
    local cluster_ocid="$6"
    local k8s_version="$7"

    local start_epoch end_epoch elapsed
    local start_time end_time
    local status="FAILED"
    local trend_cluster_name
    local safe_name
    local order
    local temp_log
    local result_file
    local kubeconfig
    local deployment_mode="NEW_CLUSTER"
    local block_deployment="false"
    local v1_lookup_result=""
    local v1_lookup_rc=0
    local v1_existing_id=""
    local v1_existing_status=""
    local v1_existing_version=""

    start_epoch="$(date +%s)"
    start_time="$(timestamp)"

    trend_cluster_name="$(
        printf '%s' "$cluster_name" \
        | sed 's/[^a-zA-Z0-9_]/_/g'
    )"

    safe_name="$(
        printf '%s' "${region}_${compartment_name}_${cluster_name}" \
        | sed 's/[^a-zA-Z0-9_.-]/_/g'
    )"

    order="$(printf '%06d' "$job_index")"

    temp_log="${TEMP_LOG_DIR}/${order}_${safe_name}.log"
    result_file="${RESULT_DIR}/${order}_${safe_name}.tsv"
    kubeconfig="${KUBECONFIG_DIR}/${order}_${safe_name}.yaml"

    echo "[$start_time] [START]   $cluster_name | Region: $region | Compartment: $compartment_name"

    {
        echo "================================================================================"
        echo " CLUSTER DEPLOYMENT"
        echo "================================================================================"
        echo "Start Time        : $start_time"
        echo "Region            : $region"
        echo "Compartment       : $compartment_name"
        echo "Compartment ID    : $compartment_id"
        echo "OKE Cluster       : $cluster_name"
        echo "Vision One Name   : $trend_cluster_name"
        echo "OKE Cluster ID    : $cluster_ocid"
        echo "Kubernetes Version: $k8s_version"
        echo "Target Version    : $RESOLVED_VERSION"
        echo "Target Tag        : $TARGET_TAG"
        echo "Install Chart URL : $CHART_URL"
        echo "Kubeconfig        : $kubeconfig"
        echo "================================================================================"
        echo
    } > "$temp_log"

    # --------------------------------------------------------------------------
    # Kubeconfig + connectivity
    # --------------------------------------------------------------------------
    # OKE clusters with a private API endpoint are unreachable from this machine
    # unless it has network access to the private subnet. The probe below turns
    # that into an explicit FAILED_UNREACHABLE instead of a confusing Helm error.
    echo "[INFO] Generating kubeconfig (auth: $KUBECONFIG_AUTH, token-version: $KUBECONFIG_TOKEN_VERSION)..." >> "$temp_log"

    if ! prepare_kubeconfig "$region" "$cluster_ocid" "$cluster_name" "$kubeconfig" "$safe_name" >> "$temp_log" 2>&1; then
        status="FAILED_KUBECONFIG"
        block_deployment="true"
        echo "[ERROR] Unable to generate the kubeconfig for $cluster_name in region $region." >> "$temp_log"
    fi

    if [[ "$block_deployment" == "false" ]]; then
        export KUBECONFIG="$kubeconfig"

        echo "[INFO] Validating cluster connectivity..." >> "$temp_log"

        if ! kubectl get nodes --request-timeout=20s >> "$temp_log" 2>&1; then
            status="FAILED_UNREACHABLE"
            block_deployment="true"
            echo >> "$temp_log"
            echo "[ERROR] The cluster API endpoint is not reachable from this machine." >> "$temp_log"
            echo "[ERROR] For OKE clusters with a private endpoint, run this script from a" >> "$temp_log"
            echo "[ERROR] host with network access (or a bastion / OCI Cloud Shell with VCN access)." >> "$temp_log"
        else
            {
                echo "[INFO] Cluster is reachable."
                echo "[INFO] Kubernetes server version:"
                kubectl version --request-timeout=20s 2>/dev/null | sed 's/^/       /'
                echo
            } >> "$temp_log"
        fi
    fi

    # --------------------------------------------------------------------------
    # Vision One pre-check
    # --------------------------------------------------------------------------
    # Existing in Vision One -> helm upgrade ONLY, using main.tar.gz.
    # Not existing in Vision One -> registration + helm upgrade --install.
    if [[ "$block_deployment" == "false" ]] && is_true "$V1_PRECHECK_ENABLED"; then
        echo "[INFO] Checking whether the cluster is already registered in Vision One..." >> "$temp_log"
        echo "[INFO] Filter: cloudProviderAccountId eq '$V1_CLOUD_ACCOUNT_ID' and name eq '$trend_cluster_name'" >> "$temp_log"

        v1_lookup_result="$(vision_one_cluster_lookup "$V1_CLOUD_ACCOUNT_ID" "$trend_cluster_name" 2>> "$temp_log")"
        v1_lookup_rc=$?

        case "$v1_lookup_rc" in
            0)
                deployment_mode="UPGRADE_EXISTING"
                v1_existing_id="$(jq -r '.id // ""' <<< "$v1_lookup_result")"
                v1_existing_status="$(jq -r '.protectionStatus // "UNKNOWN"' <<< "$v1_lookup_result")"
                v1_existing_version="$(jq -r '.applicationVersion // "UNKNOWN"' <<< "$v1_lookup_result")"

                echo "[INFO] Cluster already exists in Vision One." >> "$temp_log"
                echo "[INFO] Vision One ID       : ${v1_existing_id:-UNKNOWN}" >> "$temp_log"
                echo "[INFO] Protection Status   : ${v1_existing_status:-UNKNOWN}" >> "$temp_log"
                echo "[INFO] Application Version : ${v1_existing_version:-UNKNOWN}" >> "$temp_log"
                echo "[ACTION] Existing cluster -> helm upgrade (NO --install)." >> "$temp_log"
                echo "[ACTION] Upgrade chart     -> $CHART_URL" >> "$temp_log"
                ;;
            1)
                deployment_mode="NEW_CLUSTER"
                echo "[INFO] Cluster is not registered in Vision One." >> "$temp_log"
                echo "[ACTION] New cluster -> registration flow + helm upgrade --install." >> "$temp_log"
                ;;
            *)
                deployment_mode="V1_CHECK_FAILED"
                block_deployment="true"
                status="FAILED_V1_CHECK"
                echo "[ERROR] Unable to validate cluster registration in Vision One." >> "$temp_log"
                echo "[ERROR] Deployment blocked to avoid an incorrect registration/upgrade path." >> "$temp_log"
                ;;
        esac

        echo >> "$temp_log"
    elif [[ "$block_deployment" == "false" ]]; then
        echo "[WARNING] V1_PRECHECK_ENABLED=false - using the new-cluster registration flow." >> "$temp_log"
        echo >> "$temp_log"
    fi

    # --------------------------------------------------------------------------
    # Existing cluster in Vision One: UPGRADE ONLY
    # --------------------------------------------------------------------------
    if [[ "$block_deployment" == "false" && "$deployment_mode" == "UPGRADE_EXISTING" ]]; then
        if upgrade_existing_cluster "$cluster_name" "$region" "$trend_cluster_name" >> "$temp_log" 2>&1; then
            status="SUCCESS"
        else
            status="FAILED"
        fi
    fi

    # --------------------------------------------------------------------------
    # New cluster: keep the existing registration + upgrade --install logic
    # --------------------------------------------------------------------------
    if [[ "$block_deployment" == "false" && "$deployment_mode" == "NEW_CLUSTER" ]]; then
        if install_new_cluster "$cluster_name" "$region" "$trend_cluster_name" "$cluster_ocid" >> "$temp_log" 2>&1; then
            status="SUCCESS"
        else
            status="FAILED"
        fi
    fi

    end_epoch="$(date +%s)"
    end_time="$(timestamp)"
    elapsed=$((end_epoch - start_epoch))

    {
        echo
        echo "================================================================================"
        echo " RESULT"
        echo "================================================================================"
        echo "Deployment Mode  : $deployment_mode"
        echo "Status           : $status"
        echo "End Time         : $end_time"
        echo "Duration         : $(format_duration "$elapsed")"
        echo "================================================================================"
        echo
    } >> "$temp_log"

    # The kubeconfig carries the exec credential arguments; it is not needed
    # once this cluster is finished.
    rm -f "$kubeconfig"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$job_index" \
        "$region" \
        "$compartment_id" \
        "$compartment_name" \
        "$cluster_name" \
        "$cluster_ocid" \
        "$trend_cluster_name" \
        "$deployment_mode" \
        "$status" \
        "$elapsed" \
        "$start_epoch" \
        "$end_epoch" \
        > "$result_file"

    printf "[%s] [%-19s] %s | %-16s | %-22s | %s\n" \
        "$end_time" \
        "$status" \
        "$cluster_name" \
        "$region" \
        "$deployment_mode" \
        "$(format_duration "$elapsed")"

    # Always return success to the local job scheduler.
    # The actual deployment status is recorded in result_file.
    return 0
}

# ==============================================================================
# MAIN
# ==============================================================================

echo
echo "================================================================================"
echo " Trend Vision One - OKE (OCI) Mass Deployment"
echo "================================================================================"
echo "Start Time        : $(timestamp)"
echo "Mode              : $(is_true "$DRY_RUN" && echo "DRY-RUN (preview only)" || echo "APPLY")"
echo "Target Version    : $RESOLVED_VERSION"
echo "Target Tag        : $TARGET_TAG"
echo "Install Chart URL : $CHART_URL"
echo "Parallel Jobs     : $MAX_PARALLEL"
echo "Namespace         : $NAMESPACE"
echo "Release           : $RELEASE"
echo "OCI Profile       : ${OCI_PROFILE:-CLI default}"
echo "Region            : ${OCI_REGION:-Tenancy region subscriptions}"
echo "Compartments      : ${COMPARTMENTS:-All accessible compartments}"
echo "State Filter      : $OKE_STATE_FILTER"
echo "Tag Filter        : ${OKE_TAG_FILTER:-NONE - All matching clusters}"
echo "V1 Pre-check      : $V1_PRECHECK_ENABLED"
echo "V1 API Base URL   : $V1_API_BASE_URL"
echo "Run Directory     : $RUN_DIR"
echo "================================================================================"
echo

TENANCY_RESOLVED="$(resolve_tenancy)" || exit 1
V1_CLOUD_ACCOUNT_ID="${V1_CLOUD_ACCOUNT_ID:-$TENANCY_RESOLVED}"

echo "Tenancy           : $TENANCY_RESOLVED"
echo "V1 Account ID     : $V1_CLOUD_ACCOUNT_ID"
echo

echo "Resolving compartments..."
if ! COMPARTMENT_LIST="$(resolve_compartments "$TENANCY_RESOLVED")"; then
    echo "ERROR: Unable to list compartments in tenancy $TENANCY_RESOLVED." >&2
    exit 1
fi

COMPARTMENT_COUNT="$(printf '%s\n' "$COMPARTMENT_LIST" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
echo "Compartments      : $COMPARTMENT_COUNT"
echo

echo "Resolving regions..."
REGION_LIST="$(resolve_regions)"

if [[ -z "$(printf '%s' "$REGION_LIST" | tr -d '[:space:]')" ]]; then
    echo "ERROR: No regions were resolved. Set OCI_REGION=... to scan a single region." >&2
    exit 1
fi

REGION_COUNT="$(printf '%s\n' "$REGION_LIST" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
echo "Regions           : $REGION_COUNT"
echo

echo "Discovering target clusters..."

CLUSTER_COUNT=0
DISCOVERY_FAILURES=0
DISCOVERY_SKIPPED=0

TOTAL_DISCOVERY_START="$(date +%s)"

while IFS= read -r region; do
    [[ -z "$region" ]] && continue

    while IFS=$'\t' read -r compartment_id compartment_name; do
        [[ -z "$compartment_id" ]] && continue

        discovery_start="$(date +%s)"

        if ! clusters="$(list_target_clusters "$region" "$compartment_id")"; then
            discovery_end="$(date +%s)"
            DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))

            echo "[WARNING] Unable to list OKE clusters: region=$region compartment=${compartment_name} (${compartment_id})"
            echo "          Discovery time : $(format_duration "$((discovery_end - discovery_start))")"
            continue
        fi

        discovery_end="$(date +%s)"

        if [[ -z "$(printf '%s' "$clusters" | tr -d '[:space:]')" ]]; then
            DISCOVERY_SKIPPED=$((DISCOVERY_SKIPPED + 1))
            continue
        fi

        sub_cluster_count="$(printf '%s\n' "$clusters" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
        CLUSTER_COUNT=$((CLUSTER_COUNT + sub_cluster_count))

        echo
        echo "--------------------------------------------------------------------------------"
        echo "Region           : $region"
        echo "Compartment      : $compartment_name"
        echo "Compartment ID   : $compartment_id"
        echo "Clusters found   : $sub_cluster_count"
        echo "Discovery time   : $(format_duration "$((discovery_end - discovery_start))")"
        echo "--------------------------------------------------------------------------------"

        while IFS=$'\t' read -r cluster_name cluster_ocid k8s_version; do
            [[ -z "$cluster_name" ]] && continue

            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$region" \
                "$compartment_id" \
                "$compartment_name" \
                "$cluster_name" \
                "$cluster_ocid" \
                "$k8s_version" \
                >> "$TARGETS_FILE"

            printf "  %-40s %-14s %s\n" "$cluster_name" "$k8s_version" "$cluster_ocid"
        done <<< "$clusters"

    done <<< "$COMPARTMENT_LIST"

done <<< "$REGION_LIST"

TOTAL_DISCOVERY_END="$(date +%s)"
TOTAL_DISCOVERY_ELAPSED=$((TOTAL_DISCOVERY_END - TOTAL_DISCOVERY_START))

# ==============================================================================
# DEPLOYMENT TARGET SUMMARY
# ==============================================================================

echo
echo "================================================================================"
echo " DEPLOYMENT TARGET SUMMARY"
echo "================================================================================"

if (( CLUSTER_COUNT > 0 )); then
    printf "%-4s %-16s %-24s %-34s %-12s\n" "#" "REGION" "COMPARTMENT" "CLUSTER" "K8S"
    printf "%-4s %-16s %-24s %-34s %-12s\n" \
        "----" \
        "----------------" \
        "------------------------" \
        "----------------------------------" \
        "------------"

    target_index=0

    while IFS=$'\t' read -r region compartment_id compartment_name cluster_name cluster_ocid k8s_version; do
        [[ -z "$cluster_name" ]] && continue

        target_index=$((target_index + 1))

        printf "%-4s %-16s %-24s %-34s %-12s\n" \
            "$target_index" \
            "${region:0:16}" \
            "${compartment_name:0:24}" \
            "${cluster_name:0:34}" \
            "${k8s_version:0:12}"
    done < "$TARGETS_FILE"
else
    echo "No matching clusters were found."
fi

echo "================================================================================"
echo "Compartments scanned  : $COMPARTMENT_COUNT"
echo "Regions scanned       : $REGION_COUNT"
echo "Empty combinations    : $DISCOVERY_SKIPPED"
echo "Discovery failures    : $DISCOVERY_FAILURES"
echo "Discovery time        : $(format_duration "$TOTAL_DISCOVERY_ELAPSED")"
echo "Clusters targeted     : $CLUSTER_COUNT"
echo "================================================================================"
echo

if (( CLUSTER_COUNT == 0 )); then
    echo "Nothing to deploy. Exiting without applying any changes."
    rm -f "$TARGETS_FILE"

    if (( DISCOVERY_FAILURES > 0 )); then
        exit 2
    fi

    exit 0
fi

if is_true "$DRY_RUN"; then
    echo "DRY_RUN=true - no changes were applied."
    echo "Re-run with DRY_RUN=false (and AUTO_APPROVE=true to skip the prompt) to deploy."
    rm -f "$TARGETS_FILE"
    exit 0
fi

# ==============================================================================
# CONFIRMATION GATE
# ==============================================================================

if is_true "$AUTO_APPROVE"; then
    echo "AUTO_APPROVE=true - skipping confirmation prompt."
else
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        printf "Proceed with deployment to %d cluster(s) across %d compartment(s)? [y/N] " \
            "$CLUSTER_COUNT" "$COMPARTMENT_COUNT" > /dev/tty
        read -r CONFIRM_REPLY < /dev/tty
    else
        echo "ERROR: No interactive terminal is available to confirm the deployment." >&2
        echo "Re-run with AUTO_APPROVE=true (non-interactive apply) or DRY_RUN=true (preview only)." >&2
        rm -f "$TARGETS_FILE"
        exit 1
    fi

    case "$CONFIRM_REPLY" in
        y|Y|yes|Yes|YES)
            ;;
        *)
            echo "Aborted by user. No changes were applied."
            rm -f "$TARGETS_FILE"
            exit 1
            ;;
    esac
fi

echo
echo "Starting deployment..."
echo

mkdir -p "$TEMP_LOG_DIR" "$RESULT_DIR" "$KUBECONFIG_DIR"

generate_overrides_file
echo "Overrides file    : $OVERRIDES_FILE"
echo

TOTAL_START="$(date +%s)"

job_index=0

while IFS=$'\t' read -r region compartment_id compartment_name cluster_name cluster_ocid k8s_version; do
    [[ -z "$cluster_name" ]] && continue

    job_index=$((job_index + 1))

    wait_for_slot

    deploy_cluster \
        "$job_index" \
        "$region" \
        "$compartment_id" \
        "$compartment_name" \
        "$cluster_name" \
        "$cluster_ocid" \
        "$k8s_version" &

done < "$TARGETS_FILE"

echo
echo "Waiting for remaining deployments..."
wait

rm -f "$TARGETS_FILE" "$OVERRIDES_FILE"

TOTAL_END="$(date +%s)"
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))

# ==============================================================================
# BUILD SUMMARY
# ==============================================================================

printf "Index\tRegion\tCompartmentId\tCompartment\tCluster\tClusterOcid\tTrendCluster\tDeploymentMode\tStatus\tSeconds\tStartEpoch\tEndEpoch\n" \
    > "$SUMMARY_FILE"

if find "$RESULT_DIR" -type f -name '*.tsv' -print -quit | grep -q .; then
    while IFS= read -r result_file; do
        cat "$result_file"
    done < <(
        find "$RESULT_DIR" \
            -type f \
            -name '*.tsv' \
            -print \
            | sort
    ) >> "$SUMMARY_FILE"
fi

SUCCESS_COUNT="$(
    awk -F'\t' \
        'NR > 1 && $9 == "SUCCESS" { count++ } END { print count+0 }' \
        "$SUMMARY_FILE"
)"

FAILED_COUNT="$(
    awk -F'\t' \
        'NR > 1 && $9 ~ /^FAILED/ { count++ } END { print count+0 }' \
        "$SUMMARY_FILE"
)"

# ==============================================================================
# BUILD SINGLE CONSOLIDATED LOG
# ==============================================================================

{
    echo "================================================================================"
    echo " TREND VISION ONE CONTAINER SECURITY - MASS OKE (OCI) DEPLOYMENT"
    echo "================================================================================"
    echo "Execution End     : $(timestamp)"
    echo "Tenancy           : $TENANCY_RESOLVED"
    echo "Target Version    : $RESOLVED_VERSION"
    echo "Target Tag        : $TARGET_TAG"
    echo "Install Chart URL : $CHART_URL"
    echo "Region            : ${OCI_REGION:-Tenancy region subscriptions}"
    echo "Compartments      : ${COMPARTMENTS:-All accessible compartments}"
    echo "State Filter      : $OKE_STATE_FILTER"
    echo "Tag Filter        : ${OKE_TAG_FILTER:-NONE - All matching clusters}"
    echo "V1 Pre-check      : $V1_PRECHECK_ENABLED"
    echo "V1 API Base URL   : $V1_API_BASE_URL"
    echo "Parallel Jobs     : $MAX_PARALLEL"
    echo "================================================================================"
    echo

    if find "$TEMP_LOG_DIR" -type f -name '*.log' -print -quit | grep -q .; then
        while IFS= read -r cluster_log; do
            cat "$cluster_log"
        done < <(
            find "$TEMP_LOG_DIR" \
                -type f \
                -name '*.log' \
                -print \
                | sort
        )
    else
        echo "No cluster deployments were executed."
        echo
    fi

    echo
    echo "================================================================================"
    echo " FINAL DEPLOYMENT SUMMARY"
    echo "================================================================================"
    echo "Compartments        : $COMPARTMENT_COUNT"
    echo "Regions             : $REGION_COUNT"
    echo "Clusters            : $CLUSTER_COUNT"
    echo "Successful          : $SUCCESS_COUNT"
    echo "Failed              : $FAILED_COUNT"
    echo "Discovery Failures  : $DISCOVERY_FAILURES"
    echo "Total Time          : $(format_duration "$TOTAL_ELAPSED")"
    echo "================================================================================"
    echo

    printf "%-24s %-34s %-16s %-18s %-19s %-15s\n" \
        "COMPARTMENT" \
        "CLUSTER" \
        "REGION" \
        "MODE" \
        "STATUS" \
        "DURATION"

    printf "%-24s %-34s %-16s %-18s %-19s %-15s\n" \
        "------------------------" \
        "----------------------------------" \
        "----------------" \
        "------------------" \
        "-------------------" \
        "---------------"

    awk -F'\t' '
        NR > 1 {
            seconds=$10

            h=int(seconds/3600)
            m=int((seconds%3600)/60)
            s=seconds%60

            if (h > 0)
                duration=sprintf("%02dh:%02dm:%02ds", h, m, s)
            else if (m > 0)
                duration=sprintf("%02dm:%02ds", m, s)
            else
                duration=sprintf("%02ds", s)

            printf "%-24s %-34s %-16s %-18s %-19s %-15s\n",
                substr($4,1,24),
                substr($5,1,34),
                substr($2,1,16),
                substr($8,1,18),
                $9,
                duration
        }
    ' "$SUMMARY_FILE"

    echo
    echo "================================================================================"
} > "$FINAL_LOG"

# Temporary per-cluster logs/results/kubeconfigs are no longer needed.
rm -rf "$TEMP_LOG_DIR" "$RESULT_DIR" "$KUBECONFIG_DIR"

# ==============================================================================
# FINAL CONSOLE OUTPUT
# ==============================================================================

echo
echo "================================================================================"
echo " DEPLOYMENT COMPLETED"
echo "================================================================================"
echo "Compartments        : $COMPARTMENT_COUNT"
echo "Regions             : $REGION_COUNT"
echo "Clusters            : $CLUSTER_COUNT"
echo "Successful          : $SUCCESS_COUNT"
echo "Failed              : $FAILED_COUNT"
echo "Discovery Failures  : $DISCOVERY_FAILURES"
echo "Total Time          : $(format_duration "$TOTAL_ELAPSED")"
echo "Deployment Log      : $FINAL_LOG"
echo "Summary             : $SUMMARY_FILE"
echo "================================================================================"

if (( FAILED_COUNT > 0 || DISCOVERY_FAILURES > 0 )); then
    exit 2
fi

exit 0
