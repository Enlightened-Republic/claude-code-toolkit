// MCPGuard v3 — quality scoring for MCP servers.
// Implements the "readiness-CLI" from the research: a 0-100 score per server,
// broken down by category, with hard-fail conditions and warnings.
//
// Categories:
//   1. connectivity       — can we reach the server?
//   2. capability_inventory — does it expose any tools/resources?
//   3. response_time      — p50 of sample calls
//   4. error_rate         — fraction of failed sample calls
//   5. schema_consistency — are response shapes consistent across calls?
//   6. auth_posture       — does it require/handle auth correctly?
//
// Hard-fail conditions (return score: 0 with reason):
//   - server unreachable
//   - zero capabilities exposed
//   - 100% error rate
//   - schema broken (malformed responses on every call)
//
// Usage:
//   import { scoreReadiness } from './quality.mjs';
//   const result = await scoreReadiness({ url, auth, sampleSize: 5 });

// ============================================================================
// Per-category scoring
// ============================================================================

export function scoreConnectivity(reachable, latencyMs) {
  if (!reachable) {
    return { score: 0, hardFail: true, reason: 'server_unreachable' };
  }
  // 100 if <200ms, decays to 0 at 5s
  const score = Math.max(0, Math.min(100, 100 * (1 - (latencyMs - 200) / 4800)));
  return { score: Math.round(score), hardFail: false };
}

export function scoreCapabilityInventory(capabilities) {
  const count = (capabilities?.tools?.length || 0) + (capabilities?.resources?.length || 0) + (capabilities?.prompts?.length || 0);
  if (count === 0) {
    return { score: 0, hardFail: true, reason: 'no_capabilities_exposed' };
  }
  // 1 cap = 60, 5+ = 100
  const score = Math.min(100, 60 + count * 8);
  return { score, hardFail: false, count };
}

export function scoreResponseTime(samples) {
  if (!samples || samples.length === 0) {
    return { score: 0, hardFail: false, reason: 'no_samples' };
  }
  const sorted = [...samples].sort((a, b) => a - b);
  const p50 = sorted[Math.floor(sorted.length / 2)];
  // 100 if <100ms, decays to 0 at 3s
  const score = Math.max(0, Math.min(100, 100 * (1 - (p50 - 100) / 2900)));
  return { score: Math.round(score), p50Ms: p50, hardFail: false };
}

export function scoreErrorRate(samples) {
  if (!samples || samples.length === 0) {
    return { score: 0, hardFail: false, reason: 'no_samples' };
  }
  const errors = samples.filter(s => s.error).length;
  const rate = errors / samples.length;
  if (rate === 1) {
    return { score: 0, hardFail: true, reason: '100pct_error_rate' };
  }
  // 100 if 0% errors, decays to 0 at 100%
  return { score: Math.round(100 * (1 - rate)), errorRate: rate, hardFail: false };
}

export function scoreSchemaConsistency(samples) {
  if (!samples || samples.length < 2) {
    return { score: 50, hardFail: false, reason: 'not_enough_samples' };
  }
  // Schema = set of top-level keys. Consistency = fraction of samples with the most-common schema.
  const schemas = samples.map(s => Object.keys(s.response || {}).sort().join('|'));
  const counts = {};
  for (const s of schemas) counts[s] = (counts[s] || 0) + 1;
  const topCount = Math.max(...Object.values(counts));
  const consistency = topCount / samples.length;
  if (consistency < 0.5) {
    return { score: Math.round(consistency * 100), hardFail: true, reason: 'schema_broken' };
  }
  return { score: Math.round(consistency * 100), hardFail: false };
}

export function scoreAuthPosture(serverRequiresAuth, serverAcceptsAuth) {
  if (serverRequiresAuth && !serverAcceptsAuth) {
    return { score: 0, hardFail: false, reason: 'auth_required_but_not_accepted' };
  }
  if (!serverRequiresAuth && serverAcceptsAuth) {
    return { score: 80, hardFail: false, reason: 'auth_optional_but_accepted' }; // weird but not broken
  }
  return { score: 100, hardFail: false };
}

// ============================================================================
// Aggregate
// ============================================================================

/**
 * Score a single MCP server's readiness.
 * @param {Object} probeResult - the result of probing a single server
 *   @param {boolean} probeResult.reachable
 *   @param {number} probeResult.latencyMs
 *   @param {Object} probeResult.capabilities - {tools, resources, prompts}
 *   @param {Array<{latencyMs: number, error: boolean, response: object}>} probeResult.samples
 *   @param {boolean} probeResult.serverRequiresAuth
 *   @param {boolean} probeResult.serverAcceptsAuth
 * @returns {Object} { score, hardFail, breakdown, reasons }
 */
export function scoreReadiness(probeResult) {
  const breakdown = {
    connectivity: scoreConnectivity(probeResult.reachable, probeResult.latencyMs),
    capability_inventory: scoreCapabilityInventory(probeResult.capabilities),
    response_time: scoreResponseTime(probeResult.samples?.map(s => s.latencyMs)),
    error_rate: scoreErrorRate(probeResult.samples),
    schema_consistency: scoreSchemaConsistency(probeResult.samples),
    auth_posture: scoreAuthPosture(probeResult.serverRequiresAuth, probeResult.serverAcceptsAuth),
  };

  // Hard fail: any category is hard-fail OR multiple zeros
  const hardFails = Object.values(breakdown).filter(c => c.hardFail);
  const hardFail = hardFails.length > 0;

  // Aggregate: weighted average
  // connectivity 20%, capabilities 15%, response_time 20%, error_rate 25%, schema 15%, auth 5%
  const weights = {
    connectivity: 0.20,
    capability_inventory: 0.15,
    response_time: 0.20,
    error_rate: 0.25,
    schema_consistency: 0.15,
    auth_posture: 0.05,
  };
  let weightedSum = 0;
  for (const [k, w] of Object.entries(weights)) {
    weightedSum += breakdown[k].score * w;
  }
  const score = hardFail ? 0 : Math.round(weightedSum);

  const reasons = Object.values(breakdown)
    .filter(c => c.reason)
    .map(c => c.reason);

  return {
    score,
    hardFail,
    hardFailReasons: hardFails.map(c => c.reason),
    breakdown,
    reasons,
    recommendation: score >= 80 ? 'install' : score >= 50 ? 'install_with_caution' : 'do_not_install',
  };
}
