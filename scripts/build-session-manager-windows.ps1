$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sessionManagerRoot = Join-Path $repoRoot "Vendor\CodexMM"
$targetRoot = Join-Path $repoRoot "WindowsTray\src-tauri\SessionManager"

Push-Location $sessionManagerRoot
try {
  corepack npm install
  corepack npm run build
}
finally {
  Pop-Location
}

if (Test-Path $targetRoot) {
  Remove-Item -LiteralPath $targetRoot -Recurse -Force
}

New-Item -ItemType Directory -Force $targetRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $sessionManagerRoot "dist") -Destination $targetRoot -Recurse
Copy-Item -LiteralPath (Join-Path $sessionManagerRoot "package.json") -Destination $targetRoot

Write-Host "Session Manager staged at $targetRoot"
