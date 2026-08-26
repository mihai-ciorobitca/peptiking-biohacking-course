[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$CourseRoot,

    [ValidateRange(1, 100000)]
    [int]$StartAt = 1,

    [ValidateRange(0, 100000)]
    [int]$EndAt = 0,

    [ValidateRange(1, 8)]
    [int]$MaxParallel = 5,

    [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe',

    [string]$TemplateProfilePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ChromeProfile'),

    [ValidateRange(0, 65535)]
    [int]$TemplateDebugPort = 0,

    [string]$WorkerProfileRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ParallelVideoProfiles'),

    [ValidateRange(1025, 65000)]
    [int]$DebugPortBase = 9420,

    [ValidateRange(2, 30)]
    [int]$SeekWaitSeconds = 6,

    [string]$FfmpegPath,

    [string]$FfprobePath,

    [switch]$Automatic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)] [string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $resolvedPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
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

function Read-CdpMessage {
    param([Parameter(Mandatory)] [Net.WebSockets.ClientWebSocket]$Socket)

    $memory = [IO.MemoryStream]::new()
    try {
        do {
            $buffer = [byte[]]::new(65536)
            $segment = [ArraySegment[byte]]::new($buffer)
            $receive = $Socket.ReceiveAsync(
                $segment,
                [Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()
            if ($receive.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'Chrome closed the DevTools connection.'
            }
            if ($receive.Count -gt 0) {
                $memory.Write($buffer, 0, $receive.Count)
            }
        } while (-not $receive.EndOfMessage)

        [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
    }
    finally {
        $memory.Dispose()
    }
}

function Invoke-CdpCommandAtPort {
    param(
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [string]$Method,
        [hashtable]$Params = @{}
    )

    $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 5)
    if ($targets.Count -eq 1 -and $targets[0] -is [array]) {
        $targets = @($targets[0])
    }
    $target = @($targets | Where-Object {
        $_.type -eq 'page' -and $_.webSocketDebuggerUrl -and $_.url -match 'learningsuite\.io'
    }) | Select-Object -First 1
    if (-not $target) {
        $target = @($targets | Where-Object {
            $_.type -eq 'page' -and $_.webSocketDebuggerUrl
        }) | Select-Object -First 1
    }
    if (-not $target) {
        throw "No browser page target was found on debugging port $Port."
    }

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.SetRequestHeader('Origin', "http://127.0.0.1:$Port")
    try {
        [void]$socket.ConnectAsync(
            [Uri]$target.webSocketDebuggerUrl,
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()

        $script:ParallelCdpId++
        $commandId = $script:ParallelCdpId
        $payload = @{
            id     = $commandId
            method = $Method
            params = $Params
        } | ConvertTo-Json -Compress -Depth 30
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [ArraySegment[byte]]::new($bytes)
        [void]$socket.SendAsync(
            $segment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()

        while ($true) {
            $message = Read-CdpMessage -Socket $socket
            if (($message.PSObject.Properties.Name -contains 'id') -and $message.id -eq $commandId) {
                if ($message.PSObject.Properties.Name -contains 'error') {
                    throw "Chrome DevTools error on port ${Port}: $($message.error.message)"
                }
                return $message.result
            }
        }
    }
    finally {
        if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            try {
                [void]$socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'Finished',
                    [Threading.CancellationToken]::None
                ).GetAwaiter().GetResult()
            }
            catch { }
        }
        $socket.Dispose()
    }
}

function Copy-LearningSuiteSession {
    param(
        [Parameter(Mandatory)] [int]$SourcePort,
        [Parameter(Mandatory)] [object[]]$Workers,
        [Parameter(Mandatory)] [string]$PageUrl
    )

    $sourceResult = Invoke-CdpCommandAtPort -Port $SourcePort -Method 'Runtime.evaluate' -Params @{
        expression    = 'Object.entries(localStorage).map(([key, value]) => ({ key, value }))'
        returnByValue = $true
    }
    $entries = @($sourceResult.result.value)
    if ($entries.Count -eq 1 -and $entries[0] -is [array]) {
        $entries = @($entries[0])
    }
    if (@($entries | Where-Object { [string]$_.key -match '^auth_refresh_token_' }).Count -eq 0) {
        throw "The LearningSuite refresh token was not found in the source Chrome session on port $SourcePort."
    }

    $entriesJson = ConvertTo-Json -InputObject @($entries) -Compress -Depth 5
    $expression = @"
(() => {
  const entries = $entriesJson;
  for (const entry of entries) localStorage.setItem(entry.key, entry.value);
  return entries.length;
})()
"@

    foreach ($worker in $Workers) {
        [void](Invoke-CdpCommandAtPort -Port $worker.Port -Method 'Page.navigate' -Params @{ url = $PageUrl })
    }
    Start-Sleep -Seconds 3

    foreach ($worker in $Workers) {
        [void](Invoke-CdpCommandAtPort -Port $worker.Port -Method 'Runtime.evaluate' -Params @{
            expression    = $expression
            returnByValue = $true
        })
        [void](Invoke-CdpCommandAtPort -Port $worker.Port -Method 'Page.navigate' -Params @{ url = $PageUrl })
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
        'component_crx_cache',
        'optimization_guide_model_store',
        'Safe Browsing',
        'WasmTtsEngine',
        'OnDeviceHeadSuggestModel'
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

function Write-ParallelStatus {
    param(
        [Parameter(Mandatory)] [Collections.IEnumerable]$Rows,
        [Parameter(Mandatory)] [string]$Root
    )

    $orderedRows = @($Rows | Sort-Object Index)
    $orderedRows | Export-Csv -LiteralPath (Join-Path $Root 'parallel-download-status.csv') -NoTypeInformation -Encoding UTF8
    $orderedRows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Root 'parallel-download-status.json') -Encoding UTF8
}

if ($EndAt -gt 0 -and $EndAt -lt $StartAt) {
    throw "EndAt $EndAt must be zero or greater than or equal to StartAt $StartAt."
}
if (($DebugPortBase + $MaxParallel) -gt 65535) {
    throw 'The requested worker port range exceeds 65535.'
}

$CourseRoot = [IO.Path]::GetFullPath($CourseRoot)
$TemplateProfilePath = [IO.Path]::GetFullPath($TemplateProfilePath)
$WorkerProfileRoot = [IO.Path]::GetFullPath($WorkerProfileRoot)
$script:ParallelCdpId = 0
$useLiveSession = $TemplateDebugPort -gt 0 -and (Test-DebugPort -Port $TemplateDebugPort)

if (-not (Test-Path -LiteralPath $CourseRoot -PathType Container)) {
    throw "Course folder does not exist: $CourseRoot"
}
if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) {
    throw "Chrome was not found at: $ChromePath"
}
if (-not $useLiveSession -and -not (Test-Path -LiteralPath $TemplateProfilePath -PathType Container)) {
    throw "The authenticated Chrome profile is missing: $TemplateProfilePath"
}

$structurePath = Join-Path $CourseRoot 'course-structure.csv'
if (-not (Test-Path -LiteralPath $structurePath -PathType Leaf)) {
    throw "Course structure manifest is missing. Run 1-create-course-structure.ps1 first: $structurePath"
}

$lessonDownloader = Join-Path $PSScriptRoot 'download-learningsuite.ps1'
if (-not (Test-Path -LiteralPath $lessonDownloader -PathType Leaf)) {
    throw "The lesson downloader is missing: $lessonDownloader"
}

$structureRows = @(Import-Csv -LiteralPath $structurePath)
if ($structureRows.Count -eq 0) {
    throw "Course structure contains no lessons: $structurePath"
}

$effectiveEnd = if ($EndAt -eq 0) { $structureRows.Count } else { [Math]::Min($EndAt, $structureRows.Count) }
if ($StartAt -gt $structureRows.Count) {
    throw "StartAt $StartAt exceeds the $($structureRows.Count) lessons in this course."
}

$logRoot = Join-Path $CourseRoot 'parallel-download-logs'
$courseProfileLeaf = ([IO.Path]::GetFileName($CourseRoot) -replace '[^A-Za-z0-9._-]', '-').Trim('-')
if (-not $courseProfileLeaf) {
    $courseProfileLeaf = 'course'
}
$courseProfileRoot = Join-Path $WorkerProfileRoot $courseProfileLeaf
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
New-Item -ItemType Directory -Path $courseProfileRoot -Force | Out-Null

$results = New-Object Collections.ArrayList
$pending = [Collections.Generic.Queue[object]]::new()
for ($index = $StartAt; $index -le $effectiveEnd; $index++) {
    $lesson = $structureRows[$index - 1]
    $relativePath = [string]$lesson.RelativePath
    if (-not $relativePath -or [IO.Path]::IsPathRooted($relativePath)) {
        throw "Unsafe or missing RelativePath for lesson ${index}: $($lesson.Lesson)"
    }

    $targetFile = [IO.Path]::GetFullPath((Join-Path $CourseRoot $relativePath))
    if (-not (Test-PathInsideRoot -Path $targetFile -Root $CourseRoot)) {
        throw "Lesson path escapes the course folder: $relativePath"
    }

    $baseResult = [ordered]@{
        Index        = $index
        Module       = [string]$lesson.Module
        Lesson       = [string]$lesson.Lesson
        Duration     = [string]$lesson.Duration
        Url          = [string]$lesson.Url
        RelativePath = $relativePath
        Worker       = ''
        Status       = 'Pending'
        Error        = ''
        UpdatedAt    = ''
    }

    if ([string]$lesson.ExpectedVideo -match '^(False|0)$') {
        $baseResult.Status = 'NoVideo'
        $baseResult.UpdatedAt = (Get-Date).ToString('s')
        [void]$results.Add([pscustomobject]$baseResult)
    }
    elseif (Test-Path -LiteralPath $targetFile -PathType Leaf) {
        $baseResult.Status = 'Existing'
        $baseResult.UpdatedAt = (Get-Date).ToString('s')
        [void]$results.Add([pscustomobject]$baseResult)
    }
    else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $targetFile) -Force | Out-Null
        $pending.Enqueue([pscustomobject]@{
            Index      = $index
            Lesson     = $lesson
            TargetFile = $targetFile
            Result     = $baseResult
        })
    }
}

Write-Host ("Selected lessons {0}-{1}: {2} queued, {3} already resolved." -f $StartAt, $effectiveEnd, $pending.Count, $results.Count) -ForegroundColor Cyan
if ($pending.Count -eq 0) {
    Write-ParallelStatus -Rows $results -Root $CourseRoot
    Write-Host 'Nothing needs downloading.' -ForegroundColor Green
    return
}

$workerCount = [Math]::Min($MaxParallel, $pending.Count)
$firstUrl = [string]$pending.Peek().Lesson.Url
$workers = New-Object Collections.ArrayList

Write-Host "Preparing $workerCount isolated Chrome workers..." -ForegroundColor Cyan
for ($workerIndex = 0; $workerIndex -lt $workerCount; $workerIndex++) {
    $workerNumber = $workerIndex + 1
    $port = $DebugPortBase + $workerNumber
    $profilePath = Join-Path $courseProfileRoot ("worker-{0:00}" -f $workerNumber)
    $hasProfile = Test-Path -LiteralPath (Join-Path $profilePath 'Local State') -PathType Leaf

    if (-not $hasProfile) {
        if ($useLiveSession) {
            Write-Host "  creating clean profile for worker $workerNumber/$workerCount"
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
        }
        else {
            Write-Host "  copying authenticated profile for worker $workerNumber/$workerCount"
            Copy-ChromeProfile -Source $TemplateProfilePath -Destination $profilePath
        }
    }
    else {
        Write-Host "  reusing worker profile $workerNumber/$workerCount"
    }

    $portReady = Test-DebugPort -Port $port
    if (-not $portReady) {
        $chromeArguments = @(
            "--remote-debugging-port=$port",
            "--remote-allow-origins=http://127.0.0.1:$port",
            "--user-data-dir=$profilePath",
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-sync',
            '--new-window',
            $firstUrl
        )
        Start-Process -FilePath $ChromePath -ArgumentList $chromeArguments -WindowStyle Hidden | Out-Null
    }

    [void]$workers.Add([pscustomobject]@{
        Number      = $workerNumber
        Port        = $port
        ProfilePath = $profilePath
        Process     = $null
        Task        = $null
        LogPath     = $null
    })
}

$startupDeadline = (Get-Date).AddSeconds(60)
$startupAttempt = 0
do {
    Start-Sleep -Seconds 1
    $startupAttempt++
    if (($startupAttempt % 5) -eq 0) {
        foreach ($worker in @($workers | Where-Object { -not (Test-DebugPort -Port $_.Port) })) {
            $retryArguments = @(
                "--remote-debugging-port=$($worker.Port)",
                "--remote-allow-origins=http://127.0.0.1:$($worker.Port)",
                "--user-data-dir=$($worker.ProfilePath)",
                '--no-first-run',
                '--no-default-browser-check',
                '--disable-sync',
                '--new-window',
                $firstUrl
            )
            Start-Process -FilePath $ChromePath -ArgumentList $retryArguments -WindowStyle Hidden | Out-Null
        }
    }
    $readyWorkers = @($workers | Where-Object { Test-DebugPort -Port $_.Port }).Count
} while ($readyWorkers -lt $workerCount -and (Get-Date) -lt $startupDeadline)

if ($readyWorkers -lt $workerCount) {
    throw "Only $readyWorkers of $workerCount Chrome workers started successfully."
}

if ($useLiveSession) {
    Write-Host "Copying the authenticated LearningSuite session from port $TemplateDebugPort..." -ForegroundColor Cyan
    Copy-LearningSuiteSession -SourcePort $TemplateDebugPort -Workers @($workers) -PageUrl $firstUrl
    Start-Sleep -Seconds 3
}

if (-not $Automatic) {
    Write-Host ''
    Write-Host "$workerCount Chrome worker windows are open." -ForegroundColor Green
    Write-Host 'Confirm each window is logged in and can display the selected LearningSuite lesson.'
    Write-Host 'Leave all worker Chrome windows open until this script finishes.'
    [void](Read-Host 'Then return here and press Enter to start parallel downloads')
}

Write-Host ''
Write-Host "Starting up to $workerCount simultaneous video downloads..." -ForegroundColor Green

while ($pending.Count -gt 0 -or @($workers | Where-Object { $_.Process }).Count -gt 0) {
    foreach ($worker in $workers) {
        if ($worker.Process) {
            $worker.Process.Refresh()
            if ($worker.Process.HasExited) {
                $task = $worker.Task
                $resultData = $task.Result
                $resultData.Worker = [string]$worker.Number
                $resultData.UpdatedAt = (Get-Date).ToString('s')

                if ($worker.Process.ExitCode -eq 0 -and (Test-Path -LiteralPath $task.TargetFile -PathType Leaf)) {
                    $resultData.Status = 'Downloaded'
                    Write-Host ("[{0}] completed on worker {1}: {2}" -f $task.Index, $worker.Number, $task.Lesson.Lesson) -ForegroundColor Green
                }
                else {
                    $resultData.Status = 'Failed'
                    $resultData.Error = "Worker exit code $($worker.Process.ExitCode). See: $($worker.LogPath)"
                    Write-Warning ("[{0}] failed on worker {1}: {2}. See {3}" -f $task.Index, $worker.Number, $task.Lesson.Lesson, $worker.LogPath)
                }

                [void]$results.Add([pscustomobject]$resultData)
                Write-ParallelStatus -Rows $results -Root $CourseRoot
                $worker.Process.Dispose()
                $worker.Process = $null
                $worker.Task = $null
                $worker.LogPath = $null
            }
        }

        if (-not $worker.Process -and $pending.Count -gt 0) {
            $task = $pending.Dequeue()
            $safeLogName = "lesson-{0:0000}-worker-{1:00}" -f $task.Index, $worker.Number
            $launcherPath = Join-Path $logRoot ($safeLogName + '.ps1')
            $logPath = Join-Path $logRoot ($safeLogName + '.log')

            $commandParts = New-Object Collections.Generic.List[string]
            $commandParts.Add('&')
            $commandParts.Add((ConvertTo-PowerShellLiteral -Value $lessonDownloader))
            $commandParts.Add('-PageUrl')
            $commandParts.Add((ConvertTo-PowerShellLiteral -Value ([string]$task.Lesson.Url)))
            $commandParts.Add('-OutputPath')
            $commandParts.Add((ConvertTo-PowerShellLiteral -Value $task.TargetFile))
            $commandParts.Add('-ChromePath')
            $commandParts.Add((ConvertTo-PowerShellLiteral -Value $ChromePath))
            $commandParts.Add('-ChromeProfilePath')
            $commandParts.Add((ConvertTo-PowerShellLiteral -Value $worker.ProfilePath))
            $commandParts.Add('-DebugPort')
            $commandParts.Add([string]$worker.Port)
            $commandParts.Add('-SeekWaitSeconds')
            $commandParts.Add([string]$SeekWaitSeconds)
            $commandParts.Add('-Automatic')
            if ($FfmpegPath) {
                $commandParts.Add('-FfmpegPath')
                $commandParts.Add((ConvertTo-PowerShellLiteral -Value $FfmpegPath))
            }
            if ($FfprobePath) {
                $commandParts.Add('-FfprobePath')
                $commandParts.Add((ConvertTo-PowerShellLiteral -Value $FfprobePath))
            }

            $downloadCommand = $commandParts -join ' '
            @(
                "`$ErrorActionPreference = 'Stop'",
                "Start-Transcript -LiteralPath $(ConvertTo-PowerShellLiteral -Value $logPath) -Force | Out-Null",
                '$workerExitCode = 0',
                'try {',
                "    $downloadCommand",
                '    if (-not $?) { $workerExitCode = 1 }',
                '}',
                'catch {',
                '    Write-Error ($_ | Out-String)',
                '    $workerExitCode = 1',
                '}',
                'finally {',
                '    try { Stop-Transcript | Out-Null } catch { }',
                '}',
                'exit $workerExitCode'
            ) | Set-Content -LiteralPath $launcherPath -Encoding Unicode

            $launcherArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`""
            $worker.Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $launcherArguments -WindowStyle Hidden -PassThru
            $worker.Task = $task
            $worker.LogPath = $logPath
            Write-Host ("[{0}] started on worker {1}: {2}" -f $task.Index, $worker.Number, $task.Lesson.Lesson) -ForegroundColor Cyan
        }
    }

    if ($pending.Count -gt 0 -or @($workers | Where-Object { $_.Process }).Count -gt 0) {
        Start-Sleep -Seconds 2
    }
}

Write-ParallelStatus -Rows $results -Root $CourseRoot
$downloaded = @($results | Where-Object { $_.Status -eq 'Downloaded' }).Count
$existing = @($results | Where-Object { $_.Status -eq 'Existing' }).Count
$noVideo = @($results | Where-Object { $_.Status -eq 'NoVideo' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count

Write-Host ''
Write-Host 'Parallel download pass completed.' -ForegroundColor Green
Write-Host "Course:     $CourseRoot"
Write-Host "Range:      $StartAt-$effectiveEnd"
Write-Host "Downloaded: $downloaded"
Write-Host "Existing:   $existing"
Write-Host "No video:   $noVideo"
Write-Host "Failed:     $failed"
Write-Host "Status:     $(Join-Path $CourseRoot 'parallel-download-status.csv')"

if ($failed -gt 0) {
    throw "$failed parallel download(s) failed. Check the per-lesson logs in: $logRoot"
}
