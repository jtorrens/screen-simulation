//! Explicit camera development from authoritative mosaiced RAW to linear ACEScg.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::LinearRgb;
use screen_sensor::{RawSensorRaster, RawSensorRegion, SensorProfile, SensorRegion};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraDevelopment {
    /// Explicit multiplicative gains in native sensor RGB order.
    pub white_balance: LinearRgb,
    /// Image-plane illuminance exposure in lux-seconds placed at ACEScg 0.18.
    pub middle_gray_illuminance_seconds: f32,
    /// Explicit push/pull applied only after RAW reconstruction.
    pub develop_exposure_ev: f32,
}

impl CameraDevelopment {
    pub const NEUTRAL: Self = Self {
        white_balance: LinearRgb::new(1.0, 1.0, 1.0),
        middle_gray_illuminance_seconds: 0.18,
        develop_exposure_ev: 0.0,
    };

    pub fn validate(self) -> Result<Self, CameraDevelopmentError> {
        if [
            self.white_balance.r,
            self.white_balance.g,
            self.white_balance.b,
        ]
        .into_iter()
        .any(|value| !value.is_finite() || !(0.01..=100.0).contains(&value))
        {
            return Err(CameraDevelopmentError::InvalidWhiteBalance);
        }
        if !self.middle_gray_illuminance_seconds.is_finite()
            || !(0.000_001..=1_000_000.0).contains(&self.middle_gray_illuminance_seconds)
            || !self.develop_exposure_ev.is_finite()
            || !(-16.0..=16.0).contains(&self.develop_exposure_ev)
        {
            return Err(CameraDevelopmentError::InvalidExposureScale);
        }
        Ok(self)
    }

    fn linear_scale(self) -> f32 {
        0.18 / self.middle_gray_illuminance_seconds * self.develop_exposure_ev.exp2()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DevelopedCameraRaster {
    pub width: u32,
    pub height: u32,
    /// Scene-linear ACEScg exposure values. Negative and above-one values are preserved.
    pub acescg: Vec<LinearRgb>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DevelopedCameraRegion {
    pub sensor_width: u16,
    pub sensor_height: u16,
    pub region: SensorRegion,
    pub acescg: Vec<LinearRgb>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameraDevelopmentError {
    InvalidWhiteBalance,
    InvalidExposureScale,
    RawProfileMismatch,
    RawPixelCountMismatch,
    InvalidSensorProfile,
    InvalidColorMatrix,
    NonFiniteDevelopedPixel,
}

pub fn develop_raw_to_acescg(
    raw: &RawSensorRaster,
    sensor: SensorProfile,
    development: CameraDevelopment,
) -> Result<DevelopedCameraRaster, CameraDevelopmentError> {
    let sensor = sensor
        .validate()
        .map_err(|_| CameraDevelopmentError::InvalidSensorProfile)?;
    let development = development.validate()?;
    if raw.width != u32::from(sensor.native_width)
        || raw.height != u32::from(sensor.native_height)
        || raw.bayer_pattern != sensor.bayer_pattern
        || raw.adc_bits != sensor.adc_bits
    {
        return Err(CameraDevelopmentError::RawProfileMismatch);
    }
    if raw.width < 2 || raw.height < 2 {
        return Err(CameraDevelopmentError::RawProfileMismatch);
    }
    let pixel_count = u64::from(raw.width) * u64::from(raw.height);
    if raw.codes.len() as u64 != pixel_count
        || raw.full_well_clipped.len() as u64 != pixel_count
        || raw.adc_clipped.len() as u64 != pixel_count
    {
        return Err(CameraDevelopmentError::RawPixelCountMismatch);
    }
    let sensor_to_acescg =
        inverse3(sensor.acescg_to_sensor).ok_or(CameraDevelopmentError::InvalidColorMatrix)?;
    let maximum_code = ((1_u32 << sensor.adc_bits) - 1) as f32;
    let saturation = [
        sensor.saturation_illuminance_seconds.r,
        sensor.saturation_illuminance_seconds.g,
        sensor.saturation_illuminance_seconds.b,
    ];
    let gains = [
        development.white_balance.r,
        development.white_balance.g,
        development.white_balance.b,
    ];
    let mut native_mosaic = Vec::with_capacity(raw.codes.len());
    for (index, code) in raw.codes.iter().copied().enumerate() {
        let x = (index % raw.width as usize) as u32;
        let y = (index / raw.width as usize) as u32;
        let channel = raw.bayer_pattern.channel_at(x, y);
        native_mosaic
            .push(f32::from(code) / maximum_code / sensor.analog_gain * saturation[channel]);
    }

    let mut acescg = Vec::with_capacity(raw.codes.len());
    for y in 0..raw.height {
        for x in 0..raw.width {
            let mut sensor_rgb = [0.0_f32; 3];
            for channel in 0..3 {
                sensor_rgb[channel] = interpolate_channel(
                    &native_mosaic,
                    raw.width,
                    raw.height,
                    raw.bayer_pattern,
                    x,
                    y,
                    channel,
                ) * gains[channel];
            }
            let mut developed = mat_vec(sensor_to_acescg, sensor_rgb);
            let linear_scale = development.linear_scale();
            developed.r *= linear_scale;
            developed.g *= linear_scale;
            developed.b *= linear_scale;
            if [developed.r, developed.g, developed.b]
                .into_iter()
                .any(|value| !value.is_finite())
            {
                return Err(CameraDevelopmentError::NonFiniteDevelopedPixel);
            }
            acescg.push(developed);
        }
    }
    Ok(DevelopedCameraRaster {
        width: raw.width,
        height: raw.height,
        acescg,
    })
}

pub fn develop_raw_region_to_acescg(
    raw: &RawSensorRegion,
    sensor: SensorProfile,
    development: CameraDevelopment,
) -> Result<DevelopedCameraRegion, CameraDevelopmentError> {
    let sensor = sensor
        .validate()
        .map_err(|_| CameraDevelopmentError::InvalidSensorProfile)?;
    let development = development.validate()?;
    if raw.sensor_width != sensor.native_width
        || raw.sensor_height != sensor.native_height
        || raw.bayer_pattern != sensor.bayer_pattern
        || raw.adc_bits != sensor.adc_bits
        || raw.region.validate(sensor).is_err()
    {
        return Err(CameraDevelopmentError::RawProfileMismatch);
    }
    let pixel_count = u64::from(raw.region.width) * u64::from(raw.region.height);
    if raw.codes.len() as u64 != pixel_count
        || raw.full_well_clipped.len() as u64 != pixel_count
        || raw.adc_clipped.len() as u64 != pixel_count
    {
        return Err(CameraDevelopmentError::RawPixelCountMismatch);
    }
    let sensor_to_acescg =
        inverse3(sensor.acescg_to_sensor).ok_or(CameraDevelopmentError::InvalidColorMatrix)?;
    let maximum_code = ((1_u32 << sensor.adc_bits) - 1) as f32;
    let saturation = [
        sensor.saturation_illuminance_seconds.r,
        sensor.saturation_illuminance_seconds.g,
        sensor.saturation_illuminance_seconds.b,
    ];
    let gains = [
        development.white_balance.r,
        development.white_balance.g,
        development.white_balance.b,
    ];
    let mut native_mosaic = Vec::with_capacity(raw.codes.len());
    for (index, code) in raw.codes.iter().copied().enumerate() {
        let local_x = index % usize::from(raw.region.width);
        let local_y = index / usize::from(raw.region.width);
        let x = u32::from(raw.region.origin_x) + local_x as u32;
        let y = u32::from(raw.region.origin_y) + local_y as u32;
        let channel = raw.bayer_pattern.channel_at(x, y);
        native_mosaic
            .push(f32::from(code) / maximum_code / sensor.analog_gain * saturation[channel]);
    }

    let mut acescg = Vec::with_capacity(raw.codes.len());
    for local_y in 0..u32::from(raw.region.height) {
        for local_x in 0..u32::from(raw.region.width) {
            let global_x = u32::from(raw.region.origin_x) + local_x;
            let global_y = u32::from(raw.region.origin_y) + local_y;
            let mut sensor_rgb = [0.0_f32; 3];
            for channel in 0..3 {
                sensor_rgb[channel] = interpolate_region_channel(
                    &native_mosaic,
                    raw.region,
                    raw.bayer_pattern,
                    global_x,
                    global_y,
                    channel,
                ) * gains[channel];
            }
            let mut developed = mat_vec(sensor_to_acescg, sensor_rgb);
            let linear_scale = development.linear_scale();
            developed.r *= linear_scale;
            developed.g *= linear_scale;
            developed.b *= linear_scale;
            if [developed.r, developed.g, developed.b]
                .into_iter()
                .any(|value| !value.is_finite())
            {
                return Err(CameraDevelopmentError::NonFiniteDevelopedPixel);
            }
            acescg.push(developed);
        }
    }
    Ok(DevelopedCameraRegion {
        sensor_width: sensor.native_width,
        sensor_height: sensor.native_height,
        region: raw.region,
        acescg,
    })
}

fn interpolate_region_channel(
    mosaic: &[f32],
    region: SensorRegion,
    pattern: screen_sensor::BayerPattern,
    x: u32,
    y: u32,
    channel: usize,
) -> f32 {
    let index = |sample_x: u32, sample_y: u32| {
        (sample_y - u32::from(region.origin_y)) as usize * usize::from(region.width)
            + (sample_x - u32::from(region.origin_x)) as usize
    };
    if pattern.channel_at(x, y) == channel {
        return mosaic[index(x, y)];
    }
    let mut sum = 0.0_f32;
    let mut weight_sum = 0.0_f32;
    for offset_y in -1_i32..=1 {
        for offset_x in -1_i32..=1 {
            if offset_x == 0 && offset_y == 0 {
                continue;
            }
            let sample_x = x as i64 + i64::from(offset_x);
            let sample_y = y as i64 + i64::from(offset_y);
            if sample_x < i64::from(region.origin_x)
                || sample_y < i64::from(region.origin_y)
                || sample_x >= i64::from(region.origin_x) + i64::from(region.width)
                || sample_y >= i64::from(region.origin_y) + i64::from(region.height)
            {
                continue;
            }
            let sample_x = sample_x as u32;
            let sample_y = sample_y as u32;
            if pattern.channel_at(sample_x, sample_y) != channel {
                continue;
            }
            let weight = if offset_x == 0 || offset_y == 0 {
                2.0
            } else {
                1.0
            };
            sum += mosaic[index(sample_x, sample_y)] * weight;
            weight_sum += weight;
        }
    }
    debug_assert!(weight_sum > 0.0);
    sum / weight_sum
}

/// One deterministic normalized bilinear demosaic. Edge samples are included only when their
/// authored CFA channel matches; no guessed edge mode or alternate algorithm is selected.
fn interpolate_channel(
    mosaic: &[f32],
    width: u32,
    height: u32,
    pattern: screen_sensor::BayerPattern,
    x: u32,
    y: u32,
    channel: usize,
) -> f32 {
    if pattern.channel_at(x, y) == channel {
        return mosaic[y as usize * width as usize + x as usize];
    }
    let mut sum = 0.0_f32;
    let mut weight_sum = 0.0_f32;
    for offset_y in -1_i32..=1 {
        for offset_x in -1_i32..=1 {
            if offset_x == 0 && offset_y == 0 {
                continue;
            }
            let sample_x = x as i64 + i64::from(offset_x);
            let sample_y = y as i64 + i64::from(offset_y);
            if sample_x < 0
                || sample_y < 0
                || sample_x >= i64::from(width)
                || sample_y >= i64::from(height)
            {
                continue;
            }
            let sample_x = sample_x as u32;
            let sample_y = sample_y as u32;
            if pattern.channel_at(sample_x, sample_y) != channel {
                continue;
            }
            let weight = if offset_x == 0 || offset_y == 0 {
                2.0
            } else {
                1.0
            };
            sum += mosaic[sample_y as usize * width as usize + sample_x as usize] * weight;
            weight_sum += weight;
        }
    }
    debug_assert!(weight_sum > 0.0);
    sum / weight_sum
}

fn mat_vec(matrix: [[f32; 3]; 3], value: [f32; 3]) -> LinearRgb {
    LinearRgb::new(
        matrix[0][0] * value[0] + matrix[0][1] * value[1] + matrix[0][2] * value[2],
        matrix[1][0] * value[0] + matrix[1][1] * value[1] + matrix[1][2] * value[2],
        matrix[2][0] * value[0] + matrix[2][1] * value[1] + matrix[2][2] * value[2],
    )
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

impl fmt::Display for CameraDevelopmentError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidWhiteBalance => "white-balance gains must be finite and in [0.01, 100]",
            Self::InvalidExposureScale => {
                "middle-gray exposure must be finite and positive, and develop EV must be in [-16, 16]"
            }
            Self::RawProfileMismatch => "RAW raster does not match its authored sensor profile",
            Self::RawPixelCountMismatch => "RAW raster storage does not match its dimensions",
            Self::InvalidSensorProfile => "sensor profile is invalid",
            Self::InvalidColorMatrix => "sensor-to-ACEScg matrix cannot be resolved",
            Self::NonFiniteDevelopedPixel => "camera development produced a non-finite pixel",
        })
    }
}

impl std::error::Error for CameraDevelopmentError {}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_sensor::{BayerPattern, RawSensorRegion, SensorRegion};

    fn identity_sensor(pattern: BayerPattern) -> SensorProfile {
        SensorProfile {
            native_width: 4,
            native_height: 4,
            bayer_pattern: pattern,
            acescg_to_sensor: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            saturation_illuminance_seconds: LinearRgb::new(1.0, 1.0, 1.0),
            full_well_electrons: 10_000.0,
            dark_current_electrons_per_second: 0.0,
            read_noise_electrons_rms: 0.0,
            analog_gain: 1.0,
            adc_bits: 16,
        }
    }

    #[test]
    fn constant_native_channels_demosaic_to_constant_linear_acescg() {
        for pattern in [
            BayerPattern::Rggb,
            BayerPattern::Bggr,
            BayerPattern::Grbg,
            BayerPattern::Gbrg,
        ] {
            let sensor = identity_sensor(pattern);
            let values = [0.25_f32, 0.5, 0.75];
            let codes = (0..16)
                .map(|index| {
                    let x = index % 4;
                    let y = index / 4;
                    (values[pattern.channel_at(x, y)] * 65_535.0).round() as u16
                })
                .collect();
            let raw = RawSensorRaster {
                width: 4,
                height: 4,
                bayer_pattern: pattern,
                adc_bits: 16,
                codes,
                full_well_clipped: vec![false; 16],
                adc_clipped: vec![false; 16],
            };
            let developed = develop_raw_to_acescg(&raw, sensor, CameraDevelopment::NEUTRAL)
                .expect("developed raster");
            for pixel in developed.acescg {
                assert!((pixel.r - values[0]).abs() < 2.0e-5);
                assert!((pixel.g - values[1]).abs() < 2.0e-5);
                assert!((pixel.b - values[2]).abs() < 2.0e-5);
            }
        }
    }

    #[test]
    fn white_balance_is_explicit_and_applied_before_sensor_matrix_inverse() {
        let sensor = identity_sensor(BayerPattern::Rggb);
        let raw = RawSensorRaster {
            width: 4,
            height: 4,
            bayer_pattern: BayerPattern::Rggb,
            adc_bits: 16,
            codes: vec![32_768; 16],
            full_well_clipped: vec![false; 16],
            adc_clipped: vec![false; 16],
        };
        let developed = develop_raw_to_acescg(
            &raw,
            sensor,
            CameraDevelopment {
                white_balance: LinearRgb::new(2.0, 1.0, 0.5),
                middle_gray_illuminance_seconds: 0.18,
                develop_exposure_ev: 0.0,
            },
        )
        .expect("developed raster");
        let pixel = developed.acescg[5];
        assert!((pixel.r - 1.0).abs() < 2.0e-5);
        assert!((pixel.g - 0.5).abs() < 2.0e-5);
        assert!((pixel.b - 0.25).abs() < 2.0e-5);
    }

    #[test]
    fn explicit_middle_gray_placement_changes_developed_acescg_without_changing_raw() {
        let sensor = identity_sensor(BayerPattern::Rggb);
        let raw = RawSensorRaster {
            width: 4,
            height: 4,
            bayer_pattern: BayerPattern::Rggb,
            adc_bits: 16,
            codes: vec![16_384; 16],
            full_well_clipped: vec![false; 16],
            adc_clipped: vec![false; 16],
        };
        let original = raw.clone();
        let developed = develop_raw_to_acescg(
            &raw,
            sensor,
            CameraDevelopment {
                white_balance: LinearRgb::new(1.0, 1.0, 1.0),
                middle_gray_illuminance_seconds: 0.045,
                develop_exposure_ev: 0.0,
            },
        )
        .expect("developed raster");
        assert_eq!(raw, original);
        for channel in [
            developed.acescg[5].r,
            developed.acescg[5].g,
            developed.acescg[5].b,
        ] {
            assert!((channel - 1.0).abs() < 2.0e-5);
        }
    }

    #[test]
    fn raw_contract_mismatch_fails_instead_of_selecting_an_alternate_route() {
        let sensor = identity_sensor(BayerPattern::Rggb);
        let raw = RawSensorRaster {
            width: 4,
            height: 4,
            bayer_pattern: BayerPattern::Bggr,
            adc_bits: 16,
            codes: vec![0; 16],
            full_well_clipped: vec![false; 16],
            adc_clipped: vec![false; 16],
        };
        assert_eq!(
            develop_raw_to_acescg(&raw, sensor, CameraDevelopment::NEUTRAL),
            Err(CameraDevelopmentError::RawProfileMismatch)
        );
    }

    #[test]
    fn region_demosaic_with_halo_matches_the_complete_sensor_result() {
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..identity_sensor(BayerPattern::Rggb)
        };
        let codes: Vec<u16> = (0..64)
            .map(|index| 4_000 + (index as u16 * 701) % 50_000)
            .collect();
        let full_raw = RawSensorRaster {
            width: 8,
            height: 8,
            bayer_pattern: BayerPattern::Rggb,
            adc_bits: 16,
            codes: codes.clone(),
            full_well_clipped: vec![false; 64],
            adc_clipped: vec![false; 64],
        };
        let full = develop_raw_to_acescg(&full_raw, sensor, CameraDevelopment::NEUTRAL)
            .expect("complete development");
        let requested = SensorRegion {
            origin_x: 3,
            origin_y: 3,
            width: 2,
            height: 2,
        };
        let halo = requested.expanded_for_demosaic(sensor);
        let mut region_codes = Vec::new();
        for y in 0..usize::from(halo.height) {
            let start = (usize::from(halo.origin_y) + y) * 8 + usize::from(halo.origin_x);
            region_codes.extend_from_slice(&codes[start..start + usize::from(halo.width)]);
        }
        let region_raw = RawSensorRegion {
            sensor_width: 8,
            sensor_height: 8,
            region: halo,
            bayer_pattern: BayerPattern::Rggb,
            adc_bits: 16,
            codes: region_codes,
            full_well_clipped: vec![false; usize::from(halo.width) * usize::from(halo.height)],
            adc_clipped: vec![false; usize::from(halo.width) * usize::from(halo.height)],
        };
        let region = develop_raw_region_to_acescg(&region_raw, sensor, CameraDevelopment::NEUTRAL)
            .expect("region development");
        for y in 0..usize::from(requested.height) {
            for x in 0..usize::from(requested.width) {
                let global_x = usize::from(requested.origin_x) + x;
                let global_y = usize::from(requested.origin_y) + y;
                let region_x = global_x - usize::from(halo.origin_x);
                let region_y = global_y - usize::from(halo.origin_y);
                assert_eq!(
                    region.acescg[region_y * usize::from(halo.width) + region_x],
                    full.acescg[global_y * 8 + global_x]
                );
            }
        }
    }
}
