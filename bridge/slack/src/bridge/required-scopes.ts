// Story 095: the bridge's required OAuth bot-token scopes + preflight helpers.
// REQUIRED_SCOPES is the single source of truth — slack-required-scopes-sync.sh
// asserts bridge/slack/README.md's scope table matches it.

export const REQUIRED_SCOPES: readonly string[] = [
  'app_mentions:read',
  'channels:history',
  'channels:read',
  'chat:write',
  'groups:read',
  'im:read',
  'mpim:read',
  'reactions:read',
  'reactions:write',
  'users:read',
  'users:read.email',
];

export function assertScopes(
  required: readonly string[],
  granted: readonly string[],
): string[] {
  return required.filter((scope) => !granted.includes(scope));
}

// Returns the trimmed, de-duped scope list, or null when the preflight should
// SKIP. The blank-drop is load-bearing: @slack/web-api's buildResult does
// `header.trim().split(/\s*,\s*/)`, so an empty x-oauth-scopes header yields
// [''] (not []) — which must normalize to null, else assertScopes([''], …)
// reports every required scope missing and bricks a correctly-scoped token.
export function normalizeGrantedScopes(value: unknown): string[] | null {
  if (!Array.isArray(value)) {
    return null;
  }
  const scopes = [
    ...new Set(
      value
        .filter((s): s is string => typeof s === 'string')
        .map((s) => s.trim())
        .filter((s) => s.length > 0),
    ),
  ];
  return scopes.length > 0 ? scopes : null;
}

// The stable fail-closed stdout line for a missing-scope preflight failure.
// Story 097's reason-namer parses this exact shape (it strips the
// `[claude-slack-bridge] ` prefix + ` — exiting` suffix). Pure + here so
// smoke.test.ts can lock 095's half of the 095↔097 stdout-line contract.
export function missingScopesExitLine(missing: readonly string[]): string {
  return `[claude-slack-bridge] missing OAuth scope(s): ${missing.join(', ')} — exiting`;
}
