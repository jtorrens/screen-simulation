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

Device presets are normal global user entries in `GlobalLibrary.v1.json` under
current schema 4. Earlier supported schemas are decoded only by explicit atomic migrations,
validated completely, seeded once from the Rust catalog and atomically replaced.
The current schema never reseeds deleted entries or overwrites edits. Unknown or corrupt
schemas remain untouched and block the library with an explicit error.

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

`amount = 0` returns the exact original texture without encoding a command.
`amount = 1` evaluates the calibrated Device stage. Metal/CPU-oracle tests cover
negative values, values above one and alpha, while the existing I/O page keeps
Device at exact identity. Preview and any future Device render consumer call the
same `DeviceMetalStage`; no second physical route exists.

On the development Apple-silicon host, 30 completed 960×540 Device evaluations
measured 0.974 ms median and 1.917 ms p95, including the pinned OCIO device-signal
transform and Device Metal command completion. The reproducible command is
`SCREEN_DEVICE_BENCHMARK=1 swift test --filter deviceStagePlaybackBenchmarkWhenRequested`.

## Native UX

The bottom native navigation now has Principal, Device and Settings pages.
Device exposes only preset selection plus the immutable effective summary.
Settings owns add, edit, duplicate and delete for the global library with native
lists, forms, pickers, numeric fields, keyboard behavior and explicit validation.
Definition editing does not appear on the Device page.

Manual visual QA of the packaged application remains pending because the
desktop session was locked. Automated build, launch, layout contracts, tests,
signature and package hashes do not convert that pending review into a pass.
