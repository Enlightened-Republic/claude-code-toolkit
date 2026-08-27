#requires -Version 5.1
<#
.SYNOPSIS
    BashGuard - pre-flight risk analyzer for Bash commands in Claude Code.

.DESCRIPTION
    PreToolUse hook handler for the Bash tool. Reads the PreToolUse JSON event
    from stdin, evaluates the command against a configurable rule set, and emits
    a standard Claude Code hook response on stdout.

    Rules: bashguard-rules.json (next to this script by default).
    Audit log: ~/.bashguard/audit.log (JSONL).

.PARAMETER RulesFile
    Override the default rules file location.

.PARAMETER AuditLog
    Override the default audit log location.

.PARAMETER DefaultAction
    What to do when no rule matches: 'allow' (default) or 'block'.
#>
param(
    [string]$RulesFile = "",
    [string]$AuditLog = "",
    [string]$DefaultAction = "allow"
)

$ErrorActionPreference = 'Stop'

# ---- Read PreToolUse JSON from stdin ----
$stdin = [Console]::In.ReadToEnd()
if (-not $stdin.Trim()) {
    # No input - exit silently
    exit 0
}

try {
    $event = $stdin | ConvertFrom-Json
} catch {
    Write-Error "BashGuard: failed to parse stdin JSON: $_"
    exit 1
}

# Only handle Bash
if ($event.tool_name -ne 'Bash') {
    exit 0
}

$command = ""
if ($event.tool_input -and $event.tool_input.command) {
    $command = [string]$event.tool_input.command
}
if (-not $command) {
    exit 0
}

# ---- Resolve rules file ----
if (-not $RulesFile) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RulesFile = Join-Path $scriptDir "bashguard-rules.json"
    if (-not (Test-Path $RulesFile)) {
        # Fallback to ~/.bashguard
        $home_rules = Join-Path $HOME ".bashguard/bashguard-rules.json"
        if (Test-Path $home_rules) { $RulesFile = $home_rules }
    }
}

$rules = @()
if (Test-Path $RulesFile) {
    try {
        $loaded = Get-Content $RulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.rules) {
            $rules = $loaded.rules
            if ($loaded.defaultAction) { $DefaultAction = [string]$loaded.defaultAction }
        }
    } catch {
        # Continue with empty rules; default action applies
    }
}

# ---- Resolve audit log ----
if (-not $AuditLog) {
    $AuditLog = Join-Path $HOME ".bashguard/audit.log"
}
$auditDir = Split-Path -Parent $AuditLog
if ($auditDir -and -not (Test-Path $auditDir)) {
    New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
}

function Write-Audit {
    param([string]$Action, [string]$RuleId, [string]$Reason)
    $entry = @{
        ts = (Get-Date).ToString('o')
        command = $command
        rule = $RuleId
        action = $Action
        reason = $Reason
    } | ConvertTo-Json -Compress
    Add-Content -Path $AuditLog -Value $entry -ErrorAction SilentlyContinue
}

# ---- Evaluate rules ----
$matched = $null
foreach ($rule in $rules) {
    $isMatch = $false
    if ($rule.match -and $rule.match.command_regex) {
        try {
            if ($command -match $rule.match.command_regex) {
                $isMatch = $true
            }
        } catch {
            # bad regex, skip
        }
    }
    if (-not $isMatch -and $rule.match -and $rule.match.command_contains) {
        $needles = @($rule.match.command_contains)
        $allMatch = $true
        foreach ($n in $needles) {
            if ($command -notlike "*$n*") { $allMatch = $false; break }
        }
        if ($allMatch -and $needles.Count -gt 0) { $isMatch = $true }
    }
    if ($isMatch) {
        $matched = $rule
        break
    }
}

# ---- Emit decision ----
function Emit-Decision {
    param([string]$Decision, [string]$Reason)
    $resp = @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = $Decision
            permissionDecisionReason = $Reason
        }
    }
    Write-Output ($resp | ConvertTo-Json -Depth 5 -Compress)
}

if ($matched) {
    $action = [string]$matched.action
    $reason = if ($matched.reason) { [string]$matched.reason } else { "Matched rule: $($matched.id)" }
    $ruleId = [string]$matched.id
    Write-Audit -Action $action -RuleId $ruleId -Reason $reason
    switch ($action) {
        'block' {
            Emit-Decision -Decision 'deny' -Reason "$reason (rule: $ruleId)"
            exit 0
        }
        'warn' {
            Emit-Decision -Decision 'ask' -Reason "$reason (rule: $ruleId)"
            exit 0
        }
        default {
            # 'allow' - exit silently
            exit 0
        }
    }
}

# No rule matched - apply default
Write-Audit -Action $DefaultAction -RuleId "default" -Reason "No rule matched; default action"
if ($DefaultAction -eq 'block') {
    Emit-Decision -Decision 'deny' -Reason "BashGuard default-deny (no rule matched)"
}
exit 0
