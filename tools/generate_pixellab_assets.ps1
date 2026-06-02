# Tomato English Happy Talking - PixelLab 图片生成脚本
# 用法:
#   $env:PIXELLAB_API_TOKEN = "..."
#   .\tools\generate_pixellab_assets.ps1
#   .\tools\generate_pixellab_assets.ps1 -AssetName tomato-wave -Force
param(
    [string]$ManifestPath,
    [string]$AssetName,
    [switch]$Force,
    [switch]$SkipSyncToAppAssets,
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot "pixellab_assets.json"
}

$nodeScript = Join-Path $PSScriptRoot "generate_pixellab_assets.mjs"
if (Test-Path $nodeScript) {
    $nodeArgs = @($nodeScript)
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
        $nodeArgs += @("--manifest", $ManifestPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($AssetName)) {
        $nodeArgs += @("--asset-name", $AssetName)
    }
    if ($Force) {
        $nodeArgs += "--force"
    }
    if ($SkipSyncToAppAssets) {
        $nodeArgs += "--skip-sync-to-app-assets"
    }
    $nodeArgs += @("--timeout-seconds", $TimeoutSeconds.ToString())

    & node @nodeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Node PixelLab 生成脚本失败，退出码: $LASTEXITCODE"
    }
    exit 0
}

function Get-PixelLabApiToken {
    if (-not [string]::IsNullOrWhiteSpace($env:PIXELLAB_API_TOKEN)) {
        return $env:PIXELLAB_API_TOKEN.Trim()
    }

    $tokenFile = Join-Path $workspaceRoot "security\pixellab-api-token.txt"
    if (Test-Path $tokenFile) {
        $token = (Get-Content -Path $tokenFile -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return $token
        }
    }

    throw "未找到 PixelLab API token。请设置环境变量 PIXELLAB_API_TOKEN，或在 security\pixellab-api-token.txt 放入 token（security 目录已被 .gitignore 忽略）。"
}

function Get-ImageBase64 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    if ($null -eq $Response.image -or [string]::IsNullOrWhiteSpace($Response.image.base64)) {
        throw "PixelLab 响应中没有 image.base64 字段。"
    }

    $base64 = [string]$Response.image.base64
    $commaIndex = $base64.IndexOf(",")
    if ($base64.StartsWith("data:", [System.StringComparison]::OrdinalIgnoreCase) -and $commaIndex -ge 0) {
        return $base64.Substring($commaIndex + 1)
    }

    return $base64
}

function Save-Base64Image {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base64,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [System.IO.File]::WriteAllBytes($Path, [System.Convert]::FromBase64String($Base64))
}

function Invoke-PixelLabAssetGeneration {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Asset,
        [Parameter(Mandatory = $true)]
        [object]$Manifest,
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $description = "$($Manifest.style) $($Asset.description)"
    $body = @{
        description = $description
        image_size = @{
            width = [int]$Asset.width
            height = [int]$Asset.height
        }
        no_background = [bool]$Asset.noBackground
    }

    if ($Asset.PSObject.Properties.Name -contains "outline" -and -not [string]::IsNullOrWhiteSpace($Asset.outline)) {
        $body.outline = [string]$Asset.outline
    }

    $uri = "$($Manifest.baseUrl)$($Manifest.endpoint)"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/json"
    }

    $json = $body | ConvertTo-Json -Depth 8
    return Invoke-RestMethod `
        -Uri $uri `
        -Method Post `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $json `
        -TimeoutSec $TimeoutSeconds
}

if (-not (Test-Path $ManifestPath)) {
    throw "PixelLab 资产清单不存在: $ManifestPath"
}

$manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
$token = Get-PixelLabApiToken
$webUiAssetsRoot = Join-Path $workspaceRoot "web_ui\public\assets\ui"
$appAssetsRoot = Join-Path $workspaceRoot "app\assets\web\assets\ui"

$assets = @($manifest.assets)
if (-not [string]::IsNullOrWhiteSpace($AssetName)) {
    $assets = @($assets | Where-Object { $_.name -eq $AssetName -or $_.output -eq $AssetName })
    if ($assets.Count -eq 0) {
        throw "资产清单中找不到: $AssetName"
    }
}

foreach ($asset in $assets) {
    $targetPath = Join-Path $webUiAssetsRoot $asset.output
    if ((Test-Path $targetPath) -and -not $Force) {
        Write-Host "跳过已存在图片: $($asset.output)"
        continue
    }

    Write-Host "=== 生成 $($asset.name) ==="
    $response = Invoke-PixelLabAssetGeneration -Asset $asset -Manifest $manifest -Token $token
    $base64 = Get-ImageBase64 -Response $response
    Save-Base64Image -Base64 $base64 -Path $targetPath
    Write-Host "已保存: $targetPath"

    if (-not $SkipSyncToAppAssets) {
        $appAssetPath = Join-Path $appAssetsRoot $asset.output
        Copy-Item -Path $targetPath -Destination $appAssetPath -Force
        Write-Host "已同步: $appAssetPath"
    }
}
