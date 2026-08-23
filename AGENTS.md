# Screen Simulation working rules

These rules apply to every task in this repository.

## Architecture authority

- Read this file and every active document listed by `Docs/architecture/README.md` before changing code or persisted contracts.
- Active architecture documents describe only the current system. They contain no migration ledger, superseded decision, compatibility plan, or speculative implementation route.
- Every semantic rule has one canonical owner. Update that owner and its enforcement in the same revision.

## Decision coherence gate
<!-- decision-owner: architecture.decision-coherence -->

- Before changing architecture, persisted contracts or behavior governed by an active decision, identify its stable decision id in `architecture/decision-authority.json`, read the canonical owner section and run the declared enforcement. The registry is an index; it never restates the decision.
- Compare the user's current decision, the canonical owner, every marked reference, the implementation contract and the owning tests before choosing an implementation. Scope qualifiers are normative: a rule for a workstation scene, portable project, imported asset or external resource cannot be broadened to another scope.
- If two active statements, tests or contracts imply different observable outcomes, stop before editing that behavior. Report the exact conflict and ask the user to resolve it. Do not choose by recency, convenience, majority, perceived strictness or audit severity.
- A review or audit finding is evidence, not product authority. It cannot override an explicit user decision or the canonical owner. When it conflicts with either, surface the conflict instead of implementing the finding.
- A new or changed product decision is incomplete until the same revision updates its canonical owner, registry entry or references, implementation and focused enforcement. Unregistered semantic prose is an architecture error, not an alternate authority.
- When a task exposes an unregistered decision, register its owner before changing the governed implementation. If the correct owner or scope is ambiguous, stop and ask the user.

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
- Every library-version migration preserves every user-authored item in every collection unless the user explicitly authorizes deletion or semantic replacement of identified items. Preservation includes stable identity, authored content, collection membership, ordering, lock state and references; adding or replacing bundled seeds cannot rebuild a library from defaults or omit user items.
- Each library migration test starts with at least one user-authored item in every collection and proves those items are unchanged in the result, in addition to proving the intended schema transformation.
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
- Executable and host adapters are composition roots. Desktop, native macOS and any later OFX or other host adapter consume the same Application evaluator and cannot duplicate domain semantics.
- Cross-domain workflows use narrow typed ports. Do not introduce a universal engine, service locator, general repository, catch-all project facade, or runtime registry with semantic conditions.

## Model-authored controls and presets

- Physical models live in Rust. Each model owns the stable phase identifiers it implements, the typed input and output contract of every phase, and the parameter descriptors, limits, units, animation capability and validation required by that phase.
- UI code renders prepared presentation descriptors and sends stable control intents. It never declares phase order, model parameters, physical limits, units, preset compatibility, Color Mode availability or mappings from a visible phase to an evaluator intermediate.
- UI targets may depend only on presentation contracts and host UI frameworks. They cannot import Color, Media, Panel, Geometry, Camera, Sensor, Persistence, a native physical bridge or a model implementation. Enforce this with target dependencies so an illegal import fails compilation.
- Presets are explicit parameter providers owned by their corresponding domain: Device/Panel, Cover Glass, Camera, Lens, Sensor and later preset families remain separate. A preset contains capabilities, calibrated/reference values and supported stable identifiers; it is never an evaluator or UI definition.
- Application materializes a selected preset plus explicit manual authoring into one complete immutable resolved request before evaluation. Models never look up presets or invent missing values during evaluation.
- Preset capability and authored instance selection are different contracts. For example a Device may declare supported Color Mode ids and a luminance range, while the simulation request separately stores the selected Device id, selected Color Mode id and White Luminance. Editing the request never mutates the preset.
- Color owns the meaning and resolution of Input Transform and Output Signal identifiers. Panel owns Device Color Mode identifiers and their EOTF interpretation. A Device references the Panel-owned Color Mode ids it supports but cannot duplicate either Panel response or Color-owned OCIO transforms. UI displays only the options prepared by Application from the owning domains.

## Composable phase boundaries

- Every phase consumes and publishes a named, versioned, typed artifact independent of the preceding or following implementation. A phase output is not a generic metadata bag and cannot contain undocumented data intended only for one next model.
- ACEScg is used only where the boundary is explicitly scene-linear tristimulus imagery. Device signal, emitted radiance, sensor exposure, RAW mosaic and other physical artifacts retain their own contracts and must not be relabeled ACEScg for convenience.
- A new physical model may be inserted only when it implements the exact input and output ports at that position, or when an explicit separately owned adapter is added. Other phases are not rewritten to inspect its identity.
- An accepted phase checkpoint is the sole input to the next phase for both interactive and reference evaluation. Diagnostic previews and PNGs are presentation artifacts and never replace the canonical checkpoint.
- Preview applies only the explicitly selected output transform. If a correct checkpoint contains values that transform cannot represent, presentation may clip or hide them; no diagnostic normalization, false-color substitution or visibility compensation may alter their meaning.

## Host-neutral core and OFX readiness

- Core contracts, presets, Application orchestration and physical evaluators are host-neutral. They cannot depend on SwiftUI, AppKit, Slint, OFX, a host clip type, a file dialog, Metal presentation, a decoder session or an output writer.
- Host adapters replace only source-frame acquisition, presentation/parameter binding, render context acquisition and final-frame publication. Desktop files/patterns and an OFX input clip must resolve into the same source contract; Desktop preview/export and an OFX output clip must consume the same evaluated result.
- Application render requests explicitly carry exact time, frame rate, render scale, render window or region, pixel aspect and requested quality where applicable. Models declare spatial support and temporal frame requirements so a host may evaluate tiles, regions or multiple input times without changing semantics.
- Parameter and phase ids are stable independently of labels, language and UI order. The set of parameter identities exposed by a plugin version must be describable before an OFX instance is created; runtime state controls availability and values, not the invention of new identities by the host UI.
- CPU reference evaluation remains host-neutral even when a shipped adapter requires a particular GPU backend. Adapter-specific Metal, Windows or OFX tests cannot make that backend a dependency of the core or redefine the evaluator.

## Deterministic boundaries

- Persist stable opaque identifiers, exact rational frame rates/times, explicit units, and explicit schema versions.
- Persist project-relative resource references; machine-specific roots and credentials are workstation state.
- Never infer identity or ownership from names, filenames, type labels, list order, resolution, or visual position.
- Interactive and reference evaluation consume the same immutable resolved simulation request.
- Internal light transport remains linear float; display/output encoding occurs only at the output boundary.
- Preserve negative and above-one values until an explicit output transform permits quantization or clipping.

## Validation

- Architecture rules must become executable checks whenever practical.
- Prefer compiler-enforced module and crate boundaries over source-text checks. Each target declares the narrowest allowed dependencies; forbidden domain imports must fail to compile.
- Dependency tests must prove forbidden domain edges cannot compile or link.
- Architecture validation rejects a host or UI target that is granted a model/domain dependency merely to make an illegal import compile.
- Contract tests prove phase descriptors have unique stable ids, preset capabilities contain the authored selection, scalar limits are finite and ordered, and every phase input/output artifact is explicit and versioned.
- Host-conformance tests run the same immutable request through host-neutral reference evaluation and adapter-specific input/output bindings. Render-window and temporal tests prove tiled or multi-frame host requests do not select another physical route.
- Contract tests reject unknown versions, unknown fields, missing required values, aliases, and retired representations.
- Migration tests use disposable copies and prove normal startup is byte-for-byte read-only.
- CPU reference and GPU implementations are compared with documented numeric tolerances.
- Every changed path must have a declared validation owner; an unclassified path is an error, not a reason to run a broad fallback suite.

## Phase-gated implementation

- Before changing or adding a simulation phase, present a non-technical high-level summary and wait for explicit user confirmation.
- The summary states what the phase represents, what it receives and delivers, which controls become visible, which cumulative Preview option is added, and how it will be compared with the previous model.
- A phase is complete only after checking owner-supplied parameters and presets, limits and units, exact consumption of the prior canonical artifact, cumulative Preview selection, color/alpha/raster/placement identity, comparable old/new diagnostic PNGs, visual observations with user review, compilation and owning contract/architecture tests.
- Only a phase that passes that checklist becomes the canonical checkpoint feeding the next phase.
