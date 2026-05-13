#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs Terraform static analysis: fmt check, validate per module, and tflint.

.DESCRIPTION
    1. terraform fmt -check -recursive  (from infra root)
    2. terraform validate               (per module directory)
    3. tflint --config .tflint.hcl      (per module + root)

    Exits non-zero if any check fails. Prints a summary at the end.

.EXAMPLE
    .\scripts\test-terraform.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve infra root (parent of scripts/)
$InfraRoot = Split-Path -Parent $PSScriptRoot
Push-Location $InfraRoot

$Modules = @(
    "network",
    "security",
    "storage",
    "ecr",
    "messaging",
    "database",
    "eks",
    "alb",
    "k8s-config",
    "secrets",
    "observability",
    "mongodb-on-eks",
    "redis-on-eks"
)

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

# 1. terraform fmt -check -recursive
Write-Step "terraform fmt -check -recursive"
$fmtOut = & terraform fmt -check -recursive 2>&1
if ($LASTEXITCODE -ne 0) {
    Record-Fail "fmt-check" ($fmtOut -join "; ")
} else {
    Record-Pass "fmt-check"
}

# 2. terraform validate per module
Write-Step "terraform validate (per module)"
foreach ($mod in $Modules) {
    $modPath = Join-Path $InfraRoot "modules" $mod
    if (-not (Test-Path $modPath)) {
        Record-Fail "validate:$mod" "directory not found: $modPath"
        continue
    }
    Push-Location $modPath
    # init with -backend=false so no credentials needed
    $initOut = & terraform init -backend=false -input=false -no-color 2>&1
    if ($LASTEXITCODE -ne 0) {
        $initMsg = ($initOut | Select-Object -Last 3) -join "; "
        Record-Fail "init:$mod" $initMsg
        Pop-Location
        continue
    }
    $valOut = & terraform validate -no-color 2>&1
    if ($LASTEXITCODE -ne 0) {
        $valMsg = ($valOut | Select-Object -Last 5) -join "; "
        Record-Fail "validate:$mod" $valMsg
    } else {
        Record-Pass "validate:$mod"
    }
    Pop-Location
}

# 3. tflint per module + root
Write-Step "tflint (per module + root)"

# Check tflint is available
if (-not (Get-Command tflint -ErrorAction SilentlyContinue)) {
    Write-Host "  [SKIP] tflint not found in PATH - install from https://github.com/terraform-linters/tflint" -ForegroundColor Yellow
} else {
    $tflintConfig = Join-Path $InfraRoot ".tflint.hcl"

    # Root
    $lintOut = & tflint --config $tflintConfig --chdir $InfraRoot 2>&1
    if ($LASTEXITCODE -ne 0) {
        $lintMsg = ($lintOut | Select-Object -Last 5) -join "; "
        Record-Fail "tflint:root" $lintMsg
    } else {
        Record-Pass "tflint:root"
    }

    # Each module
    foreach ($mod in $Modules) {
        $modPath = Join-Path $InfraRoot "modules" $mod
        if (-not (Test-Path $modPath)) {
            Record-Fail "tflint:$mod" "directory not found"
            continue
        }
        $lintOut = & tflint --config $tflintConfig --chdir $modPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $lintMsg = ($lintOut | Select-Object -Last 5) -join "; "
            Record-Fail "tflint:$mod" $lintMsg
        } else {
            Record-Pass "tflint:$mod"
        }
    }
}

# Summary
Pop-Location

Write-Host ""
Write-Host "==========================================" -ForegroundColor White
Write-Host "  SUMMARY" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor White
Write-Host "  Passed : $($Successes.Count)" -ForegroundColor Green

if ($Failures.Count -gt 0) {
    Write-Host "  Failed : $($Failures.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Failed checks:" -ForegroundColor Red
    foreach ($f in $Failures) {
        Write-Host "    - $f" -ForegroundColor Red
    }
    Write-Host ""
    exit 1
} else {
    Write-Host "  Failed : 0" -ForegroundColor Green
    Write-Host ""
    Write-Host "  All checks passed." -ForegroundColor Green
    exit 0
}
