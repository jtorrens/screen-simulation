# Native physical-frame contract

Status: normative for the SwiftUI/AppKit replacement candidate.

## Ownership and version

`ScreenPhysicalBridge.h` is the single binary contract between the macOS host
and the Rust/Metal physical engine. `SCREEN_PHYSICAL_FRAME_ABI_VERSION` is the
only accepted ABI version. Swift owns request orchestration and presentation
state; Rust and Metal own every physical meaning and evaluation. A request
contains an immutable resolved Device snapshot and never a dynamic preset
reference.

The ABI is coarse: one complete frame request creates one opaque job. Textures,
frame inputs, jobs, Device profiles and results cross as opaque handles or
immutable structs. There is no per-pixel call. One opaque frame-input handle
carries two explicitly typed texture views and one placement value:

1. source linear ACEScg RGBA, after the authored IDT;
2. nonlinear Device RGB signal, after StudioColor has resolved and applied the
   authored Source-to-Device transform;
3. `Fit`, `FillCrop`, `Stretch` or `OneToOne` raster placement.

The host retains the underlying Metal textures through the complete job
lifetime. The bridge texture handles are non-owning views; creating an input
does not duplicate either texture. The job owns its output and its borrowed
result view remains valid until job release.

Swift orchestrates both input views. StudioColor alone resolves
Source-to-Device. Screen emission and subpixel evaluation consume Device RGB;
raster sampling consumes the explicit placement; the source ACEScg view is the
identity/bypass signal and is not reinterpreted as Device RGB. Capture consumes
the physical Screen result, never either source encoding directly. The final
physical output is linear ACEScg. Preview transforms, ColorSync, DeckLink and
render ODTs are outside the physical engine and run only after its result.

Version 1 has two ordered domains:

1. Screen: Emission, Subpixel Geometry, Temporal, Cover Glass, Environment.
2. Capture: Geometry, Lens, Exposure/Shutter, Sensor/CFA, Noise,
   Develop/Demosaic.

Their numeric identifiers are stable and domain-partitioned. A new stage is
appended to its owning typed section and to the same ABI version only when the
addition is backward-compatible for every v1 consumer. A semantic or binary
change increments the one contract version and updates header, Swift types,
Rust implementation, tests and documentation in one coordinated cut. It never
creates a second evaluator, compatibility reader, alias or runtime selector.

## Contribution semantics

Continuous stages carry their authored safe limits. The initial authoring
range is 0–4 and the visual slider range is 0–2:

- 0: bypass/ideal. `exact_identity_at_zero` states whether bit-exact identity
  is a valid promise for that particular stage.
- 1: calibrated physical behavior.
- 0–1: transition defined by the owning physical stage.
- greater than 1: artistic extrapolation defined and bounded by that stage.

The host never implements a generic RGB blend. Discrete stages carry an enabled
state instead of a continuous amount. CFA/topology and other operations without
a coherent interpolation remain discrete.

Screen and Capture master amounts are the domain values themselves. They are
not copied into another multiplier by the UI. Per-stage diagnostics report the
same stable identifiers.

## Request, result and lifecycle

`ScreenPhysicalFrameRequestV1` names one selected rational frame, opaque typed
frame input, resolved Device handle, quality, master and ordered stage
contributions, requested dimensions, cancellation/progress identities and the
exact parameter revision/hash.

`ScreenPhysicalFrameResultV1` returns an ACEScg texture, native and effective
dimensions, calculated quality, progress/state, ordered diagnostics and the
same parameter revision/hash. Result texture and diagnostic views are borrowed
for the owning job lifetime.

The states are `idle`, `stale`, `rendering`, `cancelled`, `failed` and
`complete`. A completed Native result becomes stale when authored parameters
change; it remains publishable with an explicit stale indication until the
next explicit Native job completes. Cancellation is matched against the exact
request cancellation identity. A cancelled or failed job never publishes a
partial authoritative frame.

Draft, Medium, High and Native preserve scene parameters, framing, geometry,
exposure and output color meaning. Quality changes precision only. Native is
explicit; the other qualities may be automatically scheduled by the host.
