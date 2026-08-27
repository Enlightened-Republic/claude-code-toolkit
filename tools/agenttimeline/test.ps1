#requires -Version 5.1
# AgentTimeline smoke test: synthesize a transcript with two subagent spawns
# (one completes, one is left orphaned) and check the reconstructed tree.

$ErrorActionPreference = 'Stop'
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
$at = Join-Path $PSScriptRoot 'agenttimeline.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("at-test-" + [guid]::NewGuid().ToString('N'))
$projDir = Join-Path $work 'projects\demo'
New-Item -ItemType Directory -Path $projDir -Force | Out-Null
$pass = 0; $fail = 0
function Check($label, $cond) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $label" }
    else       { $script:fail++; Write-Host "  FAIL  $label" }
}

$lines = @(
  (@{ type='assistant'; timestamp='2026-08-27T10:00:00Z'; message=@{
        content=@(@{ type='tool_use'; id='toolu_a'; name='Task'; input=@{ subagent_type='Explore'; description='find auth files'; prompt='go find every authentication-related file in this repository and summarize' } });
        usage=@{ input_tokens=800; output_tokens=120 } } } | ConvertTo-Json -Compress -Depth 8)
  (@{ type='assistant'; timestamp='2026-08-27T10:00:10Z'; message=@{
        content=@(@{ type='tool_use'; id='toolu_r'; name='Read'; input=@{ file_path='auth.ts' } });
        usage=@{ input_tokens=400; output_tokens=60 } } } | ConvertTo-Json -Compress -Depth 8)
  (@{ type='user'; timestamp='2026-08-27T10:00:40Z'; message=@{
        content=@(@{ type='tool_result'; tool_use_id='toolu_a'; is_error=$false; content='found 3 files' }) } } | ConvertTo-Json -Compress -Depth 8)
  (@{ type='assistant'; timestamp='2026-08-27T10:01:00Z'; message=@{
        content=@(@{ type='tool_use'; id='toolu_b'; name='Task'; input=@{ subagent_type='Plan'; description='design migration'; prompt='design a migration plan for the auth subsystem based on the findings' } });
        usage=@{ input_tokens=600; output_tokens=90 } } } | ConvertTo-Json -Compress -Depth 8)
)
$sess = Join-Path $projDir 'session-abc.jsonl'
$lines | Set-Content $sess -Encoding UTF8

$json = & $psExe -NoProfile -File $at -ProjectsDir $projDir -Json 2>$null | Out-String
$tree = $json | ConvertFrom-Json
Check 'reconstructs 2 subagents'          ($tree.Count -eq 2)
Check 'identifies the Explore subagent'   (@($tree | Where-Object { $_.subagent_type -eq 'Explore' }).Count -eq 1)
$explore = $tree | Where-Object { $_.subagent_type -eq 'Explore' }
Check 'completed subagent has exit=completed' ($explore.exit_reason -eq 'completed')
Check 'completed subagent has a duration'     ($explore.duration_ms -ge 40000)
$plan = $tree | Where-Object { $_.subagent_type -eq 'Plan' }
Check 'unreturned subagent is an orphan'  ($plan.exit_reason -eq 'orphan')

# Markdown path must not throw (regression: `exit (if ...)` was PS7-only)
$md = & $psExe -NoProfile -File $at -ProjectsDir $projDir -Markdown 2>&1 | Out-String
Check 'markdown report renders'           ($md -match '# AgentTimeline report')
Check 'markdown lists the orphan'         ($md -match 'ORPHAN')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$pass passed, $fail failed"
exit ([int]($fail -gt 0))
