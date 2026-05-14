#!/usr/bin/env pwsh
$env:PATH = "C:\Users\user\AppData\Local\Programs\Python\Python312;$env:PATH"

Write-Host "=== Debug YAML parsing ==="
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}

if ($python) {
    Write-Host "Python found: $($python.Source)"
} else {
    Write-Host "Python NOT found in PATH"
    Write-Host "PATH entries:"
    $env:PATH -split ';' | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$script = @'
import sys, yaml, json
with open(sys.argv[1]) as f:
    print(json.dumps(yaml.safe_load(f)))
'@
$tmpScript = [System.IO.Path]::GetTempFileName() + ".py"
Set-Content -Path $tmpScript -Value $script -Encoding UTF8
Write-Host "Temp script: $tmpScript"

$configPath = "$PSScriptRoot/deploy-all.config.yaml"
Write-Host "Config: $configPath"
Write-Host "Config exists: $(Test-Path $configPath)"

try {
    $json = & $python.Source $tmpScript $configPath 2>&1
    Write-Host "Exit code: $LASTEXITCODE"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS - first 100 chars: $($json.Substring(0, [Math]::Min(100, $json.Length)))"
    } else {
        Write-Host "FAILED output: $json"
    }
} catch {
    Write-Host "EXCEPTION: $_"
} finally {
    Remove-Item $tmpScript -ErrorAction SilentlyContinue
}
