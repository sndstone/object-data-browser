param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

function Get-AppVersion {
    $PubspecPath = Join-Path $RootDir "apps\flutter_app\pubspec.yaml"
    $Version = "0.0.0"
    if (Test-Path $PubspecPath) {
        $VersionMatch = Select-String -Path $PubspecPath -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
        if ($VersionMatch) {
            $Version = $VersionMatch.Matches[0].Groups[1].Value
        }
    }
    return $Version
}

if (-not $OutputPath) {
    $Version = Get-AppVersion
    $ParentDir = Split-Path -Parent $RootDir
    $OutputPath = Join-Path $ParentDir "object-data-browser-$Version-source.zip"
}

$ExcludePattern = '\\\.agents\\|\\\.claude\\|\\\.codex\\|\\\.gradle\\|\\\.pytest_cache\\|\\\.tmp\\|\\dist\\|__pycache__\\|\\apps\\flutter_app\\build\\|\\apps\\flutter_app\\\.dart_tool\\|\\apps\\flutter_app\\windows\\flutter\\ephemeral\\|\\engines\\rust\\target\\|\\engines\\go\\bin\\|\\engines\\go\\build\\|\\engines\\java\\build\\|\\engines\\java\\target\\|\\apps\\flutter_app\\\.idea\\|\\packaging\\windows\\Product\.generated\.wxs'
$ExcludedNames = @(
    'local.properties',
    '.flutter-plugins-dependencies'
)

$Items = Get-ChildItem $RootDir -Recurse -File | Where-Object {
    $_.FullName -notmatch $ExcludePattern -and
    $_.Name -notin $ExcludedNames
}

if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::Open(
    $OutputPath,
    [System.IO.Compression.ZipArchiveMode]::Create
)
try {
    foreach ($Item in $Items) {
        $RelativePath = $Item.FullName.Substring($RootDir.Length).TrimStart('\', '/')
        $EntryName = $RelativePath.Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Archive,
            $Item.FullName,
            $EntryName,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
} finally {
    $Archive.Dispose()
}
Write-Output $OutputPath
