# Screen Simulation

Cross-platform application for physically coherent simulation of digital screens photographed or filmed by a camera.

The current physical slice covers device-native media, explicit color interpretation, a fixed-pixel LCD with PWM emission, animated camera/screen geometry, thin-lens integration, exact global/rolling-shutter sampling and deterministic Bayer RAW sensor capture.

See [Docs/architecture/README.md](Docs/architecture/README.md) for the current architecture and [AGENTS.md](AGENTS.md) for repository rules.

## Build the current macOS application

Build the SwiftUI/AppKit product with:

```text
python3 scripts/build_native_macos.py
```

It installs the only current application bundle at
`/Applications/SCREEN-SIMULATION.app`. The application consumes StudioColor for
OCIO/ACES and the host-neutral Rust physical models through the native bridge.
The retired Rust/Slint application has no packaging route.

The completed native I/O, Metal, playback and output boundaries are documented
in `Docs/NATIVE_IO_METAL_PHASE.md`.
