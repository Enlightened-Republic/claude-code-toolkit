#requires -Version 5.1
# HookForge smoke test: lint, generate, and verify every placeholder is
# substituted (the enforce-write-permissions / web-fetch-allowlist / transform
# templates used to ship literal {{...}} tokens).

$ErrorActionPreference = 'Stop'
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
$hf = Join-Path $PSScriptRoot 'hookforge.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("hf-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$pass = 0; $fail = 0
function Check($label, $cond) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $label" }
    else       { $script:fail++; Write-Host "  FAIL  $label" }
}
function Spec($yaml) {
    $p = Join-Path $work ("spec-" + [guid]::NewGuid().ToString('N') + ".yaml")
    $yaml | Set-Content $p -Encoding UTF8
    return $p
}
function Gen($specPath, $name) {
    & $psExe -NoProfile -File $hf generate -Spec $specPath -OutDir $work 2>$null | Out-Null
    return (Get-Content (Join-Path $work "$name.ps1") -Raw)
}

$s1 = Spec @"
name: block-env
event: PreToolUse
matcher: Write|Edit
action: block
when:
  file_path_matches: '\.env'
reason: "no env writes"
"@
$lint = (& $psExe -NoProfile -File $hf lint -Spec $s1 2>$null | Out-String)
Check 'lint passes a valid spec' ($lint -match 'LINT OK')

$g1 = Gen $s1 'block-env'
Check 'block-on-condition generates'        ($g1 -match 'permissionDecision = "deny"')
Check 'block-on-condition has no {{ }} left' (-not ($g1 -match '\{\{'))

$s2 = Spec @"
name: writes-allowlist
event: PreToolUse
action: block
when:
  tool_name_in: [Write, Edit]
  allowed_paths: [src/, docs/]
reason: "path not allowed"
"@
$g2 = Gen $s2 'writes-allowlist'
Check 'enforce-write-permissions substitutes ALLOWED_PATHS' ($g2 -match "@\('src/','docs/'\)")
Check 'enforce-write-permissions has no {{ }} left'         (-not ($g2 -match '\{\{'))

$s3 = Spec @"
name: fetch-allowlist
event: PreToolUse
action: block
when:
  allowed_domains: [github.com, docs.anthropic.com]
reason: "domain not allowed"
"@
$g3 = Gen $s3 'fetch-allowlist'
Check 'web-fetch-allowlist substitutes ALLOWED_DOMAINS' ($g3 -match "docs\.anthropic\.com")
Check 'web-fetch-allowlist has no {{ }} left'           (-not ($g3 -match '\{\{'))

$badLint = (& $psExe -NoProfile -File $hf lint -Spec (Spec "name: broken`nevent: NotARealEvent`naction: block") 2>$null | Out-String)
Check 'lint rejects an unknown event' ($badLint -match 'LINT FAILED')

$listed = (& $psExe -NoProfile -File $hf list 2>$null | Out-String)
Check 'list shows built-in templates' ($listed -match 'block-on-condition' -and $listed -match 'redact-secrets')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$pass passed, $fail failed"
exit ([int]($fail -gt 0))
