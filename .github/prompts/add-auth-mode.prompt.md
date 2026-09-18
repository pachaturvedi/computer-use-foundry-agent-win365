---
name: add-auth-mode
description: Implement or extend one explicit W365 blueprint authentication mode with no fallback.
argument-hint: "Name the authentication mode and credential source to implement"
agent: auth-mode-implementer
---

Implement the authentication-mode change requested by the user.

- Define the exact mode name, required settings, credential source, and T1 acquisition flow.
- Keep T2 and T3 shared unless protocol evidence requires a change.
- Fail closed for missing, invalid, unavailable, or unauthorized credentials.
- Do not add automatic fallback to another mode.
- Add positive and negative unit tests, configuration/deployment wiring, documentation, cleanup, and rollback.
- Do not create or deploy live credentials unless the user explicitly requests that operation.
- Run `/final-change-review` and resolve every blocker or required finding
  before presenting the final authentication proposal.
- Report offline validation separately from live identity and W365 acceptance.
