<#
.SYNOPSIS
    Validates all Arch Analyzer services through the ALB.

.DESCRIPTION
    For each service (excluding celery-worker), sends GET http://<alb_dns>/api/<service>/health
    with a 5-second timeout, retrying every 10 seconds for up to 5 minutes.
    Records PASS (with latency ms) or FAIL (with last error).
    Emits JSON and Markdown reports to ./artifacts/.

    Requirements: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6

.PARAMETER AlbDns
    ALB DNS name. If not provided, reads from: terraform output -raw alb_dns_name

.PARAMETER ArtifactsDir
    Directory for report output. Defaults to ./artifacts
#>
[CmdletBinding()]
param(
    [string]$AlbDns = "",
    [string]$ArtifactsDir = "./artifacts"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Services to validate (celery-worker excluded per Req 16.1)
# ---------------------------------------------------------------------------
$Services = @(
    @{ Name = "auth-service";          HealthUrl = "/api/auth/health" },
    @{ Name = "api-gateway";           HealthUrl = "/api/gateway/health" },
    @{ Name = "registration-service";  HealthUrl = "/api/registration/health" },
    @{ Name = "processing-service";    HealthUrl = "/api/analyses/health" },
    @{ Name = "report-service";        HealthUrl = "/api/reports/health" }
)

$TimeoutSeconds   = 5    # per-request timeout  (Req 16.1)
$RetryIntervalSec = 10   # sleep between retries (Req 16.2)
$MaxWaitSec       = 300  # 5 minutes total       (Req 16.2)

# ---------------------------------------------------------------------------
# Resolve ALB DNS
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($AlbDns)) {
    Write-Host "Reading ALB DNS from terraform output..."
    try {
        $AlbDns = (terraform output -raw alb_dns_name 2>&1).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AlbDns)) {
            throw "terraform output -raw alb_dns_name returned empty or non-zero exit."
        }
    }
    catch {
        Write-Error "Failed to get ALB DNS: $_"
        exit 1
    }
}

Write-Host "ALB DNS: $AlbDns"

# ---------------------------------------------------------------------------
# Ensure artifacts directory exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Validate each service
# ---------------------------------------------------------------------------
$Results = @()

foreach ($svc in $Services) {
    $url       = "http://$AlbDns$($svc.HealthUrl)"
    $startTime = Get-Date
    $passed    = $false
    $latencyMs = $null
    $lastError = ""

    Write-Host ""
    Write-Host "==> Validating $($svc.Name) at $url"

    while ($true) {
        $elapsed = (Get-Date) - $startTime

        try {
            $reqStart = Get-Date
            $response = Invoke-WebRequest `
                -Uri $url `
                -Method GET `
                -TimeoutSec $TimeoutSeconds `
                -UseBasicParsing `
                -ErrorAction Stop

            $latencyMs = [int]((Get-Date) - $reqStart).TotalMilliseconds

            if ($response.StatusCode -eq 200) {
                Write-Host "  PASS  latency=${latencyMs}ms  status=$($response.StatusCode)"
                $Results += [PSCustomObject]@{
                    service    = $svc.Name
                    status     = "PASS"
                    latency_ms = $latencyMs
                    error      = $null
                    url        = $url
                }
                $passed = $true
                break
            }
            else {
                $lastError = "HTTP $($response.StatusCode)"
                Write-Host "  retry  status=$($response.StatusCode)  elapsed=$([int]$elapsed.TotalSeconds)s"
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Host "  retry  error=$lastError  elapsed=$([int]$elapsed.TotalSeconds)s"
        }

        # Check timeout AFTER the attempt so we always try at least once
        if ($elapsed.TotalSeconds -ge $MaxWaitSec) {
            break
        }

        Start-Sleep -Seconds $RetryIntervalSec
    }

    if (-not $passed) {
        Write-Host "  FAIL  last_error=$lastError"
        $Results += [PSCustomObject]@{
            service    = $svc.Name
            status     = "FAIL"
            latency_ms = $null
            error      = $lastError
            url        = $url
        }
    }
}

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
$overall   = ($Results | Where-Object { $_.status -ne "PASS" }).Count -eq 0
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$report = [PSCustomObject]@{
    timestamp  = (Get-Date -Format "o")
    alb_dns    = $AlbDns
    overall    = $overall
    items      = $Results
}

# ---------------------------------------------------------------------------
# Emit JSON report  (Req 16.6)
# ---------------------------------------------------------------------------
$jsonPath = Join-Path $ArtifactsDir "validation-report-$timestamp.json"
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
Write-Host ""
Write-Host "JSON report: $jsonPath"

# ---------------------------------------------------------------------------
# Emit Markdown report  (Req 16.6)
# ---------------------------------------------------------------------------
$mdPath = Join-Path $ArtifactsDir "validation-report-$timestamp.md"

$overallEmoji = if ($overall) { ":white_check_mark:" } else { ":x:" }
$overallText  = if ($overall) { "PASS" } else { "FAIL" }

$mdLines = @(
    "# Arch Analyzer Validation Report",
    "",
    "| Field     | Value |",
    "|-----------|-------|",
    "| Timestamp | $($report.timestamp) |",
    "| ALB DNS   | $AlbDns |",
    "| Overall   | $overallEmoji **$overallText** |",
    "",
    "## Service Results",
    "",
    "| Service | Status | Latency (ms) | Error |",
    "|---------|--------|-------------|-------|"
)

foreach ($item in $Results) {
    $statusEmoji = if ($item.status -eq "PASS") { ":white_check_mark: PASS" } else { ":x: FAIL" }
    $latency     = if ($null -ne $item.latency_ms) { $item.latency_ms } else { "—" }
    $error       = if ($null -ne $item.error) { $item.error } else { "—" }
    $mdLines    += "| $($item.service) | $statusEmoji | $latency | $error |"
}

$mdLines += ""
$mdLines += "---"
$mdLines += "_Generated by validate.ps1_"

$mdLines -join "`n" | Set-Content -Path $mdPath -Encoding UTF8
Write-Host "Markdown report: $mdPath"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================"
Write-Host "Overall: $overallText"
Write-Host "========================================"

# Exit non-zero when any service failed so CI can detect failures
if (-not $overall) {
    exit 1
}
exit 0
