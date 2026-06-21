param(
  [string]$ExePath = (Join-Path (Split-Path -Parent $PSScriptRoot) "release\windows\tomato_english_happy_talking\tomato_english_happy_talking.exe"),
  [int]$StartupWaitSeconds = 5,
  [int]$AfterMinimizeWaitSeconds = 2,
  [ValidateSet("Api", "ClickTitleBar")]
  [string]$MinimizeMode = "ClickTitleBar"
)

$ErrorActionPreference = "Stop"

$win32Source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowProbeNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
}
'@

Add-Type $win32Source

function Get-WindowDescription {
  param(
    [IntPtr]$Handle,
    [string]$Kind,
    [string]$Point,
    [int]$AppProcessId
  )

  $pidOut = [uint32]0
  [WindowProbeNative]::GetWindowThreadProcessId($Handle, [ref]$pidOut) | Out-Null
  $processName = $null
  $processPath = $null
  $parentProcessId = $null
  $commandLine = $null
  try {
    $process = Get-Process -Id $pidOut -ErrorAction Stop
    $processName = $process.ProcessName
    $processPath = $process.Path
  } catch {
  }
  try {
    $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$pidOut" -ErrorAction Stop
    $parentProcessId = $cimProcess.ParentProcessId
    $commandLine = $cimProcess.CommandLine
  } catch {
  }

  $rect = New-Object WindowProbeNative+RECT
  [WindowProbeNative]::GetWindowRect($Handle, [ref]$rect) | Out-Null

  $className = New-Object System.Text.StringBuilder 256
  [WindowProbeNative]::GetClassName($Handle, $className, $className.Capacity) | Out-Null

  $title = New-Object System.Text.StringBuilder 256
  [WindowProbeNative]::GetWindowText($Handle, $title, $title.Capacity) | Out-Null

  $root = [WindowProbeNative]::GetAncestor($Handle, 2)
  $rootOwner = [WindowProbeNative]::GetAncestor($Handle, 3)
  $rootPid = [uint32]0
  if ($root -ne [IntPtr]::Zero) {
    [WindowProbeNative]::GetWindowThreadProcessId($root, [ref]$rootPid) | Out-Null
  }
  $rootOwnerPid = [uint32]0
  if ($rootOwner -ne [IntPtr]::Zero) {
    [WindowProbeNative]::GetWindowThreadProcessId($rootOwner, [ref]$rootOwnerPid) | Out-Null
  }

  $exStyle = [WindowProbeNative]::GetWindowLong($Handle, -20)
  $style = [WindowProbeNative]::GetWindowLong($Handle, -16)

  [pscustomobject]@{
    kind = $Kind
    point = $Point
    handle = $Handle.ToInt64()
    pid = $pidOut
    processName = $processName
    parentProcessId = $parentProcessId
    processPath = $processPath
    commandLine = $commandLine
    isApp = ($pidOut -eq [uint32]$AppProcessId)
    parent = [WindowProbeNative]::GetParent($Handle).ToInt64()
    root = $root.ToInt64()
    rootPid = $rootPid
    rootIsApp = ($rootPid -eq [uint32]$AppProcessId)
    rootOwner = $rootOwner.ToInt64()
    rootOwnerPid = $rootOwnerPid
    rootOwnerIsApp = ($rootOwnerPid -eq [uint32]$AppProcessId)
    className = $className.ToString()
    title = $title.ToString()
    visible = [WindowProbeNative]::IsWindowVisible($Handle)
    iconic = [WindowProbeNative]::IsIconic($Handle)
    left = $rect.Left
    top = $rect.Top
    right = $rect.Right
    bottom = $rect.Bottom
    width = ($rect.Right - $rect.Left)
    height = ($rect.Bottom - $rect.Top)
    style = ("0x{0:X8}" -f $style)
    exStyle = ("0x{0:X8}" -f $exStyle)
    transparent = (($exStyle -band 0x20) -ne 0)
    layered = (($exStyle -band 0x80000) -ne 0)
  }
}

function Get-HitSamples {
  param(
    [string]$Phase,
    [int]$AppProcessId
  )

  $screenWidth = [WindowProbeNative]::GetSystemMetrics(0)
  $screenHeight = [WindowProbeNative]::GetSystemMetrics(1)
  $points = @(
    @{ name = "desktop-top-left"; x = 20; y = 20 },
    @{ name = "inside-app-normal"; x = 120; y = 120 },
    @{ name = "screen-center"; x = [int]($screenWidth / 2); y = [int]($screenHeight / 2) },
    @{ name = "taskbar-left"; x = 10; y = $screenHeight - 20 },
    @{ name = "taskbar-center"; x = [int]($screenWidth / 2); y = $screenHeight - 20 },
    @{ name = "show-desktop-corner"; x = $screenWidth - 2; y = $screenHeight - 2 }
  )

  foreach ($sample in $points) {
    $point = New-Object WindowProbeNative+POINT
    $point.X = $sample.x
    $point.Y = $sample.y
    $handle = [WindowProbeNative]::WindowFromPoint($point)
    Get-WindowDescription -Handle $handle -Kind ("hit:" + $Phase + ":" + $sample.name) -Point ($sample.x.ToString() + "," + $sample.y.ToString()) -AppProcessId $AppProcessId
  }
}

function Invoke-LeftClick {
  param([int]$X, [int]$Y)

  [WindowProbeNative]::SetCursorPos($X, $Y) | Out-Null
  Start-Sleep -Milliseconds 100
  [WindowProbeNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [WindowProbeNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function New-ScreenPointLParam {
  param([int]$X, [int]$Y)
  $value = (($Y -band 0xffff) -shl 16) -bor ($X -band 0xffff)
  [IntPtr]$value
}

function Find-MinimizeButtonPoint {
  param([IntPtr]$Handle)

  $rect = New-Object WindowProbeNative+RECT
  [WindowProbeNative]::GetWindowRect($Handle, [ref]$rect) | Out-Null
  for ($y = $rect.Top + 6; $y -le $rect.Top + 45; $y += 3) {
    for ($x = $rect.Right - 220; $x -le $rect.Right - 8; $x += 3) {
      $hit = [WindowProbeNative]::SendMessage($Handle, 0x0084, [IntPtr]::Zero, (New-ScreenPointLParam -X $x -Y $y)).ToInt64()
      if ($hit -eq 8) {
        return [pscustomobject]@{ x = $x; y = $y; hitTest = $hit; source = "WM_NCHITTEST" }
      }
    }
  }

  [pscustomobject]@{
    x = $rect.Right - 118
    y = $rect.Top + 18
    hitTest = [WindowProbeNative]::SendMessage($Handle, 0x0084, [IntPtr]::Zero, (New-ScreenPointLParam -X ($rect.Right - 118) -Y ($rect.Top + 18))).ToInt64()
    source = "fallback"
  }
}

function Get-AppWindows {
  param(
    [string]$Phase,
    [int]$AppProcessId
  )

  $rows = New-Object System.Collections.Generic.List[object]

  function Add-ProbeWindow {
    param([IntPtr]$Handle, [string]$Kind)

    $pidOut = [uint32]0
    [WindowProbeNative]::GetWindowThreadProcessId($Handle, [ref]$pidOut) | Out-Null
    if ($pidOut -ne [uint32]$AppProcessId) {
      return
    }
    $rows.Add((Get-WindowDescription -Handle $Handle -Kind ($Kind + ":" + $Phase) -Point "" -AppProcessId $AppProcessId)) | Out-Null
  }

  $enumTop = [WindowProbeNative+EnumWindowsProc]{
    param($handle, $lParam)
    Add-ProbeWindow -Handle $handle -Kind "top"
    return $true
  }
  [WindowProbeNative]::EnumWindows($enumTop, [IntPtr]::Zero) | Out-Null

  $enumChild = [WindowProbeNative+EnumWindowsProc]{
    param($handle, $lParam)
    Add-ProbeWindow -Handle $handle -Kind "child"
    return $true
  }
  foreach ($row in @($rows | Where-Object { $_.kind -like "top:*" })) {
    [WindowProbeNative]::EnumChildWindows([IntPtr]$row.handle, $enumChild, [IntPtr]::Zero) | Out-Null
  }

  $rows
}

function Find-AppMainWindow {
  param([int]$AppProcessId)

  $candidates = @(Get-AppWindows -Phase "main-window-search" -AppProcessId $AppProcessId |
      Where-Object {
        $_.className -eq "FLUTTER_RUNNER_WIN32_WINDOW" -and
        $_.visible -eq $true -and
        $_.iconic -eq $false -and
        $_.width -gt 0 -and
        $_.height -gt 0
      } |
      Sort-Object @{ Expression = { $_.width * $_.height }; Descending = $true })
  if ($candidates.Count -gt 0) {
    return [IntPtr]$candidates[0].handle
  }
  return [IntPtr]::Zero
}

$resolvedExe = Resolve-Path -LiteralPath $ExePath
$workingDirectory = Split-Path -Parent $resolvedExe
$process = Start-Process -FilePath $resolvedExe -WorkingDirectory $workingDirectory -PassThru

try {
  $deadline = (Get-Date).AddSeconds($StartupWaitSeconds + 10)
  do {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
  } while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)

  if ($process.MainWindowHandle -eq 0) {
    throw "main window handle was not created for process $($process.Id)"
  }

  Start-Sleep -Seconds $StartupWaitSeconds
  $process.Refresh()
  $mainHandle = Find-AppMainWindow -AppProcessId $process.Id
  if ($mainHandle -eq [IntPtr]::Zero) {
    $mainHandle = [IntPtr]$process.MainWindowHandle
  }

  [WindowProbeNative]::ShowWindow($mainHandle, 9) | Out-Null
  [WindowProbeNative]::SetWindowPos($mainHandle, [IntPtr]::Zero, 10, 10, 1280, 720, 0x0040) | Out-Null
  [WindowProbeNative]::SetForegroundWindow($mainHandle) | Out-Null
  Start-Sleep -Seconds 1

  $beforeHits = @(Get-HitSamples -Phase "before-minimize" -AppProcessId $process.Id)
  $beforeWindows = @(Get-AppWindows -Phase "before-minimize" -AppProcessId $process.Id)

  $minimizeClick = $null
  if ($MinimizeMode -eq "Api") {
    [WindowProbeNative]::ShowWindow($mainHandle, 6) | Out-Null
  } else {
    $minimizeClick = Find-MinimizeButtonPoint -Handle $mainHandle
    Invoke-LeftClick -X $minimizeClick.x -Y $minimizeClick.y
  }
  Start-Sleep -Seconds $AfterMinimizeWaitSeconds
  $process.Refresh()

  $afterHits = @(Get-HitSamples -Phase "after-minimize" -AppProcessId $process.Id)
  $afterWindows = @(Get-AppWindows -Phase "after-minimize" -AppProcessId $process.Id)

  [pscustomobject]@{
    exePath = $resolvedExe.Path
    processId = $process.Id
    mainWindowHandle = $mainHandle.ToInt64()
    minimizeMode = $MinimizeMode
    minimizeClick = $minimizeClick
    hitsBefore = $beforeHits
    appWindowsBefore = $beforeWindows
    hitsAfter = $afterHits
    appWindowsAfter = $afterWindows
  } | ConvertTo-Json -Depth 8
}
finally {
  Get-Process -Id $process.Id -ErrorAction SilentlyContinue | Stop-Process -Force
}
