#requires -Version 5.1
# SecretFort smoke test: exercises the scanner against a synthetic transcript
# and the PreToolUse hook against credential + non-credential paths.

$ErrorActionPreference = 'Stop'
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
$scanner = Join-Path $PSScriptRoot 'secretfort.ps1'
$hook    = Join-Path $PSScriptRoot 'pretooluse-env-block.ps1'
$pass = 0; $fail = 0
function Check($label, $cond) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $label" }
    else       { $script:fail++; Write-Host "  FAIL  $label" }
}

# --- scanner ---
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("sf-test-" + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $work 'projects\demo'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
$fakeGh = 'ghp_' + ('A' * 36)
$fakeAm = 'am_us_' + ('a1b2c3d4' * 8)
@(
    '{"type":"assistant","message":{"content":[{"type":"text","text":"here is a token ' + $fakeGh + '"}]}}'
    '{"type":"user","message":{"content":[{"type":"text","text":"and an agentmail key ' + $fakeAm + '"}]}}'
    '{"type":"assistant","message":{"content":[{"type":"text","text":"nothing sensitive here"}]}}'
) | Set-Content (Join-Path $proj 'session.jsonl') -Encoding UTF8

$report = Join-Path $work 'out.json'
& $psExe -NoProfile -File $scanner -Root $proj -OutFile $report -Json 2>$null | Out-Null
$json = Get-Content $report -Raw | ConvertFrom-Json
Check 'scanner finds the GitHub PAT'   (@($json.findings | Where-Object { $_.Provider -eq 'GitHub' }).Count -ge 1)
Check 'scanner finds the AgentMail key' (@($json.findings | Where-Object { $_.Provider -eq 'AgentMail' }).Count -ge 1)
Check 'scanner redacts (no raw secret in report)' (-not ((Get-Content $report -Raw) -match [regex]::Escape($fakeGh)))

# --- hook ---
function Hook($tool, $val) {
    $key = if ($tool -eq 'Bash') { 'command' } else { 'file_path' }
    $p = @{ tool_name = $tool; tool_input = @{ $key = $val } } | ConvertTo-Json -Compress
    return ($p | & $psExe -NoProfile -File $hook 2>$null | Out-String).Trim()
}
Check 'hook blocks .env read'          ((Hook 'Read' '/home/me/app/.env')            -match '"permissionDecision":"deny"')
Check 'hook blocks ~/.aws/credentials' ((Hook 'Read' 'C:\Users\me\.aws\credentials') -match '"permissionDecision":"deny"')
Check 'hook allows a normal file'      ([string]::IsNullOrWhiteSpace((Hook 'Read' '/home/me/app/README.md')))

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$pass passed, $fail failed"
exit ([int]($fail -gt 0))
