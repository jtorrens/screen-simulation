//! Coarse stable C ABI for the native shell's future Rust physical engine.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, c_float};

use screen_application::{ProceduralTestPattern, diagnostic_signal};
use screen_contracts::{RationalTime, Vec2};

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
}
