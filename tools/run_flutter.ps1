param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$flutterRoot = "D:\DevTools\flutter"
$flutterExe = Join-Path $flutterRoot "bin\flutter.bat"
if (-not (Test-Path $flutterExe)) {
    throw "Flutter not found: $flutterExe"
}

. (Join-Path $PSScriptRoot "flutter_tool_guard.ps1")
Assert-FlutterToolReady -FlutterRoot $flutterRoot

if (-not $env:PUB_HOSTED_URL) {
    $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
}
if (-not $env:FLUTTER_STORAGE_BASE_URL) {
    $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
}
$env:FLUTTER_SUPPRESS_ANALYTICS = "true"

& $flutterExe @FlutterArguments
exit $LASTEXITCODE
