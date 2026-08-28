# Native compute backend

Status: normative.

## Current boundary
<!-- decision-owner: native.compute-boundary -->

Headless Native, Render Queue and Fusion attempts never activate an interactive workspace page or schedule an unobservable Preview job. Their explicit output request is the only physical submission. When an output contract supplies a temporal sample count, the resulting `PreparedRender` count is authoritative for that attempt and is not compared with or rewritten from the authored interactive Preview count; zero shutter contribution still collapses exactly to one sample. The transported physical matte is evaluated with the physical frame, resampled once at each required typed raster boundary and reused by every downstream composition consumer.

The host-only `Setup` preview is deliberately outside the native physical frame ABI. Application prepares one immutable `SetupDiagnosticPlan` from the exact Rust-resolved scene identity; the host kernel accepts only that plan plus decoded image inputs and therefore cannot receive mutable authoring, profiles or tracking assets. It evaluates only ideal pinhole projection from the plan's camera and screen geometry, samples the source with its authored placement, applies Delivery Raster placement, and draws the diagnostic Device boundary. No panel, cover, environment, lens-aberration, exposure, sensor or develop kernel is dispatched in Setup.

`Setup entorno` is also host-only. Its Metal kernel consumes the same immutable Rust-resolved scene frame, camera, screen plane and Delivery Raster as the other Setup diagnostics, but replaces the complete material and capture pipeline with a perfect-mirror lookup solely for interactive placement. The kernel evaluates supersampled projected Device coverage, keeps the lookup at unit gain inside that coverage and applies a fixed 0.20 presentation gain outside it; the latter is contextual dimming and is absent from the physical evaluator and generated environment asset. Finite mode intersects the world-space reflected ray with the authored sphere center and radius and uses the same owner-published enclosure requirement as the product evaluator. MMB translates that sphere in camera-local axes, Alt-MMB rotates it with one locked axis per gesture, and Shift-MMB or wheel changes its radius multiplicatively; none of those gestures changes camera or Device.

For an animated scene, Application evaluates that finite-sphere enclosure from every exact
Rust-resolved camera and Device sample in the active timeline. Entering `Setup entorno` raises an
undersized authored radius once to the maximum required value and publishes the change; individual
render backends never clamp, infer or replace the sphere.

The planar HDRI-framing diagnostic is another host-only Metal presentation path. It samples a pan/zoom/roll crop of the exact decoded ACEScg source inside the projected Device while retaining dimmed planar context outside. Applying the edit returns only stable Environment control intents. Application materializes the resulting world-space anchor, source direction and anchored Möbius coefficients into the normal image-environment request; Platform never bakes or writes another HDRI for this operation.

The product evaluator separately exposes the typed headless-only `device-vfx-transparency-v1` publication used by Fusion Scene Package. Its request carries one centred active frontal raster and one explicit DOF mode: disabled, baked, or Fusion. It is the normal Camera Rendered ACEScg route with only explicit export overrides: Metal maps the raster into Device-local UV, bypasses perspective and Brown distortion, uses one shutter sample rather than motion accumulation, and evaluates depth of field only in baked mode. Panel, cover, glow, lens transmission/vignetting/chromatic character/veiling glare, shutter exposure, sensor development and Camera Rendering Intent remain authored normal-render operations. The virtual sensor raster is exactly the requested padded export raster, so the route never applies an inferred rescale. The returned raster is already the complete physical Device contribution with additive exterior RGB and its independent fractional occlusion matte. The Fusion host publishes it directly as one Device medium and cannot partition or reconstruct another pass. Source overscan is resolved once before the first frame from maximum Device sampling density plus panel tail, full positive glow, optional baked DOF and the final radiometric fade. Every frame is evaluated once; the scene-linear threshold is metadata only and the fade attenuates only exterior Device RGB. Camera motion blur is reconstructed from exported curves and shutter angle/phase. Partial Screen or Panel Emission requests fail because this route cannot consult Source or rebuild omitted radiometry.

Color owns application OCIO processing, but Fusion Scene Package exports no OCIO configuration. The writer delivers one Device medium in the selected encoding while format remains an independent alpha-capable OpenEXR, TIFF or ProRes choice. Its Loader preserves straight authored RGBA. Before native Fusion 21 color conversion, a `Custom` node supplies complete Device RGB with alpha one. After `AcesTransform` or `ColorSpaceTransform`, another `Custom` node restores the untouched physical matte without multiplying RGB. External Reference first crosses native `ChangeDepth` with `Depth = 3`, guaranteeing at least float16 before its color transform. The saved ACES 2.0 Rec.709 D65 100 nit Reference then uses `ACES_VERSION_2_0_0`, `IDT_REC709_100_INV_ODT` to `ODT_ACESCG`; another authored Reference transform produces that named node disabled with `PassThrough = true` and no substitute. There is no OCIO node, LUT or inferred route. The expanded job-specific Sticky Note records Device, Reference, metadata, exact alpha and transform contracts, ACEScg working space, composition equation and manual Viewer transform; it never changes values or claims to persist Viewer state.

`Setup foco` is host-only and uses the Setup Metal boundary rather than the physical ABI. It evaluates the analytic thin-lens circle of confusion only at the camera-ray/Device intersection, emits a grayscale focus diagnostic, and draws a Device-local red grid through the current Brown-Conrady radial/tangential distortion. The sampled red Device outline uses that same distortion while retaining one viewer-space pixel after presentation scaling. Its green autofocus gizmo is a presentation overlay, but its normalized Device-local target is model-authored state. Application projects and inversely picks that target from the same immutable resolved scene frame through the same gate, lens shift, Delivery Raster placement and Brown-Conrady coefficients; Application also resolves the per-frame optical-axis focus distance only after sampling camera and Device tracks. Platform displays the returned pixel and forwards pointer positions.

Setup, Reference Match, Setup foco and Setup entorno share this single plan contract. Transient gesture values are resolved into a new immutable candidate before dispatch; the image and tracking overlay publish the same candidate identity. The host can return only stable authoring intents after interaction and has no compatibility overload that renders directly from Swift authoring state.

The Platform scene-adjustment adapter evaluates the Color-owned operator in RGBA32F Metal before Feeder Output and during one-time image-Environment preparation. Neutral values are exact identity, alpha is unchanged, and Environment adjustment uses the non-negative incident-radiance policy rather than a display transform.

Native capture has one Application orchestration path and one result contract. Physical owners
prepare and validate immutable inputs; a narrow compute port may execute an owned numeric operation
without acquiring its semantics. A platform backend receives complete typed values and must return
the same authoritative result type. It cannot choose quality, samples, shutter behavior, placement,
color interpretation, sensor identity or development settings.

Application prepares every host request before dispatch. The preparation contract carries exact rational time and frame rate, full sensor and active sensor window, global render window, rational render scale, rational pixel aspect, requested quality, model-declared spatial support and the ordered temporal samples required by global-shutter integration. A backend may execute those samples in tiles or in parallel, but it cannot request another time or localize coordinates by discarding the full-sensor and render-window origins.

Repeated temporal work may use one Application-owned cache with explicit byte capacity. Exact cache identity includes scene revision, rational sample time, typed artifact, raster/window/region and result-affecting quality/backend values. The cache is single-flight for concurrent equal requests and evicts least-recently-used completed entries to remain within capacity. Capacity zero, eviction and cache misses only change execution cost: recomputation must publish the identical artifact. A nearest-frame lookup, frame-number rounding, implicit quality reduction or host-owned semantic cache is forbidden.

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
per-channel focus and chromatic geometry before shutter and photosite/CFA collection. This route deliberately
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
complete aperture-integrated source evaluation. Device emission glow consumes the already resolved,
alpha-attenuated Panel Light Spread emission and integrates each panel-native RGB cell before applying one
achromatic panel-relative luminance key. It prepares four positive, normalized, separable Gaussian
convolutions at fixed relative scales of the one authored physical radius. Every working raster has
transparent padding for its complete kernel support, so evaluation can sample a smooth tail beyond
the active-panel outline without clamping or repeating an edge. A panel-white-relative threshold selects bright
emission after local RGB integration, so balanced unresolved RGB structure blooms neutrally while a
genuinely coloured emitter preserves its hue. The result adds bloom inside the Device and
diffuse RGB with zero matte outside it; it cannot create separated replicas or read source/reference
pixels, and it introduces no post-sensor path.

Panel Uniformity is evaluated in the same fused optical kernel immediately after native subpixel emission. Immutable Device parameters carry explicit amplitudes, physical scales and seed; no texture name, preset lookup or frame-derived seed crosses the compute boundary. CPU and Metal evaluate the same deterministic broad and band-limited fields in device coordinates. The accepted uniformity gain at the central per-channel optical footprint is reused by the micrometre-scale Panel Light Spread and Device Emission Glow supports because every supported uniformity wavelength is materially larger than those supports. This is a declared scale-separation approximation, not a screen-space blur or temporal noise source. Character zero selects the exact pre-existing arithmetic composition so the inserted phase is bit-identical when disabled.
Metal evaluates only the requested channel component of that gain inside a channel branch; it does not
construct the two unobserved RGB components. The scalar branch retains the same lattice samples,
opponent equation, drive response and operation order as the corresponding CPU-owned component.

Application also owns a modulation-free `SpatialOpticalPlan` and `SpatialOpticalBackend` port. The
plan contains the validated camera and screen samples, sensor window, panel geometry and
colorimetry, cover, its single-radius keyed emission-glow approximation and exactly one analytic or exact single-level equirectangular HDR environment with explicit panel-local X/Y rotation. Cover-local impact coordinates and the projected optical footprint evaluate the same deterministic multiscale cellular anti-glare height field in CPU and Metal; its filtered normal reorients the existing reflection without multiplying radiance. Image-backed rough reflection uses deterministic view-dependent GGX integration with exact dielectric Fresnel and Smith masking. The Metal estimator balances visible-normal samples with solid-angle-correct source-luminance samples. Platform prepares a private RGBA32F weight hierarchy once per accepted environment texture; its level-zero RGB remains the exact input radiance and higher levels contain only summed selection weights. Quality selects 32, 64, 96 or 128 samples of that same evaluator. The plan also carries either the
procedural signal or prepared raster signal plus linear post-EOTF emission. It deliberately cannot
represent panel temporal modulation. The macOS adapter inverts each distinct Brown-Conrady observed coordinate once and reuses that immutable unscaled ideal coordinate across RGB channels, aperture rays, irradiance and the VFX sensor footprint; channel-specific lateral chromatic scaling remains on a private copy. When the authored lens has exactly one nonzero radial degree-two coefficient and zero higher radial
and tangential coefficients, Metal solves that same radial equation with its scalar analytic
Jacobian. It retains the general solver's iteration limit and residual thresholds; every other lens
continues through the complete two-dimensional Brown-Conrady inversion. Each pupil sample similarly prepares its world and screen-local origin once, while the inverse screen rotation and the two VFX rim origins are invariant for the complete output thread. The direct-pupil route prepares each channel's ideal-point irradiance weight once per sensor-footprint/PSF sample and reuses that same value for every pupil ray. It then executes aperture and thin-lens rays, chromatic offsets, resolved or area-integrated panel structure, cover
Fresnel/transmission/reflection, one centered Device-emission soft-glow evaluation, spherical analytic or direct equirectangular-HDR sampling and native-to-ACEScg conversion in one Metal kernel. The Metal execution plan prepares the HDR rotation and fixed sample count once; every reflection sample reads the exact level-zero radiance source. Physical
domains contain no Metal dependency, and a future Windows adapter can implement the same port.

Lens veiling glare uses deterministic panel-emission reduction before tiled optical evaluation.
The reduction converts post-EOTF native emission into one projected, covered gate-average ACEScg
irradiance. Every tile receives that immutable value and mixes the authored lens fraction after
local cover evaluation and before shutter integration. CPU and Metal must agree within the optical
tolerance. Zero is exact identity and bypasses the reduction rather than evaluating a value that
would later be multiplied away.
Within one temporal request, equal prepared Device-signal identity reduces the native-emission mean
exactly once. Each sample then applies only its own camera-facing angular response, gate projection,
cover transmission and irradiance conversion before its first stripe. This factorization retains the
same reduction and floating-point order while preventing scene motion from rescanning an unchanged
Device raster.

Within one temporal evaluation, Media first reuses the decoded ACEScg and Feeder Signal textures
only for an equal exact retained source-frame identity. Metal then reuses the Device row-prefix,
post-EOTF native-emission preparation and keyed Device-glow lobes when both borrowed texture
identities and every preparation parameter are exactly equal. Camera pose, Device pose, projection,
lens/cover evaluation, veiling projection, temporal emission gain and interval accumulation remain
per sample. A distinct source/Device identity or preparation parameter builds an independent
preparation; dimensions, filenames and pixel similarity never imply reuse. The preparation lifetime
ends with that immutable temporal request and cannot cross into another output-frame identity. The
prepared native emission is premultiplied once by the resolved authored Device alpha before its
summed-area representation is built. Every continuous, carrier and subpixel optical footprint
integrates that linear artifact; neither CPU nor Metal reapplies EOTF or alpha after averaging a
moving projected footprint. Subpixel stripe coverage and the footprint-filtered uniformity gain
remain per sample because their support is defined by that sample's resolved projection.
Source ACEScg is never area-integrated by this physical kernel, so preparation cannot allocate or
scan a Source row-prefix texture that no named artifact consumes.

The native-shell physical-frame ABI has one earlier flat-panel compute slice with no camera,
lens, sensor, temporal, cover or environment operation. Application prepares one immutable
`FlatPanelPlan`; `screen-panel` owns its physical derivations and CPU oracle, while
`screen-platform::MetalFlatPanel` is the mandatory macOS product backend. The backend consumes the
two borrowed typed Metal textures and placement from the v1 frame input. It never resolves color,
looks up a device preset or interprets source ACEScg as Device RGB. Active evaluation publishes
RGBA32Float linear ACEScg so a half-float contract input is not quantized a second time; Screen
amount zero contributes no physical Device emission and never reintroduces the source texture after
the placed-feeder boundary.

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
no product CPU route or legacy PWM route. Application owns global-shutter scheduling and multiplies
the modulation-free Metal result by each analytically integrated frame-global panel gain exactly
once. Tests prove that the authored number of motion samples creates the same number of ordered
complete-frame temporal samples and that CPU-oracle RAW codes, clipping masks and Developed ACEScg
remain within their declared tolerances.

Complete-frame temporal plans are submitted through the batch port. Plans that share exact Source,
Feeder Signal, Environment and physical-signal preparation use one parameter array, one signal upload
and one fused Metal temporal dispatch per prepared product stripe; the kernel evaluates every
authored moving camera/Device plan and accumulates it in authored order. The first stripe establishes
and verifies the typed preparation identities and per-sample veiling factors through the ordinary
ordered dispatches before later stripes may use the fused kernel. Distinct animated raster samples
or preparation parameters retain their exact authored sources and use separate dispatches. The batch
changes command granularity only and never drops a motion sample.

For distinct moving spatial samples, Metal batches by product stripe: one command buffer encodes each
authored sample's physical dispatch followed immediately by its ordered weighted accumulation, then
submits and waits exactly once for that stripe regardless of temporal sample count. The samples share
one scratch raster, exact signal preparations and persistent per-sample veiling factors. No
intermediate full-frame sample is published and no second full-frame accumulation command exists. The
accumulated texture retains the authored sample order and is the sole input to Sensor/RAW evaluation.

Application reuses a spatial result only when the source is explicitly static and camera transform,
camera intrinsics and screen transform each contain exactly one authored keyframe. It still
constructs and integrates every requested global-shutter interval; only the identical
modulation-free spatial value is referenced more than once. An animated procedural source, media
sequence or any multi-keyframe spatial track selects the complete plan batch automatically. This is
an optimization inside the same result contract, not another route.

Temporal integration parallelizes independent sensor pixels. Sample accumulation inside every
pixel retains authored order, so thread scheduling cannot change floating-point addition order.
Sensor exposure likewise parallelizes independent photosites; CFA phase and counter-based noise
remain keyed to global coordinates. Tests require identical exposures and RAW results with one and
multiple Rayon workers.

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

`SCREEN_BENCH_STRIPE_HEIGHT` may override diagnostic stripe height for profiling only. It does not
alter the product's 128-row physical stripe or 128-pixel logical progress boundary. The benchmark
reports cold Metal setup, time to first complete Native tile, complete-frame global-shutter
throughput for one and multiple motion samples, staged ROI and stripe breakdowns and isolated
CPU/Metal RAW-development time. Metal uses unified `StorageModeShared`; shared-buffer result
materialization is included in the Metal stage. Measurements and extrapolations are diagnostic
workstation evidence, never a product guarantee or a quality selector.

Remaining performance work is bounded to reducing exact spatial Metal and plan-preparation cost,
sharing prepared linear-emission storage across provably time-equivalent samples and extending
static-interval proofs only where exact keyframe-segment identity exists. No optimization may add a
second evaluator, omit an authored complete-frame temporal sample or weaken CPU/Metal parity.

After enabling phase-stable spatial compilation, the representative 2026-08-06 Apple M3 Ultra
measurement reported 0.043 s for either an animated one-motion-sample or static eight-sample
8064×128 product stripe, including Metal spatial optics, sensor integration, RAW development, Metal
OCIO publication and staging. Forty-eight stripes project to about 2.1 s for 8064×6048. The first
complete 128×128 tile remained available in 0.012–0.013 s. These measured projections preserve the
CPU-oracle spatial tolerance at full sensor coordinate phase; they do not reintroduce a faster
phase-unstable route.

Recording Codec is a separate host-adapter boundary after the Color-owned Recording Output. The macOS adapter executes one independent picture per requested frame: BGRA8 for H.264 High, P010 for HEVC Main10, v210 for ProRes 422 HQ and RGBA half for ProRes 4444. Every picture is encoded by AVFoundation and decoded back from the resulting payload before the exact inverse Color transform. The contract contains no GOP, B-frame, lookahead or whole-clip state, and the bundled profile catalog contains no profile without an executable adapter.
