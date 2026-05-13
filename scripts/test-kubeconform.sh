#!/usr/bin/env bash
# test-kubeconform.sh
# Validates Kubernetes manifests in every Service_K8s_Folder using kubeconform.
#
# Runs:
#   kubeconform -summary -strict -kubernetes-version 1.29 <yaml_files...>
#
# against each service k8s/ folder. Skips aws-secret-template.yaml files
# (they contain placeholder values that fail schema validation).
#
# Exits non-zero if any validation fails. Prints a summary at the end.
#
# Usage:
#   bash scripts/test-kubeconform.sh

set -euo pipefail

# ── Service k8s/ folders ──────────────────────────────────────────────────────
declare -A SERVICE_FOLDERS=(
  ["auth-service"]="/c/projects/fiap-arch-analyzer-auth-service/k8s"
  ["api-gateway"]="/c/projects/fiap-arch-analyzer-api-gateway/k8s"
  ["registration-service"]="/c/projects/fiap-arch-analyzer-registration-service/k8s"
  ["processing-service"]="/c/projects/fiap-arch-analyzer-processing-service/k8s"
  ["report-service"]="/c/projects/fiap-arch-analyzer-report-service/k8s"
)

# Ordered list (bash associative arrays are unordered)
SERVICE_ORDER=(
  "auth-service"
  "api-gateway"
  "registration-service"
  "processing-service"
  "report-service"
)

K8S_VERSION="1.29"
SKIP_FILE="aws-secret-template.yaml"

FAILURES=()
SUCCESSES=()

# ── Helpers ───────────────────────────────────────────────────────────────────
step() { echo; echo "==> $*"; }
pass() { SUCCESSES+=("$1"); echo "  [PASS] $1"; }
fail() { FAILURES+=("$1"); echo "  [FAIL] $1${2:+ — $2}" >&2; }

# ── Detect Windows paths (Git Bash / WSL) ────────────────────────────────────
# On native Windows paths like c:\projects\..., convert to /c/projects/...
resolve_path() {
  local p="$1"
  # If running under WSL, convert Windows path
  if command -v wslpath &>/dev/null && [[ "$p" == *\\* ]]; then
    wslpath "$p"
  elif [[ "$p" == [A-Za-z]:\\* ]]; then
    # Git Bash style: C:\foo → /c/foo
    local drive="${p:0:1}"
    local rest="${p:2}"
    echo "/${drive,,}${rest//\\//}"
  else
    echo "$p"
  fi
}

# Override paths with resolved versions
for svc in "${SERVICE_ORDER[@]}"; do
  SERVICE_FOLDERS["$svc"]="$(resolve_path "${SERVICE_FOLDERS[$svc]}")"
done

# ── Verify kubeconform is available ──────────────────────────────────────────
if ! command -v kubeconform &>/dev/null; then
  echo "ERROR: kubeconform not found in PATH." >&2
  echo "Install from: https://github.com/yannh/kubeconform/releases" >&2
  exit 1
fi

# ── Validate each service folder ─────────────────────────────────────────────
for svc in "${SERVICE_ORDER[@]}"; do
  k8s_dir="${SERVICE_FOLDERS[$svc]}"

  step "kubeconform: ${svc} (${k8s_dir})"

  if [[ ! -d "${k8s_dir}" ]]; then
    fail "${svc}" "k8s directory not found: ${k8s_dir}"
    continue
  fi

  # Collect yaml files, excluding aws-secret-template.yaml
  mapfile -t yaml_files < <(
    find "${k8s_dir}" -maxdepth 1 -name "*.yaml" -type f \
      ! -name "${SKIP_FILE}" \
      | sort
  )

  if [[ ${#yaml_files[@]} -eq 0 ]]; then
    echo "  [SKIP] No YAML files found (excluding ${SKIP_FILE})"
    continue
  fi

  echo "  Files: $(basename -a "${yaml_files[@]}" | tr '\n' ' ')"

  if kubeconform \
      -summary \
      -strict \
      -kubernetes-version "${K8S_VERSION}" \
      -output pretty \
      "${yaml_files[@]}" 2>&1 | sed 's/^/    /'; then
    pass "${svc}"
  else
    fail "${svc}" "kubeconform reported errors"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════"
echo "  SUMMARY"
echo "══════════════════════════════════════════"
echo "  Passed : ${#SUCCESSES[@]}"
echo "  Failed : ${#FAILURES[@]}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "  Failed services:" >&2
  for f in "${FAILURES[@]}"; do
    echo "    - ${f}" >&2
  done
  echo
  exit 1
fi

echo
echo "  All manifests valid."
exit 0
