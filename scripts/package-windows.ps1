param(
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ToolCacheDir = Join-Path $RootDir ".tmp\toolchains"
$FlutterDir = Join-Path $RootDir "apps\flutter_app"
$AppReleaseDir = Join-Path $FlutterDir "build\windows\$Arch\runner\Release"
$EnginesDir = Join-Path $AppReleaseDir "engines"
$EngineManifestPath = Join-Path $EnginesDir "manifest.json"
$GeneratedWxs = Join-Path $RootDir "packaging\windows\Product.generated.wxs"
$ArtifactDir = Join-Path $RootDir "dist\windows"

if ($Help) {
    Write-Host "Usage:"
    Write-Host "  .\scripts\package-windows.ps1"
    exit 0
}

function Resolve-ToolsDir {
    param([string]$TargetPath)

    if (-not (Test-Path $TargetPath)) {
        New-Item -ItemType Directory -Force -Path $TargetPath | Out-Null
    }

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

function New-WixId {
    param(
        [string]$Prefix,
        [string]$Value
    )

    $Sanitized = ($Value -replace '[^A-Za-z0-9_]', '_')
    if ([string]::IsNullOrWhiteSpace($Sanitized)) {
        $Sanitized = "Root"
    }
    if ($Sanitized[0] -match '[0-9]') {
        $Sanitized = "_$Sanitized"
    }
    if ($Sanitized.Length -gt 58) {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Sanitized)
        $Hash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA1]::Create().ComputeHash($Bytes)
        ).Replace("-", "").Substring(0, 10)
        $Sanitized = "{0}_{1}" -f $Sanitized.Substring(0, 47), $Hash
    }
    return "$Prefix$Sanitized"
}

function Escape-Xml {
    param([string]$Value)

    return [System.Security.SecurityElement]::Escape($Value)
}

function Invoke-NativeTool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $Process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    return $Process.ExitCode
}

function Remove-ArtifactIfPresent {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    & cmd.exe /c "attrib -R `"$Path`" >nul 2>&1"
    & cmd.exe /c "del /F /Q `"$Path`" >nul 2>&1"

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force -ErrorAction Stop
    }
}

function Resolve-ArtifactOutputPath {
    param([string]$PreferredPath)

    try {
        Remove-ArtifactIfPresent -Path $PreferredPath
        return $PreferredPath
    } catch {
        $Directory = Split-Path -Parent $PreferredPath
        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($PreferredPath)
        $Extension = [System.IO.Path]::GetExtension($PreferredPath)
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        return Join-Path $Directory "$BaseName-$Timestamp$Extension"
    }
}

if (-not (Test-Path $AppReleaseDir)) {
    throw "Windows build output was not found at $AppReleaseDir. Run .\scripts\build.ps1 -Platform windows -Installer none first, or rerun the full Windows build."
}

if (-not (Test-Path $EnginesDir)) {
    throw "Desktop sidecars were not found at $EnginesDir. Run .\scripts\build.ps1 -Platform windows so the engines folder is staged before packaging."
}

if (-not (Test-Path $EngineManifestPath)) {
    throw "Engine manifest was not found at $EngineManifestPath."
}

$EngineManifest = Get-Content -Path $EngineManifestPath -Raw | ConvertFrom-Json
$ExpectedEngineIds = @("python", "go", "rust", "java")
foreach ($EngineId in $ExpectedEngineIds) {
    $Engine = $EngineManifest.engines | Where-Object { $_.id -eq $EngineId } | Select-Object -First 1
    if ($null -eq $Engine) {
        throw "Engine manifest is missing the required $EngineId sidecar entry."
    }

    foreach ($RelativeFile in $Engine.requiredFiles) {
        $Resolved = Join-Path $EnginesDir $RelativeFile
        if (-not (Test-Path $Resolved)) {
            throw "Required sidecar file for $EngineId is missing: $Resolved"
        }
    }
}

& (Join-Path $RootDir "scripts\bootstrap.ps1") -Components wix
$ToolsDir = Resolve-ToolsDir -TargetPath $ToolCacheDir
$env:PATH = "$(Join-Path $ToolsDir 'wix');$(Join-Path $ToolsDir 'wix\bin');$env:PATH"

$LocalWixCli = Join-Path $ToolCacheDir "wix\wix.exe"
$LocalCandle = Join-Path $ToolCacheDir "wix\candle.exe"
$LocalLight = Join-Path $ToolCacheDir "wix\light.exe"

$WixCli = if (Test-Path $LocalWixCli) {
    @{ Source = $LocalWixCli }
} else {
    Get-Command wix -ErrorAction SilentlyContinue
}

$Candle = if (Test-Path $LocalCandle) {
    @{ Source = $LocalCandle }
} else {
    Get-Command candle -ErrorAction SilentlyContinue
}

$Light = if (Test-Path $LocalLight) {
    @{ Source = $LocalLight }
} else {
    Get-Command light -ErrorAction SilentlyContinue
}

if ($null -eq $WixCli -and ($null -eq $Candle -or $null -eq $Light)) {
    throw "Neither WiX v4 CLI nor WiX v3 candle/light were found after bootstrap."
}

$Version = "2.0.10"
$PubspecPath = Join-Path $FlutterDir "pubspec.yaml"
if (Test-Path $PubspecPath) {
    $VersionMatch = Select-String -Path $PubspecPath -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
    if ($VersionMatch) {
        $Version = $VersionMatch.Matches[0].Groups[1].Value
    }
}
$MsiPath = Join-Path $ArtifactDir "object-data-browser-windows-$Version-$Arch.msi"

$Files = Get-ChildItem -Path $AppReleaseDir -Recurse -File | Sort-Object FullName
$DirectoryRels = New-Object System.Collections.Generic.HashSet[string]
$ChildMap = @{}
$DirIds = @{
    '' = 'INSTALLFOLDER'
}

foreach ($File in $Files) {
    $RelativePath = $File.FullName.Substring($AppReleaseDir.Length).TrimStart('\')
    $RelativeDir = Split-Path -Parent $RelativePath
    if ($RelativeDir -and $RelativeDir -ne '.') {
        $Segments = $RelativeDir -split '\\'
        $Current = ''
        foreach ($Segment in $Segments) {
            $Current = if ([string]::IsNullOrEmpty($Current)) {
                $Segment
            } else {
                Join-Path $Current $Segment
            }
            [void]$DirectoryRels.Add($Current)
        }
    }
}

foreach ($DirRel in ($DirectoryRels | Sort-Object)) {
    $DirIds[$DirRel] = New-WixId -Prefix "DIR_" -Value $DirRel
    $Parent = Split-Path -Parent $DirRel
    if ($Parent -eq '.' -or $Parent -eq $null) {
        $Parent = ''
    }
    if (-not $ChildMap.ContainsKey($Parent)) {
        $ChildMap[$Parent] = New-Object System.Collections.Generic.List[string]
    }
    $ChildMap[$Parent].Add($DirRel)
}

function Emit-DirectoryTree {
    param(
        [string]$ParentRel,
        [string]$Indent
    )

    $Lines = New-Object System.Collections.Generic.List[string]
    if (-not $ChildMap.ContainsKey($ParentRel)) {
        return $Lines
    }

    foreach ($ChildRel in ($ChildMap[$ParentRel] | Sort-Object)) {
        $Name = Split-Path $ChildRel -Leaf
        $Lines.Add("$Indent<Directory Id=""$($DirIds[$ChildRel])"" Name=""$(Escape-Xml $Name)"">")
        foreach ($Nested in (Emit-DirectoryTree -ParentRel $ChildRel -Indent "$Indent  ")) {
            $Lines.Add($Nested)
        }
        $Lines.Add("$Indent</Directory>")
    }
    return $Lines
}

$DirectoryTree = (Emit-DirectoryTree -ParentRel '' -Indent '        ') -join "`r`n"

$ComponentLines = New-Object System.Collections.Generic.List[string]
foreach ($File in $Files) {
    $RelativePath = $File.FullName.Substring($AppReleaseDir.Length).TrimStart('\')
    $RelativeDir = Split-Path -Parent $RelativePath
    if ($RelativeDir -eq '.' -or $RelativeDir -eq $null) {
        $RelativeDir = ''
    }
    $DirectoryId = $DirIds[$RelativeDir]
    $ComponentId = New-WixId -Prefix "CMP_" -Value $RelativePath
    $FileId = New-WixId -Prefix "FIL_" -Value $RelativePath
    $Source = Escape-Xml $File.FullName
    $Name = Escape-Xml $File.Name
    $ComponentLines.Add("      <Component Id=""$ComponentId"" Directory=""$DirectoryId"" Guid=""*"">")
    $ComponentLines.Add("        <File Id=""$FileId"" Name=""$Name"" Source=""$Source"" KeyPath=""yes"" />")
    $ComponentLines.Add("      </Component>")
}
$ComponentBlock = $ComponentLines -join "`r`n"

$TemplatePath = if ($null -ne $WixCli) {
    Join-Path $RootDir "packaging\windows\Product.template.wxs"
} else {
    Join-Path $RootDir "packaging\windows\Product.wix3.template.wxs"
}

$Template = Get-Content -Path $TemplatePath -Raw
$Generated = $Template.Replace('{{VERSION}}', $Version)
$Generated = $Generated.Replace('{{DIRECTORY_TREE}}', $DirectoryTree)
$Generated = $Generated.Replace('{{COMPONENTS}}', $ComponentBlock)

Set-Content -Path $GeneratedWxs -Value $Generated -Encoding UTF8
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$MsiPath = Resolve-ArtifactOutputPath -PreferredPath $MsiPath
$WixPdbPath = [System.IO.Path]::ChangeExtension($MsiPath, ".wixpdb")
Remove-ArtifactIfPresent -Path $WixPdbPath

if ($null -ne $WixCli) {
    $ExitCode = Invoke-NativeTool -FilePath $WixCli.Source -Arguments @(
        'build',
        $GeneratedWxs,
        '-arch',
        $Arch,
        '-o',
        $MsiPath
    )
    if ($ExitCode -ne 0) {
        throw "WiX v4 build failed."
    }
} else {
    $WixObj = Join-Path $ArtifactDir "object-data-browser.wixobj"
    $CandleExitCode = Invoke-NativeTool -FilePath $Candle.Source -Arguments @(
        '-arch',
        $Arch,
        '-out',
        $WixObj,
        $GeneratedWxs
    )
    if ($CandleExitCode -ne 0) {
        throw "WiX v3 candle compilation failed."
    }
    $LightExitCode = Invoke-NativeTool -FilePath $Light.Source -Arguments @(
        '-out',
        $MsiPath,
        $WixObj
    )
    if ($LightExitCode -ne 0) {
        throw "WiX v3 light linking failed."
    }
}

Write-Host "MSI created at $MsiPath"
