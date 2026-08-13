# Native compute backend

Status: normative.

The host-only `Setup` preview is deliberately outside the native physical frame ABI. It evaluates only ideal pinhole projection from the authored camera and screen geometry, samples the source with its authored placement, applies Delivery Raster placement, and draws the diagnostic Device boundary. No panel, cover, environment, lens-aberration, exposure, sensor or develop kernel is dispatched in Setup.

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
red/blue color-difference reconstruction plus camera development. In the complete physical route,
the second pass publishes directly into the final RGBA32Float texture; it does not allocate a
complete developed float4 buffer or dispatch a third publication pass. The standalone development
parity adapter evaluates the same development function into a shared output buffer because its
host-neutral Rust result requires an immutable CPU copy. Its embedded metallib is compiled from the
owned `.metal` source at build time and is also copied into the macOS bundle resources for packaging
inspection. The standalone adapter's only platform unsafe operation maps that completed shared
Metal output buffer into an immutable Rust copy; the allocation size, completion ordering and
lifetime are audited at that boundary.

Metal/CPU parity for developed linear ACEScg uses a maximum absolute channel tolerance of `2e-5`
over all four Bayer patterns, odd global CFA origins, edge support and aggressive white balance and
develop exposure. Raw sensor codes and clipping masks, including calibrated neighbour crosstalk and
nonrecursive overflow transfer, are still produced by the CPU sensor
owner and are bit-identical because Metal begins strictly after the authoritative RAW boundary.
The native macOS Test adapter follows the same boundary: its coarse Metal physical pass stops at
shutter-integrated linear exposure, Application performs the higher-precision photosite-footprint
integration, expands regional work by the sensor bloom model's complete two-photosite support and
calls `screen-sensor`; only the resulting immutable integer RAW may be uploaded
for Metal camera development. No Metal kernel owns area-to-photosite resampling, sensor noise,
full-well state, ADC clipping or RAW quantization.
The authoritative CPU RAW always retains both clipping masks. Platform publication packs and
uploads those masks only when the requested checkpoint exposes RAW; Developed ACEScg uploads the
codes required by demosaic and does not allocate an unobservable duplicate clipping buffer.

The complete physical-frame optical kernel evaluates 32 direct equal-weight pupil rays independently
for every sensor-footprint and PSF sample. CPU and Metal rotate the same nested pupil pattern with
the same deterministic per-pixel integer hash, retain identical ray order and preserve the separate
per-channel focus and chromatic geometry before shutter and Sensor/CFA. This route deliberately
keeps resolved panel phase, RGB fringe and defocus in the same thin-lens integration.
The one owned Metal source is specialized at backend creation by the resolved lens evaluator and
incident-environment source kind. Thin Lens and VFX 2D are each combined with procedural and
equirectangular environments to form four fixed function-constant pipelines. The immutable typed
execution plan selects exactly one pipeline before dispatch; the parameter buffer carries neither
an evaluator selector nor an environment-source selector. Specialization may remove unreachable
aperture loops, texture paths and branches but cannot change either evaluator's samples, ordering,
inputs or output artifact, or either environment source's owned response.
Exact
rectangular source integration uses one `f32`
horizontal prefix per source row. Fractional left and right texels remain explicit and only the
integer interior span is obtained by prefix subtraction, so accumulation error is bounded by source
width rather than total raster area. This changes lookup cost without changing placement, EOTF,
panel phase or any physical checkpoint. The kernel also evaluates only the
checkpoint terms whose algebraic coefficients are nonzero. In the final optical result, ideal,
continuous, physical, spatial-uniformity and spread contributions are combined by their exact authored coefficients;
terms that cancel identically are not sampled merely to subtract them later. Alpha retains its
complete aperture-integrated source evaluation. Cover glow reuses the same exact area sampler for
two centered physical-radius filters instead of nesting a shifted nine-tap cover lattice over the
nine-tap panel-spread lattice. Its positive core/tail mixture preserves uniform linear energy,
keeps support outside the active outline and is materially cheaper without introducing a second
post-sensor path.

Panel Uniformity is evaluated in the same fused optical kernel immediately after native subpixel emission. Immutable Device parameters carry explicit amplitudes, physical scales and seed; no texture name, preset lookup or frame-derived seed crosses the compute boundary. CPU and Metal evaluate the same deterministic broad and band-limited fields in device coordinates. The accepted uniformity gain at the central per-channel optical footprint is reused by the micrometre-scale Panel Light Spread and Cover Glow taps because every supported uniformity wavelength is materially larger than those supports. This is a declared scale-separation approximation, not a screen-space blur or temporal noise source. Character zero selects the exact pre-existing arithmetic composition so the inserted phase is bit-identical when disabled.

Application also owns a modulation-free `SpatialOpticalPlan` and `SpatialOpticalBackend` port. The
plan contains the validated camera and screen samples, sensor window, panel geometry and
colorimetry, cover, its physical-radius core/tail glow approximation and exactly one analytic or exact single-level equirectangular HDR environment with explicit panel-local X/Y rotation. Cover-local impact coordinates and the projected optical footprint evaluate the same deterministic multiscale cellular anti-glare height field in CPU and Metal; its filtered normal reorients the existing reflection without multiplying radiance. Image-backed rough reflection uses deterministic view-dependent GGX integration with exact dielectric Fresnel and Smith masking. The Metal estimator balances visible-normal samples with solid-angle-correct source-luminance samples. Platform prepares a private RGBA32F weight hierarchy once per accepted environment texture; its level-zero RGB remains the exact input radiance and higher levels contain only summed selection weights. Quality selects 32, 64, 96 or 128 samples of that same evaluator. The plan also carries either the
procedural signal or prepared raster signal plus linear post-EOTF emission. It deliberately cannot
represent panel temporal modulation. The macOS adapter inverts each distinct Brown-Conrady observed coordinate once and reuses that immutable unscaled ideal coordinate across RGB channels, aperture rays, irradiance and the VFX sensor footprint; channel-specific lateral chromatic scaling remains on a private copy. Each pupil sample similarly prepares its world and screen-local origin once, while the inverse screen rotation and the two VFX rim origins are invariant for the complete output thread. The direct-pupil route prepares each channel's ideal-point irradiance weight once per sensor-footprint/PSF sample and reuses that same value for every pupil ray. It then executes aperture
and thin-lens rays, chromatic offsets, resolved or area-integrated panel structure, EOTF, cover
Fresnel/transmission/reflection, centered cover-glow area filtering, spherical analytic or direct equirectangular-HDR sampling and native-to-ACEScg conversion in one Metal kernel. The Metal execution plan prepares the HDR rotation and fixed sample count once; every reflection sample reads the exact level-zero radiance source. Physical
domains contain no Metal dependency, and a future Windows adapter can implement the same port.

Lens veiling glare uses deterministic panel-emission reduction before tiled optical evaluation.
The reduction converts post-EOTF native emission into one projected, covered gate-average ACEScg
irradiance. Every tile receives that immutable value and mixes the authored lens fraction after
local cover evaluation and before shutter integration. CPU and Metal must agree within the optical
tolerance. Zero is exact identity and bypasses the reduction rather than evaluating a value that
would later be multiplied away.

Within one temporal evaluation, source and Device row-prefix textures are reused only when both
borrowed Metal texture identities are exactly the same. A distinct source or Device texture builds
its own prefixes; dimensions, filenames and pixel similarity never imply reuse. The cache lifetime
ends with that immutable temporal request and cannot cross into another frame identity.

The native-shell physical-frame ABI has one earlier flat-panel compute slice with no camera,
lens, sensor, temporal, cover or environment operation. Application prepares one immutable
`FlatPanelPlan`; `screen-panel` owns its physical derivations and CPU oracle, while
`screen-platform::MetalFlatPanel` is the mandatory macOS product backend. The backend consumes the
two borrowed typed Metal textures and placement from the v1 frame input. It never resolves color,
looks up a device preset or interprets source ACEScg as Device RGB. Active evaluation publishes
RGBA32Float linear ACEScg so a half-float contract input is not quantized a second time; Screen
amount zero retains the exact source texture instead of dispatching or copying.

The flat kernel uses safe Metal math with contraction disabled. It integrates the
piecewise-constant source raster over every placed footprint, evaluates signed panel EOTF, and
analytically integrates RGB/BGR stripe and black-matrix coverage at exact device-cell phase. Work
is dispatched in 64-output-row tiles. Progress advances only after a complete tile and cancellation
is checked before every tile; a cancelled job never exposes its partially written texture. Backend
creation or dispatch failure is an explicit failed job and never selects the CPU oracle.

Flat-panel CPU/Metal conformance covers all four placements and qualities, RGB and BGR, zero and
45% black matrix, negative and above-one values, alpha, continuous artistic extension, exact
identity and both RGBA32Float and RGBA16Float contract inputs. The enforced maximum absolute
channel tolerance is `2e-3`, matching the existing spatial physical boundary and accommodating
contract input quantization. On the 2026-08-06 Apple M3 Ultra run the adversarial RGBA32Float matrix
measured `2.861023e-6` maximum deviation and the separately quantized RGBA16Float input measured
`1.9073486e-6`; these observations do not relax or redefine the enforced bound.

The reproducible flat-panel benchmark is:

```text
cargo run --release -p screen-platform --example flat_panel_benchmark
```

It creates two real 3840x2160 RGBA32Float input textures, measures first completed 64-row tile and
total Metal time, and reports exact allocated input/output texture bytes. The 2026-08-06 Apple M3
Ultra run measured `1.553 ms` backend setup and the following values; no row, frame or device
extrapolation is included:

| Device preset | Quality | Output | First tile ms | Total ms | Peak texture bytes |
|---|---:|---:|---:|---:|---:|
| Phone LCD 4.7 Retina | Draft | 360x640 | 16.762 | 21.568 | 269,107,200 |
| Phone LCD 4.7 Retina | Medium | 960x1708 | 1.190 | 10.807 | 291,655,680 |
| Phone LCD 4.7 Retina | High | 1920x3415 | 4.345 | 36.113 | 370,329,600 |
| Phone LCD 4.7 Retina | Native | 2250x4002 | 5.399 | 19.492 | 409,492,800 |
| MacBook Pro Retina 14 | Draft | 360x234 | 1.535 | 3.938 | 266,768,640 |
| MacBook Pro Retina 14 | Medium | 960x623 | 0.821 | 4.123 | 274,990,080 |
| MacBook Pro Retina 14 | High | 1920x1247 | 1.603 | 9.788 | 303,728,640 |
| MacBook Pro Retina 14 | Native | 9072x5892 | 26.181 | 51.235 | 1,120,656,384 |
| ASUS ProArt PA329CV | Draft | 360x203 | 3.952 | 6.592 | 266,590,080 |
| ASUS ProArt PA329CV | Medium | 960x540 | 0.737 | 3.754 | 273,715,200 |
| ASUS ProArt PA329CV | High | 1920x1080 | 1.502 | 8.202 | 298,598,400 |
| ASUS ProArt PA329CV | Native | 11520x6480 | 46.449 | 74.334 | 1,459,814,400 |

Raster area integration uses per-row horizontal `f32` prefixes, never a full-frame `f32`
summed-area table. The latter accumulates with total raster area and loses local differences when
nearby values are subtracted late in a UHD image, producing non-physical large spatial regions.
Row prefixes bound accumulation by source width; the kernel then integrates exactly the source
rows crossed by the optical footprint. The CPU oracle retains its higher-precision area integral,
and conformance compares both implementations at the spatial boundary.

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

Spatial optics are also compiled with safe Metal math and floating-point contraction disabled.
Resolved panel emission is phase-sensitive at native panel resolution: a numerically small ray
coordinate error can cross a physical RGB-stripe boundary and become a coherent diagonal pattern
over a full-resolution capture. Conformance therefore includes a non-origin 24×24 region of the
8064×6048 iPhone sensor viewing the 3840×2160 ASUS panel with the integrated wide lens. The test
compares the mandatory Metal product backend with the CPU oracle before sensor integration, RAW
development, OCIO publication and viewer scaling. Fast spatial math is not an available product
mode or fallback.

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

After enabling phase-stable spatial compilation, the representative 2026-08-06 Apple M3 Ultra
measurement reported 0.043 s for either an animated one-motion-sample or static eight-sample
8064×128 product stripe, including Metal spatial optics, sensor integration, RAW development, Metal
OCIO publication and staging. Forty-eight stripes project to about 2.1 s for 8064×6048. The first
complete 128×128 tile remained available in 0.012–0.013 s. These measured projections preserve the
CPU-oracle spatial tolerance at full sensor coordinate phase; they do not reintroduce a faster
phase-unstable route.
