# Screen Simulation working rules

These rules apply to every task in this repository.

## Architecture authority

- Read this file and every active document listed by `Docs/architecture/README.md` before changing code or persisted contracts.
- Active architecture documents describe only the current system. They contain no migration ledger, superseded decision, compatibility plan, or speculative implementation route.
- Every semantic rule has one canonical owner. Update that owner and its enforcement in the same revision.

## Historical archive is sealed

- `Docs/old` is a sealed historical archive.
- Do not open, search, read, quote, summarize, cite, or use any file below `Docs/old` unless the user explicitly authorizes that exact historical consultation.
- Active documents must not link to or derive a decision from `Docs/old`.
- When a document stops being necessary to implement or validate the current version, remove it from the active index and move it to `Docs/old` without consulting it afterward.

## No fallbacks or legacy routes

- Never add a fallback, inferred substitute, compatibility reader, legacy key, alias, coercion, silent default, dual-path behavior, startup repair, or guessed resource route.
- Missing, malformed, unknown, or obsolete required data fails explicitly at its boundary.
- Optional values are valid only when absence has an explicit domain meaning.
- Metadata may propose an input transform or alpha interpretation, but persisted authored selection is authoritative.
- If a change appears to require compatibility behavior, stop and request an explicit product decision before implementing it.

## Migrations are explicit maintenance

- Runtime startup and normal project opening are read-only with respect to schema and authored data.
- During development there is one current world. Contract, profiles, fixtures, tests, and renderer change together; changed results are accepted.
- A contract migration is a one-way maintenance operation over a disposable copy or explicitly selected project.
- A migration updates the schema, every affected record, references, fixtures, assets, documentation, and validation together.
- Normal readers accept only the resulting current contract. Temporary migration code is not reachable from normal open/read/render paths.
- Unknown schema or document versions are rejected.
- Do not preserve an earlier evaluator, profile behavior, output result, or document reader during development.

## One semantic owner and narrow capabilities

- Media decoding owns sample selection, orientation, decoded channel values, alpha extraction, and timestamps. It never chooses an IDT or output transform.
- Color owns OCIO configuration, explicit input/display/output transform resolution, and CPU reference processing. It does not decode media or choose panel behavior.
- Panel owns device signal interpretation, subpixel geometry, panel response, and emitted radiance. It does not decode files or emulate the camera.
- Geometry owns physical units, camera and screen animation, and projection.
- Application owns the current phase's immutable simulation request and orchestration through narrow domain ports.
- Persistence owns strict current project documents and portable references. It does not decode, resolve color, simulate, or render.
- Platform owns replaceable macOS/Windows media, GPU, display, and filesystem adapters.
- Executable and host adapters are composition roots. The current workspace contains only Desktop, whose Slint shell displays immutable prepared state and contains no domain rules. Any later host adapter must consume the same Application evaluator and cannot duplicate domain semantics.
- Cross-domain workflows use narrow typed ports. Do not introduce a universal engine, service locator, general repository, catch-all project facade, or runtime registry with semantic conditions.

## Deterministic boundaries

- Persist stable opaque identifiers, exact rational frame rates/times, explicit units, and explicit schema versions.
- Persist project-relative resource references; machine-specific roots and credentials are workstation state.
- Never infer identity or ownership from names, filenames, type labels, list order, resolution, or visual position.
- Interactive and reference evaluation consume the same immutable resolved simulation request.
- Internal light transport remains linear float; display/output encoding occurs only at the output boundary.
- Preserve negative and above-one values until an explicit output transform permits quantization or clipping.

## Validation

- Architecture rules must become executable checks whenever practical.
- Dependency tests must prove forbidden domain edges cannot compile or link.
- Contract tests reject unknown versions, unknown fields, missing required values, aliases, and retired representations.
- Migration tests use disposable copies and prove normal startup is byte-for-byte read-only.
- CPU reference and GPU implementations are compared with documented numeric tolerances.
- Every changed path must have a declared validation owner; an unclassified path is an error, not a reason to run a broad fallback suite.
