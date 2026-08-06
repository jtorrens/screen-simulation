# Screen Simulation

Cross-platform application for physically coherent simulation of digital screens photographed or filmed by a camera.

The current physical slice covers device-native media, explicit color interpretation, a fixed-pixel LCD with PWM emission, animated camera/screen geometry, thin-lens integration, exact global/rolling-shutter sampling and deterministic Bayer RAW sensor capture.

See [Docs/architecture/README.md](Docs/architecture/README.md) for the current architecture and [AGENTS.md](AGENTS.md) for repository rules.

## Run the current visual slice

```text
cargo run -p screen-desktop
```

On macOS, generate the local test application with:

```text
python3 scripts/package_macos.py
```

The signed development bundle is written to `dist/Screen Simulation.app`. The packager embeds the exact non-system dynamic libraries used by the local build and verifies that no Homebrew or other machine-specific load path remains. It is a local test build, not a notarized or redistributable package; the release FFmpeg configuration and third-party licensing set are not yet finalized.

## Native macOS replacement candidate

Build the independent SwiftUI/AppKit vertical slice with:

```text
python3 scripts/build_native_macos.py
```

It produces `dist/Screen Simulation Native.app`. The candidate consumes only
the StudioColor extraction from CREDITOS-HDR for OCIO/ACES and calls Rust's
`PhysicalPipeline(identity)` through one frame-granular C ABI. It does not
replace the Slint product until every gate in `Docs/NATIVE_MACOS_CUTOVER.md`
passes in one atomic cut.
