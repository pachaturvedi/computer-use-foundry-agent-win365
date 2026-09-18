---
applyTo: ".github/copilot-instructions.md,.github/instructions/**/*.instructions.md,.github/agents/**/*.agent.md,.github/prompts/**/*.prompt.md,CONTRIBUTING.md"
---

# Copilot customization maintenance

- Put cross-cutting non-negotiable invariants in `.github/copilot-instructions.md`.
- Put file-domain rules in the narrowest matching `*.instructions.md` file.
- Put role expertise, workflow, deliverables, and tool boundaries in custom agents; do not duplicate every repository invariant.
- Put manually invoked repeatable task framing in prompt files.
- Narrower instructions may refine but must not weaken repository-wide security, identity, lifecycle, or cleanup invariants.
- Keep agent responsibilities distinct and descriptions precise enough for reliable routing.
- Use `.agent.md`, `.instructions.md`, and `.prompt.md` frontmatter supported by the repository's target Copilot environments.
- Verify every `applyTo` glob, prompt-to-agent reference, referenced path, command, and environment-variable name.
- Review global, path-specific, agent, and prompt layers together when changing a durable rule so they do not conflict.
- Keep reviewers read-only and implementation agents mutation-capable only within the user's authorized scope.
- Every mutation-capable custom agent must invoke `final-change-gate` by default
  after non-trivial work and before its final proposal. New implementation
  agents must include this requirement explicitly.
- Do not weaken or remove the default gate without updating repository-wide
  instructions, contributor guidance, implementation agents, and prompts
  together.
