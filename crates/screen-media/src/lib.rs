//! Exact media decoding and frame-selection ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::RationalTime;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RasterSize {
    pub width: u32,
    pub height: u32,
}

impl RasterSize {
    pub fn new(width: u32, height: u32) -> Result<Self, MediaError> {
        if width == 0 || height == 0 {
            return Err(MediaError::EmptyRaster);
        }
        Ok(Self { width, height })
    }

    pub fn pixel_count(self) -> u64 {
        u64::from(self.width) * u64::from(self.height)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AlphaPresence {
    Absent,
    Present,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameCadence {
    Constant { frame_rate: RationalTime },
    Variable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaDescriptor {
    pub raster: RasterSize,
    pub cadence: FrameCadence,
    pub duration: Option<RationalTime>,
    pub alpha: AlphaPresence,
    pub codec_name: String,
    pub pixel_format_name: String,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DecodedRgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DecodedFrame {
    pub raster: RasterSize,
    pub timestamp: RationalTime,
    pub pixels: Vec<DecodedRgba>,
}

impl DecodedFrame {
    pub fn validate(self) -> Result<Self, MediaError> {
        let expected = self.raster.pixel_count();
        if self.pixels.len() as u64 != expected {
            return Err(MediaError::PixelCountMismatch {
                expected,
                actual: self.pixels.len() as u64,
            });
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaError {
    EmptyRaster,
    PixelCountMismatch { expected: u64, actual: u64 },
}

impl fmt::Display for MediaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyRaster => formatter.write_str("decoded media raster must be non-empty"),
            Self::PixelCountMismatch { expected, actual } => write!(
                formatter,
                "decoded frame has {actual} pixels but its raster requires {expected}"
            ),
        }
    }
}

impl std::error::Error for MediaError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raster_rejects_zero_dimensions() {
        assert_eq!(RasterSize::new(0, 1080), Err(MediaError::EmptyRaster));
    }

    #[test]
    fn decoded_frame_rejects_incomplete_storage() {
        let frame = DecodedFrame {
            raster: RasterSize::new(2, 2).expect("valid raster"),
            timestamp: RationalTime::new(0, 24).expect("valid timestamp"),
            pixels: vec![
                DecodedRgba {
                    r: 0.0,
                    g: 0.0,
                    b: 0.0,
                    a: 1.0,
                };
                3
            ],
        };
        assert_eq!(
            frame.validate(),
            Err(MediaError::PixelCountMismatch {
                expected: 4,
                actual: 3
            })
        );
    }
}
