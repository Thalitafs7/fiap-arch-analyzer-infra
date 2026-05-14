# Consolidated Deployment Bugfix Design

## Overview

The Arch Analyzer stack today has six independent deployment surfaces (one infra `cd-main.yml` that runs Terraform only, plus five service-repo `cd-main.yml` workflows that each push one image and roll out one Deployment). A working orchestrator script (`scripts/deploy-all.ps1` / `deploy-all.sh`) exists in the infra repo but is reachable only from a developer workstation, so the project's CI/CD surface offers no single, infra-owned entry point that deploys all five services to AWS in dependency order with one shared image tag and one Validator report.

The fix introduces a new consolidated GitHub Actions workflow inside `fiap-arch-analyzer-infra` (`cd-deploy-all.yml`) whose only responsibility is to invoke the existing `scripts/deploy-all.ps1` / `deploy-all.sh` orchestrator on a GitHub-hosted runner, with `aws-actions/configure-aws-credentials@v4` configured from the existing `LabRole`-scoped session secrets. The workflow becomes the canonical CI path for full-stack deployment; the local script keeps its current semantics; the existing infra `cd-main.yml` keeps its Terraform-only behavior; and every service repo's `ci-*.yml` and `cd-main.yml` workflows are left untouched. The fix is therefore a wiring change, not a logic rewrite: the orchestration logic already lives in `scripts/deploy-all.ps1` and `scripts/deploy-all.config.yaml` and is reused as-is from CI.

The design honours AWS Academy constraints already enforced by the project: `LabRole` only (no new IAM principals), HTTP-only ALB, private subnets for RDS, USD 50–100 monthly budget (no new chargeable resources), CloudWatch alarms preserved, and the `infra-outputs` ConfigMap as the only channel through which service manifests consume Terraform outputs.

This design assumes the Academy Preconditions (AP-1 through AP-9, see next section) are already satisfied by the underlying platform at runtime. If any precondition does not hold, the consolidated workflow itself remains correct as wiring (the orchestration logic is sound), but the underlying platform must be remediated separately before Property 1 can pass — for example, an EKS cluster lacking the in-tree EBS provisioner, or an `aws-auth` ConfigMap that does not map `LabRole`, will break the deployment regardless of how the workflow is triggered.

## Glossary

- **Bug_Condition (C)**: The condition that triggers the bug — the operator's chosen `(trigger_repo, trigger_workflow)` pair does not orchestrate all five services to AWS through a single infra-owned entry point. Concretely: infra `cd-main.yml` (Terraform only), any service-repo `cd-main.yml` (one service only), or `scripts/deploy-all.ps1` invoked outside CI.
- **Property (P)**: The desired behavior when an operator wants the full stack on AWS — one trigger run on the infra repo SHALL execute the full 11-stage flow (STS check → Terraform → kubeconfig → ECR login → build/push → MongoDB/Redis wait → migrations → staged `kubectl apply` with rollout waits → Validator → one auto-retry), produce one shared image tag across all five services, write `./artifacts/validation-report-<timestamp>.{json,md}`, and exit non-zero on failure.
- **Preservation**: Behaviors that must remain identical before and after the fix — per-service `ci-develop.yml` / `ci-feature.yml` / `ci-release.yml`, per-service `cd-main.yml` (single-service hotfix path), infra `cd-main.yml` Terraform-only semantics, direct workstation invocation of `scripts/deploy-all.ps1`, the `infra-outputs` ConfigMap contract, AWS Academy constraints (LabRole, HTTP ALB, private RDS subnets, USD 50–100 budget), and existing CloudWatch alarms.
- **deploy-all.ps1 / deploy-all.sh**: The existing local orchestrator in `scripts/` of the infra repo, driven by `scripts/deploy-all.config.yaml`. Implements the 11-stage flow and the staged `kubectl apply` with `kubectl rollout status` gates.
- **deploy-all.config.yaml**: The single source of truth for service metadata — `services[].name`, `services[].ecr_key`, `services[].k8s_dir`, `services[].deployments[]`, and the stage order list `stages[]` (`[auth] → [registration, report, processing] → [api-gateway]`).
- **Shared image tag**: One identifier resolved exactly once per consolidated run, used to tag every service image pushed to ECR. Default value is `git rev-parse --short HEAD` evaluated against the infra repo's checked-out commit; overridable via `workflow_dispatch` input `image_tag`.
- **Validator**: The existing Python tool invoked at the end of `scripts/deploy-all.ps1` that probes `http://<alb_dns>/api/<service>/health` for every service and writes `./artifacts/validation-report-<timestamp>.json` and `./artifacts/validation-report-<timestamp>.md`.
- **LabRole**: The AWS Academy session role exposed via `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`. The only IAM principal allowed for any pipeline in this project.
- **infra-outputs ConfigMap**: The shared Kubernetes ConfigMap that publishes Terraform outputs (`eks_cluster_name`, `alb_dns_name`, `ecr_repository_urls`, `ecr_registry_url`, etc.) into the cluster for service manifests to consume via `envFrom: configMapRef` or `valueFrom: configMapKeyRef`.
- **ExpiredToken**: AWS STS error code returned when Academy session credentials lapse mid-run; must abort the orchestrator with a non-zero exit and a clear refresh prompt.

## Academy Preconditions

The consolidated workflow is a wiring layer; it does not provision the EKS cluster, IAM identities, networking, or in-cluster controllers. The preconditions below describe the platform invariants the workflow assumes are already true at runtime. Each is tied to specific items in the AWS Academy IAM/role/region/EKS limitations document (`aws-academy-limitacoes.md`). If any precondition is violated, Property 1's `validator_overall = true` and `idempotent_on_rerun` clauses can be trivially broken by an Academy-specific failure mode that the consolidated workflow has no authority to repair.

- **AP-1 ALB provisioning model**: The ALB referenced by `alb_dns_name` is provisioned by Terraform (`aws_lb` + `aws_lb_target_group` + `aws_lb_target_group_attachment` against the Service NodePort), NOT by the AWS Load Balancer Controller. Rationale: `iam:CreateOpenIDConnectProvider` is blocked by SCP (Academy doc §1.3.3, §4.1.1), so IRSA is structurally unviable and the ALB Controller cannot obtain its own identity. The Terraform-provisioned ALB inherits permissions from `LabRole`, which is the only viable path.

- **AP-2 Persistent volume provisioner**: MongoDB/Redis StatefulSets use either `emptyDir` volumes (ephemeral, accepted for lab scope) or the in-tree `kubernetes.io/aws-ebs` provisioner with EBS attach permissions inherited from `LabInstanceProfile`. The EBS CSI Driver via IRSA is NOT used. Rationale: Academy doc §4.1.3 — the EBS CSI Driver depends on IRSA, which is blocked; the in-tree provisioner is the only working option.

- **AP-3 Cluster autoscaling**: Cluster Autoscaler is NOT installed. HPA (preserved by Requirement 3.6) operates strictly within the fixed node-group capacity envelope (`maxReplicas` tuned to fit within Academy's 32 vCPU / 9-instance / 100 GB EBS ceiling per Academy doc §6.2). Rationale: Academy doc §4.1.3, §4.2.3 — Cluster Autoscaler needs IRSA to call EC2/Auto Scaling APIs, which it cannot obtain.

- **AP-4 Logging/observability identity**: Fluent Bit and Container Insights agents (referenced by Requirement 3.10) authenticate to CloudWatch via the EKS node IAM (`LabInstanceProfile` / `LabRole`-equivalent attached to nodes), NOT via IRSA-bound ServiceAccounts. Rationale: Academy doc §1.3.3 — IRSA is blocked. Operators MUST validate that `LabRole` carries CloudWatch Agent permissions before assuming Requirement 3.10 holds; if those permissions are missing, observability degrades to stdout-only logs without changing the consolidated workflow.

- **AP-5 Idempotency time-window**: Property 2.9's "idempotent on re-run with no code changes" holds within a single AWS Academy Learner Lab session. After a Lab reset (Academy doc §6.3), all session-created AWS resources are wiped; a subsequent `terraform apply` from the consolidated workflow correctly recreates them from declared state. This is Terraform-correct convergence, NOT a violation of idempotency, and Property 1's idempotency clause must be read with this scope.

- **AP-6 EKS `aws-auth` mapping**: The EKS cluster's `aws-auth` ConfigMap maps `LabRole` to `system:masters` (created during the Terraform bootstrap that provisioned the cluster). The consolidated workflow's `aws eks update-kubeconfig` step relies on this mapping; it does not create or modify `aws-auth`. Rationale: Academy doc §1.2.1, §5.2.2 — the official `terraform-aws-eks` module assumes `iam:CreateRole` and would fail; the project must therefore use a custom Terraform setup that hard-codes the `LabRole` ARN as the cluster owner from the start.

- **AP-7 Region constraint**: The workflow's `AWS_REGION` MUST be `us-east-1` (or `us-west-2`) per Academy doc §6.1. The design's mention of "hardcoded `us-east-1` per Academy default" stands; any other region as a workflow input is explicitly forbidden and the workflow MUST reject non-Academy regions before any mutating step.

- **AP-8 Budget baseline reality check**: The current monthly chargeable baseline (EKS control plane ~USD 73 + 1× NAT Gateway ~USD 32 + ALB ~USD 16 + ECR storage ~USD 1 + CloudWatch Logs ~USD 5–10) totals approximately USD 127–132/month, exceeding the USD 50–100 envelope referenced by Requirement 3.8. The consolidated workflow does NOT add chargeable resources, but the operator MUST be aware that the existing baseline already overspends. Mitigation paths (out of scope for this fix, listed only for traceability): replace NAT Gateway with VPC endpoints for S3/ECR (~USD 32 saving) or accept an operational ceiling of USD 150/month for full-stack runs.

- **AP-9 GitHub→AWS authentication mode**: The workflow uses long-lived GitHub repo secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) refreshed manually from each Learner Lab session. It does NOT use GitHub OIDC federation to AWS, because `iam:CreateOpenIDConnectProvider` and trust-policy edits on `LabRole` are blocked (Academy doc §1.3.3, §2.2.1). Operators MUST refresh the three secrets at the start of each Learner Lab session before triggering `cd-deploy-all.yml`.

## Bug Details

### Bug Condition

The bug manifests when an operator wants to deploy the full Arch Analyzer stack to AWS but the project's automation surface offers no single infra-owned entry point that drives all five services together. The available triggers each cover only a subset of the deployment: the infra `cd-main.yml` runs Terraform only, any service-repo `cd-main.yml` deploys exactly one service with that repo's own `github.sha` as image tag, and the local `scripts/deploy-all.ps1` orchestrator (which already implements the correct flow) is not wired to any CI workflow.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type DeploymentTrigger
         where DeploymentTrigger = (trigger_repo, trigger_workflow, intent)
         and intent IN { "deploy_full_stack", "deploy_single_service", "infra_only" }
  OUTPUT: boolean

  // Buggy = operator's intent is "deploy_full_stack" but the triggered
  // workflow does not orchestrate all five services to AWS through one
  // infra-owned entry point with shared image tag, stage ordering,
  // and one Validator report.
  RETURN input.intent = "deploy_full_stack"
         AND (
              (input.trigger_repo = "fiap-arch-analyzer-infra"
               AND input.trigger_workflow = "cd-main.yml"
               AND NOT orchestrates_all_services(input))
           OR (input.trigger_repo IN service_repos
               AND input.trigger_workflow = "cd-main.yml"
               AND deploys_only_one_service(input))
           OR (input.trigger_workflow = "scripts/deploy-all.ps1"
               AND NOT invoked_from_ci(input))
         )
END FUNCTION
```

### Examples

- **Counterexample 1 — infra `cd-main.yml`**: operator runs the only consolidated-looking entry point in the infra repo. Expected: all five Deployments rolled out with shared image tag and Validator report written. Actual: workflow stops after `terraform apply`; EKS cluster has zero service Deployments.
- **Counterexample 2 — service-repo `cd-main.yml` (api-gateway)**: operator pushes to `main` on `fiap-arch-analyzer-api-gateway`. Expected: full stack deployed in dependency order. Actual: only `api-gateway` is built and rolled out, possibly before `auth-service` is Ready, with image tagged from the api-gateway repo's `github.sha` rather than a shared tag.
- **Counterexample 3 — six manual triggers**: operator manually triggers infra `cd-main.yml` plus all five service `cd-main.yml` workflows. Expected: ordered, idempotent, validated rollout. Actual: arbitrary completion order across six pipelines, five distinct image tags from five different commits, no consolidated `validation-report-<timestamp>.{json,md}`, no shared `ExpiredToken` handling.
- **Edge case — local script run from workstation**: operator runs `scripts/deploy-all.ps1` directly. Expected: this path keeps working unchanged (preservation). Actual today: works correctly, but is not reachable from CI, so the project has no automated full-stack deployment surface.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Per-service `ci-develop.yml`, `ci-feature.yml`, and `ci-release.yml` workflows in every service repo continue to run unchanged for build, test, lint, and image scanning on `develop`, `feature/*`, and `release/*` branches.
- Per-service `cd-main.yml` workflows remain valid as a single-service hotfix path; pushing to `main` on one service repo continues to build, push, and roll out only that service.
- Infra `cd-main.yml` continues to run Terraform-only (`terraform init`, `terraform apply -auto-approve`) for infra-only changes and continues to emit the same Terraform outputs (`eks_cluster_name`, `alb_dns_name`, `ecr_repository_urls`, `ecr_registry_url`).
- `scripts/deploy-all.ps1` and `scripts/deploy-all.sh` invoked directly from a developer workstation continue to execute the documented 11-stage flow with identical exit codes and identical artifacts under `./artifacts/`.
- The `infra-outputs` ConfigMap remains the only channel through which Service_K8s_Folder manifests consume AWS Terraform outputs (`envFrom: configMapRef` or `valueFrom: configMapKeyRef`); no AWS values are embedded as string literals.
- All AWS Academy constraints stay enforced: `LabRole`-only authentication, no new IAM users/roles/policies, HTTP-only ALB, private subnets for RDS, S3 `BlockPublicAccess=true`, SQS/S3 `aws:SecureTransport=true`, USD 50–100 monthly budget, no new chargeable resources (no extra NAT Gateway, no additional ALB, no managed CI runners beyond GitHub-hosted).
- CloudWatch alarms (5xx rate, DLQ depth) and the existing observability stack (CloudWatch log groups, Fluent Bit, Container Insights, dashboard) keep collecting from every namespace independently of which entry point triggered the deployment.
- Per-service Deployment, Service, Ingress, HPA, and `securityContext` contracts defined by the existing `aws-academy-deployment` spec (Requirement 14) remain unchanged; no manifest schema or namespace assignment is altered by this fix.

**Scope:**
All inputs that do NOT involve `intent = "deploy_full_stack"` MUST be completely unaffected by this fix. This includes:
- Pushes to `develop`, `feature/*`, `release/*` branches in any repo.
- Pushes to `main` in a single service repo for a hotfix (single-service deployment).
- Infra-only Terraform changes triggered through `cd-main.yml` in the infra repo.
- Direct workstation invocations of `scripts/deploy-all.ps1` or `scripts/deploy-all.sh`.

The actual expected correct behavior for `intent = "deploy_full_stack"` is defined in the Correctness Properties section (Property 1).

## Hypothesized Root Cause

Based on the bug description and the current state of the repos, the most likely issues are:

1. **Missing CI Wiring for the Orchestrator**: The orchestration logic is already correct and complete in `scripts/deploy-all.ps1` and `scripts/deploy-all.config.yaml`, but no GitHub Actions workflow in `fiap-arch-analyzer-infra` invokes that script. The defect is therefore a missing workflow file (`.github/workflows/cd-deploy-all.yml`), not a missing logic component. Fix is wiring, not redesign.

2. **Per-Service `cd-main.yml` Triggering on `push: main`**: Each service repo's `cd-main.yml` runs on `push: main`, so any merge to `main` deploys that one service in isolation with its own `github.sha` as image tag. There is no mechanism to coordinate a stack-wide release from one commit. The consolidated workflow must compute one shared tag from the infra repo's `git rev-parse --short HEAD` and use it for every image regardless of which service repo's `main` last advanced.

3. **No Stage-Ordered `kubectl apply` in Infra `cd-main.yml`**: The infra `cd-main.yml` stops at `terraform apply`. It does not run `aws eks update-kubeconfig`, does not wait for `MongoDB`/`Redis` rollout, does not apply per-service manifests in dependency order, and does not invoke the Validator. The fix routes those steps through `scripts/deploy-all.ps1`, which already enforces the stage order `[auth] → [registration, report, processing] → [api-gateway]` with `kubectl rollout status` gates.

4. **No Shared `ExpiredToken` Handling Across Services**: When AWS Academy session credentials expire mid-deploy in any service-repo `cd-main.yml`, that one workflow fails in isolation, leaving the stack in an inconsistent state. The consolidated workflow centralises credential handling: `aws sts get-caller-identity` runs once before any mutating step, and any subsequent `ExpiredToken` aborts the whole run with a non-zero exit and a clear refresh prompt.

5. **No Single Validator Output**: With six independent pipelines, no single workflow can write a consolidated `./artifacts/validation-report-<timestamp>.{json,md}` covering all five services. Routing the Validator through the consolidated workflow gives one report per run and uploads it as a workflow artifact.

## Correctness Properties

Property 1: Bug Condition — Consolidated Full-Stack Deployment

_For any_ trigger where the bug condition holds (operator's intent is `deploy_full_stack`), the fixed system SHALL expose one infra-owned entry point (`.github/workflows/cd-deploy-all.yml` plus the existing `scripts/deploy-all.ps1` / `deploy-all.sh`) that, in a single run, executes `aws sts get-caller-identity`, `terraform init`, `terraform apply -auto-approve`, `aws eks update-kubeconfig`, ECR login, build-and-push of every service image with one shared tag, MongoDB/Redis readiness wait, staged `kubectl apply` honouring `[auth] → [registration, report, processing] → [api-gateway]` with `kubectl rollout status` gates, the Validator with one automatic retry on failure, and writes `./artifacts/validation-report-<timestamp>.{json,md}`; the run SHALL exit non-zero on any failure (including `ExpiredToken`) and SHALL be idempotent on re-execution with no code changes within a single Learner Lab session (zero Terraform drift, zero new pushed image digests, zero rollout changes — see AP-5 for the post-Lab-reset semantics).

**Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10**

Property 2: Preservation — Non-Consolidated Paths

_For any_ trigger where the bug condition does NOT hold (per-service `ci-*.yml` runs, single-service `cd-main.yml` hotfix, infra-only `cd-main.yml` Terraform run, direct workstation invocation of `scripts/deploy-all.ps1`), the fixed system SHALL produce exactly the same observable result as the original system, preserving every per-service CI workflow, the single-service hotfix path, the Terraform-only `cd-main.yml` semantics, the local orchestrator's exit codes and `./artifacts/` outputs, the `infra-outputs` ConfigMap contract, the `LabRole`-only authentication model, the HTTP-only ALB, the private RDS subnet topology, the USD 50–100 monthly budget surface, and the existing CloudWatch alarms and observability stack.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10**

## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct, the fix is concentrated in the infra repo and is purely additive at the CI surface; the orchestration logic is reused unchanged from `scripts/deploy-all.ps1`.

**File**: `.github/workflows/cd-deploy-all.yml` (new) in `fiap-arch-analyzer-infra`

**Function**: Consolidated full-stack deployment workflow that calls `scripts/deploy-all.ps1` (or `deploy-all.sh`) from a GitHub-hosted runner.

**Specific Changes**:

1. **New Workflow File `cd-deploy-all.yml`**: Add `.github/workflows/cd-deploy-all.yml` to the infra repo with `on: workflow_dispatch` only (no `push` trigger; consolidated deploys are deliberate). Declare a single input `image_tag` (string, optional, default empty → resolved to `git rev-parse --short HEAD`) so operators can override the shared tag for replays. Pin runner to `ubuntu-latest` (cheapest GitHub-hosted runner; no managed CI runners are added, preserving the budget). Job has `permissions: contents: read` only.

2. **AWS Credentials Step**: Add a step using `aws-actions/configure-aws-credentials@v4` reading from existing repo secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and `AWS_REGION` (or hardcoded `us-east-1` per Academy default; non-Academy regions are rejected per AP-7). No new IAM principals; the workflow inherits `LabRole` session credentials. GitHub OIDC federation to AWS is explicitly NOT used (cross-reference AP-9): `iam:CreateOpenIDConnectProvider` and trust-policy edits on `LabRole` are blocked by Academy SCPs, so the only viable authentication mode is long-lived repo secrets carrying the Learner Lab session token. Operators MUST refresh `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` at the start of each Learner Lab session before re-triggering this workflow. Immediately follow the credential configuration with `aws sts get-caller-identity` as a fail-fast credential probe; any `ExpiredToken` here aborts the run before any mutating step with a clear "refresh Learner Lab credentials" message.

3. **Shared Image Tag Resolution**: Add a step that resolves the shared tag once: if `inputs.image_tag` is non-empty use it verbatim, otherwise compute `git rev-parse --short HEAD` against the checked-out infra commit. Export the value as `IMAGE_TAG` in `$GITHUB_ENV` and pass it explicitly to `scripts/deploy-all.ps1` so every service image pushed in this run carries the same tag. The same value is echoed at the top of the run log for traceability.

4. **Sibling Service Repo Checkouts**: Add `actions/checkout@v4` steps that clone each of the five service repos (`fiap-arch-analyzer-auth-service`, `fiap-arch-analyzer-registration-service`, `fiap-arch-analyzer-processing-service`, `fiap-arch-analyzer-report-service`, `fiap-arch-analyzer-api-gateway`) into the workspace alongside the infra repo, matching the directory layout `scripts/deploy-all.config.yaml` already expects (`../<repo>`). Use `ref: main` by default; expose an optional `service_ref` input later if needed (out of scope for this fix). Use the default `GITHUB_TOKEN` if repos are in the same org; otherwise document the required `SERVICES_CHECKOUT_TOKEN` PAT in the workflow file (no new secrets are mandated by this fix; if the repos are public the default token suffices).

5. **Toolchain Setup**: Add steps to install the toolchain `scripts/deploy-all.ps1` already requires: `terraform` (matching the version pinned in `.terraform.lock.hcl`), `kubectl`, `aws` CLI, Docker (preinstalled on `ubuntu-latest`), and PowerShell Core (preinstalled on `ubuntu-latest`). All are free, pre-baked tooling on GitHub-hosted runners; no chargeable resources are added.

6. **Orchestrator Invocation**: Add the single mutating step `pwsh -File ./scripts/deploy-all.ps1 -ImageTag $env:IMAGE_TAG` (or the equivalent `bash ./scripts/deploy-all.sh "$IMAGE_TAG"` if Linux runners cannot run pwsh reliably; both scripts share `scripts/deploy-all.config.yaml`). The script internally enforces the stage order `[auth] → [registration, report, processing] → [api-gateway]` with `kubectl rollout status` gates and runs the Validator with one automatic retry. No deployment logic is duplicated in YAML.

7. **`ExpiredToken` Handling**: The orchestrator already detects `ExpiredToken` from any AWS CLI / `kubectl`/`terraform` step and exits non-zero with a refresh-credentials message. The workflow surfaces the script's exit code as the job's exit code (default `pwsh` / `bash` behavior with `set -e` style); on non-zero exit the workflow run is marked failed and the operator is prompted (via the workflow run log) to refresh `LabRole` credentials in repo secrets and re-trigger.

8. **Artifact Upload**: Add a final `actions/upload-artifact@v4` step (always-run, `if: always()`) that uploads `./artifacts/validation-report-<timestamp>.json` and `./artifacts/validation-report-<timestamp>.md` produced by the Validator. Retention defaults to 90 days (free) and stays well under the budget surface.

9. **Idempotency Guarantees (No New Code, Documentation Only)**: The orchestrator already produces idempotent runs because Terraform converges to declared state, ECR `docker push` of an unchanged image yields no new digest, and `kubectl apply` is a no-op when the live object matches the manifest. Document this contract in the workflow file's header comment so operators know that re-running with no code changes is safe and that it is the canonical idempotency check.

10. **Explicit Non-Changes (Preservation Boundary)**: Do NOT modify `cd-main.yml` in the infra repo (Terraform-only behavior preserved). Do NOT modify any `ci-*.yml` or `cd-main.yml` in any service repo (single-service hotfix path preserved). Do NOT modify `scripts/deploy-all.ps1`, `scripts/deploy-all.sh`, or `scripts/deploy-all.config.yaml` (local orchestrator semantics preserved); the only adjustment, if needed, is to make `-ImageTag` an accepted parameter — already supported per the script's contract. Do NOT introduce new IAM, new ALBs, NAT Gateways, managed runners, or any chargeable AWS resource. Do NOT install or rely on AWS Load Balancer Controller (AP-1), EBS CSI Driver via IRSA (AP-2), Cluster Autoscaler (AP-3), or any IRSA-bound ServiceAccount (AP-4, AP-9). Do NOT change the EKS `aws-auth` mapping (AP-6) or the AWS region (AP-7).

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bug on the unfixed CI surface, then verify the new consolidated workflow produces the expected end-state and preserves every non-consolidated path.

Because the primary subject under test is a GitHub Actions workflow that mutates real AWS state, "exploratory" and "fix checking" tests are framed as recorded workflow runs against the Academy account, with their `validation-report-<timestamp>.{json,md}` artifacts as evidence. Preservation is checked partly with property-based tests over the orchestrator's pure decision logic (stage ordering, image tag resolution, bug-condition classification of triggers) and partly with observed runs of the unchanged workflows.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bug BEFORE implementing the fix. Confirm or refute the hypothesised root causes (missing CI wiring for the orchestrator, per-service `cd-main.yml` triggering in isolation, no stage-ordered apply in infra `cd-main.yml`, no shared `ExpiredToken` handling, no single Validator output). If any hypothesis is refuted, re-hypothesize before writing the workflow.

**Test Plan**: On the unfixed repos, trigger each existing entry point with the operator intent `deploy_full_stack`. Capture the resulting AWS state (Deployments rolled out, image tags pushed, Validator reports written) and compare against Property 1's expectations. These tests are expected to fail on the unfixed code; their failures are the counterexamples that justify the fix.

**Test Cases**:
1. **Infra `cd-main.yml` Run**: Trigger infra `cd-main.yml` and observe that no service Deployments are rolled out and no Validator report is written (will fail on unfixed code).
2. **Single Service `cd-main.yml` Run**: Push a no-op commit to `main` in one service repo and observe that only that service is deployed, with no shared tag and no stage ordering against the other four (will fail on unfixed code).
3. **Six-Pipeline Manual Run**: Manually trigger all six pipelines and observe arbitrary completion order, five distinct image tags, and zero consolidated `validation-report-<timestamp>.{json,md}` (will fail on unfixed code).
4. **Edge Case — Expired Credentials Mid-Run**: Force an `ExpiredToken` mid-run in a service-repo `cd-main.yml` and observe that other in-flight pipelines continue independently, leaving the stack inconsistent (may fail on unfixed code; demonstrates lack of shared credential gating).

**Expected Counterexamples**:
- Zero service Deployments after infra `cd-main.yml` finishes successfully.
- Possible causes: workflow stops at `terraform apply`; orchestrator script not invoked from CI; per-service workflows run in isolation with their own `github.sha` as image tag; no shared `aws sts get-caller-identity` gate.

### Fix Checking

**Goal**: Verify that for all inputs where the bug condition holds (`intent = "deploy_full_stack"`), the consolidated workflow produces the expected end-state (Property 1).

**Pseudocode:**
```
FOR ALL input WHERE isBugCondition(input) DO
  result := runConsolidatedWorkflow(input)
  ASSERT result.terraform_applied = true
     AND result.images_pushed_count = 5
     AND result.shared_image_tag_used = true
     AND result.stage_order_respected = true
            // [auth] → [registration, report, processing] → [api-gateway]
     AND result.rollout_status_gated_per_stage = true
     AND result.validator_report_written = true
            // ./artifacts/validation-report-<timestamp>.{json,md}
     AND (result.validator_overall = true OR result.exit_code <> 0)
     AND result.idempotent_on_rerun = true
            // zero terraform drift, zero new digests, zero rollout changes
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug condition does NOT hold (per-service CI runs, single-service hotfix `cd-main.yml`, infra-only `cd-main.yml`, direct workstation invocation of `scripts/deploy-all.ps1`), the fixed system produces exactly the same result as the original system.

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT runOriginal(input) = runFixed(input)
  // includes:
  //   service ci-develop.yml / ci-feature.yml / ci-release.yml runs
  //   single-service cd-main.yml hotfix
  //   infra-only cd-main.yml (terraform apply)
  //   direct scripts/deploy-all.ps1 from workstation
END FOR
```

**Testing Approach**: Property-based testing is recommended for preservation checking because:
- It generates many `(trigger_repo, trigger_workflow, intent)` tuples and confirms the bug-condition classifier routes correctly (only `intent = "deploy_full_stack"` paths through the consolidated workflow; everything else short-circuits to its original path).
- It catches edge cases in the orchestrator's pure decision logic (stage ordering against arbitrary `services[]` permutations from `deploy-all.config.yaml`, shared-tag resolution under empty/non-empty `inputs.image_tag`).
- It provides strong guarantees that non-consolidated paths are untouched, even for tuples a human would not enumerate.

**Test Plan**: Observe behavior on the unfixed code first for each non-bug input class, then write property-based tests over the orchestrator's pure helpers (stage-order computation, image-tag resolution, bug-condition predicate) capturing that behavior. Property tests live in the existing `tests/` Hypothesis suite of the infra repo (`.hypothesis/` already present).

**Test Cases**:
1. **Per-Service CI Preservation**: Observe `ci-develop.yml`, `ci-feature.yml`, `ci-release.yml` runs on each service repo before the fix; assert via re-runs after the fix that build, test, lint, and image-scan steps and their exit codes are identical.
2. **Single-Service `cd-main.yml` Hotfix Preservation**: Observe a single push-to-`main` deploy on one service repo before the fix; re-run after the fix and assert the same single Deployment is rolled out with the same image tag scheme (`github.sha` of that service repo, not the shared infra tag).
3. **Infra-Only `cd-main.yml` Preservation**: Observe an infra-only Terraform change run before the fix; re-run after the fix and assert the same Terraform plan/apply, the same outputs (`eks_cluster_name`, `alb_dns_name`, `ecr_repository_urls`, `ecr_registry_url`), and that no service rollout was triggered.
4. **Direct Workstation `deploy-all.ps1` Preservation**: Observe a local `scripts/deploy-all.ps1` run before the fix; re-run after the fix and assert identical 11-stage exit codes, identical `./artifacts/` contents (modulo timestamp), and identical AWS end-state.
5. **Budget and Security Preservation**: After a consolidated run, assert no new IAM principals exist (`aws iam list-roles | grep -v LabRole` is empty for new roles), no new ALBs/NAT Gateways are billed, S3 `BlockPublicAccess` and SQS/S3 `aws:SecureTransport` policies are unchanged, and CloudWatch alarms (5xx rate, DLQ depth) are still bound to their original metrics.

### Unit Tests

- Unit-test the `image_tag` resolution helper: empty input → `git rev-parse --short HEAD`; non-empty input → value verbatim; invalid input (whitespace, control chars) → reject with non-zero exit before any mutation.
- Unit-test the `isBugCondition(input)` predicate against the full enumeration of `(trigger_repo, trigger_workflow, intent)` tuples derived from the bugfix doc; assert it matches the truth table in `bugfix.md`.
- Unit-test the stage-order computation over `scripts/deploy-all.config.yaml` `stages[]`: `[auth]` first, `{registration, report, processing}` second (any internal order accepted), `[api-gateway]` last; reject any config where `api-gateway` precedes `auth-service`.
- Unit-test that `aws sts get-caller-identity` failure (simulated `ExpiredToken`) aborts the run before any mutating step; assert non-zero exit and the refresh-credentials message in stderr.

### Property-Based Tests

- Generate random `(trigger_repo, trigger_workflow, intent)` tuples (drawing `trigger_repo` from `{infra} ∪ service_repos`, `trigger_workflow` from the actual workflow files in each repo, and `intent` from `{deploy_full_stack, deploy_single_service, infra_only}`); assert `isBugCondition` classifies them according to Property 1 / Property 2.
- Generate random `services[]` permutations from `deploy-all.config.yaml` and assert the staged-apply planner always emits an order that satisfies `auth ≺ {registration, report, processing} ≺ api-gateway`, regardless of input ordering.
- Generate random `image_tag` inputs (empty, valid short SHAs, invalid strings) and assert the resolver produces a deterministic, replayable tag without mutation on rejection.
- Generate two consecutive runs with identical inputs and assert idempotency: same Terraform plan (zero changes), same ECR digests (zero new pushes), same `kubectl apply` outcome (zero rollout changes).

### Integration Tests

- Full consolidated run end-to-end against the Academy account: trigger `cd-deploy-all.yml`, capture `validation-report-<timestamp>.{json,md}`, assert all five `/api/<service>/health` endpoints return `200` through the HTTP ALB and the report's `overall` is `true`.
- Stage-ordering integration test: instrument `scripts/deploy-all.ps1` (temporarily, via debug logging only) to record per-stage start times in a single consolidated run; assert `auth-service` `Ready` precedes the start of `{registration, report, processing}`, which all precede `api-gateway`.
- Validator-retry integration test: deliberately publish a broken `auth-service` image once, run the consolidated workflow, and assert that the Validator retries exactly once (pod restart or ConfigMap re-apply), then exits non-zero with a clear failure summary in the report.
- Idempotency integration test: run `cd-deploy-all.yml` twice back-to-back with no code changes; assert the second run reports zero Terraform drift, zero new ECR digests, zero rollout changes, and an unchanged `validation-report-<timestamp>` (modulo timestamp filename).
- Single-service hotfix integration test (preservation): merge a no-op change to `main` in one service repo, observe that only that service's `cd-main.yml` runs, only that service rolls out, and `cd-deploy-all.yml` is not triggered — confirming the consolidated path does not become the only path.
