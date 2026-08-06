# Native Device phase

## Authoritative domain

`screen-panel` remains the sole owner of Device physics and the nine current
Rust presets. Each preset now resolves the complete validated LCD profile used
by the former Slint application: stable identity, category, native raster,
physical active dimensions, IPS LCD technology, power EOTF, black/white
luminance, sRGB/D65 native colorimetry, RGB stripe layout, black matrix,
three-channel angular response, temporal emission and explicit default cover
association. The native shell obtains these values only through the coarse
opaque-handle C ABI in `screen-native-bridge`; Swift does not reproduce the
preset table or physical validation.

The ABI validates a complete Device at configuration time. It also publishes a
small immutable Metal parameter block and a batch CPU oracle. There are no
per-pixel ABI calls in production and no Swift implementation of panel
emission.

## Global persistence

Device, Cover Glass, render and pattern presets use the same generic global
`LibraryItem` envelope in `GlobalLibrary.v1.json` under current schema 5. Seeds
are created once from their authoritative catalogs with a persistent lock. A
locked item can always be duplicated; its copy has a new stable identity and is
unlocked. Explicit unlock converts the original into a normal editable and
deletable item. The current schema never silently relocks, reseeds or overwrites
an item. Earlier supported schemas are decoded only by explicit atomic
migrations. Unknown or corrupt schemas remain untouched and block the library.

`screen-cover` remains the sole authority for the six initial Cover Glass
profiles and their validation. `screen-native-bridge` exposes that catalog and
validation through coarse V1 structures and opaque handles; Swift owns only the
global-library adapter and native controls, not the optical equations.

Selecting a Device copies an immutable resolved snapshot into the workspace.
Later edits or deletion of the global entry cannot change that evaluation. No
project or render stores a dynamic preset reference.

## Metal graph

The Device page shares the same preview component and ACEScg input texture as
the I/O page. Its active graph is:

`ACEScg → ACES 2.0 SDR sRGB device signal → Device Metal emission → ACEScg → preview`

The source-to-device processor is the pinned StudioColor/OCIO processor. Metal
then evaluates the Rust-resolved power EOTF, black/white luminance and
native-primary-to-ACEScg matrix. Output is normalized by the authored white for
the shared scene-linear preview boundary. At unresolved scale, subpixel order
and black-matrix fill preserve the compensated mean by definition; their
spatial structure becomes observable only when the later geometry/camera stage
resolves the native panel footprint. Cover glass is associated but not evaluated
in this Device-only cut.

This section records the superseded Device-only cut. Its Swift evaluator and
shader were removed when the unified Rust/Metal frame job became authoritative.
The current `amount = 0` exact identity, calibrated evaluation, negative/>1 and
alpha guarantees are owned by `NATIVE_PHYSICAL_PIPELINE_V2.md`; no Device-only
runtime route remains.

Historically, on the development Apple-silicon host, 30 completed 960×540 Device evaluations
measured 0.974 ms median and 1.917 ms p95, including the pinned OCIO device-signal
transform and Device Metal command completion. The reproducible command is
`SCREEN_DEVICE_BENCHMARK=1 swift test --filter deviceStagePlaybackBenchmarkWhenRequested`.

## Native UX

The bottom native navigation now has Principal, Device and Settings pages.
Device exposes only preset selection plus the immutable effective summary.
Settings owns add, unlock, edit, duplicate and delete for the global library with
native lists, visible lock state, forms, pickers, numeric fields, keyboard
behavior and explicit Rust-domain validation.
Definition editing does not appear on the Device page.

Manual visual QA of the packaged application remains pending because the
desktop session was locked. Automated build, launch, layout contracts, tests,
signature and package hashes do not convert that pending review into a pass.
