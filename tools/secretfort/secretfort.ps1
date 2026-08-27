# SecretFort - retrospective secret scanner for Claude Code session JSONL transcripts
# Read-only. Zero deps. Cross-platform.
# (c) 2026 Marik / Airheart Products / Enlightened Republic

[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutFile,
    [switch]$Json,
    [switch]$ListOnly,
    [switch]$IncludeHistory
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($Root)) {
    $home_ = [Environment]::GetFolderPath('UserProfile')
    $Root = Join-Path $home_ '.claude/projects'
}

if (-not (Test-Path $Root)) {
    Write-Error "Directory does not exist: $Root"
    exit 3
}

$patterns = @(
    @{ name = 'Anthropic API key'; regex = 'sk-ant-[A-Za-z0-9_\-]{60,}'; severity = 'CRITICAL'; provider = 'Anthropic' }
    @{ name = 'OpenAI API key'; regex = '(?<![A-Za-z])sk-(?!ant-|or-)(?:proj-)?[A-Za-z0-9_\-]{32,}'; severity = 'CRITICAL'; provider = 'OpenAI' }
    @{ name = 'AWS Access Key ID'; regex = 'AKIA[0-9A-Z]{16}'; severity = 'CRITICAL'; provider = 'AWS' }
    @{ name = 'GitHub Personal Access Token'; regex = 'gh[pousr]_[A-Za-z0-9]{36,}'; severity = 'CRITICAL'; provider = 'GitHub' }
    @{ name = 'Stripe Live Key'; regex = 'sk_live_[A-Za-z0-9]{20,}'; severity = 'CRITICAL'; provider = 'Stripe' }
    @{ name = 'Stripe Test Key'; regex = 'sk_test_[A-Za-z0-9]{20,}'; severity = 'WARN'; provider = 'Stripe' }
    @{ name = 'Slack Token'; regex = 'xox[abprs]-[A-Za-z0-9\-]{10,}'; severity = 'CRITICAL'; provider = 'Slack' }
    @{ name = 'Google API Key'; regex = 'AIza[0-9A-Za-z_\-]{35}'; severity = 'CRITICAL'; provider = 'Google' }
    @{ name = 'Nvidia NIM API key'; regex = 'nvapi-[A-Za-z0-9_\-]{50,}'; severity = 'CRITICAL'; provider = 'Nvidia' }
    @{ name = 'OpenRouter key'; regex = 'sk-or-v1-[A-Za-z0-9]{40,}'; severity = 'CRITICAL'; provider = 'OpenRouter' }
    @{ name = 'JWT Bearer Token'; regex = 'eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}'; severity = 'WARN'; provider = 'JWT' }
    @{ name = 'SSH Private Key block'; regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----'; severity = 'CRITICAL'; provider = 'SSH' }
    @{ name = 'Discord Bot Token'; regex = '[MN][A-Za-z\d]{23}\.[A-Za-z\d\-_]{6}\.[A-Za-z\d\-_]{27,38}'; severity = 'CRITICAL'; provider = 'Discord' }
    @{ name = 'AgentMail key'; regex = 'am_(?:us|eu)_(?:inbox_)?[a-f0-9]{32,}'; severity = 'CRITICAL'; provider = 'AgentMail' }
    @{ name = 'Gumroad access token'; regex = '(?<![A-Za-z0-9])[A-Za-z0-9_\-]{43}(?![A-Za-z0-9])'; severity = 'WARN'; provider = 'Gumroad (heuristic)' }
)

$revokeUrls = @{
    'Anthropic'  = 'https://console.anthropic.com/settings/keys'
    'OpenAI'     = 'https://platform.openai.com/api-keys'
    'AWS'        = 'https://console.aws.amazon.com/iam/home#/security_credentials  (aws iam delete-access-key --access-key-id <ID>)'
    'GitHub'     = 'https://github.com/settings/tokens  (or: gh auth refresh)'
    'Stripe'     = 'https://dashboard.stripe.com/apikeys'
    'Slack'      = 'https://api.slack.com/apps'
    'Google'     = 'https://console.cloud.google.com/apis/credentials'
    'Nvidia'     = 'https://build.nvidia.com/explore/discover  (Settings > API Keys)'
    'OpenRouter' = 'https://openrouter.ai/keys'
    'JWT'        = 'Rotate the source-of-truth secret (whatever signs the JWTs).'
    'SSH'        = 'Move ~/.ssh/<keyname> off-disk, generate a new keypair (ssh-keygen -t ed25519), update authorized_keys on every server.'
    'Discord'    = 'https://discord.com/developers/applications  (regenerate Bot Token)'
    'AgentMail'  = 'Contact AgentMail support to rotate inbox key.'
    'Gumroad (heuristic)' = 'https://app.gumroad.com/oauth/applications  (revoke + regenerate)'
}

function Redact {
    param([string]$Secret)
    if ([string]::IsNullOrEmpty($Secret)) { return '<empty>' }
    $len = $Secret.Length
    if ($len -le 12) { return ('*' * $len) }
    return ($Secret.Substring(0, 4) + ('*' * ($len - 8)) + $Secret.Substring($len - 4, 4))
}

$findings = New-Object System.Collections.ArrayList
$filesScanned = 0
$linesScanned = 0
$skipped = 0

$files = Get-ChildItem -Path $Root -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue
if ($IncludeHistory) {
    $home_ = [Environment]::GetFolderPath('UserProfile')
    $historyFile = Join-Path $home_ '.claude/history.jsonl'
    if (Test-Path $historyFile) {
        $files = @($files) + (Get-Item $historyFile)
    }
}

if (-not $files -or $files.Count -eq 0) {
    Write-Error "No JSONL files found under $Root"
    exit 3
}

foreach ($file in $files) {
    $filesScanned++
    try {
        $reader = [System.IO.File]::OpenText($file.FullName)
    } catch {
        $skipped++
        Write-Warning "Skipped (locked or unreadable): $($file.FullName)"
        continue
    }
    $lineNum = 0
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $lineNum++
            $linesScanned++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            foreach ($pat in $patterns) {
                try {
                    $matches_ = [regex]::Matches($line, $pat.regex)
                } catch { continue }
                foreach ($m in $matches_) {
                    $secret = $m.Value
                    # Heuristic: skip obvious non-secrets (very low entropy strings)
                    if ($pat.provider -eq 'Gumroad (heuristic)') {
                        # Only count if near a Gumroad context word
                        $window = $line.Substring([Math]::Max(0, $m.Index - 40), [Math]::Min(80, $line.Length - [Math]::Max(0, $m.Index - 40)))
                        if ($window -notmatch '(?i)gumroad|gumrd|api\.gumroad') { continue }
                    }
                    [void]$findings.Add([PSCustomObject]@{
                        File     = $file.FullName
                        Line     = $lineNum
                        Provider = $pat.provider
                        Pattern  = $pat.name
                        Severity = $pat.severity
                        Redacted = Redact $secret
                        Length   = $secret.Length
                    })
                }
            }
        }
    } finally {
        $reader.Close()
    }
}

# Dedupe (provider + redacted + file)
$dedup = $findings | Group-Object Provider, Redacted, File | ForEach-Object { $_.Group[0] }

# Build report
$timestamp = (Get-Date).ToString('yyyy-MM-dd-HHmmss')
if (-not $OutFile) {
    $OutFile = "secretfort-report-$timestamp.md"
}

if ($Json) {
    $report = [PSCustomObject]@{
        scanned_at    = (Get-Date).ToString('o')
        root          = $Root
        files_scanned = $filesScanned
        lines_scanned = $linesScanned
        skipped       = $skipped
        finding_count = $dedup.Count
        findings      = $dedup
    }
    [System.IO.File]::WriteAllText($OutFile, ($report | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    Write-Host "JSON report written: $OutFile"
} else {
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# SecretFort report")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("Scanned at: $((Get-Date).ToString('o'))")
    [void]$md.AppendLine("Root: $Root")
    [void]$md.AppendLine("Files scanned: $filesScanned   Lines scanned: $linesScanned   Skipped (locked): $skipped")
    [void]$md.AppendLine("Findings: $($dedup.Count)")
    [void]$md.AppendLine("")
    if ($dedup.Count -eq 0) {
        [void]$md.AppendLine("## All clean")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("No leaked secrets detected. Re-run periodically.")
    } else {
        $byProvider = $dedup | Group-Object Provider | Sort-Object Count -Descending
        [void]$md.AppendLine("## Summary by provider")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("| Provider | Count | Severity |")
        [void]$md.AppendLine("|---|---|---|")
        foreach ($g in $byProvider) {
            $sev = ($g.Group | Select-Object -First 1).Severity
            [void]$md.AppendLine("| $($g.Name) | $($g.Count) | $sev |")
        }
        [void]$md.AppendLine("")
        [void]$md.AppendLine("## Findings (redacted)")
        [void]$md.AppendLine("")
        foreach ($f in ($dedup | Sort-Object Severity, Provider)) {
            $sev = $f.Severity
            $prov = $f.Provider
            $red = $f.Redacted
            $len = $f.Length
            $fp = $f.File
            $ln = $f.Line
            [void]$md.AppendLine("- **[$sev]** $prov - ``$red`` (len $len) in ``$fp`` line $ln")
        }
        [void]$md.AppendLine("")
        if (-not $ListOnly) {
            [void]$md.AppendLine("## Revoke / rotate commands")
            [void]$md.AppendLine("")
            foreach ($g in $byProvider) {
                $url = $revokeUrls[$g.Name]
                [void]$md.AppendLine("### $($g.Name) ($($g.Count) finding(s))")
                [void]$md.AppendLine("")
                [void]$md.AppendLine($url)
                [void]$md.AppendLine("")
            }
        }
        [void]$md.AppendLine("## Next steps")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("1. Revoke / rotate every CRITICAL secret listed above at its provider console.")
        [void]$md.AppendLine("2. Update your local credential store with the new values.")
        [void]$md.AppendLine("3. Consider installing a PreToolUse hook to prevent future leaks (see bundled hooks/ folder).")
        [void]$md.AppendLine("4. Re-run SecretFort to confirm clean state.")
    }
    [System.IO.File]::WriteAllText($OutFile, $md.ToString())
    Write-Host "Report written: $OutFile"
    Write-Host ""
    Write-Host "Summary:"
    Write-Host ("  Files scanned: {0}" -f $filesScanned)
    Write-Host ("  Lines scanned: {0}" -f $linesScanned)
    Write-Host ("  Findings:      {0}" -f $dedup.Count)
    if ($dedup.Count -gt 0) {
        $critical = ($dedup | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
        Write-Host ("  CRITICAL:      {0}" -f $critical) -ForegroundColor Red
    }
}

if (($dedup | Where-Object { $_.Severity -eq 'CRITICAL' }).Count -gt 0) {
    exit 1
}
exit 0
