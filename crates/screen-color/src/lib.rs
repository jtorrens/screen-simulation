//! Explicit color interpretation and OpenColorIO ownership.

#![forbid(unsafe_code)]

use screen_contracts::{DeviceRgb, LinearRgb};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceColorInterpretation {
    IdentityDeviceSignal,
}

pub fn source_to_device(interpretation: SourceColorInterpretation, rgb: [f32; 3]) -> DeviceRgb {
    match interpretation {
        SourceColorInterpretation::IdentityDeviceSignal => DeviceRgb::new(rgb[0], rgb[1], rgb[2]),
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreviewRgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DiagnosticDisplayTransform {
    pub reference_white_nits: f32,
}

impl DiagnosticDisplayTransform {
    pub fn scene_linear_to_srgb(self, radiance_nits: LinearRgb) -> PreviewRgb {
        let encode = |value: f32| {
            let normalized = (value / self.reference_white_nits).max(0.0);
            let tone_mapped = normalized / (1.0 + normalized);
            if tone_mapped <= 0.003_130_8 {
                tone_mapped * 12.92
            } else {
                1.055 * tone_mapped.powf(1.0 / 2.4) - 0.055
            }
        };
        PreviewRgb {
            r: encode(radiance_nits.r),
            g: encode(radiance_nits.g),
            b: encode(radiance_nits.b),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostic_display_transform_is_monotonic_and_bounded() {
        let transform = DiagnosticDisplayTransform {
            reference_white_nits: 100.0,
        };
        let dim = transform.scene_linear_to_srgb(LinearRgb::new(10.0, 10.0, 10.0));
        let bright = transform.scene_linear_to_srgb(LinearRgb::new(1_000.0, 1_000.0, 1_000.0));
        assert!(bright.r > dim.r);
        assert!(bright.r < 1.0);
    }

    #[test]
    fn identity_device_interpretation_preserves_code_values() {
        assert_eq!(
            source_to_device(
                SourceColorInterpretation::IdentityDeviceSignal,
                [-0.1, 0.5, 1.2]
            ),
            DeviceRgb::new(-0.1, 0.5, 1.2)
        );
    }
}
