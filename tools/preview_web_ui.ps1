# Tomato English Happy Talking - Web UI 静态预览脚本
# 用法: .\tools\preview_web_ui.ps1 [-Port 4173] [-SkipBuild] [-NoOpen]
param(
    [int]$Port = 4173,
    [switch]$SkipBuild,
    [switch]$NoOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$webUiRoot = Join-Path $workspaceRoot "web_ui"
$webRoot = Join-Path $workspaceRoot "app\assets\web"

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$CommandName 失败，退出码: $LASTEXITCODE"
    }
}

function Get-NpmExe {
    $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($null -eq $npmCommand) {
        $npmCommand = Get-Command npm -ErrorAction Stop
    }

    return $npmCommand.Source
}

function Invoke-WebUiBuild {
    if (-not (Test-Path (Join-Path $webUiRoot "package.json"))) {
        throw "Web UI 项目不存在: $webUiRoot"
    }

    $npmExe = Get-NpmExe
    Push-Location $webUiRoot
    try {
        Write-Host "=== 构建 Web UI ===" -ForegroundColor Cyan

        if (-not (Test-Path (Join-Path $webUiRoot "node_modules"))) {
            if (Test-Path (Join-Path $webUiRoot "package-lock.json")) {
                & $npmExe ci
                Assert-LastExitCode -CommandName "npm ci"
            } else {
                & $npmExe install
                Assert-LastExitCode -CommandName "npm install"
            }
        }

        & $npmExe run build
        Assert-LastExitCode -CommandName "npm run build"
    } finally {
        Pop-Location
    }
}

function Get-ContentType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { return "text/html; charset=utf-8" }
        ".css" { return "text/css; charset=utf-8" }
        ".js" { return "text/javascript; charset=utf-8" }
        ".json" { return "application/json; charset=utf-8" }
        ".svg" { return "image/svg+xml" }
        ".png" { return "image/png" }
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".webp" { return "image/webp" }
        ".ico" { return "image/x-icon" }
        ".woff" { return "font/woff" }
        ".woff2" { return "font/woff2" }
        default { return "application/octet-stream" }
    }
}

function Resolve-WebFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestTarget
    )

    $urlPath = $RequestTarget.Split("?")[0]
    $relativePath = [Uri]::UnescapeDataString($urlPath.TrimStart("/"))
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        $relativePath = "index.html"
    }

    $relativePath = $relativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    if ($relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        return $null
    }

    $candidatePath = Join-Path $webRoot $relativePath
    $rootPath = [System.IO.Path]::GetFullPath($webRoot)
    $fullCandidatePath = [System.IO.Path]::GetFullPath($candidatePath)
    if (-not $fullCandidatePath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (Test-Path $fullCandidatePath -PathType Container) {
        $fullCandidatePath = Join-Path $fullCandidatePath "index.html"
    }

    if (Test-Path $fullCandidatePath -PathType Leaf) {
        return $fullCandidatePath
    }

    if ([System.IO.Path]::GetExtension($relativePath) -eq "") {
        return Join-Path $webRoot "index.html"
    }

    return $null
}

function Send-HttpResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory = $true)]
        [int]$StatusCode,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        [Parameter(Mandatory = $true)]
        [string]$ContentType,
        [Parameter(Mandatory = $true)]
        [byte[]]$Body,
        [Parameter(Mandatory = $true)]
        [bool]$WriteBody
    )

    $headers = @(
        "HTTP/1.1 $StatusCode $Reason",
        "Content-Type: $ContentType",
        "Content-Length: $($Body.Length)",
        "Cache-Control: no-store",
        "Connection: close",
        "",
        ""
    ) -join "`r`n"

    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headers)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($WriteBody -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
}

if (-not $SkipBuild) {
    Invoke-WebUiBuild
}

if (-not (Test-Path (Join-Path $webRoot "index.html"))) {
    throw "预览入口不存在，请先构建 Web UI: $(Join-Path $webRoot "index.html")"
}

$listener = $null
for ($candidatePort = $Port; $candidatePort -le ($Port + 20); $candidatePort++) {
    try {
        $listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Parse("127.0.0.1"),
            $candidatePort
        )
        $listener.Start()
        $Port = $candidatePort
        break
    } catch {
        if ($null -ne $listener) {
            $listener.Stop()
            $listener = $null
        }
    }
}

if ($null -eq $listener) {
    throw "端口 $Port 到 $($Port + 20) 都无法启动预览服务"
}

$previewUrl = "http://127.0.0.1:$Port/index.html"

try {
    Write-Host "`n=== Web UI 静态预览 ===" -ForegroundColor Cyan
    Write-Host "目录: $webRoot"
    Write-Host "地址: $previewUrl"
    Write-Host "按 Ctrl+C 停止预览服务。"

    if (-not $NoOpen) {
        Start-Process $previewUrl
    }

    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new(
                $stream,
                [System.Text.Encoding]::ASCII,
                $false,
                8192,
                $true
            )

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) {
                continue
            }

            while ($true) {
                $headerLine = $reader.ReadLine()
                if ($null -eq $headerLine -or $headerLine -eq "") {
                    break
                }
            }

            $requestParts = $requestLine.Split(" ")
            if ($requestParts.Count -lt 2) {
                $body = [System.Text.Encoding]::UTF8.GetBytes("Bad Request")
                Send-HttpResponse -Stream $stream -StatusCode 400 -Reason "Bad Request" -ContentType "text/plain; charset=utf-8" -Body $body -WriteBody $true
                continue
            }

            $method = $requestParts[0].ToUpperInvariant()
            if ($method -ne "GET" -and $method -ne "HEAD") {
                $body = [System.Text.Encoding]::UTF8.GetBytes("Method Not Allowed")
                Send-HttpResponse -Stream $stream -StatusCode 405 -Reason "Method Not Allowed" -ContentType "text/plain; charset=utf-8" -Body $body -WriteBody ($method -ne "HEAD")
                continue
            }

            $filePath = Resolve-WebFile -RequestTarget $requestParts[1]
            if ($null -eq $filePath) {
                $body = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
                Send-HttpResponse -Stream $stream -StatusCode 404 -Reason "Not Found" -ContentType "text/plain; charset=utf-8" -Body $body -WriteBody ($method -ne "HEAD")
                continue
            }

            $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
            Send-HttpResponse -Stream $stream -StatusCode 200 -Reason "OK" -ContentType (Get-ContentType -Path $filePath) -Body $fileBytes -WriteBody ($method -ne "HEAD")
        } catch {
            Write-Host "请求处理失败: $($_.Exception.Message)" -ForegroundColor Yellow
        } finally {
            $client.Close()
        }
    }
} finally {
    if ($null -ne $listener) {
        $listener.Stop()
    }
}
