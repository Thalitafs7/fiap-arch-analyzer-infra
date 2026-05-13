#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates Kubernetes manifests in every Service_K8s_Folder using kubeconform.

.DESCRIPTION
    Runs:
        kubeconform -summary -strict -kubernetes-version 1.29 <yaml_files...>

    against each service k8s/ folder. Skips aws-secret-template.yaml files
    (they contain placeholder values that fail schema validation).

    Exits non-zero if any validation fails. Prints a summary at the end.

.EXAMPLE
    .\scripts\test-kubeconform.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Service k8s/ folders
$ServiceFolders = [ordered]@{
    "auth-service"          = "c:\projects\fiap-arch-analyzer-auth-service\k8s"
    "api-gateway"           = "c:\projects\fiap-arch-analyzer-api-gateway\k8s"
    "registration-service"  = "c:\projects\fiap-arch-analyzer-registration-service\k8s"
    "processing-service"    = "c:\projects\fiap-arch-analyzer-processing-service\k8s"
    "report-service"        = "c:\projects\fiap-arch-analyzer-report-service\k8s"
}

$K8sVersion  = "1.29"
$SkipPattern = "aws-secret-template.yaml"

$Failures  = [System.Collections.Generic.List[string]]::new()
$Successes = [System.Collections.Generic.List[string]]::new()

function Write-Step {
    param([string]$Msg)
    Write-Host ""
    Write-Host "==> $Msg" -ForegroundColor Cyan
}

function Record-Pass {
    param([string]$Label)
    $Successes.Add($Label)
    Write-Host "  [PASS] $Label" -ForegroundColor Green
}

function Record-Fail {
    param([string]$Label, [string]$Detail = "")
    $Failures.Add($Label)
    if ($Detail) {
        Write-Host "  [FAIL] $Label - $Detail" -ForegroundColor Red
    } else {
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
    }
}

# Verify kubeconform is available
if (-not (Get-Command kubeconform -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: kubeconform not found in PATH." -ForegroundColor Red
    Write-Host "Install from: https://github.com/yannh/kubeconform/releases" -ForegroundColor Yellow
    exit 1
}

# Validate each service folder
foreach ($entry in $ServiceFolders.GetEnumerator()) {
    $svcName = $entry.Key
    $k8sDir  = $entry.Value

    Write-Step "kubeconform: $svcName ($k8sDir)"

    if (-not (Test-Path $k8sDir)) {
        Record-Fail $svcName "k8s directory not found: $k8sDir"
        continue
    }

    # Collect yaml files, excluding aws-secret-template.yaml
    $yamlFiles = Get-ChildItem -Path $k8sDir -Filter "*.yaml" -File |
                 Where-Object { $_.Name -ne $SkipPattern }

    if ($yamlFiles.Count -eq 0) {
        Write-Host "  [SKIP] No YAML files found (excluding $SkipPattern)" -ForegroundColor Yellow
        continue
    }

    Write-Host "  Files: $($yamlFiles.Name -join ', ')" -ForegroundColor DarkGray

    # Build file list for kubeconform
    $filePaths = $yamlFiles | ForEach-Object { $_.FullName }

    $output = & kubeconform `
        -summary `
        -strict `
        -kubernetes-version $K8sVersion `
        -output pretty `
        @filePaths 2>&1

    $exitCode = $LASTEXITCODE

    # Print kubeconform output
    $output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if ($exitCode -ne 0) {
        Record-Fail $svcName "kubeconform reported errors (exit $exitCode)"
    } else {
        Record-Pass $svcName
    }
}

# Summary
Write-Host ""
Write-Host "==========================================" -ForegroundColor White
Write-Host "  SUMMARY" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor White
Write-Host "  Passed : $($Successes.Count)" -ForegroundColor Green

if ($Failures.Count -gt 0) {
    Write-Host "  Failed : $($Failures.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Failed services:" -ForegroundColor Red
    foreach ($f in $Failures) {
        Write-Host "    - $f" -ForegroundColor Red
    }
    Write-Host ""
    exit 1
} else {
    Write-Host "  Failed : 0" -ForegroundColor Green
    Write-Host ""
    Write-Host "  All manifests valid." -ForegroundColor Green
    exit 0
}
