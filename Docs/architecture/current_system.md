# Current system

Status: normative.

## Product boundary

The application consumes an explicitly interpreted animated raster and evaluates a physical fixed-pixel LCD through animated screen/camera geometry and ideal final sampling. The FFmpeg adapter accepts the video and still-image formats enabled in the one shipped decoder configuration, including H.264 and ProRes. ProRes 4444 is a recommended high-quality production source, not an input restriction. OpenEXR sequences use the explicit OpenEXR adapter. No codec or container chooses color interpretation.

The current processing chain is:

```text
media source
→ decoded source frame
→ explicit source-to-device interpretation
→ device signal
→ procedural LCD emission
→ animated screen/camera projection
→ ideal final sampling
→ explicit preview or still-output transform
```

Every arrow is a typed boundary. A consumer receives a complete validated result and never reconstructs the prior owner's semantics.

## Technology

The cross-platform implementation uses Rust 1.97.1. GPU work uses `wgpu` and WGSL, selecting Metal on macOS and Direct3D 12 on Windows. The technical desktop UI uses Slint with one compiled `fluent-dark` style and its WGPU renderer on both platforms. Slint remains confined to `screen-desktop`; domain and application packages expose no UI types. The desktop bundle includes the required Slint attribution through the standard `AboutSlint` component. Media decode uses one bundled FFmpeg configuration on both platforms. OpenColorIO remains behind a narrow C++ boundary with a CPU reference processor. OpenEXR remains behind its own format adapter.

The initial supported systems are Apple Silicon on macOS 14 or later and x86-64 on Windows 11.

## Physical packages

```text
screen-contracts       shared ids, units, rational time and boundary values
screen-media           exact media decode and frame selection
screen-color           explicit OCIO and color-transform ownership
screen-panel           device signal, fixed-pixel LCD and emitted radiance
screen-geometry        camera/screen tracks and physical projection
screen-application     immutable request preparation and orchestration
screen-persistence     strict portable project documents
screen-platform        replaceable OS, GPU, media and filesystem adapters
screen-desktop         current composition root and Slint UI shell
```

Domain packages expose narrow capabilities and do not depend on sibling implementation details. The exact allowed package edges are executable in `architecture/domains.json`. Executable and host adapters are composition roots; the current workspace contains only `screen-desktop`. Any later adapter must translate its host boundary into the same immutable Application requests and cannot introduce another evaluator, domain semantics or UI types into the core.

## Current scope

The current implementation target is one source clip per simulation shot, one authored rational project frame rate, one project-owned complete LCD profile, internally authored animated camera and screen tracks, an RGB/BGR stripe panel, physical projection, ideal sampling, debug views and still export. A source whose raster differs from the device native raster requires one authored placement policy: `Fit`, `FillCrop`, `Stretch`, or `OneToOne`. Source IDT and alpha association are independent explicit decisions. Alpha is resolved to the current explicit opaque-black target before panel evaluation.
