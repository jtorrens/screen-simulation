# Native color and identity matrix

Date: 2026-08-06  
Branch: `feature/native-macos-shell`  
Authority: CREDITOS-HDR color implementation, current shared-output consumer at
`4c54d66cbbcea6393adee6902157bd836a0cf64c`

## Reproduction

```sh
cd packages/StudioColor && swift test
cd ../../apps/screen-native-macos && swift test
SCREEN_GOLDEN_SOURCE=/Volumes/SD_02/PROYECTOS/FOQN/FOQN_E06/CHATS/FOQN_E06_0090.mov \
  swift test --filter suppliedGoldenMovieRoundtrip
```

The optional golden test renders the complete supplied movie through the native
authoritative graph, reopens its output, and compares all 38 frames. The normal
test suite uses generated deterministic ramps, neutral and saturated patches,
two-pixel spatial frequencies, three distinct frame indices, alpha ramps, zero
alpha edges, hidden RGB, negative values, and values above one.

## Fixed color identity

- OCIO: 2.5.2.
- ACES Studio Config: 4.0.0 / ACES 2.0.
- Config SHA-256: `ebe2293968975e3540c6b32cfbee2ca1274b5bf3c9ff610235abb07b65da970b`.
- Native bridge SHA-256: `680eef3911af83b3579d7b7dbe27c9970d273859edd3b5fbdc0a2cc8968ee67f`.
- Working contract: premultiplied RGBA16Float, linear ACEScg. Negative and
  above-one values remain available before an output transform.

## Results and tolerances

| Contract | Result | Published tolerance |
|---|---:|---:|
| ACES SDR Rec.709 inverse display -> ACEScg -> matching ACES 2.0 ODT | pass | <= 1 code at 8-bit output |
| ACES HDR Rec.2100 PQ inverse -> ACEScg -> matching 1000-nit ODT | pass over legal 1000-nit PQ domain | max float error `2e-4` |
| DCM SDR Rec.709 Gamma 2.4 -> ACEScg -> Rec.709 Gamma 2.4 | pass | max float error `3e-5` |
| DCM HDR Rec.2100 ST2084 -> ACEScg -> colorimetric Rec.2100 ST2084 | pass | max float error `1e-3` |
| ACEScg OpenEXR half, straight alpha, negatives and values >1 | pass | max float error `0.001` |
| ProRes 4444 Y′CbCr 4:4:4 12-bit legal, straight alpha | pass | max `0.016723633`, RMSE `0.00048350522` in ACEScg |
| ProRes 4444 Y′CbCr 4:4:4 12-bit legal, premultiplied alpha | pass | max `0.016113281`, RMSE `0.00051007664` in ACEScg |
| H.264 High, BT.709 legal, Y′CbCr 4:2:0 8-bit | pass | max `0.1953125`, total RMSE `0.03585555`; neutral/color-path RMSE `0.011856354` |
| H.264 High, BT.709 full, Y′CbCr 4:2:0 8-bit | pass | max `0.17816162`, total RMSE `0.03584964`; neutral/color-path RMSE `0.01402558` |
| H.265 Main10 PQ, BT.2020 NCL, legal and full | pass | coded metadata, pixel layout and range re-detected exactly |

The H.264 total metric deliberately includes two-pixel saturated structure, so
it records expected codec/subsampling damage. The neutral-only metric isolates
the color graph and prevents that codec loss from hiding an extra transform.

PQ code 1.0 represents 10,000 nits and lies outside the invertible range of the
selected 1,000-nit ACES output. Its legal roundtrip ceiling is approximately
0.7518. Above-one HDR scene values are tested and preserved in ACEScg rather
than being misclassified as legal PQ code values.

## Supplied golden movie

Source: `FOQN_E06_0090.mov`, 1000 x 2000, 38 frames, 25 fps, ProRes 4444,
Y′CbCr 4:4:4 12-bit legal with alpha and BT.709 primaries/transfer/matrix.
Result after a new complete ACES SDR
inverse-display/ACEScg/ODT/ProRes generation:

- output re-detected as Y′CbCr 4:4:4 legal BT.709, never inferred merely from
  the ProRes codec name;
- redecoded display maximum: 4 codes;
- redecoded display RMSE: 0.406665 codes;
- sequential decode -> ACEScg -> completed preview p95: 15.172 ms
  (about 66 fps capacity at this raster on the test machine).

The inverse reconstructed ACEScg comparison reports max `212.875` and RMSE
`0.28153` for a small set of display-referred samples near inverse-DRT
singularities. Reapplying the exact matching ODT returns those samples within
the display tolerance above. Therefore this golden is a display roundtrip, as
defined by CREDITOS-HDR's notes, and is not claimed to be a scene-linear EXR
identity test. The separate EXR test owns scene-linear identity.

Preview and render queue resolve processors from the same `StudioColor` engine,
configuration and Metal shader generator. CPU/Metal parity passes every viewer
transform with maximum one 8-bit code and no more than 0.5% changed components.

## Render identity versus preview identity

Render validation stops at the coded standard signal. It persists the effective
container/codec profile, pixel encoding, range, alpha, audio, ODT, peak nits,
frame rate and frame range. The Mac ICC profile is absent from this graph.

Preview validation continues from the same ACEScg/Physical result through the
selected standard ODT into a tagged CAMetalLayer. ColorSync alone converts that
signal to the physical monitor. The manual-QA host currently reports display
ID 3, `ASUS PA329CV`, active ColorSync profile `ASUS PA329CV`, system color
space `ASUS PA329CV`. Profile and screen changes are observed by the shared
StudioColor boundary and refresh the visible diagnostic.

The codec name is never treated as a pixel contract. The current effective
writer matrix is: H.264 = Y′CbCr 4:2:0 8-bit legal/full; H.265 Main10 = Y′CbCr
4:2:0 10-bit legal/full; Apple ProRes 4444/XQ = Y′CbCr 4:4:4 12-bit legal;
DPX = RGB 10-bit full; TIFF = RGB 16-bit full; OpenEXR = RGBA float16
scene-linear. ProRes 4444 as a codec can receive material originating in RGB or
Y′CbCr, and files from other writers may declare a different model/range. Input
metadata therefore records model, matrix and range independently. On this host,
AVAssetWriter ignored a full-range attachment on RGBA-half ProRes input and
rejected the available full-range Y′CbCr rendering buffer (`-12905`); those
unimplemented combinations are not exposed as successful output options.

## Shared video-output boundary

The authoritative CREDITOS-HDR implementation has been extracted in a single
cut to the version-pinned `StudioVideoOutput` 0.2.0 package at
`5b82e0a5505fc86dcbeda53bc767602b602de44f`. It is the sole owner
of the official DeckLink SDK headers, runtime probe, capability models and
output handle. Both applications consume that package; neither contains a
bridge copy or references another repository checkout.

SCREEN-SIMULATION resolves a dedicated monitor ODT plus device, mode,
resolution/fps, range and pixel format. That immutable configuration is
independent of both the macOS preview transform and render-queue ODT. Missing
Desktop Video or hardware is reported explicitly and never replaced by a
preview mirror, simulated device, stub or fallback.
