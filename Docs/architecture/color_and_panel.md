# Color and physical panel boundary

Status: normative.

Spatial resolution and color meaning are independent. A device-native source establishes one source pixel per device pixel; it does not establish what its RGB code values mean.

The current boundary is:

```text
decoded encoded RGB
→ explicit Source Color Interpretation
→ explicit Source-to-Device transform
→ nonlinear device signal RGB
→ panel EOTF, black/white levels and channel response
→ physical RGB subpixel emission
→ linear emitted radiance in ACEScg
```

The source transform and panel EOTF must never linearize the same signal twice. `screen-color` resolves named transformations and reference processing. `screen-panel` alone converts the final device signal into physical emission.

Metadata may propose a source interpretation. The persisted authored selection is authoritative. Missing, conflicting, or unknown required interpretation blocks evaluation. `Identity` is a valid explicit Source-to-Device selection; it is never an implicit fallback.

The current panel is a fixed-pixel LCD with complete native raster, physical active width and height, derived pixel pitch/PPI, RGB or BGR stripe layout, subpixel geometry, black matrix, EOTF, channel efficiency, black level, white level and point white. PPI and pixel pitch are derived from native raster and active dimensions and cannot contradict them.

Internal emission and composition use linear float values. Negative and above-one values remain valid until an explicit display or output transform permits clipping or quantization.

