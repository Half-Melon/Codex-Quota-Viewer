$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$windowsTrayRoot = Join-Path $repoRoot "WindowsTray"
$nodeRuntimeRoot = Join-Path $windowsTrayRoot "src-tauri\NodeRuntime"
$nodeExe = Join-Path $nodeRuntimeRoot "node.exe"
$nodeDownloadUrl = "https://nodejs.org/download/release/latest-v22.x/win-x64/node.exe"

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock] $Command,
    [Parameter(Mandatory = $true)]
    [string] $Description
  )

  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE"
  }
}

$localNode = Get-Command node -ErrorAction SilentlyContinue
if ($localNode) {
  New-Item -ItemType Directory -Force $nodeRuntimeRoot | Out-Null
  Write-Host "Copying local Node runtime from $($localNode.Source)"
  Copy-Item -LiteralPath $localNode.Source -Destination $nodeExe -Force
}
elseif (!(Test-Path $nodeExe)) {
  New-Item -ItemType Directory -Force $nodeRuntimeRoot | Out-Null
  Write-Host "Downloading Windows Node runtime from $nodeDownloadUrl"
  Invoke-WebRequest -Uri $nodeDownloadUrl -OutFile $nodeExe
}

if (!(Test-Path $nodeExe)) {
  throw "Bundled Windows Node runtime is missing at $nodeExe."
}

Write-Host "Bundled Node runtime version:"
& $nodeExe --version

& (Join-Path $PSScriptRoot "build-session-manager-windows.ps1")

Push-Location $windowsTrayRoot
try {
  Invoke-Checked { corepack npm ci } "Installing Windows tray dependencies"
  Invoke-Checked { corepack npm run build } "Building Windows tray app"
}
finally {
  Pop-Location
}
