// workspace-guard.ts — Story 092: bridge-side workspace-mismatch guard.
//
// A pure assertion, kept out of index.ts so it is unit-testable without
// starting the bridge (importing index.ts runs its startup IIFE).

export class WorkspaceMismatchError extends Error {
  constructor(
    readonly expected: string,
    readonly actualTeamId: string | undefined,
    readonly actualTeam: string | undefined,
  ) {
    super(
      `workspace mismatch: expected ${expected}, ` +
        `got team=${actualTeam ?? '?'} id=${actualTeamId ?? '?'}`,
    );
    this.name = 'WorkspaceMismatchError';
  }
}

// Throws WorkspaceMismatchError when `expected` does not exactly equal the
// auth.test response's `team_id`. team_id-exact only — Slack team ids are
// stable; a display-name comparison would be collision-prone.
export function assertWorkspace(
  expected: string,
  authResp: { team_id?: string; team?: string },
): void {
  if (expected !== authResp.team_id) {
    throw new WorkspaceMismatchError(expected, authResp.team_id, authResp.team);
  }
}
