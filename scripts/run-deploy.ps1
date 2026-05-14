#!/usr/bin/env pwsh
# Wrapper that ensures Python is in PATH before calling deploy-all.ps1
$env:PATH = "C:\Users\user\AppData\Local\Programs\Python\Python312;C:\Users\user\AppData\Local\Microsoft\WinGet\Packages\Helm.Helm_Microsoft.Winget.Source_8wekyb3d8bbwe\windows-amd64;$env:PATH"
& "$PSScriptRoot\deploy-all.ps1" @args
