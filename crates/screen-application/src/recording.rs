//! Immutable preparation of an authored recording-codec selection.
//!
//! Application resolves one exact Recording-owned profile and exposes only the
//! controls that profile implements. It does not encode media or reinterpret a
//! profile selected by the author.

use core::fmt;
use screen_contracts::FrameRate;
use screen_recording::{
    EncoderExecutionPolicy, InterFrameStructure, RateControl, RecordingCodecProfile,
    RecordingError, RecordingMedium, RecordingProfile, RecordingRequest,
    RecordingTemporalRequirement, bundled_profiles,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingAdapterKind {
    ImageIoHeic,
    ImageIoJpeg,
    AvFoundationHevcMain8,
    AvFoundationH264High8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingAdapterUnavailableReason {
    NativeTenBit420InputNotImplemented,
    NativeTenBit422InputNotImplemented,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingAdapterAvailability {
    Available(RecordingAdapterKind),
    Unavailable(RecordingAdapterUnavailableReason),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ResolvedRateControl {
    ProfileDefinedIntra,
    ConstantQuality(f32),
    ConstantQuantizer(u8),
    SinglePassTargetBitrate {
        bits_per_second: u64,
        lookahead_frames: u16,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingCharacterInterpretation {
    /// Exact codec bypass. No encode/decode loss is introduced.
    Bypassed,
    /// Less compression character than the calibrated profile.
    Reduced,
    /// The calibrated profile is used without creative scaling.
    Calibrated,
    /// Compression character is intentionally increased for diagnosis or look development.
    Exaggerated,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ConditionalRecordingControl<T> {
    Unavailable,
    Available { calibrated_value: T },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RecordingControlAvailability {
    pub quality: ConditionalRecordingControl<f32>,
    pub quantizer: ConditionalRecordingControl<u8>,
    pub target_bits_per_second: ConditionalRecordingControl<u64>,
    pub lookahead_frames: ConditionalRecordingControl<u16>,
    pub fixed_gop_frames: ConditionalRecordingControl<u16>,
    pub maximum_b_frames: ConditionalRecordingControl<u8>,
}

impl RecordingControlAvailability {
    fn from_profile(profile: &RecordingProfile) -> Self {
        let mut controls = Self {
            quality: ConditionalRecordingControl::Unavailable,
            quantizer: ConditionalRecordingControl::Unavailable,
            target_bits_per_second: ConditionalRecordingControl::Unavailable,
            lookahead_frames: ConditionalRecordingControl::Unavailable,
            fixed_gop_frames: ConditionalRecordingControl::Unavailable,
            maximum_b_frames: ConditionalRecordingControl::Unavailable,
        };
        match profile.reference_rate_control {
            RateControl::ProfileDefinedIntra => {}
            RateControl::ConstantQuality { quality } => {
                controls.quality = ConditionalRecordingControl::Available {
                    calibrated_value: quality,
                };
            }
            RateControl::ConstantQuantizer { qp } => {
                controls.quantizer = ConditionalRecordingControl::Available {
                    calibrated_value: qp,
                };
            }
            RateControl::SinglePassTargetBitrate {
                bits_per_second,
                lookahead_frames,
            } => {
                controls.target_bits_per_second = ConditionalRecordingControl::Available {
                    calibrated_value: bits_per_second,
                };
                controls.lookahead_frames = ConditionalRecordingControl::Available {
                    calibrated_value: lookahead_frames,
                };
            }
        }
        if let Some(InterFrameStructure {
            fixed_gop_frames,
            maximum_b_frames,
        }) = profile.inter_frame
        {
            controls.fixed_gop_frames = ConditionalRecordingControl::Available {
                calibrated_value: fixed_gop_frames,
            };
            controls.maximum_b_frames = ConditionalRecordingControl::Available {
                calibrated_value: maximum_b_frames,
            };
        }
        controls
    }
}

/// Complete authored selection at the Application boundary. Profile identity is
/// exact and is never inferred from a filename, container, or media extension.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RecordingSelection<'a> {
    pub profile_id: &'a str,
    pub character: f32,
    pub frame_rate: Option<FrameRate>,
    pub first_frame_index: i64,
    pub frame_count: u64,
    pub execution: EncoderExecutionPolicy,
}

/// One immutable request ready for a host codec adapter.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedRecordingRequest {
    pub profile: RecordingProfile,
    pub character: f32,
    pub character_interpretation: RecordingCharacterInterpretation,
    pub frame_rate: Option<FrameRate>,
    pub first_frame_index: i64,
    pub frame_count: u64,
    pub execution: EncoderExecutionPolicy,
    pub controls: RecordingControlAvailability,
    pub temporal_requirement: RecordingTemporalRequirement,
    pub adapter: RecordingAdapterAvailability,
    pub rate_control: ResolvedRateControl,
}

impl PreparedRecordingRequest {
    pub fn as_recording_request(&self) -> RecordingRequest<'_> {
        RecordingRequest {
            profile: &self.profile,
            character: self.character,
            frame_rate: self.frame_rate,
            first_frame_index: self.first_frame_index,
            frame_count: self.frame_count,
            execution: self.execution,
        }
    }
}

pub fn prepare_recording_request(
    selection: RecordingSelection<'_>,
) -> Result<PreparedRecordingRequest, RecordingPreparationError> {
    let profile = bundled_profiles()
        .into_iter()
        .find(|profile| profile.id == selection.profile_id)
        .ok_or_else(|| {
            RecordingPreparationError::UnknownProfile(selection.profile_id.to_owned())
        })?;

    RecordingRequest {
        profile: &profile,
        character: selection.character,
        frame_rate: selection.frame_rate,
        first_frame_index: selection.first_frame_index,
        frame_count: selection.frame_count,
        execution: selection.execution,
    }
    .validate()
    .map_err(RecordingPreparationError::InvalidRequest)?;
    let temporal_requirement = profile
        .temporal_requirement()
        .map_err(RecordingPreparationError::InvalidRequest)?;
    let controls = RecordingControlAvailability::from_profile(&profile);
    let character_interpretation = match selection.character {
        0.0 => RecordingCharacterInterpretation::Bypassed,
        value if value < 1.0 => RecordingCharacterInterpretation::Reduced,
        1.0 => RecordingCharacterInterpretation::Calibrated,
        _ => RecordingCharacterInterpretation::Exaggerated,
    };
    let adapter = match profile.codec {
        RecordingCodecProfile::HeifHevcMainStillPicture => {
            RecordingAdapterAvailability::Available(RecordingAdapterKind::ImageIoHeic)
        }
        RecordingCodecProfile::JpegStill => {
            RecordingAdapterAvailability::Available(RecordingAdapterKind::ImageIoJpeg)
        }
        RecordingCodecProfile::HevcMain => {
            RecordingAdapterAvailability::Available(RecordingAdapterKind::AvFoundationHevcMain8)
        }
        RecordingCodecProfile::H264High => {
            RecordingAdapterAvailability::Available(RecordingAdapterKind::AvFoundationH264High8)
        }
        RecordingCodecProfile::HevcMain10 => RecordingAdapterAvailability::Unavailable(
            RecordingAdapterUnavailableReason::NativeTenBit420InputNotImplemented,
        ),
        RecordingCodecProfile::HevcMain42210
        | RecordingCodecProfile::ProRes422
        | RecordingCodecProfile::ProRes422Hq
        | RecordingCodecProfile::ProRes4444 => RecordingAdapterAvailability::Unavailable(
            RecordingAdapterUnavailableReason::NativeTenBit422InputNotImplemented,
        ),
    };
    let pressure = selection.character.max(0.25);
    let rate_control = match profile.reference_rate_control {
        RateControl::ProfileDefinedIntra => ResolvedRateControl::ProfileDefinedIntra,
        RateControl::ConstantQuality { quality } => {
            ResolvedRateControl::ConstantQuality((quality / pressure).clamp(0.0, 1.0))
        }
        RateControl::ConstantQuantizer { qp } => ResolvedRateControl::ConstantQuantizer(qp),
        RateControl::SinglePassTargetBitrate {
            bits_per_second,
            lookahead_frames,
        } => ResolvedRateControl::SinglePassTargetBitrate {
            bits_per_second: ((bits_per_second as f64) / f64::from(pressure)).round() as u64,
            lookahead_frames,
        },
    };

    Ok(PreparedRecordingRequest {
        profile,
        character: selection.character,
        character_interpretation,
        frame_rate: selection.frame_rate,
        first_frame_index: selection.first_frame_index,
        frame_count: selection.frame_count,
        execution: selection.execution,
        controls,
        temporal_requirement,
        adapter,
        rate_control,
    })
}

/// Prepares a host execution request from project timing. Application, rather
/// than the host adapter, decides whether that timing belongs to a still or a
/// moving-image contract.
pub fn prepare_recording_execution_request(
    profile_id: &str,
    character: f32,
    project_frame_rate: FrameRate,
    first_frame_index: i64,
    frame_count: u64,
) -> Result<PreparedRecordingRequest, RecordingPreparationError> {
    let profile = bundled_profiles()
        .into_iter()
        .find(|profile| profile.id == profile_id)
        .ok_or_else(|| RecordingPreparationError::UnknownProfile(profile_id.to_owned()))?;
    let (frame_rate, first_frame_index, frame_count) = match profile.codec.medium() {
        RecordingMedium::StillImage => (None, first_frame_index, 1),
        RecordingMedium::MovingImage => (Some(project_frame_rate), first_frame_index, frame_count),
    };
    prepare_recording_request(RecordingSelection {
        profile_id,
        character,
        frame_rate,
        first_frame_index,
        frame_count,
        execution: EncoderExecutionPolicy::SINGLE_PASS,
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordingPreparationError {
    UnknownProfile(String),
    InvalidRequest(RecordingError),
}

impl fmt::Display for RecordingPreparationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownProfile(id) => write!(formatter, "unknown recording profile `{id}`"),
            Self::InvalidRequest(error) => write!(formatter, "invalid recording request: {error}"),
        }
    }
}

impl std::error::Error for RecordingPreparationError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::UnknownProfile(_) => None,
            Self::InvalidRequest(error) => Some(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_contracts::FrameRate;
    use screen_recording::{GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID, IPHONE_HEIC_PHOTO_PROFILE_ID};

    fn still(character: f32) -> RecordingSelection<'static> {
        RecordingSelection {
            profile_id: IPHONE_HEIC_PHOTO_PROFILE_ID,
            character,
            frame_rate: None,
            first_frame_index: 0,
            frame_count: 1,
            execution: EncoderExecutionPolicy::SINGLE_PASS,
        }
    }

    #[test]
    fn exact_profile_identity_is_required() {
        let error = prepare_recording_request(RecordingSelection {
            profile_id: "iphone-heic-photo",
            ..still(1.0)
        })
        .expect_err("aliases are not accepted");
        assert_eq!(
            error,
            RecordingPreparationError::UnknownProfile("iphone-heic-photo".to_owned())
        );
    }

    #[test]
    fn still_profile_exposes_only_its_quality_control() {
        let prepared = prepare_recording_request(still(1.0)).expect("prepared still");
        assert_eq!(
            prepared.controls.quality,
            ConditionalRecordingControl::Available {
                calibrated_value: 0.82
            }
        );
        assert_eq!(
            prepared.controls.target_bits_per_second,
            ConditionalRecordingControl::Unavailable
        );
        assert_eq!(
            prepared.controls.fixed_gop_frames,
            ConditionalRecordingControl::Unavailable
        );
        assert!(
            !prepared
                .temporal_requirement
                .chronological_sequence_required
        );
        assert_eq!(prepared.temporal_requirement.future_frames, 0);
    }

    #[test]
    fn moving_profile_exposes_bitrate_and_finite_temporal_controls() {
        let prepared = prepare_recording_request(RecordingSelection {
            profile_id: GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID,
            character: 1.0,
            frame_rate: Some(FrameRate::new(24, 1).expect("rate")),
            first_frame_index: 1001,
            frame_count: 96,
            execution: EncoderExecutionPolicy::SINGLE_PASS,
        })
        .expect("prepared moving image");
        assert_eq!(
            prepared.controls.target_bits_per_second,
            ConditionalRecordingControl::Available {
                calibrated_value: 80_000_000
            }
        );
        assert_eq!(
            prepared.controls.fixed_gop_frames,
            ConditionalRecordingControl::Available {
                calibrated_value: 48
            }
        );
        assert!(
            prepared
                .temporal_requirement
                .chronological_sequence_required
        );
        assert_eq!(prepared.temporal_requirement.future_frames, 16);
        assert!(!prepared.temporal_requirement.complete_clip_preanalysis);
    }

    #[test]
    fn character_points_and_intervals_have_explicit_meaning() {
        for (value, expected) in [
            (0.0, RecordingCharacterInterpretation::Bypassed),
            (0.5, RecordingCharacterInterpretation::Reduced),
            (1.0, RecordingCharacterInterpretation::Calibrated),
            (2.0, RecordingCharacterInterpretation::Exaggerated),
        ] {
            assert_eq!(
                prepare_recording_request(still(value))
                    .expect("valid character")
                    .character_interpretation,
                expected
            );
        }
    }

    #[test]
    fn invalid_sequence_and_character_are_not_repaired() {
        assert_eq!(
            prepare_recording_request(RecordingSelection {
                frame_rate: Some(FrameRate::new(24, 1).expect("rate")),
                ..still(1.0)
            }),
            Err(RecordingPreparationError::InvalidRequest(
                RecordingError::InvalidSequence
            ))
        );
        assert_eq!(
            prepare_recording_request(still(f32::NAN)),
            Err(RecordingPreparationError::InvalidRequest(
                RecordingError::InvalidCharacter
            ))
        );
    }

    #[test]
    fn prepared_request_reconstitutes_the_exact_recording_contract() {
        let prepared = prepare_recording_request(still(0.0)).expect("prepared bypass");
        let request = prepared.as_recording_request();
        request.validate().expect("valid domain request");
        assert_eq!(request.profile.id, IPHONE_HEIC_PHOTO_PROFILE_ID);
        assert_eq!(request.character, 0.0);
        assert_eq!(request.frame_count, 1);
        assert_eq!(request.execution, EncoderExecutionPolicy::SINGLE_PASS);
    }

    #[test]
    fn application_materializes_adapter_and_effective_rate_control() {
        let still = prepare_recording_request(still(2.0)).expect("prepared still");
        assert_eq!(
            still.adapter,
            RecordingAdapterAvailability::Available(RecordingAdapterKind::ImageIoHeic)
        );
        assert_eq!(
            still.rate_control,
            ResolvedRateControl::ConstantQuality(0.41)
        );

        let unavailable = prepare_recording_request(RecordingSelection {
            profile_id: GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID,
            character: 1.0,
            frame_rate: Some(FrameRate::new(24, 1).expect("rate")),
            first_frame_index: 0,
            frame_count: 24,
            execution: EncoderExecutionPolicy::SINGLE_PASS,
        })
        .expect("valid but unavailable profile");
        assert_eq!(
            unavailable.adapter,
            RecordingAdapterAvailability::Unavailable(
                RecordingAdapterUnavailableReason::NativeTenBit420InputNotImplemented
            )
        );
    }
}
