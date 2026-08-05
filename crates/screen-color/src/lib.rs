//! Explicit color interpretation and OpenColorIO ownership.

#![forbid(unsafe_code)]

use core::fmt;
use ocio_rs::{
    CPUProcessor, Config, GpuLanguage, GpuShaderDesc, GpuTextureChannel, Interpolation,
    TransformDirection,
};
use screen_contracts::{
    ColorPrimaries, DeviceRgb, EncodedColorMetadata, LinearRgb, MatrixCoefficients,
    TransferCharacteristic,
};

pub const OCIO_CONFIGURATION_ID: &str = "studio-config-v4.0.0_aces-v2.0_ocio-v2.5";
const ACESCG_COLOR_SPACE: &str = "ACEScg";

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
            Some(OcioInputTransform::CameraRec709)
        );
        let incomplete = EncodedColorMetadata {
            matrix: None,
            ..metadata
        };
        assert_eq!(propose_ocio_input(&incomplete), None);
    }
}
