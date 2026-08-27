# BashGuard

Pre-flight risk analyzer for the `Bash` tool in Claude Code. Wires in as a
`PreToolUse` hook and **blocks** or **warns** on ~50 dangerous command patterns
before they run.

Claude Code's `Bash` permission is all-or-nothing. BashGuard adds the middle
layer: allow most commands, stop the irreversible ones.

## Requirements

- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+ (`pwsh`), any OS
- No dependencies, no network

## Install

```
mkdir ~/.bashguard
cp bashguard.ps1 bashguard-rules.json ~/.bashguard/
```

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command",
            "command": "pwsh -NoProfile -File ~/.bashguard/bashguard.ps1" }
        ]
      }
    ]
  }
}
```

(Use `powershell` instead of `pwsh` if you're on Windows PowerShell only.)

## What it does

Reads the `PreToolUse` event on stdin, matches `tool_input.command` against
`bashguard-rules.json` (first match wins), and emits a standard hook response:

- **block** → `permissionDecision: "deny"` — Claude can't run it
- **warn** → `permissionDecision: "ask"` — Claude Code prompts you
- **allow** / no match → silent, command proceeds

Every decision is appended to `~/.bashguard/audit.log` as JSONL.

### Blocked by default

`rm -rf /` · `rm -rf ~` · `rm -rf` under system dirs · `git push --force` to
main/master (`--force-with-lease` is allowed) · `curl … | sh` · `sudo` ·
`kill -9 1` · `docker run --privileged` · `dd of=/dev/…` · `mkfs` ·
`terraform destroy` · `kubectl delete namespace` / `--all` ·
`aws ec2 terminate-instances` · `DROP DATABASE`/`DROP TABLE`/`dropdb` ·
firewall flush · Windows Defender disable · reverse-shell patterns
(`nc -e`, `base64 -d | sh`).

### Warned by default

`git reset --hard` · `git clean -fd` · `git branch -D` · reading `.env` /
`~/.aws/credentials` / SSH keys · `chmod 777` · `npm install <url>` ·
appending to shell rc files · `shutdown`/`reboot` · `npm publish` ·
`git config --global user.*`.

Edit `bashguard-rules.json` to add, remove, or retune rules. Set
`"defaultAction": "block"` to flip to deny-by-default.

## Limits

- Matches the literal command string Claude submitted — does not analyze the
  contents of scripts that command then runs.
- Pipe / here-doc parsing is heuristic tokenization, not a full shell parser.
- `Write`/`Edit` to `.ps1`/`.sh` files are out of scope — pair with a `Write`
  hook (e.g. [HookForge](../hookforge)) if you need that.

## Test

```
pwsh -File test.ps1
```

## License

MIT — see [LICENSE](../../LICENSE).
