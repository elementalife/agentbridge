param(
  [string] $Repo = $(if ($env:AGENTBRIDGE_RELEASE_REPO) { $env:AGENTBRIDGE_RELEASE_REPO } else { "elementalife/agentbridge" }),
  [string] $Tag = "",
  [switch] $NoRun,
  [switch] $NoLaunch,
  [switch] $KeepDownloads,
  [switch] $Help
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
  # PowerShell 7+ on modern Windows already negotiates TLS correctly.
}

function Show-Usage {
  @"
Install the latest AgentBridge Windows x64 release.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File desktop/scripts/install-latest-windows-release.ps1 [options]

Options:
  -Tag <tag>        Install a specific release tag instead of latest.
  -Repo <owner/repo>
                    GitHub repository to download from.
  -NoRun            Download, verify, and extract, but do not run the setup exe.
  -NoLaunch         Install, but do not launch AgentBridge after setup completes.
  -KeepDownloads    Leave downloaded and extracted files in the temp directory.
  -Help             Show this help.

Environment:
  AGENTBRIDGE_RELEASE_REPO    Default repository override.
  GH_TOKEN or GITHUB_TOKEN    Optional token for GitHub API downloads.
"@
}

function Write-Log {
  param([string] $Message)
  Write-Host "[agentbridge-install] $Message"
}

function Fail {
  param([string] $Message)
  throw "[agentbridge-install] $Message"
}

function Get-AgentBridgeLauncherPath {
  $candidates = @()

  if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA "dev.agentbridge.desktop\stable\app\bin\launcher.exe"
  }

  if ($env:APPDATA) {
    $shortcutPaths = @(
      (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AgentBridge.lnk"),
      (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AgentBridge\AgentBridge.lnk")
    )

    foreach ($shortcutPath in $shortcutPaths) {
      if (-not (Test-Path -LiteralPath $shortcutPath)) {
        continue
      }

      try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        if ($shortcut.TargetPath -and $shortcut.TargetPath.EndsWith("launcher.exe", [StringComparison]::OrdinalIgnoreCase)) {
          $candidates += $shortcut.TargetPath
        }
      } catch {
        Write-Log "could not inspect shortcut ${shortcutPath}: $($_.Exception.Message)"
      }
    }
  }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  return $null
}

function Get-AgentBridgeIconPath {
  if (-not $env:LOCALAPPDATA) {
    return $null
  }

  $iconPath = Join-Path $env:LOCALAPPDATA "dev.agentbridge.desktop\stable\app\Resources\app\assets\agentbridge-icon.ico"
  if (Test-Path -LiteralPath $iconPath) {
    return $iconPath
  }

  return $null
}

function Repair-AgentBridgeStartMenuIcon {
  $iconPath = Get-AgentBridgeIconPath
  if (-not $iconPath) {
    Write-Log "could not find AgentBridge icon asset; leaving Start Menu shortcut icon unchanged"
    return
  }

  if (-not $env:APPDATA) {
    Write-Log "APPDATA is unavailable; leaving Start Menu shortcut icon unchanged"
    return
  }

  $shortcutPaths = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AgentBridge.lnk"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AgentBridge\AgentBridge.lnk")
  )

  $shell = New-Object -ComObject WScript.Shell
  foreach ($shortcutPath in $shortcutPaths) {
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
      continue
    }

    try {
      $shortcut = $shell.CreateShortcut($shortcutPath)
      $shortcut.IconLocation = "$iconPath,0"
      $shortcut.Save()
      Write-Log "updated Start Menu shortcut icon: $shortcutPath"
    } catch {
      Write-Log "could not update Start Menu shortcut icon ${shortcutPath}: $($_.Exception.Message)"
    }
  }
}

function Get-AgentBridgeInstallRoot {
  if (-not $env:LOCALAPPDATA) {
    return $null
  }

  return Join-Path $env:LOCALAPPDATA "dev.agentbridge.desktop"
}

function Get-AgentBridgeStableInstallRoot {
  $installRoot = Get-AgentBridgeInstallRoot
  if (-not $installRoot) {
    return $null
  }

  return Join-Path $installRoot "stable"
}

function Get-AgentBridgeInstallSizeKb {
  param([string] $Path)

  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    return 0
  }

  $bytes = 0
  Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $bytes += $_.Length
  }

  return [int][Math]::Max(1, [Math]::Ceiling($bytes / 1KB))
}

function Quote-CommandArgument {
  param([string] $Value)
  return "`"$($Value.Replace('"', '\"'))`""
}

function Write-AgentBridgeUninstallerScript {
  $installRoot = Get-AgentBridgeInstallRoot
  if (-not $installRoot) {
    Fail "LOCALAPPDATA is unavailable; cannot register AgentBridge uninstaller"
  }

  if (-not (Test-Path -LiteralPath $installRoot)) {
    New-Item -ItemType Directory -Path $installRoot | Out-Null
  }

  $scriptPath = Join-Path $installRoot "Uninstall-AgentBridge.ps1"
  $script = @'
param(
  [switch] $Quiet,
  [switch] $RemoveUserData
)

$ErrorActionPreference = "SilentlyContinue"

function Remove-AgentBridgePath {
  param([string] $Path)

  if ($Path -and (Test-Path -LiteralPath $Path)) {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$localAppData = [Environment]::GetFolderPath("LocalApplicationData")
$appData = [Environment]::GetFolderPath("ApplicationData")
$installRoot = Join-Path $localAppData "dev.agentbridge.desktop"
$stableRoot = Join-Path $installRoot "stable"
$installRootPrefix = $installRoot.TrimEnd("\") + "\"
$userDataRoot = Join-Path $appData "AgentBridge"
$startupPath = Join-Path $appData "Microsoft\Windows\Start Menu\Programs\Startup\AgentBridge.cmd"
$startMenuShortcut = Join-Path $appData "Microsoft\Windows\Start Menu\Programs\AgentBridge.lnk"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentBridge"

Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
  $processPath = $null
  try {
    $processPath = $_.Path
  } catch {
    $processPath = $null
  }

  if ($processPath -and $processPath.StartsWith($installRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
  }
}

Remove-Item -LiteralPath $startupPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuShortcut -Force -ErrorAction SilentlyContinue
Remove-AgentBridgePath $stableRoot

if ($RemoveUserData) {
  Remove-AgentBridgePath $userDataRoot
}

Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue

try {
  $remainingFiles = @(Get-ChildItem -LiteralPath $installRoot -Force -ErrorAction SilentlyContinue)
  if ($remainingFiles.Count -eq 0) {
    Remove-Item -LiteralPath $installRoot -Force -ErrorAction SilentlyContinue
  }
} catch {
}

if (-not $Quiet) {
  Write-Host "AgentBridge has been uninstalled."
  if (-not $RemoveUserData -and (Test-Path -LiteralPath $userDataRoot)) {
    Write-Host "Logs and local config were kept at $userDataRoot."
  }
}
'@

  Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8
  return $scriptPath
}

function Set-AgentBridgeUninstallRegistryValue {
  param(
    [string] $KeyPath,
    [string] $Name,
    [object] $Value,
    [string] $Type = "String"
  )

  New-ItemProperty -LiteralPath $KeyPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Register-AgentBridgeWindowsUninstaller {
  param([string] $Version)

  $stableRoot = Get-AgentBridgeStableInstallRoot
  if (-not $stableRoot -or -not (Test-Path -LiteralPath $stableRoot)) {
    Write-Log "could not find stable install root; skipping Windows uninstall registration"
    return
  }

  $scriptPath = Write-AgentBridgeUninstallerScript
  $uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentBridge"
  $uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(Quote-CommandArgument $scriptPath)"
  $quietUninstallCommand = "$uninstallCommand -Quiet"
  $iconPath = Get-AgentBridgeIconPath
  $launcherPath = Get-AgentBridgeLauncherPath
  $displayIcon = if ($iconPath) { "$iconPath,0" } elseif ($launcherPath) { "$launcherPath,0" } else { $null }
  $estimatedSizeKb = Get-AgentBridgeInstallSizeKb $stableRoot

  New-Item -Path $uninstallKey -Force | Out-Null
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "DisplayName" "AgentBridge"
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "DisplayVersion" $Version
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "Publisher" "AgentBridge"
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "InstallLocation" $stableRoot
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "UninstallString" $uninstallCommand
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "QuietUninstallString" $quietUninstallCommand
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "NoModify" 1 "DWord"
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "NoRepair" 1 "DWord"
  Set-AgentBridgeUninstallRegistryValue $uninstallKey "EstimatedSize" $estimatedSizeKb "DWord"

  if ($displayIcon) {
    Set-AgentBridgeUninstallRegistryValue $uninstallKey "DisplayIcon" $displayIcon
  }

  Write-Log "registered Windows uninstaller: $uninstallKey"
}

function Wait-AgentBridgeHealth {
  param(
    [string] $Url = "http://127.0.0.1:8181/health",
    [int] $TimeoutSeconds = 30
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
      if ($response.StatusCode -eq 200) {
        return $true
      }
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }

  return $false
}

function Start-AgentBridgeApp {
  $launcherPath = Get-AgentBridgeLauncherPath
  if (-not $launcherPath) {
    Fail "AgentBridge setup completed, but the installed launcher.exe could not be found"
  }

  Write-Log "launching AgentBridge from $launcherPath"
  Start-Process -FilePath $launcherPath -WorkingDirectory (Split-Path -Parent $launcherPath) | Out-Null

  Write-Log "waiting for AgentBridge at http://127.0.0.1:8181/health"
  if (-not (Wait-AgentBridgeHealth)) {
    Fail "AgentBridge launched, but did not become healthy at http://127.0.0.1:8181/health"
  }

  Write-Log "AgentBridge is running at http://127.0.0.1:8181/"
}

if ($Help) {
  Show-Usage
  exit 0
}

if ($env:OS -ne "Windows_NT") {
  Fail "this installer only runs on Windows"
}

if (-not [Environment]::Is64BitOperatingSystem) {
  Fail "only Windows x64 releases are published right now"
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agentbridge-release-" + [guid]::NewGuid().ToString("N"))
$extractDir = Join-Path $workDir "extracted"
New-Item -ItemType Directory -Path $workDir, $extractDir | Out-Null

try {
  $headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "agentbridge-windows-installer"
  }

  $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { "" }
  if ($token) {
    $headers["Authorization"] = "Bearer $token"
  }

  $releaseUrl = if ($Tag) {
    "https://api.github.com/repos/$Repo/releases/tags/$([uri]::EscapeDataString($Tag))"
  } else {
    "https://api.github.com/repos/$Repo/releases/latest"
  }

  Write-Log "loading release metadata from $Repo"
  $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers
  $assets = @($release.assets)
  $zipAssets = @($assets | Where-Object { $_.name -like "AgentBridge-*-windows-x64-setup.zip" })
  $checksumAssets = @($assets | Where-Object { $_.name -eq "SHA256SUMS-windows-x64.txt" })

  if ($zipAssets.Count -ne 1) {
    $names = ($assets | ForEach-Object { $_.name }) -join ", "
    Fail "expected exactly one Windows setup zip asset, found $($zipAssets.Count): $names"
  }

  if ($checksumAssets.Count -ne 1) {
    $names = ($assets | ForEach-Object { $_.name }) -join ", "
    Fail "expected SHA256SUMS-windows-x64.txt, found $($checksumAssets.Count): $names"
  }

  $downloadHeaders = $headers.Clone()
  $downloadHeaders["Accept"] = "application/octet-stream"

  $zipAsset = $zipAssets[0]
  $checksumAsset = $checksumAssets[0]
  $zipPath = Join-Path $workDir $zipAsset.name
  $checksumPath = Join-Path $workDir $checksumAsset.name

  Write-Log "downloading $($zipAsset.name)"
  Invoke-WebRequest -Uri $zipAsset.url -Headers $downloadHeaders -OutFile $zipPath
  Write-Log "downloading $($checksumAsset.name)"
  Invoke-WebRequest -Uri $checksumAsset.url -Headers $downloadHeaders -OutFile $checksumPath

  Write-Log "verifying checksum"
  $expectedHash = $null
  foreach ($line in Get-Content -LiteralPath $checksumPath) {
    if ($line -match "^([A-Fa-f0-9]{64})\s+\*?(.+)$") {
      $hash = $Matches[1].ToLowerInvariant()
      $name = $Matches[2].Trim()
      if ($name -eq $zipAsset.name) {
        $expectedHash = $hash
      }
    }
  }

  if (-not $expectedHash) {
    Fail "checksum file does not include $($zipAsset.name)"
  }

  $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) {
    Fail "checksum mismatch for $($zipAsset.name): expected $expectedHash, got $actualHash"
  }
  Write-Log "$($zipAsset.name): OK"

  Write-Log "extracting setup zip"
  Unblock-File -LiteralPath $zipPath -ErrorAction SilentlyContinue
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
  Get-ChildItem -LiteralPath $extractDir -Recurse -File | ForEach-Object {
    Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
  }

  $setupFiles = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter "AgentBridge-Setup.exe")
  if ($setupFiles.Count -ne 1) {
    Fail "expected exactly one AgentBridge-Setup.exe after extraction, found $($setupFiles.Count)"
  }

  $setupPath = $setupFiles[0].FullName
  if ($NoRun) {
    Write-Log "setup is ready: $setupPath"
    Write-Log "run it manually to install AgentBridge"
  } else {
    Write-Log "running $setupPath"
    $process = Start-Process -FilePath $setupPath -Wait -PassThru
    if ($process.ExitCode -ne 0) {
      Fail "setup exited with code $($process.ExitCode)"
    }
    Write-Log "AgentBridge setup completed"
    Repair-AgentBridgeStartMenuIcon
    $displayVersion = if ($release.tag_name) { $release.tag_name.TrimStart("v") } else { $zipAsset.name }
    Register-AgentBridgeWindowsUninstaller $displayVersion
    if ($NoLaunch) {
      Write-Log "skipped AgentBridge launch because -NoLaunch was set"
    } else {
      Start-AgentBridgeApp
    }
  }
} finally {
  if ($KeepDownloads) {
    Write-Log "kept downloads in $workDir"
  } else {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
