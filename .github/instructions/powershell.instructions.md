---
applyTo: "scripts/**/*.ps1"
---

# PowerShell automation

- Target PowerShell 7.4+ and Windows execution from the repository root.
- Use approved PowerShell verbs, `[CmdletBinding()]`, typed parameters, and `$ErrorActionPreference = 'Stop'` for operational scripts.
- Start every production script with concise comment-based help covering its
  purpose, behavior, key inputs, outputs, and read-only or mutation boundary.
- Under strict mode, wrap function or pipeline results in `@(...)` before using
  `.Count`; a single returned item may otherwise be an unwrapped scalar.
- Make read-only/default behavior safe. Resource mutation requires an explicit confirmation switch and must honor `-WhatIf`/`ShouldProcess` where applicable.
- Every operator workflow must identify itself as read-only, preview, or mutating; print a concise redacted action summary; report blocked prerequisites; and provide the next safe command.
- Resolve and validate IDs before mutation. Reject ambiguous Graph, Foundry, W365, RBAC, or azd results.
- Make reconciliation idempotent: reuse exact matches, reject conflicts, and preserve unrelated grants, identities, policies, and resources.
- Do not output tokens, secret values, request bodies containing credentials, raw session links, or state contents.
- Keep scripts non-interactive unless device-code or explicit human authorization is part of the documented flow.
- Use `Join-Path` and Windows-compatible paths; keep examples copy/paste ready for PowerShell.
- Do not depend on shell state from a previous process. Set required environment variables in the same process as the command that consumes them.
- Validate documented workflows from a fresh PowerShell 7 process at the repository root. Prefer one repository script over a fragile multi-command recipe.
- Add or update offline regression coverage when setup, discovery, parsing, or reconciliation changes.
- Parse every changed script and run the narrow offline test script before completing.
- Update every guide that references a changed parameter, command, environment variable, or output.
