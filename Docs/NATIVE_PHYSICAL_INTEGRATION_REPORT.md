# Native unified physical integration report

Date: 2026-08-07. Host: Apple M3 Ultra, macOS 15.6.

## Adopted authority

The native shell contains the complete authorized physical range
`c852ca86573b73a7b72c75e457e6f2b5d1b09950^..de2e04d7de0a7db6bc9bef74431be107756e036d`.
The sole product entry point is `screen_physical_frame_submit` with
`SCREEN_PHYSICAL_FRAME_ABI_VERSION 5`. There is no earlier-ABI adapter, Swift
physics, CPU product fallback or alternate shader path.

Swift creates and retains an immutable v2 snapshot for each resolved state and
releases its opaque handles with the job. StudioColor supplies typed Source
ACEScg and nonlinear Device Signal textures plus explicit RasterPlacement.
The selected-frame host creates an explicit timed sample and constant
position/quaternion pose tracks; diagnostics report `STATIC_INPUT`. This is not
presented as animated motion, while the same contract is ready for future
timeline samples and tracks.

The authoritative stage order is:

`Emission/Subpixel/Panel Light Spread -> Temporal -> Glass/Environment -> Geometry/Lens -> Global or Rolling Shutter/Motion -> Sensor/CFA/Noise -> RAW/Demosaic/WB/Develop -> ACEScg`.

Preview ODT/ColorSync, DeckLink and render output remain outside the physical
engine. Capture has no continuous master. CFA and Develop are discrete enables;
Shutter and Noise retain their continuous amounts.

## Connected control and model matrix

| UI card | Physical model | Control semantics |
|---|---|---|
| Emission | EOTF, luminance, black, color/angular response | Continuous amount 0-4 |
| Subpixel geometry | RGB/BGR, pitch, fill and black matrix | Continuous amount 0-4 |
| Panel Light Spread | Inter-pixel/subpixel optical contamination | Continuous amount 0-4; not lens bloom, halation, glass or sensor |
| Temporal | Flicker and analytic creative banding | Continuous amount 0-4 |
| Glass | Transmission, Fresnel, roughness and AR | Continuous amount 0-2, matching the authoritative safe limit |
| Environment | Reflected synthetic HDR environment | Continuous amount 0-4 |
| Camera-screen geometry | Physical poses and panel/camera geometry | Continuous amount 0-4 |
| Lens | Focus, aperture, distortion, CA, vignette and PSF | Continuous amount 0-4 |
| Shutter/Motion | Timed global or rolling shutter integration | Continuous shutter amount 0-4; static timed input in this phase |
| Sensor/CFA | Bayer sampling, well, clipping and ADC | CFA discrete enable |
| Noise | Deterministic sensor noise | Continuous amount 0-4 |
| RAW/Develop | Mosaic, demosaic, WB and ACEScg development | Develop discrete enable |

Continuous UI controls have a clean track, internal step 0.05, an exact detent
at physical 1, numeric entry, and 0/1/>1 bypass/physical/artistic semantics.
Each model owns its interpolation rather than a generic RGB mix.

General uses one aligned native-switch / label / slider / numeric-value grid.
Switch OFF publishes exact effective amount zero while retaining the editable
stored value; switching ON restores that value. CFA and Develop keep their one
discrete enable rather than receiving a redundant bypass switch. Expanded cards
use aligned label / flexible control / numeric-value / restore columns. A
modified authorable parameter reveals an `arrow.counterclockwise` button that
restores only that field to the preset snapshot, with undo and accessibility;
the column stays reserved while the icon is hidden at the base value.

## Automated validation

- Swift: **48 tests passed**. Coverage includes all eleven intermediates,
  `STATIC_INPUT`, twelve ordered diagnostics, honest fused timings, exact source
  values at amount 0, RGB/BGR, four placements, alpha, spread 0/1/2.5, every
  continuous stage at 0/1/>1, discrete CFA/Develop, Native cancellation and
  anchored pan/zoom mathematics. It also covers retained bypass values,
  persistence/undo, nonblack Developed energy and alpha, complete authorable
  UI bindings, per-field preset restoration affordances and native switch
  styling in General.
- Rust workspace: **199 tests passed**.
- `cargo fmt --all -- --check` passed.
- `cargo clippy --workspace --all-targets -- -D warnings` passed. Cargo reports
  only the upstream future-incompatibility notice for `block 0.1.6`.
- Architecture ownership, diff check, ABI-v2 source/header/symbol gate and
  native no-FFmpeg graph/Mach-O/rpath/symbol/resource gates passed.
- The native edge is
  `screen-native-bridge -> screen-platform(flat-panel-metal)` with default
  features disabled. AVFoundation, VideoToolbox and ImageIO remain the only
  native I/O route.
- Release packaging and strict deep ad-hoc codesign verification passed.
  Executable SHA-256:
  `a125da9e31b6eb9920cea54a0ed9126720652e6f34850097f023b94b9601a6e8`.

## Measured Release performance and memory

Command: `cargo run --release -p screen-platform --example physical_pipeline_benchmark`.
Input is one 3840x2160 RGBA32Float source. Memory is accounted input plus final
output texture storage, not process RSS. Setup took 1.819 ms.

| Device | Quality | Output | First preview/tile | Total | Accounted texture bytes |
|---|---:|---:|---:|---:|---:|
| Phone 4.7 Retina | Draft | 360x640 | 16.937 ms | 45.795 ms | 269,107,200 |
| Phone 4.7 Retina | Medium | 960x1708 | 2.090 ms | 36.901 ms | 291,655,680 |
| Phone 4.7 Retina | High | 1920x3415 | 7.322 ms | 183.106 ms | 370,329,600 |
| Phone 4.7 Retina | Native | 2250x4002 | 6.152 ms | 39.650 ms | 409,492,800 |
| MacBook Pro Retina 14 | Draft | 360x234 | 9.125 ms | 34.006 ms | 266,768,640 |
| MacBook Pro Retina 14 | Medium | 960x623 | 3.036 ms | 26.631 ms | 274,990,080 |
| MacBook Pro Retina 14 | High | 1920x1247 | 4.739 ms | 77.532 ms | 303,728,640 |
| MacBook Pro Retina 14 | Native | 9072x5892 | 26.810 ms | 124.882 ms | 1,120,656,384 |
| ASUS ProArt PA329CV | Draft | 360x203 | 12.611 ms | 36.668 ms | 266,590,080 |
| ASUS ProArt PA329CV | Medium | 960x540 | 3.269 ms | 25.399 ms | 273,715,200 |
| ASUS ProArt PA329CV | High | 1920x1080 | 4.980 ms | 75.181 ms | 298,598,400 |
| ASUS ProArt PA329CV | Native | 11520x6480 | 37.431 ms | 153.964 ms | 1,459,814,400 |

This owner benchmark intentionally isolates the screen lattice with capture
disabled. Capture stages are covered by exact conformance tests and fused-group
timing diagnostics, but a separate full-capture UHD benchmark is not claimed.

## Display and visual QA status

The active display previously reported by AppKit/ColorSync is ASUS PA329CV,
3840x2160, scale 1, EDR 1.0, profile
`/Library/ColorSync/Profiles/Displays/ASUS PA329CV-F3C58FD7-6A52-4D86-B8A3-255A0F791CB0.icc`.

Manual visual QA was completed in the unlocked WindowServer session on that
ASUS display. Principal published the synthetic checker visibly. Modelo
published the Developed intermediate at 3840x2160 in Draft with nonzero image
energy; Native had previously published 3840x2160 complete. The General grid
shows native switches in a dedicated aligned first column. The expanded
Emission card shows editable fields and the per-field circular restore affordance
after changing Gamma EOTF. The application log contains source/device/result
dimensions and publication revisions and contains no SwiftUI
`Publishing changes from within view updates` fault after the fix.

QA evidence:

- `/private/tmp/screen-general-switches-aligned.png`
- `/private/tmp/screen-parameter-restore-arrow.png`
- `/private/tmp/screen-p0-card-emission-expanded.png`
- `/private/tmp/screen-p0-card-capture-collapsed.png`
- `/private/tmp/screen-p0-release-native-complete.png`

Reduced human checklist for the next review:

1. Editorial, frequency/moire and color patterns in Fit, Fill/Crop, Stretch and
   1:1 at Draft, Medium, High and Native; framing must remain identical.
2. RGB and BGR, fill/black matrix, alpha and Panel Light Spread at 0, 1 and >1.
3. Every continuous amount at 0, 1 and >1; CFA and Develop disabled/enabled.
4. All intermediates in order plus twelve diagnostics, fused group timings and
   the `STATIC_INPUT` marker.
5. Native progress, cancel and stale state while retaining the prior result.
6. In 1:1, drag from the original point beyond the viewport and release; verify
   final clamp, closed-hand cursor and zoom anchored under the cursor.
7. Neutral device background without preview border/elevation, resizable
   inspector, aligned label/slider/numeric columns, clean slider tracks,
   native switches in General, per-field circular restore buttons, tooltips,
   keyboard navigation and accessibility labels.

No hardware DeckLink result is claimed. Enumeration/error behavior and build
contract are tested without simulating success.
