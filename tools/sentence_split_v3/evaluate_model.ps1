param(
  [Parameter(Mandatory = $true)]
  [string]$ModelPath,
  [string]$TestPath = 'tools\sentence_split_v3\training\ud_english_ewt_r2_18\en_ewt-ud-test.conllu'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $repoRoot 'build\udpipe-v3-trainer\udpipe_v3_train.exe'
$resolvedModel = if ([System.IO.Path]::IsPathRooted($ModelPath)) {
  $ModelPath
} else {
  Join-Path $repoRoot $ModelPath
}
$resolvedTest = if ([System.IO.Path]::IsPathRooted($TestPath)) {
  $TestPath
} else {
  Join-Path $repoRoot $TestPath
}

foreach ($requiredPath in @($runner, $resolvedModel, $resolvedTest)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required V3 evaluation input is missing: $requiredPath"
  }
}

& $runner --accuracy --tokenize --tag --parse $resolvedModel $resolvedTest
if ($LASTEXITCODE -ne 0) {
  throw "UDPipe V3 model evaluation failed with exit code $LASTEXITCODE"
}
