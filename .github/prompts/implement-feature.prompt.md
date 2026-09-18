---
name: implement-feature
description: Implement a repository feature end to end using the W365 implementation agent.
argument-hint: "Describe the desired behavior and acceptance criteria"
agent: w365-implementer
---

Implement the feature described by the user.

- Convert the request into measurable acceptance criteria.
- Include the user's goal, shortest supported Windows workflow, expected success output, actionable failure behavior, and explicit out-of-scope behavior.
- Identify every affected runtime, configuration, test, and documentation surface.
- Prefer the smallest localized change; do not introduce new abstractions, infrastructure, authentication modes, or viewer dependencies unless an acceptance criterion requires them.
- Follow existing patterns and preserve repository-wide security and W365 lifecycle invariants.
- Add focused offline tests before considering the implementation complete.
- Run targeted validation, then the Release build and formatting checks appropriate to the change.
- Run `/final-change-review` over the complete intended diff and resolve all
  blocker/required findings.
- Summarize changed behavior, files, validation, and any remaining live acceptance requirement.
