# Patch flutter_inappwebview_windows to pause/resume Graphics Capture during Lexical paste.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$methodConstOld = '  constexpr auto kMethodSetFpsLimit = "setFpsLimit";'
$methodConstNew = @'
  constexpr auto kMethodSetFpsLimit = "setFpsLimit";
  constexpr auto kMethodSetTextureCapturePaused = "setTextureCapturePaused";
'@

$handlerOld = @'
    else if (method_name.compare(kMethodSetFpsLimit) == 0) {
      if (const auto value = std::get_if<int32_t>(method_call.arguments())) {
        texture_bridge_->SetFpsLimit(*value == 0 ? std::nullopt
          : std::make_optional(*value));
        return result->Success();
      }
    }

    if (method_name.compare(kMethodSendWmPaste) == 0) {
'@

$handlerNew = @'
    else if (method_name.compare(kMethodSetFpsLimit) == 0) {
      if (const auto value = std::get_if<int32_t>(method_call.arguments())) {
        texture_bridge_->SetFpsLimit(*value == 0 ? std::nullopt
          : std::make_optional(*value));
        return result->Success();
      }
    }
    else if (method_name.compare(kMethodSetTextureCapturePaused) == 0) {
      if (const auto value = std::get_if<int32_t>(method_call.arguments())) {
        if (*value != 0) {
          texture_bridge_->Stop();
        } else {
          texture_bridge_->Start();
        }
        return result->Success();
      }
      return result->Error(kErrorInvalidArgs);
    }

    if (method_name.compare(kMethodSendWmPaste) == 0) {
'@

function Update-CustomPlatformViewCapturePatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    $content = Get-Content -LiteralPath $FilePath -Raw
    $updated = $content

    if ($updated -notlike "*kMethodSetTextureCapturePaused*") {
        $updated = $updated.Replace($methodConstOld, $methodConstNew)
    }

    if ($updated -notlike "*method_name.compare(kMethodSetTextureCapturePaused)*") {
        $updated = $updated.Replace($handlerOld, $handlerNew)
    }

    if ($updated -eq $content) {
        return $false
    }

    Set-Content -LiteralPath $FilePath -Value $updated -NoNewline
    Write-Host "Patched WebView capture pause: $FilePath"
    return $true
}

$targets = New-Object System.Collections.Generic.List[string]

$cacheRoots = @(
    (Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.flutter-io.cn"),
    (Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.dev")
)

foreach ($root in $cacheRoots) {
    if (-not (Test-Path $root)) {
        continue
    }
    Get-ChildItem -Path $root -Filter "custom_platform_view.cc" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*flutter_inappwebview_windows-*\windows\custom_platform_view\custom_platform_view.cc" } |
        ForEach-Object { $targets.Add($_.FullName) }
}

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$symlinkPath = Join-Path $workspaceRoot "app\windows\flutter\ephemeral\.plugin_symlinks\flutter_inappwebview_windows\windows\custom_platform_view\custom_platform_view.cc"
if (Test-Path -LiteralPath $symlinkPath) {
    $targets.Add($symlinkPath)
}

$patched = 0
foreach ($file in ($targets | Select-Object -Unique)) {
    if (Update-CustomPlatformViewCapturePatch -FilePath $file) {
        $patched += 1
    }
}

if ($patched -eq 0) {
    Write-Host "WebView capture pause patch skipped (already applied or package not found)."
} else {
    Write-Host "WebView capture pause patch applied to $patched file(s)."
}
