# Tomato English Happy Talking - 启动 Android 模拟器并运行 Debug 脚本
# 用法:
#   .\tools\run_android_debug.ps1
#   .\tools\run_android_debug.ps1 -AvdName EnglishRead_API_35
#   .\tools\run_android_debug.ps1 -DeviceId emulator-5554
#   .\tools\run_android_debug.ps1 -DartDefine "KEY=VALUE","KEY2=VALUE2"
param(
    [string]$AvdName = "EnglishRead_API_35",
    [string]$DeviceId,
    [int]$BootTimeoutSeconds = 300,
    [string[]]$DartDefine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$androidSdkRoot = "D:\Android\SDK"
$androidUserHome = "D:\Android\.android"
$androidAvdHome = Join-Path $androidUserHome "avd"
$emulatorExe = Join-Path $androidSdkRoot "emulator\emulator.exe"
$adbExe = Join-Path $androidSdkRoot "platform-tools\adb.exe"
$buildScript = Join-Path $PSScriptRoot "build_android.ps1"

if (-not (Test-Path $emulatorExe)) {
    throw "Android Emulator 未找到: $emulatorExe。请先执行 .\tools\setup_android_emulator.ps1"
}

if (-not (Test-Path $adbExe)) {
    throw "adb 未找到: $adbExe。请先执行 .\tools\setup_android_emulator.ps1"
}

if (-not (Test-Path $buildScript)) {
    throw "构建脚本未找到: $buildScript"
}

$env:ANDROID_HOME = $androidSdkRoot
$env:ANDROID_SDK_ROOT = $androidSdkRoot
$env:ANDROID_USER_HOME = $androidUserHome
$env:ANDROID_AVD_HOME = $androidAvdHome

function Get-ConnectedAndroidDeviceIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath
    )

    $deviceIds = @()
    $deviceLines = & $AdbPath devices

    foreach ($line in $deviceLines) {
        if ($line -match '^(?<deviceId>\S+)\s+device\b') {
            $deviceIds += $Matches.deviceId
        }
    }

    return $deviceIds
}

function Wait-ForAndroidDevice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [string]$PreferredDeviceId,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $deviceIds = Get-ConnectedAndroidDeviceIds -AdbPath $AdbPath

        if ($PreferredDeviceId) {
            if ($deviceIds -contains $PreferredDeviceId) {
                return $PreferredDeviceId
            }
        } else {
            $emulatorId = @($deviceIds | Where-Object { $_ -like 'emulator-*' } | Select-Object -First 1)
            if ($emulatorId.Count -gt 0) {
                return $emulatorId[0]
            }
        }

        Start-Sleep -Seconds 5
    }

    if ($PreferredDeviceId) {
        throw "等待设备超时: $PreferredDeviceId"
    }

    throw "等待模拟器连接超时。请确认 AVD 已成功启动。"
}

function Wait-ForAndroidBootCompleted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetDeviceId,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $bootCompleted = (& $AdbPath -s $TargetDeviceId shell getprop sys.boot_completed 2>$null).Trim()
        if ($bootCompleted -eq "1") {
            return
        }

        Start-Sleep -Seconds 5
    }

    throw "等待模拟器开机完成超时: $TargetDeviceId"
}

function Get-AvailableAvdNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EmulatorPath
    )

    $avdOutput = & $EmulatorPath -list-avds
    if ($LASTEXITCODE -ne 0) {
        throw "列出 AVD 失败，退出码: $LASTEXITCODE"
    }

    return @($avdOutput | Where-Object { $_ -match '\S' })
}

$connectedDeviceIds = Get-ConnectedAndroidDeviceIds -AdbPath $adbExe
$resolvedDeviceId = $null

if ($DeviceId) {
    if ($connectedDeviceIds -contains $DeviceId) {
        $resolvedDeviceId = $DeviceId
        Write-Host "=== 复用已连接设备 ($resolvedDeviceId) ===" -ForegroundColor Cyan
    }
} else {
    $existingEmulatorId = @($connectedDeviceIds | Where-Object { $_ -like 'emulator-*' } | Select-Object -First 1)
    if ($existingEmulatorId.Count -gt 0) {
        $resolvedDeviceId = $existingEmulatorId[0]
        Write-Host "=== 复用已启动模拟器 ($resolvedDeviceId) ===" -ForegroundColor Cyan
    }
}

if (-not $resolvedDeviceId) {
    $availableAvds = Get-AvailableAvdNames -EmulatorPath $emulatorExe
    if ($availableAvds -notcontains $AvdName) {
        throw "未找到 AVD: $AvdName。请先执行 .\tools\setup_android_emulator.ps1 -AvdName $AvdName"
    }

    Write-Host "=== 启动 Android 模拟器 ($AvdName) ===" -ForegroundColor Cyan
    Start-Process -FilePath $emulatorExe -ArgumentList @("-avd", $AvdName, "-netdelay", "none", "-netspeed", "full") -WorkingDirectory (Split-Path $emulatorExe) | Out-Null

    $resolvedDeviceId = Wait-ForAndroidDevice -AdbPath $adbExe -PreferredDeviceId $DeviceId -TimeoutSeconds $BootTimeoutSeconds
}

Write-Host "=== 等待模拟器完成启动 ($resolvedDeviceId) ===" -ForegroundColor Cyan
Wait-ForAndroidBootCompleted -AdbPath $adbExe -TargetDeviceId $resolvedDeviceId -TimeoutSeconds $BootTimeoutSeconds

Write-Host "=== 启动 Android Debug ($resolvedDeviceId) ===" -ForegroundColor Cyan
$buildAndroidArgs = @{
    Run = $true
    DeviceId = $resolvedDeviceId
}

if (@($DartDefine).Count -gt 0) {
    $buildAndroidArgs.DartDefine = $DartDefine
}

& $buildScript @buildAndroidArgs