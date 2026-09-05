# ScreenSimulation OFX

`ScreenSimulation` is the permanent product and plug-in name. The current
CPU-only version exposes the cumulative `Source` and `Origin` previews through
one `Source RGBA -> Output RGBA` clip contract. Later phases extend this same
OFX identity instead of creating additional plug-ins.

The controls are:

- `Input Transform`: the actual RGB encoding delivered to the OFX node. It is
  required for Origin because Resolve and Fusion do not publish their working
  space reliably through OFX.
- `Alpha Interpretation`: `Premultiplied`, `Straight` or `Ignore / Opaque`.
- `Preview`: `Source` is an exact passthrough; `Origin` evaluates the canonical
  unassociated linear ACEScg checkpoint and presents it back in the selected
  input/host space.

For a Resolve ACES project select `ACEScct` when the node buffer is ACEScct/AP1,
or `ACEScg` when it is linear AP1. ScreenSimulation returns Origin to that same
selected space, so Resolve remains the sole owner of the project ODT. Resolve
Color Managed and Fusion follow the same explicit rule; the plug-in never
infers a transform from the project mode or host name.

Source and Origin preserve raster dimensions, placement, pixel aspect and the
requested render window. Float and Half retain finite negative and above-one
RGB; Byte and Short clip and quantize only at their integer output boundary.

The same C++17 source builds on macOS and Windows. macOS packages the binary at
`Contents/MacOS/ScreenSimulation.ofx`; Windows packages it at
`Contents/Win64/ScreenSimulation.ofx`.

## macOS build

```sh
cmake -S ofx/screen-simulation -B target/ofx-build
cmake --build target/ofx-build --config Release
ctest --test-dir target/ofx-build --output-on-failure
```

The build invokes Cargo for the host-neutral Application/Color bridge and
combines arm64 and x86_64 into one universal macOS bundle.

The resulting bundle is
`target/ofx-build/ScreenSimulation.ofx.bundle`.

The default log is
`~/Library/Logs/ScreenSimulationOFX/ScreenSimulation.log`. Set
`SCREEN_SIMULATION_OFX_LOG` before starting the host to select another exact
path.

## Windows build

```powershell
cmake -S ofx/screen-simulation -B target/ofx-build -A x64
cmake --build target/ofx-build --config Release
ctest --test-dir target/ofx-build -C Release --output-on-failure
```

The default Windows log is
`%LOCALAPPDATA%\ScreenSimulation\Logs\ScreenSimulationOFX.log`.

Installation is intentionally separate from building. Close Resolve and
Fusion before copying the completed bundle into the platform OFX plug-in
directory.
