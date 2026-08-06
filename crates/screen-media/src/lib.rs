//! Exact media decoding and frame-selection ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{EncodedColorMetadata, MatrixCoefficients, RationalTime, SignalRange};

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
pub enum AlphaInterpretation {
    Auto,
    Straight,
    Premultiplied,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PixelEncoding {
    Rgb,
    Yuv,
    Monochrome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum YuvMatrixSelection {
    Auto,
    Bt601,
    Bt709,
    Bt2020,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignalRangeSelection {
    Auto,
    Limited,
    Full,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResolvedYuvMatrix {
    Bt601,
    Bt709,
    Bt2020,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResolvedSignalRange {
    Limited,
    Full,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourceDecodeInterpretation {
    pub matrix: YuvMatrixSelection,
    pub range: SignalRangeSelection,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResolvedYuvInterpretation {
    pub matrix: ResolvedYuvMatrix,
    pub range: ResolvedSignalRange,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResolvedSourceDecode {
    Rgb,
    Yuv(ResolvedYuvInterpretation),
    Monochrome(ResolvedSignalRange),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameCadence {
    Constant { frame_rate: RationalTime },
    Variable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameSelectionPolicy {
    /// Require a source sample at the requested rational time. Source edges are not extended.
    Exact,
    /// Select the latest sample at or before the requested time and hold the first/last sample
    /// when shutter evaluation crosses a bounded source edge.
    Floor,
    /// Select the nearest sample, breaking ties toward the earlier sample, and hold bounded edges.
    Nearest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaDescriptor {
    pub raster: RasterSize,
    pub cadence: FrameCadence,
    pub duration: Option<RationalTime>,
    pub alpha: AlphaPresence,
    pub pixel_encoding: PixelEncoding,
    pub codec_name: String,
    pub pixel_format_name: String,
    pub color_metadata: EncodedColorMetadata,
}

impl MediaDescriptor {
    pub fn resolve_decode_interpretation(
        &self,
        authored: SourceDecodeInterpretation,
    ) -> Result<ResolvedSourceDecode, MediaError> {
        if self.pixel_encoding == PixelEncoding::Rgb {
            return Ok(ResolvedSourceDecode::Rgb);
        }
        let range = match authored.range {
            SignalRangeSelection::Limited => ResolvedSignalRange::Limited,
            SignalRangeSelection::Full => ResolvedSignalRange::Full,
            SignalRangeSelection::Auto => match self.color_metadata.range.as_ref() {
                Some(SignalRange::Limited) => ResolvedSignalRange::Limited,
                Some(SignalRange::Full) => ResolvedSignalRange::Full,
                None => return Err(MediaError::UnresolvedSignalRange),
                Some(SignalRange::Other(_)) => {
                    return Err(MediaError::UnsupportedDeclaredSignalRange);
                }
            },
        };
        if self.pixel_encoding == PixelEncoding::Monochrome {
            return Ok(ResolvedSourceDecode::Monochrome(range));
        }
        let matrix = match authored.matrix {
            YuvMatrixSelection::Bt601 => ResolvedYuvMatrix::Bt601,
            YuvMatrixSelection::Bt709 => ResolvedYuvMatrix::Bt709,
            YuvMatrixSelection::Bt2020 => ResolvedYuvMatrix::Bt2020,
            YuvMatrixSelection::Auto => match self.color_metadata.matrix.as_ref() {
                Some(MatrixCoefficients::Bt601) => ResolvedYuvMatrix::Bt601,
                Some(MatrixCoefficients::Bt709) => ResolvedYuvMatrix::Bt709,
                Some(MatrixCoefficients::Bt2020Ncl | MatrixCoefficients::Bt2020Cl) => {
                    ResolvedYuvMatrix::Bt2020
                }
                None => return Err(MediaError::UnresolvedYuvMatrix),
                Some(_) => return Err(MediaError::UnsupportedDeclaredYuvMatrix),
            },
        };
        Ok(ResolvedSourceDecode::Yuv(ResolvedYuvInterpretation {
            matrix,
            range,
        }))
    }
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
    UnresolvedYuvMatrix,
    UnsupportedDeclaredYuvMatrix,
    UnresolvedSignalRange,
    UnsupportedDeclaredSignalRange,
}

impl fmt::Display for MediaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyRaster => formatter.write_str("decoded media raster must be non-empty"),
            Self::PixelCountMismatch { expected, actual } => write!(
                formatter,
                "decoded frame has {actual} pixels but its raster requires {expected}"
            ),
            Self::UnresolvedYuvMatrix => formatter.write_str(
                "source metadata does not declare a supported YUV matrix; choose one explicitly",
            ),
            Self::UnsupportedDeclaredYuvMatrix => formatter.write_str(
                "source metadata declares an unsupported YUV matrix; choose one explicitly",
            ),
            Self::UnresolvedSignalRange => formatter.write_str(
                "source metadata does not declare signal range; choose Limited or Full explicitly",
            ),
            Self::UnsupportedDeclaredSignalRange => formatter.write_str(
                "source metadata declares an unsupported signal range; choose one explicitly",
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

    fn yuv_descriptor(metadata: EncodedColorMetadata) -> MediaDescriptor {
        MediaDescriptor {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            cadence: FrameCadence::Variable,
            duration: None,
            alpha: AlphaPresence::Absent,
            pixel_encoding: PixelEncoding::Yuv,
            codec_name: "test".to_owned(),
            pixel_format_name: "yuv444p".to_owned(),
            color_metadata: metadata,
        }
    }

    #[test]
    fn auto_yuv_decode_requires_complete_supported_metadata() {
        let descriptor = yuv_descriptor(EncodedColorMetadata {
            matrix: Some(MatrixCoefficients::Bt709),
            range: Some(SignalRange::Limited),
            ..EncodedColorMetadata::default()
        });
        assert_eq!(
            descriptor.resolve_decode_interpretation(SourceDecodeInterpretation {
                matrix: YuvMatrixSelection::Auto,
                range: SignalRangeSelection::Auto,
            }),
            Ok(ResolvedSourceDecode::Yuv(ResolvedYuvInterpretation {
                matrix: ResolvedYuvMatrix::Bt709,
                range: ResolvedSignalRange::Limited,
            }))
        );
        let missing_range = yuv_descriptor(EncodedColorMetadata {
            matrix: Some(MatrixCoefficients::Bt709),
            ..EncodedColorMetadata::default()
        });
        assert_eq!(
            missing_range.resolve_decode_interpretation(SourceDecodeInterpretation {
                matrix: YuvMatrixSelection::Auto,
                range: SignalRangeSelection::Auto,
            }),
            Err(MediaError::UnresolvedSignalRange)
        );
    }

    #[test]
    fn explicit_yuv_decode_overrides_missing_or_unsupported_metadata() {
        let descriptor = yuv_descriptor(EncodedColorMetadata::default());
        assert_eq!(
            descriptor.resolve_decode_interpretation(SourceDecodeInterpretation {
                matrix: YuvMatrixSelection::Bt2020,
                range: SignalRangeSelection::Full,
            }),
            Ok(ResolvedSourceDecode::Yuv(ResolvedYuvInterpretation {
                matrix: ResolvedYuvMatrix::Bt2020,
                range: ResolvedSignalRange::Full,
            }))
        );
    }

    #[test]
    fn rgb_sources_do_not_enter_the_yuv_interpretation_route() {
        let mut descriptor = yuv_descriptor(EncodedColorMetadata::default());
        descriptor.pixel_encoding = PixelEncoding::Rgb;
        assert_eq!(
            descriptor.resolve_decode_interpretation(SourceDecodeInterpretation {
                matrix: YuvMatrixSelection::Auto,
                range: SignalRangeSelection::Auto,
            }),
            Ok(ResolvedSourceDecode::Rgb)
        );
    }

    #[test]
    fn monochrome_sources_require_range_but_not_matrix() {
        let mut descriptor = yuv_descriptor(EncodedColorMetadata {
            range: Some(SignalRange::Limited),
            ..EncodedColorMetadata::default()
        });
        descriptor.pixel_encoding = PixelEncoding::Monochrome;
        assert_eq!(
            descriptor.resolve_decode_interpretation(SourceDecodeInterpretation {
                matrix: YuvMatrixSelection::Auto,
                range: SignalRangeSelection::Auto,
            }),
            Ok(ResolvedSourceDecode::Monochrome(
                ResolvedSignalRange::Limited
            ))
        );
    }
}
