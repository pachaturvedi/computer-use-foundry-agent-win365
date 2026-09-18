---
name: validate-change
description: Review and validate a completed repository change without modifying code.
argument-hint: "Optionally identify the feature, files, or acceptance criteria to validate"
agent: validation-reviewer
---

Validate the current change against the user's acceptance criteria and repository instructions.

- Review the diff and relevant surrounding implementation.
- Check authentication boundaries, lifecycle ownership, retries, cleanup, secret handling, configuration, and documentation impact.
- Produce an acceptance matrix covering expected behavior, negative/fault cases, regression coverage, cleanup, and any required live acceptance.
- Run focused offline tests and static checks that do not mutate external resources.
- Separate confirmed evidence from assumptions and live validation still required.
- Verify that a new operator can identify prerequisites, execute the shortest workflow, recognize success, recover from expected failures, and clean up without reading source.
- Return high-confidence findings first with file and line references, followed by commands/results, cleanup evidence, blocked checks, and residual risks.
