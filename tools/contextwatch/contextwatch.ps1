# ContextWatch - measure context rot in your live Claude Code session
# Read-only. Zero deps. Cross-platform.
# (c) 2026 Marik / Airheart Products / Enlightened Republic

[CmdletBinding()]
param(
    [string]$Path,
    [int]$ContextSize = 200000,
    [int]$Top = 10,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# Char-based token heuristic (cl100k empirical mean ~3.6 chars/token for English+code).
function Get-TokenEstimate {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return [Math]::Ceiling($Text.Length / 3.6)
}

# Find active session JSONL.
function Find-LatestSessionJsonl {
    $home_ = [Environment]::GetFolderPath('UserProfile')
    $root = Join-Path $home_ '.claude/projects'
    if (-not (Test-Path $root)) {
        Write-Error "Claude Code not installed or no sessions yet - $root does not exist."
        exit 2
    }
    $files = Get-ChildItem -Path $root -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue
    if (-not $files) {
        Write-Error "No sessions found under $root."
        exit 3
    }
    return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

if ([string]::IsNullOrEmpty($Path)) {
    $Path = Find-LatestSessionJsonl
}
if (-not (Test-Path $Path)) {
    Write-Error "Path does not exist: $Path"
    exit 4
}
if (-not $Path.EndsWith('.jsonl')) {
    Write-Error "Not a Claude Code session JSONL: $Path"
    exit 4
}

$buckets = @{
    'system_prompt'      = 0
    'tools_schema'       = 0
    'messages_user'      = 0
    'messages_assistant' = 0
    'tool_results'       = 0
    'mcp_overhead'       = 0
}
$expensive = New-Object System.Collections.ArrayList
$lineCount = 0
$parseErrors = 0

Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
    $lineCount++
    if ([string]::IsNullOrWhiteSpace($_)) { return }
    try {
        $obj = $_ | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $parseErrors++
        return
    }

    # System messages / tool schemas
    if ($obj.type -eq 'system' -or $obj.role -eq 'system') {
        $t = Get-TokenEstimate ([string]$obj.content)
        $buckets['system_prompt'] += $t
        return
    }

    if ($obj.PSObject.Properties.Name -contains 'tools') {
        $t = Get-TokenEstimate ($obj.tools | ConvertTo-Json -Depth 10 -Compress)
        $buckets['tools_schema'] += $t
        return
    }

    # Message blocks (Claude Code shape: { type:user|assistant, message:{content:[...]} })
    $msg = $null
    if ($obj.message) { $msg = $obj.message }
    elseif ($obj.content) { $msg = $obj }

    if ($null -eq $msg) { return }

    $role = if ($obj.type) { $obj.type } else { $msg.role }

    if ($msg.content -is [array]) {
        foreach ($block in $msg.content) {
            $blockType = $block.type
            $blockTokens = 0
            $contentStr = ''
            switch ($blockType) {
                'text' {
                    $contentStr = [string]$block.text
                    $blockTokens = Get-TokenEstimate $contentStr
                    if ($role -eq 'user') { $buckets['messages_user'] += $blockTokens }
                    else { $buckets['messages_assistant'] += $blockTokens }
                }
                'tool_use' {
                    $contentStr = ($block.input | ConvertTo-Json -Depth 10 -Compress) + ' ' + [string]$block.name
                    $blockTokens = Get-TokenEstimate $contentStr
                    $buckets['messages_assistant'] += $blockTokens
                    if ($block.name -like 'mcp__*') {
                        $buckets['mcp_overhead'] += [Math]::Floor($blockTokens * 0.3)
                    }
                }
                'tool_result' {
                    $resultContent = $block.content
                    if ($resultContent -is [array]) {
                        $contentStr = ($resultContent | ForEach-Object { if ($_.text) { $_.text } else { ($_ | ConvertTo-Json -Compress) } }) -join "`n"
                    } else {
                        $contentStr = [string]$resultContent
                    }
                    $blockTokens = Get-TokenEstimate $contentStr
                    $buckets['tool_results'] += $blockTokens
                    $preview = if ($contentStr.Length -gt 80) { $contentStr.Substring(0,80) + '...' } else { $contentStr }
                    [void]$expensive.Add([PSCustomObject]@{
                        Tokens   = $blockTokens
                        Line     = $lineCount
                        ToolUseId = $block.tool_use_id
                        Preview  = ($preview -replace "`r?`n",' ')
                    })
                }
                default { }
            }
        }
    } elseif ($msg.content -is [string]) {
        $t = Get-TokenEstimate $msg.content
        if ($role -eq 'user') { $buckets['messages_user'] += $t }
        else { $buckets['messages_assistant'] += $t }
    }
}

$totalTokens = ($buckets.Values | Measure-Object -Sum).Sum
$pct = if ($ContextSize -gt 0) { [Math]::Round(($totalTokens / $ContextSize) * 100, 1) } else { 0 }

$band = switch ($true) {
    ($pct -lt 15)  { 'GREEN' ; break }
    ($pct -lt 25)  { 'YELLOW' ; break }
    ($pct -lt 40)  { 'ORANGE' ; break }
    ($pct -lt 60)  { 'RED' ; break }
    default        { 'DEAD' }
}

$bandAdvice = switch ($band) {
    'GREEN'  { 'Session is fresh. Keep going.' }
    'YELLOW' { 'Early dilution. Watch for output drift. Consider /compact after the next milestone.' }
    'ORANGE' { 'Measurable degradation zone. /compact now or restart with a summary handoff.' }
    'RED'    { 'Heavy rot. Output quality has dropped. Restart with a summary handoff.' }
    'DEAD'   { 'Untrustworthy zone. RESTART NOW. Do not ship code from this session without re-running it in a fresh one.' }
}

$expensiveTop = $expensive | Sort-Object Tokens -Descending | Select-Object -First $Top

if ($Json) {
    $report = [PSCustomObject]@{
        session_path = $Path
        context_size = $ContextSize
        total_tokens = $totalTokens
        percent_used = $pct
        band         = $band
        advice       = $bandAdvice
        buckets      = $buckets
        top_expensive_tool_results = $expensiveTop
        lines_parsed = $lineCount
        parse_errors = $parseErrors
    }
    $report | ConvertTo-Json -Depth 10
    return
}

# Human report
Write-Host ''
Write-Host "ContextWatch report" -ForegroundColor Cyan
Write-Host ('-' * 60)
Write-Host "Session:       $Path"
Write-Host "Context size:  $ContextSize tokens"
Write-Host ("Total used:    {0} tokens ({1} percent)" -f $totalTokens, $pct)
Write-Host ''

$bandColor = switch ($band) {
    'GREEN'  { 'Green' }
    'YELLOW' { 'Yellow' }
    'ORANGE' { 'DarkYellow' }
    'RED'    { 'Red' }
    'DEAD'   { 'Magenta' }
}
Write-Host "Rot band:      $band" -ForegroundColor $bandColor
Write-Host "Advice:        $bandAdvice"
Write-Host ''
Write-Host 'Token breakdown by source:' -ForegroundColor Cyan
$buckets.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    $bpct = if ($totalTokens -gt 0) { [Math]::Round(($_.Value / $totalTokens) * 100, 1) } else { 0 }
    Write-Host ("  {0,-20} {1,8} tokens  ({2} percent)" -f $_.Key, $_.Value, $bpct)
}
Write-Host ''
Write-Host "Top $Top expensive tool_results (compaction targets):" -ForegroundColor Cyan
if ($expensiveTop) {
    $expensiveTop | ForEach-Object {
        Write-Host ("  L{0,-5} {1,7} tok  {2}" -f $_.Line, $_.Tokens, $_.Preview)
    }
} else {
    Write-Host '  (none)'
}
Write-Host ''
Write-Host ("Lines parsed: {0}  ({1} parse errors)" -f $lineCount, $parseErrors)
Write-Host ''
