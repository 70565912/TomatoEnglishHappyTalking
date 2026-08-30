# Move recording-export files into type/book folders and rewrite
# recording_video_versions.json paths. File names drop the series prefix.
#
# Usage:
#   .\tools\reorganize_recording_export.ps1 -WhatIf
#   .\tools\reorganize_recording_export.ps1
param(
    [string]$ExportRoot = '',
    [string]$DatabasePath = '',
    [string]$ReportPath = '',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$pythonScript = Join-Path $PSScriptRoot 'reorganize_recording_export.py'
if (-not (Test-Path $pythonScript)) {
    throw "Helper script not found: $pythonScript"
}

$pythonArgs = @($pythonScript)
if (-not [string]::IsNullOrWhiteSpace($ExportRoot)) {
    $pythonArgs += @('--export-root', $ExportRoot)
}
if (-not [string]::IsNullOrWhiteSpace($DatabasePath)) {
    $pythonArgs += @('--database', $DatabasePath)
}
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $pythonArgs += @('--report-path', $ReportPath)
}
if ($WhatIf) {
    $pythonArgs += '--what-if'
}

Write-Output '=== Reorganize recording-export ==='
& python @pythonArgs
if ($LASTEXITCODE -ne 0) {
    throw "reorganize_recording_export.py failed with exit code $LASTEXITCODE"
}
