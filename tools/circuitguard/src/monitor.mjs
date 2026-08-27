// CircuitGuard monitor — a sidecar that watches the agent's state and trips on runaway patterns.
// Reads state from a JSON file (or stdin, for testing), runs detectors, writes alerts.
//
// Usage:
//   node tools/circuitguard/src/monitor.mjs --check state.json     # one-shot check
//   node tools/circuitguard/src/monitor.mjs --watch state.json     # poll every N seconds
//   node tools/circuitguard/src/monitor.mjs --alert-on-trip "..." # telegram webhook etc
//
// State file shape (JSON):
// {
//   "currentCostUsd": 0.04,
//   "costPerMinute": [[1700000000000, 0.03], ...],
//   "recentOutputs": [{ "text": "...", "timestamp": 1700000000000 }, ...],
//   "recentToolCalls": [{ "tool": "exec", "timestamp": 1700000000000, "stateChanged": true }, ...]
// }

import { readFileSync, writeFileSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { runAllDetectors } from './patterns.mjs';

// State + alert log live outside the package so a global/read-only install works.
// Override with CIRCUITGUARD_HOME.
const STATE_DIR = process.env.CIRCUITGUARD_HOME || resolve(homedir(), '.circuitguard');
try { mkdirSync(STATE_DIR, { recursive: true }); } catch { /* best effort */ }

const ALERT_LOG = resolve(STATE_DIR, 'alerts.log');
const TRIP_STATE = resolve(STATE_DIR, 'trip-state.json');

const DEFAULTS = {
  pollIntervalMs: 5000,
  cooldownMs: 60000,         // don't re-trip on the same pattern within 60s
  similarityThreshold: 0.85,
  costMultiplier: 2,
  stormCountThreshold: 10,
  stormWindowMs: 60000,
};

function readState(path) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    return null;
  }
}

function readTripState() {
  if (!existsSync(TRIP_STATE)) return {};
  try {
    return JSON.parse(readFileSync(TRIP_STATE, 'utf8'));
  } catch (e) {
    return {};
  }
}

function writeTripState(state) {
  writeFileSync(TRIP_STATE, JSON.stringify(state, null, 2));
}

function logAlert(trip) {
  const line = `[${new Date().toISOString()}] TRIP type=${trip.type} severity=${trip.severity} message="${trip.message}"\n`;
  try {
    appendFileSync(ALERT_LOG, line);
  } catch (e) {
    // best-effort logging
  }
  return line.trim();
}

function isInCooldown(tripKey, tripState, cooldownMs) {
  const last = tripState[tripKey];
  if (!last) return false;
  return (Date.now() - last) < cooldownMs;
}

function markTripped(tripKey) {
  const state = readTripState();
  state[tripKey] = Date.now();
  writeTripState(state);
}

/**
 * One check against a state object. Returns a Trip object or null.
 */
export function check(state, opts = {}) {
  const o = { ...DEFAULTS, ...opts };
  if (!state) return null;

  const trip = runAllDetectors(state);
  if (!trip) return null;

  const tripKey = `${trip.type}:${trip.tool || ''}`;
  if (isInCooldown(tripKey, readTripState(), o.cooldownMs)) {
    return null; // already alerted recently
  }

  markTripped(tripKey);
  logAlert(trip);
  return trip;
}

/**
 * Build a soft-pause message for the LLM. This is what gets injected into
 * the next turn so the LLM knows to stop and reassess.
 */
export function buildSoftPauseMessage(trip) {
  const actions = [
    '1. Take a different approach.',
    '2. Ask the human for direction.',
    '3. Stop and report what you have.',
  ];

  return `[CIRCUITGUARD TRIP] ${trip.message}\n\n` +
    `You appear to be repeating yourself or burning budget without progress. ` +
    `Pause and pick one of these:\n${actions.join('\n')}\n\n` +
    `Type the number, or just describe what you actually want to do next.`;
}

// ============================================================================
// CLI
// ============================================================================

function parseArgs(argv) {
  const args = { watch: false, check: false, json: false, interval: DEFAULTS.pollIntervalMs, state: null, alertOnTrip: null };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--check') { args.check = true; args.state = argv[++i]; }
    else if (a === '--watch') { args.watch = true; args.state = argv[++i]; }
    else if (a === '--interval') { args.interval = parseInt(argv[++i], 10); }
    else if (a === '--json') { args.json = true; }
    else if (a === '--alert-on-trip') { args.alertOnTrip = argv[++i]; }
    else if (a === '--build-soft-pause') {
      // dev helper: read a trip JSON from stdin and print the soft-pause message
      const trip = JSON.parse(readFileSync(0, 'utf8'));
      process.stdout.write(buildSoftPauseMessage(trip) + '\n');
      process.exit(0);
    }
  }
  return args;
}

async function sendAlert(trip, target) {
  // POST the trip + soft-pause message to a webhook (Slack-compatible `text` field).
  if (!target) return;
  try {
    const body = JSON.stringify({ text: buildSoftPauseMessage(trip), trip });
    const res = await fetch(target, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
    });
    if (!res.ok) console.error(`[circuitguard] alert POST ${res.status} to ${target}`);
  } catch (e) {
    console.error(`[circuitguard] alert POST failed: ${e.message}`);
  }
}

async function main() {
  const args = parseArgs(process.argv);

  if (!args.state) {
    console.error('usage: monitor.mjs --check <state.json> | --watch <state.json> [--interval ms]');
    process.exit(1);
  }

  const statePath = resolve(args.state);

  if (args.check) {
    const state = readState(statePath);
    const trip = check(state);
    if (args.json) {
      process.stdout.write(JSON.stringify(trip || { ok: true }) + '\n');
    } else if (trip) {
      process.stdout.write(`TRIP: ${trip.type}\n${trip.message}\n`);
      await sendAlert(trip, args.alertOnTrip);
    } else {
      process.stdout.write('OK\n');
    }
    process.exit(trip ? 0 : 0);
  }

  if (args.watch) {
    console.error(`[circuitguard] watching ${statePath} every ${args.interval}ms`);
    const loop = async () => {
      const state = readState(statePath);
      const trip = check(state);
      if (trip) {
        console.log(`[${new Date().toISOString()}] TRIP: ${trip.type} — ${trip.message}`);
        await sendAlert(trip, args.alertOnTrip);
      }
    };
    setInterval(loop, args.interval);
    // run once immediately
    await loop();
  }
}

// Only run main if invoked directly (not when imported). pathToFileURL handles
// Windows drive letters, POSIX paths, and spaces correctly.
const isMain = process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isMain) {
  main().catch(e => {
    console.error('FATAL:', e);
    process.exit(1);
  });
}
