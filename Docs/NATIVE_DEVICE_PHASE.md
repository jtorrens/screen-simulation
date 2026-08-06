# Native Model phase: Device foundation

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

The Model page shares the same preview component and ACEScg input texture as
the I/O page. Its active graph is:

`ACEScg → ACES 2.0 SDR sRGB device signal → Device Metal emission → ACEScg → preview`

Swift orchestrates the two explicit input views from the physical-frame
contract. The source-to-device processor is the pinned StudioColor/OCIO
processor and produces the nonlinear Device RGB view before the physical
boundary. Metal
then evaluates the Rust-resolved power EOTF, black/white luminance and
native-primary-to-ACEScg matrix. Output is normalized by the authored white for
the shared scene-linear preview boundary. At unresolved scale, subpixel order
and black-matrix fill preserve the compensated mean by definition; their
spatial structure becomes observable only when the later geometry/camera stage
resolves the native panel footprint. Cover glass is associated but not evaluated
in this Device-only cut.

The same input also carries `Fit`, `FillCrop`, `Stretch` or `OneToOne`; raster
placement is never inferred from dimensions. `amount = 0` returns the exact
original ACEScg texture without encoding a command.
`amount = 1` evaluates the calibrated Device stage. Metal/CPU-oracle tests cover
negative values, values above one and alpha, while the existing I/O page keeps
Device at exact identity. Preview and any future Device render consumer call the
same `DeviceMetalStage`; no second physical route exists.

The reproducible Device-stage performance command is
`SCREEN_DEVICE_BENCHMARK=1 swift test --filter deviceStagePlaybackBenchmarkWhenRequested`.
It measures only physical Metal command completion because StudioColor resolves
the Device signal once before the stage boundary. On the development
Apple-silicon host, 30 completed 960×540 evaluations measured 0.477 ms median
and 1.012 ms p95.

## Native UX

The bottom native navigation now has Principal, Modelo and Settings pages.
Modelo exposes the shared preview and a resizable native inspector with
`General`, `Pantalla` and `Captura` tabs. General owns the immutable Device
snapshot, raster placement, the selected-frame pipeline summary and the real
Screen/Capture master values. Pantalla exposes the five ordered contract
sections; Captura exposes its six ordered sections and states pending engine
work explicitly instead of simulating it.

Draft, Medium and High recompute the selected frame automatically. Native is an
explicit selected-frame action with progress, cancel and stale state. Fit and
1:1 share the same preview; 1:1 maps one native-result pixel to one logical
viewer pixel. No playback or sequence render is exposed on Modelo.

Settings owns add, unlock, edit, duplicate and delete for the global library with
native lists, visible lock state, forms, pickers, numeric fields, keyboard
behavior and explicit Rust-domain validation.
Definition editing does not appear on the Modelo page.

Manual QA of the packaged Release confirmed the resizable split, ordered native
cards, Device surface aspect, neutral viewport with no border/elevation,
shared toolbar and bottom-page navigation. Fit/1:1, Native stale/cancel and
accessibility are also enforced by their native controls and state tests.
