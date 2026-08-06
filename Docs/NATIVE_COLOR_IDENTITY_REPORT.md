# Native color and identity matrix

Date: 2026-08-06  
Branch: `feature/native-macos-shell`  
Authority: CREDITOS-HDR color implementation at `150ef31ffa69fec562a017d2165006f7b2913520`

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
| ProRes 4444, 24 fps, straight alpha | pass | max `0.016357422`, RMSE `0.00041711322` in ACEScg |
| ProRes 4444, 24 fps, premultiplied alpha | pass | max `0.016357422`, RMSE `0.00047576486` in ACEScg |
| H.264 High, BT.709 video range and 4:2:0 | pass | max `0.19308472`, total RMSE `0.03578926`; neutral/color-path RMSE `0.008988895` |

The H.264 total metric deliberately includes two-pixel saturated structure, so
it records expected codec/subsampling damage. The neutral-only metric isolates
the color graph and prevents that codec loss from hiding an extra transform.

PQ code 1.0 represents 10,000 nits and lies outside the invertible range of the
selected 1,000-nit ACES output. Its legal roundtrip ceiling is approximately
0.7518. Above-one HDR scene values are tested and preserved in ACEScg rather
than being misclassified as legal PQ code values.

## Supplied golden movie

Source: `FOQN_E06_0090.mov`, 1000 x 2000, 38 frames, 25 fps, ProRes 4444,
BT.709 primaries/transfer/matrix. Result after a new complete ACES SDR
inverse-display/ACEScg/ODT/ProRes generation:

- redecoded display maximum: 5 codes;
- redecoded display RMSE: 0.376716 codes;
- sequential decode -> ACEScg -> completed preview p95: 14.631 ms
  (about 68 fps capacity at this raster on the test machine).

The inverse reconstructed ACEScg comparison reports max `317.5` and RMSE
`0.27021` for a small set of display-referred samples near inverse-DRT
singularities. Reapplying the exact matching ODT returns those samples within
the display tolerance above. Therefore this golden is a display roundtrip, as
defined by CREDITOS-HDR's notes, and is not claimed to be a scene-linear EXR
identity test. The separate EXR test owns scene-linear identity.

Preview and render queue resolve processors from the same `StudioColor` engine,
configuration and Metal shader generator. CPU/Metal parity passes every viewer
transform with maximum one 8-bit code and no more than 0.5% changed components.

## Remaining phase boundary

DeckLink has not been copied into this repository. Its authoritative
`CreditsVideoOutput` plus `CreditsDeckLinkBridge` implementation depends on the
official vendored DeckLink SDK headers in CREDITOS-HDR. Moving those files into
a genuinely shared package requires a repository/licensing cut; referencing the
CREDITOS-HDR checkout or building a second local backend would violate the
no-cross-domain/no-parallel-route rule. The Settings monitor page therefore does
not pretend to offer an alternate implementation. The exact future cut is:

1. create one shared `StudioVideoOutput` package containing the unchanged
   bridge, official headers, capability models, runtime probe and output handle;
2. make SCREEN-SIMULATION and CREDITOS-HDR consume that same package in one cut;
3. delete `CreditsVideoOutput` and `CreditsDeckLinkBridge` from CREDITOS-HDR in
   the same integration commit;
4. give SCREEN-SIMULATION monitor selection its own independent StudioColor ODT,
   device, mode, range and pixel-format configuration.

No Device physical model is started while this phase boundary remains open.
