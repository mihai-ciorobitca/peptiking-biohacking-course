[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$CourseUrl,

    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BiohackingCourse'),

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

    [switch]$StructureOnly,

    [switch]$Automatic,

    [ValidateRange(1, 8)]
    [int]$WorkerCount = 1,

    [ValidateRange(0, 7)]
    [int]$WorkerIndex = 0,

    [string]$ManifestSuffix = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DevToolsTargets {
    param([int]$Port)
    @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 5)
}
function Read-CdpMessage {
    param([Parameter(Mandatory)] [System.Net.WebSockets.ClientWebSocket]$Socket)

    $memory = New-Object IO.MemoryStream
    try {
        do {
            $buffer = New-Object byte[] 65536
            $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
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

        $json = [Text.Encoding]::UTF8.GetString($memory.ToArray())
        $json | ConvertFrom-Json
    }
    finally {
        $memory.Dispose()
    }
}

function Send-CdpCommand {
    param(
        [Parameter(Mandatory)] [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)] [string]$Method,
        [hashtable]$Params = @{}
    )

    $script:CdpId++
    $commandId = $script:CdpId
    $payload = @{
        id     = $commandId
        method = $Method
        params = $Params
    } | ConvertTo-Json -Compress -Depth 30

    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
    [void]($Socket.SendAsync(
        $segment,
        [Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult())

    while ($true) {
        $message = Read-CdpMessage -Socket $Socket
        if (($message.PSObject.Properties.Name -contains 'id') -and $message.id -eq $commandId) {
            if ($message.PSObject.Properties.Name -contains 'error') {
                throw "Chrome DevTools error: $($message.error.message)"
            }
            return $message.result
        }
    }
}

function Invoke-CdpExpression {
    param(
        [Parameter(Mandatory)] [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)] [string]$Expression
    )

    $result = Send-CdpCommand -Socket $Socket -Method 'Runtime.evaluate' -Params @{
        expression    = $Expression
        returnByValue = $true
        awaitPromise  = $true
        userGesture   = $true
    }

    if ($result.PSObject.Properties.Name -contains 'exceptionDetails') {
        $description = [string]$result.exceptionDetails.text
        if ($result.exceptionDetails.exception) {
            $description = [string]$result.exceptionDetails.exception.description
        }
        throw "Page script failed: $description"
    }

    $result.result.value
}

function ConvertTo-JavaScriptString {
    param([Parameter(Mandatory)] [string]$Value)
    $Value | ConvertTo-Json -Compress
}

function Wait-ForPage {
    param(
        [Parameter(Mandatory)] [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$UrlPattern,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $state = Invoke-CdpExpression -Socket $Socket -Expression @'
(() => ({ url: location.href, ready: document.readyState, text: (document.body?.innerText || '').length }))()
'@
            if (
                $state.ready -ne 'loading' -and
                $state.text -gt 20 -and
                (-not $UrlPattern -or [string]$state.url -match $UrlPattern)
            ) {
                return $state
            }
        }
        catch {
            # Navigation briefly destroys the JavaScript context.
        }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)

    throw "The LearningSuite page did not finish loading within $TimeoutSeconds seconds."
}

function Open-CdpPage {
    param(
        [Parameter(Mandatory)] [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)] [string]$Url,
        [string]$UrlPattern
    )

    [void](Send-CdpCommand -Socket $Socket -Method 'Page.navigate' -Params @{ url = $Url })
    Wait-ForPage -Socket $Socket -UrlPattern $UrlPattern
}

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [int]$MaximumLength = 90
    )

    $safe = $Name.Trim()
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$character, '-')
    }
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim(' ', '.')
    if (-not $safe) {
        $safe = 'Untitled'
    }
    if ($safe.Length -gt $MaximumLength) {
        $safe = $safe.Substring(0, $MaximumLength).Trim(' ', '.')
    }
    $safe
}

function Write-CourseManifest {
    param(
        [Parameter(Mandatory)] [Collections.ArrayList]$Rows,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Url,
        [string]$Suffix = ''
    )

    $csvPath = Join-Path $Root ("course-manifest$Suffix.csv")
    $jsonPath = Join-Path $Root ("course-manifest$Suffix.json")
    $readmePath = Join-Path $Root ("README$Suffix.txt")

    @($Rows) | Select-Object ModuleNumber, Module, Section, LessonNumber, Lesson, Duration, Url, VideoStatus, VideoFile, AttachmentsStatus, AttachmentCount, Error, UpdatedAt |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    @($Rows) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $completed = @($Rows | Where-Object { $_.VideoStatus -in @('Downloaded', 'Existing') }).Count
    $failed = @($Rows | Where-Object { $_.VideoStatus -eq 'Failed' }).Count
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($Title)
    $lines.Add(('=' * $Title.Length))
    $lines.Add("Course URL: $Url")
    $lines.Add("Updated:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Videos:     $completed / $($Rows.Count) available locally")
    $lines.Add("Failures:   $failed")
    $lines.Add('')

    foreach ($moduleGroup in @($Rows | Group-Object ModuleNumber)) {
        $firstModule = $moduleGroup.Group | Select-Object -First 1
        $lines.Add(("{0:00}. {1}" -f [int]$firstModule.ModuleNumber, $firstModule.Module))
        foreach ($sectionGroup in @($moduleGroup.Group | Group-Object Section)) {
            $lines.Add("  $($sectionGroup.Name)")
            foreach ($row in $sectionGroup.Group) {
                $lines.Add(("    {0:00}. [{1}] {2}" -f [int]$row.LessonNumber, $row.VideoStatus, $row.Lesson))
            }
        }
        $lines.Add('')
    }

    $lines | Set-Content -LiteralPath $readmePath -Encoding UTF8
}

function Get-DownloadedFileCount {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) {
        return 0
    }
    @(
        Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ne '.crdownload' -and $_.Name -ne '.attachments-complete' }
    ).Count
}

if ($CourseUrl -match '^\s*\[' -or $CourseUrl -match '\]\(https?://') {
    throw 'Use the plain LearningSuite course URL without Markdown brackets.'
}
if ($WorkerIndex -ge $WorkerCount) {
    throw "WorkerIndex $WorkerIndex must be lower than WorkerCount $WorkerCount."
}
if ($CourseUrl -notmatch '^https://[^/]*learningsuite\.io/student/course/') {
    throw 'Pass a LearningSuite course overview or module URL.'
}
if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) {
    throw "Chrome was not found at: $ChromePath"
}

$lessonDownloader = Join-Path $PSScriptRoot 'download-learningsuite.ps1'
if (-not (Test-Path -LiteralPath $lessonDownloader -PathType Leaf)) {
    throw "The lesson downloader is missing: $lessonDownloader"
}

$courseMatch = [regex]::Match($CourseUrl, '^(?<base>https://[^/]+/student/course/[^/]+/[^/?#]+)')
if (-not $courseMatch.Success) {
    throw 'Could not determine the LearningSuite course root URL.'
}
$courseBaseUrl = $courseMatch.Groups['base'].Value
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ChromeProfilePath -Force | Out-Null

$script:CdpId = 0
$socket = $null

try {
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
            $CourseUrl
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
        Write-Host '  2. Make sure your course access is working.'
        Write-Host '  3. Leave this Chrome window open until the course finishes.'
        [void](Read-Host 'Then return here and press Enter once')
    }

    $target = $null
    $targetCandidates = @(Get-DevToolsTargets -Port $DebugPort)
    if ($targetCandidates.Count -eq 1 -and $targetCandidates[0] -is [array]) {
        $targetCandidates = @($targetCandidates[0])
    }
    foreach ($candidate in $targetCandidates) {
        if (
            $candidate.type -eq 'page' -and
            $candidate.webSocketDebuggerUrl -and
            $candidate.url -match 'learningsuite\.io'
        ) {
            $target = $candidate
            break
        }
    }
    if (-not $target) {
        throw 'No LearningSuite tab was found in the downloader Chrome window.'
    }

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.Options.SetRequestHeader('Origin', "http://127.0.0.1:$DebugPort")
    [void]($socket.ConnectAsync(
        [Uri]$target.webSocketDebuggerUrl,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult())
    [void](Send-CdpCommand -Socket $socket -Method 'Page.enable')
    [void](Send-CdpCommand -Socket $socket -Method 'Runtime.enable')

    Write-Host 'Discovering course modules...' -ForegroundColor Cyan
    [void](Open-CdpPage -Socket $socket -Url $CourseUrl -UrlPattern '/student/course/')

    $courseTitle = 'LearningSuite Course'

    $modules = New-Object Collections.ArrayList
    if ($CourseUrl -match '/t/[^/?#]+') {
        [void]$modules.Add([pscustomobject]@{ Title = 'Course module'; Url = $CourseUrl })
    }
    else {
        $moduleTitles = @()
        $moduleDeadline = (Get-Date).AddSeconds(60)
        do {
            $moduleTitles = @(Invoke-CdpExpression -Socket $socket -Expression @'
(() => Array.from(document.querySelectorAll('.MuiCard-root'))
  .filter(card => {
    const text = card.innerText || '';
    return /\d+\s+(Lektion(?:en)?|Lesson(?:s)?)/i.test(text) &&
      !/(Erscheint bald|Coming soon)/i.test(text) &&
      getComputedStyle(card).cursor === 'pointer';
  })
  .map(card => (card.innerText || '').split(/\r?\n/).map(line => line.trim()).find(Boolean) || '')
  .filter((title, index, titles) => title && titles.indexOf(title) === index))()
'@)
            if ($moduleTitles.Count -eq 1 -and $moduleTitles[0] -is [array]) {
                $moduleTitles = @($moduleTitles[0])
            }
            if ($moduleTitles.Count -eq 0) {
                Start-Sleep -Seconds 1
            }
        } while ($moduleTitles.Count -eq 0 -and (Get-Date) -lt $moduleDeadline)

        foreach ($moduleTitle in $moduleTitles) {
            [void](Open-CdpPage -Socket $socket -Url $courseBaseUrl -UrlPattern ([regex]::Escape($courseBaseUrl) + '/?$'))
            $titleJson = ConvertTo-JavaScriptString -Value ([string]$moduleTitle)
            $clickResult = $false
            $clickDeadline = (Get-Date).AddSeconds(60)
            do {
                $clickResult = Invoke-CdpExpression -Socket $socket -Expression @"
(() => {
  const wanted = $titleJson;
  const card = Array.from(document.querySelectorAll('.MuiCard-root')).find(candidate => {
    const title = (candidate.innerText || '').split(/\r?\n/).map(line => line.trim()).find(Boolean) || '';
    return title === wanted &&
      /\d+\s+(Lektion(?:en)?|Lesson(?:s)?)/i.test(candidate.innerText || '') &&
      !/(Erscheint bald|Coming soon)/i.test(candidate.innerText || '');
  });
  if (!card) return false;
  card.scrollIntoView({ block: 'center' });
  card.click();
  return true;
})()
"@
                if (-not $clickResult) {
                    Start-Sleep -Seconds 1
                }
            } while (-not $clickResult -and (Get-Date) -lt $clickDeadline)
            if (-not $clickResult) {
                throw "Could not open module: $moduleTitle"
            }

            $modulePage = Wait-ForPage -Socket $socket -UrlPattern '/t/[^/?#]+' -TimeoutSeconds 45
            [void]$modules.Add([pscustomobject]@{ Title = [string]$moduleTitle; Url = [string]$modulePage.url })
        }
    }

    [void](Open-CdpPage -Socket $socket -Url $courseBaseUrl -UrlPattern ([regex]::Escape($courseBaseUrl) + '/?$'))
    Start-Sleep -Seconds 2
    $courseTitle = [string](Invoke-CdpExpression -Socket $socket -Expression @'
(() => {
  const headings = Array.from(document.querySelectorAll('h1,h2,h3')).map(e => (e.innerText || '').trim()).filter(Boolean);
  return headings.find(text => !/^\d+%$/.test(text)) || document.title || 'LearningSuite Course';
})()
'@)

    if ($modules.Count -eq 0) {
        throw 'No downloadable modules were found on this course page.'
    }

    Write-Host "Found $($modules.Count) module(s)." -ForegroundColor Green
    $rows = New-Object Collections.ArrayList
    $lessonQueue = New-Object Collections.ArrayList
    $moduleNumber = 0

    foreach ($module in $modules) {
        $moduleNumber++
        [void](Open-CdpPage -Socket $socket -Url $module.Url -UrlPattern '/t/[^/?#]+')
        $courseBaseJson = ConvertTo-JavaScriptString -Value $courseBaseUrl
        $lessonData = @()
        $lessonDeadline = (Get-Date).AddSeconds(60)
        do {
            $lessonData = @(Invoke-CdpExpression -Socket $socket -Expression @"
(() => {
  const courseBase = $courseBaseJson;
  const basePath = new URL(courseBase).pathname.replace(/\/$/, '');
  let section = 'Section 1';
  const found = [];
  const seen = new Set();
  for (const node of document.querySelectorAll('h6,a[href]')) {
    if (node.tagName === 'H6') {
      const value = (node.innerText || '').trim();
      if (/^(Sektion|Section)\s+\d+/i.test(value)) section = value;
      continue;
    }
    const url = new URL(node.href, location.href);
    const normalizedPath = url.pathname.replace(/\/$/, '');
    const tail = normalizedPath.startsWith(basePath + '/') ? normalizedPath.slice(basePath.length + 1) : '';
    if (url.origin !== location.origin || !tail || tail.includes('/') || seen.has(url.href)) continue;
    const title = (node.querySelector('h6')?.innerText || '').trim();
    if (!title) continue;
    seen.add(url.href);
    const body = (node.innerText || '').replace(/\s+/g, ' ').trim();
    const duration = body.match(/(\d+)\s*(Minuten|Minutes)/i);
    found.push({ title, url: url.href, section, duration: duration ? duration[1] + ' min' : '' });
  }
  return found;
})()
"@)
            if ($lessonData.Count -eq 1 -and $lessonData[0] -is [array]) {
                $lessonData = @($lessonData[0])
            }
            if ($lessonData.Count -eq 0) {
                Start-Sleep -Seconds 1
            }
        } while ($lessonData.Count -eq 0 -and (Get-Date) -lt $lessonDeadline)

        $lessonNumber = 0
        foreach ($lesson in $lessonData) {
            $lessonNumber++
            [void]$lessonQueue.Add([pscustomobject]@{
                ModuleNumber = $moduleNumber
                Module       = [string]$module.Title
                Section      = [string]$lesson.section
                LessonNumber = $lessonNumber
                Lesson       = [string]$lesson.title
                Duration     = [string]$lesson.duration
                Url          = [string]$lesson.url
            })
        }
    }

    if ($lessonQueue.Count -eq 0) {
        throw 'No lesson links were discovered inside the course modules.'
    }

    $totalDiscoveredLessons = $lessonQueue.Count
    Write-Host "Found $totalDiscoveredLessons lesson(s)." -ForegroundColor Green

    if ($StructureOnly) {
        $usedPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $structureRows = New-Object Collections.ArrayList

        foreach ($lesson in $lessonQueue) {
            $moduleName = ConvertTo-SafeFileName -Name ([string]$lesson.Module)
            $lessonName = ConvertTo-SafeFileName -Name ([string]$lesson.Lesson)
            $candidateName = $lessonName
            $collisionNumber = 1
            $relativePath = Join-Path $moduleName ($candidateName + '.mp4')
            while (-not $usedPaths.Add($relativePath)) {
                $collisionNumber++
                $candidateName = '{0} ({1})' -f $lessonName, $collisionNumber
                $relativePath = Join-Path $moduleName ($candidateName + '.mp4')
            }

            New-Item -ItemType Directory -Path (Join-Path $OutputRoot $moduleName) -Force | Out-Null
            [void]$structureRows.Add([pscustomobject][ordered]@{
                Course       = $courseTitle
                CourseUrl    = $courseBaseUrl
                ModuleNumber = $lesson.ModuleNumber
                Module       = $lesson.Module
                Section      = $lesson.Section
                LessonNumber = $lesson.LessonNumber
                Lesson       = $lesson.Lesson
                Duration     = $lesson.Duration
                Url          = $lesson.Url
                RelativePath = $relativePath
                ExpectedVideo = -not ([string]$lesson.Duration -match '^0\s+min$')
            })
        }

        $structureCsv = Join-Path $OutputRoot 'course-structure.csv'
        $structureJson = Join-Path $OutputRoot 'course-structure.json'
        @($structureRows) | Export-Csv -LiteralPath $structureCsv -NoTypeInformation -Encoding UTF8
        @($structureRows) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $structureJson -Encoding UTF8

        Write-Host ''
        Write-Host 'Course folder structure created.' -ForegroundColor Green
        Write-Host "Folder:   $OutputRoot"
        Write-Host "Manifest: $structureCsv"
        return
    }

    if ($WorkerCount -gt 1) {
        $workerQueue = New-Object Collections.ArrayList
        for ($queueIndex = 0; $queueIndex -lt $lessonQueue.Count; $queueIndex++) {
            if (($queueIndex % $WorkerCount) -eq $WorkerIndex) {
                [void]$workerQueue.Add($lessonQueue[$queueIndex])
            }
        }
        $lessonQueue = $workerQueue
        Write-Host ("Worker {0}/{1} owns {2} lesson(s)." -f ($WorkerIndex + 1), $WorkerCount, $lessonQueue.Count) -ForegroundColor Green
    }

    if ($ListOnly) {
        $lessonQueue |
            Select-Object ModuleNumber, Module, Section, LessonNumber, Lesson, Duration, Url |
            Format-Table -AutoSize
        Write-Host 'Discovery-only run completed; no media was downloaded.' -ForegroundColor Green
        return
    }

    Write-Host 'Starting resumable download...' -ForegroundColor Green

    foreach ($lesson in $lessonQueue) {
        $moduleName = ConvertTo-SafeFileName -Name $lesson.Module
        $sectionName = ConvertTo-SafeFileName -Name $lesson.Section
        $lessonName = ConvertTo-SafeFileName -Name $lesson.Lesson
        $moduleDirectory = Join-Path $OutputRoot ("{0:00} - {1}" -f [int]$lesson.ModuleNumber, $moduleName)
        $sectionDirectory = Join-Path $moduleDirectory $sectionName
        $lessonDirectory = Join-Path $sectionDirectory ("{0:00} - {1}" -f [int]$lesson.LessonNumber, $lessonName)
        $attachmentDirectory = Join-Path $lessonDirectory 'attachments'
        $videoPath = Join-Path $lessonDirectory 'video.mp4'
        $notesPath = Join-Path $lessonDirectory 'lesson-notes.txt'
        $infoPath = Join-Path $lessonDirectory 'lesson-info.txt'
        $attachmentsMarker = Join-Path $attachmentDirectory '.attachments-complete'
        New-Item -ItemType Directory -Path $lessonDirectory -Force | Out-Null

        $row = [pscustomobject][ordered]@{
            ModuleNumber     = $lesson.ModuleNumber
            Module           = $lesson.Module
            Section          = $lesson.Section
            LessonNumber     = $lesson.LessonNumber
            Lesson           = $lesson.Lesson
            Duration         = $lesson.Duration
            Url              = $lesson.Url
            VideoStatus      = 'Pending'
            VideoFile        = $videoPath
            AttachmentsStatus = if ($SkipAttachments) { 'Skipped' } else { 'Pending' }
            AttachmentCount  = 0
            Error            = ''
            UpdatedAt        = (Get-Date).ToString('s')
        }
        [void]$rows.Add($row)

        Write-Host ''
        Write-Host ("[{0:00}/{1:00}] {2}" -f [int]$lesson.LessonNumber, $lessonQueue.Count, $lesson.Lesson) -ForegroundColor Yellow

        try {
            if ($lesson.Duration -match '^0\s+min$') {
                $row.VideoStatus = 'NoVideo'
                $row.VideoFile = ''
                Write-Host '  resource-only lesson; no video expected'
            }
            elseif ((Test-Path -LiteralPath $videoPath -PathType Leaf) -and -not $Force) {
                $row.VideoStatus = 'Existing'
                Write-Host '  video already exists; skipped'
            }
            else {
                $downloadArguments = @{
                    PageUrl          = $lesson.Url
                    OutputPath       = $videoPath
                    ChromePath       = $ChromePath
                    ChromeProfilePath = $ChromeProfilePath
                    DebugPort        = $DebugPort
                    SeekWaitSeconds  = $SeekWaitSeconds
                    Automatic        = $true
                }
                if ($FfmpegPath) { $downloadArguments.FfmpegPath = $FfmpegPath }
                if ($FfprobePath) { $downloadArguments.FfprobePath = $FfprobePath }
                if ($Force) { $downloadArguments.Force = $true }
                & $lessonDownloader @downloadArguments
                $row.VideoStatus = 'Downloaded'
            }

            [void](Open-CdpPage -Socket $socket -Url $lesson.Url -UrlPattern ([regex]::Escape(([Uri]$lesson.Url).AbsolutePath) + '/?$'))
            Start-Sleep -Seconds 2

            $notes = [string](Invoke-CdpExpression -Socket $socket -Expression @'
(() => {
  const main = document.querySelector('main');
  return (main?.innerText || document.body?.innerText || '').trim();
})()
'@)
            $notes | Set-Content -LiteralPath $notesPath -Encoding UTF8

            if (-not $SkipAttachments) {
                New-Item -ItemType Directory -Path $attachmentDirectory -Force | Out-Null
                if ((Test-Path -LiteralPath $attachmentsMarker) -and -not $Force) {
                    $row.AttachmentsStatus = 'Existing'
                }
                else {
                    try {
                        [void](Send-CdpCommand -Socket $socket -Method 'Browser.setDownloadBehavior' -Params @{
                            behavior       = 'allow'
                            downloadPath   = $attachmentDirectory
                            eventsEnabled  = $true
                        })
                    }
                    catch {
                        [void](Send-CdpCommand -Socket $socket -Method 'Page.setDownloadBehavior' -Params @{
                            behavior     = 'allow'
                            downloadPath = $attachmentDirectory
                        })
                    }

                    $attachmentNames = @(Invoke-CdpExpression -Socket $socket -Expression @'
(() => Array.from(document.querySelectorAll('[data-slate-void="true"]'))
  .filter(card => /Download\s*:/i.test(card.innerText || ''))
  .map(card => {
    const name = Array.from(card.querySelectorAll('p')).map(p => (p.innerText || '').trim()).find(Boolean);
    return name || 'attachment';
  }))()
'@)

                    for ($attachmentIndex = 0; $attachmentIndex -lt $attachmentNames.Count; $attachmentIndex++) {
                        $beforeCount = Get-DownloadedFileCount -Directory $attachmentDirectory
                        $clickIndex = $attachmentIndex.ToString([Globalization.CultureInfo]::InvariantCulture)
                        $clicked = Invoke-CdpExpression -Socket $socket -Expression @"
(() => {
  const cards = Array.from(document.querySelectorAll('[data-slate-void="true"]'))
    .filter(card => /Download\s*:/i.test(card.innerText || ''));
  const card = cards[$clickIndex];
  if (!card) return false;
  const control = Array.from(card.querySelectorAll('*')).find(e => getComputedStyle(e).cursor === 'pointer');
  (control || card).click();
  return true;
})()
"@
                        if (-not $clicked) {
                            throw "Could not click attachment $($attachmentIndex + 1)."
                        }

                        $downloadDeadline = (Get-Date).AddMinutes(5)
                        do {
                            Start-Sleep -Seconds 1
                            [void](Invoke-CdpExpression -Socket $socket -Expression '1')
                            $partialFiles = @(Get-ChildItem -LiteralPath $attachmentDirectory -Filter '*.crdownload' -File -ErrorAction SilentlyContinue)
                            $afterCount = Get-DownloadedFileCount -Directory $attachmentDirectory
                        } while (($afterCount -le $beforeCount -or $partialFiles.Count -gt 0) -and (Get-Date) -lt $downloadDeadline)

                        if ($afterCount -le $beforeCount) {
                            throw "Attachment timed out: $($attachmentNames[$attachmentIndex])"
                        }
                    }

                    Set-Content -LiteralPath $attachmentsMarker -Value (Get-Date).ToString('s') -Encoding ASCII
                    $row.AttachmentsStatus = 'Downloaded'
                }
                $row.AttachmentCount = Get-DownloadedFileCount -Directory $attachmentDirectory
            }
        }
        catch {
            if ($row.VideoStatus -eq 'Pending') {
                $row.VideoStatus = 'Failed'
            }
            if ($row.AttachmentsStatus -eq 'Pending') {
                $row.AttachmentsStatus = 'Failed'
            }
            $row.Error = $_.Exception.Message
            Write-Warning $row.Error
        }

        $row.UpdatedAt = (Get-Date).ToString('s')
        @(
            "Title:       $($lesson.Lesson)",
            "Module:      $($lesson.Module)",
            "Section:     $($lesson.Section)",
            "Duration:    $($lesson.Duration)",
            "URL:         $($lesson.Url)",
            "Video:       $($row.VideoStatus)",
            "Attachments: $($row.AttachmentsStatus) ($($row.AttachmentCount))",
            "Updated:     $($row.UpdatedAt)",
            "Error:       $($row.Error)"
        ) | Set-Content -LiteralPath $infoPath -Encoding UTF8
        Write-CourseManifest -Rows $rows -Root $OutputRoot -Title $courseTitle -Url $courseBaseUrl -Suffix $ManifestSuffix
    }

    Write-Host ''
    Write-Host 'Course download pass completed.' -ForegroundColor Green
    Write-Host "Folder:   $OutputRoot"
    Write-Host "Manifest: $(Join-Path $OutputRoot ("course-manifest$ManifestSuffix.csv"))"
    Write-Host "Summary:  $(Join-Path $OutputRoot ("README$ManifestSuffix.txt"))"
}
finally {
    if ($socket) {
        try {
            if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
                [void]($socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'Finished',
                    [Threading.CancellationToken]::None
                ).GetAwaiter().GetResult())
            }
        }
        catch {
            # Chrome may already have closed the connection.
        }
        $socket.Dispose()
    }
}
