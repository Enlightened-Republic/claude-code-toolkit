#requires -Version 5.1
<#
.SYNOPSIS
    AgentTimeline - post-mortem reconstruction of Claude Code subagent fan-out trees.

.DESCRIPTION
    Reads ~/.claude/projects/**/*.jsonl, identifies Agent tool calls and their
    matching subagent transcripts, builds the parent/child tree, computes
    tokens + duration + tool-call breakdown per branch, and renders an ASCII
    tree (or JSON / Markdown report).

.PARAMETER Session
    Specific session ID to analyze. Omit to use --latest.

.PARAMETER Latest
    Use the most-recently-modified session.

.PARAMETER ProjectRoot
    Optional project root to scope the session search.

.PARAMETER Json
    Emit the tree as JSON instead of ASCII.

.PARAMETER Markdown
    Emit a Markdown report.

.PARAMETER ProjectsDir
    Override the default ~/.claude/projects/ directory.
#>
param(
    [string]$Session = "",
    [switch]$Latest,
    [string]$ProjectRoot = "",
    [switch]$Json,
    [switch]$Markdown,
    [string]$ProjectsDir = ""
)

$ErrorActionPreference = 'Stop'

# ---- Resolve projects dir ----
if (-not $ProjectsDir) {
    $ProjectsDir = Join-Path $HOME ".claude/projects"
}
if (-not (Test-Path $ProjectsDir)) {
    Write-Error "AgentTimeline: projects dir not found at $ProjectsDir"
    exit 2
}

# ---- Locate session JSONL ----
function Get-ProjectSlugFromRoot {
    param([string]$Root)
    if (-not $Root) { return $null }
    $abs = (Resolve-Path $Root).Path
    # Claude Code encodes project root as path-with-dashes (e.g. C:-Users-foo-Desktop)
    return ($abs -replace '[\\/:]', '-')
}

$candidateFiles = @()
if ($ProjectRoot) {
    $slug = Get-ProjectSlugFromRoot -Root $ProjectRoot
    $projDir = Join-Path $ProjectsDir $slug
    if (Test-Path $projDir) {
        $candidateFiles = Get-ChildItem -Path $projDir -Filter *.jsonl -Recurse -File
    }
} else {
    $candidateFiles = Get-ChildItem -Path $ProjectsDir -Filter *.jsonl -Recurse -File
}

if (-not $candidateFiles) {
    Write-Error "AgentTimeline: no .jsonl files found"
    exit 2
}

$targetFile = $null
if ($Session) {
    $targetFile = $candidateFiles | Where-Object { $_.BaseName -eq $Session } | Select-Object -First 1
    if (-not $targetFile) {
        Write-Error "AgentTimeline: session '$Session' not found"
        exit 2
    }
} else {
    # Default (and explicit -Latest): most recently modified session
    $targetFile = $candidateFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

Write-Verbose "AgentTimeline: analyzing $($targetFile.FullName)"

# ---- Parse JSONL events ----
$events = @()
Get-Content -Path $targetFile.FullName -Encoding UTF8 | ForEach-Object {
    if ($_ -and $_.Trim()) {
        try {
            $events += ($_ | ConvertFrom-Json)
        } catch {
            # Skip malformed lines
        }
    }
}

# ---- Identify Agent tool calls and their results ----
$agentCalls = @{}   # agent_id -> { spawned_at, completed_at, parent_id, prompt_prefix, subagent_type }
$nextAgentId = 1

function New-AgentId {
    $id = "agent_{0:000}" -f $script:nextAgentId
    $script:nextAgentId++
    return $id
}

# Pass 1: find Agent tool calls in main session
foreach ($e in $events) {
    if (-not $e) { continue }

    # Common Claude Code event shape: { type: 'tool_use', name: 'Agent', input: {...}, id: 'toolu_xxx' }
    if ($e.type -eq 'assistant' -and $e.message -and $e.message.content) {
        foreach ($c in $e.message.content) {
            if ($c.type -eq 'tool_use' -and ($c.name -eq 'Agent' -or $c.name -eq 'Task' -or $c.name -eq 'TeammateTool')) {
                $aid = New-AgentId
                $promptPrefix = ""
                if ($c.input -and $c.input.prompt) {
                    $promptPrefix = ([string]$c.input.prompt).Substring(0, [Math]::Min(200, ([string]$c.input.prompt).Length))
                }
                $subagentType = if ($c.input -and $c.input.subagent_type) { [string]$c.input.subagent_type } else { 'general-purpose' }
                $agentCalls[$c.id] = @{
                    agent_id = $aid
                    tool_use_id = $c.id
                    spawned_at = $e.timestamp
                    completed_at = $null
                    parent_id = 'root'
                    prompt_prefix = $promptPrefix
                    subagent_type = $subagentType
                    tokens = @{ input = 0; output = 0; cache_read = 0; cache_write = 0 }
                    tool_calls = 0
                    tool_call_breakdown = @{}
                    exit_reason = 'orphan'
                    description = if ($c.input -and $c.input.description) { [string]$c.input.description } else { '(no description)' }
                }
            }
        }
    }
}

# Pass 2: find tool_result events that match agent tool calls
foreach ($e in $events) {
    if (-not $e -or $e.type -ne 'user') { continue }
    if (-not $e.message -or -not $e.message.content) { continue }
    foreach ($c in $e.message.content) {
        if ($c.type -eq 'tool_result' -and $agentCalls.ContainsKey($c.tool_use_id)) {
            $agentCalls[$c.tool_use_id].completed_at = $e.timestamp
            $agentCalls[$c.tool_use_id].exit_reason = if ($c.is_error) { 'error' } else { 'completed' }
        }
    }
}

# Pass 3: attribute tokens + tool calls to nearest enclosing subagent span
# Simple model: the first agent tool call in the main session starts span; subsequent assistant turns
# until the matching tool_result are attributed to that subagent.
# More accurate: Claude Code emits subagent events with parent tool_use_id; if present, use it.
$activeStack = New-Object System.Collections.Stack
$indexById = @{}
foreach ($k in $agentCalls.Keys) { $indexById[$agentCalls[$k].agent_id] = $agentCalls[$k] }

foreach ($e in $events) {
    if (-not $e) { continue }
    # Detect span openings
    if ($e.type -eq 'assistant' -and $e.message -and $e.message.content) {
        foreach ($c in $e.message.content) {
            if ($c.type -eq 'tool_use' -and $agentCalls.ContainsKey($c.id)) {
                # Set parent based on current active stack
                if ($activeStack.Count -gt 0) {
                    $agentCalls[$c.id].parent_id = $activeStack.Peek()
                }
                $activeStack.Push($agentCalls[$c.id].agent_id)
            }
        }
        # Attribute tokens of THIS assistant turn to currently active subagent (or root)
        if ($e.message.usage) {
            $active = if ($activeStack.Count -gt 0) { $activeStack.Peek() } else { $null }
            if ($active -and $indexById.ContainsKey($active)) {
                $node = $indexById[$active]
                if ($e.message.usage.input_tokens) { $node.tokens.input += [int]$e.message.usage.input_tokens }
                if ($e.message.usage.output_tokens) { $node.tokens.output += [int]$e.message.usage.output_tokens }
                if ($e.message.usage.cache_read_input_tokens) { $node.tokens.cache_read += [int]$e.message.usage.cache_read_input_tokens }
                if ($e.message.usage.cache_creation_input_tokens) { $node.tokens.cache_write += [int]$e.message.usage.cache_creation_input_tokens }
            }
        }
        # Count non-Agent tool calls
        $active = if ($activeStack.Count -gt 0) { $activeStack.Peek() } else { $null }
        if ($active -and $indexById.ContainsKey($active)) {
            $node = $indexById[$active]
            foreach ($c in $e.message.content) {
                if ($c.type -eq 'tool_use' -and -not ($c.name -in @('Agent','Task','TeammateTool'))) {
                    $node.tool_calls++
                    if ($node.tool_call_breakdown.$($c.name)) {
                        $node.tool_call_breakdown.$($c.name)++
                    } else {
                        $node.tool_call_breakdown.$($c.name) = 1
                    }
                }
            }
        }
    } elseif ($e.type -eq 'user' -and $e.message -and $e.message.content) {
        foreach ($c in $e.message.content) {
            if ($c.type -eq 'tool_result' -and $agentCalls.ContainsKey($c.tool_use_id)) {
                # Pop the matching agent off the stack
                $target = $agentCalls[$c.tool_use_id].agent_id
                $temp = New-Object System.Collections.Stack
                while ($activeStack.Count -gt 0) {
                    $top = $activeStack.Pop()
                    if ($top -eq $target) { break }
                    $temp.Push($top)
                }
                # Push back any siblings that weren't the target (shouldn't happen in well-formed trees)
                while ($temp.Count -gt 0) { $activeStack.Push($temp.Pop()) }
            }
        }
    }
}

# ---- Compute durations ----
foreach ($k in $agentCalls.Keys) {
    $node = $agentCalls[$k]
    if ($node.spawned_at -and $node.completed_at) {
        try {
            $start = [DateTime]::Parse($node.spawned_at)
            $end = [DateTime]::Parse($node.completed_at)
            $node.duration_ms = [int]($end - $start).TotalMilliseconds
        } catch { $node.duration_ms = 0 }
    } else {
        $node.duration_ms = 0
    }
}

# ---- Build tree ----
$nodes = $agentCalls.Values
$childrenByParent = @{}
foreach ($n in $nodes) {
    $p = $n.parent_id
    if (-not $childrenByParent.ContainsKey($p)) { $childrenByParent[$p] = @() }
    $childrenByParent[$p] += $n
}

function Get-Tree {
    param([string]$ParentId, [int]$Depth)
    $children = @()
    if ($childrenByParent.ContainsKey($ParentId)) {
        foreach ($n in ($childrenByParent[$ParentId] | Sort-Object spawned_at)) {
            $n.depth = $Depth
            $n.children = Get-Tree -ParentId $n.agent_id -Depth ($Depth + 1)
            $children += $n
        }
    }
    return $children
}

$tree = Get-Tree -ParentId 'root' -Depth 0

# ---- Render ----
function Render-Ascii {
    param($Nodes, [string]$Prefix = "", [bool]$IsRoot = $true)
    $lines = @()
    $count = $Nodes.Count
    for ($i = 0; $i -lt $count; $i++) {
        $n = $Nodes[$i]
        $isLast = ($i -eq ($count - 1))
        $connector = if ($IsRoot) { "" } elseif ($isLast) { "+-- " } else { "+-- " }
        $branch = if ($IsRoot) { "" } elseif ($isLast) { "    " } else { "|   " }
        $totalTokens = $n.tokens.input + $n.tokens.output
        $cacheRatio = if ($totalTokens -gt 0) { [int](($n.tokens.cache_read * 100) / [Math]::Max(1, $n.tokens.input)) } else { 0 }
        $dur = "{0,6}ms" -f $n.duration_ms
        $tok = "in={0} out={1} cache={2}%" -f $n.tokens.input, $n.tokens.output, $cacheRatio
        $tools = "tools={0}" -f $n.tool_calls
        $exit = $n.exit_reason
        $line = "{0}{1}{2}  [{3}] {4} | {5} | {6} | exit={7}" -f $Prefix, $connector, $n.agent_id, $n.subagent_type, $dur, $tok, $tools, $exit
        $lines += $line
        if ($n.description) {
            $descLine = "{0}{1}     desc: {2}" -f $Prefix, $branch, $n.description.Substring(0, [Math]::Min(80, $n.description.Length))
            $lines += $descLine
        }
        if ($n.children -and $n.children.Count -gt 0) {
            $lines += Render-Ascii -Nodes $n.children -Prefix ($Prefix + $branch) -IsRoot $false
        }
    }
    return $lines
}

if ($Json) {
    $tree | ConvertTo-Json -Depth 20
    exit 0
}

if ($Markdown) {
    Write-Output "# AgentTimeline report"
    Write-Output ""
    Write-Output "**Session**: $($targetFile.BaseName)"
    Write-Output "**Total subagents**: $($nodes.Count)"
    Write-Output ""
    $orphans = $nodes | Where-Object { $_.exit_reason -eq 'orphan' }
    if ($orphans.Count -gt 0) {
        Write-Output "## ORPHANS ($($orphans.Count))"
        Write-Output ""
        foreach ($o in $orphans) {
            Write-Output "- **$($o.agent_id)** [$($o.subagent_type)] spawned at $($o.spawned_at), never returned"
        }
        Write-Output ""
    }
    Write-Output "## Tree"
    Write-Output ""
    Write-Output '```'
    Render-Ascii -Nodes $tree | ForEach-Object { Write-Output $_ }
    Write-Output '```'
    $exitCode = if ($orphans.Count -gt 0) { 1 } else { 0 }
    exit $exitCode
}

# Default: ASCII to console
Write-Output "AgentTimeline - session $($targetFile.BaseName)"
Write-Output ("=" * 70)
Write-Output "Total subagents: $($nodes.Count)"
$orphans = $nodes | Where-Object { $_.exit_reason -eq 'orphan' }
if ($orphans.Count -gt 0) {
    Write-Output "ORPHANS: $($orphans.Count) (never returned)"
}
Write-Output ""
Render-Ascii -Nodes $tree | ForEach-Object { Write-Output $_ }
Write-Output ""
$exitCode = if ($orphans.Count -gt 0) { 1 } else { 0 }
exit $exitCode
