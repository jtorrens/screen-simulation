//! Coarse stable C ABI for the native shell's future Rust physical engine.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, c_float};

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
}
