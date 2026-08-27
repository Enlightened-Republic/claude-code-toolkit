# ContextWatch

Estimates how full your live Claude Code context window is, and flags when
you've crossed into the zone where output quality starts to slip — which
research puts well before you actually run out of tokens.

## Requirements

- PowerShell 5.1+ or PowerShell 7+, any OS
- No dependencies, no network

## Run

```
pwsh -File contextwatch.ps1                          # latest active session
pwsh -File contextwatch.ps1 -Path <session.jsonl>    # a specific session
pwsh -File contextwatch.ps1 -ContextSize 1000000     # 1M-token window
pwsh -File contextwatch.ps1 -Json
pwsh -File contextwatch.ps1 -Top 20
```

## What you get

- Total estimated tokens and % of the window
- A rot band: `GREEN` / `YELLOW` / `ORANGE` / `RED` / `DEAD`, each with an action
- A breakdown by source: user messages, assistant messages, tool results,
  in-band system messages, and MCP overhead
- The most expensive `tool_result` blocks — your `/compact` or restart targets

| Band | % of window | Suggested action |
|---|---|---|
| GREEN | < 15% | fresh, keep going |
| YELLOW | 15–25% | early dilution, watch for drift |
| ORANGE | 25–40% | measurable degradation, `/compact` now |
| RED | 40–60% | heavy rot, restart with a summary handoff |
| DEAD | 60%+ | don't ship code from this session without re-running it fresh |

## How the numbers are made

- Token counts are a **character heuristic** (`chars / 3.6`, ~cl100k mean for
  English + code). Fast, no API call, accurate to within ~10%.
- ContextWatch measures what's **in the transcript**. The system prompt and
  tool schemas are injected by Claude Code at request time and are *not*
  written to the JSONL, so the "system messages" row reflects only in-band
  system notices, not the base prompt. Treat the total as "conversation +
  tool traffic," which is the part you can actually act on.
- The rot bands are a heuristic mapping, not a measurement of your specific
  session's quality. Use them as a nudge, not a verdict.

## Test

```
pwsh -File test.ps1
```

## License

MIT — see [LICENSE](../../LICENSE).
