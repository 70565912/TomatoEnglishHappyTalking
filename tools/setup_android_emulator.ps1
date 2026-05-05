# Tomato English Happy Talking - Android 模拟器环境部署脚本
# 用法:
#   .\tools\setup_android_emulator.ps1
#   .\tools\setup_android_emulator.ps1 -Start
param(
    [switch]$Start,
    [string]$AvdName = "EnglishRead_API_35",
    [string]$DeviceProfile = "pixel_7",
    [string]$SystemImage = "system-images;android-35;google_apis;x86_64"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sdkRoot = "D:\Android\SDK"
$androidUserHome = "D:\Android\.android"
$androidAvdHome = Join-Path $androidUserHome "avd"
$cmdlineToolsRoot = Join-Path $sdkRoot "cmdline-tools\latest\bin"
$sdkManager = Join-Path $cmdlineToolsRoot "sdkmanager.bat"
$avdManager = Join-Path $cmdlineToolsRoot "avdmanager.bat"
$emulatorExe = Join-Path $sdkRoot "emulator\emulator.exe"
$adbExe = Join-Path $sdkRoot "platform-tools\adb.exe"

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$CommandName 失败，退出码: $LASTEXITCODE"
    }
}

if (-not (Test-Path $sdkManager)) {
    throw "sdkmanager 未找到: $sdkManager"
}

if (-not (Test-Path $avdManager)) {
    throw "avdmanager 未找到: $avdManager"
}

New-Item -ItemType Directory -Path $sdkRoot -Force | Out-Null
New-Item -ItemType Directory -Path $androidUserHome -Force | Out-Null
New-Item -ItemType Directory -Path $androidAvdHome -Force | Out-Null

$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:ANDROID_USER_HOME = $androidUserHome
$env:ANDROID_AVD_HOME = $androidAvdHome

[Environment]::SetEnvironmentVariable("ANDROID_HOME", $sdkRoot, "User")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $sdkRoot, "User")
[Environment]::SetEnvironmentVariable("ANDROID_USER_HOME", $androidUserHome, "User")
[Environment]::SetEnvironmentVariable("ANDROID_AVD_HOME", $androidAvdHome, "User")

Write-Host "=== 安装 Android 模拟器组件 ===" -ForegroundColor Cyan
& $sdkManager --install "platform-tools" "emulator" "platforms;android-35" $SystemImage
Assert-LastExitCode -CommandName "sdkmanager --install"

if (-not (Test-Path $emulatorExe)) {
    throw "Android Emulator 安装失败: $emulatorExe"
}

$existingAvdOutput = & $avdManager list avd
if ($existingAvdOutput -notmatch [regex]::Escape("Name: $AvdName")) {
    Write-Host "`n=== 创建 Android 模拟器 ===" -ForegroundColor Cyan
    $createCommand = 'echo no|"{0}" create avd -n "{1}" -k "{2}" -d "{3}" --force' -f $avdManager, $AvdName, $SystemImage, $DeviceProfile
    cmd /c $createCommand | Out-Host
    Assert-LastExitCode -CommandName "avdmanager create avd"
}

if ($Start) {
    Write-Host "`n=== 启动 Android 模拟器 ===" -ForegroundColor Cyan
    Start-Process -FilePath $emulatorExe -ArgumentList @("-avd", $AvdName, "-netdelay", "none", "-netspeed", "full") | Out-Null
    & $adbExe wait-for-device
    Assert-LastExitCode -CommandName "adb wait-for-device"

    do {
        Start-Sleep -Seconds 5
        $bootCompleted = (& $adbExe shell getprop sys.boot_completed 2>$null).Trim()
    } while ($bootCompleted -ne "1")

    Write-Host "模拟器已启动: $AvdName" -ForegroundColor Green
}