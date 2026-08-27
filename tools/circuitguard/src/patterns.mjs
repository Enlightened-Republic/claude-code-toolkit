// CircuitGuard pattern detection algorithms
// Three runaway patterns: semantic loop, cost anomaly, tool-call storm.
// Each is pure: takes a state slice, returns a Trip | null result.

// ============================================================================
// 1. SEMANTIC LOOP
//    3+ near-identical LLM outputs in a rolling window
// ============================================================================

/**
 * Jaccard token similarity between two strings.
 * Cheap, no LLM, good enough for loop detection.
 */
export function jaccardSimilarity(a, b) {
  if (!a && !b) return 1; // both empty = identical
  if (!a || !b) return 0;
  const tokensA = new Set(
    a.toLowerCase().split(/\W+/).filter(t => t.length > 2)
  );
  const tokensB = new Set(
    b.toLowerCase().split(/\W+/).filter(t => t.length > 2)
  );
  if (tokensA.size === 0 && tokensB.size === 0) return 1; // both empty
  const intersection = new Set([...tokensA].filter(t => tokensB.has(t)));
  const union = new Set([...tokensA, ...tokensB]);
  return union.size === 0 ? 0 : intersection.size / union.size;
}

/**
 * Trip on 3+ near-identical outputs in a rolling window.
 * "Near-identical" = adjacent pair Jaccard > 0.85.
 *
 * @param {Array<{text: string, timestamp: number}>} recentOutputs
 * @param {number} similarityThreshold
 * @param {number} requiredSimilarPairs
 * @returns {Trip|null}
 */
export function detectSemanticLoop(
  recentOutputs,
  similarityThreshold = 0.85,
  requiredSimilarPairs = 2  // 2 similar pairs = 3 consecutive near-identical
) {
  if (!recentOutputs || recentOutputs.length < 3) return null;

  let similarPairs = 0;
  const comparisons = [];
  for (let i = 1; i < recentOutputs.length; i++) {
    const sim = jaccardSimilarity(recentOutputs[i].text, recentOutputs[i - 1].text);
    comparisons.push({ i, sim });
    if (sim > similarityThreshold) similarPairs++;
  }

  if (similarPairs >= requiredSimilarPairs) {
    return {
      type: 'semantic_loop',
      severity: 'high',
      similarPairs,
      totalComparisons: comparisons.length,
      threshold: similarityThreshold,
      message: `agent produced ${similarPairs + 1} near-identical outputs in a row (Jaccard > ${similarityThreshold})`,
    };
  }
  return null;
}

// ============================================================================
// 2. COST ANOMALY
//    Per-minute cost > 2x rolling baseline
// ============================================================================

/**
 * Trip on per-minute cost > 2x baseline.
 *
 * @param {Array<[timestamp, costUsd]>} perMinuteCosts - last N minutes
 * @param {number} currentCost - this minute's cost so far
 * @param {number} multiplier - trip threshold (default 2x)
 * @returns {Trip|null}
 */
export function detectCostAnomaly(perMinuteCosts, currentCost, multiplier = 2) {
  if (!perMinuteCosts || perMinuteCosts.length < 5) return null; // need baseline

  const baselineValues = perMinuteCosts.map(([, c]) => c).sort((a, b) => a - b);
  const median = baselineValues[Math.floor(baselineValues.length / 2)];

  if (currentCost > median * multiplier && currentCost > 0.01) {  // noise floor: 1 cent
    return {
      type: 'cost_anomaly',
      severity: 'high',
      currentCost,
      baselineMedian: median,
      multiplier: currentCost / median,
      message: `current minute's cost ($${currentCost.toFixed(4)}) is ${(currentCost / median).toFixed(1)}x the baseline ($${median.toFixed(4)})`,
    };
  }
  return null;
}

// ============================================================================
// 3. TOOL-CALL STORM
//    Same tool 10+ times in 60s with <10% state-change
// ============================================================================

/**
 * Trip on same-tool-call storm.
 *
 * @param {Array<{tool: string, timestamp: number, stateChanged: boolean}>} recentCalls
 * @param {number} countThreshold - default 10
 * @param {number} windowMs - default 60000
 * @param {number} stateChangeRatioMax - default 0.1 (10% of calls must produce state change)
 * @returns {Trip|null}
 */
export function detectToolCallStorm(
  recentCalls,
  countThreshold = 10,
  windowMs = 60000,
  stateChangeRatioMax = 0.1
) {
  if (!recentCalls || recentCalls.length === 0) return null;

  const now = Date.now();
  const windowStart = now - windowMs;
  const inWindow = recentCalls.filter(c => c.timestamp >= windowStart);

  // Group by tool
  const byTool = {};
  for (const call of inWindow) {
    if (!byTool[call.tool]) byTool[call.tool] = [];
    byTool[call.tool].push(call);
  }

  for (const [tool, calls] of Object.entries(byTool)) {
    if (calls.length < countThreshold) continue;
    const stateChanged = calls.filter(c => c.stateChanged).length;
    const ratio = stateChanged / calls.length;
    if (ratio < stateChangeRatioMax) {
      return {
        type: 'tool_call_storm',
        severity: 'high',
        tool,
        count: calls.length,
        windowMs,
        stateChangeRatio: ratio,
        message: `tool '${tool}' called ${calls.length} times in ${windowMs / 1000}s with only ${(ratio * 100).toFixed(0)}% producing state change`,
      };
    }
  }
  return null;
}

// ============================================================================
// Aggregate check
// ============================================================================

/**
 * Run all detectors against a state slice.
 * Returns the first trip (priority order: cost > storm > loop).
 */
export function runAllDetectors(state) {
  const checks = [
    [detectCostAnomaly, [state.costPerMinute, state.currentCostUsd, 2]],
    [detectToolCallStorm, [state.recentToolCalls, 10, 60000, 0.1]],
    [detectSemanticLoop, [state.recentOutputs, 0.85, 2]],
  ];

  for (const [fn, args] of checks) {
    try {
      const trip = fn(...args);
      if (trip) return trip;
    } catch (e) {
      // don't let a bad detector crash the whole check
      // (in production, would log to state.errors)
    }
  }
  return null;
}
