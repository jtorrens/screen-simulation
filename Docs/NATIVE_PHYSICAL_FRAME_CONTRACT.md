# Native physical-frame contract

Status: normative for the SwiftUI/AppKit replacement candidate.

## Ownership and version

`ScreenPhysicalBridge.h` is the single binary contract between the macOS host
and the Rust/Metal physical engine. `SCREEN_PHYSICAL_FRAME_ABI_VERSION` is the
only accepted ABI version. Swift owns request orchestration and presentation
state; Rust and Metal own every physical meaning and evaluation. A request
contains immutable resolved Device and complete physical-pipeline snapshots;
it never contains a dynamic preset reference or an implicit default.

The ABI is coarse: one complete frame request creates one opaque job. Textures,
timed input sets, jobs, Device profiles and results cross as opaque handles or
immutable structs. There is no per-pixel call. One opaque timed-input-set
handle carries ordered exact-time samples, each with two explicitly typed
texture views, plus one placement and one explicit sampling policy:

1. source linear ACEScg RGBA, after the authored IDT;
2. nonlinear Device RGB signal, after StudioColor has resolved and applied the
   authored Source-to-Device transform;
3. `Fit`, `FillCrop`, `Stretch` or `OneToOne` raster placement;
4. `Exact`, bounded `Floor` or bounded `Nearest` source sampling.

The timed input set retains the underlying Metal texture handles through the
complete job lifetime without copying pixels. The host may release its input
wrappers after submit. Retained handles are released deterministically with the
job-owned input snapshot after completion or cancellation. The job owns its
output and its borrowed result view remains valid until job release.

Swift orchestrates both input views. StudioColor alone resolves
Source-to-Device. Screen emission and subpixel evaluation consume Device RGB;
raster sampling consumes the explicit placement; the source ACEScg view is the
identity/bypass signal and is not reinterpreted as Device RGB. Capture consumes
the physical Screen result, never either source encoding directly. The final
physical output is linear ACEScg. Preview transforms, ColorSync, DeckLink and
render ODTs are outside the physical engine and run only after its result.

Version 16 is the only live binary contract and has two ordered domains:

1. Screen: Emission, Subpixel Geometry, Panel Uniformity, Panel Light Spread,
   Temporal, Cover Glass, Environment and Cover Glow.
2. Capture: Geometry, Lens, Exposure/Shutter, Computational Capture, Sensor
   Photosite/CFA Collection and Noise, Bloom, Sensor Readout/RAW and Develop/Demosaic.

Their numeric identifiers are stable and domain-partitioned. A new stage is
appended to its owning typed section and to the same ABI version only when the
addition is backward-compatible for every current consumer. A semantic or binary
change increments the one contract version and updates header, Swift types,
Rust implementation, tests and documentation in one coordinated cut. It never
creates a second evaluator, compatibility reader, alias or runtime selector.

## Contribution semantics

Application publishes one ordered `ScreenPhysicalStageDescriptorV1` catalog
containing each stage's domain, control semantics, visual and safe limits,
zero-identity promise and General-overview membership. Swift consumes this
catalog and never declares or reconstructs those values. A submitted
`ScreenPhysicalStageContributionV3` carries only the stable stage id and its
authored continuous amount or discrete enabled state.

The common initial authoring range is 0–4 and the common visual slider range
is 0–2, with narrower owner-certified limits where published:

- 0: bypass/ideal. `exact_identity_at_zero` states whether bit-exact identity
  is a valid promise for that particular stage.
- 1: calibrated physical behavior.
- 0–1: transition defined by the owning physical stage.
- greater than 1: artistic extrapolation defined and bounded by that stage.

The host never implements a generic RGB blend. Discrete stages carry an enabled
state instead of a continuous amount. CFA/topology and other operations without
a coherent interpolation remain discrete.

The Screen master amount is not copied into another multiplier by the UI.
Capture has no continuous master because CFA and Developed RAW are discrete
domain transitions; Shutter and Noise expose their own continuous controls.
Per-stage diagnostics report the same stable identifiers.

## Request, result and lifecycle

`ScreenPhysicalFrameRequestV2` names one selected rational frame, an immutable
ordered timed input set, exact camera/screen pose tracks and shutter interval,
resolved Device handle, complete `ScreenPhysicalPipelineSnapshot`, quality,
Screen master and ordered stage contributions, requested dimensions, a required
host render context containing full-raster dimensions, bounded render window,
exact rational X/Y render scale and exact rational pixel aspect, one
typed intermediate selector, cancellation/progress identities and the exact
parameter revision/hash. The snapshot materializes cover, procedural
environment, resolved scene/camera/lens, shutter/readout/motion, sensor/noise
and RAW development. Panel emission, the complete fixed spatial-uniformity profile, temporal
behavior and complete light-spread radii and weights are materialized by the Device handle. The
live Device layout is `ScreenDeviceParametersV3`; catalog ABI 7 and test-authoring ABI 28 are
strict current-only companions to physical-frame ABI 16. The current executor
accepts only the complete window, unit scale and square pixels; every other valid
context is rejected as unsupported rather than ignored or coerced.

`ScreenPhysicalFrameResultV2` returns one borrowed texture and states which
typed intermediate it contains, plus native/effective dimensions, calculated
quality, progress/state, ordered diagnostics with elapsed nanoseconds and the
same parameter revision/hash. Final and radiance intermediates are linear
ACEScg; `DeviceSignal` retains its explicitly named nonlinear device domain.
Result texture and diagnostic views are borrowed for the owning job lifetime.

The functional cut evaluates every ordered Screen and Capture stage through the
single Rust/Metal executor. Their CPU implementations remain oracles only and
Metal is the mandatory product backend. Unsupported intermediate/enable
combinations fail explicitly; no identity stub simulates work and no CPU route
becomes a fallback.

The states are `idle`, `stale`, `rendering`, `cancelled`, `failed` and
`complete`. A completed Native result becomes stale when authored parameters
change; it remains publishable with an explicit stale indication until the
next explicit Native job completes. Cancellation is matched against the exact
request cancellation identity. A cancelled or failed job never publishes a
partial authoritative frame.

Draft, Medium, High and Native preserve scene parameters, framing, geometry,
exposure and output color meaning. Quality changes precision only. Native is
explicit; the other qualities may be automatically scheduled by the host.
