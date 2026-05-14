"""
Bug condition exploration test for the consolidated full-stack deployment bug.

Spec: .kiro/specs/consolidated-deployment/{bugfix.md, design.md, tasks.md}

**Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8**

CRITICAL: This test MUST FAIL on UNFIXED code. The failure is the evidence
that the bug exists. Do NOT attempt to fix the test or the code when it
fails. The same test will validate the fix when it passes after the
consolidated workflow (`.github/workflows/cd-deploy-all.yml`) is added.

Bug Condition (from `bugfix.md` "Bug Condition (Methodology)"):

    isBugCondition(input) iff input.intent = "deploy_full_stack" AND any of
      A) input.trigger_repo = "fiap-arch-analyzer-infra"
         AND input.trigger_workflow = "cd-main.yml"
         AND NOT orchestrates_all_services(input)
      B) input.trigger_repo IN service_repos
         AND input.trigger_workflow = "cd-main.yml"
         AND deploys_only_one_service(input)
      C) input.trigger_workflow = "scripts/deploy-all.ps1"
         AND NOT invoked_from_ci(input)

Property 1 (from `design.md` "Correctness Properties"):

    For every input where isBugCondition holds, the fixed system SHALL
    expose at least one infra-owned workflow file `w` in
    `fiap-arch-analyzer-infra/.github/workflows/` such that:
      - `w.on` includes `workflow_dispatch`
      - `orchestrates_all_services(w)` is true (invokes
        `scripts/deploy-all.ps1` or `deploy-all.sh`, passes a shared
        `IMAGE_TAG`, and uploads `./artifacts/validation-report-*.{json,md}`)
      - `w` invokes `aws sts get-caller-identity` before any mutating step

Counterexamples documented (UNFIXED code):

    Counterexample 1 — infra `cd-main.yml`:
      `terraform_applied=true` but `images_pushed_count=0`,
      `validator_report_written=false`. The workflow stops after
      `terraform apply -auto-approve` and never invokes
      `scripts/deploy-all.ps1`.

    Counterexample 2 — service-repo `cd-main.yml` (api-gateway sample):
      `images_pushed_count=1`, `shared_image_tag_used=false` (image tagged
      with that service repo's `github.sha`), `stage_order_respected=false`.
      One service rolled out in isolation.

    Counterexample 3 — six manual triggers (1 infra + 5 service):
      arbitrary completion order, five distinct image tags from five
      different commits, zero consolidated
      `validation-report-<timestamp>.{json,md}`.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import pytest
import yaml
from hypothesis import assume, given, settings, strategies as st

# ---------------------------------------------------------------------------
# Repo layout
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_WORKFLOWS_DIR = os.path.join(_REPO_ROOT, ".github", "workflows")
_DEPLOY_CONFIG_PATH = os.path.join(_REPO_ROOT, "scripts", "deploy-all.config.yaml")
_DEPLOY_PS1 = os.path.join(_REPO_ROOT, "scripts", "deploy-all.ps1")
_DEPLOY_SH = os.path.join(_REPO_ROOT, "scripts", "deploy-all.sh")

INFRA_REPO = "fiap-arch-analyzer-infra"
SERVICE_REPOS = [
    "fiap-arch-analyzer-auth-service",
    "fiap-arch-analyzer-registration-service",
    "fiap-arch-analyzer-report-service",
    "fiap-arch-analyzer-processing-service",
    "fiap-arch-analyzer-api-gateway",
]

# ---------------------------------------------------------------------------
# Domain model
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DeploymentTrigger:
    """An operator trigger as defined in `bugfix.md` "Bug Condition"."""

    trigger_repo: str
    trigger_workflow: str
    intent: str  # "deploy_full_stack" | "deploy_single_service" | "infra_only"


@dataclass
class WorkflowDoc:
    """Parsed view of a GitHub Actions workflow YAML."""

    path: str
    raw_text: str
    parsed: dict
    step_ids: List[str]  # ordered concatenation of `run` / `uses` per step


# ---------------------------------------------------------------------------
# Helpers (per task description)
# ---------------------------------------------------------------------------


def discover_infra_workflows() -> List[str]:
    """Enumerate `.github/workflows/*.yml` (and `*.yaml`) in the infra repo."""
    if not os.path.isdir(_WORKFLOWS_DIR):
        return []
    out: List[str] = []
    for entry in sorted(os.listdir(_WORKFLOWS_DIR)):
        if entry.endswith((".yml", ".yaml")):
            out.append(os.path.join(_WORKFLOWS_DIR, entry))
    return out


def parse_workflow_steps(path: str) -> WorkflowDoc:
    """Read a workflow YAML and return its parsed form + ordered step ids.

    A "step id" is the value of `run:` or `uses:` for that step, in document
    order across every job. This is the surface that
    `orchestrates_all_services` and `_invokes_sts_before_mutation` inspect.
    """
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    parsed = yaml.safe_load(text) or {}

    step_ids: List[str] = []
    jobs = parsed.get("jobs", {}) or {}
    if isinstance(jobs, dict):
        for _job_name, job in jobs.items():
            if not isinstance(job, dict):
                continue
            for step in job.get("steps", []) or []:
                if not isinstance(step, dict):
                    continue
                if "run" in step and step["run"] is not None:
                    step_ids.append(f"run:{step['run']}")
                elif "uses" in step and step["uses"] is not None:
                    step_ids.append(f"uses:{step['uses']}")

    return WorkflowDoc(path=path, raw_text=text, parsed=parsed, step_ids=step_ids)


def _on_includes_workflow_dispatch(parsed: dict) -> bool:
    """True iff the workflow's `on` field includes `workflow_dispatch`."""
    on = parsed.get("on") or parsed.get(True)  # PyYAML maps bare `on:` → True
    if on is None:
        return False
    if isinstance(on, str):
        return on == "workflow_dispatch"
    if isinstance(on, list):
        return "workflow_dispatch" in on
    if isinstance(on, dict):
        return "workflow_dispatch" in on
    return False


_DEPLOY_ALL_INVOCATION_RE = re.compile(
    r"scripts[\\/]deploy-all\.(?:ps1|sh)\b", re.IGNORECASE
)
_IMAGE_TAG_PASS_RE = re.compile(
    r"(?:-ImageTag\s+\$\{?env:IMAGE_TAG\}?|-ImageTag\s+\$\{?\s*env\.IMAGE_TAG\s*\}?"
    r"|\bdeploy-all\.sh\b[^\n]*\$\{?\s*IMAGE_TAG\s*\}?"
    r"|-ImageTag\s+\$\{?\s*IMAGE_TAG\s*\}?"
    r"|--image[-_]tag[= ]\$\{?\s*IMAGE_TAG\s*\}?)",
    re.IGNORECASE,
)
_VALIDATION_REPORT_UPLOAD_RE = re.compile(
    r"validation-report-\*?\.?(?:json|md|\{json,md\}|json,md)", re.IGNORECASE
)
_STS_PROBE_RE = re.compile(r"aws\s+sts\s+get-caller-identity", re.IGNORECASE)


def orchestrates_all_services(workflow: WorkflowDoc) -> bool:
    """Predicate from `bugfix.md` "Bug Condition (Methodology)".

    True iff the workflow:
      1. invokes `scripts/deploy-all.ps1` (or `deploy-all.sh`),
      2. passes a shared `IMAGE_TAG`, and
      3. uploads `./artifacts/validation-report-*.{json,md}` (any of the
         documented forms).
    """
    text = workflow.raw_text
    invokes_orchestrator = bool(_DEPLOY_ALL_INVOCATION_RE.search(text))
    passes_shared_tag = bool(_IMAGE_TAG_PASS_RE.search(text))
    uploads_report = bool(_VALIDATION_REPORT_UPLOAD_RE.search(text))
    return invokes_orchestrator and passes_shared_tag and uploads_report


def _load_deploy_config_services() -> List[str]:
    if not os.path.isfile(_DEPLOY_CONFIG_PATH):
        return []
    with open(_DEPLOY_CONFIG_PATH, "r", encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}
    return [entry["name"] for entry in cfg.get("services", []) if "name" in entry]


def deploys_only_one_service(workflow: WorkflowDoc) -> bool:
    """True iff the workflow's image-push / `kubectl apply` surface targets
    exactly one `services[].name` from `scripts/deploy-all.config.yaml`.

    Used to classify per-service `cd-main.yml` workflows in service repos.
    """
    services = _load_deploy_config_services()
    if not services:
        return False
    text = workflow.raw_text.lower()
    hits = {svc for svc in services if svc.lower() in text}
    return len(hits) == 1


def _invokes_sts_before_mutation(workflow: WorkflowDoc) -> bool:
    """True iff `aws sts get-caller-identity` appears before any mutating step.

    Mutating steps include: `terraform apply`, `kubectl apply`, `docker push`,
    `aws ecr get-login-password` followed by login, and any explicit invocation
    of `scripts/deploy-all.ps1` / `deploy-all.sh`.
    """
    sts_idx: Optional[int] = None
    first_mut_idx: Optional[int] = None

    mutation_patterns = (
        re.compile(r"terraform\s+apply", re.IGNORECASE),
        re.compile(r"kubectl\s+apply", re.IGNORECASE),
        re.compile(r"docker\s+push", re.IGNORECASE),
        _DEPLOY_ALL_INVOCATION_RE,
    )

    for idx, step_id in enumerate(workflow.step_ids):
        if sts_idx is None and _STS_PROBE_RE.search(step_id):
            sts_idx = idx
        if first_mut_idx is None and any(p.search(step_id) for p in mutation_patterns):
            first_mut_idx = idx

    if sts_idx is None:
        return False
    if first_mut_idx is None:
        return True  # STS probe present, no mutation reached yet
    return sts_idx < first_mut_idx


def not_invoked_from_ci(path: str) -> bool:
    """True iff `path` matches `scripts/deploy-all.ps1` (or `.sh`) and is NOT
    referenced by any `run:` line in any infra-owned `.github/workflows/*.yml`.
    """
    norm = path.replace("\\", "/").lower()
    if not norm.endswith(("/scripts/deploy-all.ps1", "/scripts/deploy-all.sh")):
        return False
    for wf_path in discover_infra_workflows():
        with open(wf_path, "r", encoding="utf-8") as fh:
            wf_text = fh.read()
        if _DEPLOY_ALL_INVOCATION_RE.search(wf_text):
            return False
    return True


# ---------------------------------------------------------------------------
# Bug condition classifier
# ---------------------------------------------------------------------------


def _service_repo_workflow_doc(_trigger: DeploymentTrigger) -> Optional[WorkflowDoc]:
    """Best-effort parse of a sibling service repo's workflow file for the
    `deploys_only_one_service` predicate.

    The exploration test runs only against the local infra clone, so we
    cannot always read sibling workflow files. When the workflow file is
    not reachable, we fall back to the design-stated invariant: every
    service-repo `cd-main.yml` deploys only its own service today (per
    Counterexample 2 in `design.md` "Bug Details > Examples").
    """
    sibling_root = os.path.dirname(_REPO_ROOT)
    candidate = os.path.join(
        sibling_root, _trigger.trigger_repo, ".github", "workflows", _trigger.trigger_workflow
    )
    if os.path.isfile(candidate):
        return parse_workflow_steps(candidate)
    return None


def is_bug_condition(trigger: DeploymentTrigger) -> bool:
    """Implements `isBugCondition` from `bugfix.md`."""
    if trigger.intent != "deploy_full_stack":
        return False

    # Case A — infra cd-main.yml does not orchestrate all services
    if trigger.trigger_repo == INFRA_REPO and trigger.trigger_workflow == "cd-main.yml":
        wf_path = os.path.join(_WORKFLOWS_DIR, trigger.trigger_workflow)
        if os.path.isfile(wf_path):
            wf = parse_workflow_steps(wf_path)
            return not orchestrates_all_services(wf)
        return True  # workflow missing → trivially does not orchestrate

    # Case B — service-repo cd-main.yml deploys only one service.
    # Per `design.md` Counterexample 2 every service-repo `cd-main.yml`
    # today is per-service-only. The bug holds whenever the workflow does
    # NOT orchestrate all five services; the textual `deploys_only_one_service`
    # signal is a refinement used for diagnostics only — it can return
    # False on per-service workflows whose YAML never mentions any of the
    # five canonical names verbatim.
    if trigger.trigger_repo in SERVICE_REPOS and trigger.trigger_workflow == "cd-main.yml":
        wf = _service_repo_workflow_doc(trigger)
        if wf is None:
            return True
        if orchestrates_all_services(wf):
            return False
        return True

    # Case C — workstation-only deploy-all.ps1 / .sh
    if trigger.trigger_workflow in ("scripts/deploy-all.ps1", "scripts/deploy-all.sh"):
        script_path = _DEPLOY_PS1 if trigger.trigger_workflow.endswith(".ps1") else _DEPLOY_SH
        return not_invoked_from_ci(script_path)

    return False


# ---------------------------------------------------------------------------
# Hypothesis strategies — scoped to the concrete bug-condition cases
# ---------------------------------------------------------------------------

# Per task spec, the bug is deterministic (workflow file presence/contents).
# The Hypothesis strategy enumerates the three counterexample cases plus
# minor variation (which service repo for Case B, ps1 vs sh for Case C).

_case_a = st.just(
    DeploymentTrigger(
        trigger_repo=INFRA_REPO,
        trigger_workflow="cd-main.yml",
        intent="deploy_full_stack",
    )
)

_case_b = st.sampled_from(SERVICE_REPOS).map(
    lambda repo: DeploymentTrigger(
        trigger_repo=repo,
        trigger_workflow="cd-main.yml",
        intent="deploy_full_stack",
    )
)

_case_c = st.sampled_from(["scripts/deploy-all.ps1", "scripts/deploy-all.sh"]).map(
    lambda script: DeploymentTrigger(
        trigger_repo=INFRA_REPO,
        trigger_workflow=script,
        intent="deploy_full_stack",
    )
)

bug_condition_triggers = st.one_of(_case_a, _case_b, _case_c)


# ---------------------------------------------------------------------------
# Static surrogate property — Property 1
# ---------------------------------------------------------------------------


def _find_consolidated_workflow() -> Tuple[Optional[WorkflowDoc], List[Dict[str, object]]]:
    """Return the first workflow `w` satisfying Property 1, plus a per-file
    diagnostic list useful as a counterexample report when no `w` exists.
    """
    diagnostics: List[Dict[str, object]] = []
    for wf_path in discover_infra_workflows():
        wf = parse_workflow_steps(wf_path)
        diag: Dict[str, object] = {
            "file": os.path.basename(wf_path),
            "on_includes_workflow_dispatch": _on_includes_workflow_dispatch(wf.parsed),
            "orchestrates_all_services": orchestrates_all_services(wf),
            "sts_probe_before_mutation": _invokes_sts_before_mutation(wf),
        }
        diagnostics.append(diag)
        if (
            diag["on_includes_workflow_dispatch"]
            and diag["orchestrates_all_services"]
            and diag["sts_probe_before_mutation"]
        ):
            return wf, diagnostics
    return None, diagnostics


@given(trigger=bug_condition_triggers)
@settings(max_examples=20, deadline=None)
def test_property_1_consolidated_workflow_exists_for_every_bug_condition_trigger(
    trigger: DeploymentTrigger,
):
    """**Validates: Requirements 1.1, 1.2, 1.5, 1.6, 1.7**

    Property 1 (static surrogate, no AWS calls):

        For every `trigger` where `isBugCondition(trigger)` holds, there
        SHALL exist at least one workflow file `w` in
        `fiap-arch-analyzer-infra/.github/workflows/` such that:

          - `w.on` includes `workflow_dispatch`
          - `orchestrates_all_services(w)` is true
          - `w` invokes `aws sts get-caller-identity` before any mutating step

    EXPECTED ON UNFIXED CODE: this property FAILS for every bug-condition
    trigger because no such workflow file exists yet (the infra repo holds
    only `cd-main.yml` which stops at `terraform apply`). The failure is
    the counterexample evidence that the bug is real.

    EXPECTED AFTER FIX: this property PASSES once
    `.github/workflows/cd-deploy-all.yml` is added per `design.md` "Fix
    Implementation > Specific Changes".
    """
    # Sanity guard: skip examples that no longer match isBugCondition
    # post-fix (e.g. Case C, where `scripts/deploy-all.ps1` is now invoked
    # from `cd-deploy-all.yml`, so `not_invoked_from_ci` returns False).
    # The property is still exercised on every example that DOES match the
    # bug condition; the post-fix invariant remains: a consolidated workflow
    # exists. Using `assume` (not `assert`) keeps the test green when the
    # fix has landed, while still rejecting non-bug examples on unfixed code.
    assume(is_bug_condition(trigger))

    consolidated, diagnostics = _find_consolidated_workflow()
    assert consolidated is not None, (
        "Property 1 violated for trigger "
        f"{trigger}: no workflow under `fiap-arch-analyzer-infra/.github/"
        "workflows/` satisfies `on includes workflow_dispatch` AND "
        "`orchestrates_all_services` AND `aws sts get-caller-identity` "
        "before any mutating step.\n\n"
        f"Workflow diagnostics: {diagnostics}\n\n"
        "Counterexample 1 (design.md): infra `cd-main.yml` stops after "
        "`terraform apply` — terraform_applied=true, images_pushed_count=0, "
        "validator_report_written=false.\n"
        "Counterexample 2 (design.md): service-repo `cd-main.yml` deploys "
        "exactly one service with that repo's github.sha as image tag — "
        "shared_image_tag_used=false, stage_order_respected=false.\n"
        "Counterexample 3 (design.md): six manual triggers produce arbitrary "
        "completion order, five distinct image tags, zero consolidated "
        "validation-report-<timestamp>.{json,md}."
    )


# ---------------------------------------------------------------------------
# Concrete case-by-case assertions (debugging-friendly counterexamples)
# ---------------------------------------------------------------------------


class TestBugConditionCounterexamples:
    """Concrete counterexamples surfaced by the static surrogate.

    Each test corresponds to one of the three counterexamples documented in
    `design.md` "Bug Details > Examples". They are individually informative
    failure modes for the property-based test above.
    """

    def test_case_a_infra_cd_main_does_not_orchestrate_all_services(self):
        """Counterexample 1 — infra `cd-main.yml` stops after `terraform apply`.

        On UNFIXED code: this assertion FAILS because `orchestrates_all_services`
        returns False — the workflow does not invoke `scripts/deploy-all.ps1`,
        does not pass a shared `IMAGE_TAG`, and does not upload
        `validation-report-*.{json,md}`.
        """
        trigger = DeploymentTrigger(
            trigger_repo=INFRA_REPO,
            trigger_workflow="cd-main.yml",
            intent="deploy_full_stack",
        )
        assert is_bug_condition(trigger), (
            "Case A is no longer the bug condition — the infra `cd-main.yml` "
            "now orchestrates all services. Either the fix has landed or "
            "the workflow has drifted."
        )

        wf_path = os.path.join(_WORKFLOWS_DIR, "cd-main.yml")
        wf = parse_workflow_steps(wf_path)

        assert orchestrates_all_services(wf), (
            "Counterexample 1 confirmed: infra `cd-main.yml` does NOT "
            f"orchestrate all services. step_ids={wf.step_ids}. "
            "Expected to invoke `scripts/deploy-all.ps1` (or `.sh`), pass a "
            "shared `IMAGE_TAG`, and upload `validation-report-*.{json,md}`."
        )

    def test_case_b_service_repo_cd_main_deploys_only_one_service(self):
        """Counterexample 2 — service-repo `cd-main.yml` is per-service-only.

        On UNFIXED code: the bug condition holds because each service repo's
        `cd-main.yml` rolls out exactly one service with its own `github.sha`
        as image tag. We assert `is_bug_condition` returns True for the
        canonical sample (api-gateway).
        """
        sample = DeploymentTrigger(
            trigger_repo="fiap-arch-analyzer-api-gateway",
            trigger_workflow="cd-main.yml",
            intent="deploy_full_stack",
        )
        assert is_bug_condition(sample), (
            "Counterexample 2 disproved: service-repo `cd-main.yml` no "
            "longer matches the per-service-only invariant. Verify whether "
            "the consolidated entry point fix has landed."
        )

    def test_case_c_workstation_script_not_invoked_from_ci(self):
        """Counterexample 3 — `scripts/deploy-all.ps1` is not wired into CI.

        On UNFIXED code: `not_invoked_from_ci` returns True because no
        `.github/workflows/*.yml` in the infra repo references the script.
        """
        sample = DeploymentTrigger(
            trigger_repo=INFRA_REPO,
            trigger_workflow="scripts/deploy-all.ps1",
            intent="deploy_full_stack",
        )
        assert is_bug_condition(sample), (
            "Counterexample 3 disproved: `scripts/deploy-all.ps1` is now "
            "referenced by an infra-owned workflow. Verify whether the "
            "consolidated entry point fix has landed."
        )

    def test_no_consolidated_workflow_exists_yet(self):
        """Direct sanity check that demonstrates the bug surface.

        On UNFIXED code: NO workflow under
        `fiap-arch-analyzer-infra/.github/workflows/` simultaneously
          - has `workflow_dispatch` in `on`,
          - satisfies `orchestrates_all_services`, and
          - probes `aws sts get-caller-identity` before any mutation.
        """
        consolidated, diagnostics = _find_consolidated_workflow()
        assert consolidated is not None, (
            "No consolidated workflow exists. Per-file diagnostics:\n"
            + "\n".join(repr(d) for d in diagnostics)
        )


# ---------------------------------------------------------------------------
# Helper sanity tests — these MUST always pass; they protect the test logic
# itself from drift, independent of whether the bug is fixed.
# ---------------------------------------------------------------------------


class TestHelperSanity:
    """Guard-rails for the helpers used by the property-based test.

    These do not assert the bug — they assert that the helpers behave the
    way the test relies on. Keep them passing always.
    """

    def test_discover_infra_workflows_returns_existing_files(self):
        files = discover_infra_workflows()
        assert files, "Expected at least one workflow under .github/workflows/"
        for f in files:
            assert os.path.isfile(f)

    def test_parse_workflow_steps_handles_existing_cd_main(self):
        wf_path = os.path.join(_WORKFLOWS_DIR, "cd-main.yml")
        if not os.path.isfile(wf_path):
            pytest.skip("cd-main.yml not present in this checkout")
        wf = parse_workflow_steps(wf_path)
        assert wf.parsed
        assert isinstance(wf.step_ids, list)
        # cd-main.yml today contains `terraform apply`
        joined = "\n".join(wf.step_ids).lower()
        assert "terraform" in joined or "apply" in joined

    def test_orchestrates_all_services_rejects_synthetic_partial_workflow(
        self, tmp_path
    ):
        """Helper: a YAML missing the artifact upload must fail the predicate."""
        partial = tmp_path / "partial.yml"
        partial.write_text(
            "name: partial\n"
            "on: workflow_dispatch\n"
            "jobs:\n"
            "  d:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - run: pwsh -File ./scripts/deploy-all.ps1 -ImageTag $env:IMAGE_TAG\n",
            encoding="utf-8",
        )
        wf = parse_workflow_steps(str(partial))
        assert not orchestrates_all_services(wf), (
            "Helper drift: a workflow without an artifact upload step "
            "incorrectly classified as orchestrating all services."
        )

    def test_orchestrates_all_services_accepts_synthetic_full_workflow(
        self, tmp_path
    ):
        """Helper: a YAML covering all three predicate clauses passes."""
        full = tmp_path / "full.yml"
        full.write_text(
            "name: full\n"
            "on: workflow_dispatch\n"
            "jobs:\n"
            "  d:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - run: aws sts get-caller-identity\n"
            "      - run: pwsh -File ./scripts/deploy-all.ps1 -ImageTag $env:IMAGE_TAG\n"
            "      - uses: actions/upload-artifact@v4\n"
            "        with:\n"
            "          name: validation-report\n"
            "          path: ./artifacts/validation-report-*.json\n",
            encoding="utf-8",
        )
        wf = parse_workflow_steps(str(full))
        assert orchestrates_all_services(wf), (
            "Helper drift: a workflow that invokes deploy-all.ps1, passes "
            "a shared IMAGE_TAG, and uploads validation-report-*.json was "
            "not classified as orchestrating all services."
        )

    def test_invokes_sts_before_mutation_synthetic_positive(self, tmp_path):
        wf_path = tmp_path / "ok.yml"
        wf_path.write_text(
            "name: ok\n"
            "on: workflow_dispatch\n"
            "jobs:\n"
            "  d:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - run: aws sts get-caller-identity\n"
            "      - run: terraform apply -auto-approve\n",
            encoding="utf-8",
        )
        wf = parse_workflow_steps(str(wf_path))
        assert _invokes_sts_before_mutation(wf)

    def test_invokes_sts_before_mutation_synthetic_negative(self, tmp_path):
        wf_path = tmp_path / "bad.yml"
        wf_path.write_text(
            "name: bad\n"
            "on: workflow_dispatch\n"
            "jobs:\n"
            "  d:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - run: terraform apply -auto-approve\n"
            "      - run: aws sts get-caller-identity\n",
            encoding="utf-8",
        )
        wf = parse_workflow_steps(str(wf_path))
        assert not _invokes_sts_before_mutation(wf)
