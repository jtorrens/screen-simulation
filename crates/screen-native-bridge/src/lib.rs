//! Coarse stable C ABI for the native shell's future Rust physical engine.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, c_float};

use screen_application::{ProceduralTestPattern, diagnostic_signal};
use screen_contracts::{DeviceRgb, LinearRgb, Meters, RationalTime, Vec2};
use screen_panel::{
    AnalyticBanding, Chromaticity, DEVICE_PRESETS, LcdProfile, PanelColorimetry, PanelTechnology,
    PanelTemporalEmission, ResidualFlicker, StripeLayout, ValidatedPanelEvaluator,
};

#[repr(C)]
pub struct ScreenUtf8View {
    bytes: *const u8,
    count: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenDeviceParametersV1 {
    abi_version: u32,
    native_width: u32,
    native_height: u32,
    panel_technology: u32,
    stripe_layout: u32,
    active_width_meters: f32,
    active_height_meters: f32,
    black_matrix_fraction: f32,
    eotf_gamma: f32,
    black_level_nits: f32,
    white_level_nits: f32,
    primary_xy: [f32; 6],
    white_xy: [f32; 2],
    angular_emission_power: [f32; 3],
    residual_period_numerator: i64,
    residual_period_denominator: u32,
    residual_amplitude: f32,
    residual_phase_numerator: i64,
    residual_phase_denominator: u32,
    banding_period_numerator: i64,
    banding_period_denominator: u32,
    banding_on_numerator: i64,
    banding_on_denominator: u32,
    banding_phase_numerator: i64,
    banding_phase_denominator: u32,
    banding_amount: f32,
}

pub struct ScreenDeviceProfile {
    evaluator: ValidatedPanelEvaluator,
}

#[repr(C)]
pub struct ScreenDeviceEvaluationParametersV1 {
    abi_version: u32,
    native_to_acescg: [f32; 9],
    eotf_gamma: f32,
    black_level_nits: f32,
    white_level_nits: f32,
}

fn utf8_view(value: &'static str) -> ScreenUtf8View {
    ScreenUtf8View {
        bytes: value.as_ptr(),
        count: value.len(),
    }
}

fn preset_at(index: usize) -> Option<screen_panel::DevicePreset> {
    DEVICE_PRESETS.get(index).copied()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_count() -> usize {
    DEVICE_PRESETS.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_id(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.id))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_label(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.label))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_category(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.category))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_white_basis(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.white_basis))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_default_cover_id(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| {
        utf8_view(preset.default_cover_glass_preset_id)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_preset_parameters(
    index: usize,
    parameters: *mut ScreenDeviceParametersV1,
) -> bool {
    let Some(preset) = preset_at(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    // SAFETY: the caller provided a writable V1 parameter structure.
    unsafe { *parameters = parameters_from_profile(preset.profile(), preset.panel_technology) };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_create(
    parameters: *const ScreenDeviceParametersV1,
    error_message: *mut *const c_char,
) -> *mut ScreenDeviceProfile {
    if parameters.is_null() {
        unsafe { set_error(error_message, b"missing device parameters\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null parameters pointer is valid for this call.
    let parameters = unsafe { *parameters };
    let profile = match profile_from_parameters(parameters) {
        Ok(profile) => profile,
        Err(message) => {
            unsafe { set_error(error_message, message) };
            return std::ptr::null_mut();
        }
    };
    let evaluator = match profile.evaluator() {
        Ok(evaluator) => evaluator,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid physical device evaluator\0") };
            return std::ptr::null_mut();
        }
    };
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenDeviceProfile { evaluator }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_release(profile: *mut ScreenDeviceProfile) {
    if !profile.is_null() {
        // SAFETY: the ABI requires the uniquely owned handle returned by create.
        unsafe { drop(Box::from_raw(profile)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_evaluation_parameters(
    profile: *const ScreenDeviceProfile,
    parameters: *mut ScreenDeviceEvaluationParametersV1,
) -> bool {
    if profile.is_null() || parameters.is_null() {
        return false;
    }
    // SAFETY: both pointers were validated for the duration of this call.
    let values = unsafe { (*profile).evaluator }.device_stage_parameters();
    // SAFETY: the caller provided a writable V1 parameter structure.
    unsafe {
        *parameters = ScreenDeviceEvaluationParametersV1 {
            abi_version: 1,
            native_to_acescg: [
                values.native_to_acescg[0][0],
                values.native_to_acescg[0][1],
                values.native_to_acescg[0][2],
                values.native_to_acescg[1][0],
                values.native_to_acescg[1][1],
                values.native_to_acescg[1][2],
                values.native_to_acescg[2][0],
                values.native_to_acescg[2][1],
                values.native_to_acescg[2][2],
            ],
            eotf_gamma: values.eotf_gamma,
            black_level_nits: values.black_level_nits,
            white_level_nits: values.white_level_nits,
        };
    }
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_evaluate_rgba32f(
    profile: *const ScreenDeviceProfile,
    device_code: *const c_float,
    acescg: *mut c_float,
    pixel_count: usize,
) -> bool {
    if profile.is_null()
        || (device_code.is_null() && pixel_count != 0)
        || (acescg.is_null() && pixel_count != 0)
    {
        return false;
    }
    // SAFETY: the ABI requires complete RGBA arrays for pixel_count pixels.
    let source = unsafe { std::slice::from_raw_parts(device_code, pixel_count * 4) };
    // SAFETY: the ABI requires writable RGBA storage for pixel_count pixels.
    let destination = unsafe { std::slice::from_raw_parts_mut(acescg, pixel_count * 4) };
    // SAFETY: the non-null handle is immutable for the duration of this call.
    let evaluator = unsafe { (*profile).evaluator };
    for (input, output) in source.chunks_exact(4).zip(destination.chunks_exact_mut(4)) {
        let value =
            evaluator.normalized_device_emission(DeviceRgb::new(input[0], input[1], input[2]));
        output.copy_from_slice(&[value.r, value.g, value.b, input[3]]);
    }
    true
}

fn parameters_from_profile(
    profile: LcdProfile,
    technology: PanelTechnology,
) -> ScreenDeviceParametersV1 {
    ScreenDeviceParametersV1 {
        abi_version: 1,
        native_width: profile.native_width,
        native_height: profile.native_height,
        panel_technology: match technology {
            PanelTechnology::IpsLcd => 0,
        },
        stripe_layout: match profile.stripe_layout {
            StripeLayout::Rgb => 0,
            StripeLayout::Bgr => 1,
        },
        active_width_meters: profile.active_width.0,
        active_height_meters: profile.active_height.0,
        black_matrix_fraction: profile.black_matrix_fraction,
        eotf_gamma: profile.eotf_gamma,
        black_level_nits: profile.black_level_nits,
        white_level_nits: profile.white_level_nits,
        primary_xy: [
            profile.colorimetry.red.x,
            profile.colorimetry.red.y,
            profile.colorimetry.green.x,
            profile.colorimetry.green.y,
            profile.colorimetry.blue.x,
            profile.colorimetry.blue.y,
        ],
        white_xy: [profile.colorimetry.white.x, profile.colorimetry.white.y],
        angular_emission_power: [
            profile.angular_emission_power.r,
            profile.angular_emission_power.g,
            profile.angular_emission_power.b,
        ],
        residual_period_numerator: profile
            .temporal_emission
            .residual_flicker
            .period
            .numerator(),
        residual_period_denominator: profile
            .temporal_emission
            .residual_flicker
            .period
            .denominator(),
        residual_amplitude: profile.temporal_emission.residual_flicker.amplitude,
        residual_phase_numerator: profile.temporal_emission.residual_flicker.phase.numerator(),
        residual_phase_denominator: profile
            .temporal_emission
            .residual_flicker
            .phase
            .denominator(),
        banding_period_numerator: profile
            .temporal_emission
            .analytic_banding
            .period
            .numerator(),
        banding_period_denominator: profile
            .temporal_emission
            .analytic_banding
            .period
            .denominator(),
        banding_on_numerator: profile
            .temporal_emission
            .analytic_banding
            .on_duration
            .numerator(),
        banding_on_denominator: profile
            .temporal_emission
            .analytic_banding
            .on_duration
            .denominator(),
        banding_phase_numerator: profile.temporal_emission.analytic_banding.phase.numerator(),
        banding_phase_denominator: profile
            .temporal_emission
            .analytic_banding
            .phase
            .denominator(),
        banding_amount: profile.temporal_emission.analytic_banding.amount,
    }
}

fn profile_from_parameters(
    parameters: ScreenDeviceParametersV1,
) -> Result<LcdProfile, &'static [u8]> {
    if parameters.abi_version != 1 {
        return Err(b"unsupported device parameter ABI\0");
    }
    if parameters.panel_technology != 0 {
        return Err(b"unsupported panel technology\0");
    }
    let stripe_layout = match parameters.stripe_layout {
        0 => StripeLayout::Rgb,
        1 => StripeLayout::Bgr,
        _ => return Err(b"unsupported subpixel layout\0"),
    };
    let time = |numerator, denominator| {
        RationalTime::new(numerator, denominator).map_err(|_| b"invalid device exact time\0" as _)
    };
    let profile = LcdProfile {
        native_width: parameters.native_width,
        native_height: parameters.native_height,
        active_width: Meters(parameters.active_width_meters),
        active_height: Meters(parameters.active_height_meters),
        stripe_layout,
        black_matrix_fraction: parameters.black_matrix_fraction,
        eotf_gamma: parameters.eotf_gamma,
        black_level_nits: parameters.black_level_nits,
        white_level_nits: parameters.white_level_nits,
        colorimetry: PanelColorimetry {
            red: Chromaticity {
                x: parameters.primary_xy[0],
                y: parameters.primary_xy[1],
            },
            green: Chromaticity {
                x: parameters.primary_xy[2],
                y: parameters.primary_xy[3],
            },
            blue: Chromaticity {
                x: parameters.primary_xy[4],
                y: parameters.primary_xy[5],
            },
            white: Chromaticity {
                x: parameters.white_xy[0],
                y: parameters.white_xy[1],
            },
        },
        angular_emission_power: LinearRgb::new(
            parameters.angular_emission_power[0],
            parameters.angular_emission_power[1],
            parameters.angular_emission_power[2],
        ),
        temporal_emission: PanelTemporalEmission {
            residual_flicker: ResidualFlicker {
                period: time(
                    parameters.residual_period_numerator,
                    parameters.residual_period_denominator,
                )?,
                amplitude: parameters.residual_amplitude,
                phase: time(
                    parameters.residual_phase_numerator,
                    parameters.residual_phase_denominator,
                )?,
            },
            analytic_banding: AnalyticBanding {
                period: time(
                    parameters.banding_period_numerator,
                    parameters.banding_period_denominator,
                )?,
                on_duration: time(
                    parameters.banding_on_numerator,
                    parameters.banding_on_denominator,
                )?,
                phase: time(
                    parameters.banding_phase_numerator,
                    parameters.banding_phase_denominator,
                )?,
                amount: parameters.banding_amount,
            },
        },
    };
    profile
        .validate()
        .map_err(|_| b"invalid physical device profile\0" as &'static [u8])
}

pub struct ScreenPhysicalPipeline;

#[unsafe(no_mangle)]
pub extern "C" fn screen_physical_pipeline_create() -> *mut ScreenPhysicalPipeline {
    Box::into_raw(Box::new(ScreenPhysicalPipeline))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_pipeline_release(pipeline: *mut ScreenPhysicalPipeline) {
    if !pipeline.is_null() {
        // SAFETY: the ABI requires the uniquely owned handle returned by create.
        unsafe { drop(Box::from_raw(pipeline)) };
    }
}

/// Exact in-place identity over one complete linear ACEScg image.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_pipeline_process_rgba32f(
    pipeline: *const ScreenPhysicalPipeline,
    pixels: *mut c_float,
    pixel_count: usize,
    error_message: *mut *const c_char,
) -> bool {
    if pipeline.is_null() || (pixels.is_null() && pixel_count != 0) {
        static ERROR: &[u8] = b"invalid PhysicalPipeline identity buffer\0";
        if !error_message.is_null() {
            // SAFETY: the optional out parameter is writable for the call.
            unsafe { *error_message = ERROR.as_ptr().cast() };
        }
        return false;
    }
    if !error_message.is_null() {
        // SAFETY: the optional out parameter is writable for the call.
        unsafe { *error_message = std::ptr::null() };
    }
    true
}

const PROCEDURAL_WIDTH: u32 = 960;
const PROCEDURAL_HEIGHT: u32 = 540;
const EMBEDDED_WIDTH: u32 = 3_840;
const EMBEDDED_HEIGHT: u32 = 2_160;

const EDITORIAL_REFERENCE: &[u8] =
    include_bytes!("../../../apps/screen-desktop/assets/editorial-text-reference.png");
const CAMERA_REFERENCE: &[u8] =
    include_bytes!("../../../apps/screen-desktop/assets/camera-color-reference.png");
const FREQUENCY_REFERENCE: &[u8] =
    include_bytes!("../../../apps/screen-desktop/assets/frequency-moire-reference.png");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_pattern_dimensions(
    pattern: u32,
    width: *mut u32,
    height: *mut u32,
) -> bool {
    if width.is_null() || height.is_null() || pattern > 5 {
        return false;
    }
    let (resolved_width, resolved_height) = if (2..=4).contains(&pattern) {
        (EMBEDDED_WIDTH, EMBEDDED_HEIGHT)
    } else {
        (PROCEDURAL_WIDTH, PROCEDURAL_HEIGHT)
    };
    // SAFETY: both output pointers were validated and belong to the caller.
    unsafe {
        *width = resolved_width;
        *height = resolved_height;
    }
    true
}

/// Renders the exact six test-pattern choices exposed by the current Slint shell.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_pattern_render_rgba32f(
    pattern: u32,
    time_seconds: f64,
    pixels: *mut c_float,
    pixel_count: usize,
    error_message: *mut *const c_char,
) -> bool {
    static INVALID: &[u8] = b"invalid SCREEN test-pattern request\0";
    static DECODE: &[u8] = b"bundled SCREEN test-pattern PNG is invalid\0";
    let mut width = 0;
    let mut height = 0;
    if !unsafe { screen_test_pattern_dimensions(pattern, &mut width, &mut height) }
        || pixels.is_null()
        || pixel_count != width as usize * height as usize
        || !time_seconds.is_finite()
    {
        unsafe { set_error(error_message, INVALID) };
        return false;
    }
    let output = unsafe { std::slice::from_raw_parts_mut(pixels, pixel_count * 4) };
    if let Some(encoded) = match pattern {
        2 => Some(EDITORIAL_REFERENCE),
        3 => Some(CAMERA_REFERENCE),
        4 => Some(FREQUENCY_REFERENCE),
        _ => None,
    } {
        let Ok(decoded) = image::load_from_memory_with_format(encoded, image::ImageFormat::Png)
            .map(image::DynamicImage::into_rgb8)
        else {
            unsafe { set_error(error_message, DECODE) };
            return false;
        };
        if decoded.dimensions() != (width, height) {
            unsafe { set_error(error_message, DECODE) };
            return false;
        }
        for (target, source) in output.chunks_exact_mut(4).zip(decoded.pixels()) {
            target[0] = f32::from(source[0]) / 255.0;
            target[1] = f32::from(source[1]) / 255.0;
            target[2] = f32::from(source[2]) / 255.0;
            target[3] = 1.0;
        }
    } else {
        let procedural = match pattern {
            0 => ProceduralTestPattern::AnimatedCheckerboard,
            1 => ProceduralTestPattern::EyeChart,
            5 => ProceduralTestPattern::PhotometricDeviceScale,
            _ => unreachable!(),
        };
        let time = RationalTime::new((time_seconds * 1_000_000.0).round() as i64, 1_000_000)
            .expect("fixed non-zero time denominator");
        for y in 0..height {
            for x in 0..width {
                let uv = Vec2 {
                    x: x as f32 / (width - 1) as f32,
                    y: y as f32 / (height - 1) as f32,
                };
                let value = diagnostic_signal(procedural, uv, time);
                let offset = (y as usize * width as usize + x as usize) * 4;
                output[offset] = value.r;
                output[offset + 1] = value.g;
                output[offset + 2] = value.b;
                output[offset + 3] = 1.0;
            }
        }
    }
    unsafe { set_error(error_message, b"\0") };
    true
}

unsafe fn set_error(destination: *mut *const c_char, message: &'static [u8]) {
    if !destination.is_null() {
        // SAFETY: the optional out parameter is writable for the call.
        unsafe {
            *destination = if message.len() == 1 {
                std::ptr::null()
            } else {
                message.as_ptr().cast()
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_preserves_every_float_bit() {
        let pipeline = screen_physical_pipeline_create();
        let mut values = [-0.5, 0.0, 1.0, 0.25, 4.0, f32::NAN, f32::INFINITY, 1.0];
        let expected = values.map(f32::to_bits);
        assert!(unsafe {
            screen_physical_pipeline_process_rgba32f(
                pipeline,
                values.as_mut_ptr(),
                values.len() / 4,
                std::ptr::null_mut(),
            )
        });
        assert_eq!(values.map(f32::to_bits), expected);
        unsafe { screen_physical_pipeline_release(pipeline) };
    }

    #[test]
    fn native_pattern_bridge_uses_the_application_pattern_authority() {
        let mut values = vec![0.0; PROCEDURAL_WIDTH as usize * PROCEDURAL_HEIGHT as usize * 4];
        assert!(unsafe {
            screen_test_pattern_render_rgba32f(
                5,
                0.0,
                values.as_mut_ptr(),
                values.len() / 4,
                std::ptr::null_mut(),
            )
        });
        let first = diagnostic_signal(
            ProceduralTestPattern::PhotometricDeviceScale,
            Vec2 { x: 0.0, y: 0.0 },
            RationalTime::new(0, 1).unwrap(),
        );
        let last = diagnostic_signal(
            ProceduralTestPattern::PhotometricDeviceScale,
            Vec2 { x: 1.0, y: 1.0 },
            RationalTime::new(0, 1).unwrap(),
        );
        assert_eq!(&values[..4], &[first.r, first.g, first.b, 1.0]);
        assert_eq!(&values[values.len() - 4..], &[last.r, last.g, last.b, 1.0]);
        for pattern in 2..=4 {
            let (mut width, mut height) = (0, 0);
            assert!(unsafe { screen_test_pattern_dimensions(pattern, &mut width, &mut height) });
            assert_eq!((width, height), (EMBEDDED_WIDTH, EMBEDDED_HEIGHT));
        }
    }

    #[test]
    fn device_catalog_exposes_complete_profiles_through_opaque_handles() {
        assert_eq!(screen_device_preset_count(), 9);
        for index in 0..screen_device_preset_count() {
            let mut parameters = ScreenDeviceParametersV1 {
                abi_version: 0,
                native_width: 0,
                native_height: 0,
                panel_technology: 0,
                stripe_layout: 0,
                active_width_meters: 0.0,
                active_height_meters: 0.0,
                black_matrix_fraction: 0.0,
                eotf_gamma: 0.0,
                black_level_nits: 0.0,
                white_level_nits: 0.0,
                primary_xy: [0.0; 6],
                white_xy: [0.0; 2],
                angular_emission_power: [0.0; 3],
                residual_period_numerator: 0,
                residual_period_denominator: 0,
                residual_amplitude: 0.0,
                residual_phase_numerator: 0,
                residual_phase_denominator: 0,
                banding_period_numerator: 0,
                banding_period_denominator: 0,
                banding_on_numerator: 0,
                banding_on_denominator: 0,
                banding_phase_numerator: 0,
                banding_phase_denominator: 0,
                banding_amount: 0.0,
            };
            assert!(unsafe { screen_device_preset_parameters(index, &mut parameters) });
            assert_eq!(parameters.abi_version, 1);
            let profile =
                unsafe { screen_device_profile_create(&parameters, std::ptr::null_mut()) };
            assert!(!profile.is_null());
            unsafe { screen_device_profile_release(profile) };
        }
    }
}
