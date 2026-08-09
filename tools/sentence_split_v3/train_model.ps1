param(
  [string]$OutputPath = 'app\assets\models\english-ewt-r2.18-udpipe-v1.4.0.model'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$trainer = Join-Path $repoRoot 'build\udpipe-v3-trainer\udpipe_v3_train.exe'
$trainingRoot = Join-Path $PSScriptRoot 'training\ud_english_ewt_r2_18'
$trainData = Join-Path $trainingRoot 'en_ewt-ud-train.conllu'
$heldoutData = Join-Path $trainingRoot 'en_ewt-ud-dev.conllu'
$resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath
} else {
  Join-Path $repoRoot $OutputPath
}

foreach ($requiredPath in @($trainer, $trainData, $heldoutData)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required V3 training input is missing: $requiredPath"
  }
}

$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$temporaryOutput = "$resolvedOutput.training"
if (Test-Path -LiteralPath $temporaryOutput) {
  Remove-Item -LiteralPath $temporaryOutput -Force
}

# These are generic model-capacity bounds, not corpus word/phrase exceptions.
# The first unrestricted run reached its best tokenizer heldout sum at epoch
# 52. Tagger 12 and parser 8 keep the reproducible desktop build bounded while
# retaining heldout-driven early stopping.
try {
  & $trainer `
    --train `
    "--heldout=$heldoutData" `
    '--tokenizer=epochs=52;early_stopping=1' `
    '--tagger=iterations=12;early_stopping=1' `
    '--parser=iterations=8;early_stopping=1' `
    $temporaryOutput `
    $trainData

  if ($LASTEXITCODE -ne 0) {
    throw "UDPipe V3 model training failed with exit code $LASTEXITCODE"
  }
  Move-Item -LiteralPath $temporaryOutput -Destination $resolvedOutput -Force
} finally {
  if (Test-Path -LiteralPath $temporaryOutput) {
    Remove-Item -LiteralPath $temporaryOutput -Force
  }
}
