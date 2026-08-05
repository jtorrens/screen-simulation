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

When the camera transform, camera intrinsics and screen transform each contain one authored key,
Application may also clone one fully validated procedural plan template for later exact times and
sensor rows. It changes only the rational time, procedural time and sensor window, and recomputes
the representative signal fields exactly. It does not reuse a spatial result: every authored
motion sample is still evaluated by the backend. Conformance requires each instantiated plan to be
field-for-field equal to a freshly prepared plan.

Temporal integration parallelizes independent sensor pixels for global shutter and independent
sensor rows for rolling shutter. Sample accumulation inside a pixel or row retains its authored
order, so thread scheduling cannot change floating-point addition order. Sensor exposure likewise
parallelizes independent photosites; CFA phase and counter-based noise remain keyed to global
coordinates. Tests require identical exposures and RAW results with one and multiple Rayon workers.

Native work retains 128-pixel sensor tiles as its logical progress and cancellation boundary, but
the macOS scheduler evaluates all horizontal tiles in a 128-row stripe as one exact product region.
This shares row-plan preparation and one Metal batch across the image width. The developed stripe
is then split only for staging publication; it is bit-identical to evaluating its logical tiles
separately. Cancellation is checked before stripe compute and before every logical-tile publication.
Completed staging remains non-authoritative and a cancelled job never publishes a partial result.

Presentation is a separate platform port. `DisplayPublicationBackend` accepts immutable developed
linear ACEScg and returns the final level-zero RGBA8 bytes; it cannot alter capture, exposure or any
physical result. Desktop composes exactly one mandatory implementation. The current implementation
uses the pinned OCIO GPU processor's generated MSL, complete LUT resources and direct RGBA8
quantization in one Metal dispatch. It has no runtime Metal/CPU selection and no fallback. Preview
remains outside this Native publication port, while Native export consumes the unchanged returned
bytes. The parallel CPU implementation remains compiled only as a benchmark and conformance oracle;
Desktop never composes it.

Metal fast math is disabled. Conformance compares generated MSL plus GPU quantization against the
pinned CPU processor over grays, primaries, negatives, values above one, non-finite values and
65,536 dense threshold-adjacent ramps. Across 262,164 RGBA channels per transform, the current
configuration differs in 86 sRGB channels, 78 Rec.709 channels and 3 Rec.2100 PQ channels; every
difference is exactly one 8-bit code value. The enforced limit is one code value and 0.5% differing
channels. Expanding that tolerance requires an explicit architecture change, not an adapter choice.

The reproducible benchmark is:

```text
cargo run --release -p screen-desktop --bin native_benchmark
```

`SCREEN_BENCH_STRIPE_HEIGHT` may override the diagnostic stripe height for profiling only. It does
not alter the product's 128-row physical stripe or 128-pixel logical progress boundary.

It reports cold Metal setup, time to the first complete Native tile, end-to-end physical throughput
for the iPhone 16e model with rolling shutter for both the default one-motion-sample case and a
static eight-motion-sample case, a staged 1536×1152 ROI breakdown, the actual 8064×128 product
stripe, measured 48 MP extrapolations, and isolated CPU/Metal RAW-development time. Metal uses
unified `StorageModeShared`, so explicit device/host transfer is zero; shared-buffer result
materialization is included in the Metal stage. Extrapolation is diagnostic evidence, not a
promise: it assumes linear stripe scaling for the same authored scene and hardware.

The pre-port 2026-08-05 release measurement on Apple M3 Ultra reported 2.065 s to the first
128×128 product tile, 7,936 sensor pixels/s and a 1.7 h linear 8064×6048 extrapolation.

After exact static reuse, the representative release run reported 0.047 s cold setup and 0.080 s
to the first complete 128×128 default tile. The default rolling/one-motion-sample path measured
205,276 sensor pixels/s, corresponding to a 4.0 minute linear iPhone 16e 48 MP extrapolation. The
static/eight-motion-sample case preserved 1,048 authored row/sample intervals while referencing 131
unique spatial plans, completed the tile in 0.071 s at 231,147 pixels/s and extrapolated to 3.5
minutes. Run-to-run GPU variance makes the small ordering difference between those two cases
non-semantic; both execute one unique spatial evaluation per rolling row.

The large-ROI run established the real fixed cost. A 1536×1152 default capture took 0.649 s:
0.575 s CPU plan preparation, 0.032 s Metal plus shared result materialization, 0.036 s temporal
integration and sensor, and 0.006 s RAW Metal. Static/eight took 0.664 s with the same exact
integration. Thus the previous minute-scale number was an invalid extrapolation of per-tile plan
preparation, not sustained GPU work.

With horizontal stripe scheduling connected to the product, an actual 8064×128 iPhone stripe took
about 0.10 s through developed linear ACEScg for both default/one-sample and static/eight. Before
the presentation change, serial CPU OCIO plus RGBA8 assembly added about 0.248 s.

The 2026-08-05 release measurement of the exact parallel publication backend on Apple M3 Ultra
reported 0.013 s setup and 0.018–0.021 s per 8064×128 stripe. The unchanged serial oracle split was
0.002 s float RGBA materialization, 0.241 s OCIO and 0.002 s quantization/assembly. Product stripes
completed in 0.124 s default/one-sample and 0.126 s static/eight, including 0.000 s output copy and
0.003 s staging, and exposed 63 logical progress tiles. Forty-eight stripes project to 5.9 s and
6.1 s respectively for the 8064×6048 sensor. This projection includes exact eight-interval temporal
integration in the static case and applies analytic row gain once; it changes no capture samples.

Static rolling rows now clone one fully validated spatial-plan template and change only its exact
time and sensor-row window. This optimization is enabled by the same explicit static/single-key
proof as spatial reuse. A conformance test requires the instantiated template to equal a freshly
prepared plan field for field, and the rolling test requires one preparation while retaining all
eight authored gain intervals and one backend plan per row. Animated sources and any multi-keyframe
spatial track still prepare the complete plans.

After exact procedural template instantiation and deterministic parallel integration/sensor
exposure, three representative 2026-08-05 release runs on Apple M3 Ultra measured 2.3–2.6 s and
2.4–2.7 s projected for the complete 8064×6048 sensor with CPU publication. Replacing only that
boundary with the single Metal authority reduced publication from roughly 0.019–0.026 s to
0.004–0.005 s per 8064×128 stripe. Three complete product-path measurements projected 1.5–1.6 s for
animated default/one-motion-sample and 1.8–1.9 s for static/eight. These are measured projections,
not a product latency guarantee. Motion samples, per-row rolling timing, analytic panel gain, RAW
and development are unchanged. Old PWM subdivision and CPU optics remain absent from the product
route.

Remaining performance work is precisely bounded:

1. Reduce exact spatial Metal cost without introducing another evaluator or loosening parity.
2. Share prepared linear-emission storage across time-equivalent decoded media samples.
3. Extend proof of static intervals beyond single-key tracks only where exact keyframe-segment
   identity can be established without heuristic tolerances.
4. Reduce exact CPU row-plan construction for moving spatial tracks without weakening
   authored motion detection, source sampling or temporal integration.
