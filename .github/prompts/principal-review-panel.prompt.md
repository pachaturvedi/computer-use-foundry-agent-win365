---
name: principal-review-panel
description: Run independent principal-level architecture, engineering, QA, product, and forward-deployed reviews, then consolidate actionable feedback.
argument-hint: "Identify the files, feature, diff, or proposal to review"
---

Review the requested scope using these independent repository agents:

1. `principal-architect`
2. `principal-engineer`
3. `principal-qa`
4. `principal-product-manager`
5. `principal-forward-deployed-engineer`

Keep each review independent. Consolidate duplicate findings, preserve meaningful
disagreements, and rank the final recommendations by user impact, correctness,
security, operability, and implementation cost.

Do not edit files during the review. Return:

- critical changes required before implementation or merge;
- high-value improvements worth adding now;
- optional future enhancements;
- feedback rejected as duplication, overengineering, or outside scope.
