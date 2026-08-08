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
    pub bloom: SensorBloomProfile,
}

/// Lateral charge coupling and non-recursive full-well overflow transfer.
/// Both operations are defined on global photosite coordinates.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SensorBloomProfile {
    pub character_strength: f32,
    /// Energy-preserving four-neighbour coupling applied before well clipping.
    pub crosstalk_fraction: f32,
    /// Fraction of charge above full well transferred to four neighbours.
    pub overflow_transfer_fraction: f32,
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

#[derive(Clone, Debug, PartialEq)]
pub struct RawSensorRaster {
    pub width: u32,
    pub height: u32,
    pub bayer_pattern: BayerPattern,
    pub adc_bits: u8,
    /// Complete profile identity used for this exposure; RAW must not be developed by a merely
    /// dimension-compatible sensor profile.
    pub sensor_profile: SensorProfile,
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

#[derive(Clone, Debug, PartialEq)]
pub struct RawSensorRegion {
    pub sensor_width: u16,
    pub sensor_height: u16,
    pub region: SensorRegion,
    pub bayer_pattern: BayerPattern,
    pub adc_bits: u8,
    pub sensor_profile: SensorProfile,
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
    InvalidNoiseAmount,
    InvalidAnalogGain,
    InvalidAdcBits,
    InvalidBloom,
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
        bloom: SensorBloomProfile::REFERENCE,
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
        self.bloom.validate()?;
        Ok(self)
    }
}

impl SensorBloomProfile {
    pub const NEUTRAL: Self = Self {
        character_strength: 0.0,
        crosstalk_fraction: 0.0,
        overflow_transfer_fraction: 0.0,
    };
    pub const REFERENCE: Self = Self {
        character_strength: 1.0,
        crosstalk_fraction: 0.012,
        overflow_transfer_fraction: 0.22,
    };
    pub const LARGE_CAMERA: Self = Self {
        character_strength: 1.0,
        crosstalk_fraction: 0.006,
        overflow_transfer_fraction: 0.12,
    };
    pub const SMALL_PIXEL_PHONE: Self = Self {
        character_strength: 1.0,
        crosstalk_fraction: 0.020,
        overflow_transfer_fraction: 0.30,
    };

    pub fn validate(self) -> Result<Self, SensorError> {
        if !self.character_strength.is_finite()
            || !(0.0..=4.0).contains(&self.character_strength)
            || !self.crosstalk_fraction.is_finite()
            || !(0.0..=0.20).contains(&self.crosstalk_fraction)
            || !self.overflow_transfer_fraction.is_finite()
            || !(0.0..=1.0).contains(&self.overflow_transfer_fraction)
            || self.crosstalk_fraction * self.character_strength > 0.80
            || self.overflow_transfer_fraction * self.character_strength > 1.0
        {
            return Err(SensorError::InvalidBloom);
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
    expose_raw_with_noise_amount(profile, exposure, identity, 1.0)
}

/// Sensor oracle with a continuous stochastic contribution. Zero preserves the
/// deterministic ideal charge before well/ADC quantization, one is the
/// historical calibrated shot+dark+read model, and values above one extend the
/// same sampled deviation without changing CFA topology.
pub fn expose_raw_with_noise_amount(
    profile: SensorProfile,
    exposure: &IntegratedOpticalExposure,
    identity: CaptureIdentity,
    noise_amount: f32,
) -> Result<RawSensorRaster, SensorError> {
    let profile = profile.validate()?;
    let full = SensorRegion::full(profile);
    let region =
        expose_raw_region_with_noise_amount(profile, exposure, identity, full, full, noise_amount)?;
    Ok(RawSensorRaster {
        width: u32::from(region.region.width),
        height: u32::from(region.region.height),
        bayer_pattern: region.bayer_pattern,
        adc_bits: region.adc_bits,
        sensor_profile: region.sensor_profile,
        codes: region.codes,
        full_well_clipped: region.full_well_clipped,
        adc_clipped: region.adc_clipped,
    })
}

fn redistribute_sensor_charge(
    input: &[f64],
    width: u32,
    height: u32,
    full_well_electrons: f32,
    profile: SensorBloomProfile,
) -> Vec<f64> {
    if profile.character_strength == 0.0 {
        return input.to_vec();
    }
    let coupling = f64::from(profile.crosstalk_fraction * profile.character_strength) / 4.0;
    let transfer = f64::from(profile.overflow_transfer_fraction * profile.character_strength);
    let mut coupled = input.to_vec();
    // Pairwise exchange across each undirected edge conserves charge exactly
    // apart from normal floating-point addition.
    for y in 0..height {
        for x in 0..width {
            let index = (y * width + x) as usize;
            if x + 1 < width {
                let other = (y * width + x + 1) as usize;
                let delta = (input[index] - input[other]) * coupling;
                coupled[index] -= delta;
                coupled[other] += delta;
            }
            if y + 1 < height {
                let other = ((y + 1) * width + x) as usize;
                let delta = (input[index] - input[other]) * coupling;
                coupled[index] -= delta;
                coupled[other] += delta;
            }
        }
    }
    let full_well = f64::from(full_well_electrons);
    let mut bloomed = coupled
        .iter()
        .map(|charge| charge.min(full_well))
        .collect::<Vec<_>>();
    for y in 0..height {
        for x in 0..width {
            let index = (y * width + x) as usize;
            let overflow = (coupled[index] - full_well).max(0.0) * transfer;
            if overflow == 0.0 {
                continue;
            }
            let neighbours = [
                x.checked_sub(1).map(|nx| (nx, y)),
                (x + 1 < width).then_some((x + 1, y)),
                y.checked_sub(1).map(|ny| (x, ny)),
                (y + 1 < height).then_some((x, y + 1)),
            ];
            let count = neighbours.iter().flatten().count() as f64;
            for (nx, ny) in neighbours.into_iter().flatten() {
                bloomed[(ny * width + nx) as usize] += overflow / count;
            }
        }
    }
    bloomed
}

pub fn expose_raw_region(
    profile: SensorProfile,
    exposure: &IntegratedOpticalExposure,
    identity: CaptureIdentity,
    exposure_region: SensorRegion,
    output_region: SensorRegion,
) -> Result<RawSensorRegion, SensorError> {
    expose_raw_region_with_noise_amount(
        profile,
        exposure,
        identity,
        exposure_region,
        output_region,
        1.0,
    )
}

pub fn expose_raw_region_with_noise_amount(
    profile: SensorProfile,
    exposure: &IntegratedOpticalExposure,
    identity: CaptureIdentity,
    exposure_region: SensorRegion,
    output_region: SensorRegion,
    noise_amount: f32,
) -> Result<RawSensorRegion, SensorError> {
    let profile = profile.validate()?;
    exposure.validate()?;
    exposure_region.validate(profile)?;
    output_region.validate(profile)?;
    if !noise_amount.is_finite() || !(0.0..=4.0).contains(&noise_amount) {
        return Err(SensorError::InvalidNoiseAmount);
    }
    if exposure.width != u32::from(exposure_region.width)
        || exposure.height != u32::from(exposure_region.height)
        || !exposure_region.contains(output_region)
    {
        return Err(SensorError::RasterProfileMismatch);
    }
    let support_count = exposure.acescg_illuminance_seconds.len();
    let mut collected = Vec::with_capacity(support_count);
    let mut read = Vec::with_capacity(support_count);
    for (local_index, acescg) in exposure
        .acescg_illuminance_seconds
        .iter()
        .copied()
        .enumerate()
    {
        let local_x = local_index % usize::from(exposure_region.width);
        let local_y = local_index / usize::from(exposure_region.width);
        let x = u32::from(exposure_region.origin_x) + local_x as u32;
        let y = u32::from(exposure_region.origin_y) + local_y as u32;
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
        let sampled_photoelectrons = sample_poisson(ideal_photoelectrons, key);
        let photoelectrons = ideal_photoelectrons
            + f64::from(noise_amount) * (sampled_photoelectrons - ideal_photoelectrons);
        let dark_electrons = f64::from(noise_amount)
            * sample_poisson(
                f64::from(profile.dark_current_electrons_per_second)
                    * f64::from(exposure.duration_seconds),
                key ^ 0xA076_1D64_78BD_642F,
            );
        let read_electrons = f64::from(noise_amount)
            * f64::from(profile.read_noise_electrons_rms)
            * gaussian_approximation(key ^ 0xE703_7ED1_A0B4_28DB);
        collected.push((photoelectrons + dark_electrons).max(0.0));
        read.push(read_electrons);
    }
    let collected = redistribute_sensor_charge(
        &collected,
        u32::from(exposure_region.width),
        u32::from(exposure_region.height),
        profile.full_well_electrons,
        profile.bloom,
    );
    let maximum_code = (1_u32 << profile.adc_bits) - 1;
    let full_well = f64::from(profile.full_well_electrons);
    let output_count = usize::from(output_region.width) * usize::from(output_region.height);
    let mut codes = Vec::with_capacity(output_count);
    let mut full_well_clipped_mask = Vec::with_capacity(output_count);
    let mut adc_clipped_mask = Vec::with_capacity(output_count);
    for output_y in 0..u32::from(output_region.height) {
        for output_x in 0..u32::from(output_region.width) {
            let support_x =
                u32::from(output_region.origin_x) + output_x - u32::from(exposure_region.origin_x);
            let support_y =
                u32::from(output_region.origin_y) + output_y - u32::from(exposure_region.origin_y);
            let index = (support_y * u32::from(exposure_region.width) + support_x) as usize;
            let collected_electrons = collected[index];
            let full_well_clipped = collected_electrons >= full_well;
            let well_electrons = collected_electrons.clamp(0.0, full_well);
            let post_read_electrons = (well_electrons + read[index]).max(0.0);
            let normalized = post_read_electrons * f64::from(profile.analog_gain) / full_well;
            let adc_clipped = normalized >= 1.0;
            codes.push((normalized.clamp(0.0, 1.0) * f64::from(maximum_code)).round() as u16);
            full_well_clipped_mask.push(full_well_clipped);
            adc_clipped_mask.push(adc_clipped);
        }
    }
    Ok(RawSensorRegion {
        sensor_width: profile.native_width,
        sensor_height: profile.native_height,
        region: output_region,
        bayer_pattern: profile.bayer_pattern,
        adc_bits: profile.adc_bits,
        sensor_profile: profile,
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
        self.expanded(profile, 3)
    }

    pub fn expanded_for_sensor_bloom(self, profile: SensorProfile) -> Self {
        self.expanded(profile, 2)
    }

    fn expanded(self, profile: SensorProfile, radius: u16) -> Self {
        let origin_x = self.origin_x.saturating_sub(radius);
        let origin_y = self.origin_y.saturating_sub(radius);
        let end_x = (u32::from(self.origin_x) + u32::from(self.width) + u32::from(radius))
            .min(u32::from(profile.native_width)) as u16;
        let end_y = (u32::from(self.origin_y) + u32::from(self.height) + u32::from(radius))
            .min(u32::from(profile.native_height)) as u16;
        Self {
            origin_x,
            origin_y,
            width: end_x - origin_x,
            height: end_y - origin_y,
        }
    }

    fn contains(self, other: Self) -> bool {
        other.origin_x >= self.origin_x
            && other.origin_y >= self.origin_y
            && u32::from(other.origin_x) + u32::from(other.width)
                <= u32::from(self.origin_x) + u32::from(self.width)
            && u32::from(other.origin_y) + u32::from(other.height)
                <= u32::from(self.origin_y) + u32::from(self.height)
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
            Self::InvalidNoiseAmount => "sensor noise amount must be finite and inside 0..=4",
            Self::InvalidAnalogGain => "sensor analog gain must be finite and positive",
            Self::InvalidAdcBits => "sensor ADC precision must be between 8 and 16 bits",
            Self::InvalidBloom => "sensor crosstalk/bloom profile is outside its physical bounds",
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
            bloom: SensorBloomProfile::NEUTRAL,
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
    fn continuous_noise_zero_is_seed_independent_one_is_historical_and_above_one_is_bounded() {
        let profile = noiseless_profile(2, 2);
        let exposure = IntegratedOpticalExposure {
            width: 2,
            height: 2,
            duration_seconds: 1.0 / 48.0,
            acescg_illuminance_seconds: vec![LinearRgb::new(0.7, 0.5, 0.3); 4],
        };
        let identity = CaptureIdentity {
            noise_seed: 7,
            frame_index: 3,
        };
        let zero =
            expose_raw_with_noise_amount(profile, &exposure, identity, 0.0).expect("zero noise");
        let other_seed = expose_raw_with_noise_amount(
            profile,
            &exposure,
            CaptureIdentity {
                noise_seed: 99,
                frame_index: 3,
            },
            0.0,
        )
        .expect("zero noise other seed");
        assert_eq!(zero, other_seed);
        assert_eq!(
            expose_raw_with_noise_amount(profile, &exposure, identity, 1.0)
                .expect("calibrated noise"),
            expose_raw(profile, &exposure, identity).expect("historical noise")
        );
        let artistic = expose_raw_with_noise_amount(profile, &exposure, identity, 2.5)
            .expect("artistic noise");
        assert_eq!(artistic.codes.len(), 4);
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
        let support = region.expanded_for_sensor_bloom(profile);
        let region_exposure = IntegratedOpticalExposure {
            width: u32::from(support.width),
            height: u32::from(support.height),
            duration_seconds: 1.0 / 48.0,
            acescg_illuminance_seconds: vec![
                pixel;
                usize::from(support.width)
                    * usize::from(support.height)
            ],
        };
        let cropped = expose_raw_region(profile, &region_exposure, identity, support, region)
            .expect("region capture");
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
    fn parallel_region_exposure_is_thread_count_invariant() {
        let profile = SensorProfile {
            native_width: 64,
            native_height: 48,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 7,
            origin_y: 5,
            width: 41,
            height: 31,
        };
        let exposure = IntegratedOpticalExposure {
            width: u32::from(region.width),
            height: u32::from(region.height),
            duration_seconds: 1.0 / 47.952,
            acescg_illuminance_seconds: (0..usize::from(region.width) * usize::from(region.height))
                .map(|index| {
                    let level = 0.002 + (index % 97) as f32 * 0.000_31;
                    LinearRgb::new(level, level * 0.83, level * 1.17)
                })
                .collect(),
        };
        let identity = CaptureIdentity {
            noise_seed: 0x5A17,
            frame_index: 43,
        };
        let expose_with_threads = |threads| {
            rayon::ThreadPoolBuilder::new()
                .num_threads(threads)
                .build()
                .unwrap()
                .install(|| {
                    expose_raw_region(profile, &exposure, identity, region, region).unwrap()
                })
        };
        assert_eq!(expose_with_threads(1), expose_with_threads(4));
    }

    #[test]
    fn sensor_bloom_zero_is_exact_and_calibrated_bloom_reaches_neighbours() {
        let mut neutral = noiseless_profile(5, 5);
        neutral.bloom = SensorBloomProfile::NEUTRAL;
        let mut calibrated = neutral;
        calibrated.bloom = SensorBloomProfile::REFERENCE;
        let mut pixels = vec![LinearRgb::new(0.0, 0.0, 0.0); 25];
        pixels[12] = LinearRgb::new(2.0, 2.0, 2.0);
        let exposure = IntegratedOpticalExposure {
            width: 5,
            height: 5,
            duration_seconds: 1.0,
            acescg_illuminance_seconds: pixels,
        };
        let identity = CaptureIdentity {
            noise_seed: 1,
            frame_index: 0,
        };
        let baseline = expose_raw_with_noise_amount(neutral, &exposure, identity, 0.0)
            .expect("neutral capture");
        let bloomed = expose_raw_with_noise_amount(calibrated, &exposure, identity, 0.0)
            .expect("bloomed capture");
        assert_eq!(baseline.codes[7], 0);
        assert!(bloomed.codes[7] > baseline.codes[7]);
        assert!(bloomed.codes[11] > baseline.codes[11]);
        assert!(bloomed.codes[13] > baseline.codes[13]);
        assert!(bloomed.codes[17] > baseline.codes[17]);
    }

    #[test]
    fn bloom_region_with_two_pixel_support_is_exactly_the_full_sensor_crop() {
        let mut profile = noiseless_profile(9, 9);
        profile.bloom = SensorBloomProfile::REFERENCE;
        let mut pixels = vec![LinearRgb::new(0.01, 0.01, 0.01); 81];
        pixels[4 * 9 + 4] = LinearRgb::new(1.8, 1.8, 1.8);
        let identity = CaptureIdentity {
            noise_seed: 22,
            frame_index: 4,
        };
        let full_exposure = IntegratedOpticalExposure {
            width: 9,
            height: 9,
            duration_seconds: 1.0,
            acescg_illuminance_seconds: pixels.clone(),
        };
        let full = expose_raw_with_noise_amount(profile, &full_exposure, identity, 0.0)
            .expect("full bloom");
        let output = SensorRegion {
            origin_x: 3,
            origin_y: 3,
            width: 3,
            height: 3,
        };
        let support = output.expanded_for_sensor_bloom(profile);
        let mut support_pixels = Vec::new();
        for y in 0..usize::from(support.height) {
            let global_y = usize::from(support.origin_y) + y;
            for x in 0..usize::from(support.width) {
                let global_x = usize::from(support.origin_x) + x;
                support_pixels.push(pixels[global_y * 9 + global_x]);
            }
        }
        let support_exposure = IntegratedOpticalExposure {
            width: u32::from(support.width),
            height: u32::from(support.height),
            duration_seconds: 1.0,
            acescg_illuminance_seconds: support_pixels,
        };
        let crop = expose_raw_region_with_noise_amount(
            profile,
            &support_exposure,
            identity,
            support,
            output,
            0.0,
        )
        .expect("supported bloom crop");
        for y in 0..3_usize {
            for x in 0..3_usize {
                assert_eq!(crop.codes[y * 3 + x], full.codes[(y + 3) * 9 + x + 3]);
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
