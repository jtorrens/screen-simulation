# Screen Simulation

## Media preparation benchmark

The macOS product keeps FFmpeg as its single decoder and sends one RGBA16 sample directly to the
authoritative Metal Source-to-Device/OCIO and panel-prefix preparation path. The complete CPU float
materialization remains only as the before/oracle measurement in this benchmark:

```text
cargo run --release -p screen-desktop --bin media_benchmark -- /path/to/source.mov
```

The report separates probe/decode, transfer plus IDT, panel-prefix preparation, first Draft and
1024-wide Native spatial previews, exact cache hits, reuse of another request resolving to the same
source frame, and next-frame invalidation.

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
