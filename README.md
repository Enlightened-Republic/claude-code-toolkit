# Claude Code Toolkit

Small, focused tools for running [Claude Code](https://claude.com/claude-code)
with more control and visibility — guardrails, hooks, and post-mortem analysis.
Free and MIT-licensed, from [Enlightened Republic](https://github.com/Enlightened-Republic).

Every tool is **self-contained** in its own folder: one script (PowerShell or
Node), a README, a test. No install step for the repo, no shared dependencies.
Take the one you want.

## The tools

| Tool | What it does | Runtime |
|---|---|---|
| **[BashGuard](tools/bashguard)** | `PreToolUse` hook that blocks/warns on ~50 dangerous Bash patterns before they run | PowerShell 5.1+ |
| **[SecretFort](tools/secretfort)** | Scans session transcripts for leaked API keys (redacted report + revoke links), plus a hook that blocks reads of credential files | PowerShell 5.1+ |
| **[HookForge](tools/hookforge)** | Generates a working Claude Code hook handler + `settings.json` fragment from a short YAML spec | PowerShell 5.1+ |
| **[ContextWatch](tools/contextwatch)** | Estimates how full your context window is and flags the quality-degradation zone before you run out | PowerShell 5.1+ |
| **[AgentTimeline](tools/agenttimeline)** | Rebuilds a subagent run from the transcript — per-subagent duration, tokens, tool calls, orphans | PowerShell 5.1+ |
| **[MCPGuard](tools/mcpguard)** | Readiness scoring, schema-drift detection, and config auditing for MCP servers | Node 18+ |
| **[CircuitGuard](tools/circuitguard)** | Runaway-agent detector — trips on loops, cost spikes, and tool-call storms from a state file you feed it | Node 18+ |

MCPGuard and CircuitGuard are host-agnostic (they read JSON, not Claude Code
internals) and work with any MCP client or agent runtime.

## Requirements

- **PowerShell tools:** Windows PowerShell 5.1, or PowerShell 7+ (`pwsh`) on any
  OS. No modules, no network.
- **Node tools:** Node 18+. Zero dependencies.

Where a command shows `pwsh`, use `powershell` instead if you're on Windows
PowerShell only — the scripts run on both.

## Install

Per tool. For example, BashGuard:

```
git clone https://github.com/Enlightened-Republic/claude-code-toolkit
cp claude-code-toolkit/tools/bashguard/bashguard*.* ~/.bashguard/
```

Then follow that tool's README for the `settings.json` wiring.

## Run the tests

```
pwsh -File test.ps1     # runs every tool's test suite (Node + PowerShell)
```

## What these are built around

Several of these exist because of specific gaps in Claude Code, and the tool
READMEs link the relevant `anthropics/claude-code` issues (#50014, #7881,
etc.). Where a tool can only approximate something — because the data isn't in
the transcript, or the heuristic is a heuristic — its README says so plainly.
Nothing here claims more than it does.

## Related

An OpenClaw counterpart (`openclaw-toolkit`) is planned for the tools that make
sense as in-process OpenClaw plugins.

## Contributing

Issues and PRs welcome. Each tool is deliberately small — a fix or a new rule
is usually a few lines.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Enlightened Republic.
