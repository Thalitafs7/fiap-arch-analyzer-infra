#!/usr/bin/env bash
# test-terraform.sh
# Runs Terraform static analysis:
#   1. terraform fmt -check -recursive  (from infra root)
#   2. terraform validate               (per module directory)
#   3. tflint --config .tflint.hcl      (per module + root)
#
# Exits non-zero if any check fails. Prints a summary at the end.
#
# Usage:
#   bash scripts/test-terraform.sh

set -euo pipefail

# ── Resolve infra root (parent of scripts/) ──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODULES=(
  "network"
  "security"
  "storage"
  "ecr"
  "messaging"
  "database"
  "eks"
  "alb"
  "k8s-config"
  "secrets"
  "observability"
  "mongodb-on-eks"
  "redis-on-eks"
)

FAILURES=()
SUCCESSES=()

# ── Helpers ───────────────────────────────────────────────────────────────────
step()       { echo; echo "==> $*"; }
pass()       { SUCCESSES+=("$1"); echo "  [PASS] $1"; }
fail()       { FAILURES+=("$1"); echo "  [FAIL] $1${2:+ — $2}" >&2; }

# ── 1. terraform fmt -check -recursive ───────────────────────────────────────
step "terraform fmt -check -recursive"
cd "${INFRA_ROOT}"
if terraform fmt -check -recursive 2>&1; then
  pass "fmt-check"
else
  fail "fmt-check" "run 'terraform fmt -recursive' to fix"
fi

# ── 2. terraform validate per module ─────────────────────────────────────────
step "terraform validate (per module)"
for mod in "${MODULES[@]}"; do
  mod_path="${INFRA_ROOT}/modules/${mod}"
  if [[ ! -d "${mod_path}" ]]; then
    fail "validate:${mod}" "directory not found: ${mod_path}"
    continue
  fi
  pushd "${mod_path}" > /dev/null
  if terraform init -backend=false -input=false -no-color > /dev/null 2>&1; then
    if terraform validate -no-color 2>&1; then
      pass "validate:${mod}"
    else
      fail "validate:${mod}"
    fi
  else
    fail "init:${mod}" "terraform init failed"
  fi
  popd > /dev/null
done

# ── 3. tflint per module + root ───────────────────────────────────────────────
step "tflint (per module + root)"
TFLINT_CONFIG="${INFRA_ROOT}/.tflint.hcl"

if ! command -v tflint &> /dev/null; then
  echo "  [SKIP] tflint not found in PATH — install from https://github.com/terraform-linters/tflint"
else
  # Root
  if tflint --config "${TFLINT_CONFIG}" --chdir "${INFRA_ROOT}" 2>&1; then
    pass "tflint:root"
  else
    fail "tflint:root"
  fi

  # Each module
  for mod in "${MODULES[@]}"; do
    mod_path="${INFRA_ROOT}/modules/${mod}"
    if [[ ! -d "${mod_path}" ]]; then
      fail "tflint:${mod}" "directory not found"
      continue
    fi
    if tflint --config "${TFLINT_CONFIG}" --chdir "${mod_path}" 2>&1; then
      pass "tflint:${mod}"
    else
      fail "tflint:${mod}"
    fi
  done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════"
echo "  SUMMARY"
echo "══════════════════════════════════════════"
echo "  Passed : ${#SUCCESSES[@]}"
echo "  Failed : ${#FAILURES[@]}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "  Failed checks:" >&2
  for f in "${FAILURES[@]}"; do
    echo "    - ${f}" >&2
  done
  echo
  exit 1
fi

echo
echo "  All checks passed."
exit 0
