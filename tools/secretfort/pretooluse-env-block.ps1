#requires -Version 5.1
<#
    SecretFort PreToolUse hook — blocks Read/Edit/Write/Bash tool calls that
    touch known credential files, so Claude can't read your .env or
    ~/.aws/credentials even if it tries.

    Wire into ~/.claude/settings.json:

    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Read|Edit|Write|Bash",
            "hooks": [
              { "type": "command",
                "command": "pwsh -NoProfile -File ~/.claude/secretfort/pretooluse-env-block.ps1" }
            ]
          }
        ]
      }
    }
#>

$ErrorActionPreference = 'Stop'

$stdin = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($stdin)) { exit 0 }

try {
    $event = $stdin | ConvertFrom-Json
} catch {
    # Unparseable payload — fail open, don't wedge the session.
    exit 0
}

$tool = [string]$event.tool_name
$toolInput = $event.tool_input

$blockPatterns = @(
    '(^|[\\/])\.env(\.[^\\/]*)?$'
    '(^|[\\/])\.env(\.[^\\/]*)?["'' ]'
    'credentials\.(json|txt|ya?ml)'
    'secrets\.(ya?ml|json|toml)'
    '\.aws[\\/]credentials'
    '\.ssh[\\/]id_(rsa|ed25519|dsa|ecdsa)$'
    '\.kube[\\/]config'
    'service[-_]?account.*\.json'
    'firebase.*(key|admin).*\.json'
    '\.npmrc$'
    '\.pypirc$'
)

function Test-Block {
    param([string]$Target)
    if ([string]::IsNullOrEmpty($Target)) { return $false }
    foreach ($p in $blockPatterns) {
        if ($Target -match $p) { return $true }
    }
    return $false
}

$target = ''
switch ($tool) {
    'Read'  { $target = [string]$toolInput.file_path }
    'Edit'  { $target = [string]$toolInput.file_path }
    'Write' { $target = [string]$toolInput.file_path }
    'Bash'  { $target = [string]$toolInput.command }
    default { exit 0 }
}

if (Test-Block $target) {
    $resp = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = "SecretFort blocked access to a credential-pattern path/command ($target). Rotate the credential out of band; if this access is intentional, remove or narrow the matching pattern in pretooluse-env-block.ps1."
        }
    }
    Write-Output ($resp | ConvertTo-Json -Depth 5 -Compress)
    exit 0
}

exit 0
