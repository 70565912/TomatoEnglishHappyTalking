param(
  [Parameter(Mandatory = $true)]
  [int]$Width,
  [Parameter(Mandatory = $true)]
  [int]$Height,
  [string]$ProcessName = 'tomato_english_happy_talking',
  [int]$X = 0,
  [int]$Y = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$win32Source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TomatoWindowResizeNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(
    IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'TomatoWindowResizeNative').Type) {
  Add-Type $win32Source
}

$process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $process) {
  throw "Process not found: $ProcessName"
}

$targetPid = [uint32]$process.Id
$found = [IntPtr]::Zero
$maxArea = 0

$callback = [TomatoWindowResizeNative+EnumWindowsProc]{
  param([IntPtr]$hWnd, [IntPtr]$lParam)
  if (-not [TomatoWindowResizeNative]::IsWindowVisible($hWnd)) {
    return $true
  }
  $pidOut = [uint32]0
  [TomatoWindowResizeNative]::GetWindowThreadProcessId($hWnd, [ref]$pidOut) | Out-Null
  if ($pidOut -ne $targetPid) {
    return $true
  }
  $rect = New-Object TomatoWindowResizeNative+RECT
  [TomatoWindowResizeNative]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
  $area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
  if ($area -gt $script:maxArea) {
    $script:maxArea = $area
    $script:found = $hWnd
  }
  return $true
}

[TomatoWindowResizeNative]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

if ($found -eq [IntPtr]::Zero) {
  throw "Visible top-level window not found for $ProcessName"
}

$flags = [uint32]0x0004 # SWP_NOZORDER
[TomatoWindowResizeNative]::SetWindowPos($found, [IntPtr]::Zero, $X, $Y, $Width, $Height, $flags) | Out-Null
Start-Sleep -Milliseconds 350

$rect = New-Object TomatoWindowResizeNative+RECT
[TomatoWindowResizeNative]::GetWindowRect($found, [ref]$rect) | Out-Null
Write-Output (@{
  ok = $true
  width = $rect.Right - $rect.Left
  height = $rect.Bottom - $rect.Top
  x = $rect.Left
  y = $rect.Top
} | ConvertTo-Json -Compress)
