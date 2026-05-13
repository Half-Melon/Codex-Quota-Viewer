$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$windowsTrayRoot = Join-Path $repoRoot "WindowsTray"
$nodeRuntimeRoot = Join-Path $windowsTrayRoot "src-tauri\NodeRuntime"
$nodeExe = Join-Path $nodeRuntimeRoot "node.exe"

& (Join-Path $PSScriptRoot "build-session-manager-windows.ps1")

if (!(Test-Path $nodeExe)) {
  throw "Bundled Windows Node runtime is missing at $nodeExe. Place node.exe and its runtime files under WindowsTray\src-tauri\NodeRuntime before building."
}

Push-Location $windowsTrayRoot
try {
  corepack npm install
  corepack npm run build
}
finally {
  Pop-Location
}
