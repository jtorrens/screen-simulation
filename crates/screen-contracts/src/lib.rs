//! Shared stable identifiers, physical units, rational time, and boundary values.

#![forbid(unsafe_code)]

use core::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RationalTime {
    numerator: i64,
    denominator: u32,
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
}

impl fmt::Display for ContractError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ZeroDenominator => {
                formatter.write_str("rational time denominator must be non-zero")
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
}
