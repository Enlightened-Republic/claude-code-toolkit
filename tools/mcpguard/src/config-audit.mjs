// MCPGuard v3 — config auditor.
// Cross-references a user's declared MCP config against a server's actual capabilities.
// Flags:
//   - declared tools that the server doesn't expose (config error: typo or removed upstream)
//   - server tools that aren't declared in the user's config (dead capability: configured but unused)
//   - tool schemas that differ between the declaration and the actual server response

/**
 * Audit a config against actual server capabilities.
 *
 * @param {Object} declaredConfig - the user's MCP config (parsed JSON or YAML)
 *   { "mcpServers": { "name": { "command": "...", "args": [...], "tools": [{name, schema}] } } }
 * @param {Object} actualCapabilities - the server's actual exposed tools (from probe)
 *   { "tools": [{name, schema}] }
 * @returns {Object} { issues, deadCapabilities, schemaMismatches, summary }
 */
export function auditConfig(declaredConfig, actualCapabilities) {
  const issues = [];
  const deadCapabilities = [];
  const schemaMismatches = [];

  if (!declaredConfig || !declaredConfig.mcpServers) {
    return { issues: [{ severity: 'error', message: 'no mcpServers in config' }], deadCapabilities, schemaMismatches, summary: { error: true } };
  }

  for (const [serverName, serverCfg] of Object.entries(declaredConfig.mcpServers)) {
    const declaredTools = new Map((serverCfg.tools || []).map(t => [t.name, t]));
    const actualTools = new Map((actualCapabilities?.tools || []).map(t => [t.name, t]));

    // Declared but not in server (config error)
    for (const [name, decl] of declaredTools) {
      if (!actualTools.has(name)) {
        issues.push({
          severity: 'error',
          server: serverName,
          tool: name,
          kind: 'declared_but_missing',
          message: `tool '${name}' is declared in config but not exposed by the server`,
        });
      }
    }

    // In server but not declared (dead capability)
    for (const [name, actual] of actualTools) {
      if (!declaredTools.has(name)) {
        deadCapabilities.push({ server: serverName, tool: name, actualSchema: actual.schema });
        issues.push({
          severity: 'warning',
          server: serverName,
          tool: name,
          kind: 'undeclared_but_present',
          message: `tool '${name}' is exposed by the server but not declared in config — consider declaring or pruning`,
        });
      }
    }

    // Schema mismatches
    for (const [name, decl] of declaredTools) {
      const actual = actualTools.get(name);
      if (!actual) continue;
      const declKeys = Object.keys(decl.schema || {}).sort().join(',');
      const actKeys = Object.keys(actual.schema || {}).sort().join(',');
      if (declKeys !== actKeys) {
        schemaMismatches.push({
          server: serverName,
          tool: name,
          declared: declKeys,
          actual: actKeys,
        });
        issues.push({
          severity: 'warning',
          server: serverName,
          tool: name,
          kind: 'schema_mismatch',
          message: `tool '${name}' schema differs from declaration`,
        });
      }
    }
  }

  return {
    issues,
    deadCapabilities,
    schemaMismatches,
    summary: {
      errorCount: issues.filter(i => i.severity === 'error').length,
      warningCount: issues.filter(i => i.severity === 'warning').length,
      deadCount: deadCapabilities.length,
      schemaMismatchCount: schemaMismatches.length,
    },
  };
}
