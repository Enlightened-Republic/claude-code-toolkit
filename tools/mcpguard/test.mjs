// MCPGuard v3 self-test
import {
  scoreConnectivity,
  scoreCapabilityInventory,
  scoreResponseTime,
  scoreErrorRate,
  scoreSchemaConsistency,
  scoreAuthPosture,
  scoreReadiness,
} from './src/quality.mjs';
import { shapeOf, normalizeShape, snapshot, diff, formatDrift } from './src/schema-drift.mjs';
import { auditConfig } from './src/config-audit.mjs';

let passed = 0, failed = 0;
function assert(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}

// ============================================================================
// readiness
// ============================================================================
console.log('--- scoreConnectivity ---');
assert(scoreConnectivity(false, 0).hardFail === true, 'unreachable is a hard fail');
assert(scoreConnectivity(true, 100).score >= 90, 'fast reachable is high score');
assert(scoreConnectivity(true, 6000).score <= 5, 'very slow reachable is low score');

console.log('\n--- scoreCapabilityInventory ---');
assert(scoreCapabilityInventory({ tools: [], resources: [], prompts: [] }).hardFail === true, 'no capabilities = hard fail');
assert(scoreCapabilityInventory({ tools: [{ name: 'a' }] }).score > 50, '1 cap = decent score');
assert(scoreCapabilityInventory({ tools: Array(20).fill({ name: 'x' }) }).score === 100, '20 caps = 100');

console.log('\n--- scoreResponseTime ---');
assert(scoreResponseTime([100, 200, 150]).p50Ms === 150, 'p50 computed correctly');
assert(scoreResponseTime([10, 20, 30]).score >= 95, 'fast = high score');
assert(scoreResponseTime([5000]).score <= 5, 'slow = low score');
assert(scoreResponseTime([]).score === 0, 'no samples = 0');

console.log('\n--- scoreErrorRate ---');
assert(scoreErrorRate([{ error: true }, { error: true }]).hardFail === true, '100% errors = hard fail');
assert(scoreErrorRate([{ error: false }, { error: false }]).score === 100, '0% errors = 100');
assert(scoreErrorRate([{ error: true }, { error: false }]).score === 50, '50% errors = 50');

console.log('\n--- scoreSchemaConsistency ---');
const consistent = [
  { response: { a: 1, b: 2 } },
  { response: { a: 3, b: 4 } },
  { response: { a: 5, b: 6 } },
];
assert(scoreSchemaConsistency(consistent).score === 100, 'consistent schemas = 100');
const inconsistent = [
  { response: { a: 1 } },
  { response: { b: 2 } },
  { response: { c: 3 } },
];
assert(scoreSchemaConsistency(inconsistent).hardFail === true, 'no consensus = hard fail');
const oneOff = [
  { response: { a: 1 } },
  { response: { a: 2 } },
  { response: { b: 3 } },
];
assert(scoreSchemaConsistency(oneOff).score === 67, '2/3 consensus ≈ 67');

console.log('\n--- scoreAuthPosture ---');
assert(scoreAuthPosture(true, false).score === 0, 'auth required but not accepted = 0');
assert(scoreAuthPosture(false, true).score === 80, 'auth optional but accepted = 80');
assert(scoreAuthPosture(false, false).score === 100, 'no auth on either side = 100');
assert(scoreAuthPosture(true, true).score === 100, 'auth required and accepted = 100');

console.log('\n--- scoreReadiness (aggregate) ---');
const healthyServer = {
  reachable: true,
  latencyMs: 100,
  capabilities: { tools: [{ name: 'a' }, { name: 'b' }, { name: 'c' }], resources: [], prompts: [] },
  samples: [
    { latencyMs: 100, error: false, response: { a: 1, b: 2 } },
    { latencyMs: 150, error: false, response: { a: 3, b: 4 } },
    { latencyMs: 120, error: false, response: { a: 5, b: 6 } },
  ],
  serverRequiresAuth: false,
  serverAcceptsAuth: false,
};
const r1 = scoreReadiness(healthyServer);
assert(r1.score >= 70 && r1.score <= 100, `healthy server scores high (got ${r1.score})`);
assert(r1.hardFail === false, 'healthy server is not a hard fail');
assert(r1.recommendation === 'install', 'healthy server → install');

const badServer = {
  reachable: false, latencyMs: 0, capabilities: null, samples: [], serverRequiresAuth: false, serverAcceptsAuth: false,
};
const r2 = scoreReadiness(badServer);
assert(r2.score === 0, 'unreachable server scores 0');
assert(r2.hardFail === true, 'unreachable server is a hard fail');
assert(r2.recommendation === 'do_not_install', 'unreachable server → do_not_install');

const mediocreServer = {
  reachable: true, latencyMs: 800,
  capabilities: { tools: [{ name: 'a' }], resources: [], prompts: [] },
  samples: [
    { latencyMs: 800, error: false, response: { result: 'x' } },
    { latencyMs: 900, error: true, response: {} },
  ],
  serverRequiresAuth: false, serverAcceptsAuth: false,
};
const r3 = scoreReadiness(mediocreServer);
assert(r3.recommendation === 'install_with_caution' || r3.recommendation === 'do_not_install',
  `mediocre server gets install_with_caution or do_not_install (got ${r3.recommendation})`);

// ============================================================================
// schema-drift
// ============================================================================
console.log('\n--- shapeOf / normalizeShape ---');
assert(JSON.stringify(normalizeShape(shapeOf({ a: 1, b: 'x', c: true }))) ===
  JSON.stringify([{ key: 'a', type: 'number' }, { key: 'b', type: 'string' }, { key: 'c', type: 'boolean' }]),
  'shapeOf captures types');
assert(normalizeShape(shapeOf({ a: [1, 2, 3] }))[0].type === 'array', 'arrays detected');
assert(normalizeShape(shapeOf({ a: null }))[0].type === 'null', 'null detected');

console.log('\n--- snapshot ---');
const s = snapshot([
  { a: 1, b: 2 },
  { a: 3, b: 4 },
  { a: 5, b: 6 },
]);
assert(s.canonical.length === 2, 'snapshot canonical has 2 fields');
assert(s.consensusRatio === 1, 'snapshot consensus is 1.0 for uniform shapes');

console.log('\n--- diff ---');
const baseline = snapshot([{ a: 1, b: 2, c: 3 }]).canonical;
const addedOnly = diff(baseline, { a: 1, b: 2, c: 3, d: 4 });
assert(addedOnly.added.length === 1, 'new optional field detected');
assert(addedOnly.isBreaking === false, 'new optional field is NOT breaking');

const removedOne = diff(baseline, { a: 1, b: 2 });
assert(removedOne.removed.length === 1, 'removed field detected');
assert(removedOne.isBreaking === true, 'removed field IS breaking');

const typeChange = diff(baseline, { a: 'string', b: 2, c: 3 });
assert(typeChange.typeChanged.length === 1, 'type change detected');
assert(typeChange.isBreaking === true, 'type change IS breaking');

const noChange = diff(baseline, { a: 99, b: 99, c: 99 });
assert(noChange.drift === false, 'no drift when only values change');

const formatOutput = formatDrift(removedOne);
assert(formatOutput.includes('REMOVED') && formatOutput.includes('BREAKING'),
  'formatDrift output includes REMOVED and BREAKING');

// ============================================================================
// config-audit
// ============================================================================
console.log('\n--- auditConfig ---');
const empty = auditConfig(null, null);
assert(empty.issues[0].severity === 'error', 'no config = error');

const cleanConfig = {
  mcpServers: {
    'fs-server': {
      command: 'mcp-fs',
      tools: [{ name: 'read_file', schema: { path: 'string' } }],
    },
  },
};
const matchingActual = {
  tools: [{ name: 'read_file', schema: { path: 'string' } }],
};
const clean = auditConfig(cleanConfig, matchingActual);
assert(clean.issues.length === 0, 'clean config has no issues');
assert(clean.deadCapabilities.length === 0, 'clean config has no dead caps');

const declaredButMissing = auditConfig(cleanConfig, { tools: [] });
assert(declaredButMissing.issues.some(i => i.kind === 'declared_but_missing'),
  'missing tool is flagged');

const undeclared = auditConfig(cleanConfig, {
  tools: [
    { name: 'read_file', schema: { path: 'string' } },
    { name: 'write_file', schema: { path: 'string', content: 'string' } },
  ],
});
assert(undeclared.deadCapabilities.length === 1, 'undeclared tool = 1 dead cap');
assert(undeclared.issues.some(i => i.kind === 'undeclared_but_present'),
  'undeclared tool is flagged');

const schemaMismatch = auditConfig(cleanConfig, {
  tools: [{ name: 'read_file', schema: { path: 'string', encoding: 'string' } }],
});
assert(schemaMismatch.schemaMismatches.length === 1, 'schema mismatch detected');

console.log(`\n--- summary: ${passed} passed, ${failed} failed ---`);
process.exit(failed === 0 ? 0 : 1);
