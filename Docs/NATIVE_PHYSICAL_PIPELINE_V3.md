# Unified native physical pipeline v3

Status: complete Rust/Metal migration cut for adoption by the native macOS shell.

Evidence date: 2026-08-06. Branch: `feature/physical-panel-spatial-v1`.

## One contract and one product route

ABI v3 is the only live physical-frame ABI. One coarse request carries ordered,
immutable Source ACEScg and nonlinear Device Signal samples at exact rational
times, explicit raster placement, retained Metal texture handles, camera and
screen pose tracks, the exact shutter interval, an explicit source-sampling
policy, resolved Device and pipeline snapshots, ordered contributions and one
requested intermediate. Rust owns validation, temporal scheduling and the fixed
stage order. Metal is the macOS product backend. CPU implementations are test
oracles only and are never selected as a product fallback.

The timed input set retains every borrowed Metal texture handle until the job
completes or is cancelled, and releases it deterministically with the job-owned
snapshot. Swift receives borrowed opaque result and diagnostic views; no Metal
intermediate ownership crosses the ABI. There are no render-time callbacks,
preset lookups, implicit defaults, compatibility readers or backend selectors.

`capture_amount` was removed from the layout: CFA and Develop are discrete
stage enables, while Shutter and Noise have their own continuous amounts. A
continuous capture-domain blend would have been physically false because RAW
topology and sensor dimensions can change. `camera_target`, stored yaw and
`screen_scale` are likewise absent. Position plus quaternion are the sole pose
authority and Device active dimensions are the sole physical size authority.

## Fixed executed pipeline

```text
Source ACEScg + Device Signal + placement
  -> panel EOTF / black / luminance / native primaries
  -> RGB or BGR subpixel geometry / fill / black matrix
  -> physical panel light spread
  -> rational temporal emission integral
  -> resolved camera/screen relative geometry and ideal projection
  -> cover glass transmission + synthetic HDR environment reflection
  -> generalized lens character and projection
  -> exact global/rolling shutter integration and motion scheduling
  -> sensor exposure + Bayer CFA + full well / clipping / ADC
  -> deterministic shot / dark / read noise
  -> RAW mosaic or edge-directed demosaic + WB + sensor-to-ACEScg develop
  -> linear ACEScg result
```

All stages above are implemented in the unified executor. ODT/view, media
decode and StudioColor Source-to-Device remain deliberately outside physics.
The request can return Source ACEScg, Device Signal, Panel Emission, Subpixel
Radiance, Panel Light Spread, Cover/Environment, Scene/Geometry/Lens,
Shutter/Motion, Sensor/Noise, RAW Mosaic or Developed ACEScg. Invalid domain or
enable combinations fail explicitly.

Panel light spread is extracted from `b58525cec55d006879b5fb5e9f47399148378130`:
the historical energy-normalized nine taps per channel, physical core/tail
radii in micrometers and resolved LCD/OLED/micro-LED profile. Temporal emission
reuses the exact rational residual-flicker and optional analytic-banding model;
bands are disabled by default. Cover/environment, geometry/lens, shutter,
sensor/noise and camera development reuse the previously audited Rust/Metal
authorities rather than parallel rewrites.

Static requests still provide one explicit Source/Device sample and constant
pose tracks. Diagnostics report `STATIC_INPUT`; motion blur is claimed only
when the supplied sample/pose history supports it. Multi-sample requests must
cover the required shutter plus rolling-readout interval. Missing coverage is
an error with required and available ranges—never frozen input or 2D blur.

## Contribution and quality semantics

- Continuous stages accept 0 through 4: zero is the exact stage bypass where
  the domain permits it, one is calibrated, and values above one extrapolate
  the historical model within validated limits.
- RGB/BGR and Bayer/CFA are discrete. Develop is a discrete domain transition.
  They are never interpolated as colors.
- Draft, Medium, High and Native preserve placement, physical frame, exposure,
  time domain and color meaning. Only the lattice/sample precision changes.
- Native resolves the authoritative 3x3 panel subpixel lattice. Native remains
  explicit/user-requested; progress, matching cancellation and parameter hash
  permit stale-result handling by the host.

## Diagnostics and timing

Results contain twelve ordered stage diagnostics, progress/state, returned
intermediate, effective result dimensions and parameter revision/hash. Stages
0–8 are a single fused physical Metal kernel, so each reports the same measured
group elapsed time; no fictional split is invented. Sensor/Noise/Develop are a
second fused command group and report that measured group time. Failed and
cancelled jobs publish no partial authoritative result.

## Numeric evidence

Workspace tests cover exact amount-zero identity, amounts 1 and greater than 1,
negative and above-one RGB, alpha, all placements, RGB/BGR, black matrix, all
four qualities, exact rational scheduling, constant and animated poses/sources,
global and per-row rolling shutter, motion sample counts 1 and greater than 1,
insufficient temporal coverage, retained-handle lifetime, cancellation and
determinism. CPU/Metal coverage includes every physical cut. Spatial tolerance
is absolute `2e-3` or relative `2e-4`; raw noise parity is one ADC code at noise
zero and four codes with deterministic noise; developed ACEScg is `3e-4`.
Frozen intermediate goldens include the distinct RAW and Developed domains.

Latest complete gate on this branch:

- `cargo fmt --all -- --check`: pass.
- `cargo clippy --workspace --all-targets -- -D warnings`: pass.
- `cargo test --workspace`: pass (57 application, 8 conformance, 30 platform,
  9 sensor, 7 bridge, plus all other workspace suites).
- `python3 scripts/check_architecture.py`: pass.
- `git diff --check`: pass.

## Reproducible Metal benchmark

Command:

```text
cargo run --release -p screen-platform --example physical_pipeline_benchmark
```

Measured 2026-08-06 on Apple M3 Ultra using two UHD 3840x2160 RGBA32Float input
textures and the calibrated physical screen path. Setup was 1.736 ms. Times and
allocated texture bytes are direct measurements from this run, not projections.
The benchmark disables the later sensor command so these figures isolate the
quality-dependent screen lattice; the capture stages have independent parity
tests and stage-group timing diagnostics.

| Device | Quality | Output | Samples/px | Resolved | First tile | Total | Peak texture bytes |
|---|---:|---:|---:|---:|---:|---:|---:|
| Phone 4.7 Retina | Draft | 360x640 | 1 | no | 16.877 ms | 45.622 ms | 269,107,200 |
| Phone 4.7 Retina | Medium | 960x1708 | 4 | no | 2.205 ms | 36.650 ms | 291,655,680 |
| Phone 4.7 Retina | High | 1920x3415 | 16 | no | 7.103 ms | 183.201 ms | 370,329,600 |
| Phone 4.7 Retina | Native | 2250x4002 | 1 | yes | 5.183 ms | 39.203 ms | 409,492,800 |
| MacBook Pro Retina 14 | Draft | 360x234 | 1 | no | 9.225 ms | 33.750 ms | 266,768,640 |
| MacBook Pro Retina 14 | Medium | 960x623 | 4 | no | 3.046 ms | 26.640 ms | 274,990,080 |
| MacBook Pro Retina 14 | High | 1920x1247 | 16 | no | 4.975 ms | 77.384 ms | 303,728,640 |
| MacBook Pro Retina 14 | Native | 9072x5892 | 1 | yes | 28.062 ms | 124.870 ms | 1,120,656,384 |
| ASUS ProArt PA329CV | Draft | 360x203 | 1 | no | 12.663 ms | 36.604 ms | 266,590,080 |
| ASUS ProArt PA329CV | Medium | 960x540 | 4 | no | 3.198 ms | 25.015 ms | 273,715,200 |
| ASUS ProArt PA329CV | High | 1920x1080 | 16 | no | 5.181 ms | 73.604 ms | 298,598,400 |
| ASUS ProArt PA329CV | Native | 11520x6480 | 1 | yes | 37.060 ms | 153.506 ms | 1,459,814,400 |

First-tile time includes the first completed 64-row work unit and can exceed
total/throughput intuition because Metal warm-up and quality work differ. Native
uses one resolved sample at each 3x3 subpixel lattice point; High uses sixteen
integration samples at a smaller publication lattice.

## Legacy-to-unified disposition

| Historical model | Current disposition | Material change / limitation |
|---|---|---|
| Source placement and Device Signal | Reused and migrated | StudioColor remains sole Device Signal authority. |
| Emission/EOTF/color/angular response | Reused and migrated | Angular response now consumes quaternion scene geometry. |
| Subpixels/RGB-BGR/fill/black matrix | Reused and migrated | Native 3x3 lattice is authoritative. |
| Pixel bloom / Panel Light Spread | Extracted from `b58525c` and migrated | No blur fallback; finite-panel edge loss retained. |
| Flicker and creative analytic banding | Reused and migrated | No panel scanout/persistence model is claimed. |
| Cover glass and synthetic HDR environment | Reused and migrated | External HDR texture ingestion was not an implemented historical model. |
| Camera/screen geometry and lens | Reused and migrated | Pose is position+quaternion only; no stored target/yaw/scale. |
| Global/rolling shutter and motion | Reused and migrated | Requires explicit timed samples/tracks; no freeze fallback. |
| Sensor, CFA, well, clipping, ADC and noise | Reused and migrated | Counter-based deterministic noise retained. |
| RAW, demosaic, WB and ACEScg develop | Reused and migrated | RAW and Developed remain distinct typed domains. |
| ODT/view | Outside physical engine | StudioColor authority retained. |
| Keyframe evaluation | Contract/executor migrated | Timeline editor/import UI is a later host feature. |
| Refresh mismatch, persistence, panel scanout | Future, never historically implemented | Must not be approximated by analytic banding. |
| External camera import | Future product work | Timed pose tracks are ready; no importer is claimed. |
| Stabilization/corner pin/baked device | Future, no historical implementation | Requires a separate domain decision. |
| Sensor bloom/crosstalk | Future, documented only | No substitute blur is present. |

No previously implemented physical model remains silently missing. Items in the
last five rows are explicitly future or outside the physical engine.

## Swift adoption boundary and QA

The complete range is adopted by `feature/native-macos-shell`. Its isolated
native graph uses `screen-platform(flat-panel-metal)` with defaults disabled;
FFmpeg/libav is neither linked nor restored. The native executable, all Swift
tests, ABI-v2 gate and graph/Mach-O/rpath/symbol/resource no-FFmpeg gate pass.
AVFoundation, VideoToolbox and ImageIO remain the only native I/O route.

The Swift host constructs explicit timed input and constant position/quaternion
tracks for the selected static frame, owns resolved immutable snapshots and
opaque-handle lifetimes, and does not own or reproduce physical calculations.
Full adoption evidence and the outstanding manual visual review are recorded in
`Docs/NATIVE_PHYSICAL_INTEGRATION_REPORT.md`.

Unified visual/functional QA for adoption:

1. Compare Source, Device Signal and every intermediate on negative, above-one
   and alpha charts; ODT only after Developed ACEScg.
2. Check Fit, FillCrop, Stretch and centered OneToOne at all qualities without
   framing/domain drift.
3. Check RGB/BGR impulses, fill factor, black matrix and per-channel light
   spread at amounts 0, 1 and greater than 1.
4. Check flicker uniformity, optional banding, environment isolation, cover
   Fresnel/AR/roughness and rotated synthetic HDR patterns.
5. Check identity quaternion, known yaw/pitch quaternion, device physical size,
   focus plane, f-stop, distortion, CA, vignette and PSF.
6. Check static, animated source, camera and screen tracks; global/rolling both
   directions; missing temporal coverage must fail explicitly.
7. Check four Bayer phases, clipping/full-well/ADC, deterministic seeds, noise
   0/1/>1, RAW mosaic and Developed ACEScg.
8. Exercise progress, matching/nonmatching cancellation, retained input lifetime,
   stale Native publication and intermediate dimensions.
9. Confirm twelve ordered diagnostics and honest fused-group timing labels.
10. Prove with the native feature graph that no ABI v1, orphan shader/evaluator,
    CPU fallback, FFmpeg/libav or default/full-platform dependency is reachable.

## Commit range for native adoption

Apply `c852ca8^..HEAD` from `feature/physical-panel-spatial-v1`. The range begins
with the typed unified contract and includes migration, tests, diagnostics and
documentation. The native-shell coordinator should resolve only Swift host-side
UI/orchestration conflicts; Rust/Metal semantics and the ABI header are the
authority from this range.
