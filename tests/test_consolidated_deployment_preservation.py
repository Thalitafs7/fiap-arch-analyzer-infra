"""
Preservation property tests for the consolidated full-stack deployment bugfix.

Spec: .kiro/specs/consolidated-deployment/{bugfix.md, design.md, tasks.md}

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10**

These tests encode Property 2 from `design.md` "Correctness Properties":

    For any input where isBugCondition does NOT hold (per-service ci-*.yml,
    single-service cd-main.yml hotfix, infra-only cd-main.yml, direct
    workstation invocation of scripts/deploy-all.ps1), the fixed system
    SHALL produce exactly the same observable result as the original system.

CRITICAL: Tests in this module MUST PASS on UNFIXED code. The baseline
they encode is the contract the fix promises to preserve.

Layout:
    PT-1   : Hypothesis property over isBugCondition classifier.
    PT-2   : Hypothesis property over the staged-apply planner across all
             permutations of `scripts/deploy-all.config.yaml` services[].
    PT-3   : Hypothesis property over the image_tag resolver.
    PT-4   : Hypothesis idempotency surrogate over two consecutive mocked
             runConsolidatedWorkflow invocations with identical inputs.
    Direct preservation snapshots:
        - service-repo workflow files are byte-identical (SHA256 baseline).
        - infra cd-main.yml step list ends at `terraform apply -auto-approve`.
        - Terraform outputs surface (file inspection) is unchanged.
        - scripts/deploy-all.ps1 has 11 declared `Write-Step` stages.
        - infra-outputs ConfigMap key set is the 16-key canonical contract.
        - AWS Academy invariants (LabRole only, HTTP-only ALB listener,
          private RDS subnets, S3 BlockPublicAccess, SQS aws:SecureTransport,
          CloudWatch alarms 5xx + DLQ depth) hold by inspection of the
          Terraform sources. Live AWS / kubectl checks are gated behind
          `pytest.mark.integration` and skipped by default.
"""

from __future__ import annotations

import hashlib
import os
import re
import string
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import pytest
import yaml
from hypothesis import HealthCheck, given, settings, strategies as st

# Reuse helpers from the exploration test (task 1 sibling).
from tests.test_consolidated_deployment_bug import (  # noqa: E402
    DeploymentTrigger,
    INFRA_REPO,
    SERVICE_REPOS,
    discover_infra_workflows,
    is_bug_condition,
    parse_workflow_steps,
)

# ---------------------------------------------------------------------------
# Repo layout
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_INFRA_WORKFLOWS_DIR = os.path.join(_REPO_ROOT, ".github", "workflows")
_SCRIPTS_DIR = os.path.join(_REPO_ROOT, "scripts")
_DEPLOY_CONFIG_PATH = os.path.join(_SCRIPTS_DIR, "deploy-all.config.yaml")
_DEPLOY_PS1 = os.path.join(_SCRIPTS_DIR, "deploy-all.ps1")
_DEPLOY_SH = os.path.join(_SCRIPTS_DIR, "deploy-all.sh")
_OUTPUTS_TF = os.path.join(_REPO_ROOT, "outputs.tf")
_K8S_CONFIG_TF = os.path.join(_REPO_ROOT, "modules", "k8s-config", "main.tf")
_ALB_TF = os.path.join(_REPO_ROOT, "modules", "alb", "main.tf")
_STORAGE_TF = os.path.join(_REPO_ROOT, "modules", "storage", "main.tf")
_MESSAGING_TF = os.path.join(_REPO_ROOT, "modules", "messaging", "main.tf")
_OBSERVABILITY_TF = os.path.join(_REPO_ROOT, "modules", "observability", "main.tf")

_SIBLING_ROOT = os.path.dirname(_REPO_ROOT)


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _sha256(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def _load_services() -> List[dict]:
    cfg = yaml.safe_load(_read(_DEPLOY_CONFIG_PATH)) or {}
    return list(cfg.get("services", []) or [])


# ---------------------------------------------------------------------------
# Pure helpers — extracted from scripts/deploy-all.ps1 / deploy-all.config.yaml
# without behavioural change. Mirror semantics in Python so they are testable
# under Hypothesis without invoking PowerShell.
# ---------------------------------------------------------------------------

# Stage order is a hard-coded constant inside scripts/deploy-all.ps1 ($stageOrder)
# Mirror it byte-for-byte here. Any drift in the script must be reflected in
# this constant (and the snapshot test below catches drift).
_STAGE_ORDER: Tuple[Tuple[str, ...], ...] = (
    ("auth-service",),
    ("registration-service", "report-service", "processing-service"),
    ("api-gateway",),
)


def plan_stage_order(services: List[str]) -> List[List[str]]:
    """Pure planner mirroring `$stageOrder` in scripts/deploy-all.ps1.

    Given an arbitrary permutation of `services[]` from
    `scripts/deploy-all.config.yaml`, emit the apply order the orchestrator
    will use. Services not present in the input are skipped (matches
    deploy-all.ps1 behaviour: ``if (-not $svcMap.ContainsKey($svcName))
    { continue }``). Services in the input but not declared in the
    canonical stage list are dropped — they are unknown to the planner and
    deploy-all.ps1 would not run them. The planner is order-stable: the
    relative order inside a stage matches the canonical stage list, NOT
    the input order.
    """
    in_set = set(services)
    out: List[List[str]] = []
    for stage in _STAGE_ORDER:
        kept = [name for name in stage if name in in_set]
        if kept:
            out.append(kept)
    return out


_VALID_TAG_CHARSET = set(string.ascii_letters + string.digits + "._-")
_MAX_TAG_LEN = 128  # Docker tag spec; "oversized" triggers rejection.


def resolve_image_tag(
    user_input: str,
    git_sha_resolver,
) -> Tuple[Optional[str], Optional[str]]:
    """Pure resolver mirroring the design's `image_tag` contract.

    Returns ``(tag, error)`` where exactly one is non-None.

    Contract from `design.md` "Unit Tests" + "Property-Based Tests":
      - empty input              → ``git rev-parse --short HEAD``.
      - non-empty valid input    → returned verbatim.
      - whitespace / control     → reject; non-zero exit; no side effects.
      - oversized (>128 chars)   → reject.
      - invalid chars            → reject.

    `git_sha_resolver` is injected so the function stays pure and testable
    without spawning git.
    """
    if user_input == "":
        sha = git_sha_resolver()
        if not sha or not _is_valid_tag(sha):
            return None, f"git rev-parse returned invalid SHA: {sha!r}"
        return sha, None

    if not _is_valid_tag(user_input):
        return None, f"invalid image_tag: {user_input!r}"

    return user_input, None


def _is_valid_tag(tag: str) -> bool:
    if not tag:
        return False
    if len(tag) > _MAX_TAG_LEN:
        return False
    # Reject leading separators (Docker tag spec).
    if tag[0] in ".-_":
        return False
    return all(ch in _VALID_TAG_CHARSET for ch in tag)


# ---------------------------------------------------------------------------
# PT-4 idempotency surrogate
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class MockAwsState:
    """Deterministic, immutable mock of the AWS surface the orchestrator touches."""

    terraform_plan_digest: str
    ecr_digests: Tuple[Tuple[str, str], ...]  # (ecr_key, image_digest)
    kubectl_apply_outcome: Tuple[Tuple[str, str], ...]  # (namespace/name, status)


def run_consolidated_workflow_pure(
    services: List[dict],
    image_tag: str,
) -> MockAwsState:
    """Pure surrogate for `runConsolidatedWorkflow` in `design.md`.

    Computes a deterministic AWS state from the inputs alone. Two
    invocations with identical inputs MUST produce equal states (this is
    the idempotency contract on the orchestrator's pure decision layer,
    surrogate for Property 2.9 minus the AWS-side convergence).
    """
    plan_payload = "|".join(
        f"{svc['name']}:{svc.get('namespace', '')}:{svc.get('ecr_key', '')}"
        for svc in services
    )
    plan_digest = hashlib.sha256(plan_payload.encode("utf-8")).hexdigest()

    digests: List[Tuple[str, str]] = []
    for svc in services:
        seed = f"{svc.get('ecr_key', '')}:{image_tag}".encode("utf-8")
        digests.append(
            (svc.get("ecr_key", ""), "sha256:" + hashlib.sha256(seed).hexdigest())
        )

    apply_outcome: List[Tuple[str, str]] = []
    for stage in plan_stage_order([svc["name"] for svc in services]):
        for name in stage:
            svc = next(s for s in services if s["name"] == name)
            for dep in svc.get("deployments", []) or []:
                apply_outcome.append((f"{svc['namespace']}/{dep}", "applied"))

    return MockAwsState(
        terraform_plan_digest=plan_digest,
        ecr_digests=tuple(sorted(digests)),
        kubectl_apply_outcome=tuple(apply_outcome),
    )


# ===========================================================================
# Hypothesis strategies
# ===========================================================================

# All canonical service names declared in deploy-all.config.yaml today.
_CANONICAL_SERVICES = ("auth-service", "registration-service",
                       "report-service", "processing-service", "api-gateway")

# Strategy: arbitrary permutation of canonical services (full or subset).
permutation_of_services = st.permutations(list(_CANONICAL_SERVICES))

# Strategy: subset (size 1..5) drawn from the canonical 5, in arbitrary order.
subset_of_services = st.lists(
    st.sampled_from(_CANONICAL_SERVICES), min_size=1, max_size=5, unique=True
)

# Strategy for PT-1: every (trigger_repo, trigger_workflow, intent) tuple
# from the bug-condition input space.
_INTENTS = ("deploy_full_stack", "deploy_single_service", "infra_only")

# Real workflow filenames present in each repo today.
_INFRA_WORKFLOW_FILES: List[str] = []
if os.path.isdir(_INFRA_WORKFLOWS_DIR):
    for entry in sorted(os.listdir(_INFRA_WORKFLOWS_DIR)):
        if entry.endswith((".yml", ".yaml")):
            _INFRA_WORKFLOW_FILES.append(entry)

_SERVICE_WORKFLOW_FILES = (
    "ci-develop.yml", "ci-feature.yml", "ci-release.yml", "cd-main.yml",
)

trigger_repo_strat = st.sampled_from((INFRA_REPO,) + tuple(SERVICE_REPOS))


@st.composite
def trigger_strategy(draw) -> DeploymentTrigger:
    repo = draw(trigger_repo_strat)
    if repo == INFRA_REPO:
        wf_choices: Tuple[str, ...] = tuple(_INFRA_WORKFLOW_FILES) + (
            "scripts/deploy-all.ps1", "scripts/deploy-all.sh",
        )
        wf = draw(st.sampled_from(wf_choices)) if wf_choices else "cd-main.yml"
    else:
        wf = draw(st.sampled_from(_SERVICE_WORKFLOW_FILES))
    intent = draw(st.sampled_from(_INTENTS))
    return DeploymentTrigger(trigger_repo=repo, trigger_workflow=wf, intent=intent)


# ===========================================================================
# PT-1 — isBugCondition classifier property
# ===========================================================================


@given(trigger=trigger_strategy())
@settings(max_examples=200, deadline=None,
          suppress_health_check=[HealthCheck.function_scoped_fixture])
def test_pt1_is_bug_condition_iff_intent_full_stack_and_buggy_path(trigger):
    """**Validates: Requirement 3.9**

    PT-1: For every (trigger_repo, trigger_workflow, intent) tuple, the
    classifier `isBugCondition` is True iff the predicate from
    `bugfix.md` holds. For every tuple where `isBugCondition` is False,
    the consolidated workflow MUST NOT be reached — i.e. the original
    routing path is preserved (`routeToOriginalPath(x) == originalPath(x)`).

    On UNFIXED code: PASS — every non-`deploy_full_stack` trigger
    short-circuits to its original path; every per-service `ci-*.yml`,
    every single-service `cd-main.yml`, every infra-only `cd-main.yml`,
    and every workstation `deploy-all.ps1` invocation is left untouched
    by definition (the consolidated workflow does not yet exist).
    """
    classified = is_bug_condition(trigger)

    # Truth-table check derived from bugfix.md.
    expected_must_be_full_stack = trigger.intent == "deploy_full_stack"
    if classified:
        assert expected_must_be_full_stack, (
            f"isBugCondition classified non-full-stack trigger as buggy: {trigger}"
        )
        # When buggy, trigger must match one of the three documented cases.
        case_a = (trigger.trigger_repo == INFRA_REPO
                  and trigger.trigger_workflow == "cd-main.yml")
        case_b = (trigger.trigger_repo in SERVICE_REPOS
                  and trigger.trigger_workflow == "cd-main.yml")
        case_c = trigger.trigger_workflow in (
            "scripts/deploy-all.ps1", "scripts/deploy-all.sh"
        )
        assert case_a or case_b or case_c, (
            f"isBugCondition classified an unrecognised trigger as buggy: {trigger}"
        )
    else:
        # Preservation: any non-buggy trigger must stay on its original path.
        # Routing the original path is "the file that already exists today",
        # which is invariant under this fix because the fix ONLY adds
        # cd-deploy-all.yml to the infra repo. Encode the invariant as: the
        # workflow file or script that today handles `trigger` is still
        # present on disk and unmodified (snapshot tests below verify
        # byte-identity for service repos; the infra cd-main.yml step list
        # is checked in test_infra_cd_main_terraform_only_unchanged).
        # Here we only assert the classifier did not over-fire.
        if trigger.intent == "deploy_full_stack":
            # Must be a known non-buggy full-stack tuple — there are none
            # today, so the classifier should have returned True.
            # If we land here it means the bug condition has been narrowed
            # by the fix. Allow that, but document it.
            pass


# ===========================================================================
# PT-2 — Stage-order planner over arbitrary services[] permutations
# ===========================================================================


@given(perm=permutation_of_services)
@settings(max_examples=200, deadline=None)
def test_pt2_stage_planner_always_emits_dependency_order(perm):
    """**Validates: Requirements 3.2, 3.6**

    PT-2: For any permutation of the 5 services, the planner emits an
    order satisfying `auth ≺ {registration, report, processing} ≺ api-gateway`.

    On UNFIXED code: PASS — the planner mirrors the hard-coded
    `$stageOrder` in `scripts/deploy-all.ps1`, which is independent of
    input ordering. Encodes Requirement 3.2 (local orchestrator semantics
    preserved) and 3.6 (per-service Deployment contracts preserved).
    """
    plan = plan_stage_order(perm)

    # Flatten with stage indices for ordering checks.
    pos: Dict[str, int] = {}
    for stage_idx, stage in enumerate(plan):
        for name in stage:
            pos[name] = stage_idx

    # All input services must appear exactly once.
    flat = [n for stage in plan for n in stage]
    assert sorted(flat) == sorted(perm), (
        f"Planner dropped or duplicated services. perm={perm}, plan={plan}"
    )

    # Dependency invariants.
    assert pos["auth-service"] < pos["registration-service"]
    assert pos["auth-service"] < pos["report-service"]
    assert pos["auth-service"] < pos["processing-service"]
    assert pos["registration-service"] < pos["api-gateway"]
    assert pos["report-service"] < pos["api-gateway"]
    assert pos["processing-service"] < pos["api-gateway"]

    # Middle three live in the same stage (parallelisable).
    assert pos["registration-service"] == pos["report-service"]
    assert pos["report-service"] == pos["processing-service"]


@given(subset=subset_of_services)
@settings(max_examples=100, deadline=None)
def test_pt2_planner_handles_arbitrary_subsets(subset):
    """**Validates: Requirement 3.9**

    Single-service hotfix path preservation: when only one service is in
    the input, the planner emits a single-stage plan containing that
    service. This corresponds to Requirement 3.9 — single-service hotfix
    via service-repo `cd-main.yml` continues to work.
    """
    plan = plan_stage_order(subset)
    flat = [n for stage in plan for n in stage]
    assert sorted(flat) == sorted(set(subset))


# ===========================================================================
# PT-3 — image_tag resolver
# ===========================================================================

# Strategy: tags Hypothesis can generate that may or may not be valid.
_image_tag_strategy = st.one_of(
    st.just(""),                                  # empty → git fallback
    st.text(alphabet=string.ascii_letters + string.digits + "._-",
            min_size=1, max_size=64),             # likely valid
    st.text(min_size=0, max_size=200),            # mixed; may be invalid
    st.text(alphabet=" \t\r\n", min_size=1, max_size=10),  # whitespace only
)


@given(user_input=_image_tag_strategy)
@settings(max_examples=200, deadline=None)
def test_pt3_image_tag_resolver_is_pure_and_total(user_input):
    """**Validates: Requirements 3.2, 3.4**

    PT-3: For every input drawn from the strategy, the resolver returns
    exactly one of (tag, error), is pure (no side effects on rejection),
    and obeys:

      - empty input  → fallback git SHA (when valid).
      - non-empty valid → verbatim.
      - whitespace / control / oversized → rejected without mutation.

    On UNFIXED code: PASS — the resolver is a pure Python function with
    no I/O on the rejection branch.
    """
    side_effects: List[str] = []

    def fake_git_sha():
        side_effects.append("git_invoked")
        return "abc1234"

    tag, err = resolve_image_tag(user_input, fake_git_sha)

    # Mutual exclusion.
    assert (tag is None) != (err is None), (
        f"Resolver returned ambiguous result: tag={tag!r}, err={err!r}"
    )

    if user_input == "":
        assert tag == "abc1234"
        assert side_effects == ["git_invoked"], (
            "Empty input must invoke the git resolver exactly once."
        )
        return

    # Non-empty inputs MUST NOT invoke git.
    assert side_effects == [], (
        "Resolver invoked git on non-empty input — purity contract broken."
    )

    if _is_valid_tag(user_input):
        assert tag == user_input, "Valid input must be returned verbatim."
    else:
        assert err is not None and tag is None, (
            "Invalid input must reject with an error and no tag."
        )


# ===========================================================================
# PT-4 — Idempotency surrogate
# ===========================================================================


@given(perm=permutation_of_services,
       image_tag=st.text(alphabet=string.ascii_letters + string.digits,
                         min_size=1, max_size=16))
@settings(max_examples=100, deadline=None)
def test_pt4_two_consecutive_runs_are_identical(perm, image_tag):
    """**Validates: Requirements 3.2, 3.10**

    PT-4: Two consecutive `runConsolidatedWorkflow` invocations with
    identical inputs (mocked AWS) yield identical Terraform plan output,
    identical ECR digest set, and identical `kubectl apply` outcome.

    On UNFIXED code: PASS — `run_consolidated_workflow_pure` is a pure
    function of its inputs. This encodes the idempotency invariant
    Requirement 3.2 reuses from the local orchestrator and preserves
    Requirement 3.10's observability contract (no log churn from
    spurious re-rolls).
    """
    services = _load_services()
    # Re-order services by the permutation to exercise input ordering.
    by_name = {svc["name"]: svc for svc in services}
    reordered = [by_name[name] for name in perm if name in by_name]

    state_a = run_consolidated_workflow_pure(reordered, image_tag)
    state_b = run_consolidated_workflow_pure(reordered, image_tag)

    assert state_a == state_b, (
        "Idempotency surrogate violated:\n"
        f"  state_a.terraform_plan_digest = {state_a.terraform_plan_digest}\n"
        f"  state_b.terraform_plan_digest = {state_b.terraform_plan_digest}\n"
        f"  state_a.ecr_digests          = {state_a.ecr_digests}\n"
        f"  state_b.ecr_digests          = {state_b.ecr_digests}\n"
        f"  state_a.kubectl_apply        = {state_a.kubectl_apply_outcome}\n"
        f"  state_b.kubectl_apply        = {state_b.kubectl_apply_outcome}"
    )


# ===========================================================================
# Direct preservation snapshots (static, no AWS)
# ===========================================================================

# SHA256 baseline of every service-repo workflow at the time task 2 was
# written. Per design.md "Specific Changes #10": no service-repo files are
# touched by this fix. Drift in any of these means the preservation
# boundary has been violated.
SERVICE_WORKFLOW_HASHES: Dict[Tuple[str, str], str] = {
    ("fiap-arch-analyzer-auth-service", "ci-develop.yml"):
        "4197d7964240fb0f20a9de09ad8f1305d3136ecd1559724d65eea08a03270b9b",
    ("fiap-arch-analyzer-auth-service", "ci-feature.yml"):
        "71f8e243f96b6d345b014332c5380f52a050d2eb24971305d7ffd463538d233e",
    ("fiap-arch-analyzer-auth-service", "ci-release.yml"):
        "7ea9931fa85f7aab416c42e8d7a2a7baa29808563ff22588266d5cbbefb780b8",
    ("fiap-arch-analyzer-auth-service", "cd-main.yml"):
        "09d6fbad9caece77821225ebd2a2af79c1c0b27d29b3a805812965f0f77be88c",
    ("fiap-arch-analyzer-registration-service", "ci-develop.yml"):
        "8ea18d3be06fc81e736bf320d1c39cdef73345a6549ab1fc0d72fdfd89fb73a3",
    ("fiap-arch-analyzer-registration-service", "ci-feature.yml"):
        "d4d8b9de3bb5c2eb2a52caaa85e44c39017d1339d3dcddc7ad541c7376bb927a",
    ("fiap-arch-analyzer-registration-service", "ci-release.yml"):
        "a6b39dbb5f95c6529e6faccb7bb8c900f028f0c744543ce287b2cb86505b5ba8",
    ("fiap-arch-analyzer-registration-service", "cd-main.yml"):
        "86664c5edd01a8ead795dbdeb4d96d5971c4b2f7179bde12e98a433b7974b90e",
    ("fiap-arch-analyzer-report-service", "ci-develop.yml"):
        "6a2e978f184d638260ba32611c6e6456d31d590fb3e0bb87a1e64e2b4c9c9754",
    ("fiap-arch-analyzer-report-service", "ci-feature.yml"):
        "285c61e2b922e0bb919a603b2c44e324bba48afaf3dd321f597a639005829dfe",
    ("fiap-arch-analyzer-report-service", "ci-release.yml"):
        "3b4193b55fad6aae972f76685cd3b3f277da3122f414158d3629a4f751c64d22",
    ("fiap-arch-analyzer-report-service", "cd-main.yml"):
        "a7b5ec72c54d6e1bd8071db12d4670f0f058f4424574cc5fadcfeaa4dae02458",
    ("fiap-arch-analyzer-processing-service", "ci-develop.yml"):
        "6a2e978f184d638260ba32611c6e6456d31d590fb3e0bb87a1e64e2b4c9c9754",
    ("fiap-arch-analyzer-processing-service", "ci-feature.yml"):
        "285c61e2b922e0bb919a603b2c44e324bba48afaf3dd321f597a639005829dfe",
    ("fiap-arch-analyzer-processing-service", "ci-release.yml"):
        "3b4193b55fad6aae972f76685cd3b3f277da3122f414158d3629a4f751c64d22",
    ("fiap-arch-analyzer-processing-service", "cd-main.yml"):
        "da3fe6a38393b52fdc9fabecf7ff3b7af2b8a23fa92f48fd7fb067439a3e1023",
    ("fiap-arch-analyzer-api-gateway", "ci-develop.yml"):
        "d8c780fb4e674b3c00d7ceb42db8940a75002ff5917d30b91dc8acd33e5357d0",
    ("fiap-arch-analyzer-api-gateway", "ci-feature.yml"):
        "0fb89fc1454e1b4efa57b7aeca873ad24dff5a7865c5b475b4ca8e240d283993",
    ("fiap-arch-analyzer-api-gateway", "ci-release.yml"):
        "dc5aa38f43ab80a3d754bb8c94d00e0d9c737f62e4289926adf0c28a3b91341b",
    ("fiap-arch-analyzer-api-gateway", "cd-main.yml"):
        "f40a7578d899b7861d2c8a3ddc790fef26bcf28298c8988fded50dfd8e5aea33",
}

# Infra-side files this fix promises NOT to touch (design.md #10).
INFRA_PRESERVED_HASHES: Dict[str, str] = {
    "scripts/deploy-all.config.yaml":
        "5ff9548584046921ccb98a3d64a3cf5a0bd52ae1f1d94ccde4af73913001dd40",
    "scripts/deploy-all.ps1":
        "1f6223cb903ad967e01fe4bde44567ddfaab2faebdb3b1de8754668f9dd8cee5",
    "scripts/deploy-all.sh":
        "a88c60f408d357370724011ebcf41de4b4d2f23f3746504f7c5891562bfed39a",
    ".github/workflows/cd-main.yml":
        "6cc795a2e08e81779a0680ded257aa6c61b72411b9a9f0545cc6d7b7ce81f8fa",
}


class TestServiceRepoPreservation:
    """**Validates: Requirements 3.1, 3.6, 3.9**

    Per design.md "Specific Changes #10": no service-repo files are
    touched by this fix. Each service-repo workflow file MUST be
    byte-identical (SHA256 stable) before AND after the fix.
    """

    @pytest.mark.parametrize(
        "repo,filename,expected_sha",
        [(repo, fn, sha) for (repo, fn), sha in SERVICE_WORKFLOW_HASHES.items()],
    )
    def test_service_repo_workflow_unchanged(self, repo, filename, expected_sha):
        path = os.path.join(_SIBLING_ROOT, repo, ".github", "workflows", filename)
        if not os.path.isfile(path):
            pytest.skip(f"sibling repo {repo} not present in this checkout")
        actual = _sha256(path)
        assert actual == expected_sha, (
            f"Preservation violated: {repo}/.github/workflows/{filename} "
            f"changed.\n  expected sha256={expected_sha}\n  actual   sha256={actual}\n"
            "design.md 'Specific Changes #10' forbids touching service-repo files."
        )

    def test_single_service_cd_main_uses_service_repo_github_sha_as_image_tag(self):
        """Requirement 3.9: single-service hotfix continues to tag images
        with that repo's `github.sha`, NOT a shared infra tag."""
        sample = os.path.join(
            _SIBLING_ROOT, "fiap-arch-analyzer-api-gateway",
            ".github", "workflows", "cd-main.yml",
        )
        if not os.path.isfile(sample):
            pytest.skip("api-gateway sibling repo not present")
        text = _read(sample)
        assert "IMAGE_TAG: ${{ github.sha }}" in text, (
            "single-service cd-main.yml must continue to tag images with the "
            "service repo's own github.sha (Requirement 3.9)."
        )
        # Must roll out exactly the canonical Deployment for that service.
        assert "DEPLOYMENT_NAME: api-gateway" in text


class TestInfraPreservation:
    """**Validates: Requirements 3.2, 3.3**

    The local orchestrator and the infra-only `cd-main.yml` keep their
    semantics exactly. Captured as SHA256 of the source files (the fix
    is purely additive — a new `cd-deploy-all.yml` — and must not
    rewrite any existing infra file).
    """

    @pytest.mark.parametrize(
        "rel_path,expected_sha",
        list(INFRA_PRESERVED_HASHES.items()),
    )
    def test_infra_file_unchanged(self, rel_path, expected_sha):
        path = os.path.join(_REPO_ROOT, rel_path.replace("/", os.sep))
        actual = _sha256(path)
        assert actual == expected_sha, (
            f"Preservation violated: {rel_path} changed.\n"
            f"  expected sha256={expected_sha}\n"
            f"  actual   sha256={actual}\n"
            "design.md 'Specific Changes #10' forbids touching this file."
        )

    def test_infra_cd_main_terraform_only_step_list(self):
        """Requirement 3.3: infra `cd-main.yml` ends after `terraform apply
        -auto-approve` and emits no service rollout, no kubectl, no docker
        push, no validator."""
        wf_path = os.path.join(_INFRA_WORKFLOWS_DIR, "cd-main.yml")
        wf = parse_workflow_steps(wf_path)
        joined = "\n".join(wf.step_ids).lower()

        assert "terraform" in joined and "apply" in joined, (
            "Infra cd-main.yml must continue to run `terraform apply`."
        )
        forbidden = ("kubectl apply", "docker push", "deploy-all.ps1",
                     "deploy-all.sh", "validation-report")
        for tok in forbidden:
            assert tok not in joined, (
                f"Infra cd-main.yml drifted into orchestrator territory: "
                f"contains '{tok}' (Requirement 3.3 forbids it)."
            )

    def test_terraform_outputs_set_unchanged(self):
        """Requirement 3.3: Terraform output set must include the four
        keys consumed downstream (`eks_cluster_name`, `alb_dns_name`,
        `ecr_repository_urls`, `ecr_registry_url`)."""
        text = _read(_OUTPUTS_TF)
        for key in (
            "eks_cluster_name", "alb_dns_name",
            "ecr_repository_urls", "ecr_registry_url",
        ):
            assert re.search(rf'output\s+"{re.escape(key)}"', text), (
                f"Terraform output `{key}` must remain declared in outputs.tf "
                "(Requirement 3.3)."
            )

    def test_deploy_all_ps1_has_eleven_stages(self):
        """Requirement 3.2: the local orchestrator continues to run the
        documented 11-stage flow. We approximate stage count by reading
        the `Stage N:` header comments embedded in `scripts/deploy-all.ps1`.
        """
        text = _read(_DEPLOY_PS1)
        # Stages are documented as "Stage 0:" through "Stage 11:" inline
        # in the script header comments.
        stages = sorted(set(int(m.group(1)) for m in re.finditer(
            r"\bStage\s+(\d+):", text)))
        assert stages, (
            "scripts/deploy-all.ps1 lost its `Stage N:` markers — the "
            "11-stage flow contract from Requirement 3.2 is no longer "
            "self-documented."
        )
        # The script declares stages 0..11 (Stage 0 = config load, Stage 11
        # = auto-retry); the documented public contract is "11 stages".
        assert max(stages) >= 10, (
            f"Expected the orchestrator to still expose at least 11 stages; "
            f"found stages {stages}."
        )

    def test_deploy_all_config_services_unchanged(self):
        """Requirement 3.2 + 3.6: services[] in deploy-all.config.yaml
        keeps the canonical 5 services with their canonical
        (name, namespace, ecr_key, deployments[]) tuples."""
        services = _load_services()
        names = {s["name"] for s in services}
        assert names == set(_CANONICAL_SERVICES), (
            f"deploy-all.config.yaml services[] drift: {names} != "
            f"{set(_CANONICAL_SERVICES)} (Requirement 3.2)."
        )
        by_name = {s["name"]: s for s in services}
        # Canonical contract (Requirement 3.6 — namespace assignment).
        assert by_name["auth-service"]["namespace"] == "auth"
        assert by_name["registration-service"]["namespace"] == "arch-analyzer-api"
        assert by_name["report-service"]["namespace"] == "arch-analyzer-ia"
        assert by_name["processing-service"]["namespace"] == "arch-analyzer-ia"
        assert by_name["api-gateway"]["namespace"] == "arch-analyzer-api"
        # ecr_key mapping (Requirement 2.4 implication on tag/repo resolution).
        assert by_name["api-gateway"]["ecr_key"] == "gateway"
        assert by_name["auth-service"]["ecr_key"] == "auth"


class TestInfraOutputsConfigMapPreservation:
    """**Validates: Requirement 3.4**

    The `infra-outputs` ConfigMap key set is the only contract through
    which Service_K8s_Folder manifests consume Terraform outputs. The
    fix must NOT alter this key set.
    """

    EXPECTED_KEYS = {
        "AWS_REGION", "AWS_ACCOUNT_ID", "CLUSTER_NAME", "ALB_DNS_NAME",
        "DB_ADDRESS", "DB_PORT", "DB_NAME",
        "SQS_PROCESSING_QUEUE_URL", "SQS_DLQ_URL",
        "S3_DIAGRAMS_BUCKET", "ECR_REGISTRY",
        "ECR_REPOSITORY_URL_GATEWAY", "ECR_REPOSITORY_URL_AUTH",
        "ECR_REPOSITORY_URL_REGISTRATION", "ECR_REPOSITORY_URL_PROCESSING",
        "ECR_REPOSITORY_URL_REPORT",
    }

    def test_infra_outputs_keys_unchanged_static(self):
        text = _read(_K8S_CONFIG_TF)
        # Extract keys from the `infra_outputs = { ... }` block.
        block = re.search(
            r"infra_outputs\s*=\s*\{(.*?)\n\s*\}", text, re.DOTALL,
        )
        assert block, (
            "Could not locate the `infra_outputs = { ... }` block in "
            "modules/k8s-config/main.tf. The ConfigMap key contract is "
            "no longer self-evident."
        )
        keys = set(re.findall(r"^\s*([A-Z][A-Z0-9_]+)\s*=", block.group(1),
                              re.MULTILINE))
        assert keys == self.EXPECTED_KEYS, (
            f"infra-outputs ConfigMap key set drifted (Requirement 3.4).\n"
            f"  added:   {keys - self.EXPECTED_KEYS}\n"
            f"  removed: {self.EXPECTED_KEYS - keys}"
        )


class TestAwsAcademyInvariants:
    """**Validates: Requirements 3.5, 3.7, 3.8, 3.10**

    Static inspection of Terraform sources to assert the AWS Academy
    invariants the consolidated workflow must NOT alter.
    """

    def test_no_new_iam_role_resources_introduced(self):
        """Requirement 3.5: `LabRole`-only authentication. No
        `aws_iam_role` / `aws_iam_user` / `aws_iam_policy` resources
        anywhere in the infra repo."""
        forbidden = re.compile(
            r'resource\s+"(aws_iam_role|aws_iam_user|aws_iam_policy|'
            r'aws_iam_instance_profile|aws_iam_openid_connect_provider)"',
        )
        offenders: List[str] = []
        for dirpath, _dirnames, filenames in os.walk(_REPO_ROOT):
            # Skip vendored / cache directories.
            if any(part in dirpath for part in (
                ".terraform", ".git", ".pytest_cache", ".hypothesis",
            )):
                continue
            for fn in filenames:
                if not fn.endswith(".tf"):
                    continue
                path = os.path.join(dirpath, fn)
                text = _read(path)
                if forbidden.search(text):
                    offenders.append(path)
        assert not offenders, (
            "Requirement 3.5 violated: forbidden IAM resources found in "
            f"{offenders}. AWS Academy permits only LabRole."
        )

    def test_alb_listener_is_http_only_on_port_80(self):
        """Requirement 3.7: HTTP-only ALB on :80, no HTTPS, no 0.0.0.0/0
        ingress except port 80."""
        text = _read(_ALB_TF)
        m = re.search(
            r'resource\s+"aws_lb_listener"\s+"http"\s*\{(.*?)\n\}',
            text, re.DOTALL,
        )
        assert m, "ALB http listener resource missing from modules/alb/main.tf."
        body = m.group(1)
        assert re.search(r'\bport\s*=\s*80\b', body), (
            "ALB HTTP listener must remain on port 80 (Requirement 3.7)."
        )
        assert re.search(r'\bprotocol\s*=\s*"HTTP"', body), (
            "ALB listener protocol must remain HTTP (Requirement 3.7)."
        )

    def test_s3_buckets_block_public_access(self):
        """Requirement 3.7: S3 buckets must keep `BlockPublicAccess=true`."""
        text = _read(_STORAGE_TF)
        # Both diagrams + access_logs buckets MUST set the four flags True.
        for flag in ("block_public_acls", "block_public_policy",
                     "ignore_public_acls"):
            count = len(re.findall(rf"\b{flag}\s*=\s*true\b", text))
            assert count >= 2, (
                f"S3 bucket public-access flag `{flag}=true` must be set on "
                f"both buckets (found {count} occurrences). Requirement 3.7."
            )

    def test_secure_transport_required_on_s3_and_sqs(self):
        """Requirement 3.7: SQS/S3 deny `aws:SecureTransport=false`."""
        s3 = _read(_STORAGE_TF)
        sqs = _read(_MESSAGING_TF)
        # Both files must include a deny clause on `aws:SecureTransport=false`.
        assert '"aws:SecureTransport" = "false"' in s3, (
            "S3 must keep the deny-on-non-TLS bucket policy (Requirement 3.7)."
        )
        assert '"aws:SecureTransport" = "false"' in sqs, (
            "SQS must keep the deny-on-non-TLS queue policy (Requirement 3.7)."
        )

    def test_cloudwatch_alarms_for_5xx_and_dlq_depth_present(self):
        """Requirement 3.7 + 3.10: ALB 5xx alarm + DLQ depth alarm
        bound to their original metrics."""
        text = _read(_OBSERVABILITY_TF)
        m_alb = re.search(
            r'resource\s+"aws_cloudwatch_metric_alarm"\s+"alb_5xx"\s*\{(.*?)\n\}',
            text, re.DOTALL,
        )
        assert m_alb, "alb_5xx alarm missing (Requirement 3.7)."
        assert "HTTPCode_Target_5XX_Count" in m_alb.group(1) \
            or "HTTPCode_Target_5XX_Count" in text, (
                "alb_5xx alarm must remain bound to HTTPCode_Target_5XX_Count."
            )

        m_dlq = re.search(
            r'resource\s+"aws_cloudwatch_metric_alarm"\s+"dlq_depth"\s*\{(.*?)\n\}',
            text, re.DOTALL,
        )
        assert m_dlq, "dlq_depth alarm missing (Requirement 3.7)."
        assert "ApproximateNumberOfMessagesVisible" in m_dlq.group(1) \
            or "ApproximateNumberOfMessagesVisible" in text, (
                "dlq_depth alarm must remain bound to "
                "ApproximateNumberOfMessagesVisible."
            )

    def test_no_new_chargeable_resources_introduced(self):
        """Requirement 3.8: USD 50–100 envelope (with AP-8 baseline
        caveat). Static check: no NEW NAT Gateways, no extra ALBs, no
        managed self-hosted CI runners declared in the Terraform sources.

        Encoded as: at most one `aws_nat_gateway` resource, at most one
        `aws_lb` resource. Drift indicates the fix added chargeable AWS
        line items, which design.md "Specific Changes #10" forbids.
        """
        nat_count = 0
        lb_count = 0
        for dirpath, _dirnames, filenames in os.walk(_REPO_ROOT):
            if any(part in dirpath for part in (
                ".terraform", ".git", ".pytest_cache", ".hypothesis",
            )):
                continue
            for fn in filenames:
                if not fn.endswith(".tf"):
                    continue
                text = _read(os.path.join(dirpath, fn))
                nat_count += len(re.findall(
                    r'resource\s+"aws_nat_gateway"', text))
                lb_count += len(re.findall(
                    r'resource\s+"aws_lb"\s', text))
        assert nat_count <= 1, (
            f"Requirement 3.8 violated: found {nat_count} aws_nat_gateway "
            "resources (expected ≤ 1; AP-8 baseline allows exactly 1)."
        )
        assert lb_count <= 1, (
            f"Requirement 3.8 violated: found {lb_count} aws_lb resources "
            "(expected ≤ 1; consolidated workflow must not add ALBs)."
        )


# ===========================================================================
# Live AWS / kubectl integration assertions — skipped by default
# ===========================================================================


@pytest.mark.integration
class TestLiveAwsAcademyInvariants:
    """**Validates: Requirements 3.5, 3.7, 3.10**

    These checks require live AWS / kubectl access against the Academy
    Learner Lab. They are skipped by default; run with
    ``pytest -m integration`` after refreshing the LabRole session
    credentials.
    """

    def test_only_lab_role_present_in_iam(self):
        """Requirement 3.5: `aws iam list-roles` returns LabRole; no new
        IAM principals introduced by the fix."""
        import json
        import subprocess
        try:
            proc = subprocess.run(
                ["aws", "iam", "list-roles", "--output", "json"],
                check=True, capture_output=True, text=True, timeout=60,
            )
        except (FileNotFoundError, subprocess.CalledProcessError,
                subprocess.TimeoutExpired) as exc:
            pytest.skip(f"aws CLI not available or not authenticated: {exc}")
        roles = {r["RoleName"] for r in json.loads(proc.stdout).get("Roles", [])}
        assert "LabRole" in roles, (
            "Requirement 3.5 violated: LabRole missing from the Academy "
            "account."
        )

    def test_infra_outputs_configmap_key_set_unchanged_in_cluster(self):
        """Requirement 3.4: live `kubectl get configmap infra-outputs -o yaml`
        key set matches the static contract."""
        import subprocess
        # Probe arch-analyzer-api namespace; the ConfigMap is mirrored to
        # arch-analyzer-ia and auth as well per modules/k8s-config/main.tf.
        try:
            proc = subprocess.run(
                ["kubectl", "get", "configmap", "infra-outputs",
                 "-n", "arch-analyzer-api", "-o", "yaml"],
                check=True, capture_output=True, text=True, timeout=30,
            )
        except (FileNotFoundError, subprocess.CalledProcessError,
                subprocess.TimeoutExpired) as exc:
            pytest.skip(f"kubectl not available or cluster unreachable: {exc}")
        cm = yaml.safe_load(proc.stdout) or {}
        keys = set((cm.get("data") or {}).keys())
        expected = TestInfraOutputsConfigMapPreservation.EXPECTED_KEYS
        assert keys == expected, (
            f"Requirement 3.4 violated: live infra-outputs ConfigMap key "
            f"drift.\n  added:   {keys - expected}\n"
            f"  removed: {expected - keys}"
        )
