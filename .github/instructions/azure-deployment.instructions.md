---
applyTo: "azure.yaml,infra/**/*.bicep,infra/**/*.json,.azure/**/*.md,scripts/Invoke-AzdDeployment.ps1,scripts/Invoke-W365SetupFlow.ps1,scripts/Setup-W365.ps1,scripts/Get-FoundryIdentity.ps1,scripts/Deploy-*.ps1,scripts/Test-AzdPrerequisites.ps1"
---

# Azure and Foundry deployment

- Treat this as an existing azd/Foundry project. Never run `azd init` or overwrite the checked-in manifest.
- Preserve two-phase onboarding: deploy a W365-disabled bootstrap first, discover Foundry-created identities, bind them to W365, then deploy an enabled immutable version.
- Deploy the same hosted-agent name so Foundry creates a new immutable version; verify the active version after deployment.
- Keep viewer infrastructure optional and disabled unless the task explicitly enables it.
- Use existing resources when configured. Do not silently create a replacement Foundry project, model, blueprint, agent identity, W365 pool, viewer, App Service, or broad resource group.
- Use least-privilege RBAC at the narrowest workable scope and verify live assignments after provisioning.
- Keep Storage private, HTTPS-only, Entra-authorized, and free of public Blob access or shared-key dependencies.
- Never place credential values in `azure.yaml`, Bicep outputs, logs, deployment plans, documentation, or command transcripts.
- Before mutation, confirm the user authorized the exact operation, run read-only discovery, preview with `-WhatIf` or the platform equivalent, and stop on ambiguous identities, scopes, ownership, or plans.
- Do not run `azd up`, `azd down`, Graph writes, credential creation/rotation, role assignment, or destructive recovery unless the user explicitly authorized that class of mutation.
- Separate provisioning from application deployment when RBAC propagation matters.
- Do not claim deployment success until the active agent/resource state and required endpoint are verified.
- Distinguish code defects from tooling, RBAC propagation, Entra, Foundry, Intune/W365, pool-capacity, and service-health failures using safe stage and correlation evidence.
- Record live validation separately from offline validation and include safe rollback/credential cleanup steps.
- Update `docs/DEPLOYMENT.md`; update `docs/W365-SETUP.md`, `docs/AUTHENTICATION.md`, or `docs/ARCHITECTURE.md` when their behavior changes.
