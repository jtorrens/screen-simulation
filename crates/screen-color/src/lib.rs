//! Explicit color interpretation and OpenColorIO ownership.

#![forbid(unsafe_code)]

use core::fmt;
use ocio_rs::{CPUProcessor, Config, TransformDirection};
use screen_contracts::{
    ColorPrimaries, DeviceRgb, EncodedColorMetadata, LinearRgb, MatrixCoefficients,
    TransferCharacteristic,
};

pub const OCIO_CONFIGURATION_ID: &str = "studio-config-v4.0.0_aces-v2.0_ocio-v2.5";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OcioInputTransform {
    SrgbEncodedRec709,
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
    pub const ALL: [Self; 10] = [
        Self::SrgbEncodedRec709,
        Self::CameraRec709,
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
            Self::SrgbEncodedRec709 => "sRGB encoded Rec.709",
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
            Self::SrgbEncodedRec709 => "srgb-encoded-rec709",
            Self::CameraRec709 => "camera-rec709",
            Self::ArriLogC3Ei800 => "arri-logc3-ei800",
            Self::ArriLogC4 => "arri-logc4",
            Self::BmdFilmWideGamutGen5 => "bmd-film-wide-gamut-gen5",
            Self::DavinciIntermediateWideGamut => "davinci-intermediate-wide-gamut",
            Self::CanonLog3CinemaGamutD55 => "canon-log3-cinema-gamut-d55",
            Self::VLogVGamut => "vlog-vgamut",
            Self::Log3G10RedWideGamutRgb => "log3g10-red-wide-gamut-rgb",
            Self::SLog3SGamut3Cine => "slog3-sgamut3-cine",
        }
    }

    pub fn from_stable_id(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|candidate| candidate.stable_id() == value)
    }

    const fn ocio_color_space(self) -> &'static str {
        match self {
            Self::SrgbEncodedRec709 => "sRGB Encoded Rec.709 (sRGB)",
            Self::CameraRec709 => "Camera Rec.709",
            Self::ArriLogC3Ei800 => "ARRI LogC3 (EI800)",
            Self::ArriLogC4 => "ARRI LogC4",
            Self::BmdFilmWideGamutGen5 => "BMDFilm WideGamut Gen5",
            Self::DavinciIntermediateWideGamut => "DaVinci Intermediate WideGamut",
            Self::CanonLog3CinemaGamutD55 => "CanonLog3 CinemaGamut D55",
            Self::VLogVGamut => "V-Log V-Gamut",
            Self::Log3G10RedWideGamutRgb => "Log3G10 REDWideGamutRGB",
            Self::SLog3SGamut3Cine => "S-Log3 S-Gamut3.Cine",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceColorTarget {
    SrgbDisplay,
    Gamma22Rec709Display,
    Rec1886Rec709Display,
}

impl DeviceColorTarget {
    const VIEW: &'static str = "ACES 2.0 - SDR 100 nits (Rec.709)";

    const fn ocio_display(self) -> &'static str {
        match self {
            Self::SrgbDisplay => "sRGB - Display",
            Self::Gamma22Rec709Display => "Gamma 2.2 Rec.709 - Display",
            Self::Rec1886Rec709Display => "Rec.1886 Rec.709 - Display",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceColorInterpretation {
    IdentityDeviceSignal,
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
        ) => Some(OcioInputTransform::CameraRec709),
        _ => None,
    }
}

pub struct ColorEngine {
    config: Config,
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

    pub fn source_to_device_processor(
        &self,
        interpretation: SourceColorInterpretation,
        target: DeviceColorTarget,
    ) -> Result<SourceToDeviceProcessor, ColorError> {
        match interpretation {
            SourceColorInterpretation::IdentityDeviceSignal => {
                Ok(SourceToDeviceProcessor::Identity)
            }
            SourceColorInterpretation::Ocio(input) => {
                let processor = self
                    .config
                    .processor_display(
                        input.ocio_color_space(),
                        target.ocio_display(),
                        DeviceColorTarget::VIEW,
                        TransformDirection::Forward,
                    )
                    .and_then(|processor| processor.default_cpu_processor())
                    .map_err(|error| ColorError::OpenColorIo(error.to_string()))?;
                Ok(SourceToDeviceProcessor::Ocio(processor))
            }
        }
    }
}

pub enum SourceToDeviceProcessor {
    Identity,
    Ocio(CPUProcessor),
}

impl SourceToDeviceProcessor {
    pub fn apply_rgba_buffer(&self, pixels: &mut [f32]) -> Result<(), ColorError> {
        if !pixels.len().is_multiple_of(4) {
            return Err(ColorError::InvalidRgbaBufferLength(pixels.len()));
        }
        match self {
            Self::Identity => Ok(()),
            Self::Ocio(processor) => processor
                .try_apply_rgba_pixels(
                    pixels,
                    i64::try_from(pixels.len() / 4).map_err(|_| ColorError::PixelCountOverflow)?,
                    4,
                )
                .map_err(|error| ColorError::OpenColorIo(error.to_string())),
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
    fn identity_device_interpretation_preserves_code_values() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        let processor = engine
            .source_to_device_processor(
                SourceColorInterpretation::IdentityDeviceSignal,
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("identity processor");
        assert_eq!(
            processor
                .apply_rgb([-0.1, 0.5, 1.2])
                .expect("identity pixel"),
            DeviceRgb::new(-0.1, 0.5, 1.2)
        );
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
    fn catalog_entries_resolve_in_the_bundled_configuration() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        for input in OcioInputTransform::ALL {
            engine
                .source_to_device_processor(
                    SourceColorInterpretation::Ocio(input),
                    DeviceColorTarget::SrgbDisplay,
                )
                .unwrap_or_else(|error| panic!("{} failed: {error}", input.label()));
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
    }

    #[test]
    fn processor_rejects_incomplete_rgba_storage() {
        let engine = ColorEngine::bundled().expect("bundled color engine");
        let processor = engine
            .source_to_device_processor(
                SourceColorInterpretation::IdentityDeviceSignal,
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("identity processor");
        assert_eq!(
            processor.apply_rgba_buffer(&mut [0.0; 3]),
            Err(ColorError::InvalidRgbaBufferLength(3))
        );
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
            Some(OcioInputTransform::CameraRec709)
        );
        let incomplete = EncodedColorMetadata {
            matrix: None,
            ..metadata
        };
        assert_eq!(propose_ocio_input(&incomplete), None);
    }
}
