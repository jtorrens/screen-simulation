# Color and physical panel boundary

Status: normative.

Spatial resolution and color meaning are independent. A device-native source establishes one source pixel per device pixel under `OneToOne`; it does not establish what its RGB code values mean. Sources of any raster size require an explicit placement policy before panel evaluation.

The current boundary is:

```text
decoded encoded RGB
→ explicit Source Color Interpretation
→ explicit Source-to-Device transform
→ nonlinear device signal RGB
→ panel EOTF, black/white levels and channel response
→ physical native-primary subpixel emission and angular response
→ per-emitter lens integration
→ explicit native-primary/white-point conversion
→ linear relative irradiance in ACEScg
```

The source transform and panel EOTF must never linearize the same signal twice. `screen-color` resolves named transformations and reference processing. `screen-panel` alone converts the final device signal into physical emission.

Media transports declared primaries, transfer characteristic, matrix coefficients and range as typed metadata without interpreting them. `screen-color` may return one proposal only for a complete exact metadata pattern that it owns. A proposal is visible UI information and never becomes an authored selection. The persisted authored selection is authoritative. Missing, conflicting, unsupported or unknown required interpretation blocks evaluation. `Identity` is a valid explicit Source-to-Device selection; it is never an implicit fallback. Named transforms are stable application identifiers resolved only by `screen-color` against the one bundled OCIO configuration. The desktop receives the catalog labels and proposal from `screen-color`; it does not reproduce OCIO names or color rules.

Alpha association is an independent authored decision. `Auto` accepts only unambiguous association metadata; otherwise evaluation blocks. `Straight` and `Premultiplied` are explicit overrides for absent or incorrect metadata. Before the source color processor, straight RGB remains unassociated and premultiplied RGB is unassociated explicitly; zero-alpha samples resolve to zero unassociated RGB. After the color processor, both representations are associated with their unchanged alpha over the current explicit opaque-black target. Alpha interpretation never selects an IDT.

The current panel is a fixed-pixel LCD with complete native raster, physical active width and height, derived pixel pitch/PPI, RGB or BGR stripe layout, subpixel geometry, black matrix, EOTF, channel efficiency, black level, white level, native-primary chromaticities, white-point chromaticity and per-emitter angular falloff. PPI and pixel pitch are derived from native raster and active dimensions and cannot contradict them. Native emission is converted through XYZ with chromatic adaptation to the ACEScg D60 basis only after channel-dependent optical evaluation.

Every physical Composite sample evaluates the same native panel geometry. The current CPU reference integrates a deterministic 4x4 sensor-pixel quadrature together with the aperture pattern. Resolution is decided independently for every rendered pixel from its complete per-channel sensor/aperture footprint: unresolved periodic subpixel/black-matrix structure uses its exact area average, while resolved structure evaluates native stripe position. Device signal remains piecewise constant inside each native device pixel; no interpolated signal may vary between its subpixels. Diagnostic views change presentation and inspection only; they never substitute another panel model.

Internal emission and composition use linear float values. Negative and above-one values remain valid until an explicit display or output transform permits clipping or quantization.
