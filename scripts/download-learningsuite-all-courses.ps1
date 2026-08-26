[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BiohackingCourse'),

    [ValidateRange(1, 4)]
    [int]$StartAt = 1,

    [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe',

    [string]$ChromeProfilePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ChromeProfile'),

    [string]$FfmpegPath,

    [string]$FfprobePath,

    [ValidateRange(1025, 65535)]
    [int]$DebugPort = 9223,

    [ValidateRange(2, 30)]
    [int]$SeekWaitSeconds = 6,

    [switch]$Force,

    [switch]$SkipAttachments,

    [switch]$ListOnly,

    [switch]$Automatic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$courseDownloader = Join-Path $PSScriptRoot 'download-learningsuite-course.ps1'
if (-not (Test-Path -LiteralPath $courseDownloader -PathType Leaf)) {
    throw "The course downloader is missing: $courseDownloader"
}
if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) {
    throw "Chrome was not found at: $ChromePath"
}
$courses = @(
    [pscustomobject]@{
        Number = 1
        Title  = 'Mini-Masterclass Peptide'
        Url    = 'https://biohacking.learningsuite.io/student/course/mini-masterclass-peptide/TlbR5YFm'
    },
    [pscustomobject]@{
        Number = 2
        Title  = 'Biohacking - Essentials'
        Url    = 'https://biohacking.learningsuite.io/student/course/biohacking-essentials/YCSwPfWB'
    },
    [pscustomobject]@{
        Number = 3
        Title  = 'Biohacking Praxis'
        Url    = 'https://biohacking.learningsuite.io/student/course/biohacking-praxis/dwfpzvnB'
    },
    [pscustomobject]@{
        Number = 4
        Title  = 'Biohacking Bibliothek'
        Url    = 'https://biohacking.learningsuite.io/student/course/biohacking-bibliothek/wCmk81lS'
    }
)

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ChromeProfilePath -Force | Out-Null

$debugReady = $false
try {
    [void](Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json/version" -TimeoutSec 2)
    $debugReady = $true
}
catch {
    $debugReady = $false
}

if (-not $debugReady) {
    $chromeArguments = @(
        "--remote-debugging-port=$DebugPort",
        "--remote-allow-origins=http://127.0.0.1:$DebugPort",
        "--user-data-dir=$ChromeProfilePath",
        '--new-window',
        'https://biohacking.learningsuite.io/student'
    )
    Start-Process -FilePath $ChromePath -ArgumentList $chromeArguments | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        try {
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json/version" -TimeoutSec 2)
            $debugReady = $true
        }
        catch {
            $debugReady = $false
        }
    } while (-not $debugReady -and (Get-Date) -lt $deadline)

    if (-not $debugReady) {
        throw 'Chrome did not expose the local DevTools connection.'
    }
}

if (-not $Automatic) {
    Write-Host ''
    Write-Host 'In the downloader Chrome window:' -ForegroundColor Cyan
    Write-Host '  1. Log in to LearningSuite if needed.'
    Write-Host '  2. Confirm that your four courses are visible.'
    Write-Host '  3. Leave Chrome open until every course finishes.'
    [void](Read-Host 'Then return here and press Enter once')
}

$selectedCourses = @($courses | Where-Object { $_.Number -ge $StartAt })
if ($selectedCourses.Count -eq 0) {
    throw "No courses remain from StartAt $StartAt."
}

$summary = New-Object Collections.ArrayList
foreach ($course in $selectedCourses) {
    $courseDirectory = Join-Path $OutputRoot ("{0:00} - {1}" -f [int]$course.Number, $course.Title)
    New-Item -ItemType Directory -Path $courseDirectory -Force | Out-Null

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host ("Course {0}/4: {1}" -f [int]$course.Number, $course.Title) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray

    $status = if ($ListOnly) { 'Listed' } else { 'Completed' }
    $errorMessage = ''
    try {
        $arguments = @{
            CourseUrl         = $course.Url
            OutputRoot        = $courseDirectory
            ChromePath        = $ChromePath
            ChromeProfilePath = $ChromeProfilePath
            DebugPort         = $DebugPort
            SeekWaitSeconds   = $SeekWaitSeconds
            Automatic         = $true
        }
        if ($FfmpegPath) { $arguments.FfmpegPath = $FfmpegPath }
        if ($FfprobePath) { $arguments.FfprobePath = $FfprobePath }
        if ($Force) { $arguments.Force = $true }
        if ($SkipAttachments) { $arguments.SkipAttachments = $true }
        if ($ListOnly) { $arguments.ListOnly = $true }

        & $courseDownloader @arguments
    }
    catch {
        $status = 'Failed'
        $errorMessage = $_.Exception.Message
        Write-Warning "$($course.Title) failed: $errorMessage"
    }

    [void]$summary.Add([pscustomobject]@{
        Number    = $course.Number
        Course    = $course.Title
        Url       = $course.Url
        Folder    = $courseDirectory
        Status    = $status
        Error     = $errorMessage
        UpdatedAt = (Get-Date).ToString('s')
    })

    @($summary) | Export-Csv -LiteralPath (Join-Path $OutputRoot 'all-courses-summary.csv') -NoTypeInformation -Encoding UTF8
    @($summary) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'all-courses-summary.json') -Encoding UTF8
}

Write-Host ''
Write-Host 'All selected courses were processed.' -ForegroundColor Green
Write-Host "Root folder: $OutputRoot"
Write-Host "Summary:     $(Join-Path $OutputRoot 'all-courses-summary.csv')"

if (@($summary | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) {
    Write-Warning 'One or more courses failed. Rerun the same command to retry only missing files.'
}
