# Native compute backend

Status: normative.

Native capture has one Application orchestration path and one result contract. Physical owners
prepare and validate immutable inputs; a narrow compute port may execute an owned numeric operation
without acquiring its semantics. A platform backend receives complete typed values and must return
the same authoritative result type. It cannot choose quality, samples, shutter behavior, placement,
color interpretation, sensor identity or development settings.

On the supported macOS product, Native RAW development is executed by `screen-platform` through
Metal. `screen-camera` owns validation, Bayer reconstruction, native-sensor white balance, the
sensor-to-ACEScg matrix and exposure placement; its prepared development plan is the only numeric
contract accepted by the Metal adapter. The packaged Desktop requires Metal backend creation and
fails the requested capture explicitly if it is unavailable. It has no runtime CPU fallback.
`CpuRawDevelopment` remains the deterministic oracle for parity tests.

The current Metal slice uses two ordered compute passes: edge-directed green reconstruction, then
red/blue color-difference reconstruction plus camera development. Its embedded metallib is compiled
from the owned `.metal` source at build time and is also copied into the macOS bundle resources for
packaging inspection. The only platform unsafe operation maps a completed shared Metal output buffer
into an immutable Rust copy; the allocation size, completion ordering and lifetime are audited at
that boundary.

Metal/CPU parity for developed linear ACEScg uses a maximum absolute channel tolerance of `2e-5`
over all four Bayer patterns, odd global CFA origins, edge support and aggressive white balance and
develop exposure. Raw sensor codes and clipping masks are still produced by the unchanged CPU sensor
owner and are bit-identical because Metal begins strictly after the authoritative RAW boundary.

Application also owns a modulation-free `SpatialOpticalPlan` and `SpatialOpticalBackend` port. The
plan contains the validated camera and screen samples, sensor window, panel geometry and
colorimetry, cover and environment, globally selected 16–128 aperture sample count, and either the
procedural signal or prepared raster signal plus linear post-EOTF emission. It deliberately cannot
represent panel temporal modulation. The macOS adapter executes Brown-Conrady inversion, aperture
and thin-lens rays, chromatic offsets, resolved or area-integrated panel structure, EOTF, cover
Fresnel/transmission/reflection and native-to-ACEScg conversion in one Metal kernel. Physical
domains contain no Metal dependency, and a future Windows adapter can implement the same port.

The scalar implementation remains available only through explicitly named CPU-oracle functions.
Optical conformance currently covers procedural and raster signals, RGB/BGR layouts, resolved and
unresolved integration, high black-matrix coverage, strong lens distortion and active cover
character. The explicit channel tolerance is maximum absolute `2e-3` or maximum relative `2e-4`;
panel-hit identity must be exact.

Native work is partitioned into 128-pixel sensor tiles. Progress publishes after each completed tile
and cancellation is checked before the next tile. Completed staging remains non-authoritative and a
cancelled job never publishes a partial result.

The reproducible benchmark is:

```text
cargo run --release -p screen-desktop --bin native_benchmark
```

It reports cold Metal setup, time to the first complete Native tile, end-to-end physical throughput
for the iPhone 16e model with rolling shutter and eight temporal samples, a measured 48 MP
extrapolation, and isolated CPU/Metal RAW-development time. Extrapolation is diagnostic evidence,
not a promise: it assumes linear pixel scaling for the same authored scene and hardware.

The 2026-08-05 release measurement on Apple M3 Ultra reported 0.045 s cold backend setup, 2.065 s
to the first complete 128×128 product tile on the pre-factorization path, 7,936 sensor pixels/s
end-to-end and a 1.7 h linear extrapolation for 8064×6048. Isolated 1024×768 RAW development
measured 0.018 s CPU versus 0.003 s Metal, or 5.75×. This localizes the legacy-shaped cost in the
repeated CPU optical evaluator rather than RAW development.

After the clean-display temporal decision, the benchmark also measures one authoritative spatial
optical evaluation separately from the existing rolling/PWM repetition. For an exact 128×128
sensor window, the CPU oracle measured 0.013 s or 1.28 million pixels/s. The first Metal spatial
result arrived in 0.013 s; eight subsequent dispatches measured 11.76 million pixels/s, a 9.2×
spatial speedup and 4.1 s linear 48 MP spatial extrapolation. The legacy-shaped eight-sample rolling
measurement remains 2.065 s per product tile and 1.7 h extrapolated until the independent temporal
contract lands. Motion that genuinely changes source or geometry still requires its explicitly
authored spatial samples; the backend never reduces them.

The remaining integration tranche is precisely bounded:

1. Consume the separately published analytical temporal contract, then select the spatial Metal
   port in the sole Native product composition path.
2. Preserve exact authored motion samples while applying separable residual modulation and optional
   per-row banding without repeating static geometry, lens, cover or panel work.
3. Split GPU command work below the publication tile if measured cancellation latency exceeds the
   interactive bound on larger windows.
4. Extend end-to-end parity through optical exposure, deterministic RAW codes and final development
   for global/rolling readout and analytic banding identity/edge cases.
