param(
    [ValidateSet("flutter", "python", "go", "java", "rust", "wix", "android", "all")]
    [string[]]$Components = @("all"),
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [switch]$Help
)

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ToolCacheDir = Join-Path $RootDir ".tmp\toolchains"
New-Item -ItemType Directory -Force -Path $ToolCacheDir | Out-Null

function Get-WindowsSystemPath {
    $SystemRoot = if ($env:SystemRoot) { $env:SystemRoot } else { "C:\Windows" }
    return @(
        (Join-Path $SystemRoot "System32"),
        $SystemRoot
    ) -join ";"
}

if ($Help) {
    Write-Host "Usage:"
    Write-Host "  .\scripts\bootstrap.ps1"
    Write-Host "  .\scripts\bootstrap.ps1 -Components flutter"
    Write-Host "  .\scripts\bootstrap.ps1 -Components flutter,python,java"
    Write-Host "  .\scripts\bootstrap.ps1 -Components flutter,python,go,java,rust,wix"
    Write-Host "  .\scripts\bootstrap.ps1 -Components flutter,java,android"
    Write-Host "  .\scripts\bootstrap.ps1 -Components all -Arch arm64"
    exit 0
}

function Use-Component {
    param([string]$Name)

    return $Components -contains "all" -or $Components -contains $Name
}

function Resolve-ToolsDir {
    param(
        [string]$TargetPath
    )

    $ResolvedTarget = (Resolve-Path $TargetPath).Path
    try {
        $SubstOutput = & subst.exe 2>$null
        foreach ($Line in $SubstOutput) {
            if ($Line -match '^([A-Z]:)\\: => (.+)$') {
                $MappedPath = $matches[2].Trim()
                if ($MappedPath -eq $ResolvedTarget) {
                    return "$($matches[1])\."
                }
            }
        }

        foreach ($Letter in @('S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
            $DriveName = "${Letter}:"
            if (-not (Get-PSDrive -Name $Letter -ErrorAction SilentlyContinue)) {
                & subst.exe $DriveName $ResolvedTarget | Out-Null
                return "$DriveName\."
            }
        }
    } catch {
        return $ResolvedTarget
    }

    return $ResolvedTarget
}

function Invoke-WebRequestCompat {
    param(
        [string]$Uri,
        [string]$OutFile
    )

    $Parameters = @{
        Uri = $Uri
    }
    if ($OutFile) {
        $Parameters.OutFile = $OutFile
    }

    $Command = Get-Command Invoke-WebRequest -ErrorAction Stop
    if ($Command.Parameters.ContainsKey("UseBasicParsing")) {
        $Parameters.UseBasicParsing = $true
    }

    return Invoke-WebRequest @Parameters
}

$ToolsDir = Resolve-ToolsDir -TargetPath $ToolCacheDir
$env:PATH = "$(Get-WindowsSystemPath);$env:PATH"

function Download-File {
    param(
        [string]$Url,
        [string]$Target
    )

    if (-not (Test-Path $Target)) {
        Write-Host "Downloading $Url"
        $Parent = Split-Path -Parent $Target
        if ($Parent) {
            New-Item -ItemType Directory -Force -Path $Parent | Out-Null
        }
        $Bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
        if ($null -ne $Bits) {
            try {
                Start-BitsTransfer -Source $Url -Destination $Target
                return
            } catch {
                if (Test-Path $Target) {
                    Remove-Item -Force $Target -ErrorAction SilentlyContinue
                }
                Write-Host "BITS download failed, falling back to Invoke-WebRequest."
            }
        }
        Invoke-WebRequestCompat -Uri $Url -OutFile $Target | Out-Null
    }
}

function Remove-DirectoryIfExists {
    param(
        [string]$Path
    )

    if (Test-Path $Path) {
        $null = & cmd.exe /c "rmdir /s /q `"$Path`""
        if (Test-Path $Path) {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Path
        }
    }
}

function Expand-ZipToStaging {
    param(
        [string]$Archive,
        [string]$StageName
    )

    $StageDrive = [System.IO.Path]::GetPathRoot($(if ($env:SystemRoot) { $env:SystemRoot } else { "C:\Windows" }))
    $StageRoot = Join-Path $StageDrive "_s3b"
    New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null
    $StageDir = Join-Path $StageRoot $StageName
    Remove-DirectoryIfExists $StageDir
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $StageDir)
    return $StageDir
}

function Ensure-Flutter {
    $Dir = Join-Path $ToolsDir "flutter"
    $FlutterBat = Join-Path $Dir "bin\flutter.bat"
    $GitDir = Join-Path $Dir ".git"
    $BundledGit = Join-Path $Dir "bin\mingit\cmd\git.exe"
    $NeedsArchiveInstall = (-not (Test-Path $FlutterBat)) -or (-not (Test-Path $GitDir)) -or (-not (Test-Path $BundledGit))

    if ($NeedsArchiveInstall) {
        Remove-DirectoryIfExists $Dir

        $ReleaseIndex = Invoke-RestMethod -Uri "https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json"
        $StableHash = $ReleaseIndex.current_release.stable
        $StableRelease = $ReleaseIndex.releases | Where-Object { $_.hash -eq $StableHash } | Select-Object -First 1

        if ($null -eq $StableRelease) {
            throw "Unable to resolve the latest stable Flutter release for Windows."
        }

        $Archive = Join-Path $ToolCacheDir "flutter.zip"
        $Url = "https://storage.googleapis.com/flutter_infra_release/releases/$($StableRelease.archive)"
        Download-File $Url $Archive
        $StageDir = Expand-ZipToStaging -Archive $Archive -StageName "_stage_flutter"
        $ExtractedFlutterDir = Join-Path $StageDir "flutter"
        if (-not (Test-Path $ExtractedFlutterDir)) {
            throw "Flutter archive did not extract to the expected flutter directory."
        }
        Move-Item -Path $ExtractedFlutterDir -Destination $Dir
        Remove-DirectoryIfExists $StageDir
    }
}

function Ensure-Go {
    $GoRoot = Join-Path $ToolsDir "go"
    if (-not (Test-Path (Join-Path $GoRoot "bin\go.exe"))) {
        $Version = (Invoke-WebRequestCompat -Uri "https://go.dev/VERSION?m=text").Content.Split("`n")[0].Trim()
        $Archive = Join-Path $ToolCacheDir "go.zip"
        $GoArch = if ($Arch -eq "arm64") { "arm64" } else { "amd64" }
        Download-File "https://go.dev/dl/$Version.windows-$GoArch.zip" $Archive
        Remove-DirectoryIfExists $GoRoot
        $StageDir = Expand-ZipToStaging -Archive $Archive -StageName "_stage_go"
        $ExtractedGoDir = Join-Path $StageDir "go"
        if (-not (Test-Path $ExtractedGoDir)) {
            throw "Go archive did not extract to the expected go directory."
        }
        Move-Item -Path $ExtractedGoDir -Destination $GoRoot
        Remove-DirectoryIfExists $StageDir
    }
}

function Ensure-Python {
    $PythonRoot = Join-Path $ToolsDir "python-embed"
    if (-not (Test-Path (Join-Path $PythonRoot "python.exe"))) {
        $Version = "3.12.10"
        $Archive = Join-Path $ToolCacheDir "python-embed-$Version.zip"
        $PythonArch = if ($Arch -eq "arm64") { "arm64" } else { "amd64" }
        Download-File "https://www.python.org/ftp/python/$Version/python-$Version-embed-$PythonArch.zip" $Archive
        Remove-DirectoryIfExists $PythonRoot
        New-Item -ItemType Directory -Force -Path $PythonRoot | Out-Null
        $StageDir = Expand-ZipToStaging -Archive $Archive -StageName "_stage_python_embed"
        Get-ChildItem -Path $StageDir | Move-Item -Destination $PythonRoot
        Remove-DirectoryIfExists $StageDir
    }
}

function Ensure-Java {
    $JavaRoot = Join-Path $ToolsDir "java"
    if (-not (Test-Path (Join-Path $JavaRoot "bin\java.exe"))) {
        $Archive = Join-Path $ToolCacheDir "java.zip"
        $JavaArch = if ($Arch -eq "arm64") { "aarch64" } else { "x64" }
        Download-File "https://api.adoptium.net/v3/binary/latest/21/ga/windows/$JavaArch/jdk/hotspot/normal/eclipse" $Archive
        Remove-DirectoryIfExists $JavaRoot
        New-Item -ItemType Directory -Force -Path $JavaRoot | Out-Null
        $StageDir = Expand-ZipToStaging -Archive $Archive -StageName "_stage_java"
        $Nested = Get-ChildItem -Path $StageDir | Select-Object -First 1
        if ($null -eq $Nested) {
            throw "Java archive did not extract to the expected directory layout."
        }
        Get-ChildItem -Path $Nested.FullName | Move-Item -Destination $JavaRoot
        Remove-DirectoryIfExists $StageDir
    }
}

function Ensure-Rust {
    $Cargo = Join-Path $ToolsDir "cargo\bin\cargo.exe"
    if (-not (Test-Path $Cargo)) {
        $Installer = Join-Path $ToolCacheDir "rustup-init.exe"
        $RustArch = if ($Arch -eq "arm64") { "aarch64" } else { "x86_64" }
        Download-File "https://win.rustup.rs/$RustArch" $Installer
        $env:CARGO_HOME = Join-Path $ToolsDir "cargo"
        $env:RUSTUP_HOME = Join-Path $ToolsDir "rustup"
        & $Installer -y --default-toolchain stable --no-modify-path
    }

    if ($Arch -eq "arm64") {
        $env:CARGO_HOME = Join-Path $ToolsDir "cargo"
        $env:RUSTUP_HOME = Join-Path $ToolsDir "rustup"
        & $Cargo target add aarch64-pc-windows-msvc
    }
}

function Ensure-Wix {
    $WixRoot = Join-Path $ToolsDir "wix"
    $WixCli = Join-Path $WixRoot "wix.exe"
    $WixCandle = Join-Path $WixRoot "bin\candle.exe"
    if ((Test-Path $WixCli) -or (Test-Path $WixCandle)) {
        return
    }

    $Archive = Join-Path $ToolCacheDir "wix314-binaries.zip"
    Download-File "https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip" $Archive
    Remove-DirectoryIfExists $WixRoot
    New-Item -ItemType Directory -Force -Path $WixRoot | Out-Null
    $StageDir = Expand-ZipToStaging -Archive $Archive -StageName "_stage_wix"
    Get-ChildItem -Path $StageDir | Move-Item -Destination $WixRoot
    Remove-DirectoryIfExists $StageDir
}

function Ensure-AndroidSdk {
    $AndroidRoot = Join-Path $ToolsDir "android-sdk"
    $CmdlineToolsRoot = Join-Path $AndroidRoot "cmdline-tools"
    $LatestDir = Join-Path $CmdlineToolsRoot "latest"
    $SdkManager = Join-Path $LatestDir "bin\sdkmanager.bat"
    if (-not (Test-Path $SdkManager)) {
        $Archive = Join-Path $ToolCacheDir "commandlinetools-win.zip"
        Download-File "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" $Archive
        Remove-DirectoryIfExists $CmdlineToolsRoot
        New-Item -ItemType Directory -Force -Path $LatestDir | Out-Null
        $StageDir = Expand-ZipToStaging -Archive $Archive -StageName "_stage_android"
        $ExtractedDir = Join-Path $StageDir "cmdline-tools"
        if (-not (Test-Path $ExtractedDir)) {
            throw "Android command-line tools archive did not extract to the expected cmdline-tools directory."
        }
        Get-ChildItem -Path $ExtractedDir | Move-Item -Destination $LatestDir
        Remove-DirectoryIfExists $StageDir
    }

    $env:ANDROID_SDK_ROOT = $AndroidRoot
    $env:ANDROID_HOME = $AndroidRoot
    $env:PATH = "$(Join-Path $LatestDir 'bin');$(Join-Path $AndroidRoot 'platform-tools');$(Get-WindowsSystemPath);$env:PATH"
    if (Test-Path (Join-Path $ToolsDir "java\bin\java.exe")) {
        $env:JAVA_HOME = Join-Path $ToolsDir "java"
        $env:PATH = "$(Join-Path $env:JAVA_HOME 'bin');$env:PATH"
    }

    $LicenseCommand = '(for /l %i in (1,1,40) do @echo y) | "' + $SdkManager + '" --sdk_root="' + $AndroidRoot + '" --licenses >nul'
    $null = & cmd.exe /c $LicenseCommand
    $global:LASTEXITCODE = 0

    foreach ($Package in @(
        "platform-tools",
        "platforms;android-34",
        "platforms;android-35",
        "build-tools;34.0.0",
        "build-tools;35.0.0",
        "ndk;27.0.12077973"
    )) {
        $InstallCommand = '"' + $SdkManager + '" --sdk_root="' + $AndroidRoot + '" "' + $Package + '"'
        $null = & cmd.exe /c $InstallCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Android SDK package install failed: $Package"
        }
    }
}

if (Use-Component "flutter") {
    Ensure-Flutter
}

if (Use-Component "go") {
    Ensure-Go
}

if (Use-Component "python") {
    Ensure-Python
}

if (Use-Component "java") {
    Ensure-Java
}

if (Use-Component "rust") {
    Ensure-Rust
}

if (Use-Component "wix") {
    Ensure-Wix
}

if (Use-Component "android") {
    Ensure-AndroidSdk
}

Write-Host "Bootstrap complete."
Write-Host "Add to PATH for this session:"
Write-Host "$ToolsDir\flutter\bin;$ToolsDir\go\bin;$ToolsDir\java\bin;$ToolsDir\cargo\bin;$ToolsDir\wix;$ToolsDir\wix\bin;$ToolsDir\android-sdk\cmdline-tools\latest\bin;$ToolsDir\android-sdk\platform-tools"
