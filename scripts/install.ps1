param(
  [string]$Repo = "loongphy/codex-auth",
  [string]$Version = "latest",
  [string]$InstallDir = "$env:LOCALAPPDATA\codex-auth\bin",
  [switch]$AddToPath
)

$ErrorActionPreference = "Stop"

function Detect-Asset {
  $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  $archText = switch ($arch) {
    "X64" { "X64" }
    "Arm64" { "ARM64" }
    default { throw "Unsupported architecture: $arch" }
  }
  return "codex-auth-Windows-$archText.zip"
}

if (-not (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) {
  throw "Invoke-WebRequest is required."
}

$Asset = Detect-Asset

$DownloadUrl = if ($Version -eq "latest") {
  "https://github.com/$Repo/releases/latest/download/$Asset"
} else {
  "https://github.com/$Repo/releases/download/$Version/$Asset"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-auth-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
try {
  $ArchivePath = Join-Path $TempDir $Asset
  Write-Host "Downloading $DownloadUrl"
  Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath

  Expand-Archive -Path $ArchivePath -DestinationPath $TempDir -Force
  $SourceBin = Join-Path $TempDir "codex-auth.exe"
  if (-not (Test-Path $SourceBin)) {
    throw "Downloaded archive does not contain codex-auth.exe"
  }

  New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
  $DestBin = Join-Path $InstallDir "codex-auth.exe"
  Copy-Item -Path $SourceBin -Destination $DestBin -Force

  Write-Host "Installed: $DestBin"
} finally {
  Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}

if ($AddToPath) {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) {
    $userPath = ""
  }
  $segments = $userPath -split ';' | Where-Object { $_ -ne "" }
  if ($segments -notcontains $InstallDir) {
    $newPath = if ($userPath -eq "") { $InstallDir } else { "$userPath;$InstallDir" }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "Added to user PATH: $InstallDir"
    Write-Host "Restart terminal to pick up PATH changes."
  }
}

if (-not (($env:Path -split ';') -contains $InstallDir)) {
  Write-Host "Note: $InstallDir is not in current PATH."
  Write-Host "Reopen terminal or run with -AddToPath."
}
