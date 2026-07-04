# Tomato English Happy Talking - Android 编译脚本
# 用法:
#   .\tools\build_android.ps1               -> 构建 Release APK 并复制到 release\android
#   .\tools\build_android.ps1 -Run          -> 在已连接的 Android 设备/模拟器上运行 Debug
#   .\tools\build_android.ps1 -Release -Run -> 构建 Release APK、复制产物，并以 Release 模式运行
#   .\tools\build_android.ps1 -Run -DartDefine "KEY=VALUE","KEY2=VALUE2"
param(
    [switch]$Release,
    [switch]$Run,
    [string]$DeviceId,
    [string[]]$DartDefine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$flutterRoot = "D:\DevTools\flutter"
$flutterExe = Join-Path $flutterRoot "bin\flutter.bat"
$androidSdkRoot = "D:\Android\SDK"
$releaseRoot = Join-Path $workspaceRoot "release"

if (-not (Test-Path $flutterExe)) {
    throw "Flutter 未找到: $flutterExe"
}

$env:PATH = "$($flutterRoot)\bin;" + $env:PATH
$env:ANDROID_HOME = $androidSdkRoot
$env:ANDROID_SDK_ROOT = $androidSdkRoot

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

if (-not $env:PUB_HOSTED_URL) {
    $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
}

if (-not $env:FLUTTER_STORAGE_BASE_URL) {
    $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
}

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

function Expand-DartDefineValues {
    param(
        [string[]]$Values
    )

    $expanded = @()
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $trimmedValue = $value.Trim()
        if ($trimmedValue.StartsWith("--dart-define=")) {
            $trimmedValue = $trimmedValue.Substring("--dart-define=".Length)
        }

        foreach ($part in $trimmedValue.Split(',')) {
            $partTrimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($partTrimmed)) {
                $expanded += $partTrimmed
            }
        }
    }

    return $expanded
}

function Get-FlutterDartDefineArgs {
    param(
        [string[]]$Values
    )

    $dartDefineOptions = @()
    foreach ($value in (Expand-DartDefineValues -Values $Values)) {
        $dartDefineOptions += "--dart-define=$value"
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

function Publish-AndroidReleaseArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppRoot
    )

    $apkSource = Join-Path $AppRoot "build\app\outputs\flutter-apk\app-release.apk"
    if (-not (Test-Path $apkSource)) {
        throw "Android Release APK 未生成: $apkSource"
    }

    $releaseAndroidDir = Join-Path $releaseRoot "android"
    New-Item -ItemType Directory -Path $releaseAndroidDir -Force | Out-Null

    $apkTarget = Join-Path $releaseAndroidDir "tomato_english_happy_talking-android-release.apk"
    $legacyApkTarget = Join-Path $releaseAndroidDir "english_love_reading-android-release.apk"

    if (Test-Path $legacyApkTarget) {
        Remove-Item -Path $legacyApkTarget -Force
    }

    Copy-Item -Path $apkSource -Destination $apkTarget -Force

    $mappingSource = Join-Path $AppRoot "build\app\outputs\mapping\release\mapping.txt"
    if (Test-Path $mappingSource) {
        Copy-Item -Path $mappingSource -Destination (Join-Path $releaseAndroidDir "mapping.txt") -Force
    }

    Write-Host "发布目录已更新: $releaseAndroidDir" -ForegroundColor Green
}

function Resolve-AndroidDeviceId {
    param(
        [string]$PreferredDeviceId,
        [string]$AdbPath
    )

    if ($PreferredDeviceId) {
        return $PreferredDeviceId
    }

    $deviceLines = & $AdbPath devices | Select-Object -Skip 1 | Where-Object {
        $_ -match "\S" -and $_ -notmatch "offline|unauthorized"
    }

    $deviceIds = @(
        foreach ($line in $deviceLines) {
            ($line -split "\s+")[0]
        }
    )

    if ($deviceIds.Count -eq 0) {
        throw "未检测到 Android 设备或模拟器。请先执行 .\tools\setup_android_emulator.ps1 -Start。"
    }

    return $deviceIds[0]
}

Push-Location (Join-Path $workspaceRoot "app")

try {
    Write-Host "=== 检查 Flutter 环境 ===" -ForegroundColor Cyan
    & $flutterExe --version
    Assert-LastExitCode -CommandName "flutter --version"
    Invoke-WebUiBuild

    $adbExe = Join-Path $androidSdkRoot "platform-tools\adb.exe"
    $runInReleaseMode = $Release
    $dartDefineArgs = Get-FlutterDartDefineArgs -Values $DartDefine

    if ($Release -or -not $Run) {
        Write-Host "`n=== 构建 Android Release APK ===" -ForegroundColor Cyan
        $buildArgs = @("build", "apk", "--release") + $dartDefineArgs
        & $flutterExe @buildArgs
        Assert-LastExitCode -CommandName "flutter build apk --release"
        Publish-AndroidReleaseArtifacts -AppRoot (Get-Location).Path
        Write-Host "`n构建完成: build\\app\\outputs\\flutter-apk\\app-release.apk" -ForegroundColor Green
    }

    if ($Run) {
        $resolvedDeviceId = Resolve-AndroidDeviceId -PreferredDeviceId $DeviceId -AdbPath $adbExe
        $runArgs = @("run", "-d", $resolvedDeviceId) + $dartDefineArgs
        if ($runInReleaseMode) {
            $runArgs += "--release"
        }

        Write-Host "`n=== 启动 Android 应用 ($resolvedDeviceId) ===" -ForegroundColor Cyan
        & $flutterExe @runArgs
        if ($runInReleaseMode) {
            Assert-LastExitCode -CommandName "flutter run --release (android)"
        } else {
            Assert-LastExitCode -CommandName "flutter run (android)"
        }
    }
} finally {
    Pop-Location
}
