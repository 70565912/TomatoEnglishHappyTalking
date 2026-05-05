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

function Get-FlutterDartDefineArgs {
    param(
        [string[]]$Values
    )

    $args = @()
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $trimmedValue = $value.Trim()
        if ($trimmedValue.StartsWith("--dart-define=")) {
            $args += $trimmedValue
        } else {
            $args += "--dart-define=$trimmedValue"
        }
    }

    return $args
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