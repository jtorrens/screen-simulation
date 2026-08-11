//! Strict portable project-document ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{FrameRate, RationalTime};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

pub const MANIFEST_NAME: &str = "project.json";
pub const CURRENT_VERSION: u32 = 10;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct OpaqueId(String);

impl OpaqueId {
    pub fn parse(value: impl Into<String>) -> Result<Self, PersistenceError> {
        let value = value.into();
        let valid = !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
        if !valid {
            return Err(PersistenceError::InvalidOpaqueId(value));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PortablePath(String);

impl PortablePath {
    pub fn parse(value: impl Into<String>) -> Result<Self, PersistenceError> {
        let value = value.into();
        let path = Path::new(&value);
        let valid = !value.is_empty()
            && !value.contains('\\')
            && !path.is_absolute()
            && path.components().all(|component| {
                matches!(component, Component::Normal(_))
                    && component.as_os_str().to_str().is_some()
            });
        if !valid {
            return Err(PersistenceError::InvalidPortablePath(value));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    fn resolve(&self, root: &Path) -> PathBuf {
        root.join(&self.0)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectManifest {
    pub schema: String,
    pub version: u32,
    pub project_id: OpaqueId,
    pub title: String,
    pub source_document: PortablePath,
    pub device_document: PortablePath,
    pub camera_document: PortablePath,
    pub sensor_document: PortablePath,
    pub screen_document: PortablePath,
    pub shot_document: PortablePath,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceDocument {
    pub schema: String,
    pub version: u32,
    pub source_id: OpaqueId,
    pub media: PortablePath,
    pub decode: PixelDecodeSelection,
    pub color: SourceColorSelection,
    pub alpha: AlphaSelection,
    pub placement: PlacementSelection,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatrixSelection {
    Auto,
    Bt601,
    Bt709,
    Bt2020,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RangeSelection {
    Auto,
    Limited,
    Full,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PixelDecodeSelection {
    pub matrix: MatrixSelection,
    pub range: RangeSelection,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum SourceColorSelection {
    Named { transform_id: OpaqueId },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlphaSelection {
    Auto,
    Straight,
    Premultiplied,
    Ignore,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlacementSelection {
    Fit,
    FillCrop,
    Stretch,
    OneToOne,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceDocument {
    pub schema: String,
    pub version: u32,
    pub device_id: OpaqueId,
    pub color_mode_id: OpaqueId,
    pub native_width: u32,
    pub native_height: u32,
    pub active_width_meters: f32,
    pub active_height_meters: f32,
    pub stripe: StripeSelection,
    pub black_matrix_fraction: f32,
    pub eotf_gamma: f32,
    pub black_level_nits: f32,
    pub white_level_nits: f32,
    pub primary_xy: [[f32; 2]; 3],
    pub white_xy: [f32; 2],
    pub angular_emission_power: [f32; 3],
    pub residual_flicker_period: ExactTime,
    pub residual_flicker_amplitude: f32,
    pub residual_flicker_phase: ExactTime,
    pub banding_period: ExactTime,
    pub banding_on_duration: ExactTime,
    pub banding_phase: ExactTime,
    pub banding_amount: f32,
    pub cover: CoverDocument,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CoverDocument {
    pub character_strength: f32,
    pub thickness_millimeters: f32,
    pub refractive_index: f32,
    pub anti_reflective_efficiency: f32,
    pub absorption_per_millimeter: [f32; 3],
    pub roughness: f32,
    pub haze: f32,
    pub glow: CoverGlowDocument,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CoverGlowDocument {
    pub character_strength: f32,
    pub scatter_fraction: f32,
    pub core_radius_millimeters: f32,
    pub tail_radius_millimeters: f32,
    pub tail_fraction: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StripeSelection {
    Rgb,
    Bgr,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InterpolationSelection {
    Hold,
    Linear,
    Smooth,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExactTime {
    pub numerator: i64,
    pub denominator: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransformKeyframe {
    pub keyframe_id: OpaqueId,
    pub time: ExactTime,
    pub translation_meters: [f32; 3],
    pub rotation_quaternion: [f32; 4],
    pub interpolation: InterpolationSelection,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CameraIntrinsicsKeyframe {
    pub keyframe_id: OpaqueId,
    pub time: ExactTime,
    pub focal_length_mm: f32,
    pub sensor_width_mm: f32,
    pub sensor_height_mm: f32,
    pub lens_shift: [f32; 2],
    pub focus_distance_meters: f32,
    pub f_stop: f32,
    pub near_clip_meters: f32,
    pub far_clip_meters: f32,
    pub lens: LensDocument,
    pub interpolation: InterpolationSelection,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LensDocument {
    pub radial_distortion: [f32; 3],
    pub tangential_distortion: [f32; 2],
    pub longitudinal_chromatic_meters: [f32; 3],
    pub lateral_chromatic_scale: [f32; 3],
    pub vignetting_strength: f32,
    pub transmission_rgb: [f32; 3],
    pub center_softness_micrometers: f32,
    pub edge_softness_micrometers: f32,
    pub veiling_glare_fraction: f32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CameraDocument {
    pub schema: String,
    pub version: u32,
    pub camera_id: OpaqueId,
    pub transform_keyframes: Vec<TransformKeyframe>,
    pub intrinsics_keyframes: Vec<CameraIntrinsicsKeyframe>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BayerSelection {
    Rggb,
    Bggr,
    Grbg,
    Gbrg,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RollingDirectionSelection {
    TopToBottom,
    BottomToTop,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum SensorReadoutDocument {
    Global,
    Rolling {
        duration: ExactTime,
        direction: RollingDirectionSelection,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SensorDocument {
    pub schema: String,
    pub version: u32,
    pub sensor_id: OpaqueId,
    pub native_width: u16,
    pub native_height: u16,
    pub bayer_pattern: BayerSelection,
    pub acescg_to_sensor: [[f32; 3]; 3],
    pub saturation_illuminance_seconds: [f32; 3],
    pub full_well_electrons: f32,
    pub dark_current_electrons_per_second: f32,
    pub read_noise_electrons_rms: f32,
    pub analog_gain: f32,
    pub adc_bits: u8,
    pub bloom: SensorBloomDocument,
    pub shutter_duration: ExactTime,
    pub temporal_samples: u16,
    pub readout: SensorReadoutDocument,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SensorBloomDocument {
    pub character_strength: f32,
    pub crosstalk_fraction: f32,
    pub overflow_transfer_fraction: f32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScreenDocument {
    pub schema: String,
    pub version: u32,
    pub screen_id: OpaqueId,
    pub transform_keyframes: Vec<TransformKeyframe>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ShotDocument {
    pub schema: String,
    pub version: u32,
    pub shot_id: OpaqueId,
    pub source_id: OpaqueId,
    pub device_id: OpaqueId,
    pub camera_id: OpaqueId,
    pub sensor_id: OpaqueId,
    pub screen_id: OpaqueId,
    pub project_frame_rate: ExactFrameRate,
    pub sensor_noise_seed: u64,
    pub neutral_density_stops: f32,
    pub white_balance_gains: [f32; 3],
    pub exposure_index: f32,
    pub middle_gray_illuminance_seconds_at_reference_ei: f32,
    pub reference_exposure_index: f32,
    pub develop_exposure_ev: f32,
    pub camera_output_transform_id: String,
    pub environment: EnvironmentDocument,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnvironmentDocument {
    pub character_strength: f32,
    pub ambient_radiance: [f32; 3],
    pub key_radiance: [f32; 3],
    pub key_direction_local: [f32; 3],
    pub key_angular_radius_degrees: f32,
    pub rotation_degrees: f32,
    pub pattern: EnvironmentPatternDocument,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnvironmentPatternDocument {
    UniformNeutral,
    StudioSoftboxes,
    CalibrationGrid,
    OfficeCeiling,
    DaylightWindow,
    WarmPracticals,
    MixedProduction,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExactFrameRate {
    pub numerator: u32,
    pub denominator: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectPackage {
    pub manifest: ProjectManifest,
    pub source: SourceDocument,
    pub device: DeviceDocument,
    pub camera: CameraDocument,
    pub sensor: SensorDocument,
    pub screen: ScreenDocument,
    pub shot: ShotDocument,
}

impl ProjectPackage {
    pub fn validate(&self) -> Result<(), PersistenceError> {
        validate_manifest(&self.manifest)?;
        validate_header(
            &self.source.schema,
            self.source.version,
            "screen_simulation_source",
        )?;
        validate_header(
            &self.device.schema,
            self.device.version,
            "screen_simulation_device",
        )?;
        validate_header(
            &self.camera.schema,
            self.camera.version,
            "screen_simulation_camera",
        )?;
        validate_header(
            &self.sensor.schema,
            self.sensor.version,
            "screen_simulation_sensor",
        )?;
        validate_header(
            &self.screen.schema,
            self.screen.version,
            "screen_simulation_screen",
        )?;
        validate_header(
            &self.shot.schema,
            self.shot.version,
            "screen_simulation_shot",
        )?;
        validate_id(&self.manifest.project_id)?;
        validate_id(&self.source.source_id)?;
        validate_id(&self.device.device_id)?;
        validate_id(&self.camera.camera_id)?;
        validate_id(&self.sensor.sensor_id)?;
        validate_id(&self.screen.screen_id)?;
        validate_id(&self.shot.shot_id)?;
        PortablePath::parse(self.source.media.as_str())?;
        if self.source.media.as_str() == MANIFEST_NAME
            || [
                &self.manifest.source_document,
                &self.manifest.device_document,
                &self.manifest.camera_document,
                &self.manifest.sensor_document,
                &self.manifest.screen_document,
                &self.manifest.shot_document,
            ]
            .iter()
            .any(|path| path.as_str() == self.source.media.as_str())
        {
            return Err(PersistenceError::ResourceOverlapsDocument(
                self.source.media.as_str().to_owned(),
            ));
        }
        if self.shot.source_id != self.source.source_id
            || self.shot.device_id != self.device.device_id
            || self.shot.camera_id != self.camera.camera_id
            || self.shot.sensor_id != self.sensor.sensor_id
            || self.shot.screen_id != self.screen.screen_id
        {
            return Err(PersistenceError::InvalidShotReference);
        }
        if self.shot.project_frame_rate.numerator == 0
            || self.shot.project_frame_rate.denominator == 0
        {
            return Err(PersistenceError::InvalidFrameRate);
        }
        FrameRate::new(
            self.shot.project_frame_rate.numerator,
            self.shot.project_frame_rate.denominator,
        )
        .map_err(|_| PersistenceError::InvalidFrameRate)?;
        validate_keyframes(&self.camera.transform_keyframes)?;
        validate_intrinsics(&self.camera.intrinsics_keyframes)?;
        validate_keyframes(&self.screen.transform_keyframes)?;
        validate_device(&self.device)?;
        validate_environment(&self.shot.environment)?;
        validate_sensor(&self.sensor)?;
        if self
            .shot
            .white_balance_gains
            .into_iter()
            .any(|value| !value.is_finite() || !(0.01..=100.0).contains(&value))
            || !self.shot.neutral_density_stops.is_finite()
            || !(0.0..=16.0).contains(&self.shot.neutral_density_stops)
            || !self.shot.exposure_index.is_finite()
            || !(25.0..=12_800.0).contains(&self.shot.exposure_index)
            || !self
                .shot
                .middle_gray_illuminance_seconds_at_reference_ei
                .is_finite()
            || self.shot.middle_gray_illuminance_seconds_at_reference_ei <= 0.0
            || !self.shot.reference_exposure_index.is_finite()
            || !(25.0..=12_800.0).contains(&self.shot.reference_exposure_index)
            || !self.shot.develop_exposure_ev.is_finite()
            || !(-16.0..=16.0).contains(&self.shot.develop_exposure_ev)
            || self.shot.camera_output_transform_id.is_empty()
        {
            return Err(PersistenceError::InvalidCameraDevelopment);
        }
        Ok(())
    }
}

pub fn open_project(root: &Path) -> Result<ProjectPackage, PersistenceError> {
    if root.extension().and_then(|value| value.to_str()) != Some("screensim") {
        return Err(PersistenceError::InvalidPackageExtension);
    }
    let manifest: ProjectManifest = read_document(&root.join(MANIFEST_NAME))?;
    validate_manifest(&manifest)?;
    let package = ProjectPackage {
        source: read_document(&manifest.source_document.resolve(root))?,
        device: read_document(&manifest.device_document.resolve(root))?,
        camera: read_document(&manifest.camera_document.resolve(root))?,
        sensor: read_document(&manifest.sensor_document.resolve(root))?,
        screen: read_document(&manifest.screen_document.resolve(root))?,
        shot: read_document(&manifest.shot_document.resolve(root))?,
        manifest,
    };
    package.validate()?;
    if !package.source.media.resolve(root).is_file() {
        return Err(PersistenceError::MissingResource(
            package.source.media.0.clone(),
        ));
    }
    Ok(package)
}

pub fn create_project(
    root: &Path,
    package: &ProjectPackage,
    source_media: &Path,
) -> Result<(), PersistenceError> {
    package.validate()?;
    if root.extension().and_then(|value| value.to_str()) != Some("screensim") {
        return Err(PersistenceError::InvalidPackageExtension);
    }
    if root.exists() {
        return Err(PersistenceError::PackageAlreadyExists(root.to_path_buf()));
    }
    if !source_media.is_file() {
        return Err(PersistenceError::SourceMediaMissing(
            source_media.to_path_buf(),
        ));
    }
    let parent = root.parent().ok_or(PersistenceError::PackageHasNoParent)?;
    let file_name = root
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or(PersistenceError::PackageHasNoParent)?;
    let staging = parent.join(format!(".{file_name}.creating-{}", std::process::id()));
    if staging.exists() {
        return Err(PersistenceError::StagingPathAlreadyExists(staging));
    }
    let result = create_project_in(&staging, package, source_media).and_then(|()| {
        fs::rename(&staging, root).map_err(|error| PersistenceError::Io(root.to_path_buf(), error))
    });
    if result.is_err() && staging.exists() {
        let _ = fs::remove_dir_all(&staging);
    }
    result
}

fn create_project_in(
    root: &Path,
    package: &ProjectPackage,
    source_media: &Path,
) -> Result<(), PersistenceError> {
    fs::create_dir(root).map_err(|error| PersistenceError::Io(root.to_path_buf(), error))?;
    for path in [
        &package.manifest.source_document,
        &package.manifest.device_document,
        &package.manifest.camera_document,
        &package.manifest.sensor_document,
        &package.manifest.screen_document,
        &package.manifest.shot_document,
        &package.source.media,
    ] {
        let parent = path
            .resolve(root)
            .parent()
            .ok_or_else(|| PersistenceError::InvalidPortablePath(path.0.clone()))?
            .to_path_buf();
        fs::create_dir_all(&parent).map_err(|error| PersistenceError::Io(parent, error))?;
    }
    write_document(&root.join(MANIFEST_NAME), &package.manifest)?;
    write_document(
        &package.manifest.source_document.resolve(root),
        &package.source,
    )?;
    write_document(
        &package.manifest.device_document.resolve(root),
        &package.device,
    )?;
    write_document(
        &package.manifest.camera_document.resolve(root),
        &package.camera,
    )?;
    write_document(
        &package.manifest.sensor_document.resolve(root),
        &package.sensor,
    )?;
    write_document(
        &package.manifest.screen_document.resolve(root),
        &package.screen,
    )?;
    write_document(&package.manifest.shot_document.resolve(root), &package.shot)?;
    let media_target = package.source.media.resolve(root);
    fs::copy(source_media, &media_target)
        .map_err(|error| PersistenceError::Io(media_target, error))?;
    Ok(())
}

fn validate_manifest(manifest: &ProjectManifest) -> Result<(), PersistenceError> {
    validate_header(
        &manifest.schema,
        manifest.version,
        "screen_simulation_project",
    )?;
    validate_id(&manifest.project_id)?;
    if manifest.title.trim().is_empty() {
        return Err(PersistenceError::EmptyProjectTitle);
    }
    let paths = [
        &manifest.source_document,
        &manifest.device_document,
        &manifest.camera_document,
        &manifest.sensor_document,
        &manifest.screen_document,
        &manifest.shot_document,
    ];
    for path in paths {
        PortablePath::parse(path.as_str())?;
        if path.as_str() == MANIFEST_NAME {
            return Err(PersistenceError::DuplicateDocumentPath(
                path.as_str().to_owned(),
            ));
        }
    }
    for (index, left) in paths.iter().enumerate() {
        if paths[index + 1..]
            .iter()
            .any(|right| left.as_str() == right.as_str())
        {
            return Err(PersistenceError::DuplicateDocumentPath(
                left.as_str().to_owned(),
            ));
        }
    }
    Ok(())
}

fn validate_header(
    actual: &str,
    version: u32,
    expected: &'static str,
) -> Result<(), PersistenceError> {
    if actual != expected {
        return Err(PersistenceError::UnknownSchema(actual.to_owned()));
    }
    if version != CURRENT_VERSION {
        return Err(PersistenceError::UnknownVersion {
            schema: expected,
            version,
        });
    }
    Ok(())
}

fn validate_id(id: &OpaqueId) -> Result<(), PersistenceError> {
    OpaqueId::parse(id.as_str()).map(|_| ())
}

fn validate_time(time: ExactTime) -> Result<(), PersistenceError> {
    RationalTime::new(time.numerator, time.denominator)
        .map(|_| ())
        .map_err(|_| PersistenceError::InvalidExactTime)
}

fn validate_keyframes(keyframes: &[TransformKeyframe]) -> Result<(), PersistenceError> {
    if keyframes.is_empty() {
        return Err(PersistenceError::EmptyAnimationTrack);
    }
    let mut prior: Option<ExactTime> = None;
    let mut ids = HashSet::new();
    for keyframe in keyframes {
        validate_id(&keyframe.keyframe_id)?;
        if !ids.insert(keyframe.keyframe_id.as_str()) {
            return Err(PersistenceError::DuplicateKeyframeId);
        }
        validate_time(keyframe.time)?;
        if !keyframe
            .translation_meters
            .iter()
            .all(|value| value.is_finite())
            || !keyframe
                .rotation_quaternion
                .iter()
                .all(|value| value.is_finite())
        {
            return Err(PersistenceError::NonFiniteNumber);
        }
        let magnitude = keyframe
            .rotation_quaternion
            .iter()
            .map(|value| value * value)
            .sum::<f32>();
        if (magnitude - 1.0).abs() > 1.0e-4 {
            return Err(PersistenceError::NonNormalizedQuaternion);
        }
        if prior.is_some_and(|previous| compare_time(previous, keyframe.time).is_ge()) {
            return Err(PersistenceError::UnorderedKeyframes);
        }
        prior = Some(keyframe.time);
    }
    Ok(())
}

fn validate_intrinsics(keyframes: &[CameraIntrinsicsKeyframe]) -> Result<(), PersistenceError> {
    if keyframes.is_empty() {
        return Err(PersistenceError::EmptyAnimationTrack);
    }
    let mut prior: Option<ExactTime> = None;
    let mut ids = HashSet::new();
    for keyframe in keyframes {
        validate_id(&keyframe.keyframe_id)?;
        if !ids.insert(keyframe.keyframe_id.as_str()) {
            return Err(PersistenceError::DuplicateKeyframeId);
        }
        validate_time(keyframe.time)?;
        let values = [
            keyframe.focal_length_mm,
            keyframe.sensor_width_mm,
            keyframe.sensor_height_mm,
            keyframe.lens_shift[0],
            keyframe.lens_shift[1],
            keyframe.focus_distance_meters,
            keyframe.f_stop,
            keyframe.near_clip_meters,
            keyframe.far_clip_meters,
        ];
        if !values.iter().all(|value| value.is_finite()) {
            return Err(PersistenceError::NonFiniteNumber);
        }
        let lens_values = keyframe
            .lens
            .radial_distortion
            .into_iter()
            .chain(keyframe.lens.tangential_distortion)
            .chain(keyframe.lens.longitudinal_chromatic_meters)
            .chain(keyframe.lens.lateral_chromatic_scale)
            .chain([keyframe.lens.vignetting_strength])
            .chain(keyframe.lens.transmission_rgb)
            .chain([
                keyframe.lens.center_softness_micrometers,
                keyframe.lens.edge_softness_micrometers,
                keyframe.lens.veiling_glare_fraction,
            ]);
        if !lens_values.clone().all(f32::is_finite) {
            return Err(PersistenceError::NonFiniteNumber);
        }
        if keyframe.focal_length_mm <= 0.0
            || keyframe.sensor_width_mm <= 0.0
            || keyframe.sensor_height_mm <= 0.0
            || keyframe.focus_distance_meters <= 0.0
            || keyframe.f_stop <= 0.0
            || keyframe.near_clip_meters <= 0.0
            || keyframe.far_clip_meters <= keyframe.near_clip_meters
            || keyframe.lens_shift[0].abs() > 0.5
            || keyframe.lens_shift[1].abs() > 0.5
            || !(0.0..=1.0).contains(&keyframe.lens.vignetting_strength)
            || keyframe
                .lens
                .lateral_chromatic_scale
                .into_iter()
                .any(|value| !(0.5..=1.5).contains(&value))
            || keyframe
                .lens
                .transmission_rgb
                .into_iter()
                .any(|value| !(0.0..=1.0).contains(&value))
            || !(0.0..=100.0).contains(&keyframe.lens.center_softness_micrometers)
            || !(0.0..=100.0).contains(&keyframe.lens.edge_softness_micrometers)
            || !(0.0..=0.25).contains(&keyframe.lens.veiling_glare_fraction)
        {
            return Err(PersistenceError::InvalidCameraIntrinsics);
        }
        if prior.is_some_and(|previous| compare_time(previous, keyframe.time).is_ge()) {
            return Err(PersistenceError::UnorderedKeyframes);
        }
        prior = Some(keyframe.time);
    }
    Ok(())
}

fn validate_device(device: &DeviceDocument) -> Result<(), PersistenceError> {
    validate_time(device.residual_flicker_period)?;
    validate_time(device.residual_flicker_phase)?;
    validate_time(device.banding_period)?;
    validate_time(device.banding_on_duration)?;
    validate_time(device.banding_phase)?;
    let values = [
        device.active_width_meters,
        device.active_height_meters,
        device.black_matrix_fraction,
        device.eotf_gamma,
        device.black_level_nits,
        device.white_level_nits,
        device.primary_xy[0][0],
        device.primary_xy[0][1],
        device.primary_xy[1][0],
        device.primary_xy[1][1],
        device.primary_xy[2][0],
        device.primary_xy[2][1],
        device.white_xy[0],
        device.white_xy[1],
        device.angular_emission_power[0],
        device.angular_emission_power[1],
        device.angular_emission_power[2],
        device.residual_flicker_amplitude,
        device.banding_amount,
    ];
    if !values.iter().all(|value| value.is_finite()) {
        return Err(PersistenceError::NonFiniteNumber);
    }
    if device.native_width == 0
        || device.native_height == 0
        || device.active_width_meters <= 0.0
        || device.active_height_meters <= 0.0
        || !(0.0..1.0).contains(&device.black_matrix_fraction)
        || device.eotf_gamma <= 0.0
        || device.black_level_nits < 0.0
        || device.white_level_nits <= device.black_level_nits
        || device
            .primary_xy
            .iter()
            .chain([&device.white_xy])
            .any(|xy| xy[0] <= 0.0 || xy[1] <= 0.0 || xy[0] + xy[1] >= 1.0)
        || device
            .angular_emission_power
            .iter()
            .any(|value| *value < 0.0)
        || device.residual_flicker_period.numerator <= 0
        || device.banding_period.numerator <= 0
        || device.banding_on_duration.numerator <= 0
        || compare_time(device.banding_on_duration, device.banding_period).is_gt()
    {
        return Err(PersistenceError::InvalidDeviceProfile);
    }
    validate_cover(&device.cover)?;
    Ok(())
}

fn validate_cover(cover: &CoverDocument) -> Result<(), PersistenceError> {
    // Persistence owns only a finite serialized representation. Optical meaning and certified
    // ranges are validated once by screen-cover at the composition boundary.
    let finite = [
        cover.character_strength,
        cover.thickness_millimeters,
        cover.refractive_index,
        cover.anti_reflective_efficiency,
        cover.absorption_per_millimeter[0],
        cover.absorption_per_millimeter[1],
        cover.absorption_per_millimeter[2],
        cover.roughness,
        cover.haze,
        cover.glow.character_strength,
        cover.glow.scatter_fraction,
        cover.glow.core_radius_millimeters,
        cover.glow.tail_radius_millimeters,
        cover.glow.tail_fraction,
    ]
    .into_iter()
    .all(f32::is_finite);
    if !finite {
        return Err(PersistenceError::InvalidOpticalCover);
    }
    Ok(())
}

fn validate_environment(environment: &EnvironmentDocument) -> Result<(), PersistenceError> {
    let finite = [
        environment.character_strength,
        environment.ambient_radiance[0],
        environment.ambient_radiance[1],
        environment.ambient_radiance[2],
        environment.key_radiance[0],
        environment.key_radiance[1],
        environment.key_radiance[2],
        environment.key_direction_local[0],
        environment.key_direction_local[1],
        environment.key_direction_local[2],
        environment.key_angular_radius_degrees,
        environment.rotation_degrees,
    ]
    .into_iter()
    .all(f32::is_finite);
    if !finite {
        return Err(PersistenceError::InvalidEnvironment);
    }
    Ok(())
}

fn validate_sensor(sensor: &SensorDocument) -> Result<(), PersistenceError> {
    validate_time(sensor.shutter_duration)?;
    let finite = sensor
        .acescg_to_sensor
        .iter()
        .flatten()
        .chain(sensor.saturation_illuminance_seconds.iter())
        .copied()
        .chain([
            sensor.full_well_electrons,
            sensor.dark_current_electrons_per_second,
            sensor.read_noise_electrons_rms,
            sensor.analog_gain,
            sensor.bloom.character_strength,
            sensor.bloom.crosstalk_fraction,
            sensor.bloom.overflow_transfer_fraction,
        ])
        .all(f32::is_finite);
    if !finite {
        return Err(PersistenceError::NonFiniteNumber);
    }
    if let SensorReadoutDocument::Rolling { duration, .. } = sensor.readout {
        validate_time(duration)?;
        if duration.numerator <= 0 {
            return Err(PersistenceError::InvalidSensorProfile);
        }
    }
    if sensor.native_width == 0
        || sensor.native_height == 0
        || sensor.shutter_duration.numerator <= 0
        || !(1..=64).contains(&sensor.temporal_samples)
        || sensor
            .saturation_illuminance_seconds
            .iter()
            .any(|value| *value <= 0.0)
        || sensor.full_well_electrons <= 0.0
        || sensor.dark_current_electrons_per_second < 0.0
        || sensor.read_noise_electrons_rms < 0.0
        || sensor.analog_gain <= 0.0
        || !(8..=16).contains(&sensor.adc_bits)
    {
        return Err(PersistenceError::InvalidSensorProfile);
    }
    Ok(())
}

fn compare_time(left: ExactTime, right: ExactTime) -> core::cmp::Ordering {
    (i128::from(left.numerator) * i128::from(right.denominator))
        .cmp(&(i128::from(right.numerator) * i128::from(left.denominator)))
}

fn read_document<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, PersistenceError> {
    let bytes = fs::read(path).map_err(|error| PersistenceError::Io(path.to_path_buf(), error))?;
    serde_json::from_slice(&bytes)
        .map_err(|error| PersistenceError::InvalidDocument(path.to_path_buf(), error))
}

fn write_document<T: Serialize>(path: &Path, value: &T) -> Result<(), PersistenceError> {
    let mut bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| PersistenceError::Serialize(path.to_path_buf(), error))?;
    bytes.push(b'\n');
    fs::write(path, bytes).map_err(|error| PersistenceError::Io(path.to_path_buf(), error))
}

#[derive(Debug)]
pub enum PersistenceError {
    InvalidOpaqueId(String),
    InvalidPortablePath(String),
    InvalidPackageExtension,
    PackageAlreadyExists(PathBuf),
    SourceMediaMissing(PathBuf),
    PackageHasNoParent,
    StagingPathAlreadyExists(PathBuf),
    DuplicateDocumentPath(String),
    ResourceOverlapsDocument(String),
    UnknownSchema(String),
    UnknownVersion { schema: &'static str, version: u32 },
    EmptyProjectTitle,
    InvalidShotReference,
    InvalidFrameRate,
    InvalidExactTime,
    EmptyAnimationTrack,
    UnorderedKeyframes,
    DuplicateKeyframeId,
    NonNormalizedQuaternion,
    InvalidCameraIntrinsics,
    InvalidDeviceProfile,
    InvalidOpticalCover,
    InvalidEnvironment,
    InvalidSensorProfile,
    InvalidCameraDevelopment,
    NonFiniteNumber,
    MissingResource(String),
    Io(PathBuf, std::io::Error),
    InvalidDocument(PathBuf, serde_json::Error),
    Serialize(PathBuf, serde_json::Error),
}

impl fmt::Display for PersistenceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidOpaqueId(value) => write!(formatter, "invalid opaque id `{value}`"),
            Self::InvalidPortablePath(value) => {
                write!(formatter, "invalid portable path `{value}`")
            }
            Self::InvalidPackageExtension => {
                formatter.write_str("project package must end in .screensim")
            }
            Self::PackageAlreadyExists(path) => write!(
                formatter,
                "project package already exists: {}",
                path.display()
            ),
            Self::SourceMediaMissing(path) => {
                write!(formatter, "source media does not exist: {}", path.display())
            }
            Self::PackageHasNoParent => {
                formatter.write_str("project package requires a parent directory")
            }
            Self::StagingPathAlreadyExists(path) => write!(
                formatter,
                "project staging path already exists: {}",
                path.display()
            ),
            Self::DuplicateDocumentPath(path) => {
                write!(formatter, "project document path is duplicated: {path}")
            }
            Self::ResourceOverlapsDocument(path) => {
                write!(formatter, "project resource overlaps a document: {path}")
            }
            Self::UnknownSchema(schema) => {
                write!(formatter, "unknown project document schema `{schema}`")
            }
            Self::UnknownVersion { schema, version } => {
                write!(formatter, "unsupported version {version} for `{schema}`")
            }
            Self::EmptyProjectTitle => formatter.write_str("project title must not be empty"),
            Self::InvalidShotReference => {
                formatter.write_str("shot contains an invalid owner reference")
            }
            Self::InvalidFrameRate => formatter.write_str("project frame rate must be positive"),
            Self::InvalidExactTime => {
                formatter.write_str("exact time denominator must be non-zero")
            }
            Self::EmptyAnimationTrack => {
                formatter.write_str("animation track requires at least one keyframe")
            }
            Self::UnorderedKeyframes => {
                formatter.write_str("keyframes must have strictly increasing times")
            }
            Self::DuplicateKeyframeId => {
                formatter.write_str("keyframe ids must be unique within their track")
            }
            Self::NonNormalizedQuaternion => {
                formatter.write_str("rotation quaternion must be normalized")
            }
            Self::InvalidCameraIntrinsics => formatter.write_str("camera intrinsics are invalid"),
            Self::InvalidDeviceProfile => formatter.write_str("device profile is invalid"),
            Self::InvalidOpticalCover => formatter.write_str("optical cover profile is invalid"),
            Self::InvalidEnvironment => formatter.write_str("environment profile is invalid"),
            Self::InvalidSensorProfile => formatter.write_str("sensor profile is invalid"),
            Self::InvalidCameraDevelopment => formatter.write_str(
                "camera development requires explicit white balance and output transform",
            ),
            Self::NonFiniteNumber => {
                formatter.write_str("project documents cannot contain non-finite numbers")
            }
            Self::MissingResource(path) => write!(formatter, "project resource is missing: {path}"),
            Self::Io(path, error) => write!(
                formatter,
                "project I/O failed at {}: {error}",
                path.display()
            ),
            Self::InvalidDocument(path, error) => write!(
                formatter,
                "invalid project document {}: {error}",
                path.display()
            ),
            Self::Serialize(path, error) => write!(
                formatter,
                "cannot serialize project document {}: {error}",
                path.display()
            ),
        }
    }
}

impl std::error::Error for PersistenceError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(_, error) => Some(error),
            Self::InvalidDocument(_, error) | Self::Serialize(_, error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(value: &str) -> OpaqueId {
        OpaqueId::parse(value).expect("valid test id")
    }

    fn path(value: &str) -> PortablePath {
        PortablePath::parse(value).expect("valid test path")
    }

    fn transform(id_value: &str) -> TransformKeyframe {
        TransformKeyframe {
            keyframe_id: id(id_value),
            time: ExactTime {
                numerator: 0,
                denominator: 24,
            },
            translation_meters: [0.0, 0.0, 0.8],
            rotation_quaternion: [0.0, 0.0, 0.0, 1.0],
            interpolation: InterpolationSelection::Linear,
        }
    }

    fn package() -> ProjectPackage {
        ProjectPackage {
            manifest: ProjectManifest {
                schema: "screen_simulation_project".into(),
                version: CURRENT_VERSION,
                project_id: id("project-01"),
                title: "Persistence test".into(),
                source_document: path("sources/source.json"),
                device_document: path("devices/device.json"),
                camera_document: path("tracks/camera.json"),
                sensor_document: path("cameras/sensor.json"),
                screen_document: path("tracks/screen.json"),
                shot_document: path("shots/shot.json"),
            },
            source: SourceDocument {
                schema: "screen_simulation_source".into(),
                version: CURRENT_VERSION,
                source_id: id("source-01"),
                media: path("media/source.mov"),
                decode: PixelDecodeSelection {
                    matrix: MatrixSelection::Auto,
                    range: RangeSelection::Auto,
                },
                color: SourceColorSelection::Named {
                    transform_id: id("srgb-encoded-rec709"),
                },
                alpha: AlphaSelection::Straight,
                placement: PlacementSelection::Fit,
            },
            device: DeviceDocument {
                schema: "screen_simulation_device".into(),
                version: CURRENT_VERSION,
                device_id: id("device-01"),
                color_mode_id: id("srgb"),
                native_width: 3840,
                native_height: 2160,
                active_width_meters: 0.596_736,
                active_height_meters: 0.335_664,
                stripe: StripeSelection::Rgb,
                black_matrix_fraction: 0.12,
                eotf_gamma: 2.2,
                black_level_nits: 0.08,
                white_level_nits: 600.0,
                primary_xy: [[0.64, 0.33], [0.30, 0.60], [0.15, 0.06]],
                white_xy: [0.3127, 0.3290],
                angular_emission_power: [1.7, 1.5, 1.8],
                residual_flicker_period: ExactTime {
                    numerator: 1,
                    denominator: 240,
                },
                residual_flicker_amplitude: 0.002,
                residual_flicker_phase: ExactTime {
                    numerator: 0,
                    denominator: 1,
                },
                banding_period: ExactTime {
                    numerator: 1,
                    denominator: 960,
                },
                banding_on_duration: ExactTime {
                    numerator: 1,
                    denominator: 1_920,
                },
                banding_phase: ExactTime {
                    numerator: 0,
                    denominator: 1,
                },
                banding_amount: 0.0,
                cover: CoverDocument {
                    character_strength: 1.0,
                    thickness_millimeters: 0.8,
                    refractive_index: 1.5,
                    anti_reflective_efficiency: 0.62,
                    absorption_per_millimeter: [0.012; 3],
                    roughness: 0.65,
                    haze: 0.03,
                    glow: CoverGlowDocument {
                        character_strength: 1.0,
                        scatter_fraction: 0.08,
                        core_radius_millimeters: 0.22,
                        tail_radius_millimeters: 1.4,
                        tail_fraction: 0.18,
                    },
                },
            },
            camera: CameraDocument {
                schema: "screen_simulation_camera".into(),
                version: CURRENT_VERSION,
                camera_id: id("camera-01"),
                transform_keyframes: vec![transform("camera-key-01")],
                intrinsics_keyframes: vec![CameraIntrinsicsKeyframe {
                    keyframe_id: id("intrinsics-key-01"),
                    time: ExactTime {
                        numerator: 0,
                        denominator: 24,
                    },
                    focal_length_mm: 50.0,
                    sensor_width_mm: 36.0,
                    sensor_height_mm: 20.25,
                    lens_shift: [0.0, 0.0],
                    focus_distance_meters: 0.8,
                    f_stop: 8.0,
                    near_clip_meters: 0.01,
                    far_clip_meters: 100.0,
                    lens: LensDocument {
                        radial_distortion: [-0.035, 0.008, 0.0],
                        tangential_distortion: [0.000_4, -0.000_3],
                        longitudinal_chromatic_meters: [0.001_2, 0.0, -0.001_5],
                        lateral_chromatic_scale: [1.000_8, 1.0, 0.999_1],
                        vignetting_strength: 0.65,
                        transmission_rgb: [0.92, 0.94, 0.95],
                        center_softness_micrometers: 1.8,
                        edge_softness_micrometers: 2.2,
                        veiling_glare_fraction: 0.006,
                    },
                    interpolation: InterpolationSelection::Linear,
                }],
            },
            sensor: SensorDocument {
                schema: "screen_simulation_sensor".into(),
                version: CURRENT_VERSION,
                sensor_id: id("sensor-01"),
                native_width: 3_840,
                native_height: 2_160,
                bayer_pattern: BayerSelection::Rggb,
                acescg_to_sensor: [[0.72, 0.21, 0.07], [0.10, 0.82, 0.08], [0.03, 0.16, 0.81]],
                saturation_illuminance_seconds: [2.4, 2.4, 2.4],
                full_well_electrons: 45_000.0,
                dark_current_electrons_per_second: 0.1,
                read_noise_electrons_rms: 2.0,
                analog_gain: 1.0,
                adc_bits: 14,
                bloom: SensorBloomDocument {
                    character_strength: 1.0,
                    crosstalk_fraction: 0.012,
                    overflow_transfer_fraction: 0.45,
                },
                shutter_duration: ExactTime {
                    numerator: 1,
                    denominator: 48,
                },
                temporal_samples: 8,
                readout: SensorReadoutDocument::Global,
            },
            screen: ScreenDocument {
                schema: "screen_simulation_screen".into(),
                version: CURRENT_VERSION,
                screen_id: id("screen-01"),
                transform_keyframes: vec![transform("screen-key-01")],
            },
            shot: ShotDocument {
                schema: "screen_simulation_shot".into(),
                version: CURRENT_VERSION,
                shot_id: id("shot-01"),
                source_id: id("source-01"),
                device_id: id("device-01"),
                camera_id: id("camera-01"),
                sensor_id: id("sensor-01"),
                screen_id: id("screen-01"),
                project_frame_rate: ExactFrameRate {
                    numerator: 24,
                    denominator: 1,
                },
                sensor_noise_seed: 42,
                neutral_density_stops: 0.0,
                white_balance_gains: [2.0, 1.0, 1.5],
                exposure_index: 800.0,
                middle_gray_illuminance_seconds_at_reference_ei: 0.0125,
                reference_exposure_index: 800.0,
                develop_exposure_ev: 0.0,
                camera_output_transform_id: "aces2-srgb-sdr-100".into(),
                environment: EnvironmentDocument {
                    character_strength: 1.0,
                    ambient_radiance: [30.0; 3],
                    key_radiance: [220.0; 3],
                    key_direction_local: [-0.45, 0.35, 0.821_584],
                    key_angular_radius_degrees: 24.0,
                    rotation_degrees: 15.0,
                    pattern: EnvironmentPatternDocument::StudioSoftboxes,
                },
            },
        }
    }

    fn create_complete_project(root: &Path) -> ProjectPackage {
        let package = package();
        let media = root.parent().expect("root parent").join("source.mov");
        fs::write(&media, b"test media").expect("test media");
        create_project(root, &package, &media).expect("create strict project");
        package
    }

    #[test]
    fn portable_paths_reject_absolute_parent_and_windows_routes() {
        for invalid in [
            "/tmp/source.mov",
            "../source.mov",
            "media/../source.mov",
            "C:\\source.mov",
        ] {
            assert!(PortablePath::parse(invalid).is_err(), "accepted {invalid}");
        }
    }

    #[test]
    fn opening_is_byte_for_byte_read_only() {
        let temp = tempfile::tempdir().expect("temp dir");
        let root = temp.path().join("test.screensim");
        let expected = create_complete_project(&root);
        let before = snapshot(&root);
        assert_eq!(open_project(&root).expect("open project"), expected);
        assert_eq!(snapshot(&root), before);
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let temp = tempfile::tempdir().expect("temp dir");
        let root = temp.path().join("test.screensim");
        create_complete_project(&root);
        let manifest_path = root.join(MANIFEST_NAME);
        let text = fs::read_to_string(&manifest_path).expect("manifest");
        let current = format!("\"version\": {CURRENT_VERSION},");
        fs::write(
            &manifest_path,
            text.replacen(&current, &format!("{current}\n  \"legacy\": true,"), 1),
        )
        .expect("alter manifest");
        assert!(matches!(
            open_project(&root),
            Err(PersistenceError::InvalidDocument(_, _))
        ));
    }

    #[test]
    fn unknown_versions_are_rejected_without_dispatch() {
        for unknown in [CURRENT_VERSION - 1, CURRENT_VERSION + 1] {
            let temp = tempfile::tempdir().expect("temp dir");
            let root = temp.path().join("test.screensim");
            create_complete_project(&root);
            let manifest_path = root.join(MANIFEST_NAME);
            let text = fs::read_to_string(&manifest_path).expect("manifest");
            fs::write(
                &manifest_path,
                text.replacen(
                    &format!("\"version\": {CURRENT_VERSION}"),
                    &format!("\"version\": {unknown}"),
                    1,
                ),
            )
            .expect("alter manifest");
            assert!(matches!(
                open_project(&root),
                Err(PersistenceError::UnknownVersion { version, .. }) if version == unknown
            ));
        }
    }

    #[test]
    fn missing_fields_and_aliases_are_rejected() {
        let temp = tempfile::tempdir().expect("temp dir");
        let root = temp.path().join("test.screensim");
        create_complete_project(&root);
        let manifest_path = root.join(MANIFEST_NAME);
        let text = fs::read_to_string(&manifest_path).expect("manifest");
        fs::write(
            &manifest_path,
            text.replace("\"source_document\"", "\"sourceDocument\""),
        )
        .expect("alter manifest");
        assert!(matches!(
            open_project(&root),
            Err(PersistenceError::InvalidDocument(_, _))
        ));
    }

    #[test]
    fn invalid_cross_document_reference_is_rejected() {
        let mut package = package();
        package.shot.source_id = id("different-source");
        assert!(matches!(
            package.validate(),
            Err(PersistenceError::InvalidShotReference)
        ));
    }

    #[test]
    fn create_never_overwrites_an_existing_package() {
        let temp = tempfile::tempdir().expect("temp dir");
        let root = temp.path().join("test.screensim");
        fs::create_dir(&root).expect("existing package");
        let media = temp.path().join("source.mov");
        fs::write(&media, b"test media").expect("test media");
        assert!(matches!(
            create_project(&root, &package(), &media),
            Err(PersistenceError::PackageAlreadyExists(_))
        ));
    }

    #[test]
    fn failed_creation_never_publishes_a_partial_package() {
        let temp = tempfile::tempdir().expect("temp dir");
        let root = temp.path().join("test.screensim");
        let missing = temp.path().join("missing.mov");
        assert!(matches!(
            create_project(&root, &package(), &missing),
            Err(PersistenceError::SourceMediaMissing(_))
        ));
        assert!(!root.exists());
    }

    fn snapshot(root: &Path) -> Vec<(PathBuf, Vec<u8>)> {
        fn visit(root: &Path, path: &Path, files: &mut Vec<(PathBuf, Vec<u8>)>) {
            let mut entries: Vec<_> = fs::read_dir(path)
                .expect("read project directory")
                .map(|entry| entry.expect("project entry"))
                .collect();
            entries.sort_by_key(|entry| entry.file_name());
            for entry in entries {
                let path = entry.path();
                if path.is_dir() {
                    visit(root, &path, files);
                } else {
                    files.push((
                        path.strip_prefix(root).expect("relative").to_path_buf(),
                        fs::read(path).expect("file bytes"),
                    ));
                }
            }
        }
        let mut files = Vec::new();
        visit(root, root, &mut files);
        files
    }
}
