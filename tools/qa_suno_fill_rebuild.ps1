Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Get-Process tomato_english_happy_talking -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Set-Location (Split-Path -Parent $PSScriptRoot)
.\tools\build_windows.ps1 -Run -DartDefine 'TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317'
