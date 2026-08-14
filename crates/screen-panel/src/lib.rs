//! Device signal, procedural fixed-pixel LCD, and emitted-radiance ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{ContractError, DeviceRgb, LinearRgb, Meters, RationalTime};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StripeLayout {
    Rgb,
    Bgr,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelTechnology {
    IpsLcd,
}

/// A panel-owned interpretation of already encoded feeder RGB codes.
///
/// Stable identifiers may intentionally match Color-owned Output Signal
/// identifiers, but the two catalogs remain independent semantic owners.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelColorMode {
    Srgb,
    Rec709Gamma22,
    Rec709Gamma24,
}

impl PanelColorMode {
    pub const ALL: [Self; 3] = [Self::Srgb, Self::Rec709Gamma22, Self::Rec709Gamma24];

    pub const fn stable_id(self) -> &'static str {
        match self {
            Self::Srgb => "srgb",
            Self::Rec709Gamma22 => "rec709-gamma22",
            Self::Rec709Gamma24 => "rec709-gamma24",
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::Srgb => "sRGB",
            Self::Rec709Gamma22 => "Rec.709 · Gamma 2.2",
            Self::Rec709Gamma24 => "Rec.709 · Gamma 2.4",
        }
    }

    pub const fn eotf_gamma(self) -> f32 {
        match self {
            Self::Srgb | Self::Rec709Gamma22 => 2.2,
            Self::Rec709Gamma24 => 2.4,
        }
    }

    pub fn from_stable_id(id: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|candidate| candidate.stable_id() == id)
    }
}

/// Precision policy for the orthographic panel surface. Every level covers the
/// same complete active area; only the sample lattice changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum FlatPanelQuality {
    Draft = 0,
    Medium = 1,
    High = 2,
    Native = 3,
}

impl TryFrom<u32> for FlatPanelQuality {
    type Error = ();

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Draft),
            1 => Ok(Self::Medium),
            2 => Ok(Self::High),
            3 => Ok(Self::Native),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlatPanelGeometry {
    pub native_width: u32,
    pub native_height: u32,
    pub active_width_meters: f32,
    pub active_height_meters: f32,
    pub pitch_x_meters: f32,
    pub pitch_y_meters: f32,
    pub pixels_per_inch: f32,
    pub stripe_layout: StripeLayout,
    pub black_matrix_fraction: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FlatPanelSampling {
    pub effective_width: u32,
    pub effective_height: u32,
    pub samples_per_output_pixel: u32,
    pub subpixel_geometry_resolved: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Chromaticity {
    pub x: f32,
    pub y: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelColorimetry {
    pub red: Chromaticity,
    pub green: Chromaticity,
    pub blue: Chromaticity,
    pub white: Chromaticity,
}

impl PanelColorimetry {
    pub const SRGB_D65: Self = Self {
        red: Chromaticity {
            x: 0.6400,
            y: 0.3300,
        },
        green: Chromaticity {
            x: 0.3000,
            y: 0.6000,
        },
        blue: Chromaticity {
            x: 0.1500,
            y: 0.0600,
        },
        white: Chromaticity {
            x: 0.3127,
            y: 0.3290,
        },
    };
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
    pub colorimetry: PanelColorimetry,
    pub angular_emission_power: LinearRgb,
    pub temporal_emission: PanelTemporalEmission,
}

/// Energy-conserving lateral transport at the emitted panel plane.
///
/// Radii are physical micrometers, never output-raster pixels. Core and tail
/// weights are the total energy assigned to four deterministic samples on
/// each ring; the remainder stays at the emitter position.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelLightSpreadProfile {
    pub character_strength: f32,
    pub core_radius_micrometers: LinearRgb,
    pub core_weight: LinearRgb,
    pub tail_radius_micrometers: LinearRgb,
    pub tail_weight: LinearRgb,
}

/// Fixed manufacturing and compensation residuals at the emitted panel plane.
/// Spatial scales are physical millimetres and the seed is authored data, so
/// the field remains attached to the device independently of camera and time.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelUniformityProfile {
    /// Zero is exact identity, one is the calibrated preset and values above
    /// one extrapolate the same fixed field without changing its frequencies.
    pub character_strength: f32,
    pub seed: u32,
    pub broad_luminance_peak_to_peak: f32,
    pub mid_luminance_peak_to_peak: f32,
    pub fine_luminance_peak_to_peak: f32,
    pub chromatic_peak_to_peak: f32,
    pub mid_scale_millimeters: f32,
    pub fine_scale_millimeters: f32,
    pub low_drive_emphasis: f32,
}

impl PanelUniformityProfile {
    pub const PROFESSIONAL_COMPENSATED: Self = Self {
        character_strength: 1.0,
        seed: 0x329C_2026,
        broad_luminance_peak_to_peak: 0.025,
        mid_luminance_peak_to_peak: 0.012,
        fine_luminance_peak_to_peak: 0.006,
        chromatic_peak_to_peak: 0.004,
        mid_scale_millimeters: 32.0,
        fine_scale_millimeters: 1.5,
        low_drive_emphasis: 0.40,
    };

    pub const DESKTOP_LCD: Self = Self {
        character_strength: 1.0,
        seed: 0xD35C_7001,
        broad_luminance_peak_to_peak: 0.050,
        mid_luminance_peak_to_peak: 0.025,
        fine_luminance_peak_to_peak: 0.010,
        chromatic_peak_to_peak: 0.007,
        mid_scale_millimeters: 24.0,
        fine_scale_millimeters: 1.2,
        low_drive_emphasis: 0.55,
    };

    pub const MOBILE_LCD: Self = Self {
        character_strength: 1.0,
        seed: 0xA10B_11E5,
        broad_luminance_peak_to_peak: 0.030,
        mid_luminance_peak_to_peak: 0.015,
        fine_luminance_peak_to_peak: 0.008,
        chromatic_peak_to_peak: 0.005,
        mid_scale_millimeters: 12.0,
        fine_scale_millimeters: 0.8,
        low_drive_emphasis: 0.45,
    };

    pub const TELEVISION_LCD: Self = Self {
        character_strength: 1.0,
        seed: 0x7E1E_5150,
        broad_luminance_peak_to_peak: 0.080,
        mid_luminance_peak_to_peak: 0.040,
        fine_luminance_peak_to_peak: 0.012,
        chromatic_peak_to_peak: 0.010,
        mid_scale_millimeters: 48.0,
        fine_scale_millimeters: 2.0,
        low_drive_emphasis: 0.65,
    };

    pub fn validate(self) -> Result<Self, PanelError> {
        let amplitudes = [
            self.broad_luminance_peak_to_peak,
            self.mid_luminance_peak_to_peak,
            self.fine_luminance_peak_to_peak,
            self.chromatic_peak_to_peak,
        ];
        if !self.character_strength.is_finite()
            || !(0.0..=4.0).contains(&self.character_strength)
            || amplitudes
                .into_iter()
                .any(|value| !value.is_finite() || !(0.0..=0.25).contains(&value))
            || !self.mid_scale_millimeters.is_finite()
            || self.mid_scale_millimeters <= 0.0
            || !self.fine_scale_millimeters.is_finite()
            || self.fine_scale_millimeters <= 0.0
            || self.fine_scale_millimeters >= self.mid_scale_millimeters
            || !self.low_drive_emphasis.is_finite()
            || !(0.0..=1.0).contains(&self.low_drive_emphasis)
            || amplitudes.into_iter().sum::<f32>() * (1.0 + self.low_drive_emphasis) * 4.0 >= 0.95
        {
            return Err(PanelError::InvalidUniformity);
        }
        Ok(self)
    }

    pub fn channel_gains(
        self,
        panel: LcdProfile,
        device_minimum: screen_contracts::Vec2,
        device_maximum: screen_contracts::Vec2,
        signal: DeviceRgb,
    ) -> LinearRgb {
        if self.character_strength == 0.0 {
            return LinearRgb::new(1.0, 1.0, 1.0);
        }
        let center = screen_contracts::Vec2 {
            x: (device_minimum.x + device_maximum.x) * 0.5 / panel.native_width as f32,
            y: (device_minimum.y + device_maximum.y) * 0.5 / panel.native_height as f32,
        };
        let footprint_millimeters = screen_contracts::Vec2 {
            x: (device_maximum.x - device_minimum.x).abs() / panel.native_width as f32
                * panel.active_width.0
                * 1_000.0,
            y: (device_maximum.y - device_minimum.y).abs() / panel.native_height as f32
                * panel.active_height.0
                * 1_000.0,
        };
        let broad = broad_uniformity(center);
        let mid = filtered_antisymmetric_noise(
            center,
            footprint_millimeters,
            panel,
            self.mid_scale_millimeters,
            self.seed,
        );
        let fine = filtered_antisymmetric_noise(
            center,
            footprint_millimeters,
            panel,
            self.fine_scale_millimeters,
            self.seed ^ 0x9E37_79B9,
        );
        let luminance = self.broad_luminance_peak_to_peak * broad
            + self.mid_luminance_peak_to_peak * mid
            + self.fine_luminance_peak_to_peak * fine;
        let chroma = self.chromatic_peak_to_peak;
        let opponent = [
            chroma * (0.5 * mid - 0.25 * fine),
            chroma * (-0.5 * mid - 0.25 * fine),
            chroma * 0.5 * fine,
        ];
        let codes = [signal.r, signal.g, signal.b];
        let mut gains = [1.0_f32; 3];
        for channel in 0..3 {
            let drive = codes[channel].abs().clamp(0.0, 1.0);
            let drive_scale = 1.0 + self.low_drive_emphasis * (1.0 - drive).powi(2);
            gains[channel] =
                1.0 + self.character_strength * drive_scale * (luminance + opponent[channel]);
        }
        LinearRgb::new(gains[0], gains[1], gains[2])
    }
}

fn broad_uniformity(uv: screen_contracts::Vec2) -> f32 {
    let x = uv.x.clamp(0.0, 1.0) - 0.5;
    let y = uv.y.clamp(0.0, 1.0) - 0.5;
    2.0 * (1.0 / 6.0 - x * x - y * y)
}

fn hash_uniformity(mut value: u32) -> f32 {
    value ^= value >> 16;
    value = value.wrapping_mul(0x7FEB_352D);
    value ^= value >> 15;
    value = value.wrapping_mul(0x846C_A68B);
    value ^= value >> 16;
    value as f32 / u32::MAX as f32
}

fn lattice_noise(x: i32, y: i32, seed: u32) -> f32 {
    let key = (x as u32).wrapping_mul(0x1F12_3BB5) ^ (y as u32).wrapping_mul(0x5F35_6495) ^ seed;
    hash_uniformity(key) * 2.0 - 1.0
}

fn smooth_noise(x: f32, y: f32, seed: u32) -> f32 {
    let ix = x.floor() as i32;
    let iy = y.floor() as i32;
    let fx = x - ix as f32;
    let fy = y - iy as f32;
    let sx = fx * fx * (3.0 - 2.0 * fx);
    let sy = fy * fy * (3.0 - 2.0 * fy);
    let a = lattice_noise(ix, iy, seed);
    let b = lattice_noise(ix + 1, iy, seed);
    let c = lattice_noise(ix, iy + 1, seed);
    let d = lattice_noise(ix + 1, iy + 1, seed);
    (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
}

fn filtered_antisymmetric_noise(
    uv: screen_contracts::Vec2,
    footprint_millimeters: screen_contracts::Vec2,
    panel: LcdProfile,
    scale_millimeters: f32,
    seed: u32,
) -> f32 {
    let width_millimeters = panel.active_width.0 * 1_000.0;
    let height_millimeters = panel.active_height.0 * 1_000.0;
    let x = uv.x * width_millimeters / scale_millimeters;
    let y = uv.y * height_millimeters / scale_millimeters;
    let mirror_x = (1.0 - uv.x) * width_millimeters / scale_millimeters;
    let mirror_y = (1.0 - uv.y) * height_millimeters / scale_millimeters;
    let footprint = footprint_millimeters.x.max(footprint_millimeters.y);
    let attenuation = 1.0 / (1.0 + (footprint / scale_millimeters).powi(2));
    (smooth_noise(x, y, seed) - smooth_noise(mirror_x, mirror_y, seed)) * 0.5 * attenuation
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelLightSpreadSample {
    pub offset_meters: screen_contracts::Vec2,
    pub weight: f32,
}

impl PanelLightSpreadProfile {
    pub const LCD_MOBILE: Self = Self {
        character_strength: 1.0,
        core_radius_micrometers: LinearRgb::new(12.0, 10.0, 14.0),
        core_weight: LinearRgb::new(0.20, 0.18, 0.22),
        tail_radius_micrometers: LinearRgb::new(48.0, 42.0, 54.0),
        tail_weight: LinearRgb::new(0.035, 0.030, 0.040),
    };

    pub const LCD_DESKTOP: Self = Self {
        character_strength: 1.0,
        core_radius_micrometers: LinearRgb::new(22.0, 18.0, 25.0),
        core_weight: LinearRgb::new(0.22, 0.20, 0.24),
        tail_radius_micrometers: LinearRgb::new(90.0, 78.0, 102.0),
        tail_weight: LinearRgb::new(0.040, 0.035, 0.045),
    };

    pub const LCD_TV: Self = Self {
        character_strength: 1.0,
        core_radius_micrometers: LinearRgb::new(35.0, 30.0, 40.0),
        core_weight: LinearRgb::new(0.24, 0.22, 0.26),
        tail_radius_micrometers: LinearRgb::new(150.0, 130.0, 170.0),
        tail_weight: LinearRgb::new(0.045, 0.040, 0.050),
    };

    pub const OLED_CONTAINED: Self = Self {
        character_strength: 1.0,
        core_radius_micrometers: LinearRgb::new(5.0, 4.0, 6.0),
        core_weight: LinearRgb::new(0.08, 0.07, 0.09),
        tail_radius_micrometers: LinearRgb::new(18.0, 16.0, 20.0),
        tail_weight: LinearRgb::new(0.010, 0.008, 0.012),
    };

    pub const MICRO_LED_CONTAINED: Self = Self {
        character_strength: 1.0,
        core_radius_micrometers: LinearRgb::new(2.0, 2.0, 2.5),
        core_weight: LinearRgb::new(0.04, 0.04, 0.05),
        tail_radius_micrometers: LinearRgb::new(8.0, 7.0, 9.0),
        tail_weight: LinearRgb::new(0.005, 0.004, 0.006),
    };

    pub fn validate(self) -> Result<Self, PanelError> {
        for channel in 0..3 {
            let core_radius = channel_value(self.core_radius_micrometers, channel);
            let core_weight = channel_value(self.core_weight, channel);
            let tail_radius = channel_value(self.tail_radius_micrometers, channel);
            let tail_weight = channel_value(self.tail_weight, channel);
            if !self.character_strength.is_finite()
                || !(0.0..=4.0).contains(&self.character_strength)
                || !core_radius.is_finite()
                || core_radius <= 0.0
                || !tail_radius.is_finite()
                || tail_radius <= core_radius
                || !core_weight.is_finite()
                || core_weight < 0.0
                || !tail_weight.is_finite()
                || tail_weight < 0.0
                || core_weight + tail_weight > 1.0
            {
                return Err(PanelError::InvalidLightSpread);
            }
        }
        Ok(self)
    }

    pub fn samples_for_channel(self, channel: usize) -> [PanelLightSpreadSample; 9] {
        debug_assert!(channel < 3);
        let core_weight = channel_value(self.core_weight, channel);
        let tail_weight = channel_value(self.tail_weight, channel);
        let core =
            channel_value(self.core_radius_micrometers, channel) * self.character_strength * 1.0e-6;
        let tail = channel_value(self.tail_radius_micrometers, channel)
            * self.character_strength
            * core::f32::consts::FRAC_1_SQRT_2
            * 1.0e-6;
        let center = PanelLightSpreadSample {
            offset_meters: screen_contracts::Vec2 { x: 0.0, y: 0.0 },
            weight: 1.0 - core_weight - tail_weight,
        };
        let core_sample = core_weight * 0.25;
        let tail_sample = tail_weight * 0.25;
        [
            center,
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: core, y: 0.0 },
                weight: core_sample,
            },
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: -core, y: 0.0 },
                weight: core_sample,
            },
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: 0.0, y: core },
                weight: core_sample,
            },
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: 0.0, y: -core },
                weight: core_sample,
            },
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: tail, y: tail },
                weight: tail_sample,
            },
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: -tail, y: tail },
                weight: tail_sample,
            },
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: tail, y: -tail },
                weight: tail_sample,
            },
            PanelLightSpreadSample {
                offset_meters: screen_contracts::Vec2 { x: -tail, y: -tail },
                weight: tail_sample,
            },
        ]
    }
}

fn channel_value(value: LinearRgb, channel: usize) -> f32 {
    [value.r, value.g, value.b][channel]
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DevicePreset {
    pub id: &'static str,
    pub label: &'static str,
    pub category: &'static str,
    pub panel_technology: PanelTechnology,
    pub light_spread: PanelLightSpreadProfile,
    pub uniformity: PanelUniformityProfile,
    pub native_width: u32,
    pub native_height: u32,
    pub active_width: Meters,
    pub active_height: Meters,
    pub reference_white_nits: f32,
    pub minimum_white_nits: f32,
    pub maximum_white_nits: f32,
    pub white_step_nits: f32,
    pub white_basis: &'static str,
    pub color_mode_ids: &'static [&'static str],
    pub default_color_mode_id: &'static str,
    pub default_cover_glass_preset_id: &'static str,
}

impl DevicePreset {
    pub fn profile(self) -> LcdProfile {
        LcdProfile {
            native_width: self.native_width,
            native_height: self.native_height,
            active_width: self.active_width,
            active_height: self.active_height,
            stripe_layout: StripeLayout::Rgb,
            black_matrix_fraction: 0.12,
            eotf_gamma: 2.2,
            black_level_nits: 0.08,
            white_level_nits: self.reference_white_nits,
            colorimetry: PanelColorimetry::SRGB_D65,
            angular_emission_power: LinearRgb::new(1.7, 1.5, 1.8),
            temporal_emission: PanelTemporalEmission {
                residual_flicker: ResidualFlicker {
                    period: RationalTime::new(1, 240).expect("preset period is valid"),
                    amplitude: 0.002,
                    phase: RationalTime::new(0, 1).expect("preset phase is valid"),
                },
                analytic_banding: AnalyticBanding {
                    period: RationalTime::new(1, 960).expect("preset period is valid"),
                    on_duration: RationalTime::new(1, 1_920).expect("preset duty is valid"),
                    phase: RationalTime::new(0, 1).expect("preset phase is valid"),
                    amount: 0.0,
                },
            },
        }
    }

    pub fn pixels_per_inch(self) -> f32 {
        let diagonal_pixels = (self.native_width as f32).hypot(self.native_height as f32);
        let diagonal_meters = self.active_width.0.hypot(self.active_height.0);
        diagonal_pixels / (diagonal_meters / 0.0254)
    }

    pub fn diagonal_inches(self) -> f32 {
        self.active_width.0.hypot(self.active_height.0) / 0.0254
    }
}

pub const DEVICE_PRESETS: [DevicePreset; 9] = [
    DevicePreset {
        id: "lcd-phone-4_7-retina",
        label: "Phone LCD · 4.7 Retina",
        category: "Phone",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_MOBILE,
        uniformity: PanelUniformityProfile::MOBILE_LCD,
        native_width: 750,
        native_height: 1_334,
        active_width: Meters(0.058_436),
        active_height: Meters(0.103_941),
        reference_white_nits: 625.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 625.0,
        white_step_nits: 1.0,
        white_basis: "Generic authored reference",
        color_mode_ids: &["srgb"],
        default_color_mode_id: "srgb",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-phone-6_1-liquid-retina",
        label: "Phone LCD · 6.1 Liquid Retina",
        category: "Phone",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_MOBILE,
        uniformity: PanelUniformityProfile::MOBILE_LCD,
        native_width: 828,
        native_height: 1_792,
        active_width: Meters(0.064_517),
        active_height: Meters(0.139_607),
        reference_white_nits: 625.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 625.0,
        white_step_nits: 1.0,
        white_basis: "Generic authored reference",
        color_mode_ids: &["srgb"],
        default_color_mode_id: "srgb",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-phone-6_5-high-density",
        label: "Phone LCD · 6.5 high density",
        category: "Phone",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_MOBILE,
        uniformity: PanelUniformityProfile::MOBILE_LCD,
        native_width: 1_080,
        native_height: 2_400,
        active_width: Meters(0.067_733),
        active_height: Meters(0.150_519),
        reference_white_nits: 500.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 500.0,
        white_step_nits: 1.0,
        white_basis: "Generic authored reference",
        color_mode_ids: &["srgb"],
        default_color_mode_id: "srgb",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-macbook-pro-retina-14",
        label: "MacBook Pro Retina · 14.2",
        category: "Laptop",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_DESKTOP,
        uniformity: PanelUniformityProfile::PROFESSIONAL_COMPENSATED,
        native_width: 3_024,
        native_height: 1_964,
        active_width: Meters(0.302_4),
        active_height: Meters(0.196_4),
        reference_white_nits: 500.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 500.0,
        white_step_nits: 1.0,
        white_basis: "Published SDR reference",
        color_mode_ids: &["srgb"],
        default_color_mode_id: "srgb",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-laptop-fhd-15_6",
        label: "Laptop LCD · 15.6 Full HD",
        category: "Laptop",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_DESKTOP,
        uniformity: PanelUniformityProfile::DESKTOP_LCD,
        native_width: 1_920,
        native_height: 1_080,
        active_width: Meters(0.345_353),
        active_height: Meters(0.194_261),
        reference_white_nits: 300.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 300.0,
        white_step_nits: 1.0,
        white_basis: "Generic authored reference",
        color_mode_ids: &["srgb"],
        default_color_mode_id: "srgb",
        default_cover_glass_preset_id: "cover-semi-gloss",
    },
    DevicePreset {
        id: "lcd-tv-hd-32",
        label: "TV LCD · 32 HD",
        category: "Television",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_TV,
        uniformity: PanelUniformityProfile::TELEVISION_LCD,
        native_width: 1_366,
        native_height: 768,
        active_width: Meters(0.708_500),
        active_height: Meters(0.398_337),
        reference_white_nits: 250.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 250.0,
        white_step_nits: 1.0,
        white_basis: "Generic authored reference",
        color_mode_ids: &["rec709-gamma24"],
        default_color_mode_id: "rec709-gamma24",
        default_cover_glass_preset_id: "cover-semi-gloss",
    },
    DevicePreset {
        id: "lcd-tv-fhd-43",
        label: "TV LCD · 43 Full HD",
        category: "Television",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_TV,
        uniformity: PanelUniformityProfile::TELEVISION_LCD,
        native_width: 1_920,
        native_height: 1_080,
        active_width: Meters(0.951_935),
        active_height: Meters(0.535_463),
        reference_white_nits: 300.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 300.0,
        white_step_nits: 1.0,
        white_basis: "Generic authored reference",
        color_mode_ids: &["rec709-gamma24"],
        default_color_mode_id: "rec709-gamma24",
        default_cover_glass_preset_id: "cover-glossy-standard-ar",
    },
    DevicePreset {
        id: "lcd-tv-uhd-55",
        label: "TV LCD · 55 UHD",
        category: "Television",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_TV,
        uniformity: PanelUniformityProfile::TELEVISION_LCD,
        native_width: 3_840,
        native_height: 2_160,
        active_width: Meters(1.217_591),
        active_height: Meters(0.684_895),
        reference_white_nits: 350.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 350.0,
        white_step_nits: 1.0,
        white_basis: "Generic authored reference",
        color_mode_ids: &["rec709-gamma24"],
        default_color_mode_id: "rec709-gamma24",
        default_cover_glass_preset_id: "cover-glossy-standard-ar",
    },
    DevicePreset {
        id: "lcd-asus-proart-pa329cv",
        label: "ASUS ProArt PA329CV · 32 UHD",
        category: "Desktop monitor",
        panel_technology: PanelTechnology::IpsLcd,
        light_spread: PanelLightSpreadProfile::LCD_DESKTOP,
        uniformity: PanelUniformityProfile::PROFESSIONAL_COMPENSATED,
        native_width: 3_840,
        native_height: 2_160,
        active_width: Meters(0.708_480),
        active_height: Meters(0.398_520),
        reference_white_nits: 350.0,
        minimum_white_nits: 100.0,
        maximum_white_nits: 350.0,
        white_step_nits: 1.0,
        white_basis: "ASUS published typical SDR",
        color_mode_ids: &["srgb", "rec709-gamma24"],
        default_color_mode_id: "srgb",
        default_cover_glass_preset_id: "cover-matte-ar",
    },
];

pub fn device_preset(id: &str) -> Option<DevicePreset> {
    DEVICE_PRESETS
        .iter()
        .copied()
        .find(|preset| preset.id == id)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelTemporalEmission {
    pub residual_flicker: ResidualFlicker,
    pub analytic_banding: AnalyticBanding,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResidualFlicker {
    pub period: RationalTime,
    pub amplitude: f32,
    pub phase: RationalTime,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnalyticBanding {
    pub period: RationalTime,
    pub on_duration: RationalTime,
    pub phase: RationalTime,
    /// Creative interpolation from clean emission at zero to duty-normalized PWM at one.
    pub amount: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ValidatedPanelEvaluator {
    profile: LcdProfile,
    native_to_acescg: [[f32; 3]; 3],
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeviceStageParameters {
    pub native_to_acescg: [[f32; 3]; 3],
    pub eotf_gamma: f32,
    pub black_level_nits: f32,
    pub white_level_nits: f32,
}

impl LcdProfile {
    pub fn validate(self) -> Result<Self, PanelError> {
        if self.native_width == 0 || self.native_height == 0 {
            return Err(PanelError::EmptyNativeRaster);
        }
        if !self.active_width.0.is_finite()
            || !self.active_height.0.is_finite()
            || self.active_width.0 <= 0.0
            || self.active_height.0 <= 0.0
        {
            return Err(PanelError::NonPositiveActiveArea);
        }
        if !(0.0..1.0).contains(&self.black_matrix_fraction) {
            return Err(PanelError::InvalidBlackMatrix);
        }
        if !self.eotf_gamma.is_finite() || self.eotf_gamma <= 0.0 {
            return Err(PanelError::InvalidEotf);
        }
        if !self.black_level_nits.is_finite()
            || !self.white_level_nits.is_finite()
            || self.black_level_nits < 0.0
            || self.white_level_nits <= self.black_level_nits
        {
            return Err(PanelError::InvalidLuminanceRange);
        }
        if native_to_acescg_matrix(self.colorimetry).is_none() {
            return Err(PanelError::InvalidColorimetry);
        }
        if [
            self.angular_emission_power.r,
            self.angular_emission_power.g,
            self.angular_emission_power.b,
        ]
        .into_iter()
        .any(|value| !value.is_finite() || value < 0.0)
        {
            return Err(PanelError::InvalidAngularResponse);
        }
        self.temporal_emission.validate()?;
        Ok(self)
    }

    pub fn pixels_per_inch(self) -> f32 {
        let diagonal_pixels =
            (self.native_width.pow(2) as f32 + self.native_height.pow(2) as f32).sqrt();
        let width_inches = self.active_width.0 / 0.0254;
        let height_inches = self.active_height.0 / 0.0254;
        diagonal_pixels / width_inches.hypot(height_inches)
    }

    /// Returns every physical-size diagnostic from the profile's sole
    /// authoritative raster and active-area values.
    pub fn flat_panel_geometry(self) -> Result<FlatPanelGeometry, PanelError> {
        let profile = self.validate()?;
        Ok(FlatPanelGeometry {
            native_width: profile.native_width,
            native_height: profile.native_height,
            active_width_meters: profile.active_width.0,
            active_height_meters: profile.active_height.0,
            pitch_x_meters: profile.active_width.0 / profile.native_width as f32,
            pitch_y_meters: profile.active_height.0 / profile.native_height as f32,
            pixels_per_inch: profile.pixels_per_inch(),
            stripe_layout: profile.stripe_layout,
            black_matrix_fraction: profile.black_matrix_fraction,
        })
    }

    /// Derives a quality lattice without changing the panel domain or framing.
    /// Native exposes a three-by-three lattice per device pixel: three emitter
    /// stripes horizontally and explicit black-matrix phase vertically.
    pub fn flat_panel_sampling(
        self,
        quality: FlatPanelQuality,
        requested_width: u32,
        requested_height: u32,
    ) -> Result<FlatPanelSampling, PanelError> {
        let profile = self.validate()?;
        if requested_width == 0 || requested_height == 0 {
            return Err(PanelError::EmptyOutputRaster);
        }
        let sampling = match quality {
            FlatPanelQuality::Draft => FlatPanelSampling {
                effective_width: requested_width,
                effective_height: requested_height,
                samples_per_output_pixel: 1,
                subpixel_geometry_resolved: requested_width
                    >= profile.native_width.saturating_mul(3)
                    && requested_height >= profile.native_height.saturating_mul(3),
            },
            FlatPanelQuality::Medium => FlatPanelSampling {
                effective_width: requested_width,
                effective_height: requested_height,
                samples_per_output_pixel: 4,
                subpixel_geometry_resolved: requested_width
                    >= profile.native_width.saturating_mul(3)
                    && requested_height >= profile.native_height.saturating_mul(3),
            },
            FlatPanelQuality::High => FlatPanelSampling {
                effective_width: requested_width,
                effective_height: requested_height,
                samples_per_output_pixel: 16,
                subpixel_geometry_resolved: requested_width
                    >= profile.native_width.saturating_mul(3)
                    && requested_height >= profile.native_height.saturating_mul(3),
            },
            FlatPanelQuality::Native => FlatPanelSampling {
                effective_width: requested_width.max(profile.native_width.saturating_mul(3)),
                effective_height: requested_height.max(profile.native_height.saturating_mul(3)),
                samples_per_output_pixel: 1,
                subpixel_geometry_resolved: true,
            },
        };
        Ok(sampling)
    }

    pub fn evaluator(self) -> Result<ValidatedPanelEvaluator, PanelError> {
        let profile = self.validate()?;
        Ok(ValidatedPanelEvaluator {
            profile,
            native_to_acescg: native_to_acescg_matrix(profile.colorimetry)
                .expect("validated panel has a finite well-conditioned color transform"),
        })
    }

    pub fn pixel_pitch_meters(self) -> f32 {
        self.active_width.0 / self.native_width as f32
    }

    pub fn native_emission(self, signal: DeviceRgb) -> LinearRgb {
        let span = self.white_level_nits - self.black_level_nits;
        let channel = |value: f32| {
            let powered = value.abs().powf(self.eotf_gamma).copysign(value);
            self.black_level_nits + span * powered
        };
        LinearRgb::new(channel(signal.r), channel(signal.g), channel(signal.b))
    }

    pub fn native_to_acescg(self, native: LinearRgb) -> LinearRgb {
        let matrix = native_to_acescg_matrix(self.colorimetry)
            .expect("panel colorimetry must be validated before emission evaluation");
        LinearRgb::new(
            matrix[0][0] * native.r + matrix[0][1] * native.g + matrix[0][2] * native.b,
            matrix[1][0] * native.r + matrix[1][1] * native.g + matrix[1][2] * native.b,
            matrix[2][0] * native.r + matrix[2][1] * native.g + matrix[2][2] * native.b,
        )
    }

    pub fn emitted_radiance(self, signal: DeviceRgb) -> LinearRgb {
        self.native_to_acescg(self.native_emission(signal))
    }

    pub fn angular_attenuation(self, emission_cosine: f32) -> LinearRgb {
        let cosine = emission_cosine.clamp(0.0, 1.0);
        if cosine == 0.0 {
            return LinearRgb::new(0.0, 0.0, 0.0);
        }
        LinearRgb::new(
            cosine.powf(self.angular_emission_power.r),
            cosine.powf(self.angular_emission_power.g),
            cosine.powf(self.angular_emission_power.b),
        )
    }

    pub fn subpixel_emission(self, signal: DeviceRgb) -> SubpixelEmission {
        let emission = self.native_emission(signal);
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
        self.native_to_acescg(self.native_emission_at_pixel(signal, pixel_uv))
    }

    pub fn native_emission_at_pixel(
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

impl ValidatedPanelEvaluator {
    pub fn device_stage_parameters(self) -> DeviceStageParameters {
        DeviceStageParameters {
            native_to_acescg: self.native_to_acescg,
            eotf_gamma: self.profile.eotf_gamma,
            black_level_nits: self.profile.black_level_nits,
            white_level_nits: self.profile.white_level_nits,
        }
    }

    pub fn normalized_device_emission(self, signal: DeviceRgb) -> LinearRgb {
        let value = self.profile.emitted_radiance(signal);
        LinearRgb::new(
            value.r / self.profile.white_level_nits,
            value.g / self.profile.white_level_nits,
            value.b / self.profile.white_level_nits,
        )
    }

    pub fn native_channel(self, signal: DeviceRgb, channel: usize) -> f32 {
        let value = [signal.r, signal.g, signal.b][channel];
        let span = self.profile.white_level_nits - self.profile.black_level_nits;
        self.profile.black_level_nits
            + span * value.abs().powf(self.profile.eotf_gamma).copysign(value)
    }

    pub fn native_channel_at_pixel(
        self,
        signal: DeviceRgb,
        pixel_uv: screen_contracts::Vec2,
        channel: usize,
    ) -> f32 {
        let margin = self.profile.black_matrix_fraction * 0.5;
        if pixel_uv.x < margin
            || pixel_uv.x > 1.0 - margin
            || pixel_uv.y < margin
            || pixel_uv.y > 1.0 - margin
        {
            return 0.0;
        }
        let stripe = ((pixel_uv.x - margin) / (1.0 - 2.0 * margin) * 3.0)
            .floor()
            .clamp(0.0, 2.0) as usize;
        let emitter = match self.profile.stripe_layout {
            StripeLayout::Rgb => stripe,
            StripeLayout::Bgr => 2 - stripe,
        };
        if emitter != channel {
            return 0.0;
        }
        let visible_area = (1.0 - self.profile.black_matrix_fraction).powi(2);
        self.native_channel(signal, channel) * 3.0 / visible_area
    }

    pub fn native_channel_over_device_rect(
        self,
        signal: DeviceRgb,
        minimum: screen_contracts::Vec2,
        maximum: screen_contracts::Vec2,
        channel: usize,
    ) -> f32 {
        let width = maximum.x - minimum.x;
        let height = maximum.y - minimum.y;
        if width <= f32::EPSILON || height <= f32::EPSILON {
            return self.native_channel_at_pixel(
                signal,
                screen_contracts::Vec2 {
                    x: minimum.x.rem_euclid(1.0),
                    y: minimum.y.rem_euclid(1.0),
                },
                channel,
            );
        }
        let margin = self.profile.black_matrix_fraction * 0.5;
        let active_span = 1.0 - 2.0 * margin;
        let emitter = match self.profile.stripe_layout {
            StripeLayout::Rgb => channel,
            StripeLayout::Bgr => 2 - channel,
        };
        let stripe_start = margin + emitter as f32 * active_span / 3.0;
        let stripe_end = margin + (emitter + 1) as f32 * active_span / 3.0;
        let covered_x = periodic_interval_coverage(minimum.x, maximum.x, stripe_start, stripe_end);
        let covered_y = periodic_interval_coverage(minimum.y, maximum.y, margin, 1.0 - margin);
        let covered_fraction = covered_x * covered_y / (width * height);
        let visible_area = active_span * active_span;
        self.native_channel(signal, channel) * covered_fraction * 3.0 / visible_area
    }

    pub fn linear_native_channel_over_device_rect(
        self,
        linear_native_channel: f32,
        minimum: screen_contracts::Vec2,
        maximum: screen_contracts::Vec2,
        channel: usize,
    ) -> f32 {
        let width = maximum.x - minimum.x;
        let height = maximum.y - minimum.y;
        if width <= f32::EPSILON || height <= f32::EPSILON {
            let pixel_uv = screen_contracts::Vec2 {
                x: minimum.x.rem_euclid(1.0),
                y: minimum.y.rem_euclid(1.0),
            };
            let margin = self.profile.black_matrix_fraction * 0.5;
            if pixel_uv.x < margin
                || pixel_uv.x > 1.0 - margin
                || pixel_uv.y < margin
                || pixel_uv.y > 1.0 - margin
            {
                return 0.0;
            }
            let stripe = ((pixel_uv.x - margin) / (1.0 - 2.0 * margin) * 3.0)
                .floor()
                .clamp(0.0, 2.0) as usize;
            let emitter = match self.profile.stripe_layout {
                StripeLayout::Rgb => stripe,
                StripeLayout::Bgr => 2 - stripe,
            };
            if emitter != channel {
                return 0.0;
            }
            return linear_native_channel * 3.0
                / (1.0 - self.profile.black_matrix_fraction).powi(2);
        }
        let margin = self.profile.black_matrix_fraction * 0.5;
        let active_span = 1.0 - 2.0 * margin;
        let emitter = match self.profile.stripe_layout {
            StripeLayout::Rgb => channel,
            StripeLayout::Bgr => 2 - channel,
        };
        let stripe_start = margin + emitter as f32 * active_span / 3.0;
        let stripe_end = margin + (emitter + 1) as f32 * active_span / 3.0;
        let covered_x = periodic_interval_coverage(minimum.x, maximum.x, stripe_start, stripe_end);
        let covered_y = periodic_interval_coverage(minimum.y, maximum.y, margin, 1.0 - margin);
        let covered_fraction = covered_x * covered_y / (width * height);
        linear_native_channel * covered_fraction * 3.0 / (active_span * active_span)
    }

    pub fn angular_channel(self, emission_cosine: f32, channel: usize) -> f32 {
        let cosine = emission_cosine.clamp(0.0, 1.0);
        if cosine == 0.0 {
            return 0.0;
        }
        cosine.powf(
            [
                self.profile.angular_emission_power.r,
                self.profile.angular_emission_power.g,
                self.profile.angular_emission_power.b,
            ][channel],
        )
    }

    pub fn native_to_acescg(self, native: LinearRgb) -> LinearRgb {
        let matrix = self.native_to_acescg;
        LinearRgb::new(
            matrix[0][0] * native.r + matrix[0][1] * native.g + matrix[0][2] * native.b,
            matrix[1][0] * native.r + matrix[1][1] * native.g + matrix[1][2] * native.b,
            matrix[2][0] * native.r + matrix[2][1] * native.g + matrix[2][2] * native.b,
        )
    }

    pub fn temporal_gain(self, time: RationalTime) -> Result<f32, PanelError> {
        self.profile.temporal_emission.gain(time)
    }
}

fn periodic_interval_coverage(minimum: f32, maximum: f32, start: f32, end: f32) -> f32 {
    fn integral(position: f32, start: f32, end: f32) -> f32 {
        let cell = position.floor();
        let phase = position - cell;
        cell * (end - start) + (phase - start).clamp(0.0, end - start)
    }

    integral(maximum, start, end) - integral(minimum, start, end)
}

impl PanelTemporalEmission {
    pub fn continuous() -> Self {
        Self {
            residual_flicker: ResidualFlicker {
                period: RationalTime::new(1, 240).expect("clean flicker period is valid"),
                amplitude: 0.0,
                phase: RationalTime::new(0, 1).expect("clean flicker phase is valid"),
            },
            analytic_banding: AnalyticBanding {
                period: RationalTime::new(1, 960).expect("clean banding period is valid"),
                on_duration: RationalTime::new(1, 1_920).expect("clean banding duty is valid"),
                phase: RationalTime::new(0, 1).expect("clean banding phase is valid"),
                amount: 0.0,
            },
        }
    }

    pub fn clean_lcd() -> Self {
        Self {
            residual_flicker: ResidualFlicker {
                period: RationalTime::new(1, 240).expect("LCD flicker period is valid"),
                amplitude: 0.002,
                phase: RationalTime::new(0, 1).expect("LCD flicker phase is valid"),
            },
            ..Self::continuous()
        }
    }

    pub fn validate(self) -> Result<Self, PanelError> {
        if self.residual_flicker.period.numerator() <= 0
            || !self.residual_flicker.amplitude.is_finite()
            || !(0.0..=0.1).contains(&self.residual_flicker.amplitude)
            || self.analytic_banding.period.numerator() <= 0
            || self.analytic_banding.on_duration.numerator() <= 0
            || self.analytic_banding.on_duration > self.analytic_banding.period
            || !self.analytic_banding.amount.is_finite()
            || !(0.0..=1.0).contains(&self.analytic_banding.amount)
        {
            return Err(PanelError::InvalidTemporalEmission);
        }
        Ok(self)
    }

    pub fn gain(self, time: RationalTime) -> Result<f32, PanelError> {
        self.validate()?;
        let residual = self.residual_gain(time);
        let banding = self.banding_gain(time)?;
        Ok(residual * banding)
    }

    pub fn average_gain(self, start: RationalTime, end: RationalTime) -> Result<f32, PanelError> {
        self.validate()?;
        if end <= start {
            return Err(PanelError::InvalidTemporalInterval);
        }
        if self.analytic_banding.amount == 0.0 {
            return Ok(self.average_residual_gain(start, end));
        }
        let mut boundaries = vec![start, end];
        boundaries.extend(self.banding_transitions_between(start, end)?);
        boundaries.sort_unstable();
        boundaries.dedup();
        let duration = end
            .checked_sub(start)
            .map_err(PanelError::Time)?
            .as_seconds();
        let mut integral = 0.0;
        for interval in boundaries.windows(2) {
            let width = interval[1]
                .checked_sub(interval[0])
                .map_err(PanelError::Time)?;
            let midpoint = interval[0]
                .checked_add(width.checked_mul_ratio(1, 2).map_err(PanelError::Time)?)
                .map_err(PanelError::Time)?;
            integral += f64::from(
                self.average_residual_gain(interval[0], interval[1])
                    * self.banding_gain(midpoint)?,
            ) * width.as_seconds();
        }
        Ok((integral / duration) as f32)
    }

    fn residual_gain(self, time: RationalTime) -> f32 {
        let relative = time.as_seconds() - self.residual_flicker.phase.as_seconds();
        let angle = core::f64::consts::TAU * relative / self.residual_flicker.period.as_seconds();
        1.0 + self.residual_flicker.amplitude * angle.sin() as f32
    }

    fn average_residual_gain(self, start: RationalTime, end: RationalTime) -> f32 {
        let period = self.residual_flicker.period.as_seconds();
        let phase = self.residual_flicker.phase.as_seconds();
        let start_seconds = start.as_seconds();
        let end_seconds = end.as_seconds();
        let duration = end_seconds - start_seconds;
        let omega = core::f64::consts::TAU / period;
        let average_sine = ((omega * (start_seconds - phase)).cos()
            - (omega * (end_seconds - phase)).cos())
            / (omega * duration);
        1.0 + self.residual_flicker.amplitude * average_sine as f32
    }

    fn banding_gain(self, time: RationalTime) -> Result<f32, PanelError> {
        if self.analytic_banding.amount == 0.0 {
            return Ok(1.0);
        }
        let relative = time
            .checked_sub(self.analytic_banding.phase)
            .map_err(PanelError::Time)?;
        let cycle = relative
            .floor_div(self.analytic_banding.period)
            .map_err(PanelError::Time)?;
        let cycle_start = self
            .analytic_banding
            .period
            .checked_mul_ratio(cycle, 1)
            .map_err(PanelError::Time)?;
        let within_cycle = relative
            .checked_sub(cycle_start)
            .map_err(PanelError::Time)?;
        let duty = (self.analytic_banding.on_duration.as_seconds()
            / self.analytic_banding.period.as_seconds()) as f32;
        let pwm = if within_cycle < self.analytic_banding.on_duration {
            1.0 / duty
        } else {
            0.0
        };
        Ok(1.0 + self.analytic_banding.amount * (pwm - 1.0))
    }

    fn banding_transitions_between(
        self,
        start: RationalTime,
        end: RationalTime,
    ) -> Result<Vec<RationalTime>, PanelError> {
        const MAX_TRANSITIONS: i64 = 4_096;
        self.validate()?;
        if end <= start {
            return Err(PanelError::InvalidTemporalInterval);
        }
        if self.analytic_banding.amount == 0.0
            || self.analytic_banding.on_duration == self.analytic_banding.period
        {
            return Ok(Vec::new());
        }
        let relative_start = start
            .checked_sub(self.analytic_banding.phase)
            .map_err(PanelError::Time)?;
        let relative_end = end
            .checked_sub(self.analytic_banding.phase)
            .map_err(PanelError::Time)?;
        let first_cycle = relative_start
            .floor_div(self.analytic_banding.period)
            .map_err(PanelError::Time)?;
        let last_cycle = relative_end
            .floor_div(self.analytic_banding.period)
            .map_err(PanelError::Time)?;
        let cycle_count = last_cycle
            .checked_sub(first_cycle)
            .and_then(|value| value.checked_add(1))
            .ok_or(PanelError::TooManyTemporalTransitions)?;
        if cycle_count > MAX_TRANSITIONS / 2 {
            return Err(PanelError::TooManyTemporalTransitions);
        }
        let mut transitions = Vec::with_capacity(cycle_count.max(0) as usize * 2);
        for cycle in first_cycle..=last_cycle {
            let cycle_start = self
                .analytic_banding
                .phase
                .checked_add(
                    self.analytic_banding
                        .period
                        .checked_mul_ratio(cycle, 1)
                        .map_err(PanelError::Time)?,
                )
                .map_err(PanelError::Time)?;
            let off = cycle_start
                .checked_add(self.analytic_banding.on_duration)
                .map_err(PanelError::Time)?;
            for transition in [cycle_start, off] {
                if transition > start && transition < end {
                    transitions.push(transition);
                }
            }
        }
        transitions.sort_unstable();
        transitions.dedup();
        Ok(transitions)
    }
}

fn chromaticity_coordinates_are_valid(color: PanelColorimetry) -> bool {
    let points = [color.red, color.green, color.blue, color.white];
    points
        .into_iter()
        .all(|p| p.x.is_finite() && p.y.is_finite() && p.x > 0.0 && p.y > 0.0 && p.x + p.y < 1.0)
}

fn xy_to_xyz(value: Chromaticity) -> [f32; 3] {
    [value.x / value.y, 1.0, (1.0 - value.x - value.y) / value.y]
}

fn primary_xyz_columns(color: PanelColorimetry) -> [[f32; 3]; 3] {
    let r = xy_to_xyz(color.red);
    let g = xy_to_xyz(color.green);
    let b = xy_to_xyz(color.blue);
    [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]]
}

fn native_to_acescg_matrix(color: PanelColorimetry) -> Option<[[f32; 3]; 3]> {
    const MAX_CONDITION_ESTIMATE: f32 = 10_000.0;
    const MIN_CONE_RESPONSE: f32 = 1.0e-4;
    const MAX_ADAPTATION_SCALE: f32 = 64.0;
    const MAX_TRANSFORM_COEFFICIENT: f32 = 32.0;
    if !chromaticity_coordinates_are_valid(color) {
        return None;
    }
    let primaries = primary_xyz_columns(color);
    let primary_inverse = inverse3(primaries)?;
    if matrix_infinity_norm(primaries) * matrix_infinity_norm(primary_inverse)
        > MAX_CONDITION_ESTIMATE
    {
        return None;
    }
    let white_xyz = xy_to_xyz(color.white);
    let scales = mat_vec(primary_inverse, white_xyz);
    if scales
        .into_iter()
        .any(|value| !value.is_finite() || value <= 0.0)
    {
        return None;
    }
    let native_to_xyz = core::array::from_fn(|row| {
        core::array::from_fn(|column| primaries[row][column] * scales[column])
    });

    const BRADFORD: [[f32; 3]; 3] = [
        [0.8951, 0.2664, -0.1614],
        [-0.7502, 1.7135, 0.0367],
        [0.0389, -0.0685, 1.0296],
    ];
    const BRADFORD_INV: [[f32; 3]; 3] = [
        [0.986_992_9, -0.147_054_3, 0.159_962_7],
        [0.432_305_3, 0.518_360_3, 0.049_291_2],
        [-0.008_528_7, 0.040_042_8, 0.968_486_7],
    ];
    const D60: [f32; 3] = [0.952_646_1, 1.0, 1.008_825_2];
    const XYZ_D60_TO_ACESCG: [[f32; 3]; 3] = [
        [1.641_023_4, -0.324_803_3, -0.236_424_7],
        [-0.663_662_9, 1.615_331_6, 0.016_756_35],
        [0.011_721_89, -0.008_284_442, 0.988_394_86],
    ];
    let source_cones = mat_vec(BRADFORD, white_xyz);
    let target_cones = mat_vec(BRADFORD, D60);
    if source_cones
        .into_iter()
        .any(|value| !value.is_finite() || value.abs() < MIN_CONE_RESPONSE)
    {
        return None;
    }
    let adaptation_scale = [
        target_cones[0] / source_cones[0],
        target_cones[1] / source_cones[1],
        target_cones[2] / source_cones[2],
    ];
    if adaptation_scale
        .into_iter()
        .any(|value| !value.is_finite() || value <= 0.0 || value > MAX_ADAPTATION_SCALE)
    {
        return None;
    }
    let diagonal = [
        [adaptation_scale[0], 0.0, 0.0],
        [0.0, adaptation_scale[1], 0.0],
        [0.0, 0.0, adaptation_scale[2]],
    ];
    let adaptation = mat_mul(BRADFORD_INV, mat_mul(diagonal, BRADFORD));
    let result = mat_mul(XYZ_D60_TO_ACESCG, mat_mul(adaptation, native_to_xyz));
    let coefficients_are_bounded = result
        .into_iter()
        .flatten()
        .all(|value| value.is_finite() && value.abs() <= MAX_TRANSFORM_COEFFICIENT);
    let result_is_well_conditioned = inverse3(result).is_some_and(|inverse| {
        matrix_infinity_norm(result) * matrix_infinity_norm(inverse) <= MAX_CONDITION_ESTIMATE
    });
    (coefficients_are_bounded && result_is_well_conditioned).then_some(result)
}

fn matrix_infinity_norm(matrix: [[f32; 3]; 3]) -> f32 {
    matrix
        .into_iter()
        .map(|row| row.into_iter().map(f32::abs).sum::<f32>())
        .fold(0.0, f32::max)
}

fn mat_vec(matrix: [[f32; 3]; 3], vector: [f32; 3]) -> [f32; 3] {
    core::array::from_fn(|row| {
        matrix[row][0] * vector[0] + matrix[row][1] * vector[1] + matrix[row][2] * vector[2]
    })
}

fn mat_mul(left: [[f32; 3]; 3], right: [[f32; 3]; 3]) -> [[f32; 3]; 3] {
    core::array::from_fn(|row| {
        core::array::from_fn(|column| {
            left[row][0] * right[0][column]
                + left[row][1] * right[1][column]
                + left[row][2] * right[2][column]
        })
    })
}

fn inverse3(matrix: [[f32; 3]; 3]) -> Option<[[f32; 3]; 3]> {
    let determinant = matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1])
        - matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0])
        + matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if !determinant.is_finite() || determinant.abs() < 1.0e-8 {
        return None;
    }
    let inverse = 1.0 / determinant;
    Some([
        [
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * inverse,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * inverse,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * inverse,
        ],
        [
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * inverse,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * inverse,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * inverse,
        ],
        [
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * inverse,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * inverse,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * inverse,
        ],
    ])
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelError {
    EmptyNativeRaster,
    EmptyOutputRaster,
    NonPositiveActiveArea,
    InvalidBlackMatrix,
    InvalidEotf,
    InvalidLuminanceRange,
    InvalidColorimetry,
    InvalidAngularResponse,
    InvalidLightSpread,
    InvalidUniformity,
    InvalidTemporalEmission,
    InvalidTemporalInterval,
    TooManyTemporalTransitions,
    Time(ContractError),
}

impl fmt::Display for PanelError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::EmptyNativeRaster => "LCD native raster must be non-empty",
            Self::EmptyOutputRaster => "flat panel output raster must be non-empty",
            Self::NonPositiveActiveArea => "LCD active dimensions must be positive",
            Self::InvalidBlackMatrix => "black matrix fraction must be in [0, 1)",
            Self::InvalidEotf => "LCD EOTF gamma must be positive",
            Self::InvalidLuminanceRange => {
                "LCD white level must be greater than a non-negative black level"
            }
            Self::InvalidColorimetry => {
                "panel primaries and white point must form a finite non-degenerate color space"
            }
            Self::InvalidAngularResponse => {
                "panel angular-emission powers must be finite and non-negative"
            }
            Self::InvalidLightSpread => "panel light-spread radii and energy weights are invalid",
            Self::InvalidUniformity => "panel spatial-uniformity profile is invalid",
            Self::InvalidTemporalEmission => {
                "panel residual flicker and analytic banding parameters are outside their certified ranges"
            }
            Self::InvalidTemporalInterval => {
                "panel temporal integration interval must have positive duration"
            }
            Self::TooManyTemporalTransitions => {
                "panel temporal interval exceeds the supported exact banding transition count"
            }
            Self::Time(error) => return write!(formatter, "invalid panel temporal phase: {error}"),
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
            colorimetry: PanelColorimetry::SRGB_D65,
            angular_emission_power: LinearRgb::new(1.7, 1.5, 1.8),
            temporal_emission: PanelTemporalEmission::continuous(),
        }
    }

    #[test]
    fn derives_pitch_and_ppi_from_physical_profile() {
        let profile = profile().validate().expect("valid panel");
        assert!((profile.pixel_pitch_meters() - 0.000_155_4).abs() < 0.000_000_1);
        assert!((profile.pixels_per_inch() - 163.5).abs() < 0.2);
    }

    #[test]
    fn panel_uniformity_is_fixed_positive_and_zero_is_exact_identity() {
        let panel = profile();
        let minimum = screen_contracts::Vec2 { x: 731.0, y: 412.0 };
        let maximum = screen_contracts::Vec2 { x: 734.0, y: 415.0 };
        let signal = DeviceRgb::new(0.1, 0.5, 0.8);
        let zero = PanelUniformityProfile {
            character_strength: 0.0,
            ..PanelUniformityProfile::PROFESSIONAL_COMPENSATED
        }
        .channel_gains(panel, minimum, maximum, signal);
        assert_eq!(zero, LinearRgb::new(1.0, 1.0, 1.0));

        let calibrated = PanelUniformityProfile::PROFESSIONAL_COMPENSATED
            .channel_gains(panel, minimum, maximum, signal);
        let repeated = PanelUniformityProfile::PROFESSIONAL_COMPENSATED
            .channel_gains(panel, minimum, maximum, signal);
        assert_eq!(calibrated, repeated);
        let exaggerated = PanelUniformityProfile {
            character_strength: 4.0,
            ..PanelUniformityProfile::PROFESSIONAL_COMPENSATED
        }
        .validate()
        .expect("certified artistic range")
        .channel_gains(panel, minimum, maximum, signal);
        for (one, four) in [calibrated.r, calibrated.g, calibrated.b].into_iter().zip([
            exaggerated.r,
            exaggerated.g,
            exaggerated.b,
        ]) {
            assert!(one.is_finite() && one > 0.0);
            assert!(four.is_finite() && four > 0.0);
            assert!((four - 1.0).abs() >= (one - 1.0).abs());
        }
    }

    #[test]
    fn panel_uniformity_presets_are_complete_and_filter_fine_structure() {
        for preset in DEVICE_PRESETS {
            preset
                .uniformity
                .validate()
                .expect("bundled Device owns valid uniformity");
        }
        let panel = profile();
        let signal = DeviceRgb::new(0.5, 0.5, 0.5);
        let point = PanelUniformityProfile::PROFESSIONAL_COMPENSATED.channel_gains(
            panel,
            screen_contracts::Vec2 {
                x: 1279.5,
                y: 719.5,
            },
            screen_contracts::Vec2 {
                x: 1280.5,
                y: 720.5,
            },
            signal,
        );
        let wide = PanelUniformityProfile::PROFESSIONAL_COMPENSATED.channel_gains(
            panel,
            screen_contracts::Vec2 {
                x: 1180.0,
                y: 620.0,
            },
            screen_contracts::Vec2 {
                x: 1380.0,
                y: 820.0,
            },
            signal,
        );
        let point_chroma = (point.r - point.g).abs() + (point.b - point.g).abs();
        let wide_chroma = (wide.r - wide.g).abs() + (wide.b - wide.g).abs();
        assert!(wide_chroma <= point_chroma + 1.0e-4);

        let mut mean = LinearRgb::new(0.0, 0.0, 0.0);
        let grid_width = 64;
        let grid_height = 36;
        for y in 0..grid_height {
            for x in 0..grid_width {
                let minimum = screen_contracts::Vec2 {
                    x: x as f32 * panel.native_width as f32 / grid_width as f32,
                    y: y as f32 * panel.native_height as f32 / grid_height as f32,
                };
                let maximum = screen_contracts::Vec2 {
                    x: (x + 1) as f32 * panel.native_width as f32 / grid_width as f32,
                    y: (y + 1) as f32 * panel.native_height as f32 / grid_height as f32,
                };
                let gain = PanelUniformityProfile::PROFESSIONAL_COMPENSATED
                    .channel_gains(panel, minimum, maximum, signal);
                mean.r += gain.r;
                mean.g += gain.g;
                mean.b += gain.b;
            }
        }
        let reciprocal = 1.0 / (grid_width * grid_height) as f32;
        for channel in [
            mean.r * reciprocal,
            mean.g * reciprocal,
            mean.b * reciprocal,
        ] {
            assert!((channel - 1.0).abs() <= 5.0e-4);
        }
    }

    #[test]
    fn bundled_device_presets_have_stable_unique_ids_and_complete_scale() {
        let mut ids = std::collections::BTreeSet::new();
        for preset in DEVICE_PRESETS {
            assert!(ids.insert(preset.id));
            assert!(preset.native_width > 0 && preset.native_height > 0);
            assert!(preset.active_width.0 > 0.0 && preset.active_height.0 > 0.0);
            assert!((40.0..500.0).contains(&preset.pixels_per_inch()));
            assert!((4.0..60.0).contains(&preset.diagonal_inches()));
            assert!(preset.reference_white_nits > 0.0);
            assert!(preset.minimum_white_nits.is_finite());
            assert!(preset.maximum_white_nits.is_finite());
            assert!(preset.white_step_nits.is_finite() && preset.white_step_nits > 0.0);
            assert!(preset.minimum_white_nits > 0.0);
            assert!(preset.minimum_white_nits <= preset.reference_white_nits);
            assert!(preset.reference_white_nits <= preset.maximum_white_nits);
            assert!(!preset.color_mode_ids.is_empty());
            assert!(
                preset
                    .color_mode_ids
                    .iter()
                    .all(|id| { PanelColorMode::from_stable_id(id).is_some() })
            );
            let unique_modes = preset
                .color_mode_ids
                .iter()
                .copied()
                .collect::<std::collections::BTreeSet<_>>();
            assert_eq!(unique_modes.len(), preset.color_mode_ids.len());
            assert!(
                preset
                    .color_mode_ids
                    .contains(&preset.default_color_mode_id)
            );
            assert!(!preset.white_basis.is_empty());
            assert_eq!(preset.panel_technology, PanelTechnology::IpsLcd);
            assert!(preset.profile().validate().is_ok());
            assert_eq!(device_preset(preset.id), Some(preset));
        }
        assert_eq!(device_preset("retired-or-unknown"), None);
    }

    #[test]
    fn eotf_preserves_values_above_one() {
        let emission = profile().native_emission(DeviceRgb::new(1.2, 0.5, 0.0));
        assert!(emission.r > profile().white_level_nits);
        assert!(emission.g > profile().black_level_nits);
        assert_eq!(emission.b, profile().black_level_nits);
    }

    #[test]
    fn eotf_preserves_negative_linear_excursions() {
        let emission = profile().native_emission(DeviceRgb::new(-0.25, 0.0, 0.0));
        assert!(emission.r < 0.0);
    }

    #[test]
    fn phase_preserving_rect_integration_averages_only_complete_device_cells() {
        let evaluator = profile().evaluator().expect("valid panel");
        let signal = DeviceRgb::new(0.8, 0.6, 0.4);
        for channel in 0..3 {
            let complete_cell = evaluator.native_channel_over_device_rect(
                signal,
                screen_contracts::Vec2 { x: 11.0, y: 7.0 },
                screen_contracts::Vec2 { x: 12.0, y: 8.0 },
                channel,
            );
            assert!((complete_cell - evaluator.native_channel(signal, channel)).abs() < 1.0e-3);
        }
    }

    #[test]
    fn phase_preserving_rect_integration_distinguishes_emitter_and_matrix_regions() {
        let evaluator = profile().evaluator().expect("valid panel");
        let signal = DeviceRgb::WHITE;
        let red_emitter = evaluator.native_channel_over_device_rect(
            signal,
            screen_contracts::Vec2 { x: 4.08, y: 2.20 },
            screen_contracts::Vec2 { x: 4.18, y: 2.80 },
            0,
        );
        let green_at_red_phase = evaluator.native_channel_over_device_rect(
            signal,
            screen_contracts::Vec2 { x: 4.08, y: 2.20 },
            screen_contracts::Vec2 { x: 4.18, y: 2.80 },
            1,
        );
        let matrix = evaluator.native_channel_over_device_rect(
            signal,
            screen_contracts::Vec2 { x: 4.01, y: 2.01 },
            screen_contracts::Vec2 { x: 4.04, y: 2.04 },
            0,
        );
        assert!(red_emitter > evaluator.native_channel(signal, 0));
        assert_eq!(green_at_red_phase, 0.0);
        assert_eq!(matrix, 0.0);
    }

    #[test]
    fn declared_white_adapts_to_neutral_acescg() {
        let white = profile().emitted_radiance(DeviceRgb::WHITE);
        assert!((white.r - white.g).abs() < 1.0);
        assert!((white.g - white.b).abs() < 1.0);
    }

    #[test]
    fn srgb_d65_to_acescg_matches_cross_platform_golden_vectors() {
        let evaluator = profile().evaluator().expect("valid panel");
        let red = evaluator.native_to_acescg(LinearRgb::new(1.0, 0.0, 0.0));
        let green = evaluator.native_to_acescg(LinearRgb::new(0.0, 1.0, 0.0));
        let blue = evaluator.native_to_acescg(LinearRgb::new(0.0, 0.0, 1.0));
        let close = |actual: f32, expected: f32| {
            assert!((actual - expected).abs() < 1.0e-3, "{actual} != {expected}")
        };
        for (actual, expected) in [red.r, red.g, red.b]
            .into_iter()
            .zip([0.6131, 0.0702, 0.0206])
        {
            close(actual, expected);
        }
        for (actual, expected) in [green.r, green.g, green.b]
            .into_iter()
            .zip([0.3395, 0.9163, 0.1096])
        {
            close(actual, expected);
        }
        for (actual, expected) in [blue.r, blue.g, blue.b]
            .into_iter()
            .zip([0.0474, 0.0135, 0.8698])
        {
            close(actual, expected);
        }
    }

    #[test]
    fn rejects_bradford_singular_and_ill_conditioned_colorimetry() {
        let mut singular_adaptation = profile();
        singular_adaptation.colorimetry = PanelColorimetry {
            red: Chromaticity { x: 0.80, y: 0.10 },
            green: Chromaticity { x: 0.10, y: 0.80 },
            blue: Chromaticity { x: 0.01, y: 0.01 },
            white: Chromaticity {
                x: 0.071_784,
                y: 0.20,
            },
        };
        assert_eq!(
            singular_adaptation.validate(),
            Err(PanelError::InvalidColorimetry)
        );

        let mut ill_conditioned_primaries = profile();
        ill_conditioned_primaries.colorimetry.green = Chromaticity {
            x: 0.640_001,
            y: 0.329_999,
        };
        assert_eq!(
            ill_conditioned_primaries.validate(),
            Err(PanelError::InvalidColorimetry)
        );

        let mut ill_conditioned_transform = profile();
        ill_conditioned_transform.colorimetry.white = Chromaticity {
            x: 0.639_99,
            y: 0.329_99,
        };
        assert_eq!(
            ill_conditioned_transform.validate(),
            Err(PanelError::InvalidColorimetry)
        );
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

    #[test]
    fn flat_geometry_derives_pitch_and_ppi_from_one_profile() {
        let panel = profile();
        let geometry = panel.flat_panel_geometry().expect("valid flat geometry");
        assert_eq!(geometry.native_width, panel.native_width);
        assert_eq!(geometry.native_height, panel.native_height);
        assert_eq!(
            geometry.pitch_x_meters,
            panel.active_width.0 / panel.native_width as f32
        );
        assert_eq!(
            geometry.pitch_y_meters,
            panel.active_height.0 / panel.native_height as f32
        );
        assert_eq!(geometry.pixels_per_inch, panel.pixels_per_inch());
    }

    #[test]
    fn quality_lattices_preserve_domain_and_native_resolves_stripes() {
        let panel = profile();
        let draft = panel
            .flat_panel_sampling(FlatPanelQuality::Draft, 320, 180)
            .expect("draft lattice");
        let medium = panel
            .flat_panel_sampling(FlatPanelQuality::Medium, 320, 180)
            .expect("medium lattice");
        let high = panel
            .flat_panel_sampling(FlatPanelQuality::High, 320, 180)
            .expect("high lattice");
        let native = panel
            .flat_panel_sampling(FlatPanelQuality::Native, 320, 180)
            .expect("native lattice");
        assert_eq!((draft.effective_width, draft.effective_height), (320, 180));
        assert_eq!(
            (medium.effective_width, medium.effective_height),
            (320, 180)
        );
        assert_eq!((high.effective_width, high.effective_height), (320, 180));
        assert_eq!(
            (native.effective_width, native.effective_height),
            (panel.native_width * 3, panel.native_height * 3)
        );
        assert_eq!(
            [
                draft.samples_per_output_pixel,
                medium.samples_per_output_pixel,
                high.samples_per_output_pixel,
                native.samples_per_output_pixel,
            ],
            [1, 4, 16, 1]
        );
        assert!(native.subpixel_geometry_resolved);
    }

    #[test]
    fn light_spread_kernels_conserve_energy_and_scale_physical_radius() {
        for profile in [
            PanelLightSpreadProfile::LCD_MOBILE,
            PanelLightSpreadProfile::LCD_DESKTOP,
            PanelLightSpreadProfile::LCD_TV,
            PanelLightSpreadProfile::OLED_CONTAINED,
            PanelLightSpreadProfile::MICRO_LED_CONTAINED,
        ] {
            profile.validate().expect("valid spread profile");
            for channel in 0..3 {
                let samples = profile.samples_for_channel(channel);
                let sum = samples.iter().map(|sample| sample.weight).sum::<f32>();
                assert!((sum - 1.0).abs() <= 2.0e-7);
            }
        }
        let mut identity = PanelLightSpreadProfile::LCD_DESKTOP;
        identity.character_strength = 0.0;
        assert!(
            identity.samples_for_channel(0).iter().all(|sample| {
                sample.offset_meters == screen_contracts::Vec2 { x: 0.0, y: 0.0 }
            })
        );
        let calibrated = PanelLightSpreadProfile::LCD_DESKTOP.samples_for_channel(0);
        let mut artistic = PanelLightSpreadProfile::LCD_DESKTOP;
        artistic.character_strength = 2.5;
        let artistic = artistic.samples_for_channel(0);
        assert_eq!(
            artistic[1].offset_meters.x,
            calibrated[1].offset_meters.x * 2.5
        );
    }

    #[test]
    fn rear_face_never_emits_even_with_lambertian_zero_power() {
        let mut panel = profile();
        panel.angular_emission_power = LinearRgb::new(0.0, 0.0, 0.0);
        assert_eq!(
            panel.angular_attenuation(0.0),
            LinearRgb::new(0.0, 0.0, 0.0)
        );
    }

    #[test]
    fn clean_flicker_and_optional_banding_are_separate_and_exposure_integrable() {
        let temporal = PanelTemporalEmission {
            residual_flicker: ResidualFlicker {
                period: RationalTime::new(1, 240).expect("valid residual period"),
                amplitude: 0.002,
                phase: RationalTime::new(0, 1).expect("valid residual phase"),
            },
            analytic_banding: AnalyticBanding {
                period: RationalTime::new(1, 100).expect("valid PWM period"),
                on_duration: RationalTime::new(1, 200).expect("valid on duration"),
                phase: RationalTime::new(0, 1).expect("valid PWM phase"),
                amount: 1.0,
            },
        };
        assert!(temporal.gain(RationalTime::new(1, 400).unwrap()).unwrap() > 1.9);
        assert_eq!(temporal.gain(RationalTime::new(3, 400).unwrap()), Ok(0.0));
        assert_eq!(temporal.gain(RationalTime::new(-1, 400).unwrap()), Ok(0.0));
        let full_cycles = temporal
            .average_gain(
                RationalTime::new(0, 1).unwrap(),
                RationalTime::new(1, 20).unwrap(),
            )
            .unwrap();
        assert!((full_cycles - 1.0).abs() < 1.0e-5);

        let clean = PanelTemporalEmission::clean_lcd();
        assert!(clean.gain(RationalTime::new(1, 960).unwrap()).unwrap() > 1.0);
        let integrated = clean
            .average_gain(
                RationalTime::new(0, 1).unwrap(),
                RationalTime::new(1, 24).unwrap(),
            )
            .unwrap();
        assert!((integrated - 1.0).abs() < 1.0e-5);
    }
}
