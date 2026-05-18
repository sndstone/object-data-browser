param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseDir,
    [Parameter(Mandatory = $true)]
    [string]$ToolsDir,
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [switch]$Help
)

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Resolve-FullPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

$ReleaseDir = Resolve-FullPath $ReleaseDir
$ToolsDir = Resolve-FullPath $ToolsDir
$ToolCacheDir = Join-Path $RootDir ".tmp\toolchains"
$EngineSourceDir = Join-Path $RootDir "engines"
$StageRoot = Join-Path $ReleaseDir "engines"

if ($Help) {
    Write-Host "Usage:"
    Write-Host "  .\scripts\stage-engines.ps1 -ReleaseDir <flutter-release-dir> -ToolsDir <tool-dir>"
    exit 0
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

function Download-File {
    param(
        [string]$Url,
        [string]$Target
    )

    if (Test-Path $Target) {
        return
    }

    $Parent = Split-Path -Parent $Target
    if ($Parent) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }

    Write-Host "Downloading $Url"
    Invoke-WebRequestCompat -Uri $Url -OutFile $Target | Out-Null
}

function Remove-DirectoryIfExists {
    param(
        [string]$Path,
        [int]$Attempts = 6
    )

    if (Test-Path $Path) {
        for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
            try {
                Remove-Item -Recurse -Force $Path -ErrorAction Stop
                break
            } catch {
                if ($Attempt -eq $Attempts) {
                    throw
                }
                Start-Sleep -Milliseconds (300 * $Attempt)
            }
        }
    }
}

function Expand-ZipToStaging {
    param(
        [string]$Archive,
        [string]$StageName
    )

    $StageDir = Join-Path $ToolCacheDir $StageName
    Remove-DirectoryIfExists $StageDir
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $StageDir)
    return $StageDir
}

function Copy-DirectoryContent {
    param(
        [string]$SourceDir,
        [string]$DestinationDir
    )

    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
    Get-ChildItem -Path $SourceDir -Force | Copy-Item -Destination $DestinationDir -Recurse -Force
}

function Ensure-EmbeddedPython {
    $PythonRoot = Join-Path $ToolsDir "python-embed"
    $PythonExe = Join-Path $PythonRoot "python.exe"
    if (Test-Path $PythonExe) {
        return $PythonRoot
    }

    $Version = "3.12.10"
    $Archive = Join-Path $ToolCacheDir "python-embed-$Version.zip"
    Download-File "https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip" $Archive
    Remove-DirectoryIfExists $PythonRoot
    $StageDir = Expand-ZipToStaging -Archive $Archive -StageName "_stage_python_embed"
    New-Item -ItemType Directory -Force -Path $PythonRoot | Out-Null
    Get-ChildItem -Path $StageDir | Move-Item -Destination $PythonRoot
    Remove-DirectoryIfExists $StageDir
    return $PythonRoot
}

function Get-PypiWheel {
    param([string]$PackageName)

    $Metadata = Invoke-RestMethod -Uri "https://pypi.org/pypi/$PackageName/json"
    $Version = $Metadata.info.version
    $Wheel = $Metadata.releases.$Version |
        Where-Object {
            $_.packagetype -eq "bdist_wheel" -and $_.filename -like "*none-any.whl"
        } |
        Select-Object -First 1

    if ($null -eq $Wheel) {
        throw "No universal wheel could be resolved for Python package $PackageName."
    }

    return $Wheel
}

function Install-WheelPackage {
    param(
        [string]$PackageName,
        [string]$SitePackagesDir
    )

    $Wheel = Get-PypiWheel -PackageName $PackageName
    $Archive = Join-Path $ToolCacheDir "python-wheels\$($Wheel.filename)"
    Download-File $Wheel.url $Archive
    $StageName = "_wheel_" + ($PackageName -replace '[^A-Za-z0-9_]', '_')
    $StageDir = Expand-ZipToStaging -Archive $Archive -StageName $StageName
    Get-ChildItem -Path $StageDir -Force | Copy-Item -Destination $SitePackagesDir -Recurse -Force
    Remove-DirectoryIfExists $StageDir
}

function Enable-EmbeddedPythonSite {
    param([string]$PythonDir)

    $PthFile = Get-ChildItem -Path $PythonDir -Filter "python*._pth" | Select-Object -First 1
    if ($null -eq $PthFile) {
        throw "Could not find the embedded Python ._pth file in $PythonDir."
    }

    $Current = Get-Content -Path $PthFile.FullName
    $Updated = New-Object System.Collections.Generic.List[string]
    foreach ($Line in $Current) {
        if ([string]::IsNullOrWhiteSpace($Line)) {
            continue
        }
        if ($Line.Trim() -eq "import site") {
            continue
        }
        $Updated.Add($Line)
    }

    foreach ($Extra in @("Lib\site-packages", "engine")) {
        if (-not ($Updated -contains $Extra)) {
            $Updated.Add($Extra)
        }
    }
    $Updated.Add("import site")

    Set-Content -Path $PthFile.FullName -Value $Updated -Encoding ASCII
}

function Get-AppVersion {
    $PubspecPath = Join-Path $RootDir "apps\flutter_app\pubspec.yaml"
    $Version = "2.0.17"
    if (Test-Path $PubspecPath) {
        $VersionMatch = Select-String -Path $PubspecPath -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
        if ($VersionMatch) {
            $Version = $VersionMatch.Matches[0].Groups[1].Value
        }
    }
    return $Version
}

function Assert-RequiredEngineFiles {
    param([object]$Manifest)

    foreach ($Engine in $Manifest.engines) {
        foreach ($RelativeFile in $Engine.requiredFiles) {
            $Resolved = Join-Path $StageRoot $RelativeFile
            if (-not (Test-Path $Resolved)) {
                throw "Required sidecar file for $($Engine.id) was not staged: $Resolved"
            }
        }
    }
}

function Stage-PythonEngine {
    $PythonToolchain = Ensure-EmbeddedPython
    $PythonDest = Join-Path $StageRoot "python"
    Remove-DirectoryIfExists $PythonDest
    Copy-DirectoryContent -SourceDir $PythonToolchain -DestinationDir $PythonDest

    $EngineDest = Join-Path $PythonDest "engine"
    $SitePackagesDir = Join-Path $PythonDest "Lib\site-packages"
    New-Item -ItemType Directory -Force -Path $EngineDest | Out-Null
    New-Item -ItemType Directory -Force -Path $SitePackagesDir | Out-Null

    Copy-Item -Path (Join-Path $EngineSourceDir "python\src\main.py") -Destination (Join-Path $EngineDest "main.py") -Force

    foreach ($Package in @(
        "boto3",
        "botocore",
        "s3transfer",
        "jmespath",
        "python-dateutil",
        "urllib3",
        "six"
    )) {
        Install-WheelPackage -PackageName $Package -SitePackagesDir $SitePackagesDir
    }

    Enable-EmbeddedPythonSite -PythonDir $PythonDest
}

function Stage-GoEngine {
    $GoExe = Join-Path $ToolsDir "go\bin\go.exe"
    if (-not (Test-Path $GoExe)) {
        throw "Go toolchain was not found at $GoExe."
    }

    $GoDest = Join-Path $StageRoot "go"
    $GoBuildDir = Join-Path $EngineSourceDir "go\build\$Arch"
    $GoBinary = Join-Path $GoBuildDir "s3-browser-go-engine.exe"
    $GoArch = if ($Arch -eq "arm64") { "arm64" } else { "amd64" }
    Remove-DirectoryIfExists $GoDest
    Remove-DirectoryIfExists $GoBuildDir
    New-Item -ItemType Directory -Force -Path $GoDest | Out-Null
    New-Item -ItemType Directory -Force -Path $GoBuildDir | Out-Null

    $PreviousGoOs = $env:GOOS
    $PreviousGoArch = $env:GOARCH
    $PreviousCgo = $env:CGO_ENABLED
    Push-Location (Join-Path $EngineSourceDir "go")
    try {
        $env:GOOS = "windows"
        $env:GOARCH = $GoArch
        $env:CGO_ENABLED = "0"
        Write-Host "Building Go engine for windows/$GoArch..."
        $GoProcess = Start-Process `
            -FilePath $GoExe `
            -ArgumentList @(
                "build",
                "-trimpath",
                "`"-ldflags=-s -w`"",
                "-o",
                "`"$GoBinary`"",
                "./src"
            ) `
            -NoNewWindow `
            -PassThru `
            -Wait
        if ($GoProcess.ExitCode -ne 0) {
            throw "Go engine build failed with exit code $($GoProcess.ExitCode)."
        }
    } finally {
        Pop-Location
        if ($null -eq $PreviousGoOs) {
            Remove-Item Env:GOOS -ErrorAction SilentlyContinue
        } else {
            $env:GOOS = $PreviousGoOs
        }
        if ($null -eq $PreviousGoArch) {
            Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
        } else {
            $env:GOARCH = $PreviousGoArch
        }
        if ($null -eq $PreviousCgo) {
            Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
        } else {
            $env:CGO_ENABLED = $PreviousCgo
        }
    }

    if (-not (Test-Path $GoBinary)) {
        $Artifacts = Get-ChildItem -Path (Join-Path $EngineSourceDir "go") -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
        $ArtifactSummary = if ($Artifacts) {
            $Artifacts -join [Environment]::NewLine
        } else {
            "No Go engine executables were found under $(Join-Path $EngineSourceDir 'go')."
        }
        throw "Go engine build did not produce the expected Windows executable at $GoBinary.`n$ArtifactSummary"
    }

    Copy-Item `
        -Path $GoBinary `
        -Destination (Join-Path $GoDest "s3-browser-go-engine.exe") `
        -Force
}

function Stage-RustEngine {
    $CargoExe = Join-Path $ToolsDir "cargo\bin\cargo.exe"
    if (-not (Test-Path $CargoExe)) {
        throw "Rust toolchain was not found at $CargoExe."
    }

    $RustSource = Join-Path $EngineSourceDir "rust"
    $RustDest = Join-Path $StageRoot "rust"
    $RustTargetTriple = if ($Arch -eq "arm64") {
        "aarch64-pc-windows-msvc"
    } else {
        "x86_64-pc-windows-msvc"
    }
    $RustBinary = Join-Path $RustSource "target\$RustTargetTriple\release\s3-browser-rust-engine.exe"
    Remove-DirectoryIfExists $RustDest
    New-Item -ItemType Directory -Force -Path $RustDest | Out-Null

    Push-Location $RustSource
    try {
        Write-Host "Building Rust engine for $RustTargetTriple..."
        $CargoProcess = Start-Process `
            -FilePath $CargoExe `
            -ArgumentList @(
                "build",
                "--release",
                "--target",
                $RustTargetTriple
            ) `
            -NoNewWindow `
            -PassThru `
            -Wait
        if ($CargoProcess.ExitCode -ne 0) {
            throw "Rust engine build failed with exit code $($CargoProcess.ExitCode)."
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $RustBinary)) {
        $FallbackBinary = Join-Path $RustSource "target\release\s3-browser-rust-engine.exe"
        $ArtifactSummary = Get-ChildItem -Path (Join-Path $RustSource "target") -Recurse -Filter "s3-browser-rust-engine*" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
        if (Test-Path $FallbackBinary) {
            $RustBinary = $FallbackBinary
        } else {
            $DiscoveredArtifacts = if ($ArtifactSummary) {
                $ArtifactSummary -join [Environment]::NewLine
            } else {
                "No matching Rust engine artifacts were found under $RustSource\target."
            }
            throw "Rust engine build did not produce the expected Windows executable at $RustBinary.`n$DiscoveredArtifacts"
        }
    }

    New-Item -ItemType Directory -Force -Path $RustDest | Out-Null
    Copy-Item `
        -Path $RustBinary `
        -Destination (Join-Path $RustDest "s3-browser-rust-engine.exe") `
        -Force
}

function Stage-JavaEngine {
    $JavaSource = Join-Path $EngineSourceDir "java"
    $JavaDest = Join-Path $StageRoot "java"
    $GradleWrapper = Join-Path $RootDir "apps\flutter_app\android\gradlew.bat"
    $JavaHome = Join-Path $ToolsDir "java"
    Remove-DirectoryIfExists $JavaDest
    New-Item -ItemType Directory -Force -Path $JavaDest | Out-Null

    if (-not (Test-Path $GradleWrapper)) {
        throw "Gradle wrapper was not found at $GradleWrapper."
    }
    if (-not (Test-Path (Join-Path $JavaHome "bin\java.exe"))) {
        throw "Java runtime was not found at $JavaHome."
    }

    Copy-DirectoryContent -SourceDir (Join-Path $ToolsDir "java") -DestinationDir (Join-Path $JavaDest "runtime")

    $PreviousJavaHome = $env:JAVA_HOME
    $PreviousPath = $env:PATH
    $env:JAVA_HOME = $JavaHome
    $env:PATH = "$(Join-Path $JavaHome 'bin');$env:PATH"
    Push-Location (Join-Path $RootDir "apps\flutter_app\android")
    try {
        $GradleProcess = Start-Process `
            -FilePath $GradleWrapper `
            -ArgumentList @(
                "-p",
                $JavaSource,
                "installDist",
                "--no-daemon"
            ) `
            -NoNewWindow `
            -PassThru `
            -Wait
        if ($GradleProcess.ExitCode -ne 0) {
            throw "Java engine installDist failed with exit code $($GradleProcess.ExitCode)."
        }
    } finally {
        Pop-Location
        if ($null -eq $PreviousJavaHome) {
            Remove-Item Env:JAVA_HOME -ErrorAction SilentlyContinue
        } else {
            $env:JAVA_HOME = $PreviousJavaHome
        }
        $env:PATH = $PreviousPath
    }

    Copy-DirectoryContent `
        -SourceDir (Join-Path $JavaSource "build\install\s3-browser-java-engine\lib") `
        -DestinationDir (Join-Path $JavaDest "lib")

    $LauncherPath = Join-Path $JavaDest "run-java-engine.bat"
    Set-Content -Path $LauncherPath -Encoding ASCII -Value @"
@echo off
setlocal
"%~dp0runtime\bin\java.exe" -cp "%~dp0lib\*" com.example.s3browser.Main %*
"@
}

if (-not (Test-Path $ReleaseDir)) {
    throw "Flutter Windows release directory was not found at $ReleaseDir."
}

Remove-DirectoryIfExists $StageRoot
New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null

Stage-PythonEngine
Stage-GoEngine
Stage-RustEngine
Stage-JavaEngine

$EngineVersion = Get-AppVersion
$Manifest = @{
    version = $EngineVersion
    architecture = $Arch
    generatedAt = (Get-Date).ToString("o")
    engines = @(
        @{
            id = "python"
            version = $EngineVersion
            executable = "python\python.exe"
            arguments = @("engine\main.py")
            workingDirectory = "python"
            requiredFiles = @(
                "python\python.exe",
                "python\engine\main.py"
            )
        },
        @{
            id = "go"
            version = $EngineVersion
            executable = "go\s3-browser-go-engine.exe"
            arguments = @()
            workingDirectory = "go"
            requiredFiles = @(
                "go\s3-browser-go-engine.exe"
            )
        },
        @{
            id = "rust"
            version = $EngineVersion
            executable = "rust\s3-browser-rust-engine.exe"
            arguments = @()
            workingDirectory = "rust"
            requiredFiles = @(
                "rust\s3-browser-rust-engine.exe"
            )
        },
        @{
            id = "java"
            version = $EngineVersion
            executable = "java\run-java-engine.bat"
            arguments = @()
            workingDirectory = "java"
            requiredFiles = @(
                "java\run-java-engine.bat",
                "java\lib",
                "java\runtime\bin\java.exe"
            )
        }
    )
}

Assert-RequiredEngineFiles -Manifest $Manifest
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $StageRoot "manifest.json") -Encoding UTF8
Write-Host "Staged desktop engine sidecars into $StageRoot"
