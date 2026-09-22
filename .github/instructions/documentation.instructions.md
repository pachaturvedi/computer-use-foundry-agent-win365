---
applyTo: "README.md,CONTRIBUTING.md,SECURITY.md,docs/**/*.md"
---

# Documentation

- Write for a Windows operator using PowerShell 7 from the repository root.
- Keep commands copy/paste ready, use backslash-separated repository paths, and include `pwsh -NoProfile -File` for scripts where appropriate.
- Put the minimum successful path first: prerequisites, configure, run, verify. Move optional viewer, production hardening, troubleshooting, rollback, and live-acceptance detail into linked owning guides.
- Keep `README.md` as the short entry point and do not make optional components prerequisites.
- Use:
  - `docs/DEPLOYMENT.md` for azd, Foundry deployment, rollback, and teardown.
  - `docs/W365-SETUP.md` for Graph, Entra agent user, Intune pool, consent, and tenant cleanup.
  - `docs/AUTHENTICATION.md` for credential modes, token exchanges, trust, and permission boundaries.
  - `docs/ARCHITECTURE.md` for components, request flow, durable state, ownership, readiness, recovery, and cleanup.
  - `docs/VIEWER.md` for OIDC, screen sharing, pause/resume, and human handoff.
- Clearly distinguish identifiers from credentials and offline validation from live acceptance.
- Never include tenant secrets, bearer tokens, raw session IDs, private state, or usable session links.
- Use exact environment-variable names and script parameters from source.
- Document defaults, prerequisites, failure behavior, cleanup, and rollback for operational changes.
- Include expected success output and actionable failures that identify the stage, remediation, whether retry is safe, and whether cleanup is required.
- When live acceptance is unavailable, state the exact unverified boundary,
  authorized verification command, expected evidence, and cleanup steps in the
  owning operational guide or pull request.
- Remove stale or contradictory instructions in the same change rather than adding another caveat.
