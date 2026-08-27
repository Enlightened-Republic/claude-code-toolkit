#requires -Version 5.1
# ContextWatch smoke test: build a synthetic session JSONL and check the
# token accounting + rot band.

$ErrorActionPreference = 'Stop'
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
$cw = Join-Path $PSScriptRoot 'contextwatch.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cw-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$pass = 0; $fail = 0
function Check($label, $cond) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $label" }
    else       { $script:fail++; Write-Host "  FAIL  $label" }
}

$big = 'x' * 40000   # ~11k tokens of "tool result"
$lines = @(
    (@{ type='user';      message=@{ role='user'; content=@(@{ type='text'; text='hello there' }) } } | ConvertTo-Json -Compress -Depth 6)
    (@{ type='assistant'; message=@{ role='assistant'; content=@(@{ type='tool_use'; name='Read'; input=@{ file_path='a.txt' } }) } } | ConvertTo-Json -Compress -Depth 6)
    (@{ type='user';      message=@{ role='user'; content=@(@{ type='tool_result'; tool_use_id='t1'; content=$big }) } } | ConvertTo-Json -Compress -Depth 6)
)
$sess = Join-Path $work 'session.jsonl'
$lines | Set-Content $sess -Encoding UTF8

$out = & $psExe -NoProfile -File $cw -Path $sess -Json 2>$null | Out-String
$r = $out | ConvertFrom-Json
Check 'reports a total token count'        ($r.total_tokens -gt 5000)
Check 'attributes the big tool_result'     ($r.buckets.tool_results -gt 8000)
Check 'computes a percent-used'            ($r.percent_used -gt 0)
Check 'assigns a rot band'                 ($r.band -in @('GREEN','YELLOW','ORANGE','RED','DEAD'))
Check 'lists the expensive tool_result'    (@($r.top_expensive_tool_results).Count -ge 1)

# small session -> GREEN
'{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' | Set-Content $sess -Encoding UTF8
$r2 = (& $psExe -NoProfile -File $cw -Path $sess -Json 2>$null | Out-String) | ConvertFrom-Json
Check 'tiny session is GREEN' ($r2.band -eq 'GREEN')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$pass passed, $fail failed"
exit ([int]($fail -gt 0))
