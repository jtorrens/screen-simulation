//! Explicit color interpretation and OpenColorIO ownership.

#![forbid(unsafe_code)]

use core::fmt;
use ocio_rs::{
    CPUProcessor, Config, GpuLanguage, GpuShaderDesc, GpuTextureChannel, Interpolation,
    TransformDirection,
};
use screen_contracts::{
    ColorPrimaries, DeviceRgb, EncodedColorMetadata, LinearRgb, MatrixCoefficients, SignalRange,
    TransferCharacteristic,
};

/// Shared scene-linear ACEScg adjustment used at explicit color boundaries.
/// It never chooses an input/output transform and preserves alpha externally.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneLinearAdjustment {
    pub exposure_ev: f32,
    pub contrast: f32,
    pub saturation: f32,
    pub temperature_kelvin: f32,
    pub tint: f32,
}

impl SceneLinearAdjustment {
    pub const NEUTRAL: Self = Self {
        exposure_ev: 0.0,
        contrast: 1.0,
        saturation: 1.0,
        temperature_kelvin: 6500.0,
        tint: 0.0,
    };

    pub fn validate(self) -> Result<Self, ColorError> {
        if !self.exposure_ev.is_finite()
            || !(-8.0..=8.0).contains(&self.exposure_ev)
            || !self.contrast.is_finite()
            || !(0.25..=4.0).contains(&self.contrast)
            || !self.saturation.is_finite()
            || !(0.0..=4.0).contains(&self.saturation)
            || !self.temperature_kelvin.is_finite()
            || !(2000.0..=12_000.0).contains(&self.temperature_kelvin)
            || !self.tint.is_finite()
            || !(-1.0..=1.0).contains(&self.tint)
        {
            return Err(ColorError::InvalidSceneLinearAdjustment);
        }
        Ok(self)
    }

    pub fn acescg_white_gains(self) -> Result<LinearRgb, ColorError> {
        self.validate()?;
        Ok(scene_linear_white_gains(self.temperature_kelvin, self.tint))
    }
}

pub fn apply_scene_linear_adjustment(
    input: LinearRgb,
    adjustment: SceneLinearAdjustment,
) -> Result<LinearRgb, ColorError> {
    let adjustment = adjustment.validate()?;
    if adjustment == SceneLinearAdjustment::NEUTRAL {
        return Ok(input);
    }
    let gains = scene_linear_white_gains(adjustment.temperature_kelvin, adjustment.tint);
    let exposure = adjustment.exposure_ev.exp2();
    let value = LinearRgb::new(
        signed_scene_contrast(input.r * exposure * gains.r, adjustment.contrast),
        signed_scene_contrast(input.g * exposure * gains.g, adjustment.contrast),
        signed_scene_contrast(input.b * exposure * gains.b, adjustment.contrast),
    );
    let luminance = value.r * 0.272_228_72 + value.g * 0.674_081_74 + value.b * 0.053_689_517;
    let result = LinearRgb::new(
        luminance + (value.r - luminance) * adjustment.saturation,
        luminance + (value.g - luminance) * adjustment.saturation,
        luminance + (value.b - luminance) * adjustment.saturation,
    );
    if [result.r, result.g, result.b]
        .into_iter()
        .any(|v| !v.is_finite())
    {
        return Err(ColorError::InvalidSceneLinearAdjustment);
    }
    Ok(result)
}

/// Converts an extended scene-linear result into physically non-negative incident
/// radiance by reducing chroma towards equal-energy luminance, never by clipping channels.
pub fn apply_incident_radiance_adjustment(
    input: LinearRgb,
    adjustment: SceneLinearAdjustment,
) -> Result<LinearRgb, ColorError> {
    if [input.r, input.g, input.b]
        .into_iter()
        .any(|v| !v.is_finite() || v < 0.0)
    {
        return Err(ColorError::InvalidSceneLinearAdjustment);
    }
    let adjusted = apply_scene_linear_adjustment(input, adjustment)?;
    if adjusted.r >= 0.0 && adjusted.g >= 0.0 && adjusted.b >= 0.0 {
        return Ok(adjusted);
    }
    let y = (adjusted.r * 0.272_228_72 + adjusted.g * 0.674_081_74 + adjusted.b * 0.053_689_517)
        .max(0.0);
    let mut scale = 1.0_f32;
    for channel in [adjusted.r, adjusted.g, adjusted.b] {
        if channel < 0.0 {
            scale = scale.min(y / (y - channel));
        }
    }
    Ok(LinearRgb::new(
        y + (adjusted.r - y) * scale,
        y + (adjusted.g - y) * scale,
        y + (adjusted.b - y) * scale,
    ))
}

fn signed_scene_contrast(value: f32, contrast: f32) -> f32 {
    value.signum() * 0.18 * (value.abs() / 0.18).powf(contrast)
}

fn scene_linear_white_gains(temperature_kelvin: f32, tint: f32) -> LinearRgb {
    let t = temperature_kelvin;
    let x = if t <= 4000.0 {
        -0.266_123_9e9 / t.powi(3) - 0.234_358e6 / t.powi(2) + 0.877_695_6e3 / t + 0.179_910
    } else {
        -3.025_846_9e9 / t.powi(3) + 2.107_038e6 / t.powi(2) + 0.222_634_7e3 / t + 0.240_390
    };
    let mut y = if t <= 2222.0 {
        -1.106_381_4 * x.powi(3) - 1.348_110_2 * x.powi(2) + 2.185_558_3 * x - 0.202_196_83
    } else if t <= 4000.0 {
        -0.954_947_6 * x.powi(3) - 1.374_185_9 * x.powi(2) + 2.091_370_2 * x - 0.167_488_67
    } else {
        3.081_758 * x.powi(3) - 5.873_387 * x.powi(2) + 3.751_129_9 * x - 0.370_014_83
    };
    y = (y + tint * 0.025).clamp(0.05, 0.85);
    let xyz = [x / y, 1.0, (1.0 - x - y) / y];
    let rgb = [
        1.641_023_4 * xyz[0] - 0.324_803_3 * xyz[1] - 0.236_424_7 * xyz[2],
        -0.663_662_9 * xyz[0] + 1.615_331_6 * xyz[1] + 0.016_756_35 * xyz[2],
        0.011_721_9 * xyz[0] - 0.008_284_44 * xyz[1] + 0.988_394_9 * xyz[2],
    ];
    let neutral = scene_linear_white_raw(6500.0);
    LinearRgb::new(
        rgb[0] / neutral[0],
        rgb[1] / neutral[1],
        rgb[2] / neutral[2],
    )
}

fn scene_linear_white_raw(t: f32) -> [f32; 3] {
    let x = -3.025_846_9e9 / t.powi(3) + 2.107_038e6 / t.powi(2) + 0.222_634_7e3 / t + 0.240_390;
    let y = 3.081_758 * x.powi(3) - 5.873_387 * x.powi(2) + 3.751_129_9 * x - 0.370_014_83;
    let xyz = [x / y, 1.0, (1.0 - x - y) / y];
    [
        1.641_023_4 * xyz[0] - 0.324_803_3 * xyz[1] - 0.236_424_7 * xyz[2],
        -0.663_662_9 * xyz[0] + 1.615_331_6 * xyz[1] + 0.016_756_35 * xyz[2],
        0.011_721_9 * xyz[0] - 0.008_284_44 * xyz[1] + 0.988_394_9 * xyz[2],
    ]
}

pub const OCIO_CONFIGURATION_ID: &str = "studio-config-v4.0.0_aces-v2.0_ocio-v2.5";
const ACESCG_COLOR_SPACE: &str = "ACEScg";
pub const RECORDING_OUTPUT_SIGNAL_ARTIFACT_ID: &str = "recording-output-signal-v2";
pub const IPHONE_HEIC_RECORDING_OUTPUT_TRANSFORM_ID: &str = "iphone-heic-display-p3-srgb-full-v2";
pub const GENERIC_SRGB_RECORDING_OUTPUT_TRANSFORM_ID: &str = "generic-srgb-recording-full-v1";
pub const GENERIC_REC709_RECORDING_OUTPUT_TRANSFORM_ID: &str = "generic-rec709-recording-full-v1";
pub const GENERIC_REC2100_PQ_RECORDING_OUTPUT_TRANSFORM_ID: &str =
    "generic-rec2100-pq-recording-full-v1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingOutputTransform {
    IphoneHeicDisplayP3SrgbFull,
    GenericSrgbFull,
    GenericRec709Full,
    GenericRec2100PqFull,
}

impl RecordingOutputTransform {
    pub const ALL: [Self; 4] = [
        Self::IphoneHeicDisplayP3SrgbFull,
        Self::GenericSrgbFull,
        Self::GenericRec709Full,
        Self::GenericRec2100PqFull,
    ];

    pub const fn stable_id(self) -> &'static str {
        match self {
            Self::IphoneHeicDisplayP3SrgbFull => IPHONE_HEIC_RECORDING_OUTPUT_TRANSFORM_ID,
            Self::GenericSrgbFull => GENERIC_SRGB_RECORDING_OUTPUT_TRANSFORM_ID,
            Self::GenericRec709Full => GENERIC_REC709_RECORDING_OUTPUT_TRANSFORM_ID,
            Self::GenericRec2100PqFull => GENERIC_REC2100_PQ_RECORDING_OUTPUT_TRANSFORM_ID,
        }
    }

    pub fn from_stable_id(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|transform| transform.stable_id() == value)
    }

    pub fn encoded_color(self) -> EncodedColorMetadata {
        match self {
            Self::IphoneHeicDisplayP3SrgbFull => EncodedColorMetadata {
                primaries: Some(ColorPrimaries::P3D65),
                transfer: Some(TransferCharacteristic::Srgb),
                matrix: Some(MatrixCoefficients::Rgb),
                range: Some(SignalRange::Full),
            },
            Self::GenericSrgbFull => EncodedColorMetadata {
                primaries: Some(ColorPrimaries::Bt709),
                transfer: Some(TransferCharacteristic::Srgb),
                matrix: Some(MatrixCoefficients::Rgb),
                range: Some(SignalRange::Full),
            },
            Self::GenericRec709Full => EncodedColorMetadata {
                primaries: Some(ColorPrimaries::Bt709),
                transfer: Some(TransferCharacteristic::Bt709),
                matrix: Some(MatrixCoefficients::Rgb),
                range: Some(SignalRange::Full),
            },
            Self::GenericRec2100PqFull => EncodedColorMetadata {
                primaries: Some(ColorPrimaries::Bt2020),
                transfer: Some(TransferCharacteristic::Pq),
                matrix: Some(MatrixCoefficients::Rgb),
                range: Some(SignalRange::Full),
            },
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingOutputAlpha {
    Opaque,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecordingOutputSignal {
    pub artifact_id: &'static str,
    pub transform: RecordingOutputTransform,
    pub width: u32,
    pub height: u32,
    /// Exact nonlinear RGB signal in RGBA float before quantization or chroma subsampling.
    pub rgba: Vec<[f32; 4]>,
    pub color: EncodedColorMetadata,
    pub alpha: RecordingOutputAlpha,
}

impl RecordingOutputSignal {
    pub fn validate(&self) -> Result<&Self, ColorError> {
        let expected = usize::try_from(self.width)
            .ok()
            .and_then(|width| {
                usize::try_from(self.height)
                    .ok()
                    .and_then(|height| width.checked_mul(height))
            })
            .ok_or(ColorError::InvalidRecordingOutputSignal)?;
        if self.artifact_id != RECORDING_OUTPUT_SIGNAL_ARTIFACT_ID
            || self.width == 0
            || self.height == 0
            || self.rgba.len() != expected
            || self.color != self.transform.encoded_color()
            || self.alpha != RecordingOutputAlpha::Opaque
            || self
                .rgba
                .iter()
                .any(|pixel| pixel.iter().any(|value| !value.is_finite()) || pixel[3] != 1.0)
        {
            return Err(ColorError::InvalidRecordingOutputSignal);
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameraOutputTransform {
    SrgbSdr100,
    Rec709Sdr100,
    Rec2100Pq1000,
}

impl CameraOutputTransform {
    pub const ALL: [Self; 3] = [Self::SrgbSdr100, Self::Rec709Sdr100, Self::Rec2100Pq1000];

    pub const fn stable_id(self) -> &'static str {
        match self {
            Self::SrgbSdr100 => "aces2-srgb-sdr-100",
            Self::Rec709Sdr100 => "aces2-rec709-sdr-100",
            Self::Rec2100Pq1000 => "aces2-rec2100-pq-1000",
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::SrgbSdr100 => "ACES 2.0 · sRGB SDR 100 nit",
            Self::Rec709Sdr100 => "ACES 2.0 · Rec.709 SDR 100 nit",
            Self::Rec2100Pq1000 => "ACES 2.0 · Rec.2100 PQ 1000 nit",
        }
    }

    pub fn from_stable_id(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|candidate| candidate.stable_id() == value)
    }

    const fn ocio_display(self) -> &'static str {
        match self {
            Self::SrgbSdr100 => "sRGB - Display",
            Self::Rec709Sdr100 => "Rec.1886 Rec.709 - Display",
            Self::Rec2100Pq1000 => "Rec.2100-PQ - Display",
        }
    }

    const fn ocio_view(self) -> &'static str {
        match self {
            Self::SrgbSdr100 | Self::Rec709Sdr100 => "ACES 2.0 - SDR 100 nits (Rec.709)",
            Self::Rec2100Pq1000 => "ACES 2.0 - HDR 1000 nits (Rec.2020)",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OcioInputTransform {
    AcesCct,
    AcesCg,
    DisplayRec709Gamma22Aces2Sdr,
    DisplayRec709Aces2Sdr,
    DisplaySrgbAces2Sdr,
    DisplayRec2100PqAces2Hdr1000,
    DisplayRec709Gamma22Dcm,
    DisplayRec2100PqDcm,
    DisplayRec2100HlgAces2Hdr1000,
    DisplayRec2100HlgDcm,
    SrgbEncodedRec709,
    LinearRec709,
    Rec709Gamma24Display,
    CameraRec709,
    ArriLogC3Ei800,
    ArriLogC4,
    BmdFilmWideGamutGen5,
    DavinciIntermediateWideGamut,
    CanonLog3CinemaGamutD55,
    VLogVGamut,
    Log3G10RedWideGamutRgb,
    SLog3SGamut3Cine,
}

impl OcioInputTransform {
    pub const ALL: [Self; 22] = [
        Self::AcesCct,
        Self::DisplayRec709Gamma22Aces2Sdr,
        Self::DisplayRec709Aces2Sdr,
        Self::DisplaySrgbAces2Sdr,
        Self::DisplayRec2100PqAces2Hdr1000,
        Self::DisplayRec709Gamma22Dcm,
        Self::Rec709Gamma24Display,
        Self::DisplayRec2100PqDcm,
        Self::DisplayRec2100HlgAces2Hdr1000,
        Self::DisplayRec2100HlgDcm,
        Self::CameraRec709,
        Self::SrgbEncodedRec709,
        Self::LinearRec709,
        Self::AcesCg,
        Self::ArriLogC3Ei800,
        Self::ArriLogC4,
        Self::BmdFilmWideGamutGen5,
        Self::DavinciIntermediateWideGamut,
        Self::CanonLog3CinemaGamutD55,
        Self::VLogVGamut,
        Self::Log3G10RedWideGamutRgb,
        Self::SLog3SGamut3Cine,
    ];

    pub const fn label(self) -> &'static str {
        match self {
            Self::AcesCct => "ACEScct / AP1",
            Self::AcesCg => "ACEScg",
            Self::DisplayRec709Gamma22Aces2Sdr => "Display Rec.709 Gamma 2.2 (ACES 2.0 SDR)",
            Self::DisplayRec709Aces2Sdr => "Display Rec.709 (ACES 2.0 SDR)",
            Self::DisplaySrgbAces2Sdr => "Display sRGB (ACES 2.0 SDR)",
            Self::DisplayRec2100PqAces2Hdr1000 => "Display Rec.2100 PQ (ACES 2.0 HDR 1000)",
            Self::DisplayRec709Gamma22Dcm => "Display Rec.709 Gamma 2.2 (DCM)",
            Self::DisplayRec2100PqDcm => "Display Rec.2100 ST2084 (DCM)",
            Self::DisplayRec2100HlgAces2Hdr1000 => {
                "Display Rec.2100 HLG (ACES 2.0 HDR 1000 P3-D65)"
            }
            Self::DisplayRec2100HlgDcm => "Display Rec.2100 HLG (DCM)",
            Self::SrgbEncodedRec709 => "sRGB encoded Rec.709",
            Self::LinearRec709 => "Linear Rec.709 (sRGB)",
            Self::Rec709Gamma24Display => "Display Rec.709 Gamma 2.4",
            Self::CameraRec709 => "Camera Rec.709",
            Self::ArriLogC3Ei800 => "ARRI LogC3 (EI800)",
            Self::ArriLogC4 => "ARRI LogC4",
            Self::BmdFilmWideGamutGen5 => "Blackmagic Film Gen 5",
            Self::DavinciIntermediateWideGamut => "DaVinci Intermediate Wide Gamut",
            Self::CanonLog3CinemaGamutD55 => "Canon Log 3 Cinema Gamut D55",
            Self::VLogVGamut => "V-Log V-Gamut",
            Self::Log3G10RedWideGamutRgb => "Log3G10 REDWideGamutRGB",
            Self::SLog3SGamut3Cine => "S-Log3 S-Gamut3.Cine",
        }
    }

    pub const fn stable_id(self) -> &'static str {
        match self {
            Self::AcesCct => "acescct",
            Self::AcesCg => "acescg",
            Self::DisplayRec709Gamma22Aces2Sdr => "display-rec709-gamma22-aces2-sdr",
            Self::DisplayRec709Aces2Sdr => "display-rec709-aces2-sdr",
            Self::DisplaySrgbAces2Sdr => "display-srgb-aces2-sdr",
            Self::DisplayRec2100PqAces2Hdr1000 => "display-rec2100-pq-aces2-hdr-1000",
            Self::DisplayRec709Gamma22Dcm => "display-rec709-gamma22-dcm",
            Self::DisplayRec2100PqDcm => "display-rec2100-pq-dcm",
            Self::DisplayRec2100HlgAces2Hdr1000 => "display-rec2100-hlg-aces2-hdr-1000",
            Self::DisplayRec2100HlgDcm => "display-rec2100-hlg-dcm",
            Self::SrgbEncodedRec709 => "srgb-encoded-rec709",
            Self::LinearRec709 => "linear-rec709",
            Self::Rec709Gamma24Display => "display-rec709-gamma24-dcm",
            Self::CameraRec709 => "input-rec709",
            Self::ArriLogC3Ei800 => "arri-logc3-ei800",
            Self::ArriLogC4 => "arri-logc4",
            Self::BmdFilmWideGamutGen5 => "bmd-film-gen5",
            Self::DavinciIntermediateWideGamut => "davinci-intermediate",
            Self::CanonLog3CinemaGamutD55 => "canon-log3",
            Self::VLogVGamut => "vlog-vgamut",
            Self::Log3G10RedWideGamutRgb => "log3g10",
            Self::SLog3SGamut3Cine => "slog3-sgamut3-cine",
        }
    }

    pub fn from_stable_id(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|candidate| candidate.stable_id() == value)
    }

    const fn processor(self) -> OcioInputProcessor {
        match self {
            Self::DisplayRec709Gamma22Aces2Sdr => OcioInputProcessor::InverseDisplay {
                display: "Gamma 2.2 Rec.709 - Display",
                view: "ACES 2.0 - SDR 100 nits (Rec.709)",
            },
            Self::DisplayRec709Aces2Sdr => OcioInputProcessor::InverseDisplay {
                display: "Rec.1886 Rec.709 - Display",
                view: "ACES 2.0 - SDR 100 nits (Rec.709)",
            },
            Self::DisplaySrgbAces2Sdr => OcioInputProcessor::InverseDisplay {
                display: "sRGB - Display",
                view: "ACES 2.0 - SDR 100 nits (Rec.709)",
            },
            Self::DisplayRec2100PqAces2Hdr1000 => OcioInputProcessor::InverseDisplay {
                display: "Rec.2100-PQ - Display",
                view: "ACES 2.0 - HDR 1000 nits (Rec.2020)",
            },
            Self::DisplayRec2100PqDcm => OcioInputProcessor::InverseDisplay {
                display: "Rec.2100-PQ - Display",
                view: "Video (colorimetric)",
            },
            Self::DisplayRec2100HlgAces2Hdr1000 => OcioInputProcessor::InverseDisplay {
                display: "Rec.2100-HLG - Display",
                view: "ACES 2.0 - HDR 1000 nits (P3 D65)",
            },
            Self::DisplayRec2100HlgDcm => OcioInputProcessor::InverseDisplay {
                display: "Rec.2100-HLG - Display",
                view: "Video (colorimetric)",
            },
            Self::AcesCct => OcioInputProcessor::ColorSpace("ACEScct"),
            Self::AcesCg => OcioInputProcessor::ColorSpace(ACESCG_COLOR_SPACE),
            Self::DisplayRec709Gamma22Dcm => {
                OcioInputProcessor::ColorSpace("Gamma 2.2 Encoded Rec.709")
            }
            Self::SrgbEncodedRec709 => {
                OcioInputProcessor::ColorSpace("sRGB Encoded Rec.709 (sRGB)")
            }
            Self::LinearRec709 => OcioInputProcessor::ColorSpace("Linear Rec.709 (sRGB)"),
            Self::Rec709Gamma24Display => {
                OcioInputProcessor::ColorSpace("Gamma 2.4 Encoded Rec.709")
            }
            Self::CameraRec709 => OcioInputProcessor::ColorSpace("Camera Rec.709"),
            Self::ArriLogC3Ei800 => OcioInputProcessor::ColorSpace("ARRI LogC3 (EI800)"),
            Self::ArriLogC4 => OcioInputProcessor::ColorSpace("ARRI LogC4"),
            Self::BmdFilmWideGamutGen5 => OcioInputProcessor::ColorSpace("BMDFilm WideGamut Gen5"),
            Self::DavinciIntermediateWideGamut => {
                OcioInputProcessor::ColorSpace("DaVinci Intermediate WideGamut")
            }
            Self::CanonLog3CinemaGamutD55 => {
                OcioInputProcessor::ColorSpace("CanonLog3 CinemaGamut D55")
            }
            Self::VLogVGamut => OcioInputProcessor::ColorSpace("V-Log V-Gamut"),
            Self::Log3G10RedWideGamutRgb => {
                OcioInputProcessor::ColorSpace("Log3G10 REDWideGamutRGB")
            }
            Self::SLog3SGamut3Cine => OcioInputProcessor::ColorSpace("S-Log3 S-Gamut3.Cine"),
        }
    }

    pub const fn reference_domain(self) -> SourceReferenceDomain {
        match self {
            Self::SrgbEncodedRec709
            | Self::DisplayRec709Gamma22Dcm
            | Self::Rec709Gamma24Display
            | Self::DisplayRec2100PqDcm
            | Self::DisplayRec2100HlgDcm => SourceReferenceDomain::DisplayReferred,
            Self::DisplayRec709Gamma22Aces2Sdr
            | Self::DisplayRec709Aces2Sdr
            | Self::DisplaySrgbAces2Sdr
            | Self::DisplayRec2100PqAces2Hdr1000
            | Self::DisplayRec2100HlgAces2Hdr1000 => SourceReferenceDomain::AcesOutputReferred,
            Self::AcesCct
            | Self::AcesCg
            | Self::LinearRec709
            | Self::CameraRec709
            | Self::ArriLogC3Ei800
            | Self::ArriLogC4
            | Self::BmdFilmWideGamutGen5
            | Self::DavinciIntermediateWideGamut
            | Self::CanonLog3CinemaGamutD55
            | Self::VLogVGamut
            | Self::Log3G10RedWideGamutRgb
            | Self::SLog3SGamut3Cine => SourceReferenceDomain::SceneReferred,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OcioInputProcessor {
    ColorSpace(&'static str),
    InverseDisplay {
        display: &'static str,
        view: &'static str,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceReferenceDomain {
    SceneReferred,
    DisplayReferred,
    AcesOutputReferred,
}

impl SourceReferenceDomain {
    pub const fn stable_id(self) -> &'static str {
        match self {
            Self::SceneReferred => "sceneReferred",
            Self::DisplayReferred => "displayReferred",
            Self::AcesOutputReferred => "acesOutputReferred",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceColorTarget {
    SrgbDisplay,
    Gamma22Rec709Display,
    Rec1886Rec709Display,
    Rec2100Pq1000Display,
    Rec2100Hlg1000Display,
}

impl DeviceColorTarget {
    pub const ALL: [Self; 5] = [
        Self::SrgbDisplay,
        Self::Gamma22Rec709Display,
        Self::Rec1886Rec709Display,
        Self::Rec2100Pq1000Display,
        Self::Rec2100Hlg1000Display,
    ];

    const fn ocio_display(self) -> &'static str {
        match self {
            Self::SrgbDisplay => "sRGB - Display",
            Self::Gamma22Rec709Display => "Gamma 2.2 Rec.709 - Display",
            Self::Rec1886Rec709Display => "Rec.1886 Rec.709 - Display",
            Self::Rec2100Pq1000Display => "Rec.2100-PQ - Display",
            Self::Rec2100Hlg1000Display => "Rec.2100-HLG - Display",
        }
    }

    const fn scene_view(self) -> &'static str {
        match self {
            Self::SrgbDisplay | Self::Gamma22Rec709Display | Self::Rec1886Rec709Display => {
                "ACES 2.0 - SDR 100 nits (Rec.709)"
            }
            Self::Rec2100Pq1000Display => "ACES 2.0 - HDR 1000 nits (Rec.2020)",
            Self::Rec2100Hlg1000Display => "ACES 2.0 - HDR 1000 nits (P3 D65)",
        }
    }

    const fn uses_display_processor_for_display_referred(self) -> bool {
        matches!(
            self,
            Self::Rec2100Pq1000Display | Self::Rec2100Hlg1000Display
        )
    }

    pub const fn stable_id(self) -> &'static str {
        match self {
            Self::SrgbDisplay => "srgb",
            Self::Gamma22Rec709Display => "rec709-gamma22",
            Self::Rec1886Rec709Display => "rec709-gamma24",
            Self::Rec2100Pq1000Display => "rec2100-pq-1000",
            Self::Rec2100Hlg1000Display => "rec2100-hlg-1000",
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::SrgbDisplay => "sRGB",
            Self::Gamma22Rec709Display => "Rec.709 Gamma 2.2",
            Self::Rec1886Rec709Display => "Rec.709 / Rec.1886 Gamma 2.4",
            Self::Rec2100Pq1000Display => "Rec.2100 PQ · 1000 nit",
            Self::Rec2100Hlg1000Display => "Rec.2100 HLG · 1000 nit · P3-D65",
        }
    }

    pub fn from_stable_id(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|target| target.stable_id() == value)
    }

    pub const fn feeder_output_id(self, domain: SourceReferenceDomain) -> &'static str {
        match (self, domain) {
            (Self::SrgbDisplay, SourceReferenceDomain::DisplayReferred) => {
                "device-srgb-colorimetric"
            }
            (
                Self::SrgbDisplay,
                SourceReferenceDomain::SceneReferred | SourceReferenceDomain::AcesOutputReferred,
            ) => "aces2-srgb-sdr-100",
            (Self::Gamma22Rec709Display, SourceReferenceDomain::DisplayReferred) => {
                "device-rec709-gamma22-colorimetric"
            }
            (
                Self::Gamma22Rec709Display,
                SourceReferenceDomain::SceneReferred | SourceReferenceDomain::AcesOutputReferred,
            ) => "aces2-rec709-gamma22-sdr-100",
            (Self::Rec1886Rec709Display, SourceReferenceDomain::DisplayReferred) => {
                "device-rec709-gamma24-colorimetric"
            }
            (
                Self::Rec1886Rec709Display,
                SourceReferenceDomain::SceneReferred | SourceReferenceDomain::AcesOutputReferred,
            ) => "aces2-rec709-sdr-100",
            (Self::Rec2100Pq1000Display, SourceReferenceDomain::DisplayReferred) => {
                "device-rec2100-pq-colorimetric"
            }
            (
                Self::Rec2100Pq1000Display,
                SourceReferenceDomain::SceneReferred | SourceReferenceDomain::AcesOutputReferred,
            ) => "aces2-rec2100-pq-1000",
            (Self::Rec2100Hlg1000Display, SourceReferenceDomain::DisplayReferred) => {
                "device-rec2100-hlg-colorimetric"
            }
            (
                Self::Rec2100Hlg1000Display,
                SourceReferenceDomain::SceneReferred | SourceReferenceDomain::AcesOutputReferred,
            ) => "aces2-rec2100-hlg-1000",
        }
    }

    const fn ocio_color_space(self) -> &'static str {
        match self {
            Self::SrgbDisplay => "sRGB Encoded Rec.709 (sRGB)",
            Self::Gamma22Rec709Display => "Gamma 2.2 Encoded Rec.709",
            Self::Rec1886Rec709Display => "Gamma 2.4 Encoded Rec.709",
            Self::Rec2100Pq1000Display | Self::Rec2100Hlg1000Display => ACESCG_COLOR_SPACE,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceColorInterpretation {
    Ocio(OcioInputTransform),
}

pub fn propose_ocio_input(metadata: &EncodedColorMetadata) -> Option<OcioInputTransform> {
    match (&metadata.primaries, &metadata.transfer, &metadata.matrix) {
        (
            Some(ColorPrimaries::Bt709),
            Some(TransferCharacteristic::Srgb),
            Some(MatrixCoefficients::Rgb | MatrixCoefficients::Bt709),
        ) => Some(OcioInputTransform::SrgbEncodedRec709),
        (
            Some(ColorPrimaries::Bt709),
            Some(TransferCharacteristic::Bt709),
            Some(MatrixCoefficients::Bt709),
        ) => Some(OcioInputTransform::Rec709Gamma24Display),
        _ => None,
    }
}

pub struct ColorEngine {
    config: Config,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OcioGpuTextureDimension {
    One,
    Two,
    Three,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OcioGpuTextureInterpolation {
    Nearest,
    Linear,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OcioGpuTexture {
    pub texture_name: String,
    pub sampler_name: String,
    pub width: u32,
    pub height: u32,
    pub depth: u32,
    pub channel_count: u8,
    pub dimension: OcioGpuTextureDimension,
    pub interpolation: OcioGpuTextureInterpolation,
    pub binding_index: u32,
    pub values: Vec<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OcioGpuShader {
    pub function_name: String,
    pub source: String,
    pub textures: Vec<OcioGpuTexture>,
    pub uniform_count: usize,
}

impl ColorEngine {
    pub fn bundled() -> Result<Self, ColorError> {
        if ocio_rs::is_stub_build() {
            return Err(ColorError::StubOpenColorIo);
        }
        let config = Config::create_from_builtin_config(OCIO_CONFIGURATION_ID)
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        Ok(Self { config })
    }

    pub fn library_version(&self) -> Result<String, ColorError> {
        ocio_rs::version().ok_or(ColorError::MissingLibraryVersion)
    }

    pub fn source_to_acescg_processor(
        &self,
        input: OcioInputTransform,
    ) -> Result<SourceToAcesCgProcessor, ColorError> {
        let processor = match input.processor() {
            OcioInputProcessor::ColorSpace(source) => {
                self.config.processor(source, ACESCG_COLOR_SPACE)
            }
            OcioInputProcessor::InverseDisplay { display, view } => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                display,
                view,
                TransformDirection::Inverse,
            ),
        }
        .and_then(|processor| processor.default_cpu_processor())
        .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        Ok(SourceToAcesCgProcessor { processor })
    }

    pub fn acescg_to_source_processor(
        &self,
        input: OcioInputTransform,
    ) -> Result<AcesCgToSourceProcessor, ColorError> {
        let processor = match input.processor() {
            OcioInputProcessor::ColorSpace(destination) => {
                self.config.processor(ACESCG_COLOR_SPACE, destination)
            }
            OcioInputProcessor::InverseDisplay { display, view } => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                display,
                view,
                TransformDirection::Forward,
            ),
        }
        .and_then(|processor| processor.default_cpu_processor())
        .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        Ok(AcesCgToSourceProcessor { processor })
    }

    pub fn source_to_device_processor(
        &self,
        interpretation: SourceColorInterpretation,
        target: DeviceColorTarget,
    ) -> Result<SourceToDeviceProcessor, ColorError> {
        match interpretation {
            SourceColorInterpretation::Ocio(input) => {
                let input_to_acescg = match input.processor() {
                    OcioInputProcessor::ColorSpace(source) => {
                        self.config.processor(source, ACESCG_COLOR_SPACE)
                    }
                    OcioInputProcessor::InverseDisplay { display, view } => {
                        self.config.processor_display(
                            ACESCG_COLOR_SPACE,
                            display,
                            view,
                            TransformDirection::Inverse,
                        )
                    }
                }
                .and_then(|processor| processor.default_cpu_processor())
                .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
                let acescg_to_output = match input.reference_domain() {
                    SourceReferenceDomain::DisplayReferred
                        if target.uses_display_processor_for_display_referred() =>
                    {
                        self.config.processor_display(
                            ACESCG_COLOR_SPACE,
                            target.ocio_display(),
                            "Video (colorimetric)",
                            TransformDirection::Forward,
                        )
                    }
                    SourceReferenceDomain::DisplayReferred => self
                        .config
                        .processor(ACESCG_COLOR_SPACE, target.ocio_color_space()),
                    SourceReferenceDomain::SceneReferred
                    | SourceReferenceDomain::AcesOutputReferred => self.config.processor_display(
                        ACESCG_COLOR_SPACE,
                        target.ocio_display(),
                        target.scene_view(),
                        TransformDirection::Forward,
                    ),
                }
                .and_then(|processor| processor.default_cpu_processor())
                .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
                Ok(SourceToDeviceProcessor::Ocio(vec![
                    input_to_acescg,
                    acescg_to_output,
                ]))
            }
        }
    }

    pub fn camera_output_processor(
        &self,
        transform: CameraOutputTransform,
    ) -> Result<CameraOutputProcessor, ColorError> {
        let processor = self
            .config
            .processor_display(
                ACESCG_COLOR_SPACE,
                transform.ocio_display(),
                transform.ocio_view(),
                TransformDirection::Forward,
            )
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        let processor = processor
            .default_cpu_processor()
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        Ok(CameraOutputProcessor {
            transform,
            processor,
        })
    }

    pub fn recording_output_processor(
        &self,
        transform: RecordingOutputTransform,
    ) -> Result<RecordingOutputProcessor, ColorError> {
        let processor = match transform {
            RecordingOutputTransform::IphoneHeicDisplayP3SrgbFull => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "Display P3 - Display",
                "ACES 2.0 - SDR 100 nits (P3 D65)",
                TransformDirection::Forward,
            ),
            RecordingOutputTransform::GenericSrgbFull => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "sRGB - Display",
                "ACES 2.0 - SDR 100 nits (Rec.709)",
                TransformDirection::Forward,
            ),
            RecordingOutputTransform::GenericRec709Full => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "Rec.1886 Rec.709 - Display",
                "ACES 2.0 - SDR 100 nits (Rec.709)",
                TransformDirection::Forward,
            ),
            RecordingOutputTransform::GenericRec2100PqFull => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "Rec.2100-PQ - Display",
                "ACES 2.0 - HDR 1000 nits (Rec.2020)",
                TransformDirection::Forward,
            ),
        }
        .and_then(|processor| processor.default_cpu_processor())
        .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        Ok(RecordingOutputProcessor {
            transform,
            processor,
        })
    }

    pub fn recording_output_inverse_processor(
        &self,
        transform: RecordingOutputTransform,
    ) -> Result<RecordingOutputInverseProcessor, ColorError> {
        let processor = match transform {
            RecordingOutputTransform::IphoneHeicDisplayP3SrgbFull => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "Display P3 - Display",
                "ACES 2.0 - SDR 100 nits (P3 D65)",
                TransformDirection::Inverse,
            ),
            RecordingOutputTransform::GenericSrgbFull => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "sRGB - Display",
                "ACES 2.0 - SDR 100 nits (Rec.709)",
                TransformDirection::Inverse,
            ),
            RecordingOutputTransform::GenericRec709Full => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "Rec.1886 Rec.709 - Display",
                "ACES 2.0 - SDR 100 nits (Rec.709)",
                TransformDirection::Inverse,
            ),
            RecordingOutputTransform::GenericRec2100PqFull => self.config.processor_display(
                ACESCG_COLOR_SPACE,
                "Rec.2100-PQ - Display",
                "ACES 2.0 - HDR 1000 nits (Rec.2020)",
                TransformDirection::Inverse,
            ),
        }
        .and_then(|processor| processor.default_cpu_processor())
        .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        Ok(RecordingOutputInverseProcessor { processor })
    }

    pub fn camera_output_gpu_shader(
        &self,
        transform: CameraOutputTransform,
    ) -> Result<OcioGpuShader, ColorError> {
        let processor = self
            .config
            .processor_display(
                ACESCG_COLOR_SPACE,
                transform.ocio_display(),
                transform.ocio_view(),
                TransformDirection::Forward,
            )
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        let gpu = processor
            .default_gpu_processor()
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        let mut shader =
            GpuShaderDesc::create().map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        shader
            .set_language(GpuLanguage::Msl2_0)
            .and_then(|()| shader.set_function_name("screenSimulationOcioDisplay"))
            .and_then(|()| shader.set_resource_prefix("screen_simulation_ocio_"))
            .and_then(|()| shader.set_allow_texture_1d(false))
            .and_then(|()| gpu.try_extract_shader_info(&mut shader))
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        let source = shader
            .shader_text()
            .ok_or_else(|| ColorError::OpenColorIo("GPU processor emitted no MSL".to_owned()))?;
        let interpolation = |value| match value {
            Interpolation::Nearest => Ok(OcioGpuTextureInterpolation::Nearest),
            Interpolation::Linear => Ok(OcioGpuTextureInterpolation::Linear),
            other => Err(ColorError::OpenColorIo(format!(
                "unsupported GPU LUT interpolation {other:?}"
            ))),
        };
        let mut textures = shader
            .textures_2d()
            .into_iter()
            .map(|texture| {
                Ok(OcioGpuTexture {
                    texture_name: texture.texture_name,
                    sampler_name: texture.sampler_name,
                    width: texture.width,
                    height: texture.height,
                    depth: 1,
                    channel_count: match texture.channel {
                        GpuTextureChannel::Red => 1,
                        GpuTextureChannel::Rgb => 3,
                    },
                    dimension: OcioGpuTextureDimension::Two,
                    interpolation: interpolation(texture.interpolation)?,
                    binding_index: texture.binding_index,
                    values: texture.values,
                })
            })
            .collect::<Result<Vec<_>, ColorError>>()?;
        textures.extend(
            shader
                .textures_3d()
                .into_iter()
                .map(|texture| {
                    Ok(OcioGpuTexture {
                        texture_name: texture.texture_name,
                        sampler_name: texture.sampler_name,
                        width: texture.edge_len,
                        height: texture.edge_len,
                        depth: texture.edge_len,
                        channel_count: 3,
                        dimension: OcioGpuTextureDimension::Three,
                        interpolation: interpolation(texture.interpolation)?,
                        binding_index: texture.binding_index,
                        values: texture.values,
                    })
                })
                .collect::<Result<Vec<_>, ColorError>>()?,
        );
        Ok(OcioGpuShader {
            function_name: "screenSimulationOcioDisplay".to_owned(),
            source,
            textures,
            uniform_count: shader.uniforms().len(),
        })
    }
}

pub struct CameraOutputProcessor {
    transform: CameraOutputTransform,
    processor: CPUProcessor,
}

pub struct SourceToAcesCgProcessor {
    processor: CPUProcessor,
}

pub struct AcesCgToSourceProcessor {
    processor: CPUProcessor,
}

fn apply_cpu_rgba(processor: &CPUProcessor, pixels: &mut [f32]) -> Result<(), ColorError> {
    if !pixels.len().is_multiple_of(4) {
        return Err(ColorError::InvalidRgbaBufferLength(pixels.len()));
    }
    let alpha = pixels
        .chunks_exact(4)
        .map(|pixel| pixel[3])
        .collect::<Vec<_>>();
    processor
        .try_apply_rgba_pixels(
            pixels,
            i64::try_from(pixels.len() / 4).map_err(|_| ColorError::PixelCountOverflow)?,
            4,
        )
        .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
    for (pixel, alpha) in pixels.chunks_exact_mut(4).zip(alpha) {
        pixel[3] = alpha;
    }
    Ok(())
}

impl SourceToAcesCgProcessor {
    pub fn apply_rgba_buffer(&self, pixels: &mut [f32]) -> Result<(), ColorError> {
        apply_cpu_rgba(&self.processor, pixels)
    }
}

impl AcesCgToSourceProcessor {
    pub fn apply_rgba_buffer(&self, pixels: &mut [f32]) -> Result<(), ColorError> {
        apply_cpu_rgba(&self.processor, pixels)
    }
}

pub struct RecordingOutputProcessor {
    transform: RecordingOutputTransform,
    processor: CPUProcessor,
}

pub struct RecordingOutputInverseProcessor {
    processor: CPUProcessor,
}

impl RecordingOutputInverseProcessor {
    pub fn apply_rgba(&self, rgba: &mut [[f32; 4]]) -> Result<(), ColorError> {
        for pixel in rgba.iter_mut() {
            pixel[3] = 1.0;
        }
        let pixel_count = i64::try_from(rgba.len()).map_err(|_| ColorError::PixelCountOverflow)?;
        self.processor
            .try_apply_rgba_pixels(rgba.as_flattened_mut(), pixel_count, 4)
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))
    }
}

impl RecordingOutputProcessor {
    pub fn apply_acescg_raster(
        &self,
        width: u32,
        height: u32,
        pixels: &[LinearRgb],
    ) -> Result<RecordingOutputSignal, ColorError> {
        let expected = usize::try_from(width)
            .ok()
            .and_then(|width| {
                usize::try_from(height)
                    .ok()
                    .and_then(|height| width.checked_mul(height))
            })
            .ok_or(ColorError::InvalidRecordingOutputSignal)?;
        if width == 0 || height == 0 || pixels.len() != expected {
            return Err(ColorError::InvalidRecordingOutputSignal);
        }
        let mut rgba = pixels
            .iter()
            .map(|pixel| [pixel.r, pixel.g, pixel.b, 1.0])
            .collect::<Vec<_>>();
        self.processor
            .try_apply_rgba_pixels(
                rgba.as_mut_slice().as_flattened_mut(),
                i64::try_from(expected).map_err(|_| ColorError::PixelCountOverflow)?,
                4,
            )
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
        for pixel in &mut rgba {
            pixel[3] = 1.0;
        }
        let signal = RecordingOutputSignal {
            artifact_id: RECORDING_OUTPUT_SIGNAL_ARTIFACT_ID,
            transform: self.transform,
            width,
            height,
            rgba,
            color: self.transform.encoded_color(),
            alpha: RecordingOutputAlpha::Opaque,
        };
        signal.validate()?;
        Ok(signal)
    }
}

impl CameraOutputProcessor {
    pub const fn transform(&self) -> CameraOutputTransform {
        self.transform
    }

    pub fn apply_acescg_rgba_buffer(&self, pixels: &mut [f32]) -> Result<(), ColorError> {
        if !pixels.len().is_multiple_of(4) {
            return Err(ColorError::InvalidRgbaBufferLength(pixels.len()));
        }
        self.processor
            .try_apply_rgba_pixels(
                pixels,
                i64::try_from(pixels.len() / 4).map_err(|_| ColorError::PixelCountOverflow)?,
                4,
            )
            .map_err(|error| ColorError::OpenColorIo(error.to_string()))
    }

    pub fn apply_acescg(&self, value: LinearRgb) -> Result<PreviewRgb, ColorError> {
        let mut rgba = [value.r, value.g, value.b, 1.0];
        self.apply_acescg_rgba_buffer(&mut rgba)?;
        Ok(PreviewRgb {
            r: rgba[0],
            g: rgba[1],
            b: rgba[2],
        })
    }
}

pub enum SourceToDeviceProcessor {
    Ocio(Vec<CPUProcessor>),
}

impl SourceToDeviceProcessor {
    pub fn apply_rgba_buffer(&self, pixels: &mut [f32]) -> Result<(), ColorError> {
        if !pixels.len().is_multiple_of(4) {
            return Err(ColorError::InvalidRgbaBufferLength(pixels.len()));
        }
        match self {
            Self::Ocio(processors) => {
                let pixel_count =
                    i64::try_from(pixels.len() / 4).map_err(|_| ColorError::PixelCountOverflow)?;
                for processor in processors {
                    processor
                        .try_apply_rgba_pixels(pixels, pixel_count, 4)
                        .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
                }
                Ok(())
            }
        }
    }

    pub fn apply_rgb(&self, rgb: [f32; 3]) -> Result<DeviceRgb, ColorError> {
        let mut rgba = [rgb[0], rgb[1], rgb[2], 1.0];
        self.apply_rgba_buffer(&mut rgba)?;
        Ok(DeviceRgb::new(rgba[0], rgba[1], rgba[2]))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ColorError {
    StubOpenColorIo,
    MissingLibraryVersion,
    InvalidRgbaBufferLength(usize),
    PixelCountOverflow,
    InvalidRecordingOutputSignal,
    InvalidSceneLinearAdjustment,
    OpenColorIo(String),
}

impl fmt::Display for ColorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::StubOpenColorIo => {
                formatter.write_str("screen-color requires a real bundled OpenColorIO build")
            }
            Self::MissingLibraryVersion => {
                formatter.write_str("OpenColorIO did not report its linked library version")
            }
            Self::InvalidRgbaBufferLength(length) => {
                write!(
                    formatter,
                    "RGBA buffer has {length} scalars; a multiple of four is required"
                )
            }
            Self::PixelCountOverflow => formatter.write_str("RGBA pixel count exceeds i64"),
            Self::InvalidRecordingOutputSignal => {
                formatter.write_str("invalid recording-output-signal-v2 artifact")
            }
            Self::InvalidSceneLinearAdjustment => {
                formatter.write_str("invalid scene-linear ACEScg adjustment")
            }
            Self::OpenColorIo(message) => write!(formatter, "OpenColorIO: {message}"),
        }
    }
}

impl std::error::Error for ColorError {}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreviewRgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DiagnosticDisplayTransform {
    pub reference_white_nits: f32,
}

impl DiagnosticDisplayTransform {
    pub fn scene_linear_to_srgb(self, radiance_nits: LinearRgb) -> PreviewRgb {
        let encode = |value: f32| {
            let normalized = (value / self.reference_white_nits).max(0.0);
            let tone_mapped = normalized / (1.0 + normalized);
            if tone_mapped <= 0.003_130_8 {
                tone_mapped * 12.92
            } else {
                1.055 * tone_mapped.powf(1.0 / 2.4) - 0.055
            }
        };
        PreviewRgb {
            r: encode(radiance_nits.r),
            g: encode(radiance_nits.g),
            b: encode(radiance_nits.b),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neutral_scene_linear_adjustment_is_exact_for_extended_values() {
        for input in [
            LinearRgb::new(-0.25, 0.0, 2.0),
            LinearRgb::new(0.18, 0.18, 0.18),
        ] {
            let output = apply_scene_linear_adjustment(input, SceneLinearAdjustment::NEUTRAL)
                .expect("neutral adjustment");
            assert_eq!(output, input);
        }
    }

    #[test]
    fn incident_adjustment_preserves_non_negative_radiance_without_channel_clipping() {
        let input = LinearRgb::new(0.02, 0.3, 0.9);
        let output = apply_incident_radiance_adjustment(
            input,
            SceneLinearAdjustment {
                saturation: 4.0,
                ..SceneLinearAdjustment::NEUTRAL
            },
        )
        .expect("physical radiance adjustment");
        assert!(output.r >= 0.0 && output.g >= 0.0 && output.b >= 0.0);
        assert_eq!(output.r, 0.0);
        assert!(output.g > 0.0 && output.b > output.g);
    }

    #[test]
    fn diagnostic_display_transform_is_monotonic_and_bounded() {
        let transform = DiagnosticDisplayTransform {
            reference_white_nits: 100.0,
        };
        let dim = transform.scene_linear_to_srgb(LinearRgb::new(10.0, 10.0, 10.0));
        let bright = transform.scene_linear_to_srgb(LinearRgb::new(1_000.0, 1_000.0, 1_000.0));
        assert!(bright.r > dim.r);
        assert!(bright.r < 1.0);
    }

    #[test]
    fn srgb_device_signal_round_trips_through_acescg_without_a_bypass() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        let processor = engine
            .source_to_device_processor(
                SourceColorInterpretation::Ocio(OcioInputTransform::SrgbEncodedRec709),
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("sRGB roundtrip processor");
        let source = [0.1, 0.5, 0.9];
        let signal = processor.apply_rgb(source).expect("roundtrip pixel");
        for (actual, expected) in [signal.r, signal.g, signal.b].into_iter().zip(source) {
            assert!((actual - expected).abs() <= 3.0e-5);
        }
    }

    #[test]
    fn every_input_transform_resolves_as_an_origin_roundtrip() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        for input in OcioInputTransform::ALL {
            let to_acescg = engine
                .source_to_acescg_processor(input)
                .unwrap_or_else(|error| panic!("{} input failed: {error}", input.label()));
            let from_acescg = engine
                .acescg_to_source_processor(input)
                .unwrap_or_else(|error| panic!("{} output failed: {error}", input.label()));
            let mut rgba = [0.18, 0.22, 0.31, 0.375];
            to_acescg
                .apply_rgba_buffer(&mut rgba)
                .unwrap_or_else(|error| panic!("{} to ACEScg failed: {error}", input.label()));
            assert!(rgba[..3].iter().all(|value| value.is_finite()));
            assert_eq!(rgba[3], 0.375);
            from_acescg
                .apply_rgba_buffer(&mut rgba)
                .unwrap_or_else(|error| panic!("{} from ACEScg failed: {error}", input.label()));
            assert!(rgba.iter().all(|value| value.is_finite()));
            assert_eq!(rgba[3], 0.375);
        }
    }

    #[test]
    fn acescg_origin_processor_preserves_extended_values_and_alpha() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        let to_acescg = engine
            .source_to_acescg_processor(OcioInputTransform::AcesCg)
            .expect("ACEScg input");
        let from_acescg = engine
            .acescg_to_source_processor(OcioInputTransform::AcesCg)
            .expect("ACEScg output");
        let expected = [-0.25, 0.18, 16.0, 0.4];
        let mut actual = expected;
        to_acescg.apply_rgba_buffer(&mut actual).expect("to ACEScg");
        from_acescg
            .apply_rgba_buffer(&mut actual)
            .expect("from ACEScg");
        assert_eq!(actual, expected);
    }

    #[test]
    fn bundled_ocio_processes_an_explicit_input_to_device_signal() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        assert!(
            engine
                .library_version()
                .expect("OCIO version")
                .starts_with("2.5.")
        );
        let processor = engine
            .source_to_device_processor(
                SourceColorInterpretation::Ocio(OcioInputTransform::ArriLogC4),
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("LogC4 processor");
        let signal = processor.apply_rgb([0.4, 0.4, 0.4]).expect("device signal");
        assert!(signal.r.is_finite() && signal.g.is_finite() && signal.b.is_finite());
        assert_ne!(signal, DeviceRgb::new(0.4, 0.4, 0.4));
    }

    #[test]
    fn every_input_transform_resolves_through_every_feeder_output() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        for input in OcioInputTransform::ALL {
            for target in DeviceColorTarget::ALL {
                let signal = engine
                    .source_to_device_processor(SourceColorInterpretation::Ocio(input), target)
                    .and_then(|processor| processor.apply_rgb([0.18, 0.18, 0.18]))
                    .unwrap_or_else(|error| {
                        panic!("{} → {} failed: {error}", input.label(), target.label())
                    });
                assert!(signal.r.is_finite() && signal.g.is_finite() && signal.b.is_finite());
            }
        }
    }

    #[test]
    fn every_camera_output_has_a_stable_id_and_resolves_in_the_pinned_configuration() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        for transform in CameraOutputTransform::ALL {
            assert_eq!(
                CameraOutputTransform::from_stable_id(transform.stable_id()),
                Some(transform)
            );
            let processor = engine
                .camera_output_processor(transform)
                .unwrap_or_else(|error| panic!("{} failed: {error}", transform.label()));
            assert_eq!(processor.transform(), transform);
            let output = processor
                .apply_acescg(LinearRgb::new(-0.1, 0.18, 4.0))
                .expect("camera output");
            assert!(output.r.is_finite() && output.g.is_finite() && output.b.is_finite());
        }
        assert_eq!(CameraOutputTransform::from_stable_id("rec709"), None);
    }

    #[test]
    fn iphone_heic_recording_output_is_strict_p3_srgb_full_opaque_float() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        let transform = RecordingOutputTransform::IphoneHeicDisplayP3SrgbFull;
        assert_eq!(
            RecordingOutputTransform::from_stable_id(transform.stable_id()),
            Some(transform)
        );
        assert_eq!(RecordingOutputTransform::from_stable_id("display-p3"), None);
        assert_eq!(
            RecordingOutputTransform::from_stable_id("iphone-heic-display-p3-bt709-full-v1"),
            None
        );
        let signal = engine
            .recording_output_processor(transform)
            .expect("recording output processor")
            .apply_acescg_raster(
                2,
                1,
                &[
                    LinearRgb::new(-0.01, 0.18, 1.2),
                    LinearRgb::new(0.0, 0.5, 4.0),
                ],
            )
            .expect("recording signal");
        assert_eq!(signal.artifact_id, RECORDING_OUTPUT_SIGNAL_ARTIFACT_ID);
        assert_eq!(signal.color, transform.encoded_color());
        assert_eq!(signal.alpha, RecordingOutputAlpha::Opaque);
        assert!(signal.rgba.iter().all(|pixel| pixel[3] == 1.0));
        assert!(signal.rgba.iter().flatten().all(|value| value.is_finite()));
        assert_ne!(signal.rgba[0], signal.rgba[1]);
    }

    #[test]
    fn recording_output_artifact_rejects_wrong_contract_without_inference() {
        let transform = RecordingOutputTransform::IphoneHeicDisplayP3SrgbFull;
        let valid = RecordingOutputSignal {
            artifact_id: RECORDING_OUTPUT_SIGNAL_ARTIFACT_ID,
            transform,
            width: 1,
            height: 1,
            rgba: vec![[0.1, 0.2, 0.3, 1.0]],
            color: transform.encoded_color(),
            alpha: RecordingOutputAlpha::Opaque,
        };
        assert!(valid.validate().is_ok());
        assert_eq!(
            RecordingOutputSignal {
                artifact_id: "recording-output-signal",
                ..valid.clone()
            }
            .validate(),
            Err(ColorError::InvalidRecordingOutputSignal)
        );
        let mut wrong_color = valid.clone();
        wrong_color.color.transfer = Some(TransferCharacteristic::Bt709);
        assert_eq!(
            wrong_color.validate(),
            Err(ColorError::InvalidRecordingOutputSignal)
        );
        let mut non_opaque = valid;
        non_opaque.rgba[0][3] = 0.999;
        assert_eq!(
            non_opaque.validate(),
            Err(ColorError::InvalidRecordingOutputSignal)
        );
    }

    #[test]
    fn output_selection_does_not_mutate_the_authoritative_acescg_value() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        let linear = LinearRgb::new(0.18, 0.09, 1.4);
        let first = engine
            .camera_output_processor(CameraOutputTransform::SrgbSdr100)
            .expect("sRGB output")
            .apply_acescg(linear)
            .expect("sRGB pixel");
        let second = engine
            .camera_output_processor(CameraOutputTransform::Rec2100Pq1000)
            .expect("PQ output")
            .apply_acescg(linear)
            .expect("PQ pixel");
        assert_eq!(linear, LinearRgb::new(0.18, 0.09, 1.4));
        assert_ne!(first, second);
    }

    #[test]
    fn pinned_sdr_output_preserves_objective_gray_anchors() {
        let processor = ColorEngine::bundled()
            .expect("bundled color engine")
            .camera_output_processor(CameraOutputTransform::SrgbSdr100)
            .expect("sRGB output");
        for (linear, expected_srgb) in [(0.18_f32, 0.349_188_f32), (0.64, 0.617_808)] {
            let output = processor
                .apply_acescg(LinearRgb::new(linear, linear, linear))
                .expect("gray output");
            assert!((output.r - expected_srgb).abs() < 1.0e-5);
            assert!((output.g - expected_srgb).abs() < 1.0e-5);
            assert!((output.b - expected_srgb).abs() < 1.0e-5);
        }
    }

    #[test]
    fn stable_input_ids_round_trip_without_aliases() {
        for input in OcioInputTransform::ALL {
            assert_eq!(
                OcioInputTransform::from_stable_id(input.stable_id()),
                Some(input)
            );
        }
        assert_eq!(OcioInputTransform::from_stable_id("ARRI LogC4"), None);
        assert_eq!(
            OcioInputTransform::from_stable_id("input-rec709"),
            Some(OcioInputTransform::CameraRec709)
        );
        assert_eq!(OcioInputTransform::from_stable_id("camera-rec709"), None);
    }

    #[test]
    fn color_modes_have_stable_ids_and_domain_specific_feeder_outputs() {
        for target in DeviceColorTarget::ALL {
            assert_eq!(
                DeviceColorTarget::from_stable_id(target.stable_id()),
                Some(target)
            );
        }
        assert_eq!(DeviceColorTarget::from_stable_id("Rec.709"), None);
        assert_eq!(
            DeviceColorTarget::SrgbDisplay.feeder_output_id(SourceReferenceDomain::DisplayReferred),
            "device-srgb-colorimetric"
        );
        assert_eq!(
            DeviceColorTarget::SrgbDisplay.feeder_output_id(SourceReferenceDomain::SceneReferred),
            "aces2-srgb-sdr-100"
        );
        assert_eq!(
            DeviceColorTarget::Rec2100Pq1000Display
                .feeder_output_id(SourceReferenceDomain::DisplayReferred),
            "device-rec2100-pq-colorimetric"
        );
        assert_eq!(
            DeviceColorTarget::Rec2100Hlg1000Display
                .feeder_output_id(SourceReferenceDomain::SceneReferred),
            "aces2-rec2100-hlg-1000"
        );
    }

    #[test]
    fn hdr_feeder_signals_resolve_for_display_and_scene_referred_sources() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        for target in [
            DeviceColorTarget::Rec2100Pq1000Display,
            DeviceColorTarget::Rec2100Hlg1000Display,
        ] {
            for input in [
                OcioInputTransform::SrgbEncodedRec709,
                OcioInputTransform::ArriLogC4,
            ] {
                let signal = engine
                    .source_to_device_processor(SourceColorInterpretation::Ocio(input), target)
                    .and_then(|processor| processor.apply_rgb([0.18, 0.18, 0.18]))
                    .unwrap_or_else(|error| panic!("{} failed: {error}", target.label()));
                assert!(signal.r.is_finite() && signal.g.is_finite() && signal.b.is_finite());
            }
        }
    }

    #[test]
    fn processor_rejects_incomplete_rgba_storage() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        let processor = engine
            .source_to_device_processor(
                SourceColorInterpretation::Ocio(OcioInputTransform::SrgbEncodedRec709),
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("sRGB processor");
        assert_eq!(
            processor.apply_rgba_buffer(&mut [0.0; 3]),
            Err(ColorError::InvalidRgbaBufferLength(3))
        );
    }

    #[test]
    fn pinned_camera_output_generates_complete_msl_resources() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        for transform in CameraOutputTransform::ALL {
            let shader = engine
                .camera_output_gpu_shader(transform)
                .unwrap_or_else(|error| panic!("{} GPU shader failed: {error}", transform.label()));
            assert!(shader.source.contains(&shader.function_name));
            assert!(!shader.textures.is_empty());
            assert!(shader.textures.iter().all(|texture| matches!(
                texture.dimension,
                OcioGpuTextureDimension::One
                    | OcioGpuTextureDimension::Two
                    | OcioGpuTextureDimension::Three
            )));
        }
    }

    #[test]
    fn complete_rec709_metadata_proposes_but_does_not_select_an_input() {
        let metadata = EncodedColorMetadata {
            primaries: Some(ColorPrimaries::Bt709),
            transfer: Some(TransferCharacteristic::Bt709),
            matrix: Some(MatrixCoefficients::Bt709),
            range: None,
        };
        assert_eq!(
            propose_ocio_input(&metadata),
            Some(OcioInputTransform::Rec709Gamma24Display)
        );
        let incomplete = EncodedColorMetadata {
            matrix: None,
            ..metadata
        };
        assert_eq!(propose_ocio_input(&incomplete), None);
    }
}
