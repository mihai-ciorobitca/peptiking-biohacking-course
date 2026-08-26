[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$CourseRoot,

    [string]$LegacyRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BiohackingCourse'),

    [ValidateSet('Move', 'Copy', 'None')]
    [string]$MigrationMode = 'Move',

    [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe',

    [string]$ChromeProfilePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ChromeProfile'),

    [string]$FfmpegPath,

    [string]$FfprobePath,

    [ValidateRange(1025, 65535)]
    [int]$DebugPort = 9223,

    [ValidateRange(2, 30)]
    [int]$SeekWaitSeconds = 6,

    [switch]$MigrationOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $resolvedPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Write-DownloadStatus {
    param(
        [Parameter(Mandatory)] [Collections.IEnumerable]$Rows,
        [Parameter(Mandatory)] [string]$Root
    )

    $csvPath = Join-Path $Root 'download-status.csv'
    $jsonPath = Join-Path $Root 'download-status.json'
    @($Rows) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    @($Rows) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
}

function Get-LegacyNameKey {
    param(
        [Parameter(Mandatory)] [string]$Module,
        [Parameter(Mandatory)] [string]$Lesson
    )

    $cleanModule = (($Module -replace '^\s*\d+\s*-\s*', '') -replace '\s+', ' ').Trim()
    $cleanLesson = (($Lesson -replace '^\s*\d+\s*-\s*', '') -replace '\s+', ' ').Trim()
    return ('{0}|{1}' -f $cleanModule, $cleanLesson).ToLowerInvariant()
}

$CourseRoot = [IO.Path]::GetFullPath($CourseRoot)
if (-not (Test-Path -LiteralPath $CourseRoot -PathType Container)) {
    throw "Course folder does not exist: $CourseRoot"
}

$structurePath = Join-Path $CourseRoot 'course-structure.csv'
if (-not (Test-Path -LiteralPath $structurePath -PathType Leaf)) {
    throw "Course structure manifest is missing. Run 1-create-course-structure.ps1 first: $structurePath"
}

$lessonDownloader = Join-Path $PSScriptRoot 'download-learningsuite.ps1'
if (-not (Test-Path -LiteralPath $lessonDownloader -PathType Leaf)) {
    throw "The lesson downloader is missing: $lessonDownloader"
}

if ($MigrationMode -eq 'Move') {
    $activeLegacyDownloaders = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.Name -match 'powershell|pwsh' -and
                $_.CommandLine -match 'download-learningsuite-(all-courses|course|parallel)\.ps1'
            }
    )
    if ($activeLegacyDownloaders.Count -gt 0) {
        throw 'A legacy downloader is still running. Moving its files now could make it download them again. Stop it first, or rerun with -MigrationMode Copy.'
    }
}

$legacyByUrl = @{}
$legacyByName = @{}
if ($MigrationMode -ne 'None' -and (Test-Path -LiteralPath $LegacyRoot -PathType Container)) {
    $LegacyRoot = [IO.Path]::GetFullPath($LegacyRoot)
    $legacyManifests = @(
        Get-ChildItem -LiteralPath $LegacyRoot -Recurse -Filter 'course-manifest*.csv' -File -ErrorAction SilentlyContinue
    )
    foreach ($manifest in $legacyManifests) {
        foreach ($legacyRow in @(Import-Csv -LiteralPath $manifest.FullName)) {
            $legacyUrl = [string]$legacyRow.Url
            $legacyFile = [string]$legacyRow.VideoFile
            if (
                $legacyUrl -and
                $legacyFile -and
                -not $legacyByUrl.ContainsKey($legacyUrl) -and
                (Test-Path -LiteralPath $legacyFile -PathType Leaf) -and
                (Test-PathInsideRoot -Path $legacyFile -Root $LegacyRoot)
            ) {
                $legacyByUrl[$legacyUrl] = [IO.Path]::GetFullPath($legacyFile)
            }
        }
    }

    foreach ($legacyVideo in @(Get-ChildItem -LiteralPath $LegacyRoot -Recurse -Filter 'video.mp4' -File -ErrorAction SilentlyContinue)) {
        $lessonDirectory = $legacyVideo.Directory
        $sectionDirectory = $lessonDirectory.Parent
        $moduleDirectory = if ($sectionDirectory) { $sectionDirectory.Parent } else { $null }
        if (-not $moduleDirectory) {
            continue
        }
        $nameKey = Get-LegacyNameKey -Module $moduleDirectory.Name -Lesson $lessonDirectory.Name
        if (-not $legacyByName.ContainsKey($nameKey)) {
            $legacyByName[$nameKey] = $legacyVideo.FullName
        }
    }
}

$structureRows = @(Import-Csv -LiteralPath $structurePath)
if ($structureRows.Count -eq 0) {
    throw "Course structure contains no lessons: $structurePath"
}

$statusRows = New-Object Collections.ArrayList
$position = 0
$migrated = 0
$downloaded = 0
$existing = 0
$failed = 0
$noVideo = 0

foreach ($lesson in $structureRows) {
    $position++
    $relativePath = [string]$lesson.RelativePath
    if (-not $relativePath -or [IO.Path]::IsPathRooted($relativePath)) {
        throw "Unsafe or missing RelativePath for lesson: $($lesson.Lesson)"
    }

    $targetFile = [IO.Path]::GetFullPath((Join-Path $CourseRoot $relativePath))
    if (-not (Test-PathInsideRoot -Path $targetFile -Root $CourseRoot)) {
        throw "Lesson path escapes the course folder: $relativePath"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $targetFile) -Force | Out-Null

    $status = 'Pending'
    $errorMessage = ''
    Write-Host ''
    Write-Host ("[{0}/{1}] {2} / {3}" -f $position, $structureRows.Count, $lesson.Module, $lesson.Lesson) -ForegroundColor Yellow

    try {
        $expectsVideo = ([string]$lesson.ExpectedVideo -notmatch '^(False|0)$')
        if (-not $expectsVideo) {
            $status = 'NoVideo'
            $noVideo++
            Write-Host '  resource-only lesson; no video expected'
        }
        elseif (Test-Path -LiteralPath $targetFile -PathType Leaf) {
            $status = 'Existing'
            $existing++
            Write-Host '  video already exists; skipped'
        }
        elseif (
            $MigrationMode -ne 'None' -and
            (
                $legacyByUrl.ContainsKey([string]$lesson.Url) -or
                $legacyByName.ContainsKey((Get-LegacyNameKey -Module ([string]$lesson.Module) -Lesson ([string]$lesson.Lesson)))
            )
        ) {
            $nameKey = Get-LegacyNameKey -Module ([string]$lesson.Module) -Lesson ([string]$lesson.Lesson)
            $legacyFile = if ($legacyByUrl.ContainsKey([string]$lesson.Url)) {
                [string]$legacyByUrl[[string]$lesson.Url]
            }
            else {
                [string]$legacyByName[$nameKey]
            }
            if ($MigrationMode -eq 'Move') {
                Move-Item -LiteralPath $legacyFile -Destination $targetFile
                $status = 'Migrated'
                Write-Host "  moved and renamed legacy video: $targetFile" -ForegroundColor Green
            }
            else {
                Copy-Item -LiteralPath $legacyFile -Destination $targetFile
                $status = 'Copied'
                Write-Host "  copied and renamed legacy video: $targetFile" -ForegroundColor Green
            }
            $migrated++
        }
        elseif ($MigrationOnly) {
            $status = 'Missing'
            Write-Host '  no matching legacy video found'
        }
        else {
            $downloadArguments = @{
                PageUrl          = [string]$lesson.Url
                OutputPath       = $targetFile
                ChromePath       = $ChromePath
                ChromeProfilePath = $ChromeProfilePath
                DebugPort        = $DebugPort
                SeekWaitSeconds  = $SeekWaitSeconds
                Automatic        = $true
            }
            if ($FfmpegPath) { $downloadArguments.FfmpegPath = $FfmpegPath }
            if ($FfprobePath) { $downloadArguments.FfprobePath = $FfprobePath }
            & $lessonDownloader @downloadArguments
            $status = 'Downloaded'
            $downloaded++
        }
    }
    catch {
        $status = 'Failed'
        $errorMessage = $_.Exception.Message
        $failed++
        Write-Warning $errorMessage
    }

    [void]$statusRows.Add([pscustomobject][ordered]@{
        Module       = $lesson.Module
        Lesson       = $lesson.Lesson
        Duration     = $lesson.Duration
        Url          = $lesson.Url
        RelativePath = $relativePath
        Status       = $status
        Error        = $errorMessage
        UpdatedAt    = (Get-Date).ToString('s')
    })
    Write-DownloadStatus -Rows $statusRows -Root $CourseRoot
}

Write-Host ''
Write-Host 'Course pass completed.' -ForegroundColor Green
Write-Host "Course:     $CourseRoot"
Write-Host "Existing:   $existing"
Write-Host "Migrated:   $migrated"
Write-Host "Downloaded: $downloaded"
Write-Host "No video:   $noVideo"
Write-Host "Failed:     $failed"
