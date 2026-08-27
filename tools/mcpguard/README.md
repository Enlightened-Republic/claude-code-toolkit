# MCPGuard

Quality checks for MCP (Model Context Protocol) servers. Three one-shot
commands: **readiness scoring**, **schema-drift detection**, **config audit**.

Host-agnostic — this is a plain Node CLI that reads JSON and prints results. It
pairs with any MCP client (Claude Code, OpenClaw, your own).

## Requirements

- Node 18+
- Zero dependencies

## Use

```
node src/cli.mjs readiness     examples/probe-healthy.json
node src/cli.mjs schema-drift  examples/snapshot-before.json examples/response-with-breaking-changes.json
node src/cli.mjs config-audit  examples/config-declared.json examples/config-actual.json
```

Each subcommand reads JSON from files or `-` (stdin).

### readiness

Scores a server 0–100 across connectivity, capability inventory, response time,
error rate, schema consistency, and auth posture, with hard-fail conditions,
and returns `install` / `install_with_caution` / `do_not_install`.

### schema-drift

Diffs a new server response against a saved snapshot. Reports added / removed /
type-changed fields; removed fields and type changes are flagged `BREAKING`
(exit 2).

### config-audit

Cross-references your declared MCP config against a server's actual
capabilities: tools you declared that don't exist, tools the server exposes
that you didn't declare, and schema mismatches.

## Scope

You supply the probe data. MCPGuard does **not** connect to servers or run the
probe itself — it's the scoring/diffing layer on top of data you collect (a
`tools/list` call, a few sample invocations, your config file). The
`examples/` folder shows the exact input shapes.

## Test

```
node test.mjs
```

## License

MIT — see [LICENSE](../../LICENSE).
