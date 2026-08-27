# AgentTimeline

Post-mortem reconstruction of a Claude Code subagent run. Reads the session
JSONL, pairs every `Task`/`Agent` tool call with its result, and prints a tree
with per-subagent duration, tokens, tool-call count, and exit reason.

Claude Code runs subagents inside the same transcript with the same session id
([anthropics/claude-code#7881](https://github.com/anthropics/claude-code/issues/7881)),
so after the fact it's hard to see which subagent did what. AgentTimeline
rebuilds that view from the transcript alone — no live hooks needed.

## Requirements

- PowerShell 5.1+ or PowerShell 7+, any OS
- No dependencies, no network

## Run

```
pwsh -File agenttimeline.ps1                     # latest session
pwsh -File agenttimeline.ps1 -Session <id>
pwsh -File agenttimeline.ps1 -ProjectRoot .      # scope to one project
pwsh -File agenttimeline.ps1 -Markdown > report.md
pwsh -File agenttimeline.ps1 -Json > tree.json
```

## Sample

```
AgentTimeline - session 1a2b3c-4d5e
======================================================================
Total subagents: 3

agent_001  [Explore]  40,000ms | in=800 out=120 cache=0% | tools=1 | exit=completed
     desc: find auth files
agent_002  [Plan]          0ms | in=600 out=90  cache=0% | tools=0 | exit=orphan
     desc: design migration
```

`exit=orphan` = spawned but no matching `tool_result` in the transcript. Exit
code 1 if any orphans are found.

## What it can and can't see

- **Reliable:** the direct parent → child pairing (each `Task` tool call ↔ its
  `tool_result`), the subagent type, wall-clock duration, and exit reason.
- **Best-effort:** token and tool-call attribution, and any nesting deeper than
  one level. Claude Code doesn't emit explicit subagent-boundary markers in the
  transcript, so deep trees and precise per-branch token splits are
  approximate. In most runs you'll see a flat list of the subagents the main
  agent spawned, which is usually what you want.
- Claude Code only. The Claude Agent SDK uses a different transcript shape.

## Test

```
pwsh -File test.ps1
```

## License

MIT — see [LICENSE](../../LICENSE).
