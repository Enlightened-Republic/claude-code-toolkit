# HookForge

YAML-to-hook generator for Claude Code. Write a short spec, get a working
PowerShell hook handler plus the `settings.json` fragment to wire it in.

Writing hooks by hand means re-deriving the stdin/stdout JSON shapes, exit
codes, and `permissionDecision` fields every time. HookForge does the
boilerplate.

## Requirements

- PowerShell 5.1+ or PowerShell 7+, any OS
- Self-contained — templates are embedded in the script

## Use

```
# a 6-line spec
cat > my-hook.yaml <<'EOF'
name: block-env-writes
event: PreToolUse
matcher: Write|Edit
action: block
when:
  file_path_matches: '\.env'
reason: "Refusing to write into a .env file"
EOF

pwsh -File hookforge.ps1 lint     -Spec my-hook.yaml
pwsh -File hookforge.ps1 generate -Spec my-hook.yaml -OutDir ~/.claude/hooks
pwsh -File hookforge.ps1 list
pwsh -File hookforge.ps1 wire -Handler ~/.claude/hooks/x.ps1 -Event PreToolUse -Matcher 'Write|Edit'
```

`generate` writes `<name>.ps1` to `-OutDir` and prints the `settings.json`
fragment for you to merge in by hand (it never edits `settings.json` directly).

## Spec fields

| Field | Notes |
|---|---|
| `name` | kebab-case, becomes the filename |
| `event` | one of the 12 documented hook events |
| `matcher` | tool matcher regex (for tool-scoped events) |
| `action` | `block` \| `warn` \| `allow` \| `log` \| `transform` |
| `when.file_path_matches` / `.command_matches` / `.prompt_matches` | regex conditions |
| `when.tool_name_in` | `[Write, Edit]` |
| `when.allowed_paths` / `when.allowed_domains` | `[src/, docs/]` — for allowlist templates |
| `transform.replace_regex` / `transform.with` | for `action: transform` |
| `reason` | required for `block` / `warn` |
| `output.audit_file` | for `log`/audit templates |

## Templates

`generate` picks a template from the event + conditions. All are also listed by
`list`:

```
block-on-condition · block-bash-pattern · enforce-write-permissions
web-fetch-allowlist · audit-tool-call · redact-secrets · session-start-banner
stop-on-condition · transform-prompt · hook-with-context-injection
log-subagent-spawn · passthrough-with-telemetry
```

## Linter

Checks required fields, that `event` is known, that `matcher` and `when` regexes
compile, and that `action` has its companion fields. Failure → exit 2, nothing
written.

## Limits

- The YAML parser is a purpose-built subset — flat keys, one level of nesting,
  and `[a, b]` inline lists. No anchors, multi-line scalars, or deep nesting.
- `generate` maps the common event → template cases; exotic combinations may
  need you to start from `list` + a hand edit.
- Generated handlers are not executed or tested by HookForge — run them
  yourself.

## Test

```
pwsh -File test.ps1
```

## License

MIT — see [LICENSE](../../LICENSE).
