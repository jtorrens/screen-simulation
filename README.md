# Screen Simulation

Cross-platform application for physically coherent simulation of digital screens photographed or filmed by a camera.

The current phase establishes the strict cross-platform architecture and the first physical vertical slice: device-native media, explicit color interpretation, a procedural fixed-pixel LCD, animated camera/screen geometry, and ideal final sampling.

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
