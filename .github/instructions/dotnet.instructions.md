---
applyTo: "src/**/*.cs,tests/**/*.cs"
---

# .NET implementation

- Target the SDK and language settings already defined by the repository; do not retarget the framework casually.
- Follow `.editorconfig`, nullable-reference-type checks, analyzers, and warnings-as-errors.
- Keep formatting rules portable across the Linux and Windows CI jobs. Do not
  require a platform-specific line ending globally; validate `dotnet format
  --verify-no-changes` from a clean checkout.
- Use feature namespaces and folders already present under `src/Win365Agent`.
- Prefer constructor injection and existing service-registration extensions over service location or static mutable state.
- Propagate `CancellationToken` through async I/O. Async methods use the `Async` suffix unless implementing an established framework signature.
- Use repository-standard typed or source-generated logging. Do not log tokens, credentials, raw identities, session IDs, state blobs, or private URLs.
- Throw explicit exceptions for invalid configuration and unsafe state. Do not add broad catches, silent defaults, or success-shaped fallbacks.
- Keep public APIs documented where the project already requires XML documentation.
- Mirror production feature folders under the corresponding
  `tests/<Project>.Tests` project.
- Use fake token providers and HTTP handlers for unit tests. Default tests must remain offline and deterministic.
- Cover success, missing configuration, invalid input, ambiguous remote outcomes, cancellation, and cleanup when behavior changes.
- Do not add production abstractions solely to make a test convenient.
