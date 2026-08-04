# Initial architecture proposal

Status: proposed.

## Product boundary

The application consumes an explicitly interpreted, device-native animated raster and produces a reproducible camera image. ProRes 4444 is the primary production input; OpenEXR sequences are the reference input. Neither codec determines color interpretation by itself.

## Processing chain

```text
Media source
→ decoded source frame
→ explicit source/color interpretation
→ device signal
→ physical panel emission
→ screen geometry and camera projection
→ optical image
→ sensor sampling
→ camera processing
→ display or output transform
→ encoded output
```

Every arrow is a typed boundary. A later module consumes the complete validated result of the prior owner and does not reconstruct or infer its semantics.

## Proposed domains

```text
Contracts        strict versioned documents, ids, units and rational time
Media            ProRes/OpenEXR decode and exact frame selection
Color            OpenColorIO, ACEScg and transform resolution
Panel            raster, subpixels, EOTF and emitted radiance
Geometry         physical screen and camera projection
Optics           PSF, focus, aberrations and pre-sensor filtering
Sensor           CFA, shutter, sampling, demosaic, aliasing and noise
Processing       camera-side tone, sharpening, reduction and compression intent
Render           immutable simulation jobs and bounded execution
Output           image/video encoding and atomic publication
Persistence      strict portable project documents
Platform         macOS/Windows media, GPU, display and filesystem adapters
App              composition root and UI shell
```

Domain packages depend on `Contracts` and narrow declared ports, never on the UI, persistence implementation, or sibling implementations. `App` is the only production composition root allowed to construct several concrete domains.

## Canonical data policy

- Version 1 will be the only readable project contract when introduced.
- Opening a project validates without writing.
- A future migration runs as an explicit one-way maintenance command and produces the new complete contract.
- After cutover, obsolete readers, writers, fields, routes, and migration hooks are removed.
- Invalid current data blocks the affected operation visibly; it is never repaired into a plausible value.

## Prevention rather than convention

The repository will enforce the design with package dependency tests, exact public-capability tests, strict schema decoding, negative fixtures, read-only startup tests, disposable migration tests, CPU/GPU parity tests, and a validation-owner manifest. Documentation alone is not considered sufficient enforcement.

