# Implementation Plan

## Overview

This plan fixes the missing infra-owned, single-trigger entry point that drives all five Arch Analyzer services to AWS in dependency order with one shared image tag and one Validator report. The fix is purely additive: a new `.github/workflows/cd-deploy-all.yml` in `fiap-arch-analyzer-infra` that invokes the existing `scripts/deploy-all.ps1` orchestrator from a GitHub-hosted runner using `LabRole` session credentials. No service-repo workflow files, no Terraform IAM resources, and no orchestrator script logic are modified — preserving every non-consolidated path (per-service CI, single-service hotfix `cd-main.yml`, infra-only `cd-main.yml`, workstation `deploy-all.ps1`) and every AWS Academy invariant (LabRole-only authentication, no IAM creation, HTTP-only ALB, private RDS subnets, USD 50–100/month budget envelope).

The plan follows the bugfix bug-condition methodology: task 1 surfaces counterexamples on UNFIXED code (test must FAIL), task 2 captures preservation behavior on UNFIXED code via property-based tests over the orchestrator's pure decision logic plus direct observation of non-consolidated surfaces (tests must PASS), task 3 implements the wiring fix and re-runs both test sets (both must PASS), and task 4 is the end-to-end checkpoint.

## Task Dependency Graph

```
1 (Bug Condition exploration test, must FAIL on unfixed code)
        │
        │   independent — can be authored in parallel
        ▼
2 (Preservation property tests, must PASS on unfixed code)
        │
        ▼
3.1 (workflow file scaffold)
        │
        ├─► 3.2 (AWS credentials + STS probe)
        │       │
        │       ├─► 3.3 (shared image_tag resolver)
        │       │
        │       ├─► 3.4 (sibling repo checkouts)
        │       │
        │       └─► 3.5 (toolchain install)
        │                   │
        │                   ▼
        │             3.6 (orchestrator invocation)
        │                   │
        │                   ▼
        │             3.7 (artifact upload)
        │                   │
        │                   ▼
        │             3.8 (re-run task 1 — must PASS now)
        │                   │
        │                   ▼
        │             3.9 (re-run task 2 — must still PASS)
        │
        ▼
4 (Checkpoint — full suite + end-to-end + idempotency re-run + Academy invariants)
```

Tasks 1 and 2 are independent and may be authored in any order, but both MUST be complete and the expected outcomes (1 fails, 2 passes) MUST be observed before any subtask of 3 starts. Task 3.1 must precede every other 3.x task because it creates the workflow file. Tasks 3.2 through 3.5 may proceed in parallel once 3.1 lands. Task 3.6 depends on all of 3.2–3.5 because the orchestrator needs credentials, the image tag, the sibling repos, and the toolchain. Tasks 3.7, 3.8, 3.9 follow 3.6 sequentially. Task 4 is the final gate.

```json
{
  "waves": [
    {
      "wave": 1,
      "description": "Author exploration and preservation tests on UNFIXED code (independent, parallel)",
      "tasks": ["1", "2"]
    },
    {
      "wave": 2,
      "description": "Create the consolidated workflow file scaffold",
      "tasks": ["3.1"]
    },
    {
      "wave": 3,
      "description": "Wire credentials, image tag, sibling checkouts, toolchain (parallel after 3.1)",
      "tasks": ["3.2", "3.3", "3.4", "3.5"]
    },
    {
      "wave": 4,
      "description": "Invoke the orchestrator as the single mutating step",
      "tasks": ["3.6"]
    },
    {
      "wave": 5,
      "description": "Upload artifact, then re-run task 1 (must PASS) and task 2 (must still PASS)",
      "tasks": ["3.7", "3.8", "3.9"]
    },
    {
      "wave": 6,
      "description": "End-to-end checkpoint plus idempotency re-run and Academy invariants verification",
      "tasks": ["4"]
    }
  ]
}
```

## Tasks

- [x] 1. Write bug condition exploration test
  - **Property 1: Bug Condition** - Consolidated Full-Stack Deployment Missing
  - **CRITICAL**: This test MUST FAIL on unfixed code - failure confirms the bug exists
  - **DO NOT attempt to fix the test or the code when it fails**
  - **NOTE**: This test encodes the expected behavior - it will validate the fix when it passes after implementation
  - **GOAL**: Surface counterexamples that demonstrate the project has no infra-owned, single-trigger entry point that drives all five services to AWS in dependency order with one shared image tag and one Validator report.
  - **Scoped PBT Approach**: Bug is deterministic (workflow file presence/contents). Scope the property to concrete failing cases corresponding to Counterexamples 1, 2, 3 from `design.md` "Bug Details > Examples":
    - Case A — `(trigger_repo="fiap-arch-analyzer-infra", trigger_workflow="cd-main.yml", intent="deploy_full_stack")`
    - Case B — `(trigger_repo="fiap-arch-analyzer-api-gateway", trigger_workflow="cd-main.yml", intent="deploy_full_stack")` (one representative service repo from `service_repos`)
    - Case C — six manual triggers (one infra `cd-main.yml` + five service `cd-main.yml`) with `intent="deploy_full_stack"`
  - Place the test under `tests/test_consolidated_deployment_bug.py` (uses the Hypothesis suite already present in `.hypothesis/` per `design.md` "Property-Based Tests").
  - Implement helpers:
    - `discover_infra_workflows()` — enumerates `.github/workflows/*.yml` in `fiap-arch-analyzer-infra` (the local clone at the repo root).
    - `parse_workflow_steps(path)` — reads YAML and returns the ordered list of `run` / `uses` step ids.
    - `orchestrates_all_services(workflow)` — predicate from `bugfix.md` "Bug Condition (Methodology)": true iff the workflow invokes `scripts/deploy-all.ps1` (or `deploy-all.sh`), passes a shared `IMAGE_TAG`, and uploads `./artifacts/validation-report-*.{json,md}`.
    - `deploys_only_one_service(workflow)` — true iff the workflow's `kubectl apply` / image-push surface targets exactly one `services[].name` from `scripts/deploy-all.config.yaml`.
    - `not_invoked_from_ci(path)` — true iff `path` matches `scripts/deploy-all.ps1` and is not referenced by any `.github/workflows/*.yml` `run:` line in any infra-owned workflow.
  - Property assertion (matches Property 1 in `design.md` "Correctness Properties"):
    - For all `input` where `isBugCondition(input)` (per the pseudocode in `bugfix.md` "Bug Condition (Methodology)"), `runConsolidatedWorkflow(input)` must satisfy: `terraform_applied=true`, `images_pushed_count=5`, `shared_image_tag_used=true`, `stage_order_respected=true` (`[auth] → [registration, report, processing] → [api-gateway]`), `rollout_status_gated_per_stage=true`, `validator_report_written=true`, `(validator_overall=true OR exit_code != 0)`, `idempotent_on_rerun=true`.
    - Static surrogate (no AWS calls in unit phase): assert there exists at least one workflow file `w` in `fiap-arch-analyzer-infra/.github/workflows/` such that `w.on` includes `workflow_dispatch`, `orchestrates_all_services(w)` is true, and `w` invokes `aws sts get-caller-identity` before any mutating step (Requirement 2.8 / `design.md` "Fix Implementation > Specific Changes #2").
  - Run the test on UNFIXED code:
    - Static surrogate: **EXPECTED OUTCOME**: Test FAILS — no workflow under `fiap-arch-analyzer-infra/.github/workflows/` satisfies `orchestrates_all_services`; the existing `cd-main.yml` stops at `terraform apply` (matches Counterexample 1 in `design.md`).
    - Dynamic surrogate (optional, gated behind a `pytest.mark.integration` marker): trigger `cd-main.yml` against the Academy account through `gh workflow run` and assert zero `Deployment`s rolled out post-run; expected to FAIL with `images_pushed_count=0`.
  - Document counterexamples found in the test docstring:
    - "Counterexample 1 — infra `cd-main.yml`: `terraform_applied=true` but `images_pushed_count=0`, `validator_report_written=false`."
    - "Counterexample 2 — service-repo `cd-main.yml`: `images_pushed_count=1`, `shared_image_tag_used=false` (image tagged with that service repo's `github.sha`), `stage_order_respected=false`."
    - "Counterexample 3 — six manual triggers: arbitrary completion order, five distinct image tags, zero consolidated `validation-report-<timestamp>.{json,md}`."
  - Mark task complete when test is written, run, and failure is documented.
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8_

- [x] 2. Write preservation property tests (BEFORE implementing fix)
  - **Property 2: Preservation** - Non-Consolidated Paths Unchanged
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first for every non-`deploy_full_stack` input class, then encode the observations as property-based tests.
  - Place tests under `tests/test_consolidated_deployment_preservation.py` alongside the exploration test from task 1.
  - **Observation phase (record on UNFIXED code, no AWS mutations beyond what already runs today):**
    - Per-service CI: capture `ci-develop.yml`, `ci-feature.yml`, `ci-release.yml` step lists, exit codes, and emitted artifact names from the latest green run on each of the five service repos.
    - Single-service hotfix: capture the latest green `cd-main.yml` run on one service repo (api-gateway is the canonical sample), recording which Deployment rolled out and the image tag scheme (`github.sha` of that service repo).
    - Infra-only `cd-main.yml`: capture a `terraform plan`/`apply` exit code and the Terraform output set (`eks_cluster_name`, `alb_dns_name`, `ecr_repository_urls`, `ecr_registry_url`) from the most recent successful run.
    - Direct workstation `scripts/deploy-all.ps1`: capture the 11 stage names, exit code, and `./artifacts/` filenames (modulo timestamp) from a local run.
    - `infra-outputs` ConfigMap: `kubectl get configmap infra-outputs -o yaml` and snapshot the key set.
    - AWS Academy invariants: `aws iam list-roles | jq '.Roles[].RoleName'` (must contain `LabRole`), ALB scheme/listener (HTTP only on :80), RDS subnet group (private subnets only), CloudWatch alarms (5xx rate, DLQ depth).
  - **Property-based tests over the orchestrator's pure decision logic** (matches `design.md` "Property-Based Tests"):
    - **PT-1 — `isBugCondition` classifier**: Hypothesis strategy generating `(trigger_repo, trigger_workflow, intent)` tuples drawn from `{"fiap-arch-analyzer-infra"} ∪ service_repos × actual_workflow_files × {"deploy_full_stack","deploy_single_service","infra_only"}`. Assert: `isBugCondition(x) == True` iff `x` matches the predicate in `bugfix.md`; for every `x` where `isBugCondition(x) == False`, `routeToOriginalPath(x) == originalPath(x)` (i.e. the consolidated workflow is never reached).
    - **PT-2 — Stage-order planner over arbitrary `services[]` permutations**: Hypothesis strategy generating permutations of `scripts/deploy-all.config.yaml` `services[]`. Assert: the planner always emits an order satisfying `auth ≺ {registration, report, processing} ≺ api-gateway`, regardless of input ordering.
    - **PT-3 — `image_tag` resolver**: Hypothesis strategy generating `image_tag` inputs (empty, valid short SHAs, whitespace, control chars, oversized strings). Assert: empty → `git rev-parse --short HEAD`; non-empty valid → verbatim; invalid → reject with non-zero exit before any mutation; pure function (no side effects on rejection).
    - **PT-4 — Idempotency surrogate**: Hypothesis strategy generating two consecutive `runConsolidatedWorkflow` invocations with identical inputs (mocked AWS). Assert: identical Terraform plan output, identical ECR digest set, identical `kubectl apply` outcome.
  - **Direct preservation assertions on observed behavior**:
    - Per-service `ci-*.yml` step lists and exit codes are byte-identical before and after the fix (no service repo files are touched by this fix, per `design.md` "Specific Changes #10").
    - Single-service `cd-main.yml` rolls out exactly one Deployment with `github.sha` of that service repo as image tag.
    - Infra `cd-main.yml` step list ends after `terraform apply -auto-approve`; the Terraform output set is unchanged.
    - Direct workstation `scripts/deploy-all.ps1` produces the same 11-stage exit codes and the same `./artifacts/` filenames (modulo timestamp).
    - `infra-outputs` ConfigMap key set is unchanged.
    - AWS Academy invariants hold: only `LabRole` present (no new IAM principals), ALB is HTTP-only, RDS subnets are private, S3 `BlockPublicAccess=true`, SQS/S3 `aws:SecureTransport=true`, CloudWatch alarms (5xx rate, DLQ depth) still bound to their original metrics, no new chargeable resources (zero net change in NAT Gateway / ALB / managed-runner counts), monthly chargeable baseline matches the AP-8 envelope (no new line items added by the fix).
  - **Verify tests PASS on UNFIXED code**:
    - PT-1 through PT-4 must pass — they test pure helpers that already exist or will be extracted from `scripts/deploy-all.ps1` / `scripts/deploy-all.config.yaml` without behavioural change.
    - All direct preservation assertions must pass — none of the observed surfaces change before the fix is applied.
  - **EXPECTED OUTCOME**: Tests PASS on UNFIXED code (this confirms the baseline behavior to preserve).
  - Mark task complete when tests are written, run, and passing on unfixed code.
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10_

- [x] 3. Fix for missing infra-owned consolidated full-stack deployment entry point

  - [x] 3.1 Create `.github/workflows/cd-deploy-all.yml` in `fiap-arch-analyzer-infra`
    - Add a new workflow file with `on: workflow_dispatch` only — no `push` trigger; consolidated deploys are deliberate (per `design.md` "Specific Changes #1").
    - Declare a single string input `image_tag` (optional, default empty → resolved to `git rev-parse --short HEAD`) so operators can override the shared tag for replays.
    - Pin the runner to `ubuntu-latest` (cheapest GitHub-hosted runner; preserves the USD 50–100/month budget surface — no managed CI runners added).
    - Set `permissions: contents: read` only on the job. No `id-token: write` (GitHub OIDC federation to AWS is forbidden — see AP-9 / Academy doc §1.3.3).
    - Header comment must document: idempotency contract (re-running with no code changes converges to zero changes — Terraform/ECR/`kubectl apply`), AP-5 Lab-reset semantics, AP-7 region constraint (`us-east-1` or `us-west-2` only), and AP-9 manual session-token refresh procedure.
    - _Bug_Condition: isBugCondition(input) — input.intent="deploy_full_stack" with any of the three trigger patterns enumerated in `design.md` "Bug Details > Bug Condition" (infra cd-main.yml, service-repo cd-main.yml, or workstation-only deploy-all.ps1)_
    - _Expected_Behavior: expectedBehavior(result) — Property 1 in `design.md` "Correctness Properties": single workflow run executes the full 11-stage flow, produces one shared image tag across all five services, writes `./artifacts/validation-report-<timestamp>.{json,md}`, and exits non-zero on failure_
    - _Preservation: design.md "Preservation Requirements" — no service-repo workflow files are touched; infra `cd-main.yml` semantics unchanged; `scripts/deploy-all.ps1` semantics unchanged; `infra-outputs` ConfigMap contract unchanged; LabRole-only authentication preserved_
    - _Requirements: 2.1, 2.2, 2.5, 2.10, 3.1, 3.2, 3.3, 3.5_

  - [x] 3.2 Configure AWS credentials step using existing repo secrets
    - Add `aws-actions/configure-aws-credentials@v4` reading `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` from existing GitHub repo secrets (already used by service workflows).
    - Hardcode `aws-region: us-east-1` (or accept it from a workflow input restricted to `us-east-1` / `us-west-2` only — reject every other value before any mutating step, per AP-7).
    - Do NOT introduce new IAM users, roles, or principals beyond `LabRole` (Requirement 3.5 / Academy doc §1.2.1, §1.3.3 — `iam:CreateRole`, `iam:AttachRolePolicy` on `LabRole`, and `iam:CreateOpenIDConnectProvider` are all blocked).
    - Immediately follow with `aws sts get-caller-identity` as a fail-fast credential probe; any `ExpiredToken` here aborts the run before any mutating step with a clear "refresh Learner Lab credentials in repo secrets" message (Requirement 2.8).
    - _Bug_Condition: isBugCondition(input) where input.intent="deploy_full_stack" and ExpiredToken occurs mid-run today with no shared handling_
    - _Expected_Behavior: expectedBehavior(result) — fail-fast on ExpiredToken before any mutation; non-zero exit; refresh prompt in stderr_
    - _Preservation: LabRole-only authentication; no new IAM; AP-9 long-lived session-token model_
    - _Requirements: 2.8, 2.10, 3.5_

  - [x] 3.3 Resolve the shared image tag once per run and export it
    - Add a step that computes the shared tag exactly once: if `inputs.image_tag` is non-empty and matches `^[A-Za-z0-9._-]{1,128}$`, use it verbatim; otherwise compute `git rev-parse --short HEAD` against the checked-out infra commit.
    - Reject malformed `inputs.image_tag` with a non-zero exit before any mutation (consistent with PT-3 from task 2).
    - Export the value as `IMAGE_TAG` in `$GITHUB_ENV` and echo it at the top of the run log for traceability.
    - Pass `-ImageTag $env:IMAGE_TAG` (or `"$IMAGE_TAG"` for bash) explicitly to `scripts/deploy-all.ps1` so every service image pushed in this run carries the same tag.
    - _Bug_Condition: isBugCondition(input) — service-repo cd-main.yml today tags each image with that repo's own github.sha, producing five distinct tags from five different commits (Counterexample 3)_
    - _Expected_Behavior: expectedBehavior(result) — Property 1's `shared_image_tag_used = true` clause; one identifier across all five services per run_
    - _Preservation: scripts/deploy-all.ps1 already accepts `-ImageTag`; no change to the script's contract_
    - _Requirements: 2.4_

  - [x] 3.4 Check out sibling service repos into the workspace
    - Add `actions/checkout@v4` for `fiap-arch-analyzer-infra` itself (current repo).
    - Add five additional `actions/checkout@v4` steps cloning `fiap-arch-analyzer-auth-service`, `fiap-arch-analyzer-registration-service`, `fiap-arch-analyzer-processing-service`, `fiap-arch-analyzer-report-service`, `fiap-arch-analyzer-api-gateway` into `../<repo>` relative to the workspace root, matching the directory layout `scripts/deploy-all.config.yaml` already expects.
    - Default `ref: main`. Use `${{ secrets.GITHUB_TOKEN }}` if all repos are in the same org and visibility allows; otherwise document a `SERVICES_CHECKOUT_TOKEN` PAT requirement in the workflow file header (no new mandatory secrets if repos are public).
    - _Bug_Condition: isBugCondition(input) — orchestrator script cannot find sibling repos when run from a clean GitHub-hosted runner_
    - _Expected_Behavior: expectedBehavior(result) — orchestrator finds every services[].k8s_dir and every Dockerfile under the layout it already expects_
    - _Preservation: directory layout matches what scripts/deploy-all.config.yaml already documents; no change to that config_
    - _Requirements: 2.1, 2.5_

  - [x] 3.5 Install the toolchain required by `scripts/deploy-all.ps1`
    - Add steps to install `terraform` (matching the version pinned in `.terraform.lock.hcl`), `kubectl`, and the `aws` CLI on the runner.
    - Docker and PowerShell Core are preinstalled on `ubuntu-latest`; do not add chargeable replacements.
    - All toolchain components are free; no chargeable resources are added (preserves Requirement 3.8 / AP-8 budget envelope).
    - _Bug_Condition: isBugCondition(input) — orchestrator depends on the toolchain; missing tools = stage failure_
    - _Expected_Behavior: expectedBehavior(result) — every stage of `scripts/deploy-all.ps1` finds its required binary on PATH_
    - _Preservation: USD 50–100/month budget surface; no managed CI runners; only free GitHub-hosted runner tooling_
    - _Requirements: 3.8_

  - [x] 3.6 Invoke the orchestrator as the single mutating step
    - Add the step `pwsh -File ./scripts/deploy-all.ps1 -ImageTag $env:IMAGE_TAG` (or `bash ./scripts/deploy-all.sh "$IMAGE_TAG"` if pwsh proves unreliable on the runner; both share `scripts/deploy-all.config.yaml`).
    - The script enforces internally: 11-stage flow (path validation, STS check, terraform init/apply, kubeconfig, ECR login, build/push, MongoDB/Redis wait, migrations, staged `kubectl apply` with `kubectl rollout status` gates, Validator, one auto-retry).
    - Stage ordering `[auth-service] → [registration-service, report-service, processing-service] → [api-gateway]` is read from `scripts/deploy-all.config.yaml` `stages[]`; do NOT duplicate it in YAML.
    - Validator probes `http://<alb_dns>/api/<service>/health` for each service and writes `./artifacts/validation-report-<timestamp>.{json,md}`.
    - On Validator failure, the script executes exactly one automatic retry (pod restart or ConfigMap re-apply) and re-runs the Validator before exiting non-zero.
    - The workflow surfaces the script's exit code as the job's exit code (default `pwsh` / `bash` `set -e` style).
    - _Bug_Condition: isBugCondition(input) — orchestration logic exists in scripts/deploy-all.ps1 but is unreachable from CI today_
    - _Expected_Behavior: expectedBehavior(result) — Property 1's full clause: `terraform_applied`, `images_pushed_count=5`, `stage_order_respected`, `validator_report_written`, `(validator_overall OR exit_code != 0)`, `idempotent_on_rerun`_
    - _Preservation: scripts/deploy-all.ps1 / .sh / .config.yaml are NOT modified by this task; only the workflow invokes them_
    - _Requirements: 2.1, 2.3, 2.5, 2.6, 2.7, 2.9_

  - [x] 3.7 Upload the consolidated validation report as a workflow artifact
    - Add a final `actions/upload-artifact@v4` step with `if: always()` that uploads `./artifacts/validation-report-*.json` and `./artifacts/validation-report-*.md`.
    - Set retention to the default (90 days, free tier) — preserves the budget surface.
    - _Bug_Condition: isBugCondition(input) — six independent pipelines today produce zero consolidated report_
    - _Expected_Behavior: expectedBehavior(result) — Property 1's `validator_report_written = true` clause; exactly one report per consolidated run, surfaced as a workflow artifact_
    - _Preservation: USD 50–100/month budget; default retention is free_
    - _Requirements: 2.6, 3.8_

  - [x] 3.8 Verify bug condition exploration test now passes
    - **Property 1: Expected Behavior** - Consolidated Full-Stack Deployment
    - **IMPORTANT**: Re-run the SAME test from task 1 — do NOT write a new test
    - The test from task 1 encodes the expected behavior; when it passes, it confirms the expected behavior is satisfied.
    - Run the static surrogate first: `pytest tests/test_consolidated_deployment_bug.py -k property_1` — must pass now that `cd-deploy-all.yml` exists, invokes `aws sts get-caller-identity` before any mutating step, calls `scripts/deploy-all.ps1` with a shared `IMAGE_TAG`, and uploads `validation-report-*.{json,md}`.
    - Run the dynamic surrogate (integration marker) once against the Academy account: `gh workflow run cd-deploy-all.yml --repo fiap-arch-analyzer-infra --ref main`; assert the run exits 0, all five `Deployment`s reach `Available`, and `validation-report-<timestamp>.json` `overall == true`.
    - **EXPECTED OUTCOME**: Test PASSES (confirms bug is fixed)
    - _Requirements: Property 1 (Expected Behavior) — 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10_

  - [x] 3.9 Verify preservation tests still pass
    - **Property 2: Preservation** - Non-Consolidated Paths Unchanged
    - **IMPORTANT**: Re-run the SAME tests from task 2 — do NOT write new tests
    - Run `pytest tests/test_consolidated_deployment_preservation.py` — PT-1 through PT-4 plus all direct preservation assertions must pass.
    - Spot-check the live surfaces:
      - Trigger one service repo's `ci-develop.yml` from a `develop` branch push — assert step list and exit code are unchanged.
      - Push a no-op commit to `main` on one service repo — assert that service's `cd-main.yml` deploys exactly that one service with `github.sha` as image tag (single-service hotfix path preserved per Requirement 3.9).
      - Trigger infra `cd-main.yml` for an infra-only change — assert it stops after `terraform apply` and emits the same Terraform output set (Requirement 3.3).
      - Run `scripts/deploy-all.ps1` from a workstation — assert identical 11-stage exit codes and identical `./artifacts/` filenames modulo timestamp (Requirement 3.2).
      - `kubectl get configmap infra-outputs -o yaml` — key set unchanged (Requirement 3.4).
      - `aws iam list-roles` — no new principals beyond `LabRole` (Requirement 3.5 / AP-9).
      - `aws elbv2 describe-load-balancers` — ALB count unchanged, listener still HTTP-only on :80 (Requirement 3.7).
      - `aws ec2 describe-nat-gateways` — NAT Gateway count unchanged (Requirement 3.8 / AP-8).
      - `aws cloudwatch describe-alarms` — 5xx rate and DLQ depth alarms still bound to their original metrics (Requirement 3.7, 3.10).
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Confirm all tests still pass after the fix (no regressions on any non-consolidated path).
    - _Requirements: Property 2 (Preservation) — 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10_

- [x] 4. Checkpoint - Ensure all tests pass
  - Run the full suite: `pytest tests/test_consolidated_deployment_bug.py tests/test_consolidated_deployment_preservation.py -v`.
  - Trigger `cd-deploy-all.yml` once end-to-end against the Academy account; assert the run exits 0, the Validator report's `overall == true`, and the artifact appears under the workflow run's "Artifacts" panel.
  - Trigger `cd-deploy-all.yml` a second time back-to-back with no code changes; assert idempotency — zero Terraform drift, zero new ECR digests, zero rollout changes — within the same Learner Lab session (per AP-5).
  - Confirm AWS Academy invariants still hold: `LabRole` is the only principal in use, ALB is HTTP-only on :80, RDS subnets are private, S3 `BlockPublicAccess=true`, SQS/S3 `aws:SecureTransport=true`, CloudWatch alarms intact, no new chargeable resources.
  - Ensure all tests pass; ask the user if questions arise.

## Notes

- **AWS Academy constraints (honored throughout)**: `LabRole`-only authentication; no `iam:CreateRole`, no `iam:AttachRolePolicy` on `LabRole`, no `iam:CreateOpenIDConnectProvider` (rules out IRSA, AWS Load Balancer Controller, EBS CSI via IRSA, Cluster Autoscaler — see AP-1 through AP-4 and AP-9 in `design.md`). GitHub OIDC federation to AWS is forbidden; long-lived repo secrets carrying the Learner Lab session token are the only viable authentication mode (AP-9).
- **Region**: workflow runs only in `us-east-1` (or `us-west-2`); reject every other region before any mutating step (AP-7 / Academy doc §6.1).
- **Budget**: no new chargeable resources introduced (no extra NAT Gateway, no additional ALB, no managed CI runners beyond GitHub-hosted `ubuntu-latest`); workflow artifact retention stays on the free 90-day default. The current chargeable baseline already overspends the USD 50–100 envelope per AP-8 — this fix does not worsen it.
- **Idempotency scope**: Property 1's `idempotent_on_rerun = true` clause holds within a single Learner Lab session. After a Lab reset (Academy doc §6.3), all session-created AWS resources are wiped; a subsequent `terraform apply` correctly recreates them — this is Terraform-correct convergence, not an idempotency violation (AP-5).
- **Preservation boundary (do NOT modify)**: any `.github/workflows/ci-*.yml` or `cd-main.yml` in any service repo; `cd-main.yml` in the infra repo; `scripts/deploy-all.ps1`, `scripts/deploy-all.sh`, or `scripts/deploy-all.config.yaml`; the EKS `aws-auth` ConfigMap; the `infra-outputs` ConfigMap schema; any IAM, ALB, NAT Gateway, or RDS subnet topology.
- **Tests must fail/pass exactly as documented**: task 1's test MUST FAIL on unfixed code (failure is the counterexample evidence), and task 2's tests MUST PASS on unfixed code (passing confirms baseline behavior captured before the fix). After task 3, both must PASS.
- **Orchestrator reuse**: all 11 deployment stages (STS check → terraform → kubeconfig → ECR login → build/push → MongoDB/Redis wait → migrations → staged `kubectl apply` with rollout gates → Validator → one auto-retry) live in `scripts/deploy-all.ps1` and are invoked unchanged from CI; the YAML never duplicates orchestration logic.
