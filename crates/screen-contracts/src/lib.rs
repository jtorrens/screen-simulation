//! Shared stable identifiers, physical units, rational time, and boundary values.

#![forbid(unsafe_code)]

use core::cmp::Ordering;
use core::fmt;

#[derive(Clone, Copy, Debug)]
pub struct RationalTime {
    numerator: i64,
    denominator: u32,
}

impl PartialEq for RationalTime {
    fn eq(&self, other: &Self) -> bool {
        i128::from(self.numerator) * i128::from(other.denominator)
            == i128::from(other.numerator) * i128::from(self.denominator)
    }
}

impl Eq for RationalTime {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameRate {
    numerator: u32,
    denominator: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ColorPrimaries {
    Bt709,
    Bt2020,
    P3D65,
    Other(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TransferCharacteristic {
    Bt709,
    Srgb,
    Gamma22,
    Gamma28,
    Linear,
    Pq,
    Hlg,
    Other(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MatrixCoefficients {
    Rgb,
    Bt601,
    Bt709,
    Bt2020Ncl,
    Bt2020Cl,
    Other(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SignalRange {
    Limited,
    Full,
    Other(String),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EncodedColorMetadata {
    pub primaries: Option<ColorPrimaries>,
    pub transfer: Option<TransferCharacteristic>,
    pub matrix: Option<MatrixCoefficients>,
    pub range: Option<SignalRange>,
}

impl EncodedColorMetadata {
    pub fn is_empty(&self) -> bool {
        self.primaries.is_none()
            && self.transfer.is_none()
            && self.matrix.is_none()
            && self.range.is_none()
    }
}

impl FrameRate {
    pub fn new(numerator: u32, denominator: u32) -> Result<Self, ContractError> {
        if numerator == 0 || denominator == 0 {
            return Err(ContractError::NonPositiveFrameRate);
        }
        Ok(Self {
            numerator,
            denominator,
        })
    }

    pub const fn numerator(self) -> u32 {
        self.numerator
    }

    pub const fn denominator(self) -> u32 {
        self.denominator
    }

    pub fn time_at_frame(self, frame: i64) -> Result<RationalTime, ContractError> {
        let numerator = frame
            .checked_mul(i64::from(self.denominator))
            .ok_or(ContractError::TimeOverflow)?;
        RationalTime::new(numerator, self.numerator)
    }
}

impl RationalTime {
    pub fn new(numerator: i64, denominator: u32) -> Result<Self, ContractError> {
        if denominator == 0 {
            return Err(ContractError::ZeroDenominator);
        }
        Ok(Self {
            numerator,
            denominator,
        })
    }

    pub const fn numerator(self) -> i64 {
        self.numerator
    }

    pub const fn denominator(self) -> u32 {
        self.denominator
    }

    pub fn as_seconds(self) -> f64 {
        self.numerator as f64 / f64::from(self.denominator)
    }

    pub fn checked_add(self, other: Self) -> Result<Self, ContractError> {
        let numerator = i128::from(self.numerator) * i128::from(other.denominator)
            + i128::from(other.numerator) * i128::from(self.denominator);
        let denominator = u128::from(self.denominator) * u128::from(other.denominator);
        rational_from_wide(numerator, denominator)
    }

    pub fn checked_sub(self, other: Self) -> Result<Self, ContractError> {
        let numerator = i128::from(self.numerator) * i128::from(other.denominator)
            - i128::from(other.numerator) * i128::from(self.denominator);
        let denominator = u128::from(self.denominator) * u128::from(other.denominator);
        rational_from_wide(numerator, denominator)
    }

    pub fn checked_mul_ratio(
        self,
        numerator: i64,
        denominator: u32,
    ) -> Result<Self, ContractError> {
        if denominator == 0 {
            return Err(ContractError::ZeroDenominator);
        }
        rational_from_wide(
            i128::from(self.numerator) * i128::from(numerator),
            u128::from(self.denominator) * u128::from(denominator),
        )
    }

    pub fn floor_div(self, positive_divisor: Self) -> Result<i64, ContractError> {
        if positive_divisor.numerator <= 0 {
            return Err(ContractError::NonPositiveTimeDivisor);
        }
        let numerator = i128::from(self.numerator) * i128::from(positive_divisor.denominator);
        let denominator = i128::from(self.denominator) * i128::from(positive_divisor.numerator);
        let quotient = numerator.div_euclid(denominator);
        i64::try_from(quotient).map_err(|_| ContractError::TimeOverflow)
    }
}

fn rational_from_wide(numerator: i128, denominator: u128) -> Result<RationalTime, ContractError> {
    let numerator_magnitude = numerator.unsigned_abs();
    let divisor = gcd_u128(numerator_magnitude, denominator);
    let reduced_numerator = numerator / divisor as i128;
    let reduced_denominator = denominator / divisor;
    Ok(RationalTime {
        numerator: i64::try_from(reduced_numerator).map_err(|_| ContractError::TimeOverflow)?,
        denominator: u32::try_from(reduced_denominator).map_err(|_| ContractError::TimeOverflow)?,
    })
}

fn gcd_u128(mut left: u128, mut right: u128) -> u128 {
    while right != 0 {
        let remainder = left % right;
        left = right;
        right = remainder;
    }
    left.max(1)
}

impl PartialOrd for RationalTime {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for RationalTime {
    fn cmp(&self, other: &Self) -> Ordering {
        (i128::from(self.numerator) * i128::from(other.denominator))
            .cmp(&(i128::from(other.numerator) * i128::from(self.denominator)))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Meters(pub f32);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Millimeters(pub f32);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Vec2 {
    pub x: f32,
    pub y: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeviceRgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

impl DeviceRgb {
    pub const BLACK: Self = Self::new(0.0, 0.0, 0.0);
    pub const WHITE: Self = Self::new(1.0, 1.0, 1.0);

    pub const fn new(r: f32, g: f32, b: f32) -> Self {
        Self { r, g, b }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LinearRgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

impl LinearRgb {
    pub const fn new(r: f32, g: f32, b: f32) -> Self {
        Self { r, g, b }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContractError {
    ZeroDenominator,
    NonPositiveFrameRate,
    TimeOverflow,
    NonPositiveTimeDivisor,
}

impl fmt::Display for ContractError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ZeroDenominator => {
                formatter.write_str("rational time denominator must be non-zero")
            }
            Self::NonPositiveFrameRate => {
                formatter.write_str("frame rate numerator and denominator must be positive")
            }
            Self::TimeOverflow => formatter.write_str("exact frame time exceeds its numeric range"),
            Self::NonPositiveTimeDivisor => {
                formatter.write_str("exact time divisor must be positive")
            }
        }
    }
}

impl std::error::Error for ContractError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rational_time_rejects_zero_denominator() {
        assert_eq!(RationalTime::new(1, 0), Err(ContractError::ZeroDenominator));
    }

    #[test]
    fn rational_time_preserves_authored_fraction() {
        let time = RationalTime::new(24_000, 24_000).expect("valid exact time");
        assert_eq!(time.numerator(), 24_000);
        assert_eq!(time.denominator(), 24_000);
        assert_eq!(time.as_seconds(), 1.0);
    }

    #[test]
    fn frame_rate_preserves_fractional_project_time() {
        let rate = FrameRate::new(24_000, 1_001).expect("valid rate");
        let time = rate.time_at_frame(24_000).expect("valid frame time");
        assert_eq!(time.numerator(), 24_024_000);
        assert_eq!(time.denominator(), 24_000);
    }

    #[test]
    fn rational_time_compares_without_float_conversion() {
        let film = RationalTime::new(1_001, 24_000).expect("valid time");
        let video = RationalTime::new(1, 24).expect("valid time");
        assert!(film > video);
    }

    #[test]
    fn rational_time_equality_is_independent_of_authored_fraction() {
        let stream_timestamp = RationalTime::new(512, 12_800).expect("valid stream time");
        let project_timestamp = RationalTime::new(1, 25).expect("valid project time");
        assert_eq!(stream_timestamp, project_timestamp);
    }

    #[test]
    fn rational_time_arithmetic_reduces_exactly_and_rejects_overflow() {
        let center = RationalTime::new(1, 24).expect("valid center");
        let half_shutter = RationalTime::new(1, 96).expect("valid half shutter");
        let open = center.checked_sub(half_shutter).expect("valid open time");
        assert_eq!(open, RationalTime::new(1, 32).expect("valid expected time"));
        assert_eq!(
            half_shutter
                .checked_mul_ratio(3, 2)
                .expect("valid scaled time"),
            RationalTime::new(1, 64).expect("valid expected time")
        );
        assert_eq!(
            RationalTime::new(i64::MAX, 1)
                .expect("valid boundary time")
                .checked_add(RationalTime::new(1, 1).expect("valid increment")),
            Err(ContractError::TimeOverflow)
        );
        assert_eq!(
            RationalTime::new(-1, 10)
                .expect("valid negative time")
                .floor_div(RationalTime::new(1, 24).expect("valid period")),
            Ok(-3)
        );
    }
}
