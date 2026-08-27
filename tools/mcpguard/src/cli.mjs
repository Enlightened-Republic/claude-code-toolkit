// MCPGuard v3 — CLI.
// Implements `mcpg readiness`, `mcpg schema-drift`, `mcpg config-audit`.
// Reads probe data from JSON files (or stdin) — actual probing is out of scope for v0.1.
//
// Usage:
//   node mcpg.mjs readiness <probe.json>
//   node mcpg.mjs schema-drift <snapshot.json> <new-response.json>
//   node mcpg.mjs config-audit <declared-config.json> <actual-capabilities.json>

import { readFileSync, existsSync } from 'node:fs';
import { scoreReadiness } from './quality.mjs';
import { snapshot, diff, formatDrift } from './schema-drift.mjs';
import { auditConfig } from './config-audit.mjs';

function readJsonOrStdin(p) {
  if (p === '-' || !p) {
    return JSON.parse(readFileSync(0, 'utf8'));
  }
  if (!existsSync(p)) {
    console.error(`file not found: ${p}`);
    process.exit(1);
  }
  return JSON.parse(readFileSync(p, 'utf8'));
}

function printReadiness(result) {
  console.log(`\nMCP Readiness Score: ${result.score}/100`);
  if (result.hardFail) {
    console.log(`HARD FAIL: ${result.hardFailReasons.join(', ')}`);
  }
  console.log(`Recommendation: ${result.recommendation.toUpperCase()}\n`);
  console.log('Breakdown:');
  for (const [category, data] of Object.entries(result.breakdown)) {
    const flag = data.hardFail ? ' [HARD FAIL]' : '';
    console.log(`  ${category.padEnd(22)} ${String(data.score).padStart(3)}/100${flag}`);
  }
  if (result.reasons.length > 0) {
    console.log(`\nReasons: ${result.reasons.join(', ')}`);
  }
}

function printDrift(result) {
  console.log(formatDrift(result));
  if (result.isBreaking) {
    console.log('\n*** BREAKING CHANGES DETECTED ***');
    process.exit(2);
  }
}

function printAudit(result) {
  console.log(`\nMCP Config Audit`);
  console.log(`Errors:   ${result.summary.errorCount || 0}`);
  console.log(`Warnings: ${result.summary.warningCount || 0}`);
  console.log(`Dead:     ${result.summary.deadCount || 0}`);
  console.log(`Schemas:  ${result.summary.schemaMismatchCount || 0}\n`);
  if (result.issues.length > 0) {
    console.log('Issues:');
    for (const issue of result.issues) {
      console.log(`  [${issue.severity.toUpperCase()}] ${issue.message}`);
    }
  }
  if (result.deadCapabilities.length > 0) {
    console.log('\nDead capabilities (server exposes, config does not declare):');
    for (const dead of result.deadCapabilities) {
      console.log(`  - ${dead.server}/${dead.tool}`);
    }
  }
  if (result.schemaMismatches.length > 0) {
    console.log('\nSchema mismatches:');
    for (const m of result.schemaMismatches) {
      console.log(`  - ${m.server}/${m.tool}: declared=[${m.declared}] actual=[${m.actual}]`);
    }
  }
}

function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];

  if (argv.includes('--help') || argv.includes('-h') || !cmd) {
    console.log(`MCPGuard v3 — MCP server quality CLI

Usage:
  mcpg readiness <probe.json>
  mcpg schema-drift <snapshot.json> <new-response.json>
  mcpg config-audit <declared-config.json> <actual-capabilities.json>

Subcommands read JSON from files or stdin (-).`);
    process.exit(0);
  }

  try {
    switch (cmd) {
      case 'readiness': {
        const probe = readJsonOrStdin(argv[1]);
        printReadiness(scoreReadiness(probe));
        break;
      }
      case 'schema-drift': {
        const snap = readJsonOrStdin(argv[1]);
        const newResp = readJsonOrStdin(argv[2]);
        const d = diff(snap.canonical, newResp);
        printDrift(d);
        break;
      }
      case 'config-audit': {
        const decl = readJsonOrStdin(argv[1]);
        const act = readJsonOrStdin(argv[2]);
        printAudit(auditConfig(decl, act));
        break;
      }
      default:
        console.error(`unknown subcommand: ${cmd}`);
        process.exit(1);
    }
  } catch (e) {
    console.error(`error: ${e.message}`);
    process.exit(1);
  }
}

main();
