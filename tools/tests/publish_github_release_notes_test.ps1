Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$publisher = Join-Path $PSScriptRoot '../publish_github_release.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($publisher, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Publish-GitTagAndRelease', 'Assert-LastExitCode')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:calls = [System.Collections.Generic.List[object]]::new()
function git { $script:calls.Add(@('git') + $args); $global:LASTEXITCODE = 0 }
function gh { $script:calls.Add(@('gh') + $args); $global:LASTEXITCODE = 0 }
$workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('tomato-release-notes-test-' + [guid]::NewGuid())
$Draft = $false
$invokeArgs = @{ TagName = 'v9.9.9'; VersionValue = '9.9.9'; ZipPath = 'windows.zip'; ApkPath = 'android.apk'; ChecksumPath = 'SHA256SUMS.txt' }
try {
    New-Item -ItemType Directory (Join-Path $workspaceRoot 'docs/releases') -Force | Out-Null
    $notesPath = Join-Path $workspaceRoot 'docs/releases/v9.9.9.md'
    foreach ($scenario in @('missing', 'empty')) {
        if ($scenario -eq 'empty') { [System.IO.File]::WriteAllText($notesPath, " `r`n ") }
        $rejected = $false
        try { Publish-GitTagAndRelease @invokeArgs } catch {
            if ($_.Exception.Message -notlike 'Release notes missing or empty:*') { throw }
            $rejected = $true
        }
        if (-not $rejected -or $script:calls.Count -ne 0) { throw "$scenario notes must fail before remote mutations" }
    }
    $body = "# 更新记录`n`n- 中文与多行内容。`n"
    [System.IO.File]::WriteAllText($notesPath, $body)
    foreach ($draftValue in @($false, $true)) {
        $Draft = $draftValue
        $script:calls.Clear()
        Publish-GitTagAndRelease @invokeArgs
        if ($script:calls.Count -ne 3) { throw 'Expected two git calls and one gh call' }
        $ghCall = $script:calls[2]
        $index = [array]::IndexOf($ghCall, '--notes-file')
        if ($ghCall[0] -ne 'gh' -or $index -lt 0 -or $ghCall[$index + 1] -ne $notesPath -or $ghCall -contains '--notes') { throw 'Release must upload the version notes file' }
        if (($ghCall -contains '--draft') -ne $Draft) { throw 'Draft behavior changed' }
        if ([System.IO.File]::ReadAllText($notesPath) -cne $body) { throw 'Notes were modified' }
    }
    Write-Host 'PASS: missing, empty, published and draft release notes (4 scenarios).'
} finally {
    $resolved = [System.IO.Path]::GetFullPath($workspaceRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\tomato-release-notes-test-'
    if (-not $resolved.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}