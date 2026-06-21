param(
  [string] $Repo = $(if ($env:AGENTBRIDGE_RELEASE_REPO) { $env:AGENTBRIDGE_RELEASE_REPO } else { "elementalife/agentbridge" }),
  [string] $Tag = "",
  [switch] $NoRun,
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
  }
} finally {
  if ($KeepDownloads) {
    Write-Log "kept downloads in $workDir"
  } else {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
