param(
  [int]$Port = 39355,
  [int]$ArticleId = 2,
  [string]$OutPath = "H:\TomatoEnglishHappyTalking\.tmp\qa-picture-book-scene-only.json",
  [ValidateSet("scene-only", "chapter-scene", "book-chapter-scene")]
  [string]$PromptMode = "chapter-scene",
  [string]$ExePath = "H:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking\tomato_english_happy_talking.exe",
  [string]$DataRoot = "",
  [switch]$NoStart,
  [int]$PromptReviewTimeoutSec = 240,
  [int]$ConfirmTimeoutSec = 1800
)

$ErrorActionPreference = "Stop"
$exe = $ExePath
$previousDataRoot = $env:TOMATO_DESKTOP_DATA_ROOT
$outDir = Split-Path -Parent $OutPath
if ($outDir) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

function Write-State {
  param([hashtable]$State)
  $State["updatedAt"] = (Get-Date).ToUniversalTime().ToString("o")
  $State | ConvertTo-Json -Depth 30 | Set-Content -Path $OutPath -Encoding UTF8
}

function Invoke-QaBridge {
  param(
    [string]$Type,
    [hashtable]$Payload,
    [int]$TimeoutSec = 60
  )
  $body = @{
    type = $Type
    payload = $Payload
  } | ConvertTo-Json -Depth 40
  return Invoke-RestMethod `
    -Uri "http://127.0.0.1:$Port/bridge" `
    -Method Post `
    -ContentType "application/json" `
    -Body $body `
    -TimeoutSec $TimeoutSec
}

function Build-BisectGroupPrompt {
  param(
    [object[]]$Scenes,
    [string]$BookDescription,
    [string]$ChapterDescription,
    [string]$Mode
  )
  $lines = New-Object System.Collections.Generic.List[string]
  if ($Mode -eq "chapter-scene" -or $Mode -eq "book-chapter-scene") {
    if ($Mode -eq "book-chapter-scene") {
      $lines.Add("Book description: $BookDescription")
    }
    $lines.Add("Chapter description: $ChapterDescription")
  }
  $index = 1
  foreach ($scene in $Scenes) {
    $sceneDescription = [string]$scene.sceneDescription
    $lines.Add("")
    $lines.Add("Image ${index}:")
    if ($sceneDescription.Trim().Length -gt 0) {
      $lines.Add("Scene description: $sceneDescription")
    }
    $index += 1
  }
  return ($lines -join "`n").Trim()
}

if (-not $NoStart) {
  $env:TOMATO_QA_REMOTE = "true"
  $env:TOMATO_QA_PORT = "$Port"
}
if ($DataRoot.Trim().Length -gt 0) {
  $env:TOMATO_DESKTOP_DATA_ROOT = $DataRoot
}
$process = $null

try {
  Write-State @{ status = "starting"; articleId = $ArticleId; port = $Port; promptMode = $PromptMode; noStart = [bool]$NoStart; exePath = $exe; dataRoot = $DataRoot }
  if (-not $NoStart) {
    $process = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
  }

  $health = $null
  for ($i = 0; $i -lt 90; $i += 1) {
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
      if ($health.ok -and ($NoStart -or $health.webReady)) { break }
    } catch {
      Start-Sleep -Seconds 1
    }
  }
  if (-not $health -or -not $health.ok -or (-not $NoStart -and -not $health.webReady)) {
    throw "QA health check failed on port $Port"
  }

  Write-State @{
    status = "reviewing"
    articleId = $ArticleId
    pid = if ($process) { $process.Id } else { $null }
    port = $Port
    promptMode = $PromptMode
    noStart = [bool]$NoStart
    exePath = $exe
    dataRoot = $DataRoot
  }
  $reviewResponse = Invoke-QaBridge `
    -Type "pictureBook.promptReview" `
    -Payload @{ articleId = $ArticleId; regenerate = $true } `
    -TimeoutSec $PromptReviewTimeoutSec
  if (-not $reviewResponse.ok) {
    throw "pictureBook.promptReview failed: $($reviewResponse.error.message)"
  }

  $review = $reviewResponse.payload
  $scenes = @($review.scenes)
  $bisectPrompt = Build-BisectGroupPrompt `
    -Scenes $scenes `
    -BookDescription ([string]$review.bookDescription) `
    -ChapterDescription ([string]$review.chapterDescription) `
    -Mode $PromptMode
  $lowerPrompt = $bisectPrompt.ToLowerInvariant()
  Write-State @{
    status = "bisectPromptReady"
    articleId = $ArticleId
    pid = if ($process) { $process.Id } else { $null }
    port = $Port
    promptMode = $PromptMode
    noStart = [bool]$NoStart
    reviewId = $review.reviewId
    sceneCount = $scenes.Count
    originalPromptLength = ([string]$review.groupPrompt).Length
    bisectPromptLength = $bisectPrompt.Length
    containsBookDescription = $lowerPrompt.Contains("book description:")
    containsChapterDescription = $lowerPrompt.Contains("chapter description:")
    containsSceneDescription = $lowerPrompt.Contains("scene description:")
    containsKilling = $lowerPrompt.Contains("killing somebody underneath")
    containsFellOffHouse = $lowerPrompt.Contains("fell off the top of the house")
    bisectPrompt = $bisectPrompt
    scenes = $scenes
  }

  Write-State @{
    status = "confirming"
    articleId = $ArticleId
    pid = if ($process) { $process.Id } else { $null }
    port = $Port
    promptMode = $PromptMode
    noStart = [bool]$NoStart
    reviewId = $review.reviewId
    sceneCount = $scenes.Count
    bisectPromptLength = $bisectPrompt.Length
  }

  $confirmResponse = Invoke-QaBridge `
    -Type "pictureBook.confirmPromptReview" `
    -Payload @{
      reviewId = $review.reviewId
      groupPrompt = $bisectPrompt
      bookDescription = $review.bookDescription
      chapterDescription = $review.chapterDescription
      scenes = $review.scenes
    } `
    -TimeoutSec $ConfirmTimeoutSec
  if (-not $confirmResponse.ok) {
    throw "pictureBook.confirmPromptReview failed: $($confirmResponse.error.message)"
  }

  $state = $confirmResponse.payload
  $pages = @($state.pages)
  $statusCounts = @{}
  foreach ($page in $pages) {
    $status = [string]$page.status
    if (-not $statusCounts.ContainsKey($status)) {
      $statusCounts[$status] = 0
    }
    $statusCounts[$status] += 1
  }
  Write-State @{
    status = "done"
    articleId = $ArticleId
    pid = if ($process) { $process.Id } else { $null }
    port = $Port
    promptMode = $PromptMode
    noStart = [bool]$NoStart
    reviewId = $review.reviewId
    sceneCount = $scenes.Count
    bisectPromptLength = $bisectPrompt.Length
    finalStatus = $state.status
    pageCount = $pages.Count
    statusCounts = $statusCounts
    firstError = ($pages | Where-Object { $_.errorMessage } | Select-Object -First 1).errorMessage
    bisectPrompt = $bisectPrompt
  }
} catch {
  Write-State @{
    status = "error"
    articleId = $ArticleId
    port = $Port
    promptMode = $PromptMode
    noStart = [bool]$NoStart
    pid = if ($process) { $process.Id } else { $null }
    message = $_.Exception.Message
  }
  throw
} finally {
  if ($process -and -not $process.HasExited) {
    Stop-Process -Id $process.Id -Force
  }
  if ($null -eq $previousDataRoot) {
    Remove-Item Env:\TOMATO_DESKTOP_DATA_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:TOMATO_DESKTOP_DATA_ROOT = $previousDataRoot
  }
}
