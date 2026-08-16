//! Host-neutral recording-codec contracts.
//!
//! This domain owns the lossy encode/decode round trip after an explicit Color-owned
//! recording-output transform. It does not develop a camera image, choose color, write a
//! container, or bind a platform encoder.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{EncodedColorMetadata, FrameRate};

pub const RECORDING_OUTPUT_SIGNAL_ARTIFACT_ID: &str = "recording-output-signal-v2";
pub const DECODED_RECORDING_SIGNAL_ARTIFACT_ID: &str = "decoded-recording-signal-v1";

pub const IPHONE_HEIC_PHOTO_PROFILE_ID: &str = "iphone-heic-photo-v1";
pub const GENERIC_JPEG_PHOTO_PROFILE_ID: &str = "generic-jpeg-photo-v1";
pub const GENERIC_HEVC_MAIN_VIDEO_PROFILE_ID: &str = "generic-hevc-main-video-v1";
pub const GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID: &str = "generic-hevc-main10-video-v1";
pub const GENERIC_H264_HIGH_VIDEO_PROFILE_ID: &str = "generic-h264-high-video-v1";
pub const GENERIC_PRORES_422_HQ_PROFILE_ID: &str = "generic-prores-422-hq-v1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingMedium {
    StillImage,
    MovingImage,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingCodecProfile {
    HeifHevcMainStillPicture,
    JpegStill,
    HevcMain,
    HevcMain10,
    HevcMain42210,
    H264High,
    ProRes422,
    ProRes422Hq,
    ProRes4444,
}

impl RecordingCodecProfile {
    pub const fn medium(self) -> RecordingMedium {
        match self {
            Self::HeifHevcMainStillPicture | Self::JpegStill => RecordingMedium::StillImage,
            Self::HevcMain
            | Self::HevcMain10
            | Self::HevcMain42210
            | Self::H264High
            | Self::ProRes422
            | Self::ProRes422Hq
            | Self::ProRes4444 => RecordingMedium::MovingImage,
        }
    }

    pub const fn is_intra_only(self) -> bool {
        matches!(
            self,
            Self::HeifHevcMainStillPicture
                | Self::JpegStill
                | Self::ProRes422
                | Self::ProRes422Hq
                | Self::ProRes4444
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChromaSampling {
    Yuv420,
    Yuv422,
    Yuv444,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChromaLocation {
    Left,
    Center,
    TopLeft,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AlphaPolicy {
    Opaque,
    Straight,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RateControl {
    /// Encoder-defined intra rate, used by fixed ProRes profiles.
    ProfileDefinedIntra,
    /// One independently coded still or intra picture.
    ConstantQuality {
        quality: f32,
    },
    ConstantQuantizer {
        qp: u8,
    },
    /// One causal pass with explicitly bounded future inspection.
    SinglePassTargetBitrate {
        bits_per_second: u64,
        lookahead_frames: u16,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EncoderExecutionPolicy {
    pub pass_count: u8,
    pub complete_clip_preanalysis: bool,
}

impl EncoderExecutionPolicy {
    pub const SINGLE_PASS: Self = Self {
        pass_count: 1,
        complete_clip_preanalysis: false,
    };

    pub fn validate(self) -> Result<Self, RecordingError> {
        if self.pass_count != 1 || self.complete_clip_preanalysis {
            return Err(RecordingError::GlobalOrMultiPassAnalysisForbidden);
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InterFrameStructure {
    pub fixed_gop_frames: u16,
    pub maximum_b_frames: u8,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecordingProfile {
    pub id: &'static str,
    pub codec: RecordingCodecProfile,
    pub bit_depth: u8,
    pub chroma_sampling: ChromaSampling,
    pub chroma_location: ChromaLocation,
    pub alpha_policy: AlphaPolicy,
    pub reference_rate_control: RateControl,
    pub inter_frame: Option<InterFrameStructure>,
}

impl RecordingProfile {
    pub fn validate(&self) -> Result<&Self, RecordingError> {
        if self.id.is_empty() || !(8..=12).contains(&self.bit_depth) {
            return Err(RecordingError::InvalidProfile);
        }
        validate_codec_format(
            self.codec,
            self.bit_depth,
            self.chroma_sampling,
            self.alpha_policy,
        )?;
        validate_rate_control(self.codec, self.reference_rate_control)?;
        match (self.codec.is_intra_only(), self.inter_frame) {
            (true, None) => {}
            (false, Some(inter)) if inter.fixed_gop_frames > 0 => {
                if u16::from(inter.maximum_b_frames) >= inter.fixed_gop_frames {
                    return Err(RecordingError::InvalidInterFrameStructure);
                }
            }
            _ => return Err(RecordingError::InvalidInterFrameStructure),
        }
        Ok(self)
    }

    pub fn temporal_requirement(&self) -> Result<RecordingTemporalRequirement, RecordingError> {
        self.validate()?;
        let lookahead = match self.reference_rate_control {
            RateControl::SinglePassTargetBitrate {
                lookahead_frames, ..
            } => lookahead_frames,
            _ => 0,
        };
        let future_frames = self
            .inter_frame
            .map_or(0, |inter| lookahead.max(u16::from(inter.maximum_b_frames)));
        Ok(RecordingTemporalRequirement {
            chronological_sequence_required: self.codec.medium() == RecordingMedium::MovingImage,
            future_frames,
            complete_clip_preanalysis: false,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RecordingTemporalRequirement {
    /// Moving-image adapters consume frames in exact chronological order and retain codec state.
    pub chronological_sequence_required: bool,
    /// Finite future window required by B pictures or causal rate-control lookahead.
    pub future_frames: u16,
    pub complete_clip_preanalysis: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RecordingRequest<'a> {
    pub profile: &'a RecordingProfile,
    /// Zero is an exact encode/decode bypass, one is calibrated, and values above one increase
    /// compression pressure without changing profile identity.
    pub character: f32,
    pub frame_rate: Option<FrameRate>,
    pub first_frame_index: i64,
    pub frame_count: u64,
    pub execution: EncoderExecutionPolicy,
}

impl RecordingRequest<'_> {
    pub fn validate(self) -> Result<Self, RecordingError> {
        self.profile.validate()?;
        self.execution.validate()?;
        if !self.character.is_finite() || !(0.0..=4.0).contains(&self.character) {
            return Err(RecordingError::InvalidCharacter);
        }
        match self.profile.codec.medium() {
            RecordingMedium::StillImage if self.frame_rate.is_none() && self.frame_count == 1 => {}
            RecordingMedium::MovingImage if self.frame_rate.is_some() && self.frame_count > 0 => {}
            _ => return Err(RecordingError::InvalidSequence),
        }
        Ok(self)
    }
}

/// Exact nonlinear recording signal produced by Color before subsampling or codec quantization.
#[derive(Clone, Debug, PartialEq)]
pub struct RecordingOutputSignal {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<[f32; 4]>,
    pub color: EncodedColorMetadata,
    pub alpha_policy: AlphaPolicy,
}

/// One exact frame supplied to a moving-image encoder. The index is part of the
/// contract so a host cannot silently repeat or reorder the current Viewer frame.
#[derive(Clone, Debug, PartialEq)]
pub struct RecordingSequenceFrame {
    pub frame_index: i64,
    pub signal: RecordingOutputSignal,
}

pub fn validate_sequence_frames(
    request: RecordingRequest<'_>,
    frames: &[RecordingSequenceFrame],
) -> Result<(), RecordingError> {
    request.validate()?;
    if frames.len()
        != usize::try_from(request.frame_count).map_err(|_| RecordingError::InvalidSequence)?
    {
        return Err(RecordingError::InvalidSequence);
    }
    for (offset, frame) in frames.iter().enumerate() {
        let offset = i64::try_from(offset).map_err(|_| RecordingError::InvalidSequence)?;
        let expected = request
            .first_frame_index
            .checked_add(offset)
            .ok_or(RecordingError::InvalidSequence)?;
        if frame.frame_index != expected {
            return Err(RecordingError::NonChronologicalSequence);
        }
        frame.signal.validate()?;
        if let Some(first) = frames.first()
            && (frame.signal.width != first.signal.width
                || frame.signal.height != first.signal.height
                || frame.signal.color != first.signal.color
                || frame.signal.alpha_policy != first.signal.alpha_policy)
        {
            return Err(RecordingError::InconsistentSequence);
        }
    }
    Ok(())
}

impl RecordingOutputSignal {
    pub fn validate(&self) -> Result<&Self, RecordingError> {
        let expected = usize::try_from(self.width)
            .ok()
            .and_then(|width| {
                usize::try_from(self.height)
                    .ok()
                    .and_then(|height| width.checked_mul(height))
            })
            .ok_or(RecordingError::InvalidRaster)?;
        if self.width == 0
            || self.height == 0
            || self.rgba.len() != expected
            || self.color.primaries.is_none()
            || self.color.transfer.is_none()
            || self.color.matrix.is_none()
            || self.color.range.is_none()
            || self
                .rgba
                .iter()
                .flatten()
                .any(|value| !value.is_finite() || !(0.0..=1.0).contains(value))
        {
            return Err(RecordingError::InvalidRaster);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EncodedPayloadEvidence {
    Bypassed,
    Encoded { byte_count: u64, sha256: [u8; 32] },
}

#[derive(Clone, Debug, PartialEq)]
pub struct DecodedRecordingSignal {
    pub profile_id: String,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<[f32; 4]>,
    pub color: EncodedColorMetadata,
    pub evidence: EncodedPayloadEvidence,
}

pub trait RecordingCodecAdapter {
    type Error;

    /// Encodes and decodes the exact request. The adapter may not choose another profile, color
    /// interpretation, rate-control mode, frame order, or temporal window.
    fn round_trip(
        &mut self,
        request: RecordingRequest<'_>,
        frames: &[RecordingSequenceFrame],
    ) -> Result<Vec<DecodedRecordingSignal>, Self::Error>;
}

pub fn bundled_profiles() -> [RecordingProfile; 6] {
    [
        RecordingProfile {
            id: IPHONE_HEIC_PHOTO_PROFILE_ID,
            codec: RecordingCodecProfile::HeifHevcMainStillPicture,
            bit_depth: 8,
            chroma_sampling: ChromaSampling::Yuv420,
            chroma_location: ChromaLocation::Left,
            alpha_policy: AlphaPolicy::Opaque,
            reference_rate_control: RateControl::ConstantQuality { quality: 0.82 },
            inter_frame: None,
        },
        RecordingProfile {
            id: GENERIC_JPEG_PHOTO_PROFILE_ID,
            codec: RecordingCodecProfile::JpegStill,
            bit_depth: 8,
            chroma_sampling: ChromaSampling::Yuv420,
            chroma_location: ChromaLocation::Center,
            alpha_policy: AlphaPolicy::Opaque,
            reference_rate_control: RateControl::ConstantQuality { quality: 0.90 },
            inter_frame: None,
        },
        RecordingProfile {
            id: GENERIC_HEVC_MAIN_VIDEO_PROFILE_ID,
            codec: RecordingCodecProfile::HevcMain,
            bit_depth: 8,
            chroma_sampling: ChromaSampling::Yuv420,
            chroma_location: ChromaLocation::Left,
            alpha_policy: AlphaPolicy::Opaque,
            reference_rate_control: RateControl::SinglePassTargetBitrate {
                bits_per_second: 80_000_000,
                lookahead_frames: 16,
            },
            inter_frame: Some(InterFrameStructure {
                fixed_gop_frames: 48,
                maximum_b_frames: 2,
            }),
        },
        RecordingProfile {
            id: GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID,
            codec: RecordingCodecProfile::HevcMain10,
            bit_depth: 10,
            chroma_sampling: ChromaSampling::Yuv420,
            chroma_location: ChromaLocation::Left,
            alpha_policy: AlphaPolicy::Opaque,
            reference_rate_control: RateControl::SinglePassTargetBitrate {
                bits_per_second: 80_000_000,
                lookahead_frames: 16,
            },
            inter_frame: Some(InterFrameStructure {
                fixed_gop_frames: 48,
                maximum_b_frames: 2,
            }),
        },
        RecordingProfile {
            id: GENERIC_H264_HIGH_VIDEO_PROFILE_ID,
            codec: RecordingCodecProfile::H264High,
            bit_depth: 8,
            chroma_sampling: ChromaSampling::Yuv420,
            chroma_location: ChromaLocation::Left,
            alpha_policy: AlphaPolicy::Opaque,
            reference_rate_control: RateControl::SinglePassTargetBitrate {
                bits_per_second: 100_000_000,
                lookahead_frames: 16,
            },
            inter_frame: Some(InterFrameStructure {
                fixed_gop_frames: 48,
                maximum_b_frames: 2,
            }),
        },
        RecordingProfile {
            id: GENERIC_PRORES_422_HQ_PROFILE_ID,
            codec: RecordingCodecProfile::ProRes422Hq,
            bit_depth: 10,
            chroma_sampling: ChromaSampling::Yuv422,
            chroma_location: ChromaLocation::Left,
            alpha_policy: AlphaPolicy::Opaque,
            reference_rate_control: RateControl::ProfileDefinedIntra,
            inter_frame: None,
        },
    ]
}

fn validate_codec_format(
    codec: RecordingCodecProfile,
    bit_depth: u8,
    chroma: ChromaSampling,
    alpha: AlphaPolicy,
) -> Result<(), RecordingError> {
    let valid = match codec {
        RecordingCodecProfile::HeifHevcMainStillPicture
        | RecordingCodecProfile::HevcMain
        | RecordingCodecProfile::H264High => {
            bit_depth == 8 && chroma == ChromaSampling::Yuv420 && alpha == AlphaPolicy::Opaque
        }
        RecordingCodecProfile::HevcMain10 => {
            bit_depth == 10 && chroma == ChromaSampling::Yuv420 && alpha == AlphaPolicy::Opaque
        }
        RecordingCodecProfile::HevcMain42210
        | RecordingCodecProfile::ProRes422
        | RecordingCodecProfile::ProRes422Hq => {
            bit_depth == 10 && chroma == ChromaSampling::Yuv422 && alpha == AlphaPolicy::Opaque
        }
        RecordingCodecProfile::JpegStill => bit_depth == 8 && alpha == AlphaPolicy::Opaque,
        RecordingCodecProfile::ProRes4444 => bit_depth == 12 && chroma == ChromaSampling::Yuv444,
    };
    if valid {
        Ok(())
    } else {
        Err(RecordingError::UnsupportedCodecFormat)
    }
}

fn validate_rate_control(
    codec: RecordingCodecProfile,
    rate: RateControl,
) -> Result<(), RecordingError> {
    let valid = match rate {
        RateControl::ProfileDefinedIntra => matches!(
            codec,
            RecordingCodecProfile::ProRes422
                | RecordingCodecProfile::ProRes422Hq
                | RecordingCodecProfile::ProRes4444
        ),
        RateControl::ConstantQuality { quality } => {
            quality.is_finite() && (0.0..=1.0).contains(&quality)
        }
        RateControl::ConstantQuantizer { qp } => {
            qp <= 63
                && !matches!(
                    codec,
                    RecordingCodecProfile::ProRes422
                        | RecordingCodecProfile::ProRes422Hq
                        | RecordingCodecProfile::ProRes4444
                )
        }
        RateControl::SinglePassTargetBitrate {
            bits_per_second,
            lookahead_frames,
        } => bits_per_second > 0 && lookahead_frames <= 120 && !codec.is_intra_only(),
    };
    if valid {
        Ok(())
    } else {
        Err(RecordingError::InvalidRateControl)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingError {
    InvalidProfile,
    UnsupportedCodecFormat,
    InvalidRateControl,
    InvalidInterFrameStructure,
    InvalidCharacter,
    InvalidSequence,
    NonChronologicalSequence,
    InconsistentSequence,
    InvalidRaster,
    GlobalOrMultiPassAnalysisForbidden,
}

impl fmt::Display for RecordingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidProfile => "invalid recording profile",
            Self::UnsupportedCodecFormat => "codec profile does not support the authored bit depth, chroma sampling, or alpha policy",
            Self::InvalidRateControl => "invalid or incompatible recording rate control",
            Self::InvalidInterFrameStructure => "invalid intra/GOP/B-frame structure",
            Self::InvalidCharacter => "recording character must be finite in 0...4",
            Self::InvalidSequence => "recording medium does not match the authored frame sequence",
            Self::NonChronologicalSequence => "moving-image frames must be supplied once in exact chronological order",
            Self::InconsistentSequence => "moving-image frames must share one raster, color declaration, and alpha policy",
            Self::InvalidRaster => "invalid recording-output signal raster",
            Self::GlobalOrMultiPassAnalysisForbidden => "recording requires one causal pass; full-clip preanalysis and multiple passes are forbidden",
        })
    }
}

impl std::error::Error for RecordingError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_profiles_are_unique_and_valid() {
        let profiles = bundled_profiles();
        for (index, profile) in profiles.iter().enumerate() {
            profile.validate().expect("valid bundled recording profile");
            assert!(profiles[..index].iter().all(|prior| prior.id != profile.id));
        }
    }

    #[test]
    fn iphone_heic_is_one_intra_still_without_temporal_state() {
        let profile = &bundled_profiles()[0];
        assert_eq!(
            profile.codec,
            RecordingCodecProfile::HeifHevcMainStillPicture
        );
        assert_eq!(profile.codec.medium(), RecordingMedium::StillImage);
        assert!(profile.codec.is_intra_only());
        assert_eq!(profile.inter_frame, None);
        assert_eq!(
            profile
                .temporal_requirement()
                .expect("requirement")
                .future_frames,
            0
        );
    }

    #[test]
    fn main10_and_main42210_are_not_conflated() {
        assert!(
            validate_codec_format(
                RecordingCodecProfile::HevcMain10,
                10,
                ChromaSampling::Yuv420,
                AlphaPolicy::Opaque
            )
            .is_ok()
        );
        assert_eq!(
            validate_codec_format(
                RecordingCodecProfile::HevcMain10,
                10,
                ChromaSampling::Yuv422,
                AlphaPolicy::Opaque
            ),
            Err(RecordingError::UnsupportedCodecFormat)
        );
        assert!(
            validate_codec_format(
                RecordingCodecProfile::HevcMain42210,
                10,
                ChromaSampling::Yuv422,
                AlphaPolicy::Opaque
            )
            .is_ok()
        );
    }

    #[test]
    fn full_clip_and_multi_pass_analysis_are_rejected() {
        assert_eq!(
            EncoderExecutionPolicy {
                pass_count: 2,
                complete_clip_preanalysis: false
            }
            .validate(),
            Err(RecordingError::GlobalOrMultiPassAnalysisForbidden)
        );
        assert_eq!(
            EncoderExecutionPolicy {
                pass_count: 1,
                complete_clip_preanalysis: true
            }
            .validate(),
            Err(RecordingError::GlobalOrMultiPassAnalysisForbidden)
        );
    }

    #[test]
    fn video_requirement_is_bounded_and_never_requests_complete_clip_analysis() {
        let profile = &bundled_profiles()[2];
        let requirement = profile.temporal_requirement().expect("requirement");
        assert!(requirement.chronological_sequence_required);
        assert_eq!(requirement.future_frames, 16);
        assert!(!requirement.complete_clip_preanalysis);
    }

    #[test]
    fn still_and_video_requests_require_exact_sequence_shapes() {
        let profiles = bundled_profiles();
        let still = RecordingRequest {
            profile: &profiles[0],
            character: 1.0,
            frame_rate: None,
            first_frame_index: 0,
            frame_count: 1,
            execution: EncoderExecutionPolicy::SINGLE_PASS,
        };
        assert!(still.validate().is_ok());
        let video = RecordingRequest {
            profile: &profiles[2],
            character: 1.0,
            frame_rate: Some(FrameRate::new(24, 1).expect("rate")),
            first_frame_index: 0,
            frame_count: 240,
            execution: EncoderExecutionPolicy::SINGLE_PASS,
        };
        assert!(video.validate().is_ok());
        assert_eq!(
            RecordingRequest {
                frame_rate: None,
                ..video
            }
            .validate(),
            Err(RecordingError::InvalidSequence)
        );
    }

    fn signal(value: f32) -> RecordingOutputSignal {
        RecordingOutputSignal {
            width: 1,
            height: 1,
            rgba: vec![[value, value, value, 1.0]],
            color: EncodedColorMetadata {
                primaries: Some(screen_contracts::ColorPrimaries::Bt709),
                transfer: Some(screen_contracts::TransferCharacteristic::Bt709),
                matrix: Some(screen_contracts::MatrixCoefficients::Rgb),
                range: Some(screen_contracts::SignalRange::Full),
            },
            alpha_policy: AlphaPolicy::Opaque,
        }
    }

    #[test]
    fn moving_frames_must_be_complete_and_chronological() {
        let profiles = bundled_profiles();
        let request = RecordingRequest {
            profile: &profiles[2],
            character: 1.0,
            frame_rate: Some(FrameRate::new(24, 1).expect("rate")),
            first_frame_index: 1001,
            frame_count: 3,
            execution: EncoderExecutionPolicy::SINGLE_PASS,
        };
        let valid = [
            RecordingSequenceFrame {
                frame_index: 1001,
                signal: signal(0.1),
            },
            RecordingSequenceFrame {
                frame_index: 1002,
                signal: signal(0.2),
            },
            RecordingSequenceFrame {
                frame_index: 1003,
                signal: signal(0.3),
            },
        ];
        assert_eq!(validate_sequence_frames(request, &valid), Ok(()));
        let mut reordered = valid.clone();
        reordered.swap(1, 2);
        assert_eq!(
            validate_sequence_frames(request, &reordered),
            Err(RecordingError::NonChronologicalSequence)
        );
        assert_eq!(
            validate_sequence_frames(request, &valid[..2]),
            Err(RecordingError::InvalidSequence)
        );
    }
}
