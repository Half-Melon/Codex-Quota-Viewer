$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sessionManagerRoot = Join-Path $repoRoot "Vendor\CodexMM"
$targetRoot = Join-Path $repoRoot "WindowsTray\src-tauri\SessionManager"

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

Push-Location $sessionManagerRoot
try {
  Invoke-Checked { corepack npm ci } "Installing Session Manager dependencies"
  Invoke-Checked { corepack npm run build } "Building Session Manager"
}
finally {
  Pop-Location
}

$builtServerEntry = Join-Path $sessionManagerRoot "dist\server\index.js"
$builtClientRoot = Join-Path $sessionManagerRoot "dist\client"

if (!(Test-Path $builtServerEntry)) {
  throw "Session Manager server build output is missing at $builtServerEntry"
}

if (!(Test-Path $builtClientRoot)) {
  throw "Session Manager client build output is missing at $builtClientRoot"
}

if (Test-Path $targetRoot) {
  Remove-Item -LiteralPath $targetRoot -Recurse -Force
}

New-Item -ItemType Directory -Force $targetRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $sessionManagerRoot "dist") -Destination $targetRoot -Recurse
Copy-Item -LiteralPath (Join-Path $sessionManagerRoot "package.json") -Destination $targetRoot
Copy-Item -LiteralPath (Join-Path $sessionManagerRoot "package-lock.json") -Destination $targetRoot

Push-Location $targetRoot
try {
  Invoke-Checked { corepack npm ci --omit=dev } "Installing Session Manager production dependencies"
}
finally {
  Pop-Location
}

Write-Host "Session Manager staged at $targetRoot"
