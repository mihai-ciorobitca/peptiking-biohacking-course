[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$PageUrl = 'https://biohacking.learningsuite.io/student',

    [string]$OutputPath,

    [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe',

    [string]$ChromeProfilePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ChromeProfile'),

    [string]$FfmpegPath,

    [string]$FfprobePath,

    [ValidateRange(1025, 65535)]
    [int]$DebugPort = 9223,

    [ValidateRange(2, 30)]
    [int]$SeekWaitSeconds = 6,

    [switch]$Force,

    [switch]$Automatic,

    [switch]$KeepTemporaryFiles
)

# Windows PowerShell 5.1 does not load this framework assembly automatically.
Add-Type -AssemblyName System.Net.Http

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Program {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$ExplicitPath,
        [string[]]$FallbackPaths = @()
    )

    if ($ExplicitPath) {
        $resolved = [IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "$Name was not found at: $resolved"
        }
        return $resolved
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($candidate in $FallbackPaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw "$Name is required but was not found. Install FFmpeg or pass -${Name}Path."
}
function Get-DevToolsTargets {
    param([int]$Port)
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 5
}

function Read-CdpMessage {
    param([Parameter(Mandatory)] [System.Net.WebSockets.ClientWebSocket]$Socket)

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

        $json = [Text.Encoding]::UTF8.GetString($memory.ToArray())
        return $json | ConvertFrom-Json
    }
    finally {
        $memory.Dispose()
    }
}

function Register-CdpEvent {
    param($Message)

    if ($Message.PSObject.Properties.Name -notcontains 'method') {
        return
    }

    if ($Message.method -eq 'Network.requestWillBeSent') {
        $url = [string]$Message.params.request.url
        if ($url -match '/(?<name>video(?<index>\d+)\.ts)(?:\?|$)') {
            $script:SegmentUrls[$Matches.name] = $url
        }
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
    $segment = [ArraySegment[byte]]::new($bytes)
    [void]$Socket.SendAsync(
        $segment,
        [Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult()

    while ($true) {
        $message = Read-CdpMessage -Socket $Socket
        Register-CdpEvent -Message $message

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
        $description = $result.exceptionDetails.exception.description
        throw "Page script failed: $description"
    }

    return $result.result.value
}

function Wait-And-DrainNetwork {
    param(
        [Parameter(Mandatory)] [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Seconds
    )

    Start-Sleep -Seconds $Seconds
    [void](Invoke-CdpExpression -Socket $Socket -Expression '1')
}

function Get-SegmentIndex {
    param([Parameter(Mandatory)] [string]$Name)
    if ($Name -notmatch '^video(?<index>\d+)\.ts$') {
        throw "Unexpected segment name: $Name"
    }
    return [int]$Matches.index
}

if ($PageUrl -match '/api/bunny/playlist/') {
    throw 'Pass the LearningSuite lesson page URL, not the protected .m3u8 URL.'
}

if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) {
    throw "Chrome was not found at: $ChromePath"
}

$ffmpegFallbacks = @(
    'C:\ffmpeg\ffmpeg-8.1.1-essentials_build\bin\ffmpeg.exe',
    'C:\ffmpeg\bin\ffmpeg.exe'
)
$ffprobeFallbacks = @(
    'C:\ffmpeg\ffmpeg-8.1.1-essentials_build\bin\ffprobe.exe',
    'C:\ffmpeg\bin\ffprobe.exe'
)
$FfmpegPath = Resolve-Program -Name 'ffmpeg' -ExplicitPath $FfmpegPath -FallbackPaths $ffmpegFallbacks
$FfprobePath = Resolve-Program -Name 'ffprobe' -ExplicitPath $FfprobePath -FallbackPaths $ffprobeFallbacks

if (-not $OutputPath) {
    $downloads = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    $OutputPath = Join-Path $downloads ("learningsuite-{0}.mp4" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "Output already exists: $OutputPath. Pass -Force to overwrite it."
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $ChromeProfilePath -Force | Out-Null

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workingDirectory = Join-Path $tempRoot ("learningsuite-download-{0}" -f [guid]::NewGuid().ToString('N'))
$segmentDirectory = Join-Path $workingDirectory 'segments'
New-Item -ItemType Directory -Path $segmentDirectory -Force | Out-Null

$socket = $null
$httpClient = $null
$script:CdpId = 0
$script:SegmentUrls = [ordered]@{}

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
            $PageUrl
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
        Write-Host 'In the Chrome window:' -ForegroundColor Cyan
        Write-Host '  1. Log in to LearningSuite if needed.'
        Write-Host '  2. Open the exact lesson containing the video.'
        Write-Host '  3. Make sure the video player is visible.'
        [void](Read-Host 'Then return here and press Enter')
    }

    $targets = @(Get-DevToolsTargets -Port $DebugPort)
    if ($targets.Count -eq 1 -and $targets[0] -is [array]) {
        $targets = @($targets[0])
    }
    $target = $null
    foreach ($candidate in $targets) {
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

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.SetRequestHeader('Origin', "http://127.0.0.1:$DebugPort")
    [void]($socket.ConnectAsync(
        [Uri]$target.webSocketDebuggerUrl,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult())

    [void](Send-CdpCommand -Socket $socket -Method 'Network.enable')
    [void](Send-CdpCommand -Socket $socket -Method 'Runtime.enable')

    if ($Automatic) {
        [void](Send-CdpCommand -Socket $socket -Method 'Page.enable')
        [void](Send-CdpCommand -Socket $socket -Method 'Page.navigate' -Params @{ url = $PageUrl })
    }

    $playerStateExpression = @'
(() => {
  const host = document.querySelector('hls-video');
  const video = host?.shadowRoot?.querySelector('video');
  if (!host || !video) return { ready: false, page: location.href };
  return {
    ready: true,
    page: location.href,
    source: host.getAttribute('src'),
    duration: Number.isFinite(video.duration) ? video.duration : 0
  };
})()
'@

    $player = $null
    $playerDeadline = (Get-Date).AddSeconds(45)
    do {
        $player = Invoke-CdpExpression -Socket $socket -Expression $playerStateExpression
        if ($player.ready -and $player.duration -gt 0) {
            break
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $playerDeadline)

    if (-not $player.ready -or $player.duration -le 0) {
        throw 'The active LearningSuite lesson does not have a ready HLS video player.'
    }

    $videoId = 'video'
    if ([string]$player.source -match '/course/(?<id>[0-9a-f-]{36})/') {
        $videoId = $Matches.id.Substring(0, 8)
    }

    Write-Host "Capturing signed stream segments for $([Math]::Round([double]$player.duration, 1)) seconds of video..." -ForegroundColor Cyan

    $duration = [double]$player.duration
    $seekPoints = [Collections.Generic.List[double]]::new()
    $position = 0.05
    while ($position -lt ($duration - 1)) {
        $seekPoints.Add($position)
        $position += 90
    }
    if ($seekPoints.Count -eq 0 -or $seekPoints[$seekPoints.Count - 1] -lt ($duration - 8)) {
        $seekPoints.Add([Math]::Max(0.05, $duration - 2))
    }

    foreach ($seekPoint in $seekPoints) {
        $seconds = [Math]::Round($seekPoint, 3).ToString([Globalization.CultureInfo]::InvariantCulture)
        $seekExpression = @"
(() => {
  const host = document.querySelector('hls-video');
  const video = host?.shadowRoot?.querySelector('video');
  if (!video) return false;
  video.muted = true;
  video.currentTime = $seconds;
  video.play().catch(() => {});
  return true;
})()
"@
        [void](Invoke-CdpExpression -Socket $socket -Expression $seekExpression)
        Wait-And-DrainNetwork -Socket $socket -Seconds $SeekWaitSeconds
        Write-Host ("  captured {0} segment URLs" -f $script:SegmentUrls.Count)
    }

    # Pause the player after capture.
    [void](Invoke-CdpExpression -Socket $socket -Expression @'
(() => {
  const video = document.querySelector('hls-video')?.shadowRoot?.querySelector('video');
  video?.pause();
  return true;
})()
'@)

    if ($script:SegmentUrls.Count -eq 0) {
        throw 'No signed .ts segment requests were captured.'
    }

    for ($repairRound = 1; $repairRound -le 5; $repairRound++) {
        $indices = @($script:SegmentUrls.Keys | ForEach-Object { Get-SegmentIndex -Name $_ } | Sort-Object)
        $highestIndex = $indices[-1]
        $missing = @(0..$highestIndex | Where-Object { $_ -notin $indices })
        if ($missing.Count -eq 0) {
            break
        }

        Write-Host "Recovering $($missing.Count) missing segment(s)..." -ForegroundColor Yellow
        $estimatedSegmentLength = $duration / ($highestIndex + 1)
        foreach ($missingIndex in $missing) {
            $repairPosition = [Math]::Min(
                $duration - 0.25,
                [Math]::Max(0.05, ($missingIndex + 0.15) * $estimatedSegmentLength)
            )
            $seconds = [Math]::Round($repairPosition, 3).ToString([Globalization.CultureInfo]::InvariantCulture)
            $repairExpression = @"
(() => {
  const video = document.querySelector('hls-video')?.shadowRoot?.querySelector('video');
  if (!video) return false;
  video.muted = true;
  video.currentTime = $seconds;
  video.play().catch(() => {});
  return true;
})()
"@
            [void](Invoke-CdpExpression -Socket $socket -Expression $repairExpression)
            Wait-And-DrainNetwork -Socket $socket -Seconds ([Math]::Max(2, [Math]::Floor($SeekWaitSeconds / 2)))
        }
    }

    [void](Invoke-CdpExpression -Socket $socket -Expression @'
(() => {
  const video = document.querySelector('hls-video')?.shadowRoot?.querySelector('video');
  video?.pause();
  return true;
})()
'@)

    $segments = @(
        $script:SegmentUrls.GetEnumerator() |
            ForEach-Object {
                [PSCustomObject]@{
                    Name  = $_.Key
                    Index = Get-SegmentIndex -Name $_.Key
                    Url   = $_.Value
                }
            } |
            Sort-Object Index
    )

    $highest = $segments[-1].Index
    $missingFinal = @(0..$highest | Where-Object { $_ -notin $segments.Index })
    if ($missingFinal.Count -gt 0) {
        throw "The capture is incomplete. Missing segment indexes: $($missingFinal -join ', ')"
    }

    Write-Host "Downloading $($segments.Count) video segments..." -ForegroundColor Cyan
    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.Timeout = [TimeSpan]::FromMinutes(2)

    for ($i = 0; $i -lt $segments.Count; $i++) {
        $segment = $segments[$i]
        $destination = Join-Path $segmentDirectory $segment.Name
        $downloaded = $false

        for ($attempt = 1; $attempt -le 5 -and -not $downloaded; $attempt++) {
            try {
                $response = $httpClient.GetAsync(
                    $segment.Url,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()
                [void]$response.EnsureSuccessStatusCode()

                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.File]::Open(
                    $destination,
                    [IO.FileMode]::Create,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )
                try {
                    $inputStream.CopyTo($outputStream)
                }
                finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                    $response.Dispose()
                }

                $downloaded = (Get-Item -LiteralPath $destination).Length -gt 0
            }
            catch {
                if ($attempt -eq 5) {
                    throw "Failed to download $($segment.Name): $($_.Exception.Message)"
                }
                Start-Sleep -Seconds $attempt
            }
        }

        if ((($i + 1) % 10) -eq 0 -or ($i + 1) -eq $segments.Count) {
            Write-Host ("  downloaded {0}/{1}" -f ($i + 1), $segments.Count)
        }
    }

    $joinedTsPath = Join-Path $workingDirectory 'joined.ts'
    $joinedStream = [IO.File]::Open(
        $joinedTsPath,
        [IO.FileMode]::Create,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        foreach ($segment in $segments) {
            $segmentPath = Join-Path $segmentDirectory $segment.Name
            $inputStream = [IO.File]::OpenRead($segmentPath)
            try {
                $inputStream.CopyTo($joinedStream)
            }
            finally {
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $joinedStream.Dispose()
    }

    if ((Test-Path -LiteralPath $OutputPath) -and $Force) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    Write-Host 'Creating MP4...' -ForegroundColor Cyan
    & $FfmpegPath `
        -hide_banner `
        -loglevel warning `
        -stats `
        -i $joinedTsPath `
        -map '0:v:0' `
        -map '0:a:0' `
        -c copy `
        -bsf:a aac_adtstoasc `
        -movflags +faststart `
        $OutputPath

    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg failed with exit code $LASTEXITCODE."
    }

    $probeJson = & $FfprobePath `
        -v error `
        -show_entries 'format=duration,size:stream=codec_type,codec_name,width,height' `
        -of json `
        $OutputPath

    if ($LASTEXITCODE -ne 0) {
        throw 'FFprobe could not verify the completed MP4.'
    }

    $probe = $probeJson | ConvertFrom-Json
    $videoStream = $probe.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
    $audioStream = $probe.streams | Where-Object codec_type -eq 'audio' | Select-Object -First 1

    Write-Host ''
    Write-Host 'Download completed successfully.' -ForegroundColor Green
    Write-Host "File:       $OutputPath"
    Write-Host "Video ID:   $videoId"
    Write-Host "Resolution: $($videoStream.width)x$($videoStream.height)"
    Write-Host "Codecs:     $($videoStream.codec_name) + $($audioStream.codec_name)"
    Write-Host "Duration:   $([Math]::Round([double]$probe.format.duration, 2)) seconds"
    Write-Host "Size:       $([Math]::Round([double]$probe.format.size / 1MB, 2)) MiB"
}
finally {
    if ($httpClient) {
        $httpClient.Dispose()
    }

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
            # The browser may already have closed the connection.
        }
        $socket.Dispose()
    }

    if (-not $KeepTemporaryFiles -and (Test-Path -LiteralPath $workingDirectory)) {
        $resolvedWorkingDirectory = [IO.Path]::GetFullPath($workingDirectory)
        $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
        $expectedPrefix = $resolvedTempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $leafName = [IO.Path]::GetFileName($resolvedWorkingDirectory)

        if (
            $resolvedWorkingDirectory.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            $leafName.StartsWith('learningsuite-download-', [StringComparison]::Ordinal)
        ) {
            Remove-Item -LiteralPath $resolvedWorkingDirectory -Recurse -Force
        }
    }
}
