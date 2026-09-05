use crate::SourceAcesCgRaster;
use core::fmt;
use screen_color::{ColorEngine, OcioInputTransform};
use screen_media::AlphaInterpretation;

pub const OFX_ORIGIN_SCHEMA_VERSION: u32 = 1;
pub const OFX_INPUT_TRANSFORM_PARAMETER_ID: &str = "input-transform";
pub const OFX_ALPHA_INTERPRETATION_PARAMETER_ID: &str = "alpha-interpretation";
pub const OFX_PREVIEW_PARAMETER_ID: &str = "preview";
pub const OFX_UNSELECTED_INPUT_TRANSFORM_ID: &str = "unselected";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OfxChoiceDescriptor {
    pub id: &'static str,
    pub label: &'static str,
}

pub fn ofx_origin_input_transform_choices() -> Vec<OfxChoiceDescriptor> {
    let mut choices = Vec::with_capacity(OcioInputTransform::ALL.len() + 1);
    choices.push(OfxChoiceDescriptor {
        id: OFX_UNSELECTED_INPUT_TRANSFORM_ID,
        label: "Select Input Transform…",
    });
    choices.extend(
        OcioInputTransform::ALL
            .into_iter()
            .map(|transform| OfxChoiceDescriptor {
                id: transform.stable_id(),
                label: transform.label(),
            }),
    );
    choices
}

pub const OFX_ORIGIN_ALPHA_CHOICES: [OfxChoiceDescriptor; 3] = [
    OfxChoiceDescriptor {
        id: "premultiplied",
        label: "Premultiplied",
    },
    OfxChoiceDescriptor {
        id: "straight",
        label: "Straight",
    },
    OfxChoiceDescriptor {
        id: "ignore",
        label: "Ignore / Opaque",
    },
];

pub const OFX_ORIGIN_PREVIEW_CHOICES: [OfxChoiceDescriptor; 2] = [
    OfxChoiceDescriptor {
        id: "source",
        label: "Source",
    },
    OfxChoiceDescriptor {
        id: "origin",
        label: "Origin",
    },
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OfxOriginPreview {
    Source,
    Origin,
}

impl OfxOriginPreview {
    pub fn from_stable_id(value: &str) -> Option<Self> {
        match value {
            "source" => Some(Self::Source),
            "origin" => Some(Self::Origin),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct OfxOriginEvaluation {
    pub checkpoint: SourceAcesCgRaster,
    pub preview_rgba: Vec<[f32; 4]>,
}

pub fn evaluate_ofx_origin(
    input_transform_id: &str,
    alpha_interpretation_id: &str,
    preview_id: &str,
    width: u32,
    height: u32,
    encoded_rgba: &[[f32; 4]],
) -> Result<OfxOriginEvaluation, OfxOriginError> {
    let input_transform = OcioInputTransform::from_stable_id(input_transform_id)
        .ok_or(OfxOriginError::InputTransformRequired)?;
    let alpha_interpretation = match alpha_interpretation_id {
        "premultiplied" => AlphaInterpretation::Premultiplied,
        "straight" => AlphaInterpretation::Straight,
        "ignore" => AlphaInterpretation::Ignore,
        _ => return Err(OfxOriginError::UnknownAlphaInterpretation),
    };
    let preview =
        OfxOriginPreview::from_stable_id(preview_id).ok_or(OfxOriginError::UnknownPreview)?;
    let expected = usize::try_from(width)
        .ok()
        .and_then(|width| {
            usize::try_from(height)
                .ok()
                .and_then(|height| width.checked_mul(height))
        })
        .ok_or(OfxOriginError::InvalidRaster)?;
    if width == 0 || height == 0 || encoded_rgba.len() != expected {
        return Err(OfxOriginError::InvalidRaster);
    }

    let mut checkpoint_rgba = Vec::with_capacity(encoded_rgba.len());
    for pixel in encoded_rgba {
        if !pixel.iter().all(|value| value.is_finite()) || !(0.0..=1.0).contains(&pixel[3]) {
            return Err(OfxOriginError::InvalidPixel);
        }
        let resolved = match alpha_interpretation {
            AlphaInterpretation::Premultiplied if pixel[3] == 0.0 => [0.0, 0.0, 0.0, 0.0],
            AlphaInterpretation::Premultiplied => [
                pixel[0] / pixel[3],
                pixel[1] / pixel[3],
                pixel[2] / pixel[3],
                pixel[3],
            ],
            AlphaInterpretation::Straight => *pixel,
            AlphaInterpretation::Ignore => [pixel[0], pixel[1], pixel[2], 1.0],
            AlphaInterpretation::Auto => unreachable!("OFX never accepts unresolved alpha"),
        };
        checkpoint_rgba.push(resolved);
    }

    let engine = ColorEngine::bundled().map_err(|_| OfxOriginError::ColorTransformFailed)?;
    let to_acescg = engine
        .source_to_acescg_processor(input_transform)
        .map_err(|_| OfxOriginError::ColorTransformFailed)?;
    to_acescg
        .apply_rgba_buffer(checkpoint_rgba.as_flattened_mut())
        .map_err(|_| OfxOriginError::ColorTransformFailed)?;
    if !checkpoint_rgba
        .iter()
        .flat_map(|pixel| pixel.iter())
        .all(|value| value.is_finite())
    {
        return Err(OfxOriginError::NonFiniteColorResult);
    }

    let checkpoint = SourceAcesCgRaster {
        width,
        height,
        rgba: checkpoint_rgba,
    };
    let preview_rgba = match preview {
        OfxOriginPreview::Source => encoded_rgba.to_vec(),
        OfxOriginPreview::Origin => {
            let mut output = checkpoint.rgba.clone();
            let from_acescg = engine
                .acescg_to_source_processor(input_transform)
                .map_err(|_| OfxOriginError::ColorTransformFailed)?;
            from_acescg
                .apply_rgba_buffer(output.as_flattened_mut())
                .map_err(|_| OfxOriginError::ColorTransformFailed)?;
            for pixel in &mut output {
                match alpha_interpretation {
                    AlphaInterpretation::Premultiplied => {
                        pixel[0] *= pixel[3];
                        pixel[1] *= pixel[3];
                        pixel[2] *= pixel[3];
                    }
                    AlphaInterpretation::Straight => {}
                    AlphaInterpretation::Ignore => pixel[3] = 1.0,
                    AlphaInterpretation::Auto => {
                        unreachable!("OFX never accepts unresolved alpha")
                    }
                }
            }
            output
        }
    };
    if !preview_rgba
        .iter()
        .flat_map(|pixel| pixel.iter())
        .all(|value| value.is_finite())
    {
        return Err(OfxOriginError::NonFiniteColorResult);
    }
    Ok(OfxOriginEvaluation {
        checkpoint,
        preview_rgba,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OfxOriginError {
    InputTransformRequired,
    UnknownAlphaInterpretation,
    UnknownPreview,
    InvalidRaster,
    InvalidPixel,
    ColorTransformFailed,
    NonFiniteColorResult,
}

impl fmt::Display for OfxOriginError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InputTransformRequired => "Input Transform must be selected",
            Self::UnknownAlphaInterpretation => "alpha interpretation is unknown",
            Self::UnknownPreview => "Preview selection is unknown",
            Self::InvalidRaster => "Origin raster is invalid",
            Self::InvalidPixel => "Origin input contains invalid pixels or alpha",
            Self::ColorTransformFailed => "Origin OCIO transform failed",
            Self::NonFiniteColorResult => "Origin OCIO transform produced non-finite values",
        })
    }
}

impl std::error::Error for OfxOriginError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn evaluate(alpha: &str, preview: &str, pixels: &[[f32; 4]]) -> OfxOriginEvaluation {
        evaluate_ofx_origin("acescg", alpha, preview, pixels.len() as u32, 1, pixels)
            .expect("Origin evaluation")
    }

    #[test]
    fn source_preview_is_exact_while_origin_checkpoint_is_typed() {
        let input = [[-0.2, 0.18, 4.0, 0.5], [0.3, 0.4, 0.5, 1.0]];
        let result = evaluate("straight", "source", &input);
        assert_eq!(result.preview_rgba, input);
        assert_eq!(result.checkpoint.width, 2);
        assert_eq!(result.checkpoint.height, 1);
        assert_eq!(result.checkpoint.rgba, input);
    }

    #[test]
    fn premultiplied_origin_unassociates_and_reassociates_once() {
        let input = [[0.1, 0.2, 0.4, 0.5], [0.0, 0.0, 0.0, 0.0]];
        let result = evaluate("premultiplied", "origin", &input);
        assert_eq!(result.checkpoint.rgba[0], [0.2, 0.4, 0.8, 0.5]);
        assert_eq!(result.checkpoint.rgba[1], [0.0, 0.0, 0.0, 0.0]);
        assert_eq!(result.preview_rgba, input);
    }

    #[test]
    fn straight_origin_preserves_independent_rgb_below_zero_alpha() {
        let input = [[0.7, -0.2, 3.0, 0.0]];
        let result = evaluate("straight", "origin", &input);
        assert_eq!(result.checkpoint.rgba, input);
        assert_eq!(result.preview_rgba, input);
    }

    #[test]
    fn ignore_origin_publishes_opaque_alpha() {
        let input = [[0.1, 0.2, 0.3, 0.25]];
        let result = evaluate("ignore", "origin", &input);
        assert_eq!(result.checkpoint.rgba[0][3], 1.0);
        assert_eq!(result.preview_rgba[0][3], 1.0);
    }

    #[test]
    fn resolve_acescct_working_space_round_trips_through_origin() {
        let input = [[0.42, 0.37, 0.51, 1.0], [0.18, 0.22, 0.31, 0.5]];
        let result = evaluate_ofx_origin("acescct", "straight", "origin", 2, 1, &input)
            .expect("Resolve ACEScct Origin evaluation");
        assert_ne!(result.checkpoint.rgba, input);
        for (actual, expected) in result
            .preview_rgba
            .iter()
            .flatten()
            .zip(input.iter().flatten())
        {
            assert!((actual - expected).abs() <= 2.0e-5);
        }
    }

    #[test]
    fn origin_requires_an_explicit_transform_and_bounded_alpha() {
        assert_eq!(
            evaluate_ofx_origin("unselected", "straight", "origin", 1, 1, &[[0.0; 4]]),
            Err(OfxOriginError::InputTransformRequired)
        );
        assert_eq!(
            evaluate_ofx_origin(
                "acescg",
                "straight",
                "origin",
                1,
                1,
                &[[0.0, 0.0, 0.0, 1.1]]
            ),
            Err(OfxOriginError::InvalidPixel)
        );
    }
}
