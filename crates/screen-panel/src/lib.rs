//! Device signal, procedural fixed-pixel LCD, and emitted-radiance ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{DeviceRgb, LinearRgb, Meters};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StripeLayout {
    Rgb,
    Bgr,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubpixelEmission {
    pub stripes: [LinearRgb; 3],
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LcdProfile {
    pub native_width: u32,
    pub native_height: u32,
    pub active_width: Meters,
    pub active_height: Meters,
    pub stripe_layout: StripeLayout,
    pub black_matrix_fraction: f32,
    pub eotf_gamma: f32,
    pub black_level_nits: f32,
    pub white_level_nits: f32,
    pub channel_efficiency: LinearRgb,
}

impl LcdProfile {
    pub fn validate(self) -> Result<Self, PanelError> {
        if self.native_width == 0 || self.native_height == 0 {
            return Err(PanelError::EmptyNativeRaster);
        }
        if self.active_width.0 <= 0.0 || self.active_height.0 <= 0.0 {
            return Err(PanelError::NonPositiveActiveArea);
        }
        if !(0.0..1.0).contains(&self.black_matrix_fraction) {
            return Err(PanelError::InvalidBlackMatrix);
        }
        if self.eotf_gamma <= 0.0 {
            return Err(PanelError::InvalidEotf);
        }
        if self.black_level_nits < 0.0 || self.white_level_nits <= self.black_level_nits {
            return Err(PanelError::InvalidLuminanceRange);
        }
        if [
            self.channel_efficiency.r,
            self.channel_efficiency.g,
            self.channel_efficiency.b,
        ]
        .into_iter()
        .any(|value| value <= 0.0)
        {
            return Err(PanelError::InvalidChannelEfficiency);
        }
        Ok(self)
    }

    pub fn pixels_per_inch(self) -> f32 {
        let diagonal_pixels =
            (self.native_width.pow(2) as f32 + self.native_height.pow(2) as f32).sqrt();
        let width_inches = self.active_width.0 / 0.0254;
        let height_inches = self.active_height.0 / 0.0254;
        diagonal_pixels / width_inches.hypot(height_inches)
    }

    pub fn pixel_pitch_meters(self) -> f32 {
        self.active_width.0 / self.native_width as f32
    }

    pub fn emitted_radiance(self, signal: DeviceRgb) -> LinearRgb {
        let span = self.white_level_nits - self.black_level_nits;
        let channel = |value: f32, efficiency: f32| {
            (self.black_level_nits + span * value.max(0.0).powf(self.eotf_gamma)) * efficiency
        };
        LinearRgb::new(
            channel(signal.r, self.channel_efficiency.r),
            channel(signal.g, self.channel_efficiency.g),
            channel(signal.b, self.channel_efficiency.b),
        )
    }

    pub fn subpixel_emission(self, signal: DeviceRgb) -> SubpixelEmission {
        let emission = self.emitted_radiance(signal);
        let visible_area = (1.0 - self.black_matrix_fraction).powi(2);
        let stripe_compensation = 3.0 / visible_area;
        let red = LinearRgb::new(emission.r * stripe_compensation, 0.0, 0.0);
        let green = LinearRgb::new(0.0, emission.g * stripe_compensation, 0.0);
        let blue = LinearRgb::new(0.0, 0.0, emission.b * stripe_compensation);
        SubpixelEmission {
            stripes: match self.stripe_layout {
                StripeLayout::Rgb => [red, green, blue],
                StripeLayout::Bgr => [blue, green, red],
            },
        }
    }

    pub fn emission_at_pixel(
        self,
        signal: DeviceRgb,
        pixel_uv: screen_contracts::Vec2,
    ) -> LinearRgb {
        let margin = self.black_matrix_fraction * 0.5;
        if pixel_uv.x < margin
            || pixel_uv.x > 1.0 - margin
            || pixel_uv.y < margin
            || pixel_uv.y > 1.0 - margin
        {
            return LinearRgb::new(0.0, 0.0, 0.0);
        }
        let stripe_position = ((pixel_uv.x - margin) / (1.0 - 2.0 * margin) * 3.0)
            .floor()
            .clamp(0.0, 2.0) as usize;
        self.subpixel_emission(signal).stripes[stripe_position]
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelError {
    EmptyNativeRaster,
    NonPositiveActiveArea,
    InvalidBlackMatrix,
    InvalidEotf,
    InvalidLuminanceRange,
    InvalidChannelEfficiency,
}

impl fmt::Display for PanelError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::EmptyNativeRaster => "LCD native raster must be non-empty",
            Self::NonPositiveActiveArea => "LCD active dimensions must be positive",
            Self::InvalidBlackMatrix => "black matrix fraction must be in [0, 1)",
            Self::InvalidEotf => "LCD EOTF gamma must be positive",
            Self::InvalidLuminanceRange => {
                "LCD white level must be greater than a non-negative black level"
            }
            Self::InvalidChannelEfficiency => "LCD channel efficiencies must be positive",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for PanelError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile() -> LcdProfile {
        LcdProfile {
            native_width: 3840,
            native_height: 2160,
            active_width: Meters(0.596_736),
            active_height: Meters(0.335_664),
            stripe_layout: StripeLayout::Rgb,
            black_matrix_fraction: 0.12,
            eotf_gamma: 2.2,
            black_level_nits: 0.08,
            white_level_nits: 600.0,
            channel_efficiency: LinearRgb::new(1.0, 0.96, 0.9),
        }
    }

    #[test]
    fn derives_pitch_and_ppi_from_physical_profile() {
        let profile = profile().validate().expect("valid panel");
        assert!((profile.pixel_pitch_meters() - 0.000_155_4).abs() < 0.000_000_1);
        assert!((profile.pixels_per_inch() - 163.5).abs() < 0.2);
    }

    #[test]
    fn eotf_preserves_values_above_one() {
        let emission = profile().emitted_radiance(DeviceRgb::new(1.2, 0.5, 0.0));
        assert!(emission.r > profile().white_level_nits);
        assert!(emission.g > profile().black_level_nits);
        assert_eq!(emission.b, profile().black_level_nits * 0.9);
    }

    #[test]
    fn bgr_profile_changes_physical_stripe_order() {
        let mut bgr = profile();
        bgr.stripe_layout = StripeLayout::Bgr;
        let stripes = bgr.subpixel_emission(DeviceRgb::WHITE).stripes;
        assert!(stripes[0].b > 0.0);
        assert!(stripes[1].g > 0.0);
        assert!(stripes[2].r > 0.0);
    }

    #[test]
    fn black_matrix_emits_no_light() {
        let emission = profile()
            .emission_at_pixel(DeviceRgb::WHITE, screen_contracts::Vec2 { x: 0.01, y: 0.5 });
        assert_eq!(emission, LinearRgb::new(0.0, 0.0, 0.0));
    }
}
