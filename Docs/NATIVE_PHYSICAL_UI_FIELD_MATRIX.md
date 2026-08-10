# Native physical ABI-v2 UI field matrix

This matrix is the active binding contract for the native Model page. A preset
seeds one project-owned `DeviceDefinition` and
`PhysicalPipelineAuthoringState`; editing these controls never mutates the
global library. Both values are `Codable`, undoable snapshots. Every change is
validated, materialized into one immutable ABI-v2 snapshot, and invalidates the
interactive result or marks Native stale.

`R/G/B`, `XYZ`, `XY`, `K1..K3`, `P1..P2`, `M00..M22`, and quaternion `XYZW`
mean one native control per named component, not a summary-only display.

| Snapshot field | Native control | Unit / safe UI range | Preset/base and persistence |
|---|---|---|---|
| `device.native_width`, `native_height` | integer stepper + input | px / 1–32768 | Device preset → project override |
| `device.panel_technology` | read-only, **Derivado** | ABI enum | Only flat-panel technology supported by current Rust catalog |
| `device.stripe_layout` | picker RGB/BGR | discrete | Device preset → project override |
| `device.active_width_meters`, `active_height_meters` | slider + input | m / 0.001–20 | Device preset → project override |
| `device.black_matrix_fraction` | slider + input | ratio / 0–0.95 | Device preset → project override |
| `device.eotf_gamma` | slider + input | gamma / 1–4 | Device preset → project override |
| `device.black_level_nits`, `white_level_nits` | slider + input | nit / 0–20, 1–10000 | Device preset → project override |
| `device.primary_xy[0..5]`, `white_xy[0..1]` | component sliders + inputs | xy / 0–1 | Device preset → project override |
| `device.angular_emission_power[0..2]` | RGB sliders + inputs | exponent / 0–64 | Device preset → project override |
| `device.light_spread_character_strength` | card header amount | 0–4; detent 1 | Same effective contribution; not duplicated |
| `device.light_spread_core_radius_micrometers[0..2]` | RGB sliders + inputs | µm / 0–5000 | Device preset → project override |
| `device.light_spread_core_weight[0..2]` | RGB sliders + inputs | ratio / 0–1 | Device preset → project override |
| `device.light_spread_tail_radius_micrometers[0..2]` | RGB sliders + inputs | µm / 0–20000 | Device preset → project override |
| `device.light_spread_tail_weight[0..2]` | RGB sliders + inputs | ratio / 0–1 | Device preset → project override |
| `device.residual_period_numerator/denominator` | integer steppers + inputs | rational seconds | Device preset → project override |
| `device.residual_amplitude` | slider + input | ratio / 0–1 | Device preset → project override |
| `device.residual_phase_numerator/denominator` | integer steppers + inputs | rational seconds | Device preset → project override |
| `device.banding_period_*`, `banding_on_*`, `banding_phase_*` | integer steppers + inputs | rational seconds | Device preset → project override |
| `device.banding_amount` | slider + input | 0–4 | Device preset → project override |
| `cover.authority` | Cover Glass preset picker | discrete | Selected global item copied into project state |
| `cover.character_strength` | card header amount | 0–2; detent 1 | Same effective contribution; not duplicated |
| `cover.thickness_millimeters` | slider + input | mm / 0.01–20 | Cover preset → project override |
| `cover.refractive_index` | slider + input | IOR / 1–3 | Cover preset → project override |
| `cover.anti_reflective_efficiency` | slider + input | ratio / 0–1 | Cover preset → project override |
| `cover.absorption_per_millimeter[0..2]` | RGB sliders + inputs | mm⁻¹ / 0–20 | Cover preset → project override |
| `cover.roughness`, `cover.haze` | slider + input | ratio / 0–1 | Cover preset → project override |
| `environment.character_strength` | card header amount | 0–4; detent 1 | Same effective contribution; not duplicated |
| `environment.ambient_radiance_acescg[0..2]` | RGB sliders + inputs | nit / 0–100000 | Project base → override |
| `environment.key_radiance_acescg[0..2]` | RGB sliders + inputs | nit / 0–100000 | Project base → override |
| `environment.key_direction_local[0..2]` | XYZ sliders + inputs | normalized component / −1–1 | Project base → override |
| `environment.key_angular_radius_degrees` | slider + input | degrees / 0.01–180 | Project base → override |
| `environment.rotation_degrees` | slider + input | degrees / −360–360 | Project base → override |
| `environment.pattern` | native picker | ABI enum 0–2 | Project base → override |
| `scene.focal_length_millimeters` | slider + input | mm / 0.1–2000 | Project base → override |
| `scene.sensor_width/height_millimeters` | slider + input | mm / 0.1–200 | Project base → override |
| `scene.lens_shift[0..1]` | XY sliders + inputs | normalized / −2–2 | Project base → override |
| `scene.focus_distance_meters` | slider + input | m / 0.001–100000 | Derived only at initial seed, then project override |
| `scene.f_stop` | slider + input | f-number / 0.1–128 | Project base → override |
| `scene.near_clip_meters`, `far_clip_meters` | sliders + inputs | m / 0.0001–100000 | Project base → override |
| `scene.lens_radial_distortion[0..2]` | K1–K3 sliders + inputs | −10–10 | Project base → override |
| `scene.lens_tangential_distortion[0..1]` | P1–P2 sliders + inputs | −10–10 | Project base → override |
| `scene.lens_longitudinal_chromatic_meters[0..2]` | RGB sliders + inputs | m / −1–1 | Project base → override |
| `scene.lens_lateral_chromatic_scale[0..2]` | RGB sliders + inputs | scale / 0–4 | Project base → override |
| `scene.lens_vignetting_strength` | slider + input | 0–4 | Project base → override |
| `scene.lens_transmission_rgb[0..2]` | RGB sliders + inputs | scale / 0–4 | Project base → override |
| `scene.lens_center/edge_softness_micrometers` | sliders + inputs | µm / 0–10000 | Project base → override |
| `scene.lens_veiling_glare_fraction` | slider + input | fraction / 0–0.25 | Lens preset → project override; wide-field gate-average approximation |
| `camera_pose.position[0..2]`, `screen_pose.position[0..2]` | XYZ sliders + inputs | m / −100–100 | Explicit project tracks, constant for this phase |
| `camera_pose.quaternion[0..3]`, `screen_pose.quaternion[0..3]` | XYZW sliders + inputs | −1–1, normalized at boundary | Explicit project tracks; no target/yaw/screen-scale state |
| `shutter.temporal_samples` | integer stepper + input | 1–256 | Project base → override |
| `shutter.readout_kind` | Global/Rolling picker | discrete | Project base → override |
| `shutter.readout_duration_numerator/denominator` | integer steppers + inputs | rational seconds | Project base → override |
| `shutter.readout_direction` | integer enum input | 0–3 | Project base → override |
| `shutter.neutral_density_stops` | slider + input | stops / 0–32 | Project base → override |
| `shutter.noise_seed` | integer input | UInt64 domain | Project base → override |
| frame `shutter_open_*`, `shutter_close_*` | offset numerator/denominator inputs | rational seconds from selected frame | Explicit project state |
| `sensor.native_width`, `native_height` | integer steppers + inputs | px / 1–32768 | Project base → override |
| `sensor.bayer_pattern` | RGGB/BGGR/GRBG/GBRG picker | discrete | Project base → override; CFA card enable remains separate |
| `sensor.acescg_to_sensor[0..8]` | M00–M22 sliders + inputs | matrix / −8–8 | Project base → override |
| `sensor.saturation_illuminance_seconds[0..2]` | RGB sliders + inputs | lux·s / 0.0001–1000000 | Project base → override |
| `sensor.full_well_electrons` | slider + input | e⁻ / 1–10000000 | Project base → override |
| `sensor.dark_current_electrons_per_second` | slider + input | e⁻/s / 0–1000000 | Project base → override |
| `sensor.read_noise_electrons_rms` | slider + input | e⁻ RMS / 0–1000000 | Project base → override |
| `sensor.analog_gain` | slider + input | gain / 0.0001–1000000 | Project base → override |
| `sensor.adc_bits` | integer stepper + input | bits / 1–31 | Project base → override |
| `develop.white_balance[0..2]` | RGB sliders + inputs | gain / 0.001–32 | Project base → override |
| `develop.middle_gray_illuminance_seconds` | slider + input | lux·s / 0.000001–1000000 | Project base → override |
| `develop.develop_exposure_ev` | slider + input | EV / −32–32 | Project base → override |
| demosaic mode | read-only, **Derivado** | Edge-directed | ABI v5 exposes no selectable demosaic field; no fake state is stored |
| lens/sensor preset reference | read-only, **Derivado** | resolved values | ABI v5 stores values, not dynamic preset references; no lookup/fallback |

Continuous contribution bypass is persisted separately from stored amount.
OFF emits effective amount zero at the request boundary and diagnostics append
`BYPASSED · effective 0 · stored …`; editing while OFF changes only the stored
value. CFA and Develop remain their single discrete enables and receive no
redundant bypass.
