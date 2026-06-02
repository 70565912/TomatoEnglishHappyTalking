# Tomato English Happy Talking - Windows 编译脚本
# 用法: .\tools\build_windows.ps1 [-Release] [-Run] [-DartDefine KEY=VALUE[,KEY=VALUE...]]
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

Initialize-FlutterGitTrust

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
                Write-Host "检测到 Web UI 依赖未变更，跳过 npm 安装。" -ForegroundColor DarkGray
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

function Publish-WindowsReleaseArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildOutputDir
    )

    if (-not (Test-Path $BuildOutputDir)) {
        throw "Windows Release 输出目录不存在: $BuildOutputDir"
    }

    $releaseWindowsDir = Join-Path $releaseRoot "windows"
    $packageDir = Join-Path $releaseWindowsDir "tomato_english_happy_talking"
    $legacyPackageDir = Join-Path $releaseWindowsDir "english_love_reading"
    $runtimeDataBackupDir = $null

    if (Test-Path $legacyPackageDir) {
        Remove-Item -Path $legacyPackageDir -Recurse -Force
    }

    if (Test-Path $packageDir) {
        $runtimeDataDir = Join-Path $packageDir ".dart_tool"
        if (Test-Path $runtimeDataDir) {
            $runtimeDataBackupDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tomato-runtime-data-" + [System.Guid]::NewGuid().ToString("N"))
            Copy-Item -Path $runtimeDataDir -Destination $runtimeDataBackupDir -Recurse -Force
        }
        Remove-Item -Path $packageDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    Copy-Item -Path (Join-Path $BuildOutputDir "*") -Destination $packageDir -Recurse -Force
    if ($null -ne $runtimeDataBackupDir -and (Test-Path $runtimeDataBackupDir)) {
        Copy-Item -Path $runtimeDataBackupDir -Destination (Join-Path $packageDir ".dart_tool") -Recurse -Force
        Remove-Item -Path $runtimeDataBackupDir -Recurse -Force
        Write-Host "已保留发布目录运行数据: .dart_tool" -ForegroundColor Yellow
    }

    Write-Host "发布目录已更新: $packageDir" -ForegroundColor Green
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
    & $flutterExe --version
    Assert-LastExitCode -CommandName "flutter --version"
    Invoke-WebUiBuild
    Clear-StaleWindowsBuildCache -AppRoot (Get-Location).Path -ExpectedBinaryName "tomato_english_happy_talking"

    $dartDefineArgs = Get-FlutterDartDefineArgs -Values $DartDefine

    if ($Release) {
        Write-Host "`n=== 构建 Windows Release ===" -ForegroundColor Cyan
        $buildArgs = @("build", "windows", "--release") + $dartDefineArgs
        & $flutterExe @buildArgs
        Assert-LastExitCode -CommandName "flutter build windows --release"
        $exePath = "build\windows\x64\runner\Release\tomato_english_happy_talking.exe"
        Publish-WindowsReleaseArtifacts -BuildOutputDir (Join-Path (Get-Location) "build\windows\x64\runner\Release")
        Write-Host "`n构建完成: $exePath" -ForegroundColor Green
        if ($Run) {
            Write-Host "`n=== 启动应用 ===" -ForegroundColor Cyan
            Start-Process $exePath
        }
    } else {
        Write-Host "`n=== 构建或运行 Windows Debug ===" -ForegroundColor Cyan
        if ($Run) {
            $runArgs = @("run", "-d", "windows") + $dartDefineArgs
            & $flutterExe @runArgs
            Assert-LastExitCode -CommandName "flutter run -d windows"
        } else {
            $buildArgs = @("build", "windows", "--debug") + $dartDefineArgs
            & $flutterExe @buildArgs
            Assert-LastExitCode -CommandName "flutter build windows --debug"
            $exePath = "build\windows\x64\runner\Debug\tomato_english_happy_talking.exe"
            Write-Host "`n构建完成: $exePath" -ForegroundColor Green
        }
    }
} finally {
    Pop-Location
}
