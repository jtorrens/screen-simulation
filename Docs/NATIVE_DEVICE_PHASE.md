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
boundary. The Rust/Metal physical-frame job then evaluates the Rust-resolved
power EOTF, black/white luminance and
native-primary-to-ACEScg matrix. Output is normalized by the authored white for
the shared scene-linear preview boundary. At unresolved scale, subpixel order
and black-matrix fill preserve the compensated mean by definition; their
spatial structure becomes observable only when the later geometry/camera stage
resolves the native panel footprint. Emission and subpixel geometry are the
only active sections; Temporal, Cover Glass, Environment and every Capture
section remain explicit zero/bypass pending implementation.

The same input also carries `Fit`, `FillCrop`, `Stretch` or `OneToOne`; raster
placement is never inferred from dimensions. `amount = 0` returns the exact
original ACEScg texture without encoding a command.
`amount = 1` evaluates the calibrated Device stage. Metal/CPU-oracle tests cover
negative values, values above one and alpha, while the existing I/O page keeps
Device at exact identity. Preview calls the single
`screen_physical_frame_submit` job boundary. The former Swift
`DeviceMetalStage` and its shader have been removed; no second physical route
exists. Draft, Medium and High use the same framing at increasing requested
resolution/sampling. Native evaluates the panel's authored raster on the
authoritative 3×3 subpixel lattice and exposes progress, cancellation,
parameter revision and diagnostics through stable snapshots.

The reproducible integration timing command is
`SCREEN_PHYSICAL_BENCHMARK=1 swift test --filter physicalPanelTimingWhenRequested`.
On the development Apple-silicon host, the bridge harness measured the UHD TV
at 12.91 ms Draft and 89.11 ms Native (11520×6480), and the 14-inch Retina
panel at 12.37 ms Draft and 77.63 ms Native (9072×5892). The packaged Release
UI measured the first Phone Retina frequency preview at 17–24 ms and its
2250×4002 Native result at 46.6 ms. These figures include job submission and
snapshot publication; the source texture was already selected.

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

## Manual visual checklist

Manual visual QA of the packaged Release covered the canonical editorial and
frequency patterns, the portrait Phone Retina surface, Draft and Native, and
the stale state. The following checklist records the observed result and the
remaining user-review surface:

- The resizable split, device surface aspect and neutral viewport have no
  preview border or elevation; Fit and 1:1 retain the same framing.
- Emission and Subpixel Geometry respond for RGB and BGR, black-matrix/fill and
  `Fit`, `FillCrop`, `Stretch` and `OneToOne`; pending cards remain bypassed.
- Screen and implemented section sliders have a clean native track with no
  tick marks, move in 0.05 steps, detent exactly at Physical = 1, retain their
  numeric field and expose complete accessibility labels.
- Amount 0 preserves exact ACEScg identity; 1 is calibrated and values above 1
  are labelled artistic.
- Draft, Medium, High and Native preserve framing and converge as quality rises;
  Native reports the 3×3 panel dimensions, progress, cancellation and stale
  state after parameter changes.
- The frequency and editorial patterns reveal expected subpixel structure
  without changing preview ODT/ColorSync behavior.

The packaged app displayed the expected RGB stripe lattice, retained the prior
Native result while showing the amber `Desactualizado` state after an amount
change, and kept the neutral viewport outside the device surface. Cancellation
and all four placements remain covered by state/bridge and Rust conformance
tests; a human review of those rapid transient states is still recommended.
