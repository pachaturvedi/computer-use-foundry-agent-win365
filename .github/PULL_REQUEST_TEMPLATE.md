## Summary

Describe the behavior change and the user-visible or operator-visible impact.

## Validation

- [ ] Ran the narrowest relevant tests, checks, or preview commands.
- [ ] Mapped acceptance criteria to expected and observed results.
- [ ] Covered applicable invalid-input, missing-configuration, provider-failure, cancellation, ambiguous-outcome, retry, and cleanup cases.
- [ ] Ran the relevant existing regression suites or explained why they do not apply.
- [ ] Confirmed default tests remained offline and did not mutate external resources.
- [ ] Included any manual validation notes for Azure, Foundry, W365, or Graph behavior.

Record each command or check exactly; use `Pass`, `Fail`, `Blocked`, or `Not applicable` rather than leaving evidence blank.

| Command or check | Outcome | Environment/platform | Scope (`Offline` or `Live`) | UTC date/time or run link (when applicable) | Evidence/result |
| --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |

Declared gaps, limitations, skipped coverage, and follow-up verification:

## Live Validation

- [ ] Not required.
- [ ] Required but still blocked; the exact unverified boundary and verification steps are documented.
- [ ] Completed with explicit authorization, sanitized evidence, active version, UTC timestamp, and cleanup proof.

## Documentation Impact

- [ ] No documentation update was required.
- [ ] Updated README for entry-point or quickstart changes.
- [ ] Updated docs/ARCHITECTURE.md for component, lifecycle, ownership, state, recovery, or cleanup changes.
- [ ] Updated docs/DEPLOYMENT.md for deployment flow, azd, environment, infra, or rollback changes.
- [ ] Updated docs/W365-SETUP.md for W365, Intune, Entra, pool, billing, or teardown changes.
- [ ] Updated docs/AUTHENTICATION.md for token, identity, caller binding, or permission changes.
- [ ] Updated docs/VIEWER.md for viewer, OIDC, federation, or handoff changes.
- [ ] Updated docs/VALIDATION-REPORT.md when the checked-in validation status changed materially.

If no documentation update was required, explain why:

## Safety Checks

- [ ] This change does not delete or mutate shared Azure, W365, or Entra resources beyond the sample-owned scope.
- [ ] Any teardown change removes only resources this repo created or explicitly recorded as owned.
- [ ] Cleanup was verified after both success and applicable failure paths.
- [ ] Temporary credentials, sessions, leases, and validation resources were revoked or released.
- [ ] Any new command examples are copy/paste ready for PowerShell on Windows.