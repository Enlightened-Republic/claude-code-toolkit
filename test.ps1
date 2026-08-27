#requires -Version 5.1
# Runs every tool's test suite. Node tools need `node` on PATH; PowerShell
# tools run under whatever PowerShell is executing this.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$fail = 0

$psTools   = 'bashguard','secretfort','hookforge','contextwatch','agenttimeline'
$nodeTools = 'mcpguard','circuitguard'

foreach ($t in $psTools) {
    Write-Host "==== $t ====" -ForegroundColor Cyan
    & (Join-Path $root "tools/$t/test.ps1")
    if ($LASTEXITCODE -ne 0) { $fail++ }
    Write-Host ""
}

$node = Get-Command node -ErrorAction SilentlyContinue
foreach ($t in $nodeTools) {
    Write-Host "==== $t ====" -ForegroundColor Cyan
    if (-not $node) { Write-Host "  SKIP (node not found)"; Write-Host ""; continue }
    & node (Join-Path $root "tools/$t/test.mjs")
    if ($LASTEXITCODE -ne 0) { $fail++ }
    Write-Host ""
}

if ($fail -gt 0) { Write-Host "$fail suite(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "all suites passed" -ForegroundColor Green
exit 0
