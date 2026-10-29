param(
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [Parameter(Mandatory = $true)][string]$PreviousMsiPath
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'Installer qualification must run on a disposable GitHub Actions Windows runner.'
}
$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir
$Tools = Join-Path $RootDir '.tmp\toolchains'
$Logs = Join-Path $RootDir 'dist\windows-verification'
New-Item -ItemType Directory -Force $Logs | Out-Null
$env:JAVA_HOME = Join-Path $Tools 'java'
$env:CARGO_HOME = Join-Path $Tools 'cargo'
$env:RUSTUP_HOME = Join-Path $Tools 'rustup'
$env:REQUIRE_ENGINE = '1'
$env:PATH = "$Tools\go\bin;$Tools\cargo\bin;$Tools\java\bin;$env:PATH"
$Results = [System.Collections.Generic.List[object]]::new()
function Invoke-Check {
    param([string]$Name, [string]$Command, [string[]]$CommandArgs)
    & $Command @CommandArgs 2>&1 | Tee-Object -FilePath (Join-Path $Logs "$Name.log")
    $Code = $LASTEXITCODE
    $Results.Add(@{name=$Name;exitCode=$Code})
    $Results | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Logs 'checks.json')
    if ($Code -ne 0) { throw "$Name failed with exit code $Code" }
}
function Install-Msi {
    param([string]$Path, [string]$Name)
    $Resolved = (Resolve-Path -LiteralPath $Path).Path
    $LogPath = Join-Path $Logs "$Name.log"
    $Process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$Resolved`"", '/qn', '/norestart', '/l*v', "`"$LogPath`"") -WindowStyle Hidden -Wait -PassThru
    if ($Process.ExitCode -notin @(0,3010)) { throw "$Name failed with exit code $($Process.ExitCode)" }
    $Results.Add(@{name=$Name;exitCode=$Process.ExitCode})
}

# This probe makes filesystem regressions mandatory rather than skipping them
# when a runner lacks the privilege required by the Windows symlink fixtures.
$Probe = Join-Path $Logs 'symlink-probe'
New-Item -ItemType SymbolicLink -Path $Probe -Target $RootDir | Out-Null
Push-Location engines\go
try {
    Invoke-Check 'go-vet' 'go.exe' @('vet','./...')
    Invoke-Check 'go-unit' 'go.exe' @('test','-count=1','-json','./...')
} finally { Pop-Location }
Invoke-Check 'rust-unit' 'cargo.exe' @('test','--locked','--release','--target','x86_64-pc-windows-msvc','--manifest-path','engines/rust/Cargo.toml')
Invoke-Check 'java-unit' (Join-Path $RootDir 'apps\flutter_app\android\gradlew.bat') @('-p','engines/java','build','test','--no-daemon')

Install-Msi -Path $PreviousMsiPath -Name 'install-2.3.1'
$Installed = Join-Path $env:ProgramFiles 'Object Data Browser'
$Exe = Join-Path $Installed 's3_browser_crossplat.exe'
if ((Get-Item $Exe).VersionInfo.ProductVersion -notlike '2.3.1*') { throw 'Previous MSI did not install version 2.3.1' }
Install-Msi -Path $MsiPath -Name 'upgrade-2.3.3'
if ((Get-Item $Exe).VersionInfo.ProductVersion -ne '2.3.3+1') { throw 'Upgrade did not install version 2.3.3+1' }
$Staged = Join-Path $RootDir 'apps\flutter_app\build\windows\x64\runner\Release'
$FileCount = 0
foreach ($File in (Get-ChildItem $Staged -File -Recurse)) {
    $Relative = $File.FullName.Substring($Staged.Length).TrimStart('\')
    $InstalledFile = Join-Path $Installed $Relative
    if (-not (Test-Path -LiteralPath $InstalledFile -PathType Leaf)) { throw "Installer omitted $Relative" }
    if ((Get-FileHash -LiteralPath $File.FullName).Hash -ne (Get-FileHash -LiteralPath $InstalledFile).Hash) { throw "Installed file differs: $Relative" }
    $FileCount++
}

# An alternate path without spaces also exercises the portable sidecar layout.
$TestRoot = Join-Path $RootDir '.tmp\installed-under-test'
New-Item -ItemType Junction -Path $TestRoot -Target $Installed | Out-Null
$EngineRoot = Join-Path $TestRoot 'engines'
$Manifest = Get-Content (Join-Path $EngineRoot 'manifest.json') -Raw | ConvertFrom-Json
if ($Manifest.version -ne '2.3.3' -or $Manifest.architecture -ne 'x64') { throw 'Unexpected installed manifest' }
if ((($Manifest.engines.id | Sort-Object) -join ',') -ne 'go,java,python,rust') { throw 'Installed engine set is incomplete' }
foreach ($Engine in $Manifest.engines) {
    foreach ($Required in $Engine.requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $EngineRoot $Required))) { throw "Missing installed engine file: $Required" }
    }
    $Executable = Join-Path $EngineRoot $Engine.executable
    $Arguments = @($Engine.arguments | ForEach-Object { Join-Path (Join-Path $EngineRoot $Engine.workingDirectory) $_ })
    $Payload = @{requestId='release-health';method='health';engineVersion='2.3.3';params=@{}} | ConvertTo-Json -Compress
    $Health = $Payload | & $Executable @Arguments | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object requestId -eq 'release-health'
    if (-not $Health.ok -or $Health.result.version -ne '2.3.3') { throw "Installed $($Engine.id) health/version failed" }
    $env:ENGINE_CMD = (@($Executable) + $Arguments) -join ' '
    Invoke-Check "installed-contract-$($Engine.id)" 'python.exe' @('-m','pytest','tests/contract','-q','-rs',"--junitxml=$Logs\installed-contract-$($Engine.id).xml")
}
@{version='2.3.3+1';architecture='x64';previousVersion='2.3.1';installedFileHashesVerified=$FileCount;checks=$Results;sourceCommit=$env:GITHUB_SHA} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Logs 'package-verification.json')
