---
name: final-change-review
description: Run the mandatory multi-persona final gate over all intended changes before presenting a final proposal.
argument-hint: "Optionally provide the user outcome, acceptance criteria, intended paths, and known validation evidence"
agent: final-change-gate
---

Review the complete intended change for the current task.

- Establish the worktree boundary and separate pre-existing changes.
- Select and invoke the relevant principal reviewer personas.
- Run only read-only/offline validation.
- Consolidate findings without hiding disagreements or unsupported evidence.
- Return `READY`, `READY_WITH_DECLARED_LIMITS`, or `NOT_READY`.
- If ready, provide the exact evidence-based final proposal the implementing
  agent may present.
