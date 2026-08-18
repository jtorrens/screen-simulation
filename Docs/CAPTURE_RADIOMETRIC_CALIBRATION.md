# Capture radiometric calibration

Every bundled capture preset carries one mandatory, explicit neutral-reference
calibration. It anchors the camera model to an 18% Lambertian target lit at
100 lux for 1/48 second at the preset reference EI/ISO. The calibration maps
that incident condition to the image-plane illuminance exposure used by the
sensor/RAW model and declares the expected developed ACEScg neutral value
(0.18).

This is an auditable model calibration, not a claim that a vendor's spectral
sensitivities, colour science, lens transmission or computational processing
have been measured. The calibration strings expose that scope in the UI.

## Required golden checks

For every preset, the application test suite verifies:

- reference condition resolves exactly to the preset middle-gray exposure;
- +1 shutter stop doubles the pre-ADC exposure;
- +1 EI/ISO doubles the pre-ADC exposure;
- +1 ND stop halves the pre-ADC exposure.

The C/Swift bridge exports this contract through
`ScreenCaptureRadiometricCalibrationV2`; new presets cannot enter the Rust
catalogue without its non-zero values and the golden checks.

The next radiometric work item is the explicit physical conversion from panel
luminance (nits) and optical geometry to the incident illuminance used by this
anchor. Until that boundary is measured, the camera pipeline is physically
consistent in relative stops but is not a photometric prediction in absolute
units.
