# Radiometric patch validation

## Purpose

This validation checks whether the physical pipeline produces plausible,
internally consistent sensor exposure from a display patch. It is not a visual
fit to an iPhone HEIC and it does not use a reference photograph to calibrate
the camera presets.

The authoritative boundary is:

`panel luminance [cd/m²] × π/(4·T²) × shutter [s] × 2^-ND × camera calibration`

The result is evaluated before and after the real sensor, CFA, ADC and develop
stages. Preview ODT and ColorSync do not participate in these measurements.

## Method

- Uniform encoded-white device patch.
- Production display EOTF and production camera profiles.
- Spatial character, reflections, temporal modulation and noise disabled so
  the test isolates absolute exposure.
- Sensor/CFA/full-well/ADC and RAW development remain enabled.
- Measurements: normalized RAW mean, full-well clipping, ADC clipping and
  Developed ACEScg luminance.

The automated suite also iterates every capture preset in the catalog. A new
camera cannot pass unless doubling panel nits, shutter duration or EI produces
one RAW stop, ND 1 removes one stop, and the reference patches remain below
clipping.

## Production profile matrix

| Camera / exposure | Display white | RAW mean | Full-well clipped | ADC clipped | Developed ACEScg Y |
|---|---:|---:|---:|---:|---:|
| ARRI ALEXA 35 · 1/48 · EI 800 | 100 nit | 0.090887 | 0% | 0% | 3.141052 |
| ARRI ALEXA 35 · 1/48 · EI 800 | 350 nit | 0.318196 | 0% | 0% | 10.996843 |
| ARRI ALEXA 35 · 1/48 · EI 800 | 625 nit | 0.568150 | 0% | 0% | 19.635256 |
| ARRI ALEXA 35 · 1/48 · EI 800 | 1000 nit | 0.909053 | 0% | 0% | 31.416862 |
| iPhone 16e · 1/48 · EI 100 | 100 nit | 1.000000 | 100% | 100% | 1.440000 |
| iPhone 16e · 1/60 · EI 80 | 100 nit | 0.800000 | 100% | 0% | 1.440000 |
| iPhone 16e · 1/82 · EI 80 | 100 nit | 0.800000 | 100% | 0% | 1.440000 |
| iPhone 16e · 1/48 · EI 320 | 100 nit | 1.000000 | 100% | 100% | 0.450000 |

The iPhone cases saturate at 100 nit with the tested production settings. This
matches the expected direction: an uncorrected fast mobile lens aimed at a
bright display requires a shorter exposure, lower gain or computational
highlight handling. The ARRI profile retains measurable highlight headroom up
to the tested 1000-nit white.

Developed ACEScg values are scene-linear and may be greater than one. They must
not be interpreted as display code values. Once a sensor value clips, changing
EI can change its normalized developed value but cannot restore lost highlight
detail.

## Supplied iPhone references

The supplied photographs of the 1000-nit PQ monitor are used only as a
plausibility reference. Available EXIF values include:

| File | Aperture | Focal length | Exposure | ISO |
|---|---:|---:|---:|---:|
| IMG_3932.HEIC | f/1.64 | 4.2 mm | 1/60 s | 125 |
| IMG_3935.HEIC | f/1.64 | 4.2 mm | 1/82 s | 80 |
| IMG_3936.HEIC | f/1.64 | 4.2 mm | 1/76 s | 80 |
| IMG_3937.HEIC | f/1.64 | 4.2 mm | 1/48 s | 320 |
| IMG_3938.HEIC | f/1.64 | 4.2 mm | 1/60 s | 80 |

They are not numeric calibration targets because the photographed pixel value
inside the PQ image is unknown and the HEIC includes Apple's computational
capture, local tone mapping and display-referred encoding. The exposure range
is nevertheless consistent with the simulation predicting strong highlight
pressure for an iPhone at f/1.64.

## Reproduction

```sh
cargo test -p screen-application production_camera_display_patch_matrix_is_physically_plausible -- --nocapture
cargo test -p screen-application every_capture_preset_must_pass_radiometric_stop_invariants
```

