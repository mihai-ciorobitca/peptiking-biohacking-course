[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BiohackingCourse'),

    [ValidateRange(1, 4)]
    [int]$StartAt = 2,

    [ValidateRange(1, 4)]
    [int]$WorkersPerCourse = 2,

    [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe',

    [string]$TemplateProfilePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ChromeProfile'),

    [string]$ParallelProfileRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ParallelProfiles'),

    [ValidateRange(1025, 65000)]
    [int]$ParallelPortBase = 9300,

    [ValidateRange(2, 30)]
    [int]$SeekWaitSeconds = 4,

    [string]$FfmpegPath,

    [string]$FfprobePath,

    [switch]$Force,

    [switch]$SkipAttachments,

    [switch]$ReuseWorkerProfiles,

    [switch]$ListOnly,

    [switch]$Automatic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)] [string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}
function Test-DebugPort {
    param([int]$Port)
    try {
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 1)
        return $true
    }
    catch {
        return $false
    }
}

function Copy-ChromeProfile {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $excludedDirectories = @(
        'Cache',
        'Code Cache',
        'GPUCache',
        'GrShaderCache',
        'ShaderCache',
        'DawnCache',
        'Crashpad',
        'BrowserMetrics',
        'component_crx_cache'
    )
    $arguments = @(
        $Source,
        $Destination,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/R:1',
        '/W:1',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP',
        '/XD'
    ) + $excludedDirectories + @(
        '/XF',
        'Singleton*',
        'DevToolsActivePort',
        '*.lock',
        '*.tmp'
    )

    & robocopy.exe @arguments | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Chrome profile copy failed with robocopy exit code $LASTEXITCODE."
    }
}

function Move-StaleChromeProfile {
    param(
        [Parameter(Mandatory)] [string]$ProfilePath,
        [Parameter(Mandatory)] [string]$ProfileRoot
    )

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) {
        return
    }

    $resolvedProfile = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
    if (-not $resolvedProfile.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace a Chrome profile outside the parallel profile root: $resolvedProfile"
    }

    $backupPath = '{0}.stale-{1}' -f $resolvedProfile, (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    Move-Item -LiteralPath $resolvedProfile -Destination $backupPath
    Write-Host "    previous worker profile preserved at: $backupPath" -ForegroundColor DarkGray
}

function Merge-WorkerManifests {
    param([Parameter(Mandatory)] [string]$CourseDirectory)

    $manifestFiles = @(
        Get-ChildItem -LiteralPath $CourseDirectory -Filter 'course-manifest.worker-*.csv' -File -ErrorAction SilentlyContinue
    )
    if ($manifestFiles.Count -eq 0) {
        return
    }

    $rows = @(
        foreach ($manifestFile in $manifestFiles) {
            Import-Csv -LiteralPath $manifestFile.FullName
        }
    ) | Sort-Object `
        @{ Expression = { [int]$_.ModuleNumber } },
        @{ Expression = { [string]$_.Section } },
        @{ Expression = { [int]$_.LessonNumber } }

    $rows | Export-Csv -LiteralPath (Join-Path $CourseDirectory 'course-manifest.csv') -NoTypeInformation -Encoding UTF8
    $rows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $CourseDirectory 'course-manifest.json') -Encoding UTF8

    $summaryLines = New-Object Collections.Generic.List[string]
    $summaryLines.Add('Parallel LearningSuite download summary')
    $summaryLines.Add(('Updated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $summaryLines.Add(('Lessons recorded: ' + $rows.Count))
    $summaryLines.Add(('Videos available: ' + @($rows | Where-Object { $_.VideoStatus -in @('Downloaded', 'Existing') }).Count))
    $summaryLines.Add(('Resource-only lessons: ' + @($rows | Where-Object { $_.VideoStatus -eq 'NoVideo' }).Count))
    $summaryLines.Add(('Failures: ' + @($rows | Where-Object { $_.VideoStatus -eq 'Failed' }).Count))
    $summaryLines | Set-Content -LiteralPath (Join-Path $CourseDirectory 'README-parallel.txt') -Encoding UTF8
}

$courseDownloader = Join-Path $PSScriptRoot 'download-learningsuite-course.ps1'
if (-not (Test-Path -LiteralPath $courseDownloader -PathType Leaf)) {
    throw "The course downloader is missing: $courseDownloader"
}
if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) {
    throw "Chrome was not found at: $ChromePath"
}
if (-not (Test-Path -LiteralPath $TemplateProfilePath -PathType Container)) {
    throw "The authenticated downloader Chrome profile is missing: $TemplateProfilePath"
}

if (Test-DebugPort -Port 9223) {
    throw 'The original downloader Chrome is still running on port 9223. Finish/stop the current lesson and close that downloader Chrome window before starting the parallel script. Nothing was stopped automatically.'
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
$ParallelProfileRoot = [IO.Path]::GetFullPath($ParallelProfileRoot)
$parallelLogRoot = Join-Path $OutputRoot 'parallel-logs'
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ParallelProfileRoot -Force | Out-Null
New-Item -ItemType Directory -Path $parallelLogRoot -Force | Out-Null

$workerSpecs = New-Object Collections.ArrayList
foreach ($course in @($courses | Where-Object { $_.Number -ge $StartAt })) {
    for ($workerIndex = 0; $workerIndex -lt $WorkersPerCourse; $workerIndex++) {
        $workerNumber = $workerIndex + 1
        $port = $ParallelPortBase + ($course.Number * 10) + $workerNumber
        $portAlreadyRunning = Test-DebugPort -Port $port
        if ($portAlreadyRunning -and -not $ReuseWorkerProfiles) {
            throw "Parallel worker port $port is already in use. Close the previous parallel Chrome windows before restarting."
        }

        $profilePath = Join-Path $ParallelProfileRoot ("course-{0:00}-worker-{1:00}" -f [int]$course.Number, $workerNumber)
        $courseDirectory = Join-Path $OutputRoot ("{0:00} - {1}" -f [int]$course.Number, $course.Title)
        [void]$workerSpecs.Add([pscustomobject]@{
            Course          = $course
            WorkerIndex     = $workerIndex
            WorkerNumber    = $workerNumber
            Port            = $port
            ProfilePath     = $profilePath
            CourseDirectory = $courseDirectory
            PortAlreadyRunning = $portAlreadyRunning
            Process         = $null
        })
    }
}

if ($workerSpecs.Count -eq 0) {
    throw 'No courses were selected.'
}

Write-Host "Preparing $($workerSpecs.Count) isolated Chrome workers..." -ForegroundColor Cyan
foreach ($worker in $workerSpecs) {
    $hasExistingProfile = Test-Path -LiteralPath (Join-Path $worker.ProfilePath 'Local State') -PathType Leaf
    if (-not $hasExistingProfile -or -not $ReuseWorkerProfiles) {
        if ($hasExistingProfile -and -not $ReuseWorkerProfiles) {
            Move-StaleChromeProfile -ProfilePath $worker.ProfilePath -ProfileRoot $ParallelProfileRoot
        }
        Write-Host ("  copying login profile for course {0}, worker {1}" -f $worker.Course.Number, $worker.WorkerNumber)
        Copy-ChromeProfile -Source $TemplateProfilePath -Destination $worker.ProfilePath
    }

    New-Item -ItemType Directory -Path $worker.CourseDirectory -Force | Out-Null
    if (-not $worker.PortAlreadyRunning) {
        $chromeArguments = @(
            "--remote-debugging-port=$($worker.Port)",
            "--remote-allow-origins=http://127.0.0.1:$($worker.Port)",
            "--user-data-dir=$($worker.ProfilePath)",
            '--new-window',
            $worker.Course.Url
        )
        Start-Process -FilePath $ChromePath -ArgumentList $chromeArguments | Out-Null
    }
}

$startupDeadline = (Get-Date).AddSeconds(45)
do {
    Start-Sleep -Seconds 1
    $readyWorkers = @($workerSpecs | Where-Object { Test-DebugPort -Port $_.Port }).Count
} while ($readyWorkers -lt $workerSpecs.Count -and (Get-Date) -lt $startupDeadline)

if ($readyWorkers -lt $workerSpecs.Count) {
    throw "Only $readyWorkers of $($workerSpecs.Count) Chrome workers started successfully."
}

if (-not $Automatic) {
    Write-Host ''
    Write-Host "$($workerSpecs.Count) Chrome worker windows are open." -ForegroundColor Green
    Write-Host 'Confirm each window shows its LearningSuite course and is logged in.'
    Write-Host 'Do not close the worker Chrome windows while downloads are running.'
    [void](Read-Host 'Then return here and press Enter to start all workers')
}

foreach ($worker in $workerSpecs) {
    $manifestSuffix = ".worker-{0:00}-of-{1:00}" -f $worker.WorkerNumber, $WorkersPerCourse
    $commandParts = New-Object Collections.Generic.List[string]
    $commandParts.Add('&')
    $commandParts.Add((ConvertTo-PowerShellLiteral -Value $courseDownloader))
    $commandParts.Add((ConvertTo-PowerShellLiteral -Value $worker.Course.Url))
    $commandParts.Add('-OutputRoot')
    $commandParts.Add((ConvertTo-PowerShellLiteral -Value $worker.CourseDirectory))
    $commandParts.Add('-ChromePath')
    $commandParts.Add((ConvertTo-PowerShellLiteral -Value $ChromePath))
    $commandParts.Add('-ChromeProfilePath')
    $commandParts.Add((ConvertTo-PowerShellLiteral -Value $worker.ProfilePath))
    $commandParts.Add('-DebugPort')
    $commandParts.Add([string]$worker.Port)
    $commandParts.Add('-SeekWaitSeconds')
    $commandParts.Add([string]$SeekWaitSeconds)
    $commandParts.Add('-WorkerCount')
    $commandParts.Add([string]$WorkersPerCourse)
    $commandParts.Add('-WorkerIndex')
    $commandParts.Add([string]$worker.WorkerIndex)
    $commandParts.Add('-ManifestSuffix')
    $commandParts.Add((ConvertTo-PowerShellLiteral -Value $manifestSuffix))
    $commandParts.Add('-Automatic')
    if ($FfmpegPath) {
        $commandParts.Add('-FfmpegPath')
        $commandParts.Add((ConvertTo-PowerShellLiteral -Value $FfmpegPath))
    }
    if ($FfprobePath) {
        $commandParts.Add('-FfprobePath')
        $commandParts.Add((ConvertTo-PowerShellLiteral -Value $FfprobePath))
    }
    if ($Force) { $commandParts.Add('-Force') }
    if ($SkipAttachments) { $commandParts.Add('-SkipAttachments') }
    if ($ListOnly) { $commandParts.Add('-ListOnly') }

    $workerName = "course-{0:00}-worker-{1:00}" -f [int]$worker.Course.Number, $worker.WorkerNumber
    $launcherPath = Join-Path $parallelLogRoot "$workerName.ps1"
    $logPath = Join-Path $parallelLogRoot "$workerName.log"
    $downloadCommand = $commandParts -join ' '
    @(
        "`$ErrorActionPreference = 'Stop'",
        "Start-Transcript -LiteralPath $(ConvertTo-PowerShellLiteral -Value $logPath) -Force | Out-Null",
        "`$workerExitCode = 0",
        'try {',
        "    $downloadCommand",
        "    if (-not `$?) { `$workerExitCode = 1 }",
        '}',
        'catch {',
        "    Write-Error (`$_ | Out-String)",
        "    `$workerExitCode = 1",
        '}',
        'finally {',
        "    try { Stop-Transcript | Out-Null } catch { }",
        '}',
        'exit $workerExitCode'
    ) | Set-Content -LiteralPath $launcherPath -Encoding UTF8

    $launcherArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`""
    $worker.Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $launcherArguments -PassThru
    Write-Host ("Started course {0} worker {1}/{2}: PID {3}, port {4}, log {5}" -f $worker.Course.Number, $worker.WorkerNumber, $WorkersPerCourse, $worker.Process.Id, $worker.Port, $logPath) -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'Workers are downloading in parallel. Their individual windows show live progress.' -ForegroundColor Green
Write-Host 'This coordinator will merge their manifests when every worker exits.'

while (@($workerSpecs | Where-Object { -not $_.Process.HasExited }).Count -gt 0) {
    Start-Sleep -Seconds 10
    $remaining = @($workerSpecs | Where-Object { -not $_.Process.HasExited }).Count
    Write-Host "$remaining worker(s) still running..."
}

$failedWorkers = @($workerSpecs | Where-Object { $_.Process.ExitCode -ne 0 })
foreach ($course in @($courses | Where-Object { $_.Number -ge $StartAt })) {
    $courseDirectory = Join-Path $OutputRoot ("{0:00} - {1}" -f [int]$course.Number, $course.Title)
    Merge-WorkerManifests -CourseDirectory $courseDirectory
}

Write-Host ''
Write-Host 'Parallel download pass completed.' -ForegroundColor Green
Write-Host "Root folder: $OutputRoot"
if ($failedWorkers.Count -gt 0) {
    Write-Warning "$($failedWorkers.Count) worker(s) exited with errors. Rerun this script with -ReuseWorkerProfiles; completed videos will be skipped."
}
