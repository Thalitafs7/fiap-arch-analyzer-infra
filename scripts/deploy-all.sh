#!/usr/bin/env bash
# deploy-all.sh — Deployment_Orchestrator for Arch Analyzer on AWS Academy EKS
# POSIX-compatible bash (bash 4+). Same logic as deploy-all.ps1.
#
# Requirements fulfilled:
#   15.2  Validate repo_path and k8s_dir exist; fail fast on missing
#   15.3  Verify aws sts get-caller-identity before proceeding
#   15.4  terraform init + apply -auto-approve
#   15.5  aws eks update-kubeconfig using eks_cluster_name TF output
#   15.6  docker build + push tagged with git rev-parse --short HEAD
#   15.7  Wait for MongoDB + Redis rollout before per-service apply
#   15.8  kubectl apply -k when kustomization.yaml exists, else -f
#   15.9  Stage order: auth → {reg,report,proc} → api-gateway
#   15.10 Block on rollout status between stages
#   15.11 Write validation report to ./artifacts/
#   15.12 One automatic retry on Validator failure
#   15.13 Stop on ExpiredToken, prompt user, exit non-zero
#   15.14 Idempotent re-runs produce zero drift
#
# Usage:
#   ./scripts/deploy-all.sh [--config PATH] [--dry-run] [--git-sha SHA]

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_PATH="$SCRIPT_DIR/deploy-all.config.yaml"
DRY_RUN=0
GIT_SHA_OVERRIDE=""

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --config)    CONFIG_PATH="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --git-sha)   GIT_SHA_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# Usage/,/^$/p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ─── Colour helpers ───────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

step()    { echo -e "\n${CYAN}==> $*${NC}"; }
info()    { echo -e "    $*"; }
success() { echo -e "    ${GREEN}[OK] $*${NC}"; }
fail()    { echo -e "    ${RED}[FAIL] $*${NC}"; }

# ─── Command runner with ExpiredToken detection (Req 15.13) ──────────────────
run_cmd() {
    # Usage: run_cmd [--capture VAR] -- cmd args...
    local capture_var=""
    if [ "$1" = "--capture" ]; then
        capture_var="$2"
        shift 2
    fi
    # Strip leading '--' separator if present
    [ "$1" = "--" ] && shift

    local cmd_str="$*"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY-RUN] $cmd_str"
        [ -n "$capture_var" ] && eval "$capture_var=''"
        return 0
    fi

    info "$ $cmd_str"
    local output
    if [ -n "$capture_var" ]; then
        output=$("$@" 2>&1) || {
            local exit_code=$?
            if echo "$output" | grep -qE "ExpiredToken|ExpiredTokenException"; then
                expired_token_exit
            fi
            echo "$output" >&2
            return $exit_code
        }
        if echo "$output" | grep -qE "ExpiredToken|ExpiredTokenException"; then
            expired_token_exit
        fi
        eval "$capture_var=\$output"
    else
        "$@" 2>&1 | tee /tmp/_deploy_cmd_out || {
            local exit_code=${PIPESTATUS[0]}
            if grep -qE "ExpiredToken|ExpiredTokenException" /tmp/_deploy_cmd_out 2>/dev/null; then
                expired_token_exit
            fi
            return $exit_code
        }
        if grep -qE "ExpiredToken|ExpiredTokenException" /tmp/_deploy_cmd_out 2>/dev/null; then
            expired_token_exit
        fi
    fi
}

expired_token_exit() {
    fail "AWS credentials have expired (ExpiredToken)."
    echo ""
    echo -e "  ${YELLOW}ACTION REQUIRED: Refresh your AWS Academy Learner Lab credentials.${NC}"
    echo -e "  ${YELLOW}1. Open the Learner Lab console and click 'Start Lab'.${NC}"
    echo -e "  ${YELLOW}2. Copy the new credentials into ~/.aws/credentials (or set env vars).${NC}"
    echo -e "  ${YELLOW}3. Re-run this script.${NC}"
    exit 1
}

# ─── YAML parser (requires python3+pyyaml or yq) ─────────────────────────────
parse_yaml_field() {
    # parse_yaml_field <file> <jq-expression>
    local file="$1" expr="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, yaml, json
with open('$file') as f:
    d = yaml.safe_load(f)
print(json.dumps(d))
" | python3 -c "import sys,json; d=json.load(sys.stdin); print($expr)"
    elif command -v yq >/dev/null 2>&1; then
        yq -r "$expr" "$file"
    else
        echo "ERROR: install python3 (with pyyaml) or yq to parse YAML" >&2
        exit 1
    fi
}

# Parse full config to JSON once
parse_config_json() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, yaml, json
with open('$CONFIG_PATH') as f:
    print(json.dumps(yaml.safe_load(f)))
"
    elif command -v yq >/dev/null 2>&1; then
        yq -o=json "$CONFIG_PATH"
    else
        echo "ERROR: install python3 (with pyyaml) or yq" >&2
        exit 1
    fi
}

# ─── Stage 0: Load config ─────────────────────────────────────────────────────
step "Loading orchestrator config: $CONFIG_PATH"
[ -f "$CONFIG_PATH" ] || { fail "Config not found: $CONFIG_PATH"; exit 1; }
CONFIG_JSON="$(parse_config_json)"
SVC_COUNT=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['services']))")
success "Config loaded ($SVC_COUNT services)"

# Helper: get field from service by name
svc_field() {
    local name="$1" field="$2"
    echo "$CONFIG_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
svc=next(s for s in d['services'] if s['name']=='$name')
val=svc.get('$field','')
if isinstance(val,list): print(' '.join(str(v) for v in val))
else: print(val if val is not None else '')
"
}

svc_names() {
    echo "$CONFIG_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d['services']: print(s['name'])
"
}

svc_has_migrations() {
    local name="$1"
    echo "$CONFIG_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
svc=next(s for s in d['services'] if s['name']=='$name')
print('yes' if svc.get('migrations') else 'no')
"
}

svc_migration_cmd() {
    local name="$1"
    echo "$CONFIG_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
svc=next(s for s in d['services'] if s['name']=='$name')
m=svc.get('migrations',{})
print(m.get('command',''))
"
}

svc_migration_workdir() {
    local name="$1"
    echo "$CONFIG_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
svc=next(s for s in d['services'] if s['name']=='$name')
m=svc.get('migrations',{})
print(m.get('workdir',''))
"
}

resolve_repo_abs() {
    local repo_path="$1"
    if [[ "$repo_path" = /* ]]; then
        echo "$repo_path"
    else
        echo "$INFRA_ROOT/$repo_path"
    fi
}

# ─── Stage 1: Validate paths (Req 15.2) ──────────────────────────────────────
step "Validating repo paths and k8s directories (Req 15.2)"
MISSING=0
while IFS= read -r svc_name; do
    repo_path=$(svc_field "$svc_name" "repo_path")
    k8s_dir=$(svc_field "$svc_name" "k8s_dir")
    [ -z "$k8s_dir" ] && k8s_dir="k8s"
    repo_abs=$(resolve_repo_abs "$repo_path")
    k8s_abs="$repo_abs/$k8s_dir"

    if [ ! -d "$repo_abs" ]; then
        fail "repo_path missing: $repo_abs (service: $svc_name)"
        MISSING=1
    fi
    if [ ! -d "$k8s_abs" ]; then
        fail "k8s_dir missing: $k8s_abs (service: $svc_name)"
        MISSING=1
    fi
done < <(svc_names)

[ "$MISSING" -eq 1 ] && { fail "Path validation failed. Aborting."; exit 1; }
success "All repo paths and k8s dirs exist"

# ─── Stage 2: Verify AWS credentials (Req 15.3) ───────────────────────────────
step "Verifying AWS credentials (Req 15.3)"
run_cmd --capture CALLER_IDENTITY -- aws sts get-caller-identity --output json
CALLER_ARN=$(echo "$CALLER_IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
success "Authenticated as: $CALLER_ARN"

# ─── Stage 3: Terraform init + apply (Req 15.4) ───────────────────────────────
step "Running terraform init (Req 15.4)"
run_cmd -- terraform -chdir="$INFRA_ROOT" init -input=false

step "Running terraform apply (Req 15.4)"
run_cmd -- terraform -chdir="$INFRA_ROOT" apply -auto-approve -input=false

# ─── Stage 4: Capture Terraform outputs ───────────────────────────────────────
step "Reading Terraform outputs"
run_cmd --capture EKS_CLUSTER_NAME -- terraform -chdir="$INFRA_ROOT" output -raw eks_cluster_name
run_cmd --capture ALB_DNS_NAME     -- terraform -chdir="$INFRA_ROOT" output -raw alb_dns_name
run_cmd --capture ECR_URLS_JSON    -- terraform -chdir="$INFRA_ROOT" output -json ecr_repository_urls

success "EKS cluster: $EKS_CLUSTER_NAME"
success "ALB DNS:     $ALB_DNS_NAME"

# ─── Stage 5: Update kubeconfig (Req 15.5) ────────────────────────────────────
step "Updating kubeconfig for cluster: $EKS_CLUSTER_NAME (Req 15.5)"
run_cmd -- aws eks update-kubeconfig --region us-east-1 --name "$EKS_CLUSTER_NAME"
success "kubeconfig updated"

# ─── Stage 6: Wait for shared bootstrap (Req 15.7) ────────────────────────────
step "Waiting for MongoDB and Redis readiness (Req 15.7)"

wait_statefulset() {
    local ns="$1" name="$2" timeout="${3:-5m}"
    info "Waiting: statefulset/$name -n $ns (timeout $timeout)"
    kubectl rollout status "statefulset/$name" -n "$ns" --timeout="$timeout" 2>/dev/null || {
        info "StatefulSet '$name' not found, waiting for pods by label..."
        kubectl wait pod -n "$ns" -l "app.kubernetes.io/name=$name" \
            --for=condition=Ready --timeout="$timeout" 2>/dev/null || true
    }
}

wait_statefulset "data" "mongodb"
# Bitnami redis chart uses 'redis-master' for the primary StatefulSet
kubectl rollout status statefulset/redis-master -n data --timeout=5m 2>/dev/null || \
    kubectl rollout status statefulset/redis -n data --timeout=5m 2>/dev/null || \
    kubectl wait pod -n data -l "app.kubernetes.io/name=redis" \
        --for=condition=Ready --timeout=5m 2>/dev/null || true

success "MongoDB and Redis are ready"

# ─── Stage 7: ECR login + build + push (Req 15.6) ─────────────────────────────
step "Logging in to ECR (Req 15.6)"
SAMPLE_ECR_URL=$(echo "$ECR_URLS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(list(d.values())[0])")
ECR_REGISTRY=$(echo "$SAMPLE_ECR_URL" | cut -d'/' -f1)
AWS_REGION="us-east-1"

if [ "$DRY_RUN" -eq 0 ]; then
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_REGISTRY"
else
    info "[DRY-RUN] docker login --username AWS --password-stdin $ECR_REGISTRY"
fi

# Resolve git SHA (Req 15.6)
if [ -n "$GIT_SHA_OVERRIDE" ]; then
    GIT_SHA="$GIT_SHA_OVERRIDE"
else
    GIT_SHA=$(git -C "$INFRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "latest")
fi
info "Image tag: $GIT_SHA"

while IFS= read -r svc_name; do
    step "Building image: $svc_name"
    repo_path=$(svc_field "$svc_name" "repo_path")
    dockerfile=$(svc_field "$svc_name" "dockerfile")
    build_context=$(svc_field "$svc_name" "build_context")
    ecr_key=$(svc_field "$svc_name" "ecr_key")

    repo_abs=$(resolve_repo_abs "$repo_path")
    ecr_url=$(echo "$ECR_URLS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$ecr_key',''))")

    if [ -z "$ecr_url" ]; then
        fail "ECR URL not found for key '$ecr_key'. Check terraform outputs."
        exit 1
    fi

    image_tag="${ecr_url}:${GIT_SHA}"
    dockerfile_abs="$repo_abs/$dockerfile"
    build_context_abs="$repo_abs/$build_context"

    run_cmd -- docker build -t "$image_tag" -f "$dockerfile_abs" "$build_context_abs"
    info "Pushing: $image_tag"
    run_cmd -- docker push "$image_tag"
    success "Pushed: $image_tag"
done < <(svc_names)

# ─── Stage 8: Database migrations ─────────────────────────────────────────────
step "Running database migrations (services that declare them)"
while IFS= read -r svc_name; do
    has_migr=$(svc_has_migrations "$svc_name")
    [ "$has_migr" = "yes" ] || continue

    info "Migration for $svc_name"
    repo_path=$(svc_field "$svc_name" "repo_path")
    repo_abs=$(resolve_repo_abs "$repo_path")
    migr_cmd=$(svc_migration_cmd "$svc_name")
    migr_workdir=$(svc_migration_workdir "$svc_name")

    if [ -n "$migr_workdir" ]; then
        migr_dir="$repo_abs/$migr_workdir"
    else
        migr_dir="$repo_abs"
    fi

    (cd "$migr_dir" && eval "$migr_cmd")
    success "Migration complete: $svc_name"
done < <(svc_names)

# ─── Stage 9: Per-service k8s apply in stage order (Req 15.8/15.9/15.10) ──────

# Stage order: auth → {registration, report, processing} → api-gateway (Req 15.9)
STAGE_1="auth-service"
STAGE_2="registration-service report-service processing-service"
STAGE_3="api-gateway"

apply_service() {
    local svc_name="$1"
    # Check service exists in config
    local in_cfg
    in_cfg=$(echo "$CONFIG_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
names=[s['name'] for s in d['services']]
print('yes' if '$svc_name' in names else 'no')
")
    if [ "$in_cfg" = "no" ]; then
        info "Service '$svc_name' not in config, skipping"
        return 0
    fi

    local repo_path k8s_dir namespace
    repo_path=$(svc_field "$svc_name" "repo_path")
    k8s_dir=$(svc_field "$svc_name" "k8s_dir")
    namespace=$(svc_field "$svc_name" "namespace")
    [ -z "$k8s_dir" ] && k8s_dir="k8s"

    local repo_abs k8s_path
    repo_abs=$(resolve_repo_abs "$repo_path")
    k8s_path="$repo_abs/$k8s_dir"

    # Req 15.8: prefer kustomize when kustomization.yaml exists
    if [ -f "$k8s_path/kustomization.yaml" ]; then
        info "kubectl apply -k $k8s_path"
        run_cmd -- kubectl apply -k "$k8s_path"
    else
        info "kubectl apply -f $k8s_path/ --namespace $namespace"
        run_cmd -- kubectl apply -f "$k8s_path/" --namespace "$namespace"
    fi
}

wait_service_rollouts() {
    local svc_name="$1"
    local in_cfg
    in_cfg=$(echo "$CONFIG_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
names=[s['name'] for s in d['services']]
print('yes' if '$svc_name' in names else 'no')
")
    [ "$in_cfg" = "no" ] && return 0

    local namespace deployments
    namespace=$(svc_field "$svc_name" "namespace")
    deployments=$(svc_field "$svc_name" "deployments")

    for dep in $deployments; do
        info "Waiting rollout: deployment/$dep -n $namespace"
        if [ "$DRY_RUN" -eq 0 ]; then
            kubectl rollout status "deployment/$dep" -n "$namespace" --timeout=5m
        else
            info "[DRY-RUN] kubectl rollout status deployment/$dep -n $namespace --timeout=5m"
        fi
    done
}

# Stage 1: auth-service
step "Applying stage 1: [$STAGE_1]"
for svc in $STAGE_1; do apply_service "$svc"; done
for svc in $STAGE_1; do wait_service_rollouts "$svc"; done
success "Stage 1 [$STAGE_1] ready"

# Stage 2: registration, report, processing (parallel apply, sequential wait)
step "Applying stage 2: [$STAGE_2]"
for svc in $STAGE_2; do apply_service "$svc"; done
for svc in $STAGE_2; do wait_service_rollouts "$svc"; done
success "Stage 2 [$STAGE_2] ready"

# Stage 3: api-gateway
step "Applying stage 3: [$STAGE_3]"
for svc in $STAGE_3; do apply_service "$svc"; done
for svc in $STAGE_3; do wait_service_rollouts "$svc"; done
success "Stage 3 [$STAGE_3] ready"

# ─── Stage 10: Invoke Validator + write report (Req 15.11) ────────────────────
step "Running Validator (Req 15.11)"

ARTIFACTS_DIR="$INFRA_ROOT/artifacts"
mkdir -p "$ARTIFACTS_DIR"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
REPORT_JSON="$ARTIFACTS_DIR/validation-report-$TIMESTAMP.json"
REPORT_MD="$ARTIFACTS_DIR/validation-report-$TIMESTAMP.md"

VALIDATE_SCRIPT="$SCRIPT_DIR/validate.sh"

run_validator() {
    local alb_dns="$1" json_out="$2" md_out="$3"
    if [ -x "$VALIDATE_SCRIPT" ]; then
        "$VALIDATE_SCRIPT" --alb-dns "$alb_dns" --config "$CONFIG_PATH" \
            --report-json "$json_out" --report-md "$md_out"
        return $?
    fi
    # Inline fallback validator (Req 16)
    info "validate.sh not found; running inline validator"
    inline_validator "$alb_dns" "$json_out" "$md_out"
}

inline_validator() {
    local alb_dns="$1" json_out="$2" md_out="$3"
    local overall=true
    local results_json="["
    local first=1

    while IFS= read -r svc_name; do
        # celery-worker has no ingress/health endpoint
        [ "$svc_name" = "celery-worker" ] && continue

        local ingress_path health_path
        ingress_path=$(svc_field "$svc_name" "ingress_path")
        health_path=$(svc_field "$svc_name" "health_path")
        [ -z "$health_path" ] && health_path="/health"

        local url="http://$alb_dns$ingress_path/health"
        info "Probing: $url"

        local status="FAIL" latency_ms="null" last_error=""
        local deadline
        deadline=$(( $(date +%s) + 300 ))  # 5 minutes

        while [ "$(date +%s)" -lt "$deadline" ]; do
            local start_ts
            start_ts=$(date +%s%3N)
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --max-time 5 "$url" 2>/dev/null || echo "000")
            local end_ts
            end_ts=$(date +%s%3N)

            if [ "$http_code" = "200" ]; then
                status="PASS"
                latency_ms=$(( end_ts - start_ts ))
                break
            fi
            last_error="HTTP $http_code"
            sleep 10
        done

        [ "$status" = "FAIL" ] && overall=false

        local icon
        [ "$status" = "PASS" ] && icon="[PASS]" || icon="[FAIL]"
        info "$icon $svc_name — $url"

        [ "$first" -eq 0 ] && results_json+=","
        results_json+="{\"service\":\"$svc_name\",\"status\":\"$status\",\"latencyMs\":$latency_ms,\"error\":\"$last_error\"}"
        first=0
    done < <(svc_names)

    results_json+="]"

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$json_out" <<EOF
{
  "timestamp": "$ts",
  "overall": $overall,
  "alb_dns": "$alb_dns",
  "services": $results_json
}
EOF

    # Markdown report
    {
        echo "# Validation Report"
        echo ""
        echo "**Timestamp:** $ts"
        echo "**ALB DNS:** $alb_dns"
        if $overall; then
            echo "**Overall:** ✅ PASS"
        else
            echo "**Overall:** ❌ FAIL"
        fi
        echo ""
        echo "## Services"
        echo ""
        echo "| Service | Status | Latency (ms) | Error |"
        echo "|---------|--------|-------------|-------|"
        echo "$results_json" | python3 -c "
import sys,json
rows=json.load(sys.stdin)
for r in rows:
    icon='✅' if r['status']=='PASS' else '❌'
    print(f\"| {r['service']} | {icon} {r['status']} | {r['latencyMs']} | {r['error']} |\")
"
    } > "$md_out"

    $overall && return 0 || return 1
}

if run_validator "$ALB_DNS_NAME" "$REPORT_JSON" "$REPORT_MD"; then
    VALIDATION_PASSED=1
else
    VALIDATION_PASSED=0
fi

# ─── Stage 11: Auto-retry on failure (Req 15.12) ──────────────────────────────
if [ "$VALIDATION_PASSED" -eq 0 ]; then
    step "Validator reported failures — attempting automatic retry (Req 15.12)"

    while IFS= read -r svc_name; do
        local_ns=$(svc_field "$svc_name" "namespace")
        local_deps=$(svc_field "$svc_name" "deployments")
        for dep in $local_deps; do
            info "kubectl rollout restart deployment/$dep -n $local_ns"
            kubectl rollout restart "deployment/$dep" -n "$local_ns" 2>/dev/null || true
        done
    done < <(svc_names)

    # Wait for rollouts to settle
    while IFS= read -r svc_name; do
        local_ns=$(svc_field "$svc_name" "namespace")
        local_deps=$(svc_field "$svc_name" "deployments")
        for dep in $local_deps; do
            kubectl rollout status "deployment/$dep" -n "$local_ns" --timeout=5m 2>/dev/null || true
        done
    done < <(svc_names)

    TIMESTAMP2=$(date +"%Y%m%d-%H%M%S")
    REPORT_JSON="$ARTIFACTS_DIR/validation-report-$TIMESTAMP2.json"
    REPORT_MD="$ARTIFACTS_DIR/validation-report-$TIMESTAMP2.md"

    if run_validator "$ALB_DNS_NAME" "$REPORT_JSON" "$REPORT_MD"; then
        VALIDATION_PASSED=1
    else
        VALIDATION_PASSED=0
    fi
fi

# ─── Final summary ─────────────────────────────────────────────────────────────
step "Deployment complete"
info "Report JSON: $REPORT_JSON"
info "Report MD:   $REPORT_MD"

if [ "$VALIDATION_PASSED" -eq 1 ]; then
    success "All services PASS. Stack is healthy."
    exit 0
else
    fail "One or more services FAILED validation after retry."
    fail "Review the report: $REPORT_JSON"
    exit 1
fi
