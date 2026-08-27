// MCPGuard v3 — schema-drift detection.
// Snapshots server response shapes, compares on subsequent runs,
// alerts on missing fields, type changes, or new required fields.
// Tolerates forward-compatible additions (new optional fields).

/**
 * Compute the schema (set of keys + their types) of an object.
 */
export function shapeOf(obj) {
  if (obj === null || typeof obj !== 'object') return { _type: typeof obj };
  const shape = {};
  for (const [k, v] of Object.entries(obj)) {
    shape[k] = v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v;
  }
  return shape;
}

/**
 * Normalize a snapshot: array of {key: type} entries, sorted by key.
 */
export function normalizeShape(shape) {
  return Object.entries(shape)
    .map(([k, t]) => ({ key: k, type: t }))
    .sort((a, b) => a.key.localeCompare(b.key));
}

/**
 * Take a snapshot of multiple response shapes.
 * Returns the canonical shape (most common across samples) and any anomalies.
 */
export function snapshot(responses) {
  if (!responses || responses.length === 0) return { canonical: null, anomalies: [] };

  const shapes = responses.map(r => normalizeShape(shapeOf(r)));
  const counts = new Map();
  for (const s of shapes) {
    const key = JSON.stringify(s);
    counts.set(key, (counts.get(key) || 0) + 1);
  }

  let canonicalKey = null;
  let maxCount = 0;
  for (const [k, c] of counts) {
    if (c > maxCount) { maxCount = c; canonicalKey = k; }
  }
  const canonical = JSON.parse(canonicalKey);

  return {
    canonical,
    sampleCount: responses.length,
    uniqueShapeCount: counts.size,
    consensusRatio: maxCount / responses.length,
  };
}

/**
 * Compare a new response against a saved snapshot.
 * Returns { drift, added, removed, typeChanged, isBreaking }.
 */
export function diff(snapshotCanonical, newResponse) {
  if (!snapshotCanonical) {
    return { drift: false, added: [], removed: [], typeChanged: [], isBreaking: false, reason: 'no_baseline' };
  }
  const newShape = normalizeShape(shapeOf(newResponse));
  const baseline = new Map(snapshotCanonical.map(s => [s.key, s.type]));

  const added = [];
  const removed = [];
  const typeChanged = [];

  for (const { key, type } of newShape) {
    if (!baseline.has(key)) {
      added.push({ key, type });
    } else if (baseline.get(key) !== type) {
      typeChanged.push({ key, from: baseline.get(key), to: type });
    }
  }
  for (const { key, type } of snapshotCanonical) {
    if (!newShape.find(s => s.key === key)) {
      removed.push({ key, type });
    }
  }

  // Forward-compatible: new optional fields are fine.
  // Breaking: removed fields, type changes, OR new fields (if server treats them as required).
  // We don't know which new fields are required, so we WARN on new fields.
  const isBreaking = removed.length > 0 || typeChanged.length > 0;

  return {
    drift: added.length > 0 || removed.length > 0 || typeChanged.length > 0,
    added,
    removed,
    typeChanged,
    isBreaking,
    addedCount: added.length,
    removedCount: removed.length,
    typeChangedCount: typeChanged.length,
  };
}

/**
 * Format a drift report for human reading.
 */
export function formatDrift(diffResult) {
  if (!diffResult.drift) return 'no drift detected';
  const lines = [];
  if (diffResult.added.length) {
    lines.push(`+ ADDED ${diffResult.added.length} field(s): ${diffResult.added.map(f => `${f.key}:${f.type}`).join(', ')}`);
  }
  if (diffResult.removed.length) {
    lines.push(`- REMOVED ${diffResult.removed.length} field(s): ${diffResult.removed.map(f => `${f.key}:${f.type}`).join(', ')} [BREAKING]`);
  }
  if (diffResult.typeChanged.length) {
    lines.push(`~ CHANGED ${diffResult.typeChanged.length} field(s): ${diffResult.typeChanged.map(f => `${f.key}: ${f.from} -> ${f.to}`).join(', ')} [BREAKING]`);
  }
  return lines.join('\n');
}
