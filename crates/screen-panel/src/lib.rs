//! Device signal, procedural fixed-pixel LCD, and emitted-radiance ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{ContractError, DeviceRgb, LinearRgb, Meters, RationalTime};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StripeLayout {
    Rgb,
    Bgr,
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

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DevicePreset {
    pub id: &'static str,
    pub label: &'static str,
    pub native_width: u32,
    pub native_height: u32,
    pub active_width: Meters,
    pub active_height: Meters,
    pub reference_white_nits: f32,
    pub white_basis: &'static str,
    pub default_cover_glass_preset_id: &'static str,
}

impl DevicePreset {
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
        native_width: 750,
        native_height: 1_334,
        active_width: Meters(0.058_436),
        active_height: Meters(0.103_941),
        reference_white_nits: 625.0,
        white_basis: "Generic authored reference",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-phone-6_1-liquid-retina",
        label: "Phone LCD · 6.1 Liquid Retina",
        native_width: 828,
        native_height: 1_792,
        active_width: Meters(0.064_517),
        active_height: Meters(0.139_607),
        reference_white_nits: 625.0,
        white_basis: "Generic authored reference",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-phone-6_5-high-density",
        label: "Phone LCD · 6.5 high density",
        native_width: 1_080,
        native_height: 2_400,
        active_width: Meters(0.067_733),
        active_height: Meters(0.150_519),
        reference_white_nits: 500.0,
        white_basis: "Generic authored reference",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-macbook-pro-retina-14",
        label: "MacBook Pro Retina · 14.2",
        native_width: 3_024,
        native_height: 1_964,
        active_width: Meters(0.302_4),
        active_height: Meters(0.196_4),
        reference_white_nits: 500.0,
        white_basis: "Published SDR reference",
        default_cover_glass_preset_id: "cover-glossy-strong-ar",
    },
    DevicePreset {
        id: "lcd-laptop-fhd-15_6",
        label: "Laptop LCD · 15.6 Full HD",
        native_width: 1_920,
        native_height: 1_080,
        active_width: Meters(0.345_353),
        active_height: Meters(0.194_261),
        reference_white_nits: 300.0,
        white_basis: "Generic authored reference",
        default_cover_glass_preset_id: "cover-semi-gloss",
    },
    DevicePreset {
        id: "lcd-tv-hd-32",
        label: "TV LCD · 32 HD",
        native_width: 1_366,
        native_height: 768,
        active_width: Meters(0.708_500),
        active_height: Meters(0.398_337),
        reference_white_nits: 250.0,
        white_basis: "Generic authored reference",
        default_cover_glass_preset_id: "cover-semi-gloss",
    },
    DevicePreset {
        id: "lcd-tv-fhd-43",
        label: "TV LCD · 43 Full HD",
        native_width: 1_920,
        native_height: 1_080,
        active_width: Meters(0.951_935),
        active_height: Meters(0.535_463),
        reference_white_nits: 300.0,
        white_basis: "Generic authored reference",
        default_cover_glass_preset_id: "cover-glossy-standard-ar",
    },
    DevicePreset {
        id: "lcd-tv-uhd-55",
        label: "TV LCD · 55 UHD",
        native_width: 3_840,
        native_height: 2_160,
        active_width: Meters(1.217_591),
        active_height: Meters(0.684_895),
        reference_white_nits: 350.0,
        white_basis: "Generic authored reference",
        default_cover_glass_preset_id: "cover-glossy-standard-ar",
    },
    DevicePreset {
        id: "lcd-asus-proart-pa329cv",
        label: "ASUS ProArt PA329CV · 32 UHD",
        native_width: 3_840,
        native_height: 2_160,
        active_width: Meters(0.708_480),
        active_height: Meters(0.398_520),
        reference_white_nits: 350.0,
        white_basis: "ASUS published typical SDR",
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
    NonPositiveActiveArea,
    InvalidBlackMatrix,
    InvalidEotf,
    InvalidLuminanceRange,
    InvalidColorimetry,
    InvalidAngularResponse,
    InvalidTemporalEmission,
    InvalidTemporalInterval,
    TooManyTemporalTransitions,
    Time(ContractError),
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
            Self::InvalidColorimetry => {
                "panel primaries and white point must form a finite non-degenerate color space"
            }
            Self::InvalidAngularResponse => {
                "panel angular-emission powers must be finite and non-negative"
            }
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
    fn bundled_device_presets_have_stable_unique_ids_and_complete_scale() {
        let mut ids = std::collections::BTreeSet::new();
        for preset in DEVICE_PRESETS {
            assert!(ids.insert(preset.id));
            assert!(preset.native_width > 0 && preset.native_height > 0);
            assert!(preset.active_width.0 > 0.0 && preset.active_height.0 > 0.0);
            assert!((40.0..500.0).contains(&preset.pixels_per_inch()));
            assert!((4.0..60.0).contains(&preset.diagonal_inches()));
            assert!(preset.reference_white_nits > 0.0);
            assert!(!preset.white_basis.is_empty());
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
