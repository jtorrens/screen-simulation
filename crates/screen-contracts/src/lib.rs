//! Shared stable identifiers, physical units, rational time, and boundary values.

#![forbid(unsafe_code)]

use core::cmp::Ordering;
use core::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RationalTime {
    numerator: i64,
    denominator: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameRate {
    numerator: u32,
    denominator: u32,
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
}
