#!/usr/bin/env bash

# Trend Vision One Container Security - Mass AKS Deployment
# - Multi-subscription discovery
# - Optional Azure tag filtering
# - Dry-run mode: preview the full target list before anything is applied
# - Interactive confirmation gate before deploying (skippable via AUTO_APPROVE)
# - Parallel execution
# - Automatic latest stable Helm chart tag resolution
# - Vision One-aware deployment: helm upgrade for existing clusters, helm upgrade --install for new clusters
# - Existing Vision One clusters upgrade from the repository main branch chart
# - Helm operations use --atomic
# - Per-cluster timing
# - Single consolidated deployment log at the end
# - TSV summary

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
GROUP_ID="${GROUP_ID:-00000000-0000-0000-0000-000000000002}"
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

# ============ AZURE CONFIGURATION ============= #
SUBSCRIPTIONS="${SUBSCRIPTIONS:-}"
AKS_TAG_FILTER="${AKS_TAG_FILTER:-}"

V1_API_BASE_URL="${V1_API_BASE_URL:-https://api.xdr.trendmicro.com}"
V1_K8S_CLUSTERS_ENDPOINT="${V1_API_BASE_URL%/}/v3.0/containerSecurity/kubernetesClusters"

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

# ==============================================================================
# VALIDATION
# ==============================================================================

for cmd in az jq git curl; do
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

if [[ -n "$AKS_TAG_FILTER" ]]; then
    IFS=',' read -r -a _tag_filters <<< "$AKS_TAG_FILTER"

    for _tag_filter in "${_tag_filters[@]}"; do
        _tag_filter="$(trim "$_tag_filter")"

        if [[ "$_tag_filter" != *=* ]]; then
            echo "ERROR: Invalid AKS_TAG_FILTER entry: '$_tag_filter'" >&2
            echo "Expected format: Key=Value[,Key=Value]" >&2
            exit 1
        fi

        _tag_key="$(trim "${_tag_filter%%=*}")"

        if [[ -z "$_tag_key" ]]; then
            echo "ERROR: AKS_TAG_FILTER contains an empty tag key." >&2
            exit 1
        fi
    done
fi

# Validate Azure authentication.
if ! az account show >/dev/null 2>&1; then
    echo "ERROR: Azure CLI is not authenticated. Run 'az login' first." >&2
    exit 1
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
RUN_DIR="${RUN_DIR:-./trend-aks-run-${RUN_TIMESTAMP}}"

TEMP_LOG_DIR="${RUN_DIR}/.tmp-logs"
RESULT_DIR="${RUN_DIR}/.tmp-results"
TARGETS_FILE="${RUN_DIR}/.targets.tsv"

FINAL_LOG="${RUN_DIR}/deployment.log"
SUMMARY_FILE="${RUN_DIR}/summary.tsv"

OVERRIDES_FILE="${RUN_DIR}/overrides.yaml"
OVERRIDES_BASENAME="$(basename "$OVERRIDES_FILE")"

# TEMP_LOG_DIR / RESULT_DIR are created later, only once discovery is
# confirmed and the deployment phase actually starts.
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
# SUBSCRIPTION DISCOVERY
# ==============================================================================

resolve_subscriptions() {
    if [[ -z "$SUBSCRIPTIONS" ]]; then
        az account show --query id -o tsv
    elif [[ "$SUBSCRIPTIONS" == "all" ]]; then
        az account list \
            --query "[?state=='Enabled'].id" \
            -o tsv
    else
        printf '%s\n' "$SUBSCRIPTIONS" \
            | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | sed '/^$/d'
    fi
}

# ==============================================================================
# AKS DISCOVERY + OPTIONAL TAG FILTERING
# ==============================================================================

list_target_clusters() {
    local sub_id="$1"
    local aks_json=""

    if ! aks_json="$(az aks list --subscription "$sub_id" -o json 2>/dev/null)"; then
        return 1
    fi

    if [[ -z "$AKS_TAG_FILTER" ]]; then
        jq -r '
            .[]
            | select(
                (.powerState.code // "") == "Running"
                and
                (.provisioningState // "") == "Succeeded"
            )
            | [
                .name,
                .resourceGroup,
                .id
              ]
            | @tsv
        ' <<< "$aks_json"

        return 0
    fi

    jq -r \
        --arg filters "$AKS_TAG_FILTER" '
        (
            $filters
            | split(",")
            | map(
                gsub("^\\s+|\\s+$"; "")
                | select(length > 0)
                | capture("^(?<key>[^=]+)=(?<value>.*)$")
                | .key |= (
                    gsub("^\\s+|\\s+$"; "")
                    | ascii_downcase
                  )
                | .value |= gsub("^\\s+|\\s+$"; "")
              )
        ) as $requiredTags

        | .[]
        | select(
            (.powerState.code // "") == "Running"
            and
            (.provisioningState // "") == "Succeeded"
          )

        | . as $aks

        | (
            ($aks.tags // {})
            | with_entries(.key |= ascii_downcase)
          ) as $clusterTags

        | select(
            all(
                $requiredTags[];
                (($clusterTags[.key] // null) == .value)
            )
          )

        | [
            $aks.name,
            $aks.resourceGroup,
            $aks.id
          ]
        | @tsv
    ' <<< "$aks_json"
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

    # AKS subscription IDs and the generated Vision One cluster names do not contain
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
# CLUSTER DEPLOYMENT
# ==============================================================================

deploy_cluster() {
    local job_index="$1"
    local sub_id="$2"
    local aks_name="$3"
    local aks_rg="$4"
    local aks_id="$5"
    local sub_name="$6"

    local start_epoch end_epoch elapsed
    local start_time end_time
    local status="FAILED"
    local trend_cluster_name
    local safe_name
    local order
    local temp_log
    local result_file
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
        printf '%s' "$aks_name" \
        | sed 's/[^a-zA-Z0-9_]/_/g'
    )"

    safe_name="$(
        printf '%s' "${sub_id}_${aks_rg}_${aks_name}" \
        | sed 's/[^a-zA-Z0-9_.-]/_/g'
    )"

    order="$(printf '%06d' "$job_index")"

    temp_log="${TEMP_LOG_DIR}/${order}_${safe_name}.log"
    result_file="${RESULT_DIR}/${order}_${safe_name}.tsv"

    echo "[$start_time] [START]   $aks_name | Subscription: $sub_name"

    {
        echo "================================================================================"
        echo " CLUSTER DEPLOYMENT"
        echo "================================================================================"
        echo "Start Time       : $start_time"
        echo "Subscription     : $sub_name"
        echo "Subscription ID  : $sub_id"
        echo "Resource Group   : $aks_rg"
        echo "Azure Cluster    : $aks_name"
        echo "Vision One Name  : $trend_cluster_name"
        echo "Resource ID      : $aks_id"
        echo "Target Version   : $RESOLVED_VERSION"
        echo "Target Tag       : $TARGET_TAG"
        echo "Install Chart URL: $CHART_URL"
        echo "================================================================================"
        echo
    } > "$temp_log"

    # --------------------------------------------------------------------------
    # Vision One pre-check
    # --------------------------------------------------------------------------
    # Existing in Vision One -> helm upgrade ONLY, using main.tar.gz.
    # Not existing in Vision One -> registration + helm upgrade --install.
    if is_true "$V1_PRECHECK_ENABLED"; then
        echo "[INFO] Checking whether the cluster is already registered in Vision One..." >> "$temp_log"
        echo "[INFO] Filter: cloudProviderAccountId eq '$sub_id' and name eq '$trend_cluster_name'" >> "$temp_log"

        v1_lookup_result="$(vision_one_cluster_lookup "$sub_id" "$trend_cluster_name" 2>> "$temp_log")"
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
    else
        echo "[WARNING] V1_PRECHECK_ENABLED=false - using the new-cluster registration flow." >> "$temp_log"
        echo >> "$temp_log"
    fi

    # --------------------------------------------------------------------------
    # Existing cluster in Vision One: UPGRADE ONLY
    # --------------------------------------------------------------------------
    if [[ "$block_deployment" == "false" && "$deployment_mode" == "UPGRADE_EXISTING" ]]; then
        if az aks command invoke \
            --subscription "$sub_id" \
            --resource-group "$aks_rg" \
            --name "$aks_name" \
            --only-show-errors \
            --file "$OVERRIDES_FILE" \
            --command "
                set -e

                echo '============================================================'
                echo 'Trend Vision One Container Security - Existing Cluster'
                echo '============================================================'
                echo 'Azure Cluster : $aks_name'
                echo 'Vision One    : $trend_cluster_name'
                echo 'Action        : helm upgrade'
                echo 'Chart         : $CHART_URL'
                echo

                echo '[1/3] Validating existing Helm release...'

                if ! helm status '$RELEASE' --namespace '$NAMESPACE' >/dev/null 2>&1; then
                    echo '[ERROR] Vision One contains this cluster, but Helm release "$RELEASE" was not found in namespace "$NAMESPACE".'
                    echo '[ERROR] Existing-cluster mode intentionally does not use --install.'
                    exit 1
                fi

                echo '[INFO] Existing Helm release found.'
                echo
                echo '[2/3] Upgrading Container Security...'

                helm upgrade \
                    --reuse-values \
                    --values '$OVERRIDES_BASENAME' \
                    --namespace '$NAMESPACE' \
                    '$RELEASE' \
                    '$CHART_URL' \
                    --atomic \
                    --timeout '$TIMEOUT'

                echo
                echo '[3/3] Validating upgraded deployment...'
                echo
                echo 'Helm status:'

                helm status '$RELEASE' \
                    --namespace '$NAMESPACE'

                echo
                echo 'Trend Micro pods:'

                kubectl get pods \
                    --namespace '$NAMESPACE' \
                    -o wide
            " >> "$temp_log" 2>&1
        then
            status="SUCCESS"
        else
            status="FAILED"
        fi
    fi

    # --------------------------------------------------------------------------
    # New cluster: keep the existing registration + upgrade --install logic
    # --------------------------------------------------------------------------
    if [[ "$block_deployment" == "false" && "$deployment_mode" == "NEW_CLUSTER" ]]; then
        if az aks command invoke \
            --subscription "$sub_id" \
            --resource-group "$aks_rg" \
            --name "$aks_name" \
            --only-show-errors \
            --file "$OVERRIDES_FILE" \
            --command "
                set -e

                echo '============================================================'
                echo 'Trend Vision One Container Security - New Cluster'
                echo '============================================================'
                echo 'Azure Cluster : $aks_name'
                echo 'Vision One    : $trend_cluster_name'
                echo 'Target Version: $RESOLVED_VERSION'
                echo 'Action        : helm upgrade --install'
                echo

                echo '[1/3] Creating namespace if required...'

                kubectl create namespace '$NAMESPACE' \
                    --dry-run=client \
                    -o yaml \
                    | kubectl apply -f -

                echo
                echo '[2/3] Applying Vision One registration secret...'

                kubectl create secret generic trendmicro-container-security-registration-key \
                    --from-literal=registration.key='$V1_API_KEY' \
                    -n '$NAMESPACE' \
                    --dry-run=client \
                    -o yaml | kubectl apply -f -

                if ! kubectl get secret trendmicro-container-security-registration-key -n '$NAMESPACE' >/dev/null 2>&1; then
                    echo '[ERROR] Required secret trendmicro-container-security-registration-key could not be created.'
                    exit 1
                fi

                echo '[INFO] Secret trendmicro-container-security-registration-key is available.'

                echo
                echo '[3/3] Installing / upgrading Container Security...'

                helm upgrade --install \
                    '$RELEASE' \
                    '$CHART_URL' \
                    --namespace '$NAMESPACE' \
                    --values '$OVERRIDES_BASENAME' \
                    --set visionOne.clusterRegistrationKey=true \
                    --set-string visionOne.groupId='$GROUP_ID' \
                    --set-string visionOne.clusterName='$trend_cluster_name' \
                    --set-string visionOne.resourceId='$aks_id' \
                    --atomic \
                    --timeout '$TIMEOUT'

                echo
                echo 'Helm status:'

                helm status '$RELEASE' \
                    --namespace '$NAMESPACE'

                echo
                echo 'Trend Micro pods:'

                kubectl get pods \
                    --namespace '$NAMESPACE' \
                    -o wide
            " >> "$temp_log" 2>&1
        then
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

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$job_index" \
        "$sub_id" \
        "$sub_name" \
        "$aks_rg" \
        "$aks_name" \
        "$trend_cluster_name" \
        "$deployment_mode" \
        "$status" \
        "$elapsed" \
        "$start_epoch" \
        "$end_epoch" \
        > "$result_file"

    printf "[%s] [%-7s] %s | %-16s | %s\n" \
        "$end_time" \
        "$status" \
        "$aks_name" \
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
echo " Trend Vision One - AKS Mass Deployment"
echo "================================================================================"
echo "Start Time       : $(timestamp)"
echo "Mode             : $(is_true "$DRY_RUN" && echo "DRY-RUN (preview only)" || echo "APPLY")"
echo "Target Version   : $RESOLVED_VERSION"
echo "Target Tag       : $TARGET_TAG"
echo "Install Chart URL: $CHART_URL"
echo "Parallel Jobs    : $MAX_PARALLEL"
echo "Namespace        : $NAMESPACE"
echo "Release          : $RELEASE"
echo "Subscriptions    : ${SUBSCRIPTIONS:-Current Azure CLI subscription}"
echo "Tag Filter       : ${AKS_TAG_FILTER:-NONE - All Running/Succeeded clusters}"
echo "V1 Pre-check      : $V1_PRECHECK_ENABLED"
echo "V1 API Base URL  : $V1_API_BASE_URL"
echo "Run Directory    : $RUN_DIR"
echo "================================================================================"
echo
echo "Discovering target clusters..."

SUBSCRIPTION_COUNT=0
CLUSTER_COUNT=0
DISCOVERY_FAILURES=0

while IFS= read -r sub_id; do
    [[ -z "$sub_id" ]] && continue

    SUBSCRIPTION_COUNT=$((SUBSCRIPTION_COUNT + 1))

    sub_name="$(
        az account show \
            --subscription "$sub_id" \
            --query name \
            -o tsv 2>/dev/null
    )"

    [[ -z "$sub_name" ]] && sub_name="$sub_id"

    echo
    echo "--------------------------------------------------------------------------------"
    echo "Subscription     : $sub_name"
    echo "Subscription ID  : $sub_id"
    echo "Tag Filter       : ${AKS_TAG_FILTER:-NONE}"
    echo "--------------------------------------------------------------------------------"

    discovery_start="$(date +%s)"

    if ! clusters="$(list_target_clusters "$sub_id")"; then
        discovery_end="$(date +%s)"
        DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))

        echo "[WARNING] Unable to list AKS clusters in subscription $sub_name."
        echo "Discovery time   : $(format_duration "$((discovery_end - discovery_start))")"
        continue
    fi

    discovery_end="$(date +%s)"

    if [[ -z "$clusters" ]]; then
        echo "Clusters found   : 0"
        echo "Discovery time   : $(format_duration "$((discovery_end - discovery_start))")"
        continue
    fi

    sub_cluster_count="$(
        printf '%s\n' "$clusters" \
        | sed '/^[[:space:]]*$/d' \
        | wc -l \
        | tr -d ' '
    )"

    echo "Clusters found   : $sub_cluster_count"
    echo "Discovery time   : $(format_duration "$((discovery_end - discovery_start))")"
    echo

    while IFS=$'\t' read -r aks_name aks_rg aks_id; do
        [[ -z "$aks_name" ]] && continue

        CLUSTER_COUNT=$((CLUSTER_COUNT + 1))

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$sub_id" "$sub_name" "$aks_name" "$aks_rg" "$aks_id" \
            >> "$TARGETS_FILE"

    done <<< "$clusters"

done < <(resolve_subscriptions)

# ==============================================================================
# DEPLOYMENT TARGET SUMMARY
# ==============================================================================

echo
echo "================================================================================"
echo " DEPLOYMENT TARGET SUMMARY"
echo "================================================================================"

if (( CLUSTER_COUNT > 0 )); then
    printf "%-4s %-28s %-20s %-34s\n" "#" "SUBSCRIPTION" "RESOURCE GROUP" "CLUSTER"
    printf "%-4s %-28s %-20s %-34s\n" \
        "----" \
        "----------------------------" \
        "--------------------" \
        "----------------------------------"

    target_index=0

    while IFS=$'\t' read -r sub_id sub_name aks_name aks_rg aks_id; do
        [[ -z "$aks_name" ]] && continue

        target_index=$((target_index + 1))

        printf "%-4s %-28s %-20s %-34s\n" \
            "$target_index" \
            "${sub_name:0:28}" \
            "${aks_rg:0:20}" \
            "${aks_name:0:34}"
    done < "$TARGETS_FILE"
else
    echo "No matching clusters were found."
fi

echo "================================================================================"
echo "Subscriptions scanned : $SUBSCRIPTION_COUNT"
echo "Discovery failures    : $DISCOVERY_FAILURES"
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
        printf "Proceed with deployment to %d cluster(s) across %d subscription(s)? [y/N] " \
            "$CLUSTER_COUNT" "$SUBSCRIPTION_COUNT" > /dev/tty
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

mkdir -p "$TEMP_LOG_DIR" "$RESULT_DIR"

generate_overrides_file
echo "Overrides file   : $OVERRIDES_FILE"
echo

TOTAL_START="$(date +%s)"

job_index=0

while IFS=$'\t' read -r sub_id sub_name aks_name aks_rg aks_id; do
    [[ -z "$aks_name" ]] && continue

    job_index=$((job_index + 1))

    wait_for_slot

    deploy_cluster \
        "$job_index" \
        "$sub_id" \
        "$aks_name" \
        "$aks_rg" \
        "$aks_id" \
        "$sub_name" &

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

printf "Index\tSubscriptionId\tSubscription\tResourceGroup\tCluster\tTrendCluster\tDeploymentMode\tStatus\tSeconds\tStartEpoch\tEndEpoch\n" \
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
        'NR > 1 && $8 == "SUCCESS" { count++ } END { print count+0 }' \
        "$SUMMARY_FILE"
)"

FAILED_COUNT="$(
    awk -F'\t' \
        'NR > 1 && $8 ~ /^FAILED/ { count++ } END { print count+0 }' \
        "$SUMMARY_FILE"
)"


# ==============================================================================
# BUILD SINGLE CONSOLIDATED LOG
# ==============================================================================

{
    echo "================================================================================"
    echo " TREND VISION ONE CONTAINER SECURITY - MASS AKS DEPLOYMENT"
    echo "================================================================================"
    echo "Execution End    : $(timestamp)"
    echo "Target Version   : $RESOLVED_VERSION"
    echo "Target Tag       : $TARGET_TAG"
    echo "Install Chart URL: $CHART_URL"
    echo "Subscriptions    : ${SUBSCRIPTIONS:-Current Azure CLI subscription}"
    echo "Tag Filter       : ${AKS_TAG_FILTER:-NONE - All Running/Succeeded clusters}"
    echo "V1 Pre-check      : $V1_PRECHECK_ENABLED"
    echo "V1 API Base URL  : $V1_API_BASE_URL"
    echo "Parallel Jobs    : $MAX_PARALLEL"
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
    echo "Subscriptions       : $SUBSCRIPTION_COUNT"
    echo "Clusters             : $CLUSTER_COUNT"
    echo "Successful           : $SUCCESS_COUNT"
    echo "Failed               : $FAILED_COUNT"
    echo "Discovery Failures   : $DISCOVERY_FAILURES"
    echo "Total Time           : $(format_duration "$TOTAL_ELAPSED")"
    echo "================================================================================"
    echo

    printf "%-28s %-34s %-18s %-18s %-15s\n" \
        "SUBSCRIPTION" \
        "CLUSTER" \
        "MODE" \
        "STATUS" \
        "DURATION"

    printf "%-28s %-34s %-18s %-18s %-15s\n" \
        "----------------------------" \
        "----------------------------------" \
        "------------------" \
        "------------------" \
        "---------------"

    awk -F'\t' '
        NR > 1 {
            seconds=$9

            h=int(seconds/3600)
            m=int((seconds%3600)/60)
            s=seconds%60

            if (h > 0)
                duration=sprintf("%02dh:%02dm:%02ds", h, m, s)
            else if (m > 0)
                duration=sprintf("%02dm:%02ds", m, s)
            else
                duration=sprintf("%02ds", s)

            printf "%-28s %-34s %-18s %-18s %-15s\n",
                substr($3,1,28),
                substr($5,1,34),
                substr($7,1,18),
                $8,
                duration
        }
    ' "$SUMMARY_FILE"

    echo
    echo "================================================================================"
} > "$FINAL_LOG"

# Temporary per-cluster logs/results are no longer needed.
rm -rf "$TEMP_LOG_DIR" "$RESULT_DIR"

# ==============================================================================
# FINAL CONSOLE OUTPUT
# ==============================================================================

echo
echo "================================================================================"
echo " DEPLOYMENT COMPLETED"
echo "================================================================================"
echo "Subscriptions       : $SUBSCRIPTION_COUNT"
echo "Clusters             : $CLUSTER_COUNT"
echo "Successful           : $SUCCESS_COUNT"
echo "Failed               : $FAILED_COUNT"
echo "Discovery Failures   : $DISCOVERY_FAILURES"
echo "Total Time           : $(format_duration "$TOTAL_ELAPSED")"
echo "Deployment Log       : $FINAL_LOG"
echo "Summary              : $SUMMARY_FILE"
echo "================================================================================"

if (( FAILED_COUNT > 0 || DISCOVERY_FAILURES > 0 )); then
    exit 2
fi

exit 0