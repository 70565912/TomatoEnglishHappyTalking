# Sync exported listening/song mp4 and song-audio mp3 from the Windows release
# data directory into the Alice animation publish folder.
#
# Usage:
#   .\tools\sync_alice_publish_media.ps1
#   .\tools\sync_alice_publish_media.ps1 -WhatIf
#   .\tools\sync_alice_publish_media.ps1 -ReplaceOlder
#
# Default source layout (App recording-export):
#   recording-export\subtitled\* - listening - subtitled - *.mp4  -> target\listening\
#   recording-export\subtitled\* - song - subtitled - *.mp4     -> target\songs\
#   recording-export\mp3\* - song-audio - *.mp3                   -> target\mp3\
#
# Default target: X:\动画\爱丽丝梦游仙境\{listening,songs,mp3}

param(
    [string]$SourceRoot = '',
    [string]$TargetRoot = '',
    [string]$SeriesPrefix = '',
    [switch]$WhatIf,
    [switch]$ReplaceOlder,
    [string]$ReportPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultAlicePublishRoot {
    $animationFolder = -join (@(0x52A8, 0x753B) | ForEach-Object { [char]$_ })
    $bookFolder = -join (@(
            0x7231, 0x4E3D, 0x4E1D, 0x68A6, 0x6E38, 0x4ED9, 0x5883
        ) | ForEach-Object { [char]$_ })
    return Join-Path ('X:\' + $animationFolder) $bookFolder
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar

    if (-not ($resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Label is outside the expected directory: $resolvedPath"
    }
}

function Get-ExportMediaDescriptor {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)]
        [string]$MediaKind,
        [Parameter(Mandatory = $true)]
        [string]$TargetSubfolder
    )

    $name = $File.Name
    $pattern = '^(?<episode>.+?) - (?<kind>listening|song-audio|song) - (?:(?<subtitle>srt|subtitled) - )?(?<stamp>\d{8}-\d{6})(?:-\d+)?\.(?<ext>mp3|mp4)$'
    $match = [regex]::Match($name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    $kind = $match.Groups['kind'].Value.ToLowerInvariant()
    if ($kind -eq 'listening' -and $MediaKind -ne 'listening') {
        return $null
    }
    if ($kind -eq 'song' -and $MediaKind -ne 'song') {
        return $null
    }
    if ($kind -eq 'song-audio' -and $MediaKind -ne 'song-audio') {
        return $null
    }

    return [pscustomobject]@{
        File = $File
        FileName = $name
        EpisodeKey = $match.Groups['episode'].Value.Trim()
        MediaKind = $MediaKind
        ExportKind = $kind
        Stamp = $match.Groups['stamp'].Value
        TargetSubfolder = $TargetSubfolder
        TargetPath = Join-Path (Join-Path $script:SyncTargetRoot $TargetSubfolder) $name
        SourcePath = $File.FullName
        Length = $File.Length
        LastWriteTime = $File.LastWriteTimeUtc
    }
}

function Get-StampSortKey {
    param([Parameter(Mandatory = $true)][string]$Stamp)

    if ($Stamp -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$') {
        return [datetime]::ParseExact($Stamp, 'yyyyMMdd-HHmmss', $null)
    }

    return [datetime]::MinValue
}

function Get-SourceDescriptors {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$SearchFilter,
        [Parameter(Mandatory = $true)][string]$MediaKind,
        [Parameter(Mandatory = $true)][string]$TargetSubfolder,
        [Parameter(Mandatory = $true)][string]$SeriesPrefix
    )

    if (-not (Test-Path $SourceDirectory)) {
        return @()
    }

    $items = Get-ChildItem -Path $SourceDirectory -File -Filter $SearchFilter -ErrorAction Stop
    $descriptors = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if (-not $item.Name.StartsWith($SeriesPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $descriptor = Get-ExportMediaDescriptor -File $item -MediaKind $MediaKind -TargetSubfolder $TargetSubfolder
        if ($null -ne $descriptor) {
            $descriptors.Add($descriptor) | Out-Null
        }
    }

    return $descriptors
}

function Get-TargetDescriptors {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][string]$MediaKind,
        [Parameter(Mandatory = $true)][string]$TargetSubfolder,
        [Parameter(Mandatory = $true)][string]$SeriesPrefix
    )

    if (-not (Test-Path $TargetDirectory)) {
        return @()
    }

    $filter = switch ($MediaKind) {
        'song-audio' { '*.mp3' }
        default { '*.mp4' }
    }

    $items = Get-ChildItem -Path $TargetDirectory -File -Filter $filter -ErrorAction Stop
    $descriptors = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if (-not $item.Name.StartsWith($SeriesPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $descriptor = Get-ExportMediaDescriptor -File $item -MediaKind $MediaKind -TargetSubfolder $TargetSubfolder
        if ($null -ne $descriptor) {
            $descriptors.Add($descriptor) | Out-Null
        }
    }

    return $descriptors
}

function Select-NewestDescriptor {
    param([object[]]$Descriptors = @())

    if ($null -eq $Descriptors -or $Descriptors.Count -eq 0) {
        return $null
    }

    $best = $null
    $bestStamp = [datetime]::MinValue
    foreach ($descriptor in $Descriptors) {
        $stamp = Get-StampSortKey -Stamp $descriptor.Stamp
        if ($null -eq $best -or $stamp -gt $bestStamp -or (
                $stamp -eq $bestStamp -and $descriptor.LastWriteTime -gt $best.LastWriteTime)) {
            $best = $descriptor
            $bestStamp = $stamp
        }
    }

    return $best
}

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return '{0:N2} GB' -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return '{0:N2} MB' -f ($Bytes / 1MB)
    }
    if ($Bytes -ge 1KB) {
        return '{0:N2} KB' -f ($Bytes / 1KB)
    }

    return "$Bytes B"
}

$workspaceRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Join-Path $workspaceRoot 'release\windows\tomato_english_happy_talking\recording-export'
}
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $TargetRoot = Get-DefaultAlicePublishRoot
}
if ([string]::IsNullOrWhiteSpace($SeriesPrefix)) {
    $SeriesPrefix = "Alice's Adventures in Wonderland"
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $workspaceRoot '.tmp\sync_alice_publish_media_report.json'
}

$script:SyncTargetRoot = $TargetRoot

Write-Output '=== Sync Alice publish media ==='
Write-Output "Source: $SourceRoot"
Write-Output "Target: $TargetRoot"
Write-Output "Series prefix: $SeriesPrefix"
if ($WhatIf) {
    Write-Output 'Mode: preview only'
}

if (-not (Test-Path $SourceRoot)) {
    throw "Source directory not found: $SourceRoot"
}

if (-not (Test-Path $TargetRoot)) {
    throw "Target directory not found: $TargetRoot"
}

$sourceGroups = @(
    @{
        SourceDirectory = Join-Path $SourceRoot 'subtitled'
        SearchFilter = "$SeriesPrefix*listening*subtitled*.mp4"
        MediaKind = 'listening'
        TargetSubfolder = 'listening'
    },
    @{
        SourceDirectory = Join-Path $SourceRoot 'subtitled'
        SearchFilter = "$SeriesPrefix*song*subtitled*.mp4"
        MediaKind = 'song'
        TargetSubfolder = 'songs'
    },
    @{
        SourceDirectory = Join-Path $SourceRoot 'mp3'
        SearchFilter = "$SeriesPrefix*song-audio*.mp3"
        MediaKind = 'song-audio'
        TargetSubfolder = 'mp3'
    }
)

$actions = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]

foreach ($group in $sourceGroups) {
    $targetDirectory = Join-Path $TargetRoot $group.TargetSubfolder
    if (-not (Test-Path $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Write-Output "Created target folder: $targetDirectory"
    }

    $sourceDescriptors = @(Get-SourceDescriptors `
        -SourceDirectory $group.SourceDirectory `
        -SearchFilter $group.SearchFilter `
        -MediaKind $group.MediaKind `
        -TargetSubfolder $group.TargetSubfolder `
        -SeriesPrefix $SeriesPrefix)

    $targetDescriptors = @(Get-TargetDescriptors `
        -TargetDirectory $targetDirectory `
        -MediaKind $group.MediaKind `
        -TargetSubfolder $group.TargetSubfolder `
        -SeriesPrefix $SeriesPrefix)

    $sourceByEpisode = $sourceDescriptors | Group-Object -Property EpisodeKey
    foreach ($episodeGroup in $sourceByEpisode) {
        $newestSource = Select-NewestDescriptor -Descriptors @($episodeGroup.Group)
        if ($null -eq $newestSource) {
            continue
        }

        $existingExact = @($targetDescriptors | Where-Object { $_.FileName -eq $newestSource.FileName })
        if ($existingExact.Count -gt 0) {
            $skipped.Add([pscustomobject]@{
                reason = 'already_exists'
                mediaKind = $group.MediaKind
                episodeKey = $newestSource.EpisodeKey
                fileName = $newestSource.FileName
            }) | Out-Null
            continue
        }

        $episodeTargets = @($targetDescriptors | Where-Object { $_.EpisodeKey -eq $newestSource.EpisodeKey })
        $newestTarget = Select-NewestDescriptor -Descriptors $episodeTargets
        $sourceStamp = Get-StampSortKey -Stamp $newestSource.Stamp
        $targetStamp = if ($null -eq $newestTarget) {
            [datetime]::MinValue
        } else {
            Get-StampSortKey -Stamp $newestTarget.Stamp
        }

        if ($null -ne $newestTarget -and $sourceStamp -le $targetStamp) {
            $skipped.Add([pscustomobject]@{
                reason = 'target_is_newer_or_same'
                mediaKind = $group.MediaKind
                episodeKey = $newestSource.EpisodeKey
                sourceFile = $newestSource.FileName
                targetFile = $newestTarget.FileName
            }) | Out-Null
            continue
        }

        $replaceCandidates = @()
        if ($ReplaceOlder -and $episodeTargets.Count -gt 0) {
            foreach ($targetItem in $episodeTargets) {
                $itemStamp = Get-StampSortKey -Stamp $targetItem.Stamp
                if ($itemStamp -lt $sourceStamp) {
                    $replaceCandidates += $targetItem
                }
            }
        }

        $actions.Add([pscustomobject]@{
            action = if ($replaceCandidates.Count -gt 0) { 'copy_and_replace' } else { 'copy' }
            mediaKind = $group.MediaKind
            episodeKey = $newestSource.EpisodeKey
            sourcePath = $newestSource.SourcePath
            targetPath = $newestSource.TargetPath
            fileName = $newestSource.FileName
            size = $newestSource.Length
            stamp = $newestSource.Stamp
            replaceTargets = @($replaceCandidates | ForEach-Object { $_.TargetPath })
        }) | Out-Null
    }
}

if ($actions.Count -eq 0) {
    Write-Output 'No files need copying.'
} else {
    Write-Output "Pending files: $($actions.Count)"
    foreach ($action in $actions) {
        Write-Output ('[{0}] {1} -> {2} ({3})' -f $action.mediaKind, $action.fileName, $action.targetPath, (Format-FileSize $action.size))
        if ($action.replaceTargets.Count -gt 0) {
            foreach ($replaceTarget in $action.replaceTargets) {
                Write-Output "  remove older: $replaceTarget"
            }
        }

        if ($WhatIf) {
            continue
        }

        Assert-PathUnderRoot -Path $action.targetPath -RootPath $TargetRoot -Label 'target file'
        Copy-Item -Path $action.sourcePath -Destination $action.targetPath -Force
        foreach ($replaceTarget in $action.replaceTargets) {
            Assert-PathUnderRoot -Path $replaceTarget -RootPath $TargetRoot -Label 'older target file'
            Remove-Item -Path $replaceTarget -Force
        }
    }
}

Write-Output "Skipped: $($skipped.Count)"

$reportActions = @(
    foreach ($item in $actions) {
        [pscustomobject]@{
            action = $item.action
            mediaKind = $item.mediaKind
            episodeKey = $item.episodeKey
            sourcePath = $item.sourcePath
            targetPath = $item.targetPath
            fileName = $item.fileName
            size = $item.size
            stamp = $item.stamp
            replaceTargets = @($item.replaceTargets)
        }
    }
)
$reportSkipped = @(
    foreach ($item in $skipped) {
        $entry = [ordered]@{
            reason = $item.reason
            mediaKind = $item.mediaKind
            episodeKey = $item.episodeKey
        }
        if ($null -ne $item.PSObject.Properties['fileName']) {
            $entry['fileName'] = $item.fileName
        }
        if ($null -ne $item.PSObject.Properties['sourceFile']) {
            $entry['sourceFile'] = $item.sourceFile
        }
        if ($null -ne $item.PSObject.Properties['targetFile']) {
            $entry['targetFile'] = $item.targetFile
        }
        [pscustomobject]$entry
    }
)

$report = @{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    sourceRoot = $SourceRoot
    targetRoot = $TargetRoot
    seriesPrefix = $SeriesPrefix
    whatIf = [bool]$WhatIf
    replaceOlder = [bool]$ReplaceOlder
    actions = $reportActions
    skipped = $reportSkipped
}

$reportDirectory = Split-Path -Parent $ReportPath
if ($reportDirectory) {
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
}
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $ReportPath -Encoding UTF8
Write-Output "Report: $ReportPath"

if ($WhatIf) {
    Write-Output 'Preview complete. Re-run without -WhatIf to copy files.'
} else {
    Write-Output 'Sync complete.'
}
