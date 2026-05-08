param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

function Get-AppVersion {
    $PubspecPath = Join-Path $RootDir "apps\flutter_app\pubspec.yaml"
    $Version = "2.0.10"
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

$ExcludePattern = '\\\.tmp\\|\\dist\\|\\apps\\flutter_app\\build\\|\\apps\\flutter_app\\\.dart_tool\\|\\apps\\flutter_app\\android\\\.gradle\\|\\engines\\rust\\target\\|\\engines\\go\\bin\\|\\engines\\java\\target\\|\\apps\\flutter_app\\\.idea\\'
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

Compress-Archive -Force -DestinationPath $OutputPath -LiteralPath $Items.FullName
Write-Output $OutputPath
