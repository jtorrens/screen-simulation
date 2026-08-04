# Current system

Status: normative.

## Product boundary

The application consumes an explicitly interpreted animated raster at the device's exact native resolution and evaluates a physical fixed-pixel LCD through animated screen/camera geometry and ideal final sampling. ProRes 4444 is the production input and OpenEXR sequences are the reference input. Neither codec chooses color interpretation.

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

The cross-platform implementation uses Rust 1.97.1. GPU work uses `wgpu` and WGSL, selecting Metal on macOS and Direct3D 12 on Windows. The technical desktop UI uses `egui`. Media decode uses one bundled FFmpeg configuration on both platforms. OpenColorIO remains behind a narrow C++ boundary with a CPU reference processor. OpenEXR remains behind its own format adapter.

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
screen-desktop         sole executable composition root and UI shell
```

Domain packages expose narrow capabilities and do not depend on sibling implementation details. The exact allowed package edges are executable in `architecture/domains.json`. `screen-desktop` is the only executable allowed to construct several concrete domains.

## Current scope

The current implementation target is one source clip per simulation shot, one project-owned complete LCD profile, internally authored animated camera and screen tracks, an RGB/BGR stripe panel, physical projection, ideal sampling, debug views and still export. Source resolution must equal device native resolution. Alpha is resolved to explicit opaque device RGB before panel evaluation.
