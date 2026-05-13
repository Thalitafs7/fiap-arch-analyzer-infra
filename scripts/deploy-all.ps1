#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Deployment_Orchestrator for the Arch Analyzer stack on AWS Academy EKS.

.DESCRIPTION
    Single idempotent entry point that:
      1. Validates repo paths and k8s dirs exist on disk (Req 15.2)
      2. Verifies AWS credentials via sts get-caller-identity (Req 15.3)
      3. Runs terraform init + apply (Req 15.4)
      4. Updates kubeconfig from eks_cluster_name TF output (Req 15.5)
      5. Builds and pushes each service image tagged with git short SHA (Req 15.6)
      6. Waits for MongoDB and Redis rollout before per-service apply (Req 15.7)
      7. Applies per-service manifests (kustomize preferred, else -f) (Req 15.8)
      8. Honors stage order auth → {reg,report,proc} → api-gateway (Req 15.9/15.10)
      9. Invokes Validator and writes report to ./artifacts/ (Req 15.11)
     10. One automatic retry on Validator failure (Req 15.12)
     11. Stops on ExpiredToken with user prompt (Req 15.13)
     12. Idempotent re-runs produce zero drift (Req 15.14)

.PARAMETER ConfigPath
    Path to deploy-all.config.yaml. Defaults to $PSScriptRoot/deploy-all.config.yaml.

.PARAMETER DryRun
    Print commands without executing them.

.PARAMETER GitSha
    Override the git short SHA used for image tags.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot/deploy-all.config.yaml",
    [switch]$DryRun,
    [string]$GitSha = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────────────────── Helpers ────────────────────────────────────────────────────────────────

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Info([string]$msg) {
    Write-Host "    $msg" -ForegroundColor White
}

function Write-Success([string]$msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Write-Fail([string]$msg) {
    Write-Host "    [FAIL] $msg" -ForegroundColor Red
}

# Run a command; on ExpiredToken error stop and prompt user (Req 15.13)
function Invoke-Cmd {
    param(
        [string[]]$Cmd,
        [string]$WorkDir = $PWD,
        [switch]$CaptureOutput
    )
    $cmdStr = $Cmd -join " "
    if ($DryRun) {
        Write-Info "[DRY-RUN] $cmdStr"
        return ""
    }
    Write-Info "$ $cmdStr"
    $result = $null
    try {
        Push-Location $WorkDir
        if ($CaptureOutput) {
            $result = & $Cmd[0] $Cmd[1..($Cmd.Length - 1)] 2>&1
            $exitCode = $LASTEXITCODE
        } else {
            & $Cmd[0] $Cmd[1..($Cmd.Length - 1)]
            $exitCode = $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }

    $outputStr = if ($result) { $result | Out-String } else { "" }

    # Req 15.13 — detect ExpiredToken
    if ($outputStr -match "ExpiredToken" -or $outputStr -match "ExpiredTokenException") {
        Write-Fail "AWS credentials have expired (ExpiredToken)."
        Write-Host ""
        Write-Host "  ACTION REQUIRED: Refresh your AWS Academy Learner Lab credentials." -ForegroundColor Yellow
        Write-Host "  1. Open the Learner Lab console and click 'Start Lab'." -ForegroundColor Yellow
        Write-Host "  2. Copy the new credentials into ~/.aws/credentials (or set env vars)." -ForegroundColor Yellow
        Write-Host "  3. Re-run this script." -ForegroundColor Yellow
        exit 1
    }

    if ($exitCode -ne 0) {
        throw "Command failed (exit $exitCode): $cmdStr`n$outputStr"
    }

    return $outputStr.Trim()
}

# Parse YAML with PowerShell (no external dependency required for simple flat/list YAML)
# Uses a minimal parser sufficient for deploy-all.config.yaml structure.
function ConvertFrom-SimpleYaml([string]$Path) {
    # Delegate to python if available (most reliable), else use yq/powershell-yaml
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if ($python) {
        $script = @'
import sys, yaml, json
with open(sys.argv[1]) as f:
    print(json.dumps(yaml.safe_load(f)))
'@
        $tmpScript = [System.IO.Path]::GetTempFileName() + ".py"
        Set-Content -Path $tmpScript -Value $script -Encoding UTF8
        try {
            $json = & $python.Source $tmpScript $Path 2>&1
            if ($LASTEXITCODE -eq 0) { return $json | ConvertFrom-Json }
        } finally {
            Remove-Item $tmpScript -ErrorAction SilentlyContinue
        }
    }

    # Fallback: yq
    $yq = Get-Command yq -ErrorAction SilentlyContinue
    if ($yq) {
        $json = & yq -o=json $Path 2>&1
        if ($LASTEXITCODE -eq 0) { return $json | ConvertFrom-Json }
    }

    throw "Cannot parse YAML: install python3 (with pyyaml) or yq."
}

function Get-TerraformOutput([string]$Key) {
    $raw = Invoke-Cmd -Cmd @("terraform", "output", "-raw", $Key) -CaptureOutput
    return $raw
}

function Get-TerraformOutputJson([string]$Key) {
    $raw = Invoke-Cmd -Cmd @("terraform", "output", "-json", $Key) -CaptureOutput
    return $raw | ConvertFrom-Json
}

function Wait-KubectlRollout([string]$Namespace, [string]$Deployment, [string]$Timeout = "5m") {
    Write-Info "Waiting for rollout: deployment/$Deployment -n $Namespace (timeout $Timeout)"
    Invoke-Cmd -Cmd @("kubectl", "rollout", "status", "deployment/$Deployment",
        "-n", $Namespace, "--timeout=$Timeout")
}

function Wait-KubectlStatefulSet([string]$Namespace, [string]$StatefulSet, [string]$Timeout = "5m") {
    Write-Info "Waiting for rollout: statefulset/$StatefulSet -n $Namespace (timeout $Timeout)"
    Invoke-Cmd -Cmd @("kubectl", "rollout", "status", "statefulset/$StatefulSet",
        "-n", $Namespace, "--timeout=$Timeout")
}

# ──────────────────────────────────────────────────────────────────────────── Stage 0: Load config ────────────────────────────────────────────────────

Write-Step "Loading orchestrator config: $ConfigPath"
if (-not (Test-Path $ConfigPath)) {
    Write-Fail "Config file not found: $ConfigPath"
    exit 1
}
$cfg = ConvertFrom-SimpleYaml -Path $ConfigPath
Write-Success "Config loaded ($(($cfg.services | Measure-Object).Count) services)"

# ──────────────────────────────────────────────────────────────────────────── Stage 1: Validate paths (Req 15.2) ─────────────────────────────────────

Write-Step "Validating repo paths and k8s directories (Req 15.2)"
$infraRoot = Split-Path $PSScriptRoot -Parent
$missingPaths = @()

foreach ($svc in $cfg.services) {
    $repoAbs = if ([System.IO.Path]::IsPathRooted($svc.repo_path)) {
        $svc.repo_path
    } else {
        Join-Path $infraRoot $svc.repo_path
    }
    $k8sDir = if ($svc.k8s_dir) { $svc.k8s_dir } else { "k8s" }
    $k8sAbs = Join-Path $repoAbs $k8sDir

    if (-not (Test-Path $repoAbs -PathType Container)) {
        $missingPaths += "repo_path missing: $repoAbs (service: $($svc.name))"
    }
    if (-not (Test-Path $k8sAbs -PathType Container)) {
        $missingPaths += "k8s_dir missing: $k8sAbs (service: $($svc.name))"
    }
}

if ($missingPaths.Count -gt 0) {
    Write-Fail "Path validation failed:"
    $missingPaths | ForEach-Object { Write-Fail "  $_" }
    exit 1
}
Write-Success "All repo paths and k8s dirs exist"

# ──────────────────────────────────────────────────────────────────────────── Stage 2: Verify AWS credentials (Req 15.3) ──────────────────────────────

Write-Step "Verifying AWS credentials (Req 15.3)"
$callerIdentity = Invoke-Cmd -Cmd @("aws", "sts", "get-caller-identity", "--output", "json") -CaptureOutput
$identity = $callerIdentity | ConvertFrom-Json
Write-Success "Authenticated as: $($identity.Arn)"

# ──────────────────────────────────────────────────────────────────────────── Stage 3: Terraform init + apply (Req 15.4) ──────────────────────────────

Write-Step "Running terraform init (Req 15.4)"
Invoke-Cmd -Cmd @("terraform", "init", "-input=false") -WorkDir $infraRoot

Write-Step "Running terraform apply (Req 15.4)"
Invoke-Cmd -Cmd @("terraform", "apply", "-auto-approve", "-input=false") -WorkDir $infraRoot

# ──────────────────────────────────────────────────────────────────────────── Stage 4: Capture Terraform outputs ──────────────────────────────────────

Write-Step "Reading Terraform outputs"
Push-Location $infraRoot
$eksClusterName = Get-TerraformOutput "eks_cluster_name"
$albDnsName     = Get-TerraformOutput "alb_dns_name"
$ecrUrlsJson    = Get-TerraformOutputJson "ecr_repository_urls"
$awsRegion      = "us-east-1"
Pop-Location

Write-Success "EKS cluster: $eksClusterName"
Write-Success "ALB DNS:     $albDnsName"

# ──────────────────────────────────────────────────────────────────────────── Stage 5: Update kubeconfig (Req 15.5) ───────────────────────────────────

Write-Step "Updating kubeconfig for cluster: $eksClusterName (Req 15.5)"
Invoke-Cmd -Cmd @("aws", "eks", "update-kubeconfig",
    "--region", "us-east-1",
    "--name", $eksClusterName)
Write-Success "kubeconfig updated"

# ──────────────────────────────────────────────────────────────────────────── Stage 6: Wait for shared bootstrap (Req 15.7) ───────────────────────────

Write-Step "Waiting for MongoDB and Redis readiness (Req 15.7)"
# MongoDB StatefulSet (bitnami chart uses 'mongodb' as app label)
try {
    Wait-KubectlStatefulSet -Namespace "data" -StatefulSet "mongodb" -Timeout "5m"
} catch {
    # Fallback: try rollout on deployment if helm chart uses Deployment
    Write-Info "StatefulSet 'mongodb' not found, trying deployment..."
    Invoke-Cmd -Cmd @("kubectl", "wait", "pod",
        "-n", "data",
        "-l", "app.kubernetes.io/name=mongodb",
        "--for=condition=Ready",
        "--timeout=5m")
}

try {
    Wait-KubectlStatefulSet -Namespace "data" -StatefulSet "redis-master" -Timeout "5m"
} catch {
    Write-Info "StatefulSet 'redis-master' not found, trying 'redis'..."
    try {
        Wait-KubectlStatefulSet -Namespace "data" -StatefulSet "redis" -Timeout "5m"
    } catch {
        Invoke-Cmd -Cmd @("kubectl", "wait", "pod",
            "-n", "data",
            "-l", "app.kubernetes.io/name=redis",
            "--for=condition=Ready",
            "--timeout=5m")
    }
}
Write-Success "MongoDB and Redis are ready"

# ──────────────────────────────────────────────────────────────────────────── Stage 7: ECR login + build + push (Req 15.6) ────────────────────────────

Write-Step "Logging in to ECR (Req 15.6)"
# Usa o output ecr_registry_url diretamente (account.dkr.ecr.region.amazonaws.com)
Push-Location $infraRoot
$ecrRegistry = Get-TerraformOutput "ecr_registry_url"
Pop-Location

Invoke-Cmd -Cmd @("aws", "ecr", "get-login-password",
    "--region", $awsRegion) -CaptureOutput | ForEach-Object {
    if (-not $DryRun) {
        $_ | docker login --username AWS --password-stdin $ecrRegistry
        if ($LASTEXITCODE -ne 0) { throw "ECR docker login failed" }
    } else {
        Write-Info "[DRY-RUN] docker login --username AWS --password-stdin $ecrRegistry"
    }
}

# Resolve git SHA (Req 15.6)
if (-not $GitSha) {
    try {
        $GitSha = Invoke-Cmd -Cmd @("git", "rev-parse", "--short", "HEAD") `
            -WorkDir $infraRoot -CaptureOutput
    } catch {
        $GitSha = "latest"
        Write-Info "Could not resolve git SHA; using 'latest'"
    }
}
Write-Info "Image tag: $GitSha"

foreach ($svc in $cfg.services) {
    Write-Step "Building image: $($svc.name)"
    $repoAbs = if ([System.IO.Path]::IsPathRooted($svc.repo_path)) {
        $svc.repo_path
    } else {
        Join-Path $infraRoot $svc.repo_path
    }

    $ecrKey = $svc.ecr_key
    $ecrUrl = $ecrUrlsJson.$ecrKey
    if (-not $ecrUrl) {
        throw "ECR URL not found for key '$ecrKey'. Check terraform outputs."
    }
    $imageTag = "${ecrUrl}:${GitSha}"

    $dockerfilePath = Join-Path $repoAbs $svc.dockerfile
    $buildContextAbs = Join-Path $repoAbs $svc.build_context

    Invoke-Cmd -Cmd @("docker", "build",
        "-t", $imageTag,
        "-f", $dockerfilePath,
        $buildContextAbs)

    Write-Info "Pushing: $imageTag"
    Invoke-Cmd -Cmd @("docker", "push", $imageTag)
    Write-Success "Pushed: $imageTag"

    # Store resolved image on the service object for later use
    $svc | Add-Member -NotePropertyName "resolved_image" -NotePropertyValue $imageTag -Force
}

# ──────────────────────────────────────────────────────────────────────────── Stage 8: Database migrations ────────────────────────────────────────────

Write-Step "Running database migrations (services that declare them)"
foreach ($svc in $cfg.services) {
    if (-not $svc.migrations) { continue }
    Write-Info "Migration for $($svc.name): $($svc.migrations.command)"
    $repoAbs = if ([System.IO.Path]::IsPathRooted($svc.repo_path)) {
        $svc.repo_path
    } else {
        Join-Path $infraRoot $svc.repo_path
    }
    $migrWorkDir = if ($svc.migrations.workdir) {
        Join-Path $repoAbs $svc.migrations.workdir
    } else {
        $repoAbs
    }
    $migrCmd = $svc.migrations.command -split "\s+"
    Invoke-Cmd -Cmd $migrCmd -WorkDir $migrWorkDir
    Write-Success "Migration complete: $($svc.name)"
}

# ──────────────────────────────────────────────────────────────────────────── Stage 9: Per-service k8s apply in stage order (Req 15.8/15.9/15.10) ─────

# Stage order: auth → {registration, report, processing} → api-gateway
$stageOrder = @(
    @("auth-service"),
    @("registration-service", "report-service", "processing-service"),
    @("api-gateway")
)

# Build lookup map
$svcMap = @{}
foreach ($svc in $cfg.services) { $svcMap[$svc.name] = $svc }

foreach ($stage in $stageOrder) {
    Write-Step "Applying stage: [$($stage -join ', ')]"

    foreach ($svcName in $stage) {
        if (-not $svcMap.ContainsKey($svcName)) {
            Write-Info "Service '$svcName' not in config, skipping"
            continue
        }
        $svc = $svcMap[$svcName]
        $repoAbs = if ([System.IO.Path]::IsPathRooted($svc.repo_path)) {
            $svc.repo_path
        } else {
            Join-Path $infraRoot $svc.repo_path
        }
        $k8sDir = if ($svc.k8s_dir) { $svc.k8s_dir } else { "k8s" }
        $k8sPath = Join-Path $repoAbs $k8sDir
        $kustomizationFile = Join-Path $k8sPath "kustomization.yaml"

        # Req 15.8: prefer kustomize when kustomization.yaml exists
        if (Test-Path $kustomizationFile) {
            Write-Info "kubectl apply -k $k8sPath"
            Invoke-Cmd -Cmd @("kubectl", "apply", "-k", $k8sPath)
        } else {
            Write-Info "kubectl apply -f $k8sPath/ --namespace $($svc.namespace)"
            Invoke-Cmd -Cmd @("kubectl", "apply", "-f", "$k8sPath/",
                "--namespace", $svc.namespace)
        }
    }

    # Req 15.10: block on rollout status for every deployment in this stage
    foreach ($svcName in $stage) {
        if (-not $svcMap.ContainsKey($svcName)) { continue }
        $svc = $svcMap[$svcName]
        foreach ($dep in $svc.deployments) {
            Wait-KubectlRollout -Namespace $svc.namespace -Deployment $dep -Timeout "5m"
        }
    }
    Write-Success "Stage [$($stage -join ', ')] ready"
}

# ──────────────────────────────────────────────────────────────────────────── Stage 10: Invoke Validator + write report (Req 15.11) ───────────────────

Write-Step "Running Validator (Req 15.11)"

$artifactsDir = Join-Path $infraRoot "artifacts"
if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportJsonPath = Join-Path $artifactsDir "validation-report-$timestamp.json"
$reportMdPath   = Join-Path $artifactsDir "validation-report-$timestamp.md"

$validateScript = Join-Path $PSScriptRoot "validate.ps1"

function Invoke-Validator {
    param([string]$AlbDns, [string]$JsonOut, [string]$MdOut)
    if (Test-Path $validateScript) {
        & $validateScript -AlbDnsName $AlbDns -ConfigPath $ConfigPath `
            -ReportJsonPath $JsonOut -ReportMdPath $MdOut
        return $LASTEXITCODE -eq 0
    }
    # Inline fallback validator (Req 16)
    Write-Info "validate.ps1 not found; running inline validator"
    return Invoke-InlineValidator -AlbDns $AlbDns -JsonOut $JsonOut -MdOut $MdOut
}

function Invoke-InlineValidator {
    param([string]$AlbDns, [string]$JsonOut, [string]$MdOut)
    $results = @()
    $overall = $true

    foreach ($svc in $cfg.services) {
        # celery-worker has no ingress/health endpoint
        if ($svc.name -eq "celery-worker") { continue }
        $healthPath = if ($svc.health_path) { $svc.health_path } else { "/health" }
        # Build ALB-level health URL: /api/<service>/health
        $ingressBase = $svc.ingress_path
        $url = "http://$AlbDns$ingressBase/health"

        Write-Info "Probing: $url"
        $status = "FAIL"
        $latencyMs = $null
        $lastError = ""
        $deadline = (Get-Date).AddMinutes(5)

        while ((Get-Date) -lt $deadline) {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $resp = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                $sw.Stop()
                if ($resp.StatusCode -eq 200) {
                    $status = "PASS"
                    $latencyMs = $sw.ElapsedMilliseconds
                    break
                }
                $lastError = "HTTP $($resp.StatusCode)"
            } catch {
                $lastError = $_.Exception.Message
            }
            Start-Sleep -Seconds 10
        }

        if ($status -eq "FAIL") { $overall = $false }
        $results += [PSCustomObject]@{
            service   = $svc.name
            status    = $status
            latencyMs = $latencyMs
            error     = $lastError
        }
        $icon = if ($status -eq "PASS") { "[PASS]" } else { "[FAIL]" }
        Write-Info "$icon $($svc.name) — $url"
    }

    $report = [PSCustomObject]@{
        timestamp = (Get-Date -Format "o")
        overall   = $overall
        alb_dns   = $AlbDns
        services  = $results
    }

    $report | ConvertTo-Json -Depth 5 | Set-Content -Path $JsonOut -Encoding UTF8

    # Markdown report
    $md = @"
# Validation Report

**Timestamp:** $($report.timestamp)
**ALB DNS:** $AlbDns
**Overall:** $(if ($overall) { "[PASS]" } else { "[FAIL]" })

## Services

| Service | Status | Latency (ms) | Error |
|---------|--------|-------------|-------|
"@
    foreach ($r in $results) {
        $icon = if ($r.status -eq "PASS") { "[PASS]" } else { "[FAIL]" }
        $md += "`n| $($r.service) | $icon $($r.status) | $($r.latencyMs) | $($r.error) |"
    }
    Set-Content -Path $MdOut -Value $md -Encoding UTF8

    return $overall
}

$validationPassed = Invoke-Validator -AlbDns $albDnsName `
    -JsonOut $reportJsonPath -MdOut $reportMdPath

# ──────────────────────────────────────────────────────────────────────────── Stage 11: Auto-retry on failure (Req 15.12) ─────────────────────────────

if (-not $validationPassed) {
    Write-Step "Validator reported failures — attempting automatic retry (Req 15.12)"

    # Restart all service deployments
    foreach ($svc in $cfg.services) {
        foreach ($dep in $svc.deployments) {
            Write-Info "kubectl rollout restart deployment/$dep -n $($svc.namespace)"
            try {
                Invoke-Cmd -Cmd @("kubectl", "rollout", "restart",
                    "deployment/$dep", "-n", $svc.namespace)
            } catch {
                Write-Info "Could not restart $dep (may not exist yet): $_"
            }
        }
    }

    # Wait for rollouts to settle
    foreach ($svc in $cfg.services) {
        foreach ($dep in $svc.deployments) {
            try {
                Wait-KubectlRollout -Namespace $svc.namespace -Deployment $dep -Timeout "5m"
            } catch {
                Write-Info "Rollout wait failed for $($dep): $($_.Exception.Message)"
            }
        }
    }

    # Re-run validator with new timestamp
    $timestamp2 = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportJsonPath = Join-Path $artifactsDir "validation-report-$timestamp2.json"
    $reportMdPath   = Join-Path $artifactsDir "validation-report-$timestamp2.md"

    $validationPassed = Invoke-Validator -AlbDns $albDnsName `
        -JsonOut $reportJsonPath -MdOut $reportMdPath
}

# ──────────────────────────────────────────────────────────────────────────── Final summary ────────────────────────────────────────────────────────────

Write-Step "Deployment complete"
Write-Info "Report JSON: $reportJsonPath"
Write-Info "Report MD:   $reportMdPath"

if ($validationPassed) {
    Write-Success "All services PASS. Stack is healthy."
    exit 0
} else {
    Write-Fail "One or more services FAILED validation after retry."
    Write-Fail "Review the report: $reportJsonPath"
    exit 1
}
