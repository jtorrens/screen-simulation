# Current system

Status: normative.

## Product boundary

The application consumes an explicitly interpreted animated raster and evaluates a physical fixed-pixel LCD through animated screen/camera geometry and phase-preserving photosite-footprint sampling. The FFmpeg adapter accepts the video and still-image formats enabled in the one shipped decoder configuration, including H.264 and ProRes. ProRes 4444 is a recommended high-quality production source, not an input restriction. OpenEXR sequences use the explicit OpenEXR adapter. No codec or container chooses color interpretation.

The current processing chain is:

```text
media source
→ explicit pixel decode interpretation
→ decoded source frame
→ explicit source-to-device interpretation
→ device signal
→ colorimetrically declared, angle-dependent LCD emission
→ independently animated screen/camera projection
→ explicit optical-cover transmission and authored environment reflection
→ deterministic sensor-footprint and thin-lens integration
→ immutable linear ACEScg optical result in image-plane illuminance
  ├→ explicit optical-preview or still-output transform
  └→ exact global/rolling-shutter temporal integration
     → explicit photometric exposure, optical ND and shutter integration in lux-seconds
     → Bayer photosite charge, full-well saturation, noise, gain and ADC quantization
     → single reference edge-directed Bayer demosaic
     → explicit native-sensor white balance
     → explicit EI middle-gray placement and develop push/pull
     → immutable linear ACEScg developed camera result
     → explicit OCIO output transform
```

Every arrow is a typed boundary. A consumer receives a complete validated result and never reconstructs the prior owner's semantics. Declared media color metadata crosses the Media boundary as typed evidence only. YUV matrix and signal range resolve independently from the source IDT: `Auto` consumes only supported declared metadata, while absent or unsupported evidence blocks decoding until the user authors an explicit value. RGB sources bypass the YUV interpretation route, and monochrome sources require range but not matrix. The Platform adapter receives only a fully resolved decode interpretation and configures the single FFmpeg YUV-to-RGB conversion before OCIO. Color may propose an IDT from an exact complete pattern, while evaluation remains blocked until the source interpretation is explicitly authored.

Media sample selection consumes exact project time and one authored policy. Rational timestamps compare by value even when the project and stream use different denominators. `Exact` requires an equal presentation timestamp and does not extend source edges. `Floor` selects the latest timestamped frame that does not exceed project time; `Nearest` compares the adjacent timestamps exactly and selects the earlier sample on a tie. Both non-exact policies explicitly hold the first or last sample when shutter or rolling-readout evaluation crosses the edge of a bounded source. Missing timestamps and unknown-duration access beyond the exact initial sample fail explicitly. There is no implicit policy change, retry, loop mode or legacy sampling route.

## Technology

The current macOS-first implementation uses Rust 1.97.1. Native RAW development runs through the required Metal backend on Apple Silicon; the physical core and typed domain boundaries remain platform-independent, but the current version does not require, ship or validate a Windows/D3D12 adapter. Native display publication uses one required Metal backend generated from the pinned OCIO processor and quantizes its result directly to RGBA8; the OCIO CPU processor remains only a numeric oracle with the explicit tolerance in `native_compute.md`. The technical desktop UI uses Slint with one compiled `fluent-dark` style and its WGPU renderer on macOS. Slint remains confined to `screen-desktop`; domain and application packages expose no UI types. The desktop bundle includes the required Slint attribution through the standard `AboutSlint` component. Media decode uses one linked FFmpeg configuration. The Platform adapter owns two small product unsafe bridges: `sws_setColorspaceDetails`, because the safe Rust wrapper does not expose this required libswscale operation, and completed shared Metal-buffer copies described by `native_compute.md`; no unsafe code crosses the adapter boundary. The current local macOS packager copies its complete non-system Mach-O dependency closure and the compiled Native metallib into the application, rewrites every route to the bundle and rejects remaining machine-specific paths. OpenColorIO 2.5.2 is statically built through the `screen-color` dependency boundary; `screen-color` opens the exact upstream built-in `studio-config-v4.0.0_aces-v2.0_ocio-v2.5` configuration and never reads the process environment or a workstation configuration path. OpenEXR remains behind its own format adapter.

An isolated SwiftUI/AppKit replacement candidate exists under
`apps/screen-native-macos`. It is not a second product composition root and is
not reachable from `screen-desktop`. Its only color implementation is the
extractable `packages/StudioColor` boundary copied from the authoritative
CREDITOS-HDR OCIO/ACES implementation at the pinned source commit and hashes.
The candidate decodes one explicitly requested frame with Apple frameworks,
authors an explicit IDT into linear ACEScg, calls the Rust-owned
`PhysicalPipeline(identity)` once per complete float buffer, and uses the
StudioColor OCIO-generated Metal display processor for preview and output.
The existing Slint executable remains the shipped composition root until the
single cutover defined in `Docs/NATIVE_MACOS_CUTOVER.md`; there is no runtime
backend selector or fallback between the two shells or color implementations.

The candidate's one physical-frame boundary is the versioned coarse ABI in
`ScreenPhysicalBridge.h`, specified by `Docs/NATIVE_PHYSICAL_FRAME_CONTRACT.md`.
It carries one selected frame through an opaque input containing the source
linear-ACEScg texture, the nonlinear Device RGB texture resolved by StudioColor
and one explicit raster-placement policy. An immutable resolved Device snapshot
then crosses ordered Screen and Capture domains to one opaque linear-ACEScg
result texture. Screen consumes Device RGB and placement; Capture consumes the
physical Screen result. Rust/Metal owns physical stage semantics; Swift owns
only request orchestration and presentation state.
Preview, ColorSync, DeckLink and render output transforms remain downstream of
this boundary and cannot appear as physical contributions.

The current supported system is Apple Silicon on macOS 14 or later. Windows and D3D12 are outside the current version and impose no parity requirement on Metal work.

## Physical packages

```text
screen-contracts       shared ids, units, rational time and boundary values
screen-media           exact media decode and frame selection
screen-color           explicit OCIO and color-transform ownership
screen-panel           device signal, fixed-pixel LCD and emitted radiance
screen-cover           cover glass, coatings, transmission and environment reflection
screen-geometry        camera/screen tracks and physical projection
screen-sensor          integrated exposure, photosites, sensor noise and mosaiced RAW
screen-camera          explicit Bayer development and sensor RGB to linear ACEScg
screen-application     immutable request preparation and orchestration
screen-persistence     strict portable project documents
screen-platform        replaceable OS, GPU, media and filesystem adapters
screen-desktop         current composition root and Slint UI shell
```

Domain packages expose narrow capabilities and do not depend on sibling implementation details. The exact allowed package edges are executable in `architecture/domains.json`. Executable and host adapters are composition roots; the current workspace contains only `screen-desktop`. Any later adapter must translate its host boundary into the same immutable Application requests and cannot introduce another evaluator, domain semantics or UI types into the core.

## Current scope

The project-owned physical state includes complete LCD, optical-cover, environment and sensor profiles. Cover and environment cross the same immutable Application request as panel and sensor; they are not workstation-only effects.

The current implementation target is one source clip per simulation shot, one authored rational project frame rate, one project-owned complete LCD profile and sensor profile, internally authored independent camera-transform, camera-intrinsics and screen-transform tracks, an RGB/BGR stripe panel, transformed physical projection, deterministic reference sampling, a public linear optical result, exact global/rolling-shutter integration with analytically integrated residual flicker and optional banding, mosaiced RAW capture, debug views and still export. The technical desktop also authors six explicit bundled test sources: an animated checkerboard, a static black-on-white eye chart, a 3840×2160 editorial page containing common document/UI text sizes, a 3840×2160 photographic camera-color reference containing diverse skin tones, textiles, neutrals, glossy/matte materials and fine texture, a deterministic 3840×2160 frequency reference containing a Siemens star, authored 1–8-pixel line pairs, slanted edges, channel ramps and exact pixel marks, and a procedural photometric scale containing nine achromatic device-signal patches at exact codes `0.00`, `0.05`, `0.10`, `0.18`, `0.25`, `0.50`, `0.75`, `0.90` and `1.00`. Their device-signal channels remain in `[0,1]`; none is a media fallback. The three raster references are decoded once into the same prepared device-signal representation used by media, while every procedural reference enters the same device-signal, placement, panel, optical and native-capture evaluator without an image-decoding route. A source whose raster differs from the device native raster requires one authored placement policy: `Fit`, `FillCrop`, `Stretch`, or `OneToOne`. Pixel decode matrix, pixel decode range, source IDT and alpha association are independent explicit decisions. Alpha is resolved to the current explicit opaque-black target before panel evaluation.

The technical desktop camera-result view authors one complete capture profile: native photosite raster, physical gate, Bayer pattern, sensor response/noise/ADC data and lens defaults. The bundled templates are ARRI ALEXA 35 Open Gate and an explicitly labelled calibrated approximation of the iPhone 16e main camera; `Custom` edits the same complete values. Selecting a template copies its values into current state, and evaluation never resolves a preset id. Interchangeable optics use one geometry-owned catalog of generic 18, 25, 35, 50, 85 and 135 mm photographic approximations. The iPhone template selects a separate calibrated approximation of its integrated 4.2 mm main lens; it does not emulate computational photography. Lens selection copies the complete distortion, chromatic, vignetting and transmission values into the same camera-intrinsics track consumed by every quality and Native capture. Integrated phone optics keep their calibrated focal length and lens preset fixed in the technical UI, while f-stop remains an explicit editable simulation value so the model can be evaluated beyond the physical handset's fixed aperture.

An explicit one-frame native capture may evaluate either the complete sensor or a centered native 1024×1024 region. Both use the same optical, RAW and development route. Evaluation is partitioned into 128-pixel sensor tiles without first materializing a giant luminous-panel raster. Every ray retains complete-sensor coordinates, rolling-shutter row time remains anchored to the complete sensor, and media is decoded and cached at every exact temporal sample requested by that tile rather than frozen at nominal frame time. The panel signal remains at its native device resolution with one immutable summed-area representation per resolved media sample. Sensor CFA phase, counter-based noise identity and panel-cell phase are therefore global: a regional result is exactly the same pixels as the corresponding crop of a complete capture. Demosaic evaluates its complete three-photosite support around each requested region before cropping it, so tile boundaries cannot create another result. Tile execution occurs off the UI thread, reports progress, supports cancellation between complete tiles and publishes the authoritative frame only after completion; a downscaled staging visualization may expose completed tiles without becoming an output. The worker also derives a deterministic three-level 2× area-filtered display pyramid from the completed developed frame. The workstation viewer selects among that pyramid and the unchanged native level according to magnification: Fit cannot resample the full sensor texture directly, while `1:1 Sensor` presents the native level at one sensor sample per logical viewer pixel. These display levels are non-authoritative and cannot become capture or export data. Zoom and pan never change camera geometry, focus, optical sampling or the authored result. Physical inspection remains a separate camera operation and is unavailable as a substitute for viewer magnification in the camera-result view.

The workstation has one explicit quality selector: `Draft` targets a 360-pixel-wide preview, `Medium` 960 pixels and `High` 1920 pixels; `Native 1024 px sensor crop` and `Native complete frame` select exact sensor capture. The final discrete preview width may differ from its quality target by one pixel so the integer height and width represent the authored viewport within the required half-pixel bound. The three preview qualities use the identical camera, lens, depth-of-field, panel and full-gate projection; only the explicit output sampling raster differs. In optical diagnostic views they use the explicit presentation-only Preview EV. In Camera Result they instead approximate the authored capture exposure and ODT while explicitly omitting the sensor/RAW stages enumerated by the sensor-capture contract. They never change the selected view. Ray projection continues to use the exact authored viewport aspect and the viewer presents that aspect, so this is raster quantization rather than another camera or gate policy. A larger mismatch remains an error. While one preview is running, UI changes invalidate its publication and coalesce into one subsequent render at the selected quality instead of creating parallel semantic routes. Native modes never render implicitly: one contextual `Render` button appears beside the fixed quality and camera selectors, and cancellation remains explicit. A completed non-stale Native result may be exported as one output-transformed 8-bit RGBA PNG by encoding its unchanged level-zero publication buffer. Export neither reevaluates the scene nor consumes a display-pyramid level, and its selected output transform is named in the workstation result. Scene-linear ACEScg export is not inferred from this display-referred file and requires its own future explicit encoding contract.

The inspector groups the adjustable physical stages in their execution order: panel emission,
cover plus incident environment, lens, then the discrete CFA and demosaic boundary. Panel and lens
amounts use the same authoring convention as cover and environment: zero is the corresponding ideal
identity, one is the calibrated profile and values above one deliberately extrapolate character.
These amounts are parameters of the same CPU/Metal optical request and invalidate Native results;
they do not select alternate renderers. CFA and demosaic remain discrete because a continuous amount
would not describe a physical operation. Intermediate-buffer taps are intentionally not claimed until
the current immutable results expose those boundaries.

The bundled LCD device catalog is a set of current authoring templates with stable ids, native raster, active physical dimensions, one reference operating white with an explicit basis label and one default optical-cover authoring template. Selecting a device copies both complete profiles into current state; it never leaves a runtime dependency on either catalog id. The white and cover selection remain editable. Evaluation never looks up a preset id, and an existing project result therefore cannot change when the bundled catalog changes. Generic templates state that their white is an authored approximation; the ASUS ProArt PA329CV uses its published 350-nit typical SDR value and the 14.2-inch MacBook Pro template uses its published 500-nit SDR value. `Custom` edits the same complete values and does not select another evaluator. PPI, diagonal and pixel pitch are derived presentation values, never independent authorities.

The optical-cover catalog provides glossy, semi-gloss, matte and thick-glass approximations. Its complete material profile authors thickness, refractive index, anti-reflective efficiency, RGB absorption, roughness and haze. A separate synthetic-HDR environment profile supplies typed linear ACEScg radiance, complete spherical rotation and exactly one current latitude-longitude distribution: uniform neutral, studio softboxes or calibration grid. Values are scene-linear and may exceed one; the presets do not pass through a display encoding or photographic tone map. The desktop exposes independent non-negative character amounts: cover amount zero is an exact identity and environment amount zero contributes no reflection, while values above one explicitly exaggerate the same operators. A later EXR/HDR image adapter must populate this same incident-environment boundary rather than create another reflection path. Cover evaluation is shared by Draft, Medium, High and Native capture.
