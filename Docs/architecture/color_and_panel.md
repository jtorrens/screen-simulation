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
→ optical-cover transmission and authored environment reflection
→ per-emitter lens integration with absolute luminance retained
→ explicit native-primary/white-point conversion
→ linear image-plane illuminance in ACEScg
```

The source transform and panel EOTF must never linearize the same signal twice. `screen-color` resolves named transformations and reference processing. `screen-panel` alone converts the final device signal into physical emission.

Media transports declared primaries, transfer characteristic, matrix coefficients and range as typed metadata without interpreting them. `screen-color` may return one proposal only for a complete exact metadata pattern that it owns. A proposal is visible UI information and never becomes an authored selection. The persisted authored selection is authoritative. Missing, conflicting, unsupported or unknown required interpretation blocks evaluation. `Identity` is a valid explicit Source-to-Device selection; it is never an implicit fallback. Named transforms are stable application identifiers resolved only by `screen-color` against the one bundled OCIO configuration. The desktop receives the catalog labels and proposal from `screen-color`; it does not reproduce OCIO names or color rules.

Alpha association is an independent authored decision. `Auto` accepts only unambiguous association metadata; otherwise evaluation blocks. `Straight` and `Premultiplied` are explicit overrides for absent or incorrect metadata. Before the source color processor, straight RGB remains unassociated and premultiplied RGB is unassociated explicitly; zero-alpha samples resolve to zero unassociated RGB. After the color processor, both representations are associated with their unchanged alpha over the current explicit opaque-black target. Alpha interpretation never selects an IDT.

The current panel is a fixed-pixel LCD with complete native raster, physical active width and height, derived pixel pitch/PPI, RGB or BGR stripe layout, subpixel geometry, black matrix, EOTF, black level, white luminance, native-primary chromaticities, white-point chromaticity, per-emitter angular falloff and an exact PWM emission period/on-duration/phase. PPI and pixel pitch are derived from native raster and active dimensions and cannot contradict them. The primary-normalization matrix is solved from the declared white point, so device RGB `[1,1,1]` reproduces both that chromaticity and `white_level_nits`; no independent channel-gain authority may contradict them. Validation rejects non-finite or ill-conditioned primary matrices, non-positive primary scales, singular Bradford cone responses and unbounded final transform coefficients before an evaluator can exist. Native emission is converted through XYZ with chromatic adaptation to the ACEScg D60 basis only after channel-dependent optical evaluation. PWM gain is evaluated from exact project time before shutter integration, and its exact transitions partition the shutter quadrature so binary duty cycle cannot alias against the authored motion-sample count. A full-duty profile is explicit continuous emission with no temporal transitions, not a bypass route.

Every physical Composite sample evaluates the same native panel geometry. Resolution is decided independently for every rendered pixel from its complete per-channel sensor/aperture footprint. Resolved structure uses deterministic 4x4 sensor-pixel quadrature and evaluates native stripe position. When that footprint cannot resolve individual stripes, Panel analytically integrates the periodic emitter and black-matrix mask over the footprint at its exact device-cell phase. Complete cell periods converge to the declared channel average, while fractional periods retain phase variation so the sensor lattice may produce physical spatial aliasing and moire instead of an ideal uniform replacement. Device content independently uses a deterministic separable area integral of the piecewise-constant native raster for each aperture footprint. A double-precision summed-area representation is built once per source frame, so every rectangular content integral has bounded constant sampling cost independent of its covered pixel count without overflowing on finite float source values. No interpolated signal may vary between a device pixel's subpixels. Diagnostic views change presentation and inspection only; they never substitute another panel model.

Bundled device presets currently describe LCD geometry, a reference operating white and one default optical-cover preset. They do not claim OLED or MicroLED emission and cannot label the LCD evaluator as another panel technology. A preset is an authoring template rather than a runtime profile reference; selection copies its values and the copied white and cover remain editable.

`screen-panel` ends at the emissive LCD surface. `screen-cover` owns the next physical boundary: thickness and refractive index, RGB absorption, Fresnel reflection, anti-reflective efficiency, roughness, haze and reflected authored environment radiance. Application resolves one smooth cover-surface ray from the same camera/screen geometry and applies the cover before lens and sensor capture. The current model is a bounded tristimulus approximation; it does not claim wavelength-resolved thin-film interference, polarization or multi-bounce internal ghosting. Diagnostic emission views remain before the cover, while Composite and Camera Result consume it.

The current environment is an explicit procedural linear-radiance profile with ambient illumination and one finite angular source. A future HDR adapter replaces only that authored incident-radiance source and must enter the same `screen-cover` evaluator. It cannot introduce another reflection operator. Cover and environment character amounts are multiplicative authoring controls: zero cover is an exact identity, zero environment contributes no reflection and values above one deliberately exaggerate the current material response.

Illumination of external scene geometry by the panel is a later scene-renderer responsibility. It must consume the already-evaluated panel as a physical rectangular area emitter, including its spatial signal and angular response. A presentation-space halo or edge glow is not an acceptable substitute. Cover-internal edge losses and reflections remain part of `screen-cover`; emitted light falling on surrounding objects belongs outside it.

Internal emission and composition use linear float values. Negative and above-one values remain valid until an explicit display or output transform permits clipping or quantization.

Photometric calibration uses authored achromatic device-signal codes, the current panel EOTF and declared physical black/white luminance. Tests require a known uniform device code to preserve the EOTF ratio through the optical evaluator, require shutter integration and optical ND to preserve their analytic lux-second ratios, require the sensor to quantize a known exposure without changing its physical full-well decision, and require explicit camera development to place its authored middle-gray exposure. A processed handset photograph is never a luminance authority because its exposure automation and computational development are unknown; it may be used only as a later perceptual reference.

The developed camera result enters `screen-color` as immutable linear ACEScg. Camera output selection uses one stable application identifier resolved against the pinned bundled configuration. The current catalog is ACES 2.0 sRGB SDR 100 nit, Rec.709 SDR 100 nit and Rec.2100 PQ 1000 nit. Preview and export must consume the same resolved output processor; the active monitor never selects or substitutes a transform. Selecting another output does not recompute sensor capture, demosaic, white balance or the authoritative ACEScg result. Scene-linear output is a separate explicit encoding boundary, not an OCIO display-transform fallback.
