---
applyTo: "src/Win365Shared/Identity/**/*.cs,src/Win365Shared/Configuration/**/*.cs,tests/Win365Shared.Tests/Identity/**/*.cs,tests/Win365Shared.Tests/Configuration/**/*.cs,azure.yaml,scripts/Setup-W365.ps1,scripts/Get-FoundryIdentity.ps1,scripts/Invoke-W365SetupFlow.ps1,docs/AUTHENTICATION.md,docs/W365-SETUP.md"
---

# Identity and authentication

- Preserve the three-stage flow: blueprint T1, agent-identity T2, and agent-user resource token T3.
- Only T1 varies by `W365_BLUEPRINT_CREDENTIAL_MODE`. Keep T2 and T3 shared unless the external protocol itself changes.
- Supported configuration values are explicit and mutually exclusive:
  - `managed_identity_federation`
  - `client_secret`
  - `key_vault_certificate` only after its full implementation
- Never implement automatic fallback between modes. A failed mode returns a stage-aware error and stops.
- `client_secret` requires `W365_CLIENT_SECRET` (viewer) or `W365_KEY_VAULT_NAME` (hosted agent, which fetches the secret directly from Key Vault using its own identity instead of an environment variable); never print, hash for display, serialize into documentation, or commit the resolved secret value.
- Managed identity must use the intended runtime identity. Do not use Azure CLI, developer credentials, or an interactive user as a W365 fallback.
- Certificate mode must use Key Vault and managed identity, register only public certificate material with the blueprint, and keep private key material out of source and local files.
- Preserve `fmi_path=W365_AGENT_ID` for blueprint exchanges.
- Validate blueprint, agent, agent-user, tenant, and object/client identifier roles independently even when GUID values happen to match.
- Keep safe diagnostics limited to stage, HTTP status, Entra error/code, and correlation ID. Detailed provider descriptions belong only in administrator logs and must not contain tokens.
- Every new mode requires settings validation, positive and negative unit tests, deployment variable wiring, operator documentation, live validation, and cleanup/rollback guidance.
- A mode becomes supported only after configuration validation, credential acquisition, token exchange, negative tests, deployment wiring, live acceptance, credential cleanup, and rollback are all documented and proven. Until then it must fail closed.
- Update `docs/AUTHENTICATION.md` for token behavior and `docs/DEPLOYMENT.md` or `docs/W365-SETUP.md` for operator steps.
