# Patch flutter_inappwebview_windows focus toggle on pointer down (Windows WebView2).
# Removes the delayed second FocusNode.requestFocus() that steals HTML input focus.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$cacheRoots = @(
    (Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.flutter-io.cn"),
    (Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.dev")
)

$oldBlock = @'
                      if (!_focusNode.hasFocus) {
                        _focusNode.requestFocus();
                        Future.delayed(const Duration(milliseconds: 50), () {
                          if (!_focusNode.hasFocus) {
                            _focusNode.requestFocus();
                          }
                        });
                      }
'@

$newBlock = @'
                      if (!_focusNode.hasFocus) {
                        _focusNode.requestFocus();
                      }
'@

$patched = 0
foreach ($root in $cacheRoots) {
    if (-not (Test-Path $root)) {
        continue
    }
    $files = Get-ChildItem -Path $root -Filter "custom_platform_view.dart" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*flutter_inappwebview_windows-*\lib\src\in_app_webview\custom_platform_view.dart" }
    foreach ($file in $files) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        if ($content -like "*Future.delayed(const Duration(milliseconds: 50)*") {
            $updated = $content.Replace($oldBlock, $newBlock)
            if ($updated -ne $content) {
                Set-Content -LiteralPath $file.FullName -Value $updated -NoNewline
                Write-Host "Patched WebView focus: $($file.FullName)"
                $patched += 1
            }
        }
    }
}

if ($patched -eq 0) {
    Write-Host "WebView focus patch skipped (already applied or package not found)."
} else {
    Write-Host "WebView focus patch applied to $patched file(s)."
}
