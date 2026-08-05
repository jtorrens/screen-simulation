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

The optical ray evaluator and exact shutter accumulation remain CPU in this first connected slice.
They are the measured dominant cost and the next Metal tranche must execute the existing prepared
optical model, including every selected temporal and aperture sample, rolling-row time, PWM
partition, cover ray and native panel phase. It must enter through a similarly narrow Application
port; it cannot add a second evaluator or retain a product CPU route. A future Windows backend may
implement these ports without introducing platform dependencies into any physical domain.

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

The 2026-08-05 release measurement on Apple M3 Ultra reported 0.114 s cold backend setup, 2.031 s
to the first complete 128×128 product tile, 8,067 sensor pixels/s end-to-end and a 1.7 h linear
extrapolation for 8064×6048. Isolated 1024×768 RAW development measured 0.017 s CPU versus 0.003 s
Metal, or 5.58×. This localizes the remaining cost in the pre-RAW optical evaluator rather than the
connected Metal stage.

The next implementation tranche is precisely bounded:

1. Add an Application-owned prepared optical-work contract containing validated frame, panel,
   cover, placement, temporal/PWM partitions and the globally selected aperture pattern.
2. Execute the current per-ray panel, cover and lens equations in Metal for procedural, static and
   time-varying device signal through that one contract.
3. Accumulate every exact temporal interval without reducing the authored sample count, retaining
   complete-sensor row/CFA/panel phase for ROI and full-frame requests.
4. Split GPU command work below the 128-pixel publication tile so cancellation can stop queued work
   promptly without publishing a partial authoritative tile.
5. Extend CPU-oracle parity to optical illuminance, RAW codes and final development for rolling/PWM,
   resolved/unresolved subpixels, cover extremes, 16–128 aperture samples and 1–64 temporal samples.
