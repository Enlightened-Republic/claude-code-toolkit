// CircuitGuard self-test
// Synthesizes three runaway states and one healthy state, runs the detectors
// against each, and asserts the right pattern trips.

import {
  jaccardSimilarity,
  detectSemanticLoop,
  detectCostAnomaly,
  detectToolCallStorm,
  runAllDetectors,
} from './src/patterns.mjs';

let passed = 0;
let failed = 0;

function assert(cond, label) {
  if (cond) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    failed++;
    console.log(`  ❌ ${label}`);
  }
}

console.log('--- jaccardSimilarity ---');
assert(jaccardSimilarity('the cat sat on the mat', 'the cat sat on a mat') > 0.6,
  'similar sentences have high Jaccard');
assert(jaccardSimilarity('hello world', 'goodbye moon') < 0.3,
  'unrelated sentences have low Jaccard');
assert(jaccardSimilarity('', '') === 1,
  'two empty strings are identical');
assert(jaccardSimilarity('hello', '') === 0,
  'one empty string has 0 Jaccard');

console.log('\n--- detectSemanticLoop ---');
// 3 near-identical outputs in a row
const loopOutputs = [
  { text: 'let me check the file contents and report back', timestamp: 1 },
  { text: 'let me check the file contents and report back', timestamp: 2 },
  { text: 'let me check the file contents and report back', timestamp: 3 },
];
assert(detectSemanticLoop(loopOutputs) !== null,
  '3 identical outputs trip the semantic-loop detector');

const diverseOutputs = [
  { text: 'check the file', timestamp: 1 },
  { text: 'compute the average', timestamp: 2 },
  { text: 'write a summary', timestamp: 3 },
];
assert(detectSemanticLoop(diverseOutputs) === null,
  '3 diverse outputs do NOT trip');

const tooFew = [
  { text: 'check the file', timestamp: 1 },
];
assert(detectSemanticLoop(tooFew) === null,
  'fewer than 3 outputs do not trip');

console.log('\n--- detectCostAnomaly ---');
// 5-minute baseline of ~$0.01/min, current $0.05/min
const baseline = [
  [1, 0.01], [2, 0.012], [3, 0.009], [4, 0.011], [5, 0.01]
];
assert(detectCostAnomaly(baseline, 0.05, 2) !== null,
  '5x baseline trips cost anomaly');
assert(detectCostAnomaly(baseline, 0.015, 2) === null,
  '1.5x baseline does NOT trip');
assert(detectCostAnomaly(baseline, 0.001, 2) === null,
  'way below baseline does not trip');
assert(detectCostAnomaly(null, 0.05) === null,
  'no baseline = no trip (need history)');

console.log('\n--- detectToolCallStorm ---');
const now = Date.now();
// 12 calls to 'exec' in the last 60s, only 1 produced state change
const stormCalls = Array.from({ length: 12 }, (_, i) => ({
  tool: 'exec',
  timestamp: now - i * 4000,  // every 4s for 48s
  stateChanged: i === 0,  // only the first one
}));
assert(detectToolCallStorm(stormCalls) !== null,
  '12 same-tool calls in 60s with 1/12 state change trips');
assert(detectToolCallStorm(stormCalls).tool === 'exec',
  'trip identifies the storming tool');

// 12 calls to 'exec' but ALL produced state change — not a storm
const productiveCalls = Array.from({ length: 12 }, (_, i) => ({
  tool: 'exec',
  timestamp: now - i * 4000,
  stateChanged: true,
}));
assert(detectToolCallStorm(productiveCalls) === null,
  '12 productive calls do NOT trip');

// Calls to different tools — not a storm
const mixedCalls = Array.from({ length: 20 }, (_, i) => ({
  tool: ['exec', 'read', 'write'][i % 3],
  timestamp: now - i * 3000,
  stateChanged: true,
}));
assert(detectToolCallStorm(mixedCalls) === null,
  '20 mixed-tool calls do NOT trip (no single-tool storm)');

// Calls older than 60s
const oldCalls = Array.from({ length: 20 }, (_, i) => ({
  tool: 'exec',
  timestamp: now - 120000 - i * 1000,  // all > 60s old
  stateChanged: false,
}));
assert(detectToolCallStorm(oldCalls) === null,
  'old calls (outside window) do NOT trip');

console.log('\n--- runAllDetectors ---');
const healthyState = {
  currentCostUsd: 0.01,
  costPerMinute: baseline,
  recentOutputs: diverseOutputs,
  recentToolCalls: mixedCalls,
};
assert(runAllDetectors(healthyState) === null,
  'healthy state has no trip');

const runawayState = {
  currentCostUsd: 0.10,
  costPerMinute: baseline,
  recentOutputs: loopOutputs,
  recentToolCalls: stormCalls,
};
const trip = runAllDetectors(runawayState);
assert(trip !== null, 'runaway state trips');
assert(['cost_anomaly', 'tool_call_storm', 'semantic_loop'].includes(trip.type),
  `trip type is one of the three (got ${trip && trip.type})`);

console.log(`\n--- summary: ${passed} passed, ${failed} failed ---`);
process.exit(failed === 0 ? 0 : 1);
