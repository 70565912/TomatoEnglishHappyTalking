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

    if (Test-Path $legacyPackageDir) {
        Remove-Item -Path $legacyPackageDir -Recurse -Force
    }

    if (Test-Path $packageDir) {
        Remove-Item -Path $packageDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    Copy-Item -Path (Join-Path $BuildOutputDir "*") -Destination $packageDir -Recurse -Force

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
        Write-Host "`n=== 构建并运行 Windows Debug ===" -ForegroundColor Cyan
        if ($Run) {
            $runArgs = @("run", "-d", "windows") + $dartDefineArgs
            & $flutterExe @runArgs
            Assert-LastExitCode -CommandName "flutter run -d windows"
        } else {
            $buildArgs = @("build", "windows") + $dartDefineArgs
            & $flutterExe @buildArgs
            Assert-LastExitCode -CommandName "flutter build windows"
            $exePath = "build\windows\x64\runner\Debug\tomato_english_happy_talking.exe"
            Write-Host "`n构建完成: $exePath" -ForegroundColor Green
        }
    }
} finally {
    Pop-Location
}