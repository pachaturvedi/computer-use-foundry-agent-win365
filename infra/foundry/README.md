# Foundry provisioning layer

This directory contains the explicit Bicep infrastructure for the sample's
Foundry account, project, and model deployment. The hosted agent is still
deployed by `azd deploy win365-desktop-agent`; this layer only provisions the
Azure resources the agent depends on.

The template shape is based on an exported Cognitive Services / Foundry ARM
deployment and keeps configurable values in azd environment parameters instead
of relying on provider-specific substitution inside `azure.yaml`.
