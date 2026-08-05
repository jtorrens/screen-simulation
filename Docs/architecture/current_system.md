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
→ deterministic sensor-footprint and thin-lens integration
→ immutable linear ACEScg optical result
  ├→ explicit optical-preview or still-output transform
  └→ exact global/rolling-shutter temporal integration
     → Bayer photosite charge, noise, saturation, gain and RAW quantization
     → single reference Bayer demosaic
     → explicit native-sensor white balance
     → explicit linear camera exposure scale
     → immutable linear ACEScg developed camera result
     → explicit OCIO output transform
```

Every arrow is a typed boundary. A consumer receives a complete validated result and never reconstructs the prior owner's semantics. Declared media color metadata crosses the Media boundary as typed evidence only. YUV matrix and signal range resolve independently from the source IDT: `Auto` consumes only supported declared metadata, while absent or unsupported evidence blocks decoding until the user authors an explicit value. RGB sources bypass the YUV interpretation route, and monochrome sources require range but not matrix. The Platform adapter receives only a fully resolved decode interpretation and configures the single FFmpeg YUV-to-RGB conversion before OCIO. Color may propose an IDT from an exact complete pattern, while evaluation remains blocked until the source interpretation is explicitly authored.

Media sample selection consumes exact project time and one authored policy. `Exact` requires an equal presentation timestamp. `Floor` selects the latest timestamped frame that does not exceed project time. `Nearest` compares the adjacent timestamps exactly and selects the earlier sample on a tie. Negative time, missing timestamps, unknown-duration access beyond the exact initial sample, and time at or beyond a known source duration fail explicitly. The current evaluator has no implicit hold or loop mode.

## Technology

The cross-platform implementation uses Rust 1.97.1. GPU work uses `wgpu` and WGSL, selecting Metal on macOS and Direct3D 12 on Windows. The technical desktop UI uses Slint with one compiled `fluent-dark` style and its WGPU renderer on both platforms. Slint remains confined to `screen-desktop`; domain and application packages expose no UI types. The desktop bundle includes the required Slint attribution through the standard `AboutSlint` component. Media decode uses one linked FFmpeg configuration. The Platform adapter owns one small audited unsafe bridge to `sws_setColorspaceDetails` because the safe Rust wrapper does not expose this required libswscale operation; no unsafe code crosses the adapter boundary. The current local macOS test packager copies its complete non-system Mach-O dependency closure into the application, rewrites every route to the bundle and rejects remaining machine-specific paths. A distributable FFmpeg build configuration and its identical Windows counterpart remain required before release packaging. OpenColorIO 2.5.2 is statically built through the `screen-color` dependency boundary; `screen-color` opens the exact upstream built-in `studio-config-v4.0.0_aces-v2.0_ocio-v2.5` configuration and never reads the process environment or a workstation configuration path. Its CPU processor is the current reference implementation. OpenEXR remains behind its own format adapter.

The initial supported systems are Apple Silicon on macOS 14 or later and x86-64 on Windows 11.

## Physical packages

```text
screen-contracts       shared ids, units, rational time and boundary values
screen-media           exact media decode and frame selection
screen-color           explicit OCIO and color-transform ownership
screen-panel           device signal, fixed-pixel LCD and emitted radiance
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

The current implementation target is one source clip per simulation shot, one authored rational project frame rate, one project-owned complete LCD profile and sensor profile, internally authored independent camera-transform, camera-intrinsics and screen-transform tracks, an RGB/BGR stripe panel, transformed physical projection, deterministic reference sampling, a public linear optical result, exact global/rolling-shutter integration with panel PWM phase, mosaiced RAW capture, debug views and still export. The technical desktop also authors one explicit procedural source: either the animated checkerboard or a static black-on-white eye chart whose device-signal channels remain in `[0,1]`; neither is a media fallback. A source whose raster differs from the device native raster requires one authored placement policy: `Fit`, `FillCrop`, `Stretch`, or `OneToOne`. Pixel decode matrix, pixel decode range, source IDT and alpha association are independent explicit decisions. Alpha is resolved to the current explicit opaque-black target before panel evaluation.

The technical desktop camera-result view authors one complete capture profile: native photosite raster, physical gate, Bayer pattern, sensor response/noise/ADC data and lens defaults. The bundled templates are ARRI ALEXA 35 Open Gate and an explicitly labelled calibrated approximation of the iPhone 16e main camera; `Custom` edits the same complete values. Selecting a template copies its values into current state, and evaluation never resolves a preset id. Fixed phone optics disable contradictory focal-length and f-stop editing in the technical UI.

An explicit one-frame native capture may evaluate either the complete sensor or a centered native 1024×1024 region. Both use the same optical, RAW and development route. Evaluation is partitioned into 512-pixel sensor tiles without first materializing a giant luminous-panel raster. Every ray retains complete-sensor coordinates, and the panel signal remains at its native device resolution with one immutable summed-area representation. Sensor CFA phase, counter-based noise identity and panel-cell phase are therefore global: a regional result is exactly the same pixels as the corresponding crop of a complete capture. Demosaic evaluates a one-photosite halo around each requested region before cropping it, so tile boundaries cannot create another result. Tile execution occurs off the UI thread, reports progress, supports cancellation between complete tiles and never publishes a partial frame. The workstation viewer retains the resulting native raster and may zoom and pan it without changing camera geometry, focus, optical sampling or the authored result. Physical inspection remains a separate camera operation and is unavailable as a substitute for viewer magnification in the camera-result view.

The workstation preview uses the same evaluator on an explicitly reduced sampling raster and executes outside the UI thread. A discrete raster may round the authored physical viewport by at most one half-pixel in width; ray projection continues to use the exact authored viewport aspect and the viewer presents that aspect, so this is raster quantization rather than another camera or gate policy. A larger mismatch remains an error. While one preview is running, UI changes coalesce into one subsequent render instead of creating parallel semantic routes. The inspector keeps view and capture-camera selection outside its scrollable detail region, and native capture publishes exact tile progress through one persistent progress surface.

The bundled LCD device catalog is a set of current geometry templates with stable ids, native raster and active physical dimensions. Selecting a template copies those complete values into the same device profile consumed by evaluation. Evaluation never looks up a preset id, and an existing project result therefore cannot change when the bundled catalog changes. `Custom` edits the same complete values and does not select another evaluator. PPI, diagonal and pixel pitch are derived presentation values, never independent authorities.
