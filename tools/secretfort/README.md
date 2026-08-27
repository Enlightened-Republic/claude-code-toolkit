# SecretFort

Two parts:

1. **Scanner** — walks your Claude Code session transcripts
   (`~/.claude/projects/**/*.jsonl`) for leaked secrets, writes a redacted
   report plus revoke/rotate pointers per provider.
2. **PreToolUse hook** — blocks `Read`/`Edit`/`Write`/`Bash` calls that touch
   known credential files, so Claude can't read your `.env` in the first place.

Context: [anthropics/claude-code#50014](https://github.com/anthropics/claude-code/issues/50014).

## Requirements

- PowerShell 5.1+ or PowerShell 7+, any OS
- No dependencies, no network — nothing ever leaves your machine

## Scan

```
pwsh -File secretfort.ps1                       # scan ~/.claude/projects
pwsh -File secretfort.ps1 -Root <dir>           # scan a specific tree
pwsh -File secretfort.ps1 -Json                 # machine-readable
pwsh -File secretfort.ps1 -ListOnly             # findings only, no revoke section
pwsh -File secretfort.ps1 -IncludeHistory       # also scan ~/.claude/history.jsonl
```

Writes `secretfort-report-<timestamp>.md` (or `.json`) to the current
directory. Every match is redacted to first-4 + last-4 — the full secret is
never printed or written.

Detects provider-specific patterns for Anthropic, OpenAI, Nvidia NIM,
OpenRouter, AWS, GitHub, Stripe, Slack, Google, Discord, AgentMail, plus
bearer JWTs and SSH private-key blocks. Gumroad tokens are matched
heuristically (only near a "gumroad" context word) and flagged `WARN`.

Exit codes: `0` clean · `1` one or more `CRITICAL` findings (CI-friendly) ·
`3` no transcripts found.

## Prevent future leaks (hook)

```
mkdir ~/.claude/secretfort
cp pretooluse-env-block.ps1 ~/.claude/secretfort/
```

Add to `~/.claude/settings.json`:

```json
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
```

Blocks paths matching `.env`, `credentials.*`, `secrets.*`, `.aws/credentials`,
`.ssh/id_*`, `.kube/config`, `serviceAccount*.json`, `.npmrc`, `.pypirc`, and
similar. Edit the `$blockPatterns` list to fit your setup.

## Limits

- Regex-based. High-entropy secrets with no recognizable prefix and no nearby
  keyword can slip through.
- Scanner reads the transcript text streams only — not binary artifacts.
- Does not revoke anything for you. It hands you the console links / commands;
  you rotate.

## Test

```
pwsh -File test.ps1
```

## License

MIT — see [LICENSE](../../LICENSE).
