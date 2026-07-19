# Tomato English Happy Talking - GitHub Release publisher
# Usage:
#   .\tools\publish_github_release.ps1 -Version 1.0.0
#   .\tools\publish_github_release.ps1 -Version 1.0.0 -SkipBuild
#   .\tools\publish_github_release.ps1 -Version 1.0.0 -Draft
#
# Encoding guard:
# Keep this file saved as UTF-8 with BOM. Windows PowerShell 5.1 may parse a
# UTF-8 file without BOM as the local ANSI code page.
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [switch]$SkipBuild,
    [switch]$Draft
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$releaseRoot = Join-Path $workspaceRoot "release"
$distRoot = Join-Path $releaseRoot "dist"
$packageName = "tomato_english_happy_talking"
$windowsRunnerReleaseDir = Join-Path $workspaceRoot "app\build\windows\x64\runner\Release"
$androidReleaseApk = Join-Path $releaseRoot "android\$packageName-android-release.apk"

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "$CommandName failed, exit code: $LASTEXITCODE"
    }
}

function Get-WindowsRuntimeDirectories {
    return @(
        ".dart_tool",
        "tomato_api_cache",
        "downloads",
        "diagnostics",
        "recordings",
        "recording-export",
        "picture_book",
        "book-transfer-assets",
        "song-assets",
        "suno-music",
        "runtime",
        "user_data",
        "logs",
        "security",
        "data\downloads",
        "data\tomato_api_cache",
        "data\recordings",
        "data\picture_book",
        "data\song-assets",
        "data\suno-music",
        "data\user_data",
        "data\databases"
    )
}

function Get-WindowsRuntimeFiles {
    return @(
        "AccessKey.txt",
        "speech-api-key.txt",
        "settings.json"
    )
}

function Normalize-WindowsRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $normalized = $Path.Trim().Replace('/', '\')
    while ($normalized.StartsWith('.\', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }

    return $normalized.TrimStart('\')
}

function Get-WindowsRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$BaseDir
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedBaseDir = [System.IO.Path]::GetFullPath($BaseDir)
    if (-not $resolvedBaseDir.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString(), [System.StringComparison]::Ordinal)) {
        $resolvedBaseDir = $resolvedBaseDir + [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [System.Uri]::new($resolvedBaseDir)
    $pathUri = [System.Uri]::new($resolvedPath)
    $relativeUri = $baseUri.MakeRelativeUri($pathUri)
    $relativePath = [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', '\')
    return Normalize-WindowsRelativePath $relativePath
}

function Test-IsPreservedWindowsRuntimeDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $normalized = Normalize-WindowsRelativePath $RelativePath
    foreach ($runtimePath in @(Get-WindowsRuntimeDirectories)) {
        if ($normalized.Equals($runtimePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        $prefix = $runtimePath + '\'
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-IsPreservedWindowsRuntimeFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $normalized = Normalize-WindowsRelativePath $RelativePath
    foreach ($runtimePath in @(Get-WindowsRuntimeFiles)) {
        if ($normalized.Equals($runtimePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $fileName = [System.IO.Path]::GetFileName($normalized)
    if ($fileName -match '\.(db|sqlite|sqlite3)(-wal|-shm)?$') {
        return $true
    }

    return $false
}

function Copy-WindowsProgramArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,
        [Parameter(Mandatory = $true)]
        [string]$DestinationDir,
        [Parameter(Mandatory = $false)]
        [string]$RootSourceDir = $SourceDir
    )

    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null

    foreach ($item in @(Get-ChildItem -LiteralPath $SourceDir -Force)) {
        $relativePath = Get-WindowsRelativePath -Path $item.FullName -BaseDir $RootSourceDir

        if ($item.PSIsContainer) {
            if (Test-IsPreservedWindowsRuntimeDirectory -RelativePath $relativePath) {
                continue
            }

            $destinationPath = Join-Path $DestinationDir $item.Name
            Copy-WindowsProgramArtifacts -SourceDir $item.FullName -DestinationDir $destinationPath -RootSourceDir $RootSourceDir
            continue
        }

        if (Test-IsPreservedWindowsRuntimeFile -RelativePath $relativePath) {
            continue
        }

        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $DestinationDir $item.Name) -Force
    }
}

function Get-WindowsFfmpegBundleSourceDir {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($env:VCPKG_ROOT)) {
        $candidates += (Join-Path $env:VCPKG_ROOT "installed\x64-windows\tools\ffmpeg")
    }

    $candidates += @(
        "E:\SDK\vcpkg\installed\x64-windows\tools\ffmpeg",
        "e:\sdk\vcpkg\installed\x64-windows\tools\ffmpeg"
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $ffmpegExe = Join-Path $candidate "ffmpeg.exe"
        if (Test-Path $ffmpegExe) {
            return $candidate
        }
    }

    return $null
}

function Copy-WindowsFfmpegRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    $sourceDir = Get-WindowsFfmpegBundleSourceDir
    if ([string]::IsNullOrWhiteSpace($sourceDir)) {
        throw "FFmpeg bundle not found. Check E:\SDK\vcpkg\installed\x64-windows\tools\ffmpeg\ffmpeg.exe or set VCPKG_ROOT."
    }

    $copied = @()
    $ffmpegExe = Join-Path $sourceDir "ffmpeg.exe"
    Copy-Item -LiteralPath $ffmpegExe -Destination (Join-Path $PackageDir "ffmpeg.exe") -Force
    $copied += "ffmpeg.exe"

    Get-ChildItem -LiteralPath $sourceDir -File -Filter "*.dll" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $PackageDir $_.Name) -Force
        $copied += $_.Name
    }

    Write-Host "Packaged FFmpeg runtime files: $($copied.Count)" -ForegroundColor Green
}

function Assert-VersionFormat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -notmatch '^\d+\.\d+\.\d+$') {
        throw "Version must look like 1.0.0 (got: $Value). Do not include the leading 'v'."
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @(),
        [switch]$IgnoreExitCode
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $FilePath @ArgumentList 1>$null 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    if (-not $IgnoreExitCode -and $null -ne $exitCode -and $exitCode -ne 0) {
        throw "$FilePath $($ArgumentList -join ' ') failed, exit code: $exitCode"
    }

    return $exitCode
}

function Assert-GhAuthenticated {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $login = (& gh api user --jq .login 2>$null | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "gh is not authenticated. Run: gh auth login"
    }
    if ([string]::IsNullOrWhiteSpace($login)) {
        throw "gh is not authenticated. Run: gh auth login"
    }

    Write-Host "GitHub CLI authenticated as: $login" -ForegroundColor DarkGray
}

function Assert-GitWorktreeCleanForRelease {
    Push-Location $workspaceRoot
    try {
        $statusLines = @(& git status --porcelain --untracked-files=no)
        Assert-LastExitCode -CommandName "git status"
        if ($statusLines.Count -gt 0) {
            $preview = ($statusLines | Select-Object -First 20) -join "`n"
            throw @"
Tracked files have uncommitted changes. Commit or stash them before publishing.

$preview
"@
        }
    } finally {
        Pop-Location
    }
}

function Assert-TagAndReleaseAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName
    )

    Push-Location $workspaceRoot
    try {
        $localTagExit = Invoke-ExternalCommand -FilePath "git" -ArgumentList @("rev-parse", "-q", "--verify", "refs/tags/$TagName") -IgnoreExitCode
        if ($localTagExit -eq 0) {
            throw "Local tag already exists: $TagName"
        }

        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $remoteTag = (& git ls-remote --tags origin "refs/tags/$TagName" 2>$null | Out-String).Trim()
            $remoteExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($null -ne $remoteExit -and $remoteExit -ne 0) {
            throw "git ls-remote failed, exit code: $remoteExit"
        }
        if (-not [string]::IsNullOrWhiteSpace($remoteTag)) {
            throw "Remote tag already exists: $TagName"
        }

        $releaseViewExit = Invoke-ExternalCommand -FilePath "gh" -ArgumentList @("release", "view", $TagName) -IgnoreExitCode
        if ($releaseViewExit -eq 0) {
            throw "GitHub Release already exists: $TagName"
        }
    } finally {
        Pop-Location
    }
}

function Invoke-ReleaseBuilds {
    Write-Host "=== Build Windows Release ===" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "build_windows.ps1") -Release

    Write-Host "=== Build Android Release APK ===" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "build_android.ps1")
}

function New-CleanWindowsDistZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,
        [Parameter(Mandatory = $true)]
        [string]$ZipPath
    )

    if (-not (Test-Path $windowsRunnerReleaseDir)) {
        throw "Windows Release output missing: $windowsRunnerReleaseDir. Run without -SkipBuild or build first."
    }

    $exePath = Join-Path $windowsRunnerReleaseDir "$packageName.exe"
    if (-not (Test-Path $exePath)) {
        throw "Windows Release exe missing: $exePath"
    }

    $stagingRoot = Join-Path $distRoot "staging-$TagName"
    $stagingAppDir = Join-Path $stagingRoot $packageName

    if (Test-Path $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    if (Test-Path $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    New-Item -ItemType Directory -Path $stagingAppDir -Force | Out-Null
    Copy-WindowsProgramArtifacts -SourceDir $windowsRunnerReleaseDir -DestinationDir $stagingAppDir
    Copy-WindowsFfmpegRuntime -PackageDir $stagingAppDir

    $stagedExe = Join-Path $stagingAppDir "$packageName.exe"
    if (-not (Test-Path $stagedExe)) {
        throw "Clean staging missing exe: $stagedExe"
    }

    Compress-Archive -Path $stagingAppDir -DestinationPath $ZipPath -Force
    Assert-CleanWindowsZip -ZipPath $ZipPath

    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    Write-Host "Windows zip ready: $ZipPath" -ForegroundColor Green
}

function Assert-CleanWindowsZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $forbiddenPatterns = @(
            '(^|/)logs(/|$)',
            '(^|/)security(/|$)',
            '(^|/)diagnostics(/|$)',
            '(^|/)recording-export(/|$)',
            '(^|/)recordings(/|$)',
            '(^|/)suno-music(/|$)',
            '(^|/)tomato_api_cache(/|$)',
            '(^|/)picture_book(/|$)',
            '(^|/)song-assets(/|$)',
            '(^|/)user_data(/|$)',
            '(^|/)\.dart_tool(/|$)',
            '(^|/)settings\.json$',
            '(^|/)AccessKey\.txt$',
            '(^|/)speech-api-key\.txt$',
            '\.(db|sqlite|sqlite3)(-wal|-shm)?$'
        )

        $violations = @()
        foreach ($entry in $archive.Entries) {
            $fullName = $entry.FullName.Replace('\', '/')
            foreach ($pattern in $forbiddenPatterns) {
                if ($fullName -match $pattern) {
                    $violations += $fullName
                    break
                }
            }
        }

        if ($violations.Count -gt 0) {
            $preview = ($violations | Select-Object -First 20) -join "`n"
            throw @"
Clean zip validation failed. Forbidden paths found:

$preview
"@
        }

        $exeEntries = @(
            $archive.Entries |
                Where-Object { $_.FullName -replace '\\', '/' -match "/$packageName\.exe$" -or $_.Name -eq "$packageName.exe" }
        )
        if ($exeEntries.Count -lt 1) {
            throw "Clean zip validation failed: $packageName.exe not found inside zip."
        }
    } finally {
        $archive.Dispose()
    }

    Write-Host "Windows zip passed clean-content check." -ForegroundColor Green
}

function New-VersionedAndroidApk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,
        [Parameter(Mandatory = $true)]
        [string]$ApkPath
    )

    if (-not (Test-Path $androidReleaseApk)) {
        throw "Android release APK missing: $androidReleaseApk. Run without -SkipBuild or build first."
    }

    if (Test-Path $ApkPath) {
        Remove-Item -LiteralPath $ApkPath -Force
    }

    Copy-Item -LiteralPath $androidReleaseApk -Destination $ApkPath -Force
    Write-Host "Android APK ready: $ApkPath" -ForegroundColor Green
}

function Publish-GitTagAndRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,
        [Parameter(Mandatory = $true)]
        [string]$VersionValue,
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,
        [Parameter(Mandatory = $true)]
        [string]$ApkPath
    )

    Push-Location $workspaceRoot
    try {
        Write-Host "=== Create annotated tag $TagName ===" -ForegroundColor Cyan
        & git tag -a $TagName -m "Release $TagName"
        Assert-LastExitCode -CommandName "git tag"

        Write-Host "=== Push tag $TagName ===" -ForegroundColor Cyan
        & git push origin $TagName
        Assert-LastExitCode -CommandName "git push origin tag"

        $notes = @"
## Tomato English Happy Talking $TagName

### Assets
- Windows: ``$([System.IO.Path]::GetFileName($ZipPath))`` (clean zip, no local runtime data)
- Android: ``$([System.IO.Path]::GetFileName($ApkPath))``

### Notes
- Android APK currently uses the project debug signing config (not a store keystore).
- Windows package is staged from the Flutter Release runner output plus FFmpeg; it does not include local databases, caches, logs, or API keys.
"@

        $ghArgs = @(
            "release", "create", $TagName,
            $ZipPath,
            $ApkPath,
            "--title", "Tomato English Happy Talking $TagName",
            "--notes", $notes
        )
        if ($Draft) {
            $ghArgs += "--draft"
        }

        Write-Host "=== Create GitHub Release $TagName ===" -ForegroundColor Cyan
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & gh @ghArgs
            $releaseExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($null -ne $releaseExit -and $releaseExit -ne 0) {
            throw "gh release create failed, exit code: $releaseExit"
        }
    } finally {
        Pop-Location
    }
}

# --- main ---

Assert-VersionFormat -Value $Version
$tagName = "v$Version"
$zipFileName = "$packageName-windows-$tagName.zip"
$apkFileName = "$packageName-android-$tagName.apk"
$zipPath = Join-Path $distRoot $zipFileName
$apkPath = Join-Path $distRoot $apkFileName

Write-Host "=== Preflight checks ($tagName) ===" -ForegroundColor Cyan
Assert-VersionFormat -Value $Version
Assert-GitWorktreeCleanForRelease
Assert-GhAuthenticated
Assert-TagAndReleaseAvailable -TagName $tagName

New-Item -ItemType Directory -Path $distRoot -Force | Out-Null

if (-not $SkipBuild) {
    Invoke-ReleaseBuilds
} else {
    Write-Host "SkipBuild enabled; reusing existing build outputs." -ForegroundColor Yellow
}

Write-Host "=== Package clean Windows zip ===" -ForegroundColor Cyan
New-CleanWindowsDistZip -TagName $tagName -ZipPath $zipPath

Write-Host "=== Package versioned Android APK ===" -ForegroundColor Cyan
New-VersionedAndroidApk -TagName $tagName -ApkPath $apkPath

Publish-GitTagAndRelease -TagName $tagName -VersionValue $Version -ZipPath $zipPath -ApkPath $apkPath

Write-Host "`nRelease published: $tagName" -ForegroundColor Green
Write-Host "  Windows: $zipPath"
Write-Host "  Android: $apkPath"
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $releaseUrl = (& gh release view $tagName --json url --jq .url 2>$null | Out-String).Trim()
} finally {
    $ErrorActionPreference = $previousErrorAction
}
if (-not [string]::IsNullOrWhiteSpace($releaseUrl)) {
    Write-Host "  URL: $releaseUrl"
}
