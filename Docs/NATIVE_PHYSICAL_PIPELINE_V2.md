# Unified native physical pipeline v2

Status: implemented first functional cut; authoritative Rust/Metal handoff.

## Delivered contract

The sole live C contract is ABI version 2. Version 1 types, symbols and runtime
readers do not coexist with it. One coarse request owns the complete immutable
meaning of a frame:

1. source linear ACEScg and nonlinear Device Signal texture views;
2. explicit Fit, FillCrop, Stretch or OneToOne placement;
3. a resolved Device snapshot including emission, subpixel topology, temporal
   data and the complete panel-light-spread profile;
4. a resolved pipeline snapshot including cover, environment, scene/camera,
   lens, shutter/readout/motion, sensor/noise and RAW development;
5. ordered stage controls, requested quality and one typed intermediate;
6. cancellation/progress identities and parameter revision/hash.

Rust owns the fixed 12-stage order. Metal is the mandatory product backend;
the scalar CPU evaluator remains an oracle for tests. Swift crosses the ABI
once per job and never owns physical equations or Metal resources produced by
an intermediate.

## Functional and unsupported stages

The first cut evaluates, in order:

1. Panel Emission;
2. Subpixel Geometry;
3. Panel Light Spread.

Light spread is extracted from `b58525cec55d006879b5fb5e9f47399148378130`:
the same 9 deterministic energy-normalized taps per channel, physical core and
tail radii in micrometers, per-channel weights and contained LCD/OLED/micro-LED
profiles. Amount 0 takes the exact unspread path, 1 is calibrated and values up
to 4 scale physical radii safely. RGB/BGR remains a discrete topology.

Temporal, Cover, Environment and every Capture stage require complete valid
snapshots but reject nonzero/enabled controls. Their ordered diagnostics say
`unsupported`; no shader, identity stub or CPU fallback pretends to process
them.

Supported intermediate requests are Source ACEScg, Device Signal, Panel
Emission, Subpixel Radiance, Panel Light Spread and the current Developed
ACEScg endpoint. Requests for later intermediates fail explicitly. Each result
reports the returned domain, dimensions, quality, progress, parameter identity
and 12 ordered stage diagnostics. Current supported stages share one fused
Metal dispatch, so their diagnostic time is the measured fused job duration,
labelled as such rather than misreported as isolated stage timings.

## Numeric validation

- Frozen 64-bit domain goldens cover all six supported intermediates.
- CPU/Metal parity covers amounts 0, 1 and 2.5, negative and above-one RGB,
  alpha, four placements, RGB/BGR, black-matrix extremes and all qualities.
- Maximum accepted absolute CPU/Metal error remains `2e-3`; the shader uses
  safe Metal math and float32 authoritative output.
- Amount 0 returns the exact source texture for the final endpoint, including
  float bits and alpha.
- The light-spread kernel sums to one per channel; loss occurs only when energy
  exits the finite panel boundary.

## Reproducible Metal benchmark

Command:

```text
cargo run --release -p screen-platform --example physical_pipeline_benchmark
```

Measured 2026-08-06 on Apple M3 Ultra with one UHD RGBA32Float source and
calibrated LCD light spread. Memory is exact allocated texture storage. Every
time below is measured by that run; none is extrapolated.

| Device | Quality | Output | Samples/px | First tile | Total | Peak texture memory |
|---|---:|---:|---:|---:|---:|---:|
| Phone 4.7 Retina | Draft | 360×640 | 1 | 17.955 ms | 51.674 ms | 269,107,200 B |
| Phone 4.7 Retina | Medium | 960×1708 | 4 | 2.024 ms | 33.225 ms | 291,655,680 B |
| Phone 4.7 Retina | High | 1920×3415 | 16 | 5.448 ms | 125.456 ms | 370,329,600 B |
| Phone 4.7 Retina | Native | 2250×4002 | 1 | 4.883 ms | 29.306 ms | 409,492,800 B |
| MacBook Pro Retina 14 | Draft | 360×234 | 1 | 8.078 ms | 30.930 ms | 266,768,640 B |
| MacBook Pro Retina 14 | Medium | 960×623 | 4 | 2.974 ms | 23.753 ms | 274,990,080 B |
| MacBook Pro Retina 14 | High | 1920×1247 | 16 | 3.811 ms | 56.930 ms | 303,728,640 B |
| MacBook Pro Retina 14 | Native | 9072×5892 | 1 | 27.588 ms | 100.149 ms | 1,120,656,384 B |
| ASUS ProArt PA329CV | Draft | 360×203 | 1 | 11.922 ms | 34.452 ms | 266,590,080 B |
| ASUS ProArt PA329CV | Medium | 960×540 | 4 | 2.876 ms | 21.875 ms | 273,715,200 B |
| ASUS ProArt PA329CV | High | 1920×1080 | 16 | 4.276 ms | 54.327 ms | 298,598,400 B |
| ASUS ProArt PA329CV | Native | 11520×6480 | 1 | 37.028 ms | 123.384 ms | 1,459,814,400 B |

Quality preserves the full panel domain and placement. Draft, Medium and High
change only output lattice and integration precision; Native resolves the
authoritative 3×3 subpixel lattice.

## Swift adoption QA

1. Build the native package against the v2 header and current static library;
   any old-version type must fail at compile time.
2. Materialize every snapshot field explicitly; never resolve a preset ID in
   the frame worker or fill missing data with a default.
3. Verify Fit letterbox, FillCrop crop, Stretch and centered OneToOne with the
   same framing at all four qualities.
4. Verify RGB and BGR impulse charts, black-matrix borders and per-channel
   light-spread radii at 0, 1 and greater than 1.
5. Verify negatives, values above 1 and alpha survive Source and final outputs;
   Device Signal remains explicitly nonlinear.
6. Request each supported intermediate and confirm `returned_intermediate`;
   later intermediates must fail instead of returning the final texture.
7. Exercise progress, matching and nonmatching cancellation identities,
   failed jobs, Native stale publication and parameter revision/hash changes.
8. Confirm all 12 diagnostics retain order; only the first three process and
   later stages remain explicitly unsupported.

## Honest limitations

- Camera, lens, cover/environment, temporal, shutter/motion, sensor/noise and
  RAW development are transported but not evaluated by this cut.
- Supported-stage timing is fused job time, not isolated GPU counter timing.
- Native memory is dominated by UHD input plus the 3×3 physical output lattice.
- UI controls for the new snapshots and intermediate selector belong to the
  coordinated Swift adoption and are intentionally not implemented here.
