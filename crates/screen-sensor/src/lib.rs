//! Camera-sensor exposure, photosite, noise, saturation and RAW ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::LinearRgb;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BayerPattern {
    Rggb,
    Bggr,
    Grbg,
    Gbrg,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SensorProfile {
    pub native_width: u16,
    pub native_height: u16,
    pub bayer_pattern: BayerPattern,
    pub acescg_to_sensor: [[f32; 3]; 3],
    /// Per-channel image-plane illuminance exposure in lux-seconds that fills the charge well.
    pub saturation_illuminance_seconds: LinearRgb,
    pub full_well_electrons: f32,
    pub dark_current_electrons_per_second: f32,
    pub read_noise_electrons_rms: f32,
    pub analog_gain: f32,
    pub adc_bits: u8,
}

#[derive(Clone, Debug, PartialEq)]
pub struct IntegratedOpticalExposure {
    pub width: u32,
    pub height: u32,
    pub duration_seconds: f32,
    /// Image-plane illuminance exposure in lux-seconds, expressed in the ACEScg basis.
    pub acescg_illuminance_seconds: Vec<LinearRgb>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CaptureIdentity {
    pub noise_seed: u64,
    pub frame_index: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawSensorRaster {
    pub width: u32,
    pub height: u32,
    pub bayer_pattern: BayerPattern,
    pub adc_bits: u8,
    pub codes: Vec<u16>,
    pub full_well_clipped: Vec<bool>,
    pub adc_clipped: Vec<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SensorRegion {
    pub origin_x: u16,
    pub origin_y: u16,
    pub width: u16,
    pub height: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawSensorRegion {
    pub sensor_width: u16,
    pub sensor_height: u16,
    pub region: SensorRegion,
    pub bayer_pattern: BayerPattern,
    pub adc_bits: u8,
    pub codes: Vec<u16>,
    pub full_well_clipped: Vec<bool>,
    pub adc_clipped: Vec<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SensorError {
    EmptyRaster,
    InvalidNativeRaster,
    RasterProfileMismatch,
    PixelCountMismatch,
    NonFiniteExposure,
    InvalidDuration,
    InvalidColorMatrix,
    InvalidSaturationExposure,
    InvalidFullWell,
    InvalidDarkCurrent,
    InvalidReadNoise,
    InvalidAnalogGain,
    InvalidAdcBits,
    InvalidSensorRegion,
}

impl SensorProfile {
    pub const REFERENCE: Self = Self {
        native_width: 3_840,
        native_height: 2_160,
        bayer_pattern: BayerPattern::Rggb,
        acescg_to_sensor: [[0.72, 0.21, 0.07], [0.10, 0.82, 0.08], [0.03, 0.16, 0.81]],
        saturation_illuminance_seconds: LinearRgb::new(2.4, 2.4, 2.4),
        full_well_electrons: 45_000.0,
        dark_current_electrons_per_second: 0.1,
        read_noise_electrons_rms: 2.0,
        analog_gain: 1.0,
        adc_bits: 14,
    };

    pub fn validate(self) -> Result<Self, SensorError> {
        if self.native_width == 0 || self.native_height == 0 {
            return Err(SensorError::InvalidNativeRaster);
        }
        if !matrix_is_valid(self.acescg_to_sensor) {
            return Err(SensorError::InvalidColorMatrix);
        }
        if [
            self.saturation_illuminance_seconds.r,
            self.saturation_illuminance_seconds.g,
            self.saturation_illuminance_seconds.b,
        ]
        .into_iter()
        .any(|value| !value.is_finite() || value <= 0.0)
        {
            return Err(SensorError::InvalidSaturationExposure);
        }
        if !self.full_well_electrons.is_finite()
            || !(1.0..=100_000_000.0).contains(&self.full_well_electrons)
        {
            return Err(SensorError::InvalidFullWell);
        }
        if !self.dark_current_electrons_per_second.is_finite()
            || self.dark_current_electrons_per_second < 0.0
        {
            return Err(SensorError::InvalidDarkCurrent);
        }
        if !self.read_noise_electrons_rms.is_finite() || self.read_noise_electrons_rms < 0.0 {
            return Err(SensorError::InvalidReadNoise);
        }
        if !self.analog_gain.is_finite() || self.analog_gain <= 0.0 {
            return Err(SensorError::InvalidAnalogGain);
        }
        if !(8..=16).contains(&self.adc_bits) {
            return Err(SensorError::InvalidAdcBits);
        }
        Ok(self)
    }
}

impl IntegratedOpticalExposure {
    pub fn validate(&self) -> Result<(), SensorError> {
        if self.width == 0 || self.height == 0 {
            return Err(SensorError::EmptyRaster);
        }
        if self.acescg_illuminance_seconds.len() as u64
            != u64::from(self.width) * u64::from(self.height)
        {
            return Err(SensorError::PixelCountMismatch);
        }
        if !self.duration_seconds.is_finite() || self.duration_seconds <= 0.0 {
            return Err(SensorError::InvalidDuration);
        }
        if self
            .acescg_illuminance_seconds
            .iter()
            .any(|pixel| !pixel.r.is_finite() || !pixel.g.is_finite() || !pixel.b.is_finite())
        {
            return Err(SensorError::NonFiniteExposure);
        }
        Ok(())
    }
}

pub fn expose_raw(
    profile: SensorProfile,
    exposure: &IntegratedOpticalExposure,
    identity: CaptureIdentity,
) -> Result<RawSensorRaster, SensorError> {
    let profile = profile.validate()?;
    exposure.validate()?;
    if exposure.width != u32::from(profile.native_width)
        || exposure.height != u32::from(profile.native_height)
    {
        return Err(SensorError::RasterProfileMismatch);
    }
    let maximum_code = (1_u32 << profile.adc_bits) - 1;
    let mut codes = Vec::with_capacity(exposure.acescg_illuminance_seconds.len());
    let mut full_well_clipped_mask = Vec::with_capacity(exposure.acescg_illuminance_seconds.len());
    let mut adc_clipped_mask = Vec::with_capacity(exposure.acescg_illuminance_seconds.len());
    for (index, acescg) in exposure
        .acescg_illuminance_seconds
        .iter()
        .copied()
        .enumerate()
    {
        let x = (index % exposure.width as usize) as u32;
        let y = (index / exposure.width as usize) as u32;
        let channel = profile.bayer_pattern.channel_at(x, y);
        let sensor_rgb = mat_vec(profile.acescg_to_sensor, acescg);
        let native_exposure = [sensor_rgb.r, sensor_rgb.g, sensor_rgb.b][channel].max(0.0);
        let saturation = [
            profile.saturation_illuminance_seconds.r,
            profile.saturation_illuminance_seconds.g,
            profile.saturation_illuminance_seconds.b,
        ][channel];
        let ideal_photoelectrons = f64::from(native_exposure) / f64::from(saturation)
            * f64::from(profile.full_well_electrons);
        let key = pixel_noise_key(identity, index as u64);
        let photoelectrons = sample_poisson(ideal_photoelectrons, key);
        let dark_electrons = sample_poisson(
            f64::from(profile.dark_current_electrons_per_second)
                * f64::from(exposure.duration_seconds),
            key ^ 0xA076_1D64_78BD_642F,
        );
        let read_electrons = f64::from(profile.read_noise_electrons_rms)
            * gaussian_approximation(key ^ 0xE703_7ED1_A0B4_28DB);
        let full_well = f64::from(profile.full_well_electrons);
        let collected_electrons = photoelectrons + dark_electrons;
        let full_well_clipped = collected_electrons >= full_well;
        let well_electrons = collected_electrons.clamp(0.0, full_well);
        let post_read_electrons = (well_electrons + read_electrons).max(0.0);
        let normalized = post_read_electrons * f64::from(profile.analog_gain) / full_well;
        let adc_clipped = normalized >= 1.0;
        let code = (normalized.clamp(0.0, 1.0) * f64::from(maximum_code)).round() as u16;
        codes.push(code);
        full_well_clipped_mask.push(full_well_clipped);
        adc_clipped_mask.push(adc_clipped);
    }
    Ok(RawSensorRaster {
        width: exposure.width,
        height: exposure.height,
        bayer_pattern: profile.bayer_pattern,
        adc_bits: profile.adc_bits,
        codes,
        full_well_clipped: full_well_clipped_mask,
        adc_clipped: adc_clipped_mask,
    })
}

pub fn expose_raw_region(
    profile: SensorProfile,
    exposure: &IntegratedOpticalExposure,
    identity: CaptureIdentity,
    region: SensorRegion,
) -> Result<RawSensorRegion, SensorError> {
    let profile = profile.validate()?;
    exposure.validate()?;
    region.validate(profile)?;
    if exposure.width != u32::from(region.width) || exposure.height != u32::from(region.height) {
        return Err(SensorError::RasterProfileMismatch);
    }
    let maximum_code = (1_u32 << profile.adc_bits) - 1;
    let mut codes = Vec::with_capacity(exposure.acescg_illuminance_seconds.len());
    let mut full_well_clipped_mask = Vec::with_capacity(exposure.acescg_illuminance_seconds.len());
    let mut adc_clipped_mask = Vec::with_capacity(exposure.acescg_illuminance_seconds.len());
    for (local_index, acescg) in exposure
        .acescg_illuminance_seconds
        .iter()
        .copied()
        .enumerate()
    {
        let local_x = local_index % usize::from(region.width);
        let local_y = local_index / usize::from(region.width);
        let x = u32::from(region.origin_x) + local_x as u32;
        let y = u32::from(region.origin_y) + local_y as u32;
        let channel = profile.bayer_pattern.channel_at(x, y);
        let sensor_rgb = mat_vec(profile.acescg_to_sensor, acescg);
        let native_exposure = [sensor_rgb.r, sensor_rgb.g, sensor_rgb.b][channel].max(0.0);
        let saturation = [
            profile.saturation_illuminance_seconds.r,
            profile.saturation_illuminance_seconds.g,
            profile.saturation_illuminance_seconds.b,
        ][channel];
        let ideal_photoelectrons = f64::from(native_exposure) / f64::from(saturation)
            * f64::from(profile.full_well_electrons);
        let global_index = u64::from(y) * u64::from(profile.native_width) + u64::from(x);
        let key = pixel_noise_key(identity, global_index);
        let photoelectrons = sample_poisson(ideal_photoelectrons, key);
        let dark_electrons = sample_poisson(
            f64::from(profile.dark_current_electrons_per_second)
                * f64::from(exposure.duration_seconds),
            key ^ 0xA076_1D64_78BD_642F,
        );
        let read_electrons = f64::from(profile.read_noise_electrons_rms)
            * gaussian_approximation(key ^ 0xE703_7ED1_A0B4_28DB);
        let full_well = f64::from(profile.full_well_electrons);
        let collected_electrons = photoelectrons + dark_electrons;
        let full_well_clipped = collected_electrons >= full_well;
        let well_electrons = collected_electrons.clamp(0.0, full_well);
        let post_read_electrons = (well_electrons + read_electrons).max(0.0);
        let normalized = post_read_electrons * f64::from(profile.analog_gain) / full_well;
        let adc_clipped = normalized >= 1.0;
        codes.push((normalized.clamp(0.0, 1.0) * f64::from(maximum_code)).round() as u16);
        full_well_clipped_mask.push(full_well_clipped);
        adc_clipped_mask.push(adc_clipped);
    }
    Ok(RawSensorRegion {
        sensor_width: profile.native_width,
        sensor_height: profile.native_height,
        region,
        bayer_pattern: profile.bayer_pattern,
        adc_bits: profile.adc_bits,
        codes,
        full_well_clipped: full_well_clipped_mask,
        adc_clipped: adc_clipped_mask,
    })
}

impl SensorRegion {
    pub fn full(profile: SensorProfile) -> Self {
        Self {
            origin_x: 0,
            origin_y: 0,
            width: profile.native_width,
            height: profile.native_height,
        }
    }

    pub fn validate(self, profile: SensorProfile) -> Result<Self, SensorError> {
        let end_x = u32::from(self.origin_x) + u32::from(self.width);
        let end_y = u32::from(self.origin_y) + u32::from(self.height);
        if self.width == 0
            || self.height == 0
            || end_x > u32::from(profile.native_width)
            || end_y > u32::from(profile.native_height)
        {
            return Err(SensorError::InvalidSensorRegion);
        }
        Ok(self)
    }

    pub fn expanded_for_demosaic(self, profile: SensorProfile) -> Self {
        let origin_x = self.origin_x.saturating_sub(1);
        let origin_y = self.origin_y.saturating_sub(1);
        let end_x = (u32::from(self.origin_x) + u32::from(self.width) + 1)
            .min(u32::from(profile.native_width)) as u16;
        let end_y = (u32::from(self.origin_y) + u32::from(self.height) + 1)
            .min(u32::from(profile.native_height)) as u16;
        Self {
            origin_x,
            origin_y,
            width: end_x - origin_x,
            height: end_y - origin_y,
        }
    }
}

impl BayerPattern {
    pub fn channel_at(self, x: u32, y: u32) -> usize {
        let parity = ((y & 1) << 1) | (x & 1);
        match self {
            Self::Rggb => [0, 1, 1, 2][parity as usize],
            Self::Bggr => [2, 1, 1, 0][parity as usize],
            Self::Grbg => [1, 0, 2, 1][parity as usize],
            Self::Gbrg => [1, 2, 0, 1][parity as usize],
        }
    }
}

fn mat_vec(matrix: [[f32; 3]; 3], value: LinearRgb) -> LinearRgb {
    LinearRgb::new(
        matrix[0][0] * value.r + matrix[0][1] * value.g + matrix[0][2] * value.b,
        matrix[1][0] * value.r + matrix[1][1] * value.g + matrix[1][2] * value.b,
        matrix[2][0] * value.r + matrix[2][1] * value.g + matrix[2][2] * value.b,
    )
}

fn matrix_is_valid(matrix: [[f32; 3]; 3]) -> bool {
    if matrix
        .into_iter()
        .flatten()
        .any(|value| !value.is_finite() || value.abs() > 16.0)
    {
        return false;
    }
    let Some(inverse) = inverse3(matrix) else {
        return false;
    };
    let white_response = mat_vec(matrix, LinearRgb::new(1.0, 1.0, 1.0));
    [white_response.r, white_response.g, white_response.b]
        .into_iter()
        .all(|value| value.is_finite() && value > 0.0)
        && matrix_norm(matrix) * matrix_norm(inverse) <= 10_000.0
}

fn matrix_norm(matrix: [[f32; 3]; 3]) -> f32 {
    matrix
        .into_iter()
        .map(|row| row.into_iter().map(f32::abs).sum::<f32>())
        .fold(0.0, f32::max)
}

fn inverse3(matrix: [[f32; 3]; 3]) -> Option<[[f32; 3]; 3]> {
    let determinant = matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1])
        - matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0])
        + matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if !determinant.is_finite() || determinant.abs() < 1.0e-8 {
        return None;
    }
    let reciprocal = determinant.recip();
    Some([
        [
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * reciprocal,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * reciprocal,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * reciprocal,
        ],
        [
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * reciprocal,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * reciprocal,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * reciprocal,
        ],
        [
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * reciprocal,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * reciprocal,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * reciprocal,
        ],
    ])
}

fn pixel_noise_key(identity: CaptureIdentity, pixel_index: u64) -> u64 {
    identity.noise_seed
        ^ (identity.frame_index as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ pixel_index.wrapping_mul(0xD1B5_4A32_D192_ED03)
}

fn splitmix64(mut value: u64) -> u64 {
    value = value.wrapping_add(0x9E37_79B9_7F4A_7C15);
    value = (value ^ (value >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    value ^ (value >> 31)
}

fn uniform(key: u64, sample: u64) -> f64 {
    let bits = splitmix64(key ^ sample.wrapping_mul(0xA076_1D64_78BD_642F)) >> 11;
    (bits as f64 + 0.5) * (1.0 / ((1_u64 << 53) as f64))
}

fn gaussian_approximation(key: u64) -> f64 {
    (0..12).map(|sample| uniform(key, sample)).sum::<f64>() - 6.0
}

fn sample_poisson(lambda: f64, key: u64) -> f64 {
    if lambda <= 0.0 {
        return 0.0;
    }
    if lambda >= 30.0 {
        return (lambda + lambda.sqrt() * gaussian_approximation(key))
            .round()
            .max(0.0);
    }
    let threshold = (-lambda).exp();
    let mut product = 1.0;
    let mut count = 0_u64;
    loop {
        product *= uniform(key, count);
        if product <= threshold {
            return count as f64;
        }
        count += 1;
    }
}

impl fmt::Display for SensorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::EmptyRaster => "integrated optical exposure raster must be non-empty",
            Self::InvalidNativeRaster => "sensor native photosite raster must be non-empty",
            Self::RasterProfileMismatch => {
                "integrated optical exposure raster must match the sensor native photosite raster"
            }
            Self::PixelCountMismatch => {
                "integrated optical exposure pixel count does not match its raster"
            }
            Self::NonFiniteExposure => "integrated optical exposure contains a non-finite value",
            Self::InvalidDuration => "sensor exposure duration must be finite and positive",
            Self::InvalidColorMatrix => {
                "sensor color matrix must be finite, invertible and well-conditioned"
            }
            Self::InvalidSaturationExposure => {
                "sensor saturation exposures must be finite and positive"
            }
            Self::InvalidFullWell => {
                "sensor full-well capacity is outside the supported electron range"
            }
            Self::InvalidDarkCurrent => "sensor dark current must be finite and non-negative",
            Self::InvalidReadNoise => "sensor read noise must be finite and non-negative",
            Self::InvalidAnalogGain => "sensor analog gain must be finite and positive",
            Self::InvalidAdcBits => "sensor ADC precision must be between 8 and 16 bits",
            Self::InvalidSensorRegion => "sensor region must lie inside the authored native raster",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for SensorError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn noiseless_profile(native_width: u16, native_height: u16) -> SensorProfile {
        SensorProfile {
            native_width,
            native_height,
            acescg_to_sensor: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            dark_current_electrons_per_second: 0.0,
            read_noise_electrons_rms: 0.0,
            ..SensorProfile::REFERENCE
        }
    }

    #[test]
    fn bayer_patterns_select_one_physical_photosite_channel() {
        assert_eq!(BayerPattern::Rggb.channel_at(0, 0), 0);
        assert_eq!(BayerPattern::Rggb.channel_at(1, 0), 1);
        assert_eq!(BayerPattern::Rggb.channel_at(0, 1), 1);
        assert_eq!(BayerPattern::Rggb.channel_at(1, 1), 2);
        assert_eq!(BayerPattern::Bggr.channel_at(0, 0), 2);
    }

    #[test]
    fn noiseless_exposure_quantizes_native_cfa_and_saturates() {
        let profile = noiseless_profile(2, 2);
        let half = profile.saturation_illuminance_seconds.r * 0.5;
        let exposure = IntegratedOpticalExposure {
            width: 2,
            height: 2,
            duration_seconds: 1.0 / 48.0,
            acescg_illuminance_seconds: vec![
                LinearRgb::new(half, 0.0, 0.0),
                LinearRgb::new(0.0, half, 0.0),
                LinearRgb::new(0.0, half, 0.0),
                LinearRgb::new(0.0, 0.0, profile.saturation_illuminance_seconds.b * 2.0),
            ],
        };
        let raw = expose_raw(
            profile,
            &exposure,
            CaptureIdentity {
                noise_seed: 7,
                frame_index: 12,
            },
        )
        .expect("valid RAW capture");
        let half_code = ((1_u32 << profile.adc_bits) - 1) / 2;
        for code in &raw.codes[..3] {
            assert!((i64::from(*code) - i64::from(half_code)).abs() <= 256);
        }
        assert_eq!(raw.codes[3], (1_u16 << profile.adc_bits) - 1);
        assert_eq!(raw.full_well_clipped, vec![false, false, false, true]);
        assert_eq!(raw.adc_clipped, vec![false, false, false, true]);
    }

    #[test]
    fn calibrated_five_hundred_nit_screen_exposure_preserves_full_well_headroom() {
        let profile = noiseless_profile(2, 2);
        let white_exposure = 500.0 * core::f32::consts::FRAC_PI_4 / 16.0 / 48.0;
        let exposure = IntegratedOpticalExposure {
            width: 2,
            height: 2,
            duration_seconds: 1.0 / 48.0,
            acescg_illuminance_seconds: vec![
                LinearRgb::new(
                    white_exposure,
                    white_exposure,
                    white_exposure,
                );
                4
            ],
        };
        let raw = expose_raw(
            profile,
            &exposure,
            CaptureIdentity {
                noise_seed: 1,
                frame_index: 0,
            },
        )
        .expect("calibrated RAW capture");
        assert!(raw.full_well_clipped.iter().all(|clipped| !clipped));
        assert!(raw.adc_clipped.iter().all(|clipped| !clipped));
    }

    #[test]
    fn deterministic_noise_changes_only_with_capture_identity() {
        let profile = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let exposure = IntegratedOpticalExposure {
            width: 8,
            height: 8,
            duration_seconds: 1.0 / 48.0,
            acescg_illuminance_seconds: vec![LinearRgb::new(0.01, 0.01, 0.01); 64],
        };
        let first = expose_raw(
            profile,
            &exposure,
            CaptureIdentity {
                noise_seed: 99,
                frame_index: 3,
            },
        )
        .expect("first capture");
        let repeated = expose_raw(
            profile,
            &exposure,
            CaptureIdentity {
                noise_seed: 99,
                frame_index: 3,
            },
        )
        .expect("repeated capture");
        let next = expose_raw(
            profile,
            &exposure,
            CaptureIdentity {
                noise_seed: 99,
                frame_index: 4,
            },
        )
        .expect("next capture");
        assert_eq!(first, repeated);
        assert_ne!(first.codes, next.codes);
    }

    #[test]
    fn region_capture_preserves_global_cfa_phase_and_noise_identity() {
        let profile = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let identity = CaptureIdentity {
            noise_seed: 19,
            frame_index: 3,
        };
        let pixel = LinearRgb::new(0.01, 0.012, 0.014);
        let full_exposure = IntegratedOpticalExposure {
            width: 8,
            height: 8,
            duration_seconds: 1.0 / 48.0,
            acescg_illuminance_seconds: vec![pixel; 64],
        };
        let full = expose_raw(profile, &full_exposure, identity).expect("full capture");
        let region = SensorRegion {
            origin_x: 3,
            origin_y: 2,
            width: 3,
            height: 4,
        };
        let region_exposure = IntegratedOpticalExposure {
            width: 3,
            height: 4,
            duration_seconds: 1.0 / 48.0,
            acescg_illuminance_seconds: vec![pixel; 12],
        };
        let cropped =
            expose_raw_region(profile, &region_exposure, identity, region).expect("region capture");
        for local_y in 0..usize::from(region.height) {
            for local_x in 0..usize::from(region.width) {
                let full_index = (usize::from(region.origin_y) + local_y) * 8
                    + usize::from(region.origin_x)
                    + local_x;
                let region_index = local_y * usize::from(region.width) + local_x;
                assert_eq!(cropped.codes[region_index], full.codes[full_index]);
                assert_eq!(
                    cropped.full_well_clipped[region_index],
                    full.full_well_clipped[full_index]
                );
                assert_eq!(
                    cropped.adc_clipped[region_index],
                    full.adc_clipped[full_index]
                );
            }
        }
    }

    #[test]
    fn full_well_clips_before_read_noise_and_analog_gain() {
        let mut profile = noiseless_profile(1, 1);
        profile.analog_gain = 0.5;
        let exposure = IntegratedOpticalExposure {
            width: 1,
            height: 1,
            duration_seconds: 1.0,
            acescg_illuminance_seconds: vec![LinearRgb::new(
                profile.saturation_illuminance_seconds.r * 2.0,
                0.0,
                0.0,
            )],
        };
        let raw = expose_raw(
            profile,
            &exposure,
            CaptureIdentity {
                noise_seed: 1,
                frame_index: 0,
            },
        )
        .expect("valid saturated capture");
        let half_scale = ((1_u32 << profile.adc_bits) - 1) / 2;
        assert!((i64::from(raw.codes[0]) - i64::from(half_scale)).abs() <= 1);
        assert_eq!(raw.full_well_clipped, vec![true]);
        assert_eq!(raw.adc_clipped, vec![false]);
    }

    #[test]
    fn invalid_profiles_and_exposures_fail_before_capture() {
        let mut invalid = SensorProfile::REFERENCE;
        invalid.native_width = 0;
        assert_eq!(invalid.validate(), Err(SensorError::InvalidNativeRaster));
        invalid = SensorProfile::REFERENCE;
        invalid.acescg_to_sensor[2] = invalid.acescg_to_sensor[1];
        assert_eq!(invalid.validate(), Err(SensorError::InvalidColorMatrix));
        invalid = SensorProfile::REFERENCE;
        invalid.full_well_electrons = f32::NAN;
        assert_eq!(invalid.validate(), Err(SensorError::InvalidFullWell));
        invalid = SensorProfile::REFERENCE;
        invalid.acescg_to_sensor = [[-1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.0, 0.0, -1.0]];
        assert_eq!(invalid.validate(), Err(SensorError::InvalidColorMatrix));
        let exposure = IntegratedOpticalExposure {
            width: 1,
            height: 1,
            duration_seconds: 0.0,
            acescg_illuminance_seconds: vec![LinearRgb::new(0.0, 0.0, 0.0)],
        };
        assert_eq!(exposure.validate(), Err(SensorError::InvalidDuration));

        let mismatched = IntegratedOpticalExposure {
            width: 1,
            height: 1,
            duration_seconds: 1.0,
            acescg_illuminance_seconds: vec![LinearRgb::new(0.0, 0.0, 0.0)],
        };
        assert_eq!(
            expose_raw(
                SensorProfile::REFERENCE,
                &mismatched,
                CaptureIdentity {
                    noise_seed: 0,
                    frame_index: 0,
                },
            ),
            Err(SensorError::RasterProfileMismatch)
        );
    }
}
