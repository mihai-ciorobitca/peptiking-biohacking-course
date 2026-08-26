[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$CourseUrl,

    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Biohacking'),

    [string]$CourseName,

    [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe',

    [string]$ChromeProfilePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LearningSuiteDownloader\ChromeProfile'),

    [ValidateRange(1025, 65535)]
    [int]$DebugPort = 9223,

    [switch]$Automatic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SafeFolderName {
    param([Parameter(Mandatory)] [string]$Name)

    $safe = $Name.Trim()
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$character, '-')
    }
    $safe = ($safe -replace '\s+', ' ').Trim().TrimEnd('.')
    if (-not $safe) {
        throw 'The course folder name is empty after removing invalid filename characters.'
    }
    return $safe
}

if ($CourseUrl -match '^\s*\[' -or $CourseUrl -match '\]\(https?://') {
    throw 'Use the plain LearningSuite course URL without Markdown brackets.'
}

$courseMatch = [regex]::Match($CourseUrl, '^(?<base>https://[^/]+/student/course/(?<slug>[^/]+)/[^/?#]+)')
if (-not $courseMatch.Success) {
    throw 'Pass a LearningSuite course overview or module URL.'
}
$courseBaseUrl = $courseMatch.Groups['base'].Value
$courseSlug = $courseMatch.Groups['slug'].Value

if (-not $CourseName) {
    $knownNames = @{
        'mini-masterclass-peptide' = 'Mini-Masterclass Peptide'
        'biohacking-essentials'    = 'Biohacking - Essentials'
        'biohacking-praxis'        = 'Biohacking Praxis'
        'biohacking-bibliothek'    = 'Biohacking Bibliothek'
    }
    if ($knownNames.ContainsKey($courseSlug)) {
        $CourseName = $knownNames[$courseSlug]
    }
    else {
        $CourseName = $courseSlug -replace '-', ' '
    }
}

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$courseFolderName = ConvertTo-SafeFolderName -Name $CourseName
$courseRoot = Join-Path $OutputRoot $courseFolderName
New-Item -ItemType Directory -Path $courseRoot -Force | Out-Null

$discoveryScript = Join-Path $PSScriptRoot 'download-learningsuite-course.ps1'
if (-not (Test-Path -LiteralPath $discoveryScript -PathType Leaf)) {
    throw "The course discovery helper is missing: $discoveryScript"
}

$arguments = @{
    CourseUrl         = $courseBaseUrl
    OutputRoot        = $courseRoot
    ChromePath        = $ChromePath
    ChromeProfilePath = $ChromeProfilePath
    DebugPort         = $DebugPort
    StructureOnly     = $true
}
if ($Automatic) {
    $arguments.Automatic = $true
}

& $discoveryScript @arguments

Write-Host ''
Write-Host "Next: run 2-download-missing-videos.ps1 for this folder:" -ForegroundColor Cyan
Write-Host $courseRoot
