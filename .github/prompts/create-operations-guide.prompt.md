---
name: create-operations-guide
description: Create or improve a Windows-first operations runbook and diagnostic query catalog.
argument-hint: "Describe the operation, incident, deployment, recovery task, or queries to document"
agent: principal-operations-documentation-engineer
---

Create the requested operational documentation from verified repository
behavior.

- Identify the operator goal, responsible role, prerequisites, permission
  boundary, and expected outcome.
- Separate read-only discovery, preview, mutation, verification, rollback, and
  cleanup.
- Include copy/paste-ready PowerShell commands and explain what question each
  diagnostic query answers.
- Include expected output, common failures, safe remediation, retry guidance,
  evidence capture, and escalation ownership.
- Validate every referenced command, parameter, environment variable, path, and
  documentation link.
- Do not execute live mutations or include sensitive tenant data.
