# Native compute backend

Status: normative.

Native capture has one Application orchestration path and one result contract. Physical owners
prepare and validate immutable inputs; a narrow compute port may execute an owned numeric operation
without acquiring its semantics. A platform backend receives complete typed values and must return
the same authoritative result type. It cannot choose quality, samples, shutter behavior, placement,
color interpretation, sensor identity or development settings.

On the supported macOS product, Native RAW development is executed by `screen-platform` through
Metal. `screen-camera` owns validation, Bayer reconstruction, native-sensor white balance, the
sensor-to-ACEScg matrix and exposure placement; its prepared development plan is the only numeric
contract accepted by the Metal adapter. The packaged Desktop requires Metal backend creation and
fails the requested capture explicitly if it is unavailable. It has no runtime CPU fallback.
`CpuRawDevelopment` remains the deterministic oracle for parity tests.

The current Metal slice uses two ordered compute passes: edge-directed green reconstruction, then
red/blue color-difference reconstruction plus camera development. Its embedded metallib is compiled
from the owned `.metal` source at build time and is also copied into the macOS bundle resources for
packaging inspection. The only platform unsafe operation maps a completed shared Metal output buffer
into an immutable Rust copy; the allocation size, completion ordering and lifetime are audited at
that boundary.

Metal/CPU parity for developed linear ACEScg uses a maximum absolute channel tolerance of `2e-5`
over all four Bayer patterns, odd global CFA origins, edge support and aggressive white balance and
develop exposure. Raw sensor codes and clipping masks are still produced by the unchanged CPU sensor
owner and are bit-identical because Metal begins strictly after the authoritative RAW boundary.

Application also owns a modulation-free `SpatialOpticalPlan` and `SpatialOpticalBackend` port. The
plan contains the validated camera and screen samples, sensor window, panel geometry and
colorimetry, cover and environment, globally selected 16–128 aperture sample count, and either the
procedural signal or prepared raster signal plus linear post-EOTF emission. It deliberately cannot
represent panel temporal modulation. The macOS adapter executes Brown-Conrady inversion, aperture
and thin-lens rays, chromatic offsets, resolved or area-integrated panel structure, EOTF, cover
Fresnel/transmission/reflection and native-to-ACEScg conversion in one Metal kernel. Physical
domains contain no Metal dependency, and a future Windows adapter can implement the same port.

The scalar implementation remains available only through explicitly named CPU-oracle functions.
Optical conformance currently covers procedural and raster signals, RGB/BGR layouts, resolved and
unresolved integration, high black-matrix coverage, strong lens distortion and active cover
character. The explicit channel tolerance is maximum absolute `2e-3` or maximum relative `2e-4`;
panel-hit identity must be exact.

Desktop selects the same `MetalRawDevelopment` adapter for both Application compute ports. There is
no product CPU route or legacy PWM route. Application owns shutter scheduling and multiplies the
modulation-free Metal result by each analytically integrated panel gain exactly once. Tests prove
that `analytic_banding.amount == 0` is exact identity, that eight requested motion samples create
eight spatial samples, and that a complete eight-sample rolling capture preserves CPU-oracle RAW
codes and clipping masks exactly. Developed ACEScg remains within `2e-5`.

Rolling row/sample plans are submitted through the batch port. Plans that share procedural or
static raster storage use one parameter array, one signal upload and one Metal dispatch; distinct
animated raster samples retain their exact authored source and may require separate dispatches.
The batch changes command granularity only and never drops a row or motion sample.

Application reuses a spatial result only when the source is explicitly static and camera
transform, camera intrinsics and screen transform each contain exactly one authored keyframe. It
still constructs and integrates every requested shutter interval and its analytical per-row gain;
only the identical modulation-free spatial value is referenced more than once. An animated
procedural source, media sequence or any multi-keyframe spatial track selects the complete plan
batch automatically. This is an optimization inside the same result contract, not another route.

Native work is partitioned into 128-pixel sensor tiles. Progress publishes after each completed tile
and cancellation is checked before the next tile. Completed staging remains non-authoritative and a
cancelled job never publishes a partial result.

The reproducible benchmark is:

```text
cargo run --release -p screen-desktop --bin native_benchmark
```

It reports cold Metal setup, time to the first complete Native tile, end-to-end physical throughput
for the iPhone 16e model with rolling shutter for both the default one-motion-sample case and a
static eight-motion-sample case, measured 48 MP extrapolations, and isolated CPU/Metal
RAW-development time. Extrapolation is diagnostic evidence, not a promise: it assumes linear pixel
scaling for the same authored scene and hardware.

The pre-port 2026-08-05 release measurement on Apple M3 Ultra reported 2.065 s to the first
128×128 product tile, 7,936 sensor pixels/s and a 1.7 h linear 8064×6048 extrapolation.

After exact static reuse, the representative release run reported 0.047 s cold setup and 0.080 s
to the first complete 128×128 default tile. The default rolling/one-motion-sample path measured
205,276 sensor pixels/s, corresponding to a 4.0 minute linear iPhone 16e 48 MP extrapolation. The
static/eight-motion-sample case preserved 1,048 authored row/sample intervals while referencing 131
unique spatial plans, completed the tile in 0.071 s at 231,147 pixels/s and extrapolated to 3.5
minutes. Run-to-run GPU variance makes the small ordering difference between those two cases
non-semantic; both execute one unique spatial evaluation per rolling row.

The isolated spatial kernel delivered its first tile in 0.010 s and sustained 13.19 million
pixels/s, a 3.7 s one-sample 48 MP extrapolation. Isolated 1024×768 RAW development measured
0.017 s CPU versus 0.003 s Metal, or 5.53×. For moving sources or multi-keyframe geometry, exact
motion sampling remains the dominant cost; old PWM subdivision and CPU optics are absent from the
product route.

Remaining performance work is precisely bounded:

1. Share prepared linear-emission storage across time-equivalent decoded media samples.
2. Extend proof of static intervals beyond single-key tracks only where exact keyframe-segment
   identity can be established without heuristic tolerances.
3. Consider multi-tile GPU scheduling only if it preserves sub-second progress and cooperative
   cancellation at the existing publication boundary.
