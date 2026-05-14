# Bugfix Requirements Document

## Introduction

The Arch Analyzer stack is composed of one infrastructure repo (`fiap-arch-analyzer-infra`) and five service repos (`api-gateway`, `auth-service`, `registration-service`, `processing-service`, `report-service`). Today there is no consolidated deployment path that brings the whole stack to AWS through the infrastructure project: the infra `cd-main.yml` workflow only runs `terraform apply`, and every service repo carries its own independent `cd-main.yml` that builds, pushes, and rolls out one Deployment in isolation. As a consequence, deploying the full system requires triggering at least six unrelated pipelines, in an undefined order, with no shared image tag, no shared dependency ordering (auth → {registration, report, processing} → api-gateway), and no end-to-end Validator run.

A working orchestrator already exists locally as `scripts/deploy-all.ps1` / `deploy-all.sh` driven by `scripts/deploy-all.config.yaml`, but it is not wired into any CI/CD entry point owned by the infra repo, so the consolidated deployment is unreachable from the project's automation surface. This bugfix treats the absence of a single, infra-owned, consolidated deployment entry point that drives all five services simultaneously to AWS as the defect to fix, while preserving the existing local script, the existing service-level CI workflows used for build/test, and the existing Terraform-only `terraform apply` flow.

The fix follows the same AWS Academy constraints already adopted by the infra project: reuse of `LabRole` (no new IAM), HTTP-only ALB, EKS-only data plane, USD 50–100 monthly budget, and the Well-Architected operational pillars (least privilege, observability, cost awareness, IaC).

## Bug Analysis

### Current Behavior (Defect)

When an operator wants to deploy the Arch Analyzer stack to AWS through the infrastructure project, the project does not expose a single orchestrated entry point that drives all services together; the existing infra CD pipeline only manages Terraform, and each service repo deploys independently with no shared ordering, image tag, or end-to-end validation.

1.1 WHEN an operator triggers `.github/workflows/cd-main.yml` in `fiap-arch-analyzer-infra` THEN the system runs only `terraform init` and `terraform apply` and does not build, push, or roll out any of the five service images, leaving the EKS cluster without the application workloads.

1.2 WHEN the operator wants to deploy all five services to AWS in one action through the infra project THEN the system requires the operator to manually trigger at least five independent service-repo `cd-main.yml` workflows (api-gateway, auth-service, registration-service, processing-service, report-service) instead of a single consolidated entry point owned by the infra repo.

1.3 WHEN multiple service-repo CD workflows run on `push: main` THEN the system applies their Kubernetes manifests in arbitrary order with no enforced stage dependency between `auth-service`, `{registration-service, report-service, processing-service}`, and `api-gateway`, so api-gateway and dependent services may roll out before `auth-service` is Ready.

1.4 WHEN service-repo CD workflows run independently THEN the system tags each service image with that repo's own `github.sha`, producing a stack whose images come from different commits and cannot be traced to a single release.

1.5 WHEN the consolidated local script `scripts/deploy-all.ps1` exists in the infra repo THEN the system does not invoke it from any infra-owned CI/CD workflow, so the orchestrated path (Terraform → ECR build/push → staged kubectl apply → Validator with retry) is reachable only from a developer workstation.

1.6 WHEN the infra `cd-main.yml` `terraform apply` step finishes successfully THEN the system does not run `aws eks update-kubeconfig`, does not wait for `MongoDB`/`Redis` rollout, does not apply per-service manifests, and does not invoke the Validator, so post-apply the stack is structurally unfinished.

1.7 WHEN service repos deploy independently to EKS THEN the system has no place to write a consolidated `./artifacts/validation-report-<timestamp>.{json,md}` covering all services in a single run, so end-to-end deployment success is not observable from one report.

1.8 WHEN AWS Academy session credentials expire mid-deployment in any single service-repo workflow THEN the system has no shared `ExpiredToken` handling across services, so partial deploys leave the stack in an inconsistent state with no single rollback point.

### Expected Behavior (Correct)

The infrastructure project SHALL own and expose one consolidated deployment entry point that drives all five services to AWS in a single run, in dependency order, with one shared image tag, one Validator report, and one shared credential check, while still allowing service repos to build their own images on their own pipelines for non-deployment purposes.

2.1 WHEN an operator triggers the consolidated deployment entry point in `fiap-arch-analyzer-infra` (a `workflow_dispatch` GitHub Actions workflow plus the existing local `scripts/deploy-all.ps1` / `deploy-all.sh`) THEN the system SHALL execute, in order, `aws sts get-caller-identity`, `terraform init`, `terraform apply -auto-approve`, `aws eks update-kubeconfig`, ECR login, build-and-push of every service image, MongoDB/Redis readiness wait, staged `kubectl apply` of every Service_K8s_Folder, and the Validator, returning a non-zero exit only on failure.

2.2 WHEN the operator wants to deploy all five services simultaneously to AWS THEN the system SHALL accept a single trigger on the infra repo (one CI workflow run or one local script invocation) and SHALL NOT require the operator to trigger any service-repo workflow.

2.3 WHEN the consolidated entry point applies per-service manifests THEN the system SHALL honour the stage order `[auth-service] → [registration-service, report-service, processing-service] → [api-gateway]`, blocking on `kubectl rollout status` for every Deployment listed in `scripts/deploy-all.config.yaml` `services[].deployments[]` of the previous stage before starting the next.

2.4 WHEN the consolidated entry point builds service images THEN the system SHALL tag every image with one shared identifier resolved once per run (the infra repo's `git rev-parse --short HEAD`, overridable via input parameter), and SHALL push each image to the ECR repository URL resolved from the `ecr_key` declared for that service in `scripts/deploy-all.config.yaml`.

2.5 WHEN the consolidated CI workflow runs in `fiap-arch-analyzer-infra` THEN the system SHALL invoke `scripts/deploy-all.ps1` (or `deploy-all.sh` on Linux runners) so that the CI path and the local path share one orchestrator implementation.

2.6 WHEN the consolidated entry point finishes applying manifests THEN the system SHALL invoke the Validator and SHALL write `./artifacts/validation-report-<timestamp>.json` and `./artifacts/validation-report-<timestamp>.md` covering all five services through `http://<alb_dns>/api/<service>/health`.

2.7 WHEN the Validator reports at least one failing service THEN the system SHALL execute exactly one automatic retry (pod restart or ConfigMap re-apply) and re-run the Validator before exiting with a non-zero status.

2.8 IF AWS credentials return an `ExpiredToken` error at any stage of the consolidated entry point THEN the system SHALL stop, log the error, prompt the operator to refresh Learner_Lab credentials, and exit with a non-zero status before further state mutation.

2.9 WHEN the consolidated entry point completes successfully and is re-executed with no code changes THEN the system SHALL produce zero Terraform drift, zero new pushed image digests, and zero Kubernetes rollout changes (idempotent re-run).

2.10 WHEN the consolidated CI workflow runs THEN the system SHALL configure AWS credentials via `aws-actions/configure-aws-credentials@v4` using the existing `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` GitHub secrets already used by service workflows, and SHALL NOT introduce new IAM users, roles, or principals beyond `LabRole`.

### Unchanged Behavior (Regression Prevention)

The fix SHALL preserve every behavior that does not depend on consolidation, including service-level CI for build/test, the existing local orchestrator semantics, the Terraform-only `cd-main.yml` semantics for infra-only changes, and all AWS Academy / Well-Architected constraints already encoded in the project.

3.1 WHEN a developer pushes to `develop`, `feature/*`, or `release/*` branches in any service repo THEN the system SHALL CONTINUE TO run that repo's `ci-develop.yml`, `ci-feature.yml`, or `ci-release.yml` workflows unchanged for build, test, lint, and image scanning.

3.2 WHEN an operator runs `scripts/deploy-all.ps1` or `scripts/deploy-all.sh` directly on a workstation against the existing `scripts/deploy-all.config.yaml` THEN the system SHALL CONTINUE TO execute the documented 11-stage flow (path validation, STS check, terraform init/apply, kubeconfig, ECR login, build/push, MongoDB/Redis wait, migrations, staged kubectl apply with rollout waits, Validator, one auto-retry) with the same exit codes and the same artifacts under `./artifacts/`.

3.3 WHEN an operator runs only `terraform apply` from the infra repo root for an infra-only change (no service image rebuild needed) THEN the system SHALL CONTINUE TO converge AWS resources without requiring the consolidated entry point and SHALL CONTINUE TO produce the same Terraform outputs (`eks_cluster_name`, `alb_dns_name`, `ecr_repository_urls`, `ecr_registry_url`, etc.).

3.4 WHEN service-repo manifests in any Service_K8s_Folder reference AWS Terraform outputs THEN the system SHALL CONTINUE TO consume them exclusively through the shared `infra-outputs` ConfigMap via `envFrom: configMapRef` or `valueFrom: configMapKeyRef`, and SHALL NOT embed AWS values as string literals (Requirement 14.13 of the existing `aws-academy-deployment` spec is preserved).

3.5 WHEN any pipeline (consolidated or per-service) authenticates to AWS THEN the system SHALL CONTINUE TO use only `LabRole`-derived session credentials, with no new IAM roles, users, or `AdministratorAccess` / wildcard policies introduced by this fix.

3.6 WHEN the existing `aws-academy-deployment` spec defines the per-service Deployment, Service, Ingress, HPA, and `securityContext` contracts (Requirement 14) THEN the system SHALL CONTINUE TO satisfy them; no Service_K8s_Folder manifest schema or namespace assignment changes as part of this fix.

3.7 WHEN the existing security contracts apply (no `0.0.0.0/0` ingress except ALB:80, no public subnets for RDS, S3 buckets `BlockPublicAccess=true`, SQS/S3 `aws:SecureTransport=true`, CloudWatch alarms on 5xx and DLQ depth) THEN the system SHALL CONTINUE TO enforce them; the consolidated entry point SHALL NOT relax any security group, bucket policy, or alarm.

3.8 WHEN the cost surface of the stack is measured THEN the system SHALL CONTINUE TO operate within the USD 50–100/month Academy_Budget; the consolidated entry point SHALL NOT add new chargeable AWS resources (no extra NAT Gateway, no additional ALB, no managed CI runners beyond the GitHub-hosted runners already in use).

3.9 WHEN the operator chooses to deploy only one service for a hotfix using that service's own `cd-main.yml` THEN the system SHALL CONTINUE TO support that flow as a fallback; the consolidated entry point SHALL NOT be the only path to deploy a service to AWS.

3.10 WHEN the existing observability stack runs (CloudWatch log groups, Fluent Bit, Container Insights, alarms, dashboard) THEN the system SHALL CONTINUE TO collect logs, metrics, and traces from every namespace independently of which entry point triggered the deployment.

## Bug Condition (Methodology)

The fix targets a single bug condition `C(X)` over the input space `X = (trigger_repo, trigger_workflow)` of "what an operator runs to deploy the stack to AWS".

```pascal
FUNCTION isBugCondition(X)
  INPUT: X = (trigger_repo, trigger_workflow)
  OUTPUT: boolean

  // Buggy = operator wants the full stack on AWS but no single infra-owned
  //         entry point drives all services; today only one of these is true:
  //           (a) trigger is infra/cd-main.yml  → Terraform only, no services
  //           (b) trigger is service-repo cd-main.yml → one service only
  //           (c) trigger is local scripts/deploy-all.* → orchestrated but
  //               not reachable from the project's CI surface
  RETURN (X.trigger_repo = "fiap-arch-analyzer-infra"
          AND X.trigger_workflow = "cd-main.yml"
          AND not_orchestrates_services(X))
      OR (X.trigger_repo IN service_repos
          AND X.trigger_workflow = "cd-main.yml"
          AND deploys_only_one_service(X))
      OR (X.trigger_workflow = "scripts/deploy-all.ps1"
          AND not_invoked_from_ci(X))
END FUNCTION
```

```pascal
// Property: Fix Checking — consolidated deployment
FOR ALL X WHERE isBugCondition(X) DO
  result ← deployStack'(X)
  ASSERT result.terraform_applied = true
     AND result.images_pushed_count = 5
     AND result.stage_order_respected = true   // auth → {reg, report, proc} → gateway
     AND result.shared_image_tag = true        // one git_sha across all 5
     AND result.validator_report_written = true
     AND (result.validator_overall = true OR result.exit_code <> 0)
     AND result.idempotent_on_rerun = true
END FOR
```

```pascal
// Property: Preservation Checking — non-consolidated paths
FOR ALL X WHERE NOT isBugCondition(X) DO
  ASSERT deployStack(X) = deployStack'(X)
  // i.e. service ci-develop/ci-feature/ci-release, infra-only terraform apply,
  // single-service hotfix via service cd-main.yml, and direct
  // scripts/deploy-all.ps1 from a workstation all behave identically before
  // and after the fix.
END FOR
```

**Counterexample (today, before fix):**
`X = (trigger_repo="fiap-arch-analyzer-infra", trigger_workflow="cd-main.yml")` — operator runs the only consolidated-looking entry point in the infra repo and the EKS cluster ends up with zero of the five service Deployments rolled out, because the workflow stops after `terraform apply`.
