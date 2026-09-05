use screen_application::{
    OFX_ORIGIN_ALPHA_CHOICES, OFX_ORIGIN_PREVIEW_CHOICES, OFX_ORIGIN_SCHEMA_VERSION,
    OfxChoiceDescriptor, OfxOriginError, evaluate_ofx_origin, ofx_origin_input_transform_choices,
};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenOfxStringView {
    pub data: *const u8,
    pub length: usize,
}

impl ScreenOfxStringView {
    const EMPTY: Self = Self {
        data: std::ptr::null(),
        length: 0,
    };

    fn from_str(value: &'static str) -> Self {
        Self {
            data: value.as_ptr(),
            length: value.len(),
        }
    }
}

#[repr(u32)]
#[derive(Clone, Copy)]
enum BridgeStatus {
    Ok = 0,
    InvalidArgument = 1,
    InputTransformRequired = 2,
    UnknownAlphaInterpretation = 3,
    UnknownPreview = 4,
    InvalidRaster = 5,
    InvalidPixel = 6,
    ColorTransformFailed = 7,
    NonFiniteColorResult = 8,
    Panic = 9,
}

impl From<OfxOriginError> for BridgeStatus {
    fn from(value: OfxOriginError) -> Self {
        match value {
            OfxOriginError::InputTransformRequired => Self::InputTransformRequired,
            OfxOriginError::UnknownAlphaInterpretation => Self::UnknownAlphaInterpretation,
            OfxOriginError::UnknownPreview => Self::UnknownPreview,
            OfxOriginError::InvalidRaster => Self::InvalidRaster,
            OfxOriginError::InvalidPixel => Self::InvalidPixel,
            OfxOriginError::ColorTransformFailed => Self::ColorTransformFailed,
            OfxOriginError::NonFiniteColorResult => Self::NonFiniteColorResult,
        }
    }
}

fn descriptor_at(
    descriptors: &[OfxChoiceDescriptor],
    index: usize,
    label: bool,
) -> ScreenOfxStringView {
    descriptors
        .get(index)
        .map(|descriptor| {
            ScreenOfxStringView::from_str(if label {
                descriptor.label
            } else {
                descriptor.id
            })
        })
        .unwrap_or(ScreenOfxStringView::EMPTY)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_schema_version() -> u32 {
    OFX_ORIGIN_SCHEMA_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_input_transform_count() -> usize {
    ofx_origin_input_transform_choices().len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_input_transform_id(index: usize) -> ScreenOfxStringView {
    descriptor_at(&ofx_origin_input_transform_choices(), index, false)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_input_transform_label(index: usize) -> ScreenOfxStringView {
    descriptor_at(&ofx_origin_input_transform_choices(), index, true)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_alpha_count() -> usize {
    OFX_ORIGIN_ALPHA_CHOICES.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_alpha_id(index: usize) -> ScreenOfxStringView {
    descriptor_at(&OFX_ORIGIN_ALPHA_CHOICES, index, false)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_alpha_label(index: usize) -> ScreenOfxStringView {
    descriptor_at(&OFX_ORIGIN_ALPHA_CHOICES, index, true)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_preview_count() -> usize {
    OFX_ORIGIN_PREVIEW_CHOICES.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_preview_id(index: usize) -> ScreenOfxStringView {
    descriptor_at(&OFX_ORIGIN_PREVIEW_CHOICES, index, false)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_preview_label(index: usize) -> ScreenOfxStringView {
    descriptor_at(&OFX_ORIGIN_PREVIEW_CHOICES, index, true)
}

unsafe fn required_utf8<'a>(value: *const c_char) -> Result<&'a str, BridgeStatus> {
    if value.is_null() {
        return Err(BridgeStatus::InvalidArgument);
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| BridgeStatus::InvalidArgument)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_ofx_origin_process_rgba32f(
    input_transform_id: *const c_char,
    alpha_interpretation_id: *const c_char,
    preview_id: *const c_char,
    width: u32,
    height: u32,
    input_rgba: *const f32,
    output_rgba: *mut f32,
) -> u32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let pixel_count = usize::try_from(width)
            .ok()
            .and_then(|width| {
                usize::try_from(height)
                    .ok()
                    .and_then(|height| width.checked_mul(height))
            })
            .ok_or(BridgeStatus::InvalidRaster)?;
        if pixel_count == 0 || input_rgba.is_null() || output_rgba.is_null() {
            return Err(BridgeStatus::InvalidArgument);
        }
        let input_transform_id = unsafe { required_utf8(input_transform_id) }?;
        let alpha_interpretation_id = unsafe { required_utf8(alpha_interpretation_id) }?;
        let preview_id = unsafe { required_utf8(preview_id) }?;
        let input =
            unsafe { std::slice::from_raw_parts(input_rgba.cast::<[f32; 4]>(), pixel_count) };
        let result = evaluate_ofx_origin(
            input_transform_id,
            alpha_interpretation_id,
            preview_id,
            width,
            height,
            input,
        )
        .map_err(BridgeStatus::from)?;
        let output =
            unsafe { std::slice::from_raw_parts_mut(output_rgba.cast::<[f32; 4]>(), pixel_count) };
        output.copy_from_slice(&result.preview_rgba);
        Ok::<(), BridgeStatus>(())
    }));
    match result {
        Ok(Ok(())) => BridgeStatus::Ok as u32,
        Ok(Err(status)) => status as u32,
        Err(_) => BridgeStatus::Panic as u32,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_ofx_origin_error_message(status: u32) -> ScreenOfxStringView {
    ScreenOfxStringView::from_str(match status {
        0 => "ok",
        1 => "invalid Origin bridge argument",
        2 => "Input Transform must be selected",
        3 => "unknown alpha interpretation",
        4 => "unknown Preview selection",
        5 => "invalid Origin raster",
        6 => "invalid Origin pixel or alpha",
        7 => "OCIO Origin transform failed",
        8 => "OCIO Origin transform produced non-finite values",
        _ => "Origin bridge panicked",
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn view(value: ScreenOfxStringView) -> String {
        assert!(!value.data.is_null());
        String::from_utf8(unsafe { std::slice::from_raw_parts(value.data, value.length) }.to_vec())
            .expect("UTF-8 descriptor")
    }

    #[test]
    fn bridge_publishes_application_owned_stable_choices() {
        assert_eq!(screen_ofx_origin_schema_version(), 1);
        assert_eq!(view(screen_ofx_origin_input_transform_id(0)), "unselected");
        assert!(screen_ofx_origin_input_transform_count() > 2);
        assert_eq!(view(screen_ofx_origin_alpha_id(0)), "premultiplied");
        assert_eq!(view(screen_ofx_origin_preview_id(1)), "origin");
    }

    #[test]
    fn bridge_processes_origin_without_redeclaring_color_semantics() {
        let transform = CString::new("acescg").unwrap();
        let alpha = CString::new("straight").unwrap();
        let preview = CString::new("origin").unwrap();
        let input = [-0.2, 0.18, 4.0, 0.5];
        let mut output = [0.0; 4];
        let status = unsafe {
            screen_ofx_origin_process_rgba32f(
                transform.as_ptr(),
                alpha.as_ptr(),
                preview.as_ptr(),
                1,
                1,
                input.as_ptr(),
                output.as_mut_ptr(),
            )
        };
        assert_eq!(
            status,
            0,
            "{}",
            view(screen_ofx_origin_error_message(status))
        );
        assert_eq!(output, input);
    }
}
