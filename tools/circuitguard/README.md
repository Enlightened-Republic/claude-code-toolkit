# CircuitGuard

Runaway-pattern detector for AI agents. You write a small JSON state file as
your agent runs; CircuitGuard reads it and trips when it sees a loop, a cost
spike, or a tool-call storm — before the burn gets large.

Host-agnostic Node tool. It's the real-time pattern layer that a per-key spend
cap doesn't give you.

## Requirements

- Node 18+ (uses global `fetch` for webhook alerts)
- Zero dependencies

## The three detectors

| Pattern | Trips when |
|---|---|
| **Semantic loop** | 3+ near-identical outputs in a row (Jaccard token similarity > 0.85) |
| **Cost anomaly** | this minute's cost > 2× the rolling 10-minute median (with a $0.01 noise floor; needs ≥5 minutes of history) |
| **Tool-call storm** | same tool 10+ times in 60s with < 10% of calls changing state |

On a trip it logs to `~/.circuitguard/alerts.log`, applies a 60s per-pattern
cooldown, and — if you pass `--alert-on-trip <url>` — POSTs the trip plus a
soft-pause message (Slack-compatible `text` field) to that webhook.

CircuitGuard does **not** kill the agent. `buildSoftPauseMessage()` produces a
"you appear to be looping — pause and pick one of these" message for you to
inject into the next turn.

## Use

```
# one-shot check
node src/monitor.mjs --check state.json
node src/monitor.mjs --check state.json --json

# poll a file that your agent keeps updating
node src/monitor.mjs --watch state.json --interval 5000 --alert-on-trip https://hooks.example.com/...

# try the bundled trip examples
node src/monitor.mjs --check examples/runaway-cost.json
node src/monitor.mjs --check examples/runaway-loop.json
```

## The state file — you produce this

CircuitGuard is a **reader**. Your agent (or a thin wrapper around it) appends
to a JSON file as it runs:

```json
{
  "currentCostUsd": 0.04,
  "costPerMinute": [[1700000000000, 0.03], [1700000060000, 0.025]],
  "recentOutputs":   [{ "text": "…", "timestamp": 1700000000000 }],
  "recentToolCalls": [{ "tool": "exec", "timestamp": 1700000000000, "stateChanged": true }]
}
```

`examples/` has one file per detector showing exactly what trips it. State +
cooldown tracking live in `~/.circuitguard/` (override with `CIRCUITGUARD_HOME`).

You can also `import { check, runAllDetectors, buildSoftPauseMessage } from
'./src/monitor.mjs'` and call the detectors directly.

## Not in this version

- Hard stop (soft-pause message only)
- Cross-agent pattern sharing
- A built-in state writer for any specific harness — you wire the state file

## Test

```
node test.mjs
```

## License

MIT — see [LICENSE](../../LICENSE).
