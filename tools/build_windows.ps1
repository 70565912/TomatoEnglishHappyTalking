# Tomato English Happy Talking - Windows 编译脚本
# 用法: .\tools\build_windows.ps1 [-Release] [-Run] [-DartDefine KEY=VALUE[,KEY=VALUE...]]
#
# Encoding guard:
# Keep this file saved as UTF-8 with BOM. Windows PowerShell 5.1 may parse a
# UTF-8 file without BOM as the local ANSI code page, which can corrupt Chinese
# quoted strings and make this script fail before execution. If an editor cannot
# preserve the BOM, keep newly added quoted log/error strings ASCII-only.
param(
    [switch]$Release,
    [switch]$Run,
    [string[]]$DartDefine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot

# 固定 Flutter 路径，避免不同终端 PATH 不一致
$flutterRoot = "D:\DevTools\flutter"
$flutterExe = Join-Path $flutterRoot "bin\flutter.bat"

if (-not (Test-Path $flutterExe)) {
    throw "Flutter 未找到: $flutterExe"
}

$env:PATH = "$($flutterRoot)\bin;" + $env:PATH

function Initialize-FlutterGitTrust {
    $toolingRoot = Join-Path $workspaceRoot ".tmp\tooling"
    New-Item -ItemType Directory -Path $toolingRoot -Force | Out-Null

    $env:GIT_CONFIG_GLOBAL = Join-Path $toolingRoot "flutter-safe-gitconfig"

    foreach ($safePath in @($flutterRoot, $workspaceRoot)) {
        $normalizedPath = $safePath.Replace("\", "/")
        $existingValues = @(& git config --global --get-all safe.directory 2>$null)
        if ($existingValues -notcontains $normalizedPath) {
            & git config --global --add safe.directory $normalizedPath
            Assert-LastExitCode -CommandName "git config safe.directory"
        }
    }
}

$wingetLinksDir = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"
if (Test-Path (Join-Path $wingetLinksDir "nuget.exe")) {
    $env:PATH = "$wingetLinksDir;" + $env:PATH
}

# 使用国内镜像，加快首次依赖下载
if (-not $env:PUB_HOSTED_URL) {
    $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
}

if (-not $env:FLUTTER_STORAGE_BASE_URL) {
    $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
}

$releaseRoot = Join-Path $workspaceRoot "release"

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$CommandName 失败，退出码: $LASTEXITCODE"
    }
}

function Initialize-FlutterToolEnvironment {
    $env:FLUTTER_SUPPRESS_ANALYTICS = "true"

    $cacheLockPath = Join-Path $flutterRoot "bin\cache\lockfile"
    try {
        $lockParent = Split-Path -Parent $cacheLockPath
        New-Item -ItemType Directory -Path $lockParent -Force | Out-Null
        $lockProbe = [System.IO.File]::Open(
            $cacheLockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite
        )
        $lockProbe.Dispose()
    } catch {
        throw @"
Flutter SDK cache is not writable from this process:
  $cacheLockPath

Run this build outside the sandbox or with approved escalation. Otherwise the
Flutter tool can hang at the Windows build step until the outer command times out.
"@
    }
}

Initialize-FlutterGitTrust
Initialize-FlutterToolEnvironment

function Get-FlutterDartDefineArgs {
    param(
        [string[]]$Values
    )

    $dartDefineOptions = @()
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $trimmedValue = $value.Trim()
        if ($trimmedValue.StartsWith("--dart-define=")) {
            $dartDefineOptions += $trimmedValue
        } else {
            $dartDefineOptions += "--dart-define=$trimmedValue"
        }
    }

    return $dartDefineOptions
}

function Test-DartDefineKeyPresent {
    param(
        [string[]]$Values,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $trimmedValue = $value.Trim()
        $normalizedValue = $trimmedValue
        if ($normalizedValue.StartsWith("--dart-define=")) {
            $normalizedValue = $normalizedValue.Substring("--dart-define=".Length)
        }

        if ($normalizedValue.StartsWith("$Key=", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Add-DebugDesktopDataRootDefine {
    param(
        [string[]]$Values
    )

    if (Test-DartDefineKeyPresent -Values $Values -Key "TOMATO_DESKTOP_DATA_ROOT") {
        return @($Values)
    }

    $debugDataRoot = Join-Path $releaseRoot "windows\tomato_english_happy_talking"
    New-Item -ItemType Directory -Path $debugDataRoot -Force | Out-Null
    Write-Host "Debug 将复用发布目录运行数据: $debugDataRoot" -ForegroundColor DarkGray
    return @($Values) + "TOMATO_DESKTOP_DATA_ROOT=$debugDataRoot"
}

function Get-OptionalFileHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

function Get-WebUiDependencyStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebUiRoot
    )

    return Join-Path $WebUiRoot "node_modules\.tomato-package-lock.sha256"
}

function Save-WebUiDependencyState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebUiRoot,
        [string]$PackageLockHash
    )

    if ([string]::IsNullOrWhiteSpace($PackageLockHash)) {
        return
    }

    $stateFilePath = Get-WebUiDependencyStatePath -WebUiRoot $WebUiRoot
    Set-Content -Path $stateFilePath -Value $PackageLockHash -NoNewline
}

function Test-WebUiDependenciesReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebUiRoot,
        [Parameter(Mandatory = $true)]
        [string]$NpmExe,
        [string]$PackageLockHash
    )

    $nodeModulesPath = Join-Path $WebUiRoot "node_modules"
    if (-not (Test-Path $nodeModulesPath)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($PackageLockHash)) {
        $stateFilePath = Get-WebUiDependencyStatePath -WebUiRoot $WebUiRoot
        if (Test-Path $stateFilePath) {
            $savedHash = (Get-Content -Path $stateFilePath -Raw).Trim()
            return $savedHash -eq $PackageLockHash
        }
    }

    $null = & $NpmExe ls --depth=0 --silent 2>$null
    $dependenciesReady = $LASTEXITCODE -eq 0

    if ($dependenciesReady) {
        Save-WebUiDependencyState -WebUiRoot $WebUiRoot -PackageLockHash $PackageLockHash
    }

    return $dependenciesReady
}

function Sync-WebUiBuildArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    if (-not (Test-Path $SourceRoot)) {
        throw "Web UI 构建输出不存在: $SourceRoot"
    }

    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null

    Get-ChildItem -Path $DestinationRoot -Force | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force
    }

    Copy-Item -Path (Join-Path $SourceRoot "*") -Destination $DestinationRoot -Recurse -Force
}

function Invoke-WebUiBuildInTempWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebUiRoot,
        [Parameter(Mandatory = $true)]
        [string]$NpmExe
    )

    $tempWorkspaceRoot = Join-Path $env:TEMP ("tomato-web-ui-build-" + [guid]::NewGuid().ToString("N"))
    $tempWebUiRoot = Join-Path $tempWorkspaceRoot "web_ui"
    $tempOutputRoot = Join-Path $tempWorkspaceRoot "app\assets\web"
    $workspaceOutputRoot = Join-Path $workspaceRoot "app\assets\web"

    New-Item -ItemType Directory -Path $tempWebUiRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $tempOutputRoot -Force | Out-Null

    try {
        Get-ChildItem -Path $WebUiRoot -Force | Where-Object {
            $_.Name -ne "node_modules"
        } | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination (Join-Path $tempWebUiRoot $_.Name) -Recurse -Force
        }

        Push-Location $tempWebUiRoot
        try {
            Write-Host "检测到本地依赖目录被占用，改用临时目录构建 Web UI。" -ForegroundColor Yellow
            if (Test-Path (Join-Path $tempWebUiRoot "package-lock.json")) {
                & $NpmExe ci
                Assert-LastExitCode -CommandName "npm ci (temp web_ui)"
            } else {
                & $NpmExe install
                Assert-LastExitCode -CommandName "npm install (temp web_ui)"
            }

            & $NpmExe run build
            Assert-LastExitCode -CommandName "npm run build (temp web_ui)"
        } finally {
            Pop-Location
        }

        Sync-WebUiBuildArtifacts -SourceRoot $tempOutputRoot -DestinationRoot $workspaceOutputRoot
    } finally {
        if (Test-Path $tempWorkspaceRoot) {
            Remove-Item -Path $tempWorkspaceRoot -Recurse -Force
        }
    }
}

function Invoke-WebUiBuild {
    $webUiRoot = Join-Path $workspaceRoot "web_ui"
    if (-not (Test-Path (Join-Path $webUiRoot "package.json"))) {
        throw "Web UI 项目不存在: $webUiRoot"
    }

    $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($null -eq $npmCommand) {
        $npmCommand = Get-Command npm -ErrorAction Stop
    }
    $npmExe = $npmCommand.Source
    $packageLockPath = Join-Path $webUiRoot "package-lock.json"
    $packageLockHash = Get-OptionalFileHash -Path $packageLockPath
    $shouldUseTempBuild = $false

    Push-Location $webUiRoot
    try {
        Write-Host "`n=== 构建 Web UI ===" -ForegroundColor Cyan
        try {
            if (Test-WebUiDependenciesReady -WebUiRoot $webUiRoot -NpmExe $npmExe -PackageLockHash $packageLockHash) {
                Write-Host "Web UI dependencies unchanged; skipping npm install." -ForegroundColor DarkGray
            } elseif (Test-Path $packageLockPath) {
                & $npmExe ci
                Assert-LastExitCode -CommandName "npm ci"
                Save-WebUiDependencyState -WebUiRoot $webUiRoot -PackageLockHash $packageLockHash
            } else {
                & $npmExe install
                Assert-LastExitCode -CommandName "npm install"
            }

            & $npmExe run build
            Assert-LastExitCode -CommandName "npm run build"
        } catch {
            if (-not (Test-Path (Join-Path $webUiRoot "node_modules"))) {
                throw
            }

            $shouldUseTempBuild = $true
        }
    } finally {
        Pop-Location
    }

    if ($shouldUseTempBuild) {
        Invoke-WebUiBuildInTempWorkspace -WebUiRoot $webUiRoot -NpmExe $npmExe
    }
}

function Assert-PathInsideDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedParent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
    $prefix = $resolvedParent + [System.IO.Path]::DirectorySeparatorChar

    if (-not ($resolvedPath.Equals($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase) -or
        $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "路径不在预期目录内，拒绝操作: $resolvedPath"
    }
}

function New-WindowsRuntimeBackupDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot
    )

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $suffix = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
    return Join-Path $BackupRoot ("runtime-data-$timestamp-$suffix")
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

    Assert-PathInsideDirectory -Path $PackageDir -ParentPath (Split-Path -Parent $PackageDir)

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

function Ensure-WindowsRuntimeDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    foreach ($relativePath in @(Get-WindowsRuntimeDirectories)) {
        $destinationPath = Join-Path $PackageDir $relativePath
        Assert-PathInsideDirectory -Path $destinationPath -ParentPath $PackageDir
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    }
}

function Get-WindowsRuntimeFiles {
    return @(
        "AccessKey.txt",
        "speech-api-key.txt",
        "settings.json"
    )
}

function Normalize-WindowsRelativePath {
    param(
        [string]$Path
    )

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
    }

    return $false
}

function Test-HasPreservedWindowsRuntimeDescendants {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $normalized = Normalize-WindowsRelativePath $RelativePath
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $true
    }

    $prefix = "$normalized\"
    foreach ($runtimePath in @(Get-WindowsRuntimeDirectories) + @(Get-WindowsRuntimeFiles)) {
        $candidate = Normalize-WindowsRelativePath $runtimePath
        if ($candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
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

    $parentPath = [System.IO.Path]::GetDirectoryName($normalized)
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        return ([System.IO.Path]::GetFileName($normalized) -match '\.(db|sqlite|sqlite3)(-wal|-shm)?$')
    }

    return $false
}

function Clear-WindowsReleaseProgramFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    if (-not (Test-Path $PackageDir)) {
        return @()
    }

    $removedItems = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $PackageDir -Force)) {
        $relativePath = Get-WindowsRelativePath -Path $item.FullName -BaseDir $PackageDir

        if ($item.PSIsContainer) {
            if (Test-IsPreservedWindowsRuntimeDirectory -RelativePath $relativePath) {
                continue
            }

            if (Test-HasPreservedWindowsRuntimeDescendants -RelativePath $relativePath) {
                $removedItems += @(Clear-WindowsReleaseProgramFiles -PackageDir $item.FullName)
                if (-not (Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                    Assert-PathInsideDirectory -Path $item.FullName -ParentPath $PackageDir
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force
                    $removedItems += $relativePath
                }
                continue
            }

            Assert-PathInsideDirectory -Path $item.FullName -ParentPath $PackageDir
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
            $removedItems += $relativePath
            continue
        }

        if (Test-IsPreservedWindowsRuntimeFile -RelativePath $relativePath) {
            continue
        }

        Assert-PathInsideDirectory -Path $item.FullName -ParentPath $PackageDir
        Remove-Item -LiteralPath $item.FullName -Force
        $removedItems += $relativePath
    }

    return $removedItems
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
            if (Test-HasPreservedWindowsRuntimeDescendants -RelativePath $relativePath) {
                Copy-WindowsProgramArtifacts -SourceDir $item.FullName -DestinationDir $destinationPath -RootSourceDir $RootSourceDir
                continue
            }

            Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Recurse -Force
            continue
        }

        if (Test-IsPreservedWindowsRuntimeFile -RelativePath $relativePath) {
            continue
        }

        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $DestinationDir $item.Name) -Force
    }
}

function Assert-WindowsReleasePackageNotRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$ProcessName
    )

    if (-not (Test-Path $PackageDir)) {
        return
    }

    $resolvedPackageDir = (Resolve-Path -LiteralPath $PackageDir).Path.TrimEnd('\')
    $packagePrefix = "$resolvedPackageDir\"
    $blockingProcesses = @()

    foreach ($process in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        $processPath = $null
        try {
            $processPath = $process.Path
        } catch {
            $processPath = $null
        }

        if ([string]::IsNullOrWhiteSpace($processPath)) {
            continue
        }

        $resolvedProcessPath = $null
        try {
            $resolvedProcessPath = (Resolve-Path -LiteralPath $processPath -ErrorAction Stop).Path
        } catch {
            $resolvedProcessPath = $processPath
        }

        if ($resolvedProcessPath.StartsWith($packagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $blockingProcesses += $process
        }
    }

    if ($blockingProcesses.Count -eq 0) {
        return
    }

    $processSummary = @(
        $blockingProcesses |
            ForEach-Object { "PID $($_.Id)" }
    ) -join ', '
    throw "发布目录正在被运行中的程序占用，请先关闭 Tomato English Happy Talking 后重试。占用进程: $processSummary"
}

function Restore-WindowsRuntimeData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    if (-not (Test-Path $BackupDir)) {
        return @()
    }

    $restoredItems = @()
    $runtimeDirectories = @(Get-WindowsRuntimeDirectories)

    foreach ($relativePath in $runtimeDirectories) {
        $sourcePath = Join-Path $BackupDir $relativePath
        if (-not (Test-Path $sourcePath)) {
            continue
        }

        $destinationPath = Join-Path $PackageDir $relativePath
        Assert-PathInsideDirectory -Path $destinationPath -ParentPath $PackageDir
        $destinationParent = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        if (Test-Path $destinationPath) {
            Remove-Item -LiteralPath $destinationPath -Recurse -Force
        }
        Move-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $restoredItems += $relativePath
    }

    $runtimeFiles = @(Get-WindowsRuntimeFiles)

    foreach ($relativePath in $runtimeFiles) {
        $sourcePath = Join-Path $BackupDir $relativePath
        if (-not (Test-Path $sourcePath)) {
            continue
        }

        $destinationPath = Join-Path $PackageDir $relativePath
        Assert-PathInsideDirectory -Path $destinationPath -ParentPath $PackageDir
        Move-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $restoredItems += $relativePath
    }

    Get-ChildItem -LiteralPath $BackupDir -File -Force | Where-Object {
        $_.Name -match '\.(db|sqlite|sqlite3)(-wal|-shm)?$'
    } | ForEach-Object {
        $destinationPath = Join-Path $PackageDir $_.Name
        Assert-PathInsideDirectory -Path $destinationPath -ParentPath $PackageDir
        Move-Item -LiteralPath $_.FullName -Destination $destinationPath -Force
        $restoredItems += $_.Name
    }

    return $restoredItems
}

function Move-WindowsRuntimeDataToBackup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot
    )

    if (-not (Test-Path $PackageDir)) {
        return $null
    }

    $backupDir = New-WindowsRuntimeBackupDirectory -BackupRoot $BackupRoot
    $movedItems = @()

    foreach ($relativePath in @(Get-WindowsRuntimeDirectories)) {
        $sourcePath = Join-Path $PackageDir $relativePath
        if (-not (Test-Path $sourcePath)) {
            continue
        }

        $destinationPath = Join-Path $backupDir $relativePath
        Assert-PathInsideDirectory -Path $sourcePath -ParentPath $PackageDir
        Assert-PathInsideDirectory -Path $destinationPath -ParentPath $backupDir
        $destinationParent = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Move-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $movedItems += $relativePath
    }

    foreach ($relativePath in @(Get-WindowsRuntimeFiles)) {
        $sourcePath = Join-Path $PackageDir $relativePath
        if (-not (Test-Path $sourcePath)) {
            continue
        }

        $destinationPath = Join-Path $backupDir $relativePath
        Assert-PathInsideDirectory -Path $sourcePath -ParentPath $PackageDir
        Assert-PathInsideDirectory -Path $destinationPath -ParentPath $backupDir
        $destinationParent = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Move-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $movedItems += $relativePath
    }

    Get-ChildItem -LiteralPath $PackageDir -File -Force | Where-Object {
        $_.Name -match '\.(db|sqlite|sqlite3)(-wal|-shm)?$'
    } | ForEach-Object {
        $destinationPath = Join-Path $backupDir $_.Name
        Assert-PathInsideDirectory -Path $_.FullName -ParentPath $PackageDir
        Assert-PathInsideDirectory -Path $destinationPath -ParentPath $backupDir
        Move-Item -LiteralPath $_.FullName -Destination $destinationPath -Force
        $movedItems += $_.Name
    }

    if ($movedItems.Count -eq 0) {
        if (Test-Path $backupDir) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force
        }
        return $null
    }

    [PSCustomObject]@{
        Path = $backupDir
        Items = $movedItems
    }
}

function Publish-WindowsPackageArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildOutputDir,
        [Parameter(Mandatory = $true)]
        [string]$BuildConfiguration
    )

    if (-not (Test-Path $BuildOutputDir)) {
        throw "Windows $BuildConfiguration 输出目录不存在: $BuildOutputDir"
    }

    $releaseWindowsDir = Join-Path $releaseRoot "windows"
    $packageDir = Join-Path $releaseWindowsDir "tomato_english_happy_talking"
    $legacyPackageDir = Join-Path $releaseWindowsDir "english_love_reading"
    $runtimeBackupRoot = Join-Path $releaseWindowsDir ".runtime_backups"
    $runtimeBackup = $null

    if (Test-Path $legacyPackageDir) {
        Assert-PathInsideDirectory -Path $legacyPackageDir -ParentPath $releaseWindowsDir
        Remove-Item -LiteralPath $legacyPackageDir -Recurse -Force
    }

    Assert-WindowsReleasePackageNotRunning -PackageDir $packageDir -ProcessName "tomato_english_happy_talking"
    if (Test-Path $packageDir) {
        Assert-PathInsideDirectory -Path $packageDir -ParentPath $releaseWindowsDir
        $runtimeBackup = Move-WindowsRuntimeDataToBackup -PackageDir $packageDir -BackupRoot $runtimeBackupRoot
        if ($null -ne $runtimeBackup) {
            Write-Host "已移出发布目录运行数据: $($runtimeBackup.Path)" -ForegroundColor Yellow
        }
    }

    try {
        New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
        $removedItems = @(Clear-WindowsReleaseProgramFiles -PackageDir $packageDir)
        if ($removedItems.Count -gt 0) {
            Write-Host "Cleaned old program artifacts: $($removedItems.Count)" -ForegroundColor Yellow
        }
        Copy-WindowsProgramArtifacts -SourceDir $BuildOutputDir -DestinationDir $packageDir
        Copy-WindowsFfmpegRuntime -PackageDir $packageDir
        Ensure-WindowsRuntimeDirectories -PackageDir $packageDir

        if ($null -ne $runtimeBackup -and (Test-Path $runtimeBackup.Path)) {
            $restoredItems = @(Restore-WindowsRuntimeData -BackupDir $runtimeBackup.Path -PackageDir $packageDir)
            Write-Host "已恢复发布目录运行数据: $($restoredItems.Count)" -ForegroundColor Green
            if (-not (Get-ChildItem -LiteralPath $runtimeBackup.Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $runtimeBackup.Path -Recurse -Force
            }
        }
    } catch {
        if ($null -ne $runtimeBackup -and (Test-Path $runtimeBackup.Path)) {
            Restore-WindowsRuntimeData -BackupDir $runtimeBackup.Path -PackageDir $packageDir | Out-Null
        }
        throw
    }

    Write-Host "Windows $BuildConfiguration 程序目录已更新: $packageDir" -ForegroundColor Green
    return $packageDir
}

function Publish-WindowsReleaseArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildOutputDir
    )

    return Publish-WindowsPackageArtifacts -BuildOutputDir $BuildOutputDir -BuildConfiguration "Release"
}

function Publish-WindowsDebugArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildOutputDir
    )

    return Publish-WindowsPackageArtifacts -BuildOutputDir $BuildOutputDir -BuildConfiguration "Debug"
}

function Clear-StaleWindowsBuildCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppRoot,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedBinaryName
    )

    $windowsBuildDir = Join-Path $AppRoot "build\windows"
    $cmakeCachePath = Join-Path $windowsBuildDir "x64\CMakeCache.txt"

    if (-not (Test-Path $cmakeCachePath)) {
        return
    }

    $cmakeCache = Get-Content -Path $cmakeCachePath -Raw
    if ($cmakeCache -match 'TARGET_FILE_DIR:' -and
        $cmakeCache -notmatch [regex]::Escape("TARGET_FILE_DIR:$ExpectedBinaryName")) {
        Write-Host "检测到旧的 Windows 构建缓存，正在清理: $windowsBuildDir" -ForegroundColor Yellow
        Remove-Item -Path $windowsBuildDir -Recurse -Force
    }
}

# 切换到 app 目录
Push-Location (Join-Path $workspaceRoot "app")

try {
    Write-Host "=== 检查 Flutter 环境 ===" -ForegroundColor Cyan
    Write-Host "Flutter SDK: $flutterExe" -ForegroundColor DarkGray
    Invoke-WebUiBuild
    Clear-StaleWindowsBuildCache -AppRoot (Get-Location).Path -ExpectedBinaryName "tomato_english_happy_talking"

    if ($Release) {
        $dartDefineArgs = Get-FlutterDartDefineArgs -Values $DartDefine
        Write-Host "`n=== 构建 Windows Release ===" -ForegroundColor Cyan
        $buildArgs = @("build", "windows", "--release") + $dartDefineArgs
        & $flutterExe @buildArgs
        Assert-LastExitCode -CommandName "flutter build windows --release"
        $releasePackageDir = Publish-WindowsReleaseArtifacts -BuildOutputDir (Join-Path (Get-Location) "build\windows\x64\runner\Release")
        $releaseExePath = Join-Path $releasePackageDir "tomato_english_happy_talking.exe"
        Write-Host "`n构建完成: $releaseExePath" -ForegroundColor Green
        if ($Run) {
            Write-Host "`n=== 启动应用 ===" -ForegroundColor Cyan
            Start-Process -FilePath $releaseExePath -WorkingDirectory $releasePackageDir
        }
    } else {
        $debugDartDefine = Add-DebugDesktopDataRootDefine -Values $DartDefine
        $dartDefineArgs = Get-FlutterDartDefineArgs -Values $debugDartDefine
        Write-Host "`n=== Build or run Windows Debug ===" -ForegroundColor Cyan
        $buildArgs = @("build", "windows", "--debug") + $dartDefineArgs
        & $flutterExe @buildArgs
        Assert-LastExitCode -CommandName "flutter build windows --debug"
        $debugPackageDir = Publish-WindowsDebugArtifacts -BuildOutputDir (Join-Path (Get-Location) "build\windows\x64\runner\Debug")
        $debugExePath = Join-Path $debugPackageDir "tomato_english_happy_talking.exe"
        Write-Host "`nBuild complete: $debugExePath" -ForegroundColor Green
        if ($Run) {
            Write-Host "`n=== Start app ===" -ForegroundColor Cyan
            Start-Process -FilePath $debugExePath -WorkingDirectory $debugPackageDir
        }
    }
} finally {
    Pop-Location
}
