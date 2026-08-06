# Native unified physical integration report

Date: 2026-08-06. Host: Apple M3 Ultra, macOS 15.6.

## Adopted authority

The native shell applies the complete owner range
`73a5c72d937bb88b443e7ca90d29716fbc6f6557..3c78b6731f6ecb3dd0f817dcc206bd824a7156ed`
in order. The only live product entry point is
`screen_physical_frame_submit` with `SCREEN_PHYSICAL_FRAME_ABI_VERSION 2`.
The Swift consumer materializes and retains one complete immutable Device and
pipeline snapshot per job, then releases every opaque handle with the job.

StudioColor produces both Source ACEScg and the nonlinear Device Signal. The
physical result remains outside preview, DeckLink and render color policy. When
the Device Signal intermediate is inspected, its exact matching inverse display
processor runs in StudioColor before the normal preview ODT/ColorSync path; it
is never treated as linear ACEScg.

Implemented product stages are Emission, Subpixel Geometry and Panel Light
Spread. Temporal, Cover, Environment and all Capture stages remain visible but
disabled. A nonzero API request for any unsupported stage is rejected at the
coarse submission boundary.

## Automated validation

- Swift: 37 tests passed, including six supported intermediates, exact amount-0
  texture identity, RGB/BGR, four placements, black matrix, spread 0/1/2.5,
  matching cancellation and rejection of unsupported active stages.
- Rust workspace: 181 tests passed, including five physical conformance tests.
- `cargo fmt --all -- --check` passed.
- `cargo clippy --workspace --all-targets -- -D warnings` passed. Cargo reports
  only the upstream future-incompatibility notice for `block 0.1.6`.
- Architecture ownership, diff check, ABI-v2 source/header/symbol gate and
  native no-FFmpeg graph/Mach-O/rpath/resource gate passed.
- The native dependency edge is
  `screen-native-bridge -> screen-platform(flat-panel-metal)` with
  default features disabled. AVFoundation, VideoToolbox and ImageIO remain the
  sole native I/O route.
- Release bundle passed strict deep codesign verification with an ad-hoc
  signature. Executable SHA-256:
  `cbb2df0073efa9d1682a3569798c0e6cb2e18db99f30161ed1799851a6c3f500`.

## Measured Release performance and memory

Command: `cargo run --release -p screen-platform --example physical_pipeline_benchmark`.
Input is one 3840×2160 RGBA32Float source. Memory is exact allocated texture
storage, not RSS and not an extrapolation.

| Device | Quality | Output | First tile | Total | Peak texture bytes |
|---|---:|---:|---:|---:|---:|
| Phone 4.7 Retina | Draft | 360×640 | 18.540 ms | 49.796 ms | 269,107,200 |
| Phone 4.7 Retina | Medium | 960×1708 | 1.915 ms | 30.659 ms | 291,655,680 |
| Phone 4.7 Retina | High | 1920×3415 | 5.906 ms | 124.925 ms | 370,329,600 |
| Phone 4.7 Retina | Native | 2250×4002 | 5.465 ms | 30.122 ms | 409,492,800 |
| MacBook Pro Retina 14 | Draft | 360×234 | 8.160 ms | 30.679 ms | 266,768,640 |
| MacBook Pro Retina 14 | Medium | 960×623 | 2.738 ms | 23.595 ms | 274,990,080 |
| MacBook Pro Retina 14 | High | 1920×1247 | 3.771 ms | 57.357 ms | 303,728,640 |
| MacBook Pro Retina 14 | Native | 9072×5892 | 26.961 ms | 99.926 ms | 1,120,656,384 |
| ASUS ProArt PA329CV | Draft | 360×203 | 12.108 ms | 34.685 ms | 266,590,080 |
| ASUS ProArt PA329CV | Medium | 960×540 | 2.899 ms | 21.937 ms | 273,715,200 |
| ASUS ProArt PA329CV | High | 1920×1080 | 4.323 ms | 54.385 ms | 298,598,400 |
| ASUS ProArt PA329CV | Native | 11520×6480 | 36.647 ms | 122.794 ms | 1,459,814,400 |

## Display and visual QA status

The active display reported by AppKit/ColorSync is ASUS PA329CV, 3840×2160,
scale 1, EDR 1.0, with profile
`/Library/ColorSync/Profiles/Displays/ASUS PA329CV-F3C58FD7-6A52-4D86-B8A3-255A0F791CB0.icc`.

Manual visual QA is not closed. The desktop capture returned a fully black
frame and the locked/inaccessible window server exposed no application window,
so no visual claim is inferred from automated launch, tests or signatures.
Review the signed bundle manually with this checklist:

1. Frequency/moire and editorial patterns in Fit, Fill/Crop, Stretch and 1:1.
2. RGB and BGR presets, black-matrix/fill changes and alpha edges.
3. Emission, Subpixel and Spread at 0, 1 and greater than 1; sliders have no
   ticks, step by 0.05 and detent exactly at 1.
4. Source, Device, Emission, Subpixel, Spread and Developed diagnostics in
   order; Device must retain the expected appearance through its inverse.
5. Draft, Medium, High and Native retain framing; Native keeps the prior result
   while stale, reports progress and cancels.
6. Neutral viewport outside the device surface, no preview border/elevation,
   resizable inspector, aligned label/slider/numeric columns and accessibility.

No hardware DeckLink result is claimed. Enumeration/error behavior and build
contract are tested without simulating success.
