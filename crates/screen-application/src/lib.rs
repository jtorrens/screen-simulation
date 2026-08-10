//! UI-independent immutable request preparation and current-pipeline orchestration.

#![forbid(unsafe_code)]

mod physical_pipeline;
mod test_authoring;

pub use physical_pipeline::{
    PHYSICAL_STAGE_ORDER, PhysicalIntermediate, PhysicalPipelineSnapshot, PhysicalStage,
    PhysicalStageControl, ResolvedSceneGeometryLensSnapshot, ResolvedShutterMotionSnapshot,
    SourceAcesCgRaster,
};
pub use test_authoring::{
    COLOR_MODE_CONTROL_ID, DEVICE_CONTROL_ID, DEVICE_INTERPRETATION_PHASE_ID,
    FEEDER_SIGNAL_PHASE_ID, ORIGIN_PHASE_ID, OUTPUT_SIGNAL_CONTROL_ID, PLACEMENT_CONTROL_ID,
    PREVIEW_QUALITY_CONTROL_ID, ResolvedTestAuthoringSelection, TestAuthoringError,
    TestAuthoringSelection, TestChoiceOption, TestControlRequirement, TestPageDescriptor,
    TestPhaseDescriptor, TestPreviewResult, WHITE_LUMINANCE_CONTROL_ID, apply_test_choice,
    apply_test_scalar, apply_test_toggle, default_test_authoring_selection,
    resolve_test_authoring_selection, test_page_descriptor,
};

use core::fmt;
use rayon::prelude::*;
use screen_camera::{
    CameraDevelopment, CameraDevelopmentError, CpuRawDevelopment, DevelopedCameraRaster,
    DevelopedCameraRegion, RawDevelopmentBackend, develop_raw_to_acescg,
};
use screen_color::{ColorError, DiagnosticDisplayTransform, PreviewRgb, SourceToDeviceProcessor};
use screen_contracts::{
    ContractError, DeviceRgb, FrameRate, LinearRgb, Millimeters, RationalTime, Vec2, Vec3,
};
use screen_cover::{
    AcesCgRadiance, CoverError, CoverGlassProfile, CoverSurfaceSample, IncidentEnvironment,
    ProceduralEnvironment, ValidatedCoverEvaluator,
};
#[cfg(test)]
use screen_geometry::APERTURE_SAMPLE_COUNT;
use screen_geometry::{
    CameraRig, CameraSample, GeometryError, OpticalSample, PanelRegion, ProjectedScreen,
    ScreenSample, ScreenTrack, panel_uv_aperture_samples,
    panel_uv_aperture_samples_boxed_with_count, panel_uv_aperture_samples_with_count,
    panel_uv_at_viewport, panel_uv_continuous_pupil_footprint, project_scene_point, project_screen,
    projected_screen_gate_coverage, variance_matched_lens_psf_radius_millimeters,
    vfx_carrier_half_extent, vfx_rectangular_support_half_extent,
};
use screen_media::{AlphaInterpretation, AlphaPresence, DecodedFrame};
use screen_panel::{
    FlatPanelGeometry, FlatPanelQuality, FlatPanelSampling, LcdProfile, PanelError,
    PanelLightSpreadProfile, ValidatedPanelEvaluator,
};
use screen_sensor::{
    BayerPattern, CaptureIdentity, ComputationalCaptureProfile, IntegratedOpticalExposure,
    RawSensorRaster, RawSensorRegion, SensorBloomProfile, SensorError, SensorProfile, SensorRegion,
    expose_raw, expose_raw_region, expose_raw_with_noise_amount,
};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LensAssociationPolicy {
    Interchangeable,
    Fixed,
}

/// Explicit bridge from scene-referred photometry to the effective exposure
/// units accepted by a [`SensorProfile`].
///
/// `SensorProfile::saturation_illuminance_seconds` is intentionally an
/// effective, calibratable quantity: manufacturers generally do not publish
/// the quantum efficiency, microlens transmission and analogue gain needed to
/// derive it from first principles.  This profile anchors that approximation to
/// a reproducible ISO-style scene instead of treating panel nits as sensor
/// lux-seconds directly.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraRadiometricCalibration {
    /// ISO/EI at which this calibration was established.
    pub base_exposure_index: f32,
    /// Reference Lambertian card reflectance (normally 0.18).
    pub reference_lambertian_reflectance: f32,
    /// Illuminance incident on the reference card, in lux.
    pub reference_illuminance_lux: f32,
    /// T-stop used to establish the reference exposure.
    pub reference_t_stop: f32,
    /// Exposure duration for the reference capture, in seconds.
    pub reference_shutter_seconds: f32,
    /// Multiplicative conversion from physical sensor-plane lux·s to the
    /// profile's effective `saturation_illuminance_seconds` domain.
    pub effective_sensor_exposure_scale: f32,
    /// Human-readable provenance/limitation for the effective constant.
    pub provenance: &'static str,
}

impl CameraRadiometricCalibration {
    /// Neutral reference used by low-level physical fixtures only. Product
    /// capture presets must always provide their own documented calibration.
    pub const REFERENCE: Self = Self {
        base_exposure_index: 100.0,
        reference_lambertian_reflectance: 0.18,
        reference_illuminance_lux: 100.0,
        reference_t_stop: 4.0,
        reference_shutter_seconds: 1.0 / 48.0,
        effective_sensor_exposure_scale: 1.0,
        provenance: "Test-only neutral radiometric reference.",
    };

    /// Lambertian card luminance, in cd/m², for the declared reference scene.
    pub fn reference_card_luminance_nits(self) -> f32 {
        self.reference_illuminance_lux * self.reference_lambertian_reflectance
            / core::f32::consts::PI
    }

    /// Irradiance-time at the sensor plane for an ideal lossless T-stop.
    pub fn reference_sensor_plane_lux_seconds(self) -> f32 {
        self.reference_illuminance_lux * self.reference_lambertian_reflectance
            / (4.0 * self.reference_t_stop * self.reference_t_stop)
            * self.reference_shutter_seconds
    }

    /// Converts a Lambertian display luminance in cd/m² to ideal sensor-plane
    /// illuminance in lux for the active T-stop. T-stop, rather than f-number,
    /// is intentional: lens transmission belongs here exactly once.
    pub fn panel_luminance_to_sensor_plane_lux(active_t_stop: f32) -> f32 {
        core::f32::consts::PI / (4.0 * active_t_stop * active_t_stop)
    }

    /// The effective sensor-domain exposure that the calibration declares for
    /// its ISO-style reference card.
    pub fn reference_effective_sensor_exposure(self) -> f32 {
        self.reference_sensor_plane_lux_seconds() * self.effective_sensor_exposure_scale
    }

    pub fn validate(self) -> Result<(), &'static str> {
        if !self.base_exposure_index.is_finite() || self.base_exposure_index <= 0.0 {
            return Err("radiometric base EI must be finite and positive");
        }
        if !self.reference_lambertian_reflectance.is_finite()
            || !(0.0..=1.0).contains(&self.reference_lambertian_reflectance)
            || self.reference_lambertian_reflectance == 0.0
        {
            return Err("radiometric Lambertian reflectance must be in (0, 1]");
        }
        for (name, value) in [
            ("reference illuminance", self.reference_illuminance_lux),
            ("reference T-stop", self.reference_t_stop),
            ("reference shutter", self.reference_shutter_seconds),
            (
                "effective sensor exposure scale",
                self.effective_sensor_exposure_scale,
            ),
        ] {
            if !value.is_finite() || value <= 0.0 {
                return Err(match name {
                    "reference illuminance" => {
                        "radiometric reference illuminance must be finite and positive"
                    }
                    "reference T-stop" => {
                        "radiometric reference T-stop must be finite and positive"
                    }
                    "reference shutter" => {
                        "radiometric reference shutter must be finite and positive"
                    }
                    _ => "radiometric effective sensor exposure scale must be finite and positive",
                });
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptureDevicePreset {
    pub id: &'static str,
    pub label: &'static str,
    pub calibration: &'static str,
    pub sensor: SensorProfile,
    pub computational_capture: ComputationalCaptureProfile,
    pub gate_width: Millimeters,
    pub gate_height: Millimeters,
    pub default_lens_preset_id: &'static str,
    pub compatible_lens_preset_ids: &'static [&'static str],
    pub lens_association_policy: LensAssociationPolicy,
    pub f_stop: f32,
    pub reference_exposure_index: f32,
    pub middle_gray_illuminance_seconds_at_reference_ei: f32,
    pub radiometric_calibration: CameraRadiometricCalibration,
    pub default_shutter_angle_degrees: f32,
    pub default_temporal_samples: u16,
    pub default_readout_duration_milliseconds: f32,
}

pub const CAPTURE_DEVICE_PRESETS: &[CaptureDevicePreset] = &[
    CaptureDevicePreset {
        id: "arri-alexa-35-open-gate",
        label: "ARRI ALEXA 35 · 4.6K Open Gate",
        calibration: "Published ALEV 4 geometry · reference 50 mm lens",
        sensor: SensorProfile {
            native_width: 4_608,
            native_height: 3_164,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: SensorProfile::REFERENCE.acescg_to_sensor,
            saturation_illuminance_seconds: LinearRgb::new(2.4, 2.4, 2.4),
            full_well_electrons: 65_000.0,
            dark_current_electrons_per_second: 0.1,
            read_noise_electrons_rms: 2.0,
            analog_gain: 1.0,
            adc_bits: 14,
            bloom: SensorBloomProfile::LARGE_CAMERA,
        },
        computational_capture: ComputationalCaptureProfile::SINGLE_EXPOSURE,
        gate_width: Millimeters(27.99),
        gate_height: Millimeters(19.22),
        default_lens_preset_id: "generic-prime-50mm",
        compatible_lens_preset_ids: &[
            "generic-prime-18mm",
            "generic-prime-25mm",
            "generic-prime-35mm",
            "generic-prime-50mm",
            "generic-prime-85mm",
            "generic-prime-135mm",
        ],
        lens_association_policy: LensAssociationPolicy::Interchangeable,
        f_stop: 4.0,
        reference_exposure_index: 800.0,
        middle_gray_illuminance_seconds_at_reference_ei: 0.0125,
        radiometric_calibration: CameraRadiometricCalibration {
            base_exposure_index: 800.0,
            reference_lambertian_reflectance: 0.18,
            reference_illuminance_lux: 100.0,
            reference_t_stop: 4.0,
            reference_shutter_seconds: 1.0 / 48.0,
            // Effective calibration constant: public ALEV geometry is known,
            // but QE and analogue chain are not fully published.
            // 0.0125 effective lux·s at EI 800 / 0.005859375 physical
            // lux·s for the declared 18 % card, 100 lux, T4, 1/48 s anchor.
            effective_sensor_exposure_scale: 2.133_333_4,
            provenance: "Effective ISO-800 calibration anchored to 18% at 100 lux, T4, 1/48 s; public ALEV 4 geometry, sensor-chain constant is calibratable.",
        },
        default_shutter_angle_degrees: 180.0,
        default_temporal_samples: 1,
        default_readout_duration_milliseconds: 7.8,
    },
    CaptureDevicePreset {
        id: "iphone-16e-main-48mp",
        label: "iPhone 16e Main · 48 MP",
        calibration: "Developed-image approximation · 4.2 mm EXIF / 26 mm equivalent · residual post-GDC distortion · eight-exposure effective bracket",
        sensor: SensorProfile {
            native_width: 8_064,
            native_height: 6_048,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: SensorProfile::REFERENCE.acescg_to_sensor,
            saturation_illuminance_seconds: LinearRgb::new(0.8, 0.8, 0.8),
            full_well_electrons: 10_000.0,
            dark_current_electrons_per_second: 0.05,
            read_noise_electrons_rms: 1.5,
            analog_gain: 1.0,
            adc_bits: 12,
            bloom: SensorBloomProfile::SMALL_PIXEL_PHONE,
        },
        computational_capture: ComputationalCaptureProfile {
            exposure_count: 8,
            bracket_spacing_stops: 1.0,
        },
        gate_width: Millimeters(5.815_385),
        gate_height: Millimeters(4.361_539),
        default_lens_preset_id: "iphone-16e-main-integrated",
        compatible_lens_preset_ids: &["iphone-16e-main-integrated"],
        lens_association_policy: LensAssociationPolicy::Fixed,
        f_stop: 1.64,
        reference_exposure_index: 100.0,
        middle_gray_illuminance_seconds_at_reference_ei: 0.1,
        radiometric_calibration: CameraRadiometricCalibration {
            base_exposure_index: 100.0,
            reference_lambertian_reflectance: 0.18,
            reference_illuminance_lux: 100.0,
            reference_t_stop: 1.64,
            reference_shutter_seconds: 1.0 / 48.0,
            // Integrated mobile sensor QE/ISP is not public; this remains an
            // explicit calibratable effective constant, not a claimed spec.
            // 0.1 effective lux·s at ISO 100 / 0.03484656 physical lux·s
            // for the declared 18 % card, 100 lux, T1.64, 1/48 s anchor.
            effective_sensor_exposure_scale: 2.868_906_7,
            provenance: "Effective ISO-100 calibration anchored to 18% at 100 lux, T1.64, 1/48 s; integrated sensor-chain constant is calibratable.",
        },
        default_shutter_angle_degrees: 30.0,
        default_temporal_samples: 1,
        default_readout_duration_milliseconds: 12.0,
    },
    CaptureDevicePreset {
        id: "canon-powershot-a470-reference",
        label: "Canon PowerShot A470 · ECU-02 reference approximation",
        calibration: "ECU-02 developed-image camera/lens · residual distortion, sensor and radiometry approximated",
        sensor: SensorProfile {
            native_width: 3_072,
            native_height: 2_304,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: SensorProfile::REFERENCE.acescg_to_sensor,
            saturation_illuminance_seconds: LinearRgb::new(0.9, 0.9, 0.9),
            full_well_electrons: 18_000.0,
            dark_current_electrons_per_second: 0.12,
            read_noise_electrons_rms: 3.0,
            analog_gain: 1.0,
            adc_bits: 12,
            bloom: SensorBloomProfile::REFERENCE,
        },
        computational_capture: ComputationalCaptureProfile::SINGLE_EXPOSURE,
        gate_width: Millimeters(5.76),
        gate_height: Millimeters(4.32),
        default_lens_preset_id: "canon-a470-wide-reference",
        compatible_lens_preset_ids: &["canon-a470-wide-reference"],
        lens_association_policy: LensAssociationPolicy::Fixed,
        f_stop: 3.0,
        reference_exposure_index: 200.0,
        middle_gray_illuminance_seconds_at_reference_ei: 0.1,
        radiometric_calibration: CameraRadiometricCalibration {
            base_exposure_index: 200.0,
            reference_lambertian_reflectance: 0.18,
            reference_illuminance_lux: 100.0,
            reference_t_stop: 3.0,
            reference_shutter_seconds: 1.0 / 60.0,
            effective_sensor_exposure_scale: 12.0,
            provenance: "ECU-02 identifies Canon A470, 6.3 mm, f/3 and ISO 200; gate, full well and effective sensor-chain constant are reference approximations.",
        },
        default_shutter_angle_degrees: 144.0,
        default_temporal_samples: 1,
        default_readout_duration_milliseconds: 20.0,
    },
    CaptureDevicePreset {
        id: "iphone-14-pro-main-reference",
        label: "iPhone 14 Pro main · DCID reference approximation",
        calibration: "DCID developed-image capture family · residual distortion and sensor/radiometry approximated",
        sensor: SensorProfile {
            native_width: 8_064,
            native_height: 6_048,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: SensorProfile::REFERENCE.acescg_to_sensor,
            saturation_illuminance_seconds: LinearRgb::new(0.8, 0.8, 0.8),
            full_well_electrons: 12_000.0,
            dark_current_electrons_per_second: 0.05,
            read_noise_electrons_rms: 1.4,
            analog_gain: 1.0,
            adc_bits: 12,
            bloom: SensorBloomProfile::SMALL_PIXEL_PHONE,
        },
        computational_capture: ComputationalCaptureProfile {
            exposure_count: 3,
            bracket_spacing_stops: 1.0,
        },
        gate_width: Millimeters(9.8),
        gate_height: Millimeters(7.35),
        default_lens_preset_id: "iphone-14-pro-main-reference",
        compatible_lens_preset_ids: &["iphone-14-pro-main-reference"],
        lens_association_policy: LensAssociationPolicy::Fixed,
        f_stop: 1.78,
        reference_exposure_index: 100.0,
        middle_gray_illuminance_seconds_at_reference_ei: 0.1,
        radiometric_calibration: CameraRadiometricCalibration {
            base_exposure_index: 100.0,
            reference_lambertian_reflectance: 0.18,
            reference_illuminance_lux: 100.0,
            reference_t_stop: 1.78,
            reference_shutter_seconds: 1.0 / 60.0,
            effective_sensor_exposure_scale: 4.224_533_6,
            provenance: "DCID identifies the iPhone 14 Pro capture family; physical gate, full well and effective sensor-chain constant are explicit reference approximations.",
        },
        default_shutter_angle_degrees: 144.0,
        default_temporal_samples: 1,
        default_readout_duration_milliseconds: 12.0,
    },
    CaptureDevicePreset {
        id: "iphone-14-pro-ultrawide-reference",
        label: "iPhone 14 Pro ultra-wide · DCID reference approximation",
        calibration: "DCID developed-image capture family · residual distortion and sensor/radiometry approximated",
        sensor: SensorProfile {
            native_width: 4_032,
            native_height: 3_024,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: SensorProfile::REFERENCE.acescg_to_sensor,
            saturation_illuminance_seconds: LinearRgb::new(0.8, 0.8, 0.8),
            full_well_electrons: 8_000.0,
            dark_current_electrons_per_second: 0.05,
            read_noise_electrons_rms: 1.7,
            analog_gain: 1.0,
            adc_bits: 12,
            bloom: SensorBloomProfile::SMALL_PIXEL_PHONE,
        },
        computational_capture: ComputationalCaptureProfile {
            exposure_count: 3,
            bracket_spacing_stops: 1.0,
        },
        gate_width: Millimeters(5.6),
        gate_height: Millimeters(4.2),
        default_lens_preset_id: "iphone-14-pro-ultrawide-reference",
        compatible_lens_preset_ids: &["iphone-14-pro-ultrawide-reference"],
        lens_association_policy: LensAssociationPolicy::Fixed,
        f_stop: 2.2,
        reference_exposure_index: 100.0,
        middle_gray_illuminance_seconds_at_reference_ei: 0.1,
        radiometric_calibration: CameraRadiometricCalibration {
            base_exposure_index: 100.0,
            reference_lambertian_reflectance: 0.18,
            reference_illuminance_lux: 100.0,
            reference_t_stop: 2.2,
            reference_shutter_seconds: 1.0 / 60.0,
            effective_sensor_exposure_scale: 6.453_333,
            provenance: "DCID identifies the iPhone 14 Pro capture family; physical gate, full well and effective sensor-chain constant are explicit reference approximations.",
        },
        default_shutter_angle_degrees: 144.0,
        default_temporal_samples: 1,
        default_readout_duration_milliseconds: 14.0,
    },
];

pub fn capture_device_preset(id: &str) -> Option<CaptureDevicePreset> {
    CAPTURE_DEVICE_PRESETS
        .iter()
        .copied()
        .find(|preset| preset.id == id)
}
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RasterPlacement {
    Fit,
    FillCrop,
    Stretch,
    OneToOne,
}

/// Fraction of the active device raster occupied by authored source samples.
/// Fit and One-to-One may leave an explicitly black feeder surround; Fill/Crop
/// and Stretch occupy the complete active raster.
pub fn placed_signal_area_fraction(
    placement: RasterPlacement,
    source_width: u32,
    source_height: u32,
    device_width: u32,
    device_height: u32,
) -> f32 {
    let source_aspect = source_width as f32 / source_height as f32;
    let device_aspect = device_width as f32 / device_height as f32;
    match placement {
        RasterPlacement::Fit => (source_aspect / device_aspect)
            .min(device_aspect / source_aspect)
            .clamp(0.0, 1.0),
        RasterPlacement::FillCrop | RasterPlacement::Stretch => 1.0,
        RasterPlacement::OneToOne => ((source_width as f32 / device_width as f32).min(1.0)
            * (source_height as f32 / device_height as f32).min(1.0))
        .clamp(0.0, 1.0),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceSignalRaster {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<DeviceRgb>,
}

#[derive(Clone, Debug)]
pub struct PreparedDeviceSignalRaster {
    source: DeviceSignalRaster,
    integral: DeviceSignalIntegral,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicalPipelineInput {
    pub width: u32,
    pub height: u32,
    /// Coarse linear ACEScg RGBA entering the physical boundary.
    pub acescg: Vec<[f32; 4]>,
    /// The explicitly color-resolved device code for the same source samples.
    pub device_signal: DeviceSignalRaster,
    /// Explicit scene-linear ACEScg equirectangular incident-radiance map.
    /// It must be present exactly when the resolved environment selects the
    /// image-backed source.
    pub environment_acescg: Option<EnvironmentRadianceRaster>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EnvironmentRadianceRaster {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<[f32; 4]>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicalPipelineRequest {
    pub input: PhysicalPipelineInput,
    pub plan: PhysicalPipelineExecutionPlan,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalPipelineExecutionPlan {
    pub panel: LcdProfile,
    pub panel_light_spread: PanelLightSpreadProfile,
    pub placement: RasterPlacement,
    pub quality: FlatPanelQuality,
    pub requested_width: u32,
    pub requested_height: u32,
    pub screen_amount: f32,
    pub emission_amount: f32,
    pub subpixel_geometry_amount: f32,
    /// Continuous contribution from the calibrated, shutter-integrated panel
    /// temporal model. Zero is exact identity and one is the resolved profile.
    pub temporal_emission_amount: f32,
    /// Calibrated exposure-average emission gain resolved with exact rational
    /// timing by the Rust executor. Metal only evaluates this materialized value.
    pub temporal_emission_gain: f32,
    pub cover: CoverGlassProfile,
    pub environment: IncidentEnvironment,
    pub scene_geometry_lens: ResolvedSceneGeometryLensSnapshot,
    pub camera_position: Vec3,
    pub camera_rotation: screen_geometry::Quaternion,
    pub screen_translation: Vec3,
    pub screen_rotation: screen_geometry::Quaternion,
    pub scene_geometry_amount: f32,
    pub lens_amount: f32,
    pub lens_evaluation_model: LensEvaluationModel,
    pub frame_time: RationalTime,
    pub shutter_open: RationalTime,
    pub shutter_close: RationalTime,
    pub shutter_motion: ResolvedShutterMotionSnapshot,
    pub shutter_motion_amount: f32,
    pub computational_capture: ComputationalCaptureProfile,
    pub computational_character_strength: f32,
    pub sensor: SensorProfile,
    pub radiometric_calibration: CameraRadiometricCalibration,
    pub sensor_enabled: bool,
    pub sensor_noise_amount: f32,
    pub development: CameraDevelopment,
    pub development_enabled: bool,
    pub frame_index: i64,
    pub requested_intermediate: PhysicalIntermediate,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LensEvaluationModel {
    ThinLens,
    VfxDepthBlur,
}

/// Direct full-pipeline aperture integration policy. Aperture and sensor-footprint
/// samples are independent axes. The complete physical-frame evaluator uses this
/// one deterministic point-pupil policy at every quality level.
pub fn physical_pipeline_aperture_sample_count(quality: FlatPanelQuality) -> usize {
    match quality {
        FlatPanelQuality::Draft
        | FlatPanelQuality::Medium
        | FlatPanelQuality::High
        | FlatPanelQuality::Native => 32,
    }
}

impl PhysicalPipelineExecutionPlan {
    /// Returns the current immutable request with every stage after the requested
    /// diagnostic boundary neutralized. Geometry is a data checkpoint: it becomes
    /// observable by the following cover/environment stage without fabricating a
    /// separate display-referred raster.
    pub fn stopped_at_requested_intermediate(mut self) -> Self {
        match self.requested_intermediate {
            PhysicalIntermediate::SourceAcesCg
            | PhysicalIntermediate::DeviceSignal
            | PhysicalIntermediate::PanelEmission
            | PhysicalIntermediate::SubpixelRadiance
            | PhysicalIntermediate::PanelLightSpread => {
                self.scene_geometry_amount = 0.0;
                self.lens_amount = 0.0;
                self.cover.glow.character_strength = 0.0;
            }
            PhysicalIntermediate::RelativeGeometry | PhysicalIntermediate::CoverEnvironment => {
                self.lens_amount = 0.0;
                self.cover.glow.character_strength = 0.0;
            }
            PhysicalIntermediate::CoverGlow => {
                self.lens_amount = 0.0;
            }
            PhysicalIntermediate::LensProjection
            | PhysicalIntermediate::ShutterMotion
            | PhysicalIntermediate::ComputationalCapture
            | PhysicalIntermediate::RawMosaic
            | PhysicalIntermediate::DevelopedAcesCg => {}
            PhysicalIntermediate::SensorBloom | PhysicalIntermediate::SensorNoise => {
                self.sensor_noise_amount = 0.0;
            }
        }
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalPipelineDiagnostic {
    pub geometry: FlatPanelGeometry,
    pub sampling: FlatPanelSampling,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicalPipelineCpuResult {
    pub width: u32,
    pub height: u32,
    pub acescg: Vec<[f32; 4]>,
    pub diagnostic: PhysicalPipelineDiagnostic,
}

fn resample_physical_rgba_area(
    source: &[[f32; 4]],
    source_width: u32,
    source_height: u32,
    output_width: u32,
    output_height: u32,
) -> Vec<[f32; 4]> {
    let mut output = Vec::with_capacity((output_width * output_height) as usize);
    for output_y in 0..output_height {
        let minimum_y = output_y as f64 * source_height as f64 / output_height as f64;
        let maximum_y = (output_y + 1) as f64 * source_height as f64 / output_height as f64;
        for output_x in 0..output_width {
            let minimum_x = output_x as f64 * source_width as f64 / output_width as f64;
            let maximum_x = (output_x + 1) as f64 * source_width as f64 / output_width as f64;
            let mut sum = [0.0_f64; 4];
            let mut area = 0.0_f64;
            for source_y in minimum_y.floor() as u32..maximum_y.ceil() as u32 {
                let overlap_y = (maximum_y.min(f64::from(source_y + 1))
                    - minimum_y.max(f64::from(source_y)))
                .max(0.0);
                for source_x in minimum_x.floor() as u32..maximum_x.ceil() as u32 {
                    let overlap_x = (maximum_x.min(f64::from(source_x + 1))
                        - minimum_x.max(f64::from(source_x)))
                    .max(0.0);
                    let weight = overlap_x * overlap_y;
                    let pixel = source[(source_y.min(source_height - 1) * source_width
                        + source_x.min(source_width - 1))
                        as usize];
                    for channel in 0..4 {
                        sum[channel] += f64::from(pixel[channel]) * weight;
                    }
                    area += weight;
                }
            }
            output.push(sum.map(|value| (value / area) as f32));
        }
    }
    output
}

/// Canonical Application-owned transition from the shutter-integrated physical
/// raster into the Sensor-owned integer RAW boundary. Platform adapters may
/// accelerate the optical work before this call and camera development after
/// it, but they cannot reproduce photosite, noise, clipping, or ADC semantics.
pub fn expose_physical_pipeline_raw(
    shuttered: &[[f32; 4]],
    shuttered_width: u32,
    shuttered_height: u32,
    plan: PhysicalPipelineExecutionPlan,
) -> Result<RawSensorRaster, ApplicationError> {
    let expected = u64::from(shuttered_width) * u64::from(shuttered_height);
    if shuttered_width == 0
        || shuttered_height == 0
        || shuttered.len() as u64 != expected
        || !plan.sensor_enabled
        || !matches!(
            plan.requested_intermediate,
            PhysicalIntermediate::SensorBloom
                | PhysicalIntermediate::SensorNoise
                | PhysicalIntermediate::RawMosaic
                | PhysicalIntermediate::DevelopedAcesCg
        )
    {
        return Err(ApplicationError::OpticalSampleRasterMismatch);
    }
    let sensor = plan
        .computational_capture
        .effective_sensor(plan.sensor, plan.computational_character_strength)
        .map_err(ApplicationError::Sensor)?;
    plan.radiometric_calibration
        .validate()
        .map_err(ApplicationError::InvalidRadiometricCalibration)?;
    let parameters = plan
        .panel
        .evaluator()
        .map_err(ApplicationError::Panel)?
        .device_stage_parameters();
    let sensor_pixels = resample_physical_rgba_area(
        shuttered,
        shuttered_width,
        shuttered_height,
        u32::from(sensor.native_width),
        u32::from(sensor.native_height),
    );
    let duration = plan
        .shutter_close
        .checked_sub(plan.shutter_open)
        .map_err(ApplicationError::Time)?;
    // The optical checkpoint already contains the lens pupil throughput,
    // including the inverse-square f-number term. This boundary restores the
    // panel's absolute luminance and applies only the calibrated sensor-domain
    // conversion; reevaluating the pupil here would apply the aperture twice.
    let exposure_scale =
        parameters.white_level_nits * plan.radiometric_calibration.effective_sensor_exposure_scale;
    let exposure = IntegratedOpticalExposure {
        width: u32::from(sensor.native_width),
        height: u32::from(sensor.native_height),
        duration_seconds: duration.as_seconds() as f32,
        acescg_illuminance_seconds: sensor_pixels
            .iter()
            .map(|pixel| {
                LinearRgb::new(
                    pixel[0] * exposure_scale,
                    pixel[1] * exposure_scale,
                    pixel[2] * exposure_scale,
                )
            })
            .collect(),
    };
    expose_raw_with_noise_amount(
        sensor,
        &exposure,
        CaptureIdentity {
            noise_seed: plan.shutter_motion.noise_seed,
            frame_index: plan.frame_index,
        },
        plan.sensor_noise_amount,
    )
    .map_err(ApplicationError::Sensor)
}

impl DeviceSignalRaster {
    pub fn validate(&self) -> Result<(), ApplicationError> {
        if self.width == 0 || self.height == 0 {
            return Err(ApplicationError::EmptyDeviceSignalRaster);
        }
        let expected = u64::from(self.width) * u64::from(self.height);
        if self.pixels.len() as u64 != expected {
            return Err(ApplicationError::DeviceSignalPixelCountMismatch {
                expected,
                actual: self.pixels.len() as u64,
            });
        }
        if self
            .pixels
            .iter()
            .any(|pixel| !pixel.r.is_finite() || !pixel.g.is_finite() || !pixel.b.is_finite())
        {
            return Err(ApplicationError::NonFiniteDeviceSignal);
        }
        Ok(())
    }

    fn sample_native_pixel(&self, uv: Vec2) -> DeviceRgb {
        let x = (uv.x * self.width as f32)
            .floor()
            .clamp(0.0, self.width.saturating_sub(1) as f32) as u32;
        let y = (uv.y * self.height as f32)
            .floor()
            .clamp(0.0, self.height.saturating_sub(1) as f32) as u32;
        self.pixels[(u64::from(y) * u64::from(self.width) + u64::from(x)) as usize]
    }
}

impl PreparedDeviceSignalRaster {
    pub fn new(source: DeviceSignalRaster) -> Result<Self, ApplicationError> {
        source.validate()?;
        let integral = DeviceSignalIntegral::new(&source);
        Ok(Self { source, integral })
    }

    pub fn raster_size(&self) -> [u32; 2] {
        [self.source.width, self.source.height]
    }
}

impl PhysicalPipelineInput {
    fn validate(&self) -> Result<(), ApplicationError> {
        if self.width == 0 || self.height == 0 {
            return Err(ApplicationError::EmptyDeviceSignalRaster);
        }
        let expected = u64::from(self.width) * u64::from(self.height);
        if self.acescg.len() as u64 != expected {
            return Err(ApplicationError::DecodedPixelCountMismatch {
                expected,
                actual: self.acescg.len() as u64,
            });
        }
        if self.device_signal.width != self.width || self.device_signal.height != self.height {
            return Err(ApplicationError::OpticalSampleRasterMismatch);
        }
        self.device_signal.validate()
    }
}

impl EnvironmentRadianceRaster {
    fn validate(&self) -> Result<(), ApplicationError> {
        if self.width < 2 || self.height < 2 || self.width != self.height.saturating_mul(2) {
            return Err(ApplicationError::OpticalSampleRasterMismatch);
        }
        let expected = u64::from(self.width) * u64::from(self.height);
        if self.rgba.len() as u64 != expected {
            return Err(ApplicationError::DecodedPixelCountMismatch {
                expected,
                actual: self.rgba.len() as u64,
            });
        }
        if self.rgba.iter().flatten().any(|value| !value.is_finite()) {
            return Err(ApplicationError::NonFiniteDeviceSignal);
        }
        Ok(())
    }

    fn sample_equirectangular(
        &self,
        direction: [f32; 3],
        rotation_degrees: f32,
        roughness: f32,
        haze: f32,
    ) -> LinearRgb {
        let length = direction
            .into_iter()
            .map(|value| value * value)
            .sum::<f32>()
            .sqrt();
        let mut direction = direction.map(|value| value / length.max(1.0e-8));
        let (sine, cosine) = rotation_degrees.to_radians().sin_cos();
        direction = [
            direction[0] * cosine + direction[2] * sine,
            direction[1],
            -direction[0] * sine + direction[2] * cosine,
        ];
        let u = (direction[0].atan2(direction[2]) / core::f32::consts::TAU + 0.5).rem_euclid(1.0);
        let v =
            (0.5 - direction[1].clamp(-1.0, 1.0).asin() / core::f32::consts::PI).clamp(0.0, 1.0);
        // Box footprint equivalent to the GPU mip choice. The authored
        // perceptual roughness becomes the conventional squared microfacet
        // slope. Its angular reflection radius, plus the independent haze
        // lobe, is then converted through the equirectangular texel density.
        // This keeps the response independent from the HDR raster resolution.
        let footprint = environment_reflection_footprint_texels(self.width, roughness, haze);
        let taps = 4_u32;
        let mut sum = [0.0_f32; 3];
        for y in 0..taps {
            for x in 0..taps {
                let offset_x = (x as f32 + 0.5) / taps as f32 - 0.5;
                let offset_y = (y as f32 + 0.5) / taps as f32 - 0.5;
                let sample_u = (u + offset_x * footprint / self.width as f32).rem_euclid(1.0);
                let sample_v = (v + offset_y * footprint / self.height as f32).clamp(0.0, 1.0);
                let px = (sample_u * self.width as f32)
                    .floor()
                    .rem_euclid(self.width as f32) as u32;
                let py = (sample_v * self.height as f32)
                    .floor()
                    .clamp(0.0, self.height.saturating_sub(1) as f32)
                    as u32;
                let pixel = self.rgba[(py * self.width + px) as usize];
                sum[0] += pixel[0];
                sum[1] += pixel[1];
                sum[2] += pixel[2];
            }
        }
        let reciprocal = 1.0 / (taps * taps) as f32;
        LinearRgb::new(
            sum[0] * reciprocal,
            sum[1] * reciprocal,
            sum[2] * reciprocal,
        )
    }
}

fn environment_reflection_footprint_texels(width: u32, roughness: f32, haze: f32) -> f32 {
    let microfacet_slope = roughness * roughness;
    let microfacet_radius = microfacet_slope.atan();
    let haze_radius = haze * core::f32::consts::FRAC_PI_2;
    let lobe_radius = (microfacet_radius + haze_radius).clamp(0.0, core::f32::consts::FRAC_PI_2);
    // A lobe with angular radius r has diameter 2r. A 2:1 panorama has
    // width / 2pi texels per radian, hence width * r / pi texels.
    (width as f32 * lobe_radius / core::f32::consts::PI).max(1.0)
}

fn sample_placed_acescg_area(
    source_width: u32,
    source_height: u32,
    acescg: &[[f32; 4]],
    device_raster: [u32; 2],
    placement: RasterPlacement,
    minimum: Vec2,
    maximum: Vec2,
) -> [f32; 4] {
    let source_raster = [source_width, source_height];
    let Some(first) = source_uv_unbounded(source_raster, device_raster, placement, minimum) else {
        return [0.0; 4];
    };
    let Some(second) = source_uv_unbounded(source_raster, device_raster, placement, maximum) else {
        return [0.0; 4];
    };
    let minimum = Vec2 {
        x: first.x.min(second.x) * source_width as f32,
        y: first.y.min(second.y) * source_height as f32,
    };
    let maximum = Vec2 {
        x: first.x.max(second.x) * source_width as f32,
        y: first.y.max(second.y) * source_height as f32,
    };
    let area = ((maximum.x - minimum.x) * (maximum.y - minimum.y)).max(1.0e-12);
    let mut sum = [0.0_f64; 4];
    for y in minimum.y.floor() as i64..maximum.y.ceil() as i64 {
        if y < 0 || y >= i64::from(source_height) {
            continue;
        }
        let weight_y = (maximum.y.min((y + 1) as f32) - minimum.y.max(y as f32)).max(0.0);
        for x in minimum.x.floor() as i64..maximum.x.ceil() as i64 {
            if x < 0 || x >= i64::from(source_width) {
                continue;
            }
            let weight_x = (maximum.x.min((x + 1) as f32) - minimum.x.max(x as f32)).max(0.0);
            let value = acescg[(y as u32 * source_width + x as u32) as usize];
            for channel in 0..4 {
                sum[channel] += f64::from(value[channel]) * f64::from(weight_x * weight_y);
            }
        }
    }
    sum.map(|value| (value / f64::from(area)) as f32)
}

/// Deterministic scalar oracle for the flat, orthographic physical panel surface.
/// Product composition uses the corresponding platform backend; this function
/// owns the reference numeric result and never applies a camera or output transform.
pub fn evaluate_physical_pipeline_cpu_oracle(
    request: PhysicalPipelineRequest,
) -> Result<PhysicalPipelineCpuResult, ApplicationError> {
    request.input.validate()?;
    let plan = request.plan.stopped_at_requested_intermediate();
    plan.environment
        .validate()
        .map_err(ApplicationError::Cover)?;
    match (plan.environment, request.input.environment_acescg.as_ref()) {
        (IncidentEnvironment::Procedural(_), None) => {}
        (IncidentEnvironment::Equirectangular(_), Some(raster)) => raster.validate()?,
        _ => return Err(ApplicationError::OpticalSampleRasterMismatch),
    }
    if [
        plan.screen_amount,
        plan.emission_amount,
        plan.subpixel_geometry_amount,
        plan.temporal_emission_amount,
        plan.scene_geometry_amount,
        plan.lens_amount,
        plan.shutter_motion_amount,
        plan.sensor_noise_amount,
    ]
    .into_iter()
    .any(|amount| !amount.is_finite() || !(0.0..=4.0).contains(&amount))
        || !plan.temporal_emission_gain.is_finite()
    {
        return Err(ApplicationError::InvalidCharacterStrength);
    }
    plan.panel_light_spread
        .validate()
        .map_err(ApplicationError::Panel)?;
    let cover = plan
        .cover
        .evaluator(match plan.environment {
            IncidentEnvironment::Procedural(environment) => environment,
            IncidentEnvironment::Equirectangular(_) => ProceduralEnvironment::NONE,
        })
        .map_err(ApplicationError::Cover)?;
    let resolved_scene = plan
        .scene_geometry_lens
        .resolve(
            plan.camera_position,
            plan.camera_rotation,
            plan.screen_translation,
            plan.screen_rotation,
            plan.lens_amount,
        )
        .map_err(ApplicationError::Geometry)?;
    let geometry = request
        .plan
        .panel
        .flat_panel_geometry()
        .map_err(ApplicationError::Panel)?;
    let sampling = request
        .plan
        .panel
        .flat_panel_sampling(plan.quality, plan.requested_width, plan.requested_height)
        .map_err(ApplicationError::Panel)?;

    // This stage can promise exact identity at zero because it returns the
    // borrowed coarse raster domain without resampling or float arithmetic.
    if plan.screen_amount == 0.0
        && matches!(
            plan.requested_intermediate,
            PhysicalIntermediate::SourceAcesCg | PhysicalIntermediate::DevelopedAcesCg
        )
    {
        return Ok(PhysicalPipelineCpuResult {
            width: request.input.width,
            height: request.input.height,
            acescg: request.input.acescg,
            diagnostic: PhysicalPipelineDiagnostic { geometry, sampling },
        });
    }

    let evaluator = plan.panel.evaluator().map_err(ApplicationError::Panel)?;
    let parameters = evaluator.device_stage_parameters();
    let source_width = request.input.width;
    let source_height = request.input.height;
    let source_acescg = request.input.acescg;
    let prepared = PreparedDeviceSignalRaster::new(request.input.device_signal)?;
    let emission_integral = DeviceSignalIntegral::new_mapped(&prepared.source, |value| {
        DeviceRgb::new(
            evaluator.native_channel(value, 0),
            evaluator.native_channel(value, 1),
            evaluator.native_channel(value, 2),
        )
    });
    let veiling_glare_gate_average =
        {
            let camera = resolved_scene.0;
            let screen = resolved_scene.1;
            let fraction = camera.lens.veiling_glare_fraction;
            if fraction == 0.0 {
                LinearRgb::new(0.0, 0.0, 0.0)
            } else {
                let reciprocal = 1.0 / prepared.source.pixels.len() as f32;
                let mean_native = prepared.source.pixels.iter().fold(
                    LinearRgb::new(0.0, 0.0, 0.0),
                    |sum, pixel| {
                        LinearRgb::new(
                            sum.r + evaluator.native_channel(*pixel, 0),
                            sum.g + evaluator.native_channel(*pixel, 1),
                            sum.b + evaluator.native_channel(*pixel, 2),
                        )
                    },
                );
                let mean_native = LinearRgb::new(
                    mean_native.r * reciprocal,
                    mean_native.g * reciprocal,
                    mean_native.b * reciprocal,
                );
                let projected = project_screen(
                    camera,
                    screen,
                    plan.panel.active_width,
                    plan.panel.active_height,
                    sampling.effective_width as f32 / sampling.effective_height as f32,
                );
                let coverage = projected.map_or(0.0, projected_screen_gate_coverage)
                    * placed_signal_area_fraction(
                        plan.placement,
                        source_width,
                        source_height,
                        plan.panel.native_width,
                        plan.panel.native_height,
                    );
                let facing = projected.map_or(0.0, |value| value.facing_ratio);
                let transmission = cover.transmission(facing);
                let pupil = core::f32::consts::PI * 0.25 / (camera.f_stop * camera.f_stop);
                let weighted_native = LinearRgb::new(
                    mean_native.r
                        * evaluator.angular_channel(facing, 0)
                        * camera.lens.transmission_rgb[0]
                        * transmission.r
                        * pupil
                        * coverage,
                    mean_native.g
                        * evaluator.angular_channel(facing, 1)
                        * camera.lens.transmission_rgb[1]
                        * transmission.g
                        * pupil
                        * coverage,
                    mean_native.b
                        * evaluator.angular_channel(facing, 2)
                        * camera.lens.transmission_rgb[2]
                        * transmission.b
                        * pupil
                        * coverage,
                );
                let converted = evaluator.native_to_acescg(weighted_native);
                LinearRgb::new(
                    converted.r / parameters.white_level_nits,
                    converted.g / parameters.white_level_nits,
                    converted.b / parameters.white_level_nits,
                )
            }
        };
    let source_raster = [source_width, source_height];
    let device_raster = [plan.panel.native_width, plan.panel.native_height];
    let side = match sampling.samples_per_output_pixel {
        1 => 1,
        4 => 2,
        16 => 4,
        _ => return Err(ApplicationError::InvalidCharacterStrength),
    };
    let physical_aperture_samples = physical_pipeline_aperture_sample_count(plan.quality);
    let output_count = u64::from(sampling.effective_width)
        .checked_mul(u64::from(sampling.effective_height))
        .and_then(|value| usize::try_from(value).ok())
        .ok_or(ApplicationError::DecodedPixelStorageTooLarge)?;
    let mut output = Vec::with_capacity(output_count);
    for y in 0..sampling.effective_height {
        for x in 0..sampling.effective_width {
            let mut physical_native = LinearRgb::new(0.0, 0.0, 0.0);
            let mut spread_native = LinearRgb::new(0.0, 0.0, 0.0);
            let mut glow_native = LinearRgb::new(0.0, 0.0, 0.0);
            let mut continuous_native = LinearRgb::new(0.0, 0.0, 0.0);
            let mut carrier_detail_native = LinearRgb::new(0.0, 0.0, 0.0);
            let mut average_device_code = DeviceRgb::BLACK;
            let mut ideal = [0.0_f32; 4];
            // The cover is evaluated after aperture integration. Preserve the
            // traced green-ray direction/cosine and per-channel lens
            // irradiance instead of substituting a front-facing sample.
            let mut cover_cosine = 0.0_f32;
            let mut cover_direction = [0.0_f32; 3];
            let mut cover_irradiance = [0.0_f32; 3];
            let mut cover_weight = 0.0_f32;
            let mut aperture_weight = 0.0_f32;
            let psf_samples_per_area = if plan.lens_amount == 0.0 {
                1
            } else {
                16 / (side * side)
            };
            for sy in 0..side {
                for sx in 0..side {
                    let base_minimum_uv = Vec2 {
                        x: (x as f32 + sx as f32 / side as f32) / sampling.effective_width as f32,
                        y: (y as f32 + sy as f32 / side as f32) / sampling.effective_height as f32,
                    };
                    let base_maximum_uv = Vec2 {
                        x: (x as f32 + (sx + 1) as f32 / side as f32)
                            / sampling.effective_width as f32,
                        y: (y as f32 + (sy + 1) as f32 / side as f32)
                            / sampling.effective_height as f32,
                    };
                    let base_center = Vec2 {
                        x: (base_minimum_uv.x + base_maximum_uv.x) * 0.5,
                        y: (base_minimum_uv.y + base_maximum_uv.y) * 0.5,
                    };
                    let base_viewport_ndc = Vec2 {
                        x: base_center.x * 2.0 - 1.0,
                        y: base_center.y * 2.0 - 1.0,
                    };
                    let field = (base_viewport_ndc.x * base_viewport_ndc.x
                        + base_viewport_ndc.y * base_viewport_ndc.y)
                        .mul_add(0.5, 0.0)
                        .clamp(0.0, 1.0);
                    let softness_micrometers = resolved_scene.0.lens.center_softness_micrometers
                        + (resolved_scene.0.lens.edge_softness_micrometers
                            - resolved_scene.0.lens.center_softness_micrometers)
                            * field;
                    let sensor_pitch_millimeters =
                        resolved_scene.0.sensor_width.0 / sampling.effective_width as f32;
                    let airy_radius_millimeters = 1.22 * 0.000_550 * resolved_scene.0.f_stop;
                    let psf_radius_millimeters = match plan.lens_evaluation_model {
                        LensEvaluationModel::ThinLens => {
                            softness_micrometers * 0.001 + airy_radius_millimeters
                        }
                        LensEvaluationModel::VfxDepthBlur => {
                            variance_matched_lens_psf_radius_millimeters(
                                softness_micrometers,
                                resolved_scene.0.f_stop,
                            )
                        }
                    };
                    let psf_pixels =
                        (psf_radius_millimeters / sensor_pitch_millimeters) * plan.lens_amount;
                    for psf_sample in 0..psf_samples_per_area {
                        let sample_index = (sy * side + sx) * psf_samples_per_area + psf_sample;
                        let disk = physical_psf_disk_sample(sample_index as usize);
                        let psf_offset = Vec2 {
                            x: disk.x * psf_pixels / sampling.effective_width as f32,
                            y: disk.y * psf_pixels / sampling.effective_height as f32,
                        };
                        let minimum_uv = Vec2 {
                            x: base_minimum_uv.x + psf_offset.x,
                            y: base_minimum_uv.y + psf_offset.y,
                        };
                        let maximum_uv = Vec2 {
                            x: base_maximum_uv.x + psf_offset.x,
                            y: base_maximum_uv.y + psf_offset.y,
                        };
                        let flat_center = Vec2 {
                            x: base_center.x + psf_offset.x,
                            y: base_center.y + psf_offset.y,
                        };
                        let viewport_ndc = Vec2 {
                            x: flat_center.x * 2.0 - 1.0,
                            y: flat_center.y * 2.0 - 1.0,
                        };
                        debug_assert_eq!(physical_aperture_samples, 32);
                        let optical_samples = (plan.lens_evaluation_model
                            == LensEvaluationModel::ThinLens)
                            .then(|| {
                                panel_uv_aperture_samples_with_count::<32>(
                                    resolved_scene.0,
                                    resolved_scene.1,
                                    plan.panel.active_width,
                                    plan.panel.active_height,
                                    viewport_ndc,
                                    0.0,
                                )
                            });
                        let continuous_footprint = (plan.lens_evaluation_model
                            == LensEvaluationModel::VfxDepthBlur)
                            .then(|| {
                                panel_uv_continuous_pupil_footprint(
                                    resolved_scene.0,
                                    resolved_scene.1,
                                    plan.panel.active_width,
                                    plan.panel.active_height,
                                    viewport_ndc,
                                    Vec2 {
                                        x: maximum_uv.x - minimum_uv.x,
                                        y: maximum_uv.y - minimum_uv.y,
                                    },
                                )
                            });
                        let aperture_count = if optical_samples.is_some() { 32 } else { 1 };
                        for aperture_index in 0..aperture_count {
                            let (optical, aperture_cell_half_extent, sensor_panel_half_extent) =
                                if let Some(samples) = optical_samples.as_ref() {
                                    (
                                        samples[aperture_index],
                                        [Vec2 { x: 0.0, y: 0.0 }; 3],
                                        [Vec2 {
                                            x: (maximum_uv.x - minimum_uv.x) * 0.5,
                                            y: (maximum_uv.y - minimum_uv.y) * 0.5,
                                        }; 3],
                                    )
                                } else {
                                    let footprint = continuous_footprint
                                        .expect("the resolved VFX lens footprint exists");
                                    (
                                        footprint.optical,
                                        footprint.panel_half_extent.map(|extent| Vec2 {
                                            x: extent.x * plan.scene_geometry_amount,
                                            y: extent.y * plan.scene_geometry_amount,
                                        }),
                                        footprint.sensor_panel_half_extent,
                                    )
                                };
                            let layer_weight = 1.0;
                            aperture_weight += layer_weight;
                            if let Some(direction) = optical.reflection_direction_local[1] {
                                cover_cosine += optical.emission_cosine[1] * layer_weight;
                                cover_direction[0] += direction.x * layer_weight;
                                cover_direction[1] += direction.y * layer_weight;
                                cover_direction[2] += direction.z * layer_weight;
                                cover_irradiance[0] += optical.irradiance_weight[0] * layer_weight;
                                cover_irradiance[1] += optical.irradiance_weight[1] * layer_weight;
                                cover_irradiance[2] += optical.irradiance_weight[2] * layer_weight;
                                cover_weight += layer_weight;
                            }
                            let mapped_bounds = |channel: usize| {
                                if plan.scene_geometry_amount == 0.0 && plan.lens_amount == 0.0 {
                                    return (minimum_uv, maximum_uv, minimum_uv, maximum_uv, 1.0);
                                }
                                let hit = optical.panel_uv[channel];
                                let target = hit.unwrap_or(Vec2 { x: -2.0, y: -2.0 });
                                let center = Vec2 {
                                    x: flat_center.x
                                        + plan.scene_geometry_amount * (target.x - flat_center.x),
                                    y: flat_center.y
                                        + plan.scene_geometry_amount * (target.y - flat_center.y),
                                };
                                let angular = if hit.is_some() {
                                    evaluator
                                        .angular_channel(optical.emission_cosine[channel], channel)
                                        * optical.irradiance_weight[channel]
                                } else {
                                    0.0
                                };
                                let flat_sensor_half_extent = Vec2 {
                                    x: (maximum_uv.x - minimum_uv.x) * 0.5,
                                    y: (maximum_uv.y - minimum_uv.y) * 0.5,
                                };
                                let projected_sensor_half_extent =
                                    sensor_panel_half_extent[channel];
                                let sensor_half_extent = Vec2 {
                                    x: flat_sensor_half_extent.x
                                        + plan.scene_geometry_amount
                                            * (projected_sensor_half_extent.x
                                                - flat_sensor_half_extent.x),
                                    y: flat_sensor_half_extent.y
                                        + plan.scene_geometry_amount
                                            * (projected_sensor_half_extent.y
                                                - flat_sensor_half_extent.y),
                                };
                                let reconstructed_half_extent = vfx_rectangular_support_half_extent(
                                    sensor_half_extent,
                                    aperture_cell_half_extent[channel],
                                );
                                let carrier_half_extent = vfx_carrier_half_extent(
                                    sensor_half_extent,
                                    aperture_cell_half_extent[channel],
                                );
                                (
                                    Vec2 {
                                        x: center.x - reconstructed_half_extent.x,
                                        y: center.y - reconstructed_half_extent.y,
                                    },
                                    Vec2 {
                                        x: center.x + reconstructed_half_extent.x,
                                        y: center.y + reconstructed_half_extent.y,
                                    },
                                    Vec2 {
                                        x: center.x - carrier_half_extent.x,
                                        y: center.y - carrier_half_extent.y,
                                    },
                                    Vec2 {
                                        x: center.x + carrier_half_extent.x,
                                        y: center.y + carrier_half_extent.y,
                                    },
                                    1.0 + plan.scene_geometry_amount * (angular - 1.0),
                                )
                            };
                            for channel in 0..3 {
                                let (
                                    channel_minimum,
                                    channel_maximum,
                                    carrier_minimum,
                                    carrier_maximum,
                                    optical_weight,
                                ) = mapped_bounds(channel);
                                let optical_weight = optical_weight * layer_weight;
                                let area = sample_placed_area(
                                    &prepared.integral,
                                    &emission_integral,
                                    source_raster,
                                    device_raster,
                                    plan.placement,
                                    channel_minimum,
                                    channel_maximum,
                                );
                                let device_minimum = Vec2 {
                                    x: channel_minimum.x * plan.panel.native_width as f32,
                                    y: channel_minimum.y * plan.panel.native_height as f32,
                                };
                                let device_maximum = Vec2 {
                                    x: channel_maximum.x * plan.panel.native_width as f32,
                                    y: channel_maximum.y * plan.panel.native_height as f32,
                                };
                                let base = evaluator.native_channel_over_device_rect(
                                    area.device_code,
                                    device_minimum,
                                    device_maximum,
                                    channel,
                                );
                                let carrier_area = sample_placed_area(
                                    &prepared.integral,
                                    &emission_integral,
                                    source_raster,
                                    device_raster,
                                    plan.placement,
                                    carrier_minimum,
                                    carrier_maximum,
                                );
                                let carrier = evaluator.native_channel_over_device_rect(
                                    carrier_area.device_code,
                                    Vec2 {
                                        x: carrier_minimum.x * plan.panel.native_width as f32,
                                        y: carrier_minimum.y * plan.panel.native_height as f32,
                                    },
                                    Vec2 {
                                        x: carrier_maximum.x * plan.panel.native_width as f32,
                                        y: carrier_maximum.y * plan.panel.native_height as f32,
                                    },
                                    channel,
                                );
                                let carrier_detail = (carrier - base) * optical_weight;
                                let spread_at = |cover_offset_meters: [f32; 2]| {
                                    plan.panel_light_spread
                                        .samples_for_channel(channel)
                                        .into_iter()
                                        .map(|sample| {
                                            let offset = Vec2 {
                                                x: (sample.offset_meters.x
                                                    + cover_offset_meters[0])
                                                    / plan.panel.active_width.0,
                                                y: (sample.offset_meters.y
                                                    + cover_offset_meters[1])
                                                    / plan.panel.active_height.0,
                                            };
                                            let shifted_minimum = Vec2 {
                                                x: channel_minimum.x + offset.x,
                                                y: channel_minimum.y + offset.y,
                                            };
                                            let shifted_maximum = Vec2 {
                                                x: channel_maximum.x + offset.x,
                                                y: channel_maximum.y + offset.y,
                                            };
                                            let shifted = sample_placed_area(
                                                &prepared.integral,
                                                &emission_integral,
                                                source_raster,
                                                device_raster,
                                                plan.placement,
                                                shifted_minimum,
                                                shifted_maximum,
                                            );
                                            evaluator.native_channel_over_device_rect(
                                                shifted.device_code,
                                                Vec2 {
                                                    x: shifted_minimum.x
                                                        * plan.panel.native_width as f32,
                                                    y: shifted_minimum.y
                                                        * plan.panel.native_height as f32,
                                                },
                                                Vec2 {
                                                    x: shifted_maximum.x
                                                        * plan.panel.native_width as f32,
                                                    y: shifted_maximum.y
                                                        * plan.panel.native_height as f32,
                                                },
                                                channel,
                                            ) * sample.weight
                                        })
                                        .sum::<f32>()
                                };
                                let native_over_bounds = |minimum: Vec2, maximum: Vec2| {
                                    let sampled = sample_placed_area(
                                        &prepared.integral,
                                        &emission_integral,
                                        source_raster,
                                        device_raster,
                                        plan.placement,
                                        minimum,
                                        maximum,
                                    );
                                    evaluator.native_channel_over_device_rect(
                                        sampled.device_code,
                                        Vec2 {
                                            x: minimum.x * plan.panel.native_width as f32,
                                            y: minimum.y * plan.panel.native_height as f32,
                                        },
                                        Vec2 {
                                            x: maximum.x * plan.panel.native_width as f32,
                                            y: maximum.y * plan.panel.native_height as f32,
                                        },
                                        channel,
                                    )
                                };
                                let value = if plan.panel_light_spread.character_strength == 0.0 {
                                    base * optical_weight
                                } else {
                                    spread_at([0.0, 0.0]) * optical_weight
                                };
                                let glow_value = if plan.cover.glow.character_strength == 0.0 {
                                    value
                                } else {
                                    let glow = plan.cover.glow;
                                    let scattered = glow.scatter_fraction * glow.character_strength;
                                    let extent = |radius_millimeters: f32| Vec2 {
                                        x: radius_millimeters * (0.001 / 3.0)
                                            / plan.panel.active_width.0,
                                        y: radius_millimeters * (0.001 / 3.0)
                                            / plan.panel.active_height.0,
                                    };
                                    let core = extent(glow.core_radius_millimeters);
                                    let tail = extent(glow.tail_radius_millimeters);
                                    let core_blur = native_over_bounds(
                                        Vec2 {
                                            x: channel_minimum.x - core.x,
                                            y: channel_minimum.y - core.y,
                                        },
                                        Vec2 {
                                            x: channel_maximum.x + core.x,
                                            y: channel_maximum.y + core.y,
                                        },
                                    );
                                    let tail_blur = native_over_bounds(
                                        Vec2 {
                                            x: channel_minimum.x - tail.x,
                                            y: channel_minimum.y - tail.y,
                                        },
                                        Vec2 {
                                            x: channel_maximum.x + tail.x,
                                            y: channel_maximum.y + tail.y,
                                        },
                                    );
                                    value * (1.0 - scattered)
                                        + core_blur
                                            * scattered
                                            * (1.0 - glow.tail_fraction)
                                            * optical_weight
                                        + tail_blur
                                            * scattered
                                            * glow.tail_fraction
                                            * optical_weight
                                };
                                let base = base * optical_weight;
                                match channel {
                                    0 => {
                                        physical_native.r += base;
                                        spread_native.r += value;
                                        glow_native.r += glow_value;
                                        continuous_native.r +=
                                            area.linear_native_emission.r * optical_weight;
                                        average_device_code.r += area.device_code.r * layer_weight;
                                        carrier_detail_native.r += carrier_detail;
                                    }
                                    1 => {
                                        physical_native.g += base;
                                        spread_native.g += value;
                                        glow_native.g += glow_value;
                                        continuous_native.g +=
                                            area.linear_native_emission.g * optical_weight;
                                        average_device_code.g += area.device_code.g * layer_weight;
                                        carrier_detail_native.g += carrier_detail;
                                    }
                                    _ => {
                                        physical_native.b += base;
                                        spread_native.b += value;
                                        glow_native.b += glow_value;
                                        continuous_native.b +=
                                            area.linear_native_emission.b * optical_weight;
                                        average_device_code.b += area.device_code.b * layer_weight;
                                        carrier_detail_native.b += carrier_detail;
                                    }
                                }
                            }
                            let (ideal_minimum, ideal_maximum, _, _, _) = mapped_bounds(1);
                            let value = sample_placed_acescg_area(
                                source_width,
                                source_height,
                                &source_acescg,
                                device_raster,
                                plan.placement,
                                ideal_minimum,
                                ideal_maximum,
                            );
                            for channel in 0..4 {
                                ideal[channel] += value[channel] * layer_weight;
                            }
                        }
                    }
                }
            }
            let reciprocal = 1.0 / aperture_weight;
            physical_native.r *= reciprocal;
            physical_native.g *= reciprocal;
            physical_native.b *= reciprocal;
            spread_native.r *= reciprocal;
            spread_native.g *= reciprocal;
            spread_native.b *= reciprocal;
            glow_native.r *= reciprocal;
            glow_native.g *= reciprocal;
            glow_native.b *= reciprocal;
            continuous_native.r *= reciprocal;
            continuous_native.g *= reciprocal;
            continuous_native.b *= reciprocal;
            carrier_detail_native.r *= reciprocal;
            carrier_detail_native.g *= reciprocal;
            carrier_detail_native.b *= reciprocal;
            average_device_code.r *= reciprocal;
            average_device_code.g *= reciprocal;
            average_device_code.b *= reciprocal;
            for value in &mut ideal {
                *value *= reciprocal;
            }
            let matrix = parameters.native_to_acescg;
            let physical = [
                (matrix[0][0] * physical_native.r
                    + matrix[0][1] * physical_native.g
                    + matrix[0][2] * physical_native.b)
                    / parameters.white_level_nits,
                (matrix[1][0] * physical_native.r
                    + matrix[1][1] * physical_native.g
                    + matrix[1][2] * physical_native.b)
                    / parameters.white_level_nits,
                (matrix[2][0] * physical_native.r
                    + matrix[2][1] * physical_native.g
                    + matrix[2][2] * physical_native.b)
                    / parameters.white_level_nits,
            ];
            let continuous = [
                (matrix[0][0] * continuous_native.r
                    + matrix[0][1] * continuous_native.g
                    + matrix[0][2] * continuous_native.b)
                    / parameters.white_level_nits,
                (matrix[1][0] * continuous_native.r
                    + matrix[1][1] * continuous_native.g
                    + matrix[1][2] * continuous_native.b)
                    / parameters.white_level_nits,
                (matrix[2][0] * continuous_native.r
                    + matrix[2][1] * continuous_native.g
                    + matrix[2][2] * continuous_native.b)
                    / parameters.white_level_nits,
            ];
            let spread = [
                (matrix[0][0] * spread_native.r
                    + matrix[0][1] * spread_native.g
                    + matrix[0][2] * spread_native.b)
                    / parameters.white_level_nits,
                (matrix[1][0] * spread_native.r
                    + matrix[1][1] * spread_native.g
                    + matrix[1][2] * spread_native.b)
                    / parameters.white_level_nits,
                (matrix[2][0] * spread_native.r
                    + matrix[2][1] * spread_native.g
                    + matrix[2][2] * spread_native.b)
                    / parameters.white_level_nits,
            ];
            let glowed = [
                (matrix[0][0] * glow_native.r
                    + matrix[0][1] * glow_native.g
                    + matrix[0][2] * glow_native.b)
                    / parameters.white_level_nits,
                (matrix[1][0] * glow_native.r
                    + matrix[1][1] * glow_native.g
                    + matrix[1][2] * glow_native.b)
                    / parameters.white_level_nits,
                (matrix[2][0] * glow_native.r
                    + matrix[2][1] * glow_native.g
                    + matrix[2][2] * glow_native.b)
                    / parameters.white_level_nits,
            ];
            let carrier_detail = [
                (matrix[0][0] * carrier_detail_native.r
                    + matrix[0][1] * carrier_detail_native.g
                    + matrix[0][2] * carrier_detail_native.b)
                    / parameters.white_level_nits,
                (matrix[1][0] * carrier_detail_native.r
                    + matrix[1][1] * carrier_detail_native.g
                    + matrix[1][2] * carrier_detail_native.b)
                    / parameters.white_level_nits,
                (matrix[2][0] * carrier_detail_native.r
                    + matrix[2][1] * carrier_detail_native.g
                    + matrix[2][2] * carrier_detail_native.b)
                    / parameters.white_level_nits,
            ];
            let glowed = if plan.lens_evaluation_model == LensEvaluationModel::VfxDepthBlur {
                [
                    glowed[0] + plan.subpixel_geometry_amount * carrier_detail[0],
                    glowed[1] + plan.subpixel_geometry_amount * carrier_detail[1],
                    glowed[2] + plan.subpixel_geometry_amount * carrier_detail[2],
                ]
            } else {
                glowed
            };
            let staged = [
                ideal[0]
                    + plan.emission_amount * (continuous[0] - ideal[0])
                    + plan.subpixel_geometry_amount * (physical[0] - continuous[0])
                    + (spread[0] - physical[0]),
                ideal[1]
                    + plan.emission_amount * (continuous[1] - ideal[1])
                    + plan.subpixel_geometry_amount * (physical[1] - continuous[1])
                    + (spread[1] - physical[1]),
                ideal[2]
                    + plan.emission_amount * (continuous[2] - ideal[2])
                    + plan.subpixel_geometry_amount * (physical[2] - continuous[2])
                    + (spread[2] - physical[2]),
            ];
            let staged = [
                staged[0] + glowed[0] - spread[0],
                staged[1] + glowed[1] - spread[1],
                staged[2] + glowed[2] - spread[2],
            ];
            let resolved_temporal_gain =
                physical_row_temporal_gain(plan, y as usize, sampling.effective_height as usize)?;
            let temporal_gain =
                1.0 + plan.temporal_emission_amount * (resolved_temporal_gain - 1.0);
            let temporally_integrated = staged.map(|value| value * temporal_gain);
            let reciprocal_cover = if cover_weight == 0.0 {
                1.0
            } else {
                1.0 / cover_weight
            };
            let direction_length = (cover_direction[0] * cover_direction[0]
                + cover_direction[1] * cover_direction[1]
                + cover_direction[2] * cover_direction[2])
                .sqrt();
            let reflection_direction_local = if direction_length > 1.0e-6 {
                [
                    cover_direction[0] / direction_length,
                    cover_direction[1] / direction_length,
                    cover_direction[2] / direction_length,
                ]
            } else {
                [0.0, 0.0, 1.0]
            };
            let emitted = LinearRgb::new(
                temporally_integrated[0],
                temporally_integrated[1],
                temporally_integrated[2],
            );
            let cover_sample = CoverSurfaceSample {
                view_cosine: (cover_cosine * reciprocal_cover).clamp(0.0, 1.0),
                reflection_direction_local,
                lens_irradiance_weight: LinearRgb::new(
                    cover_irradiance[0] * reciprocal_cover / parameters.white_level_nits,
                    cover_irradiance[1] * reciprocal_cover / parameters.white_level_nits,
                    cover_irradiance[2] * reciprocal_cover / parameters.white_level_nits,
                ),
            };
            let covered = match plan.environment {
                IncidentEnvironment::Procedural(_) => cover.evaluate(emitted, cover_sample),
                IncidentEnvironment::Equirectangular(environment) => {
                    let raster = request
                        .input
                        .environment_acescg
                        .as_ref()
                        .expect("validated image-backed environment owns its raster");
                    let sampled = raster.sample_equirectangular(
                        reflection_direction_local,
                        environment.rotation_degrees,
                        plan.cover.roughness,
                        plan.cover.haze,
                    );
                    let scale = environment.radiance_scale();
                    cover.evaluate_with_incident_radiance(
                        emitted,
                        AcesCgRadiance(LinearRgb::new(
                            sampled.r * scale,
                            sampled.g * scale,
                            sampled.b * scale,
                        )),
                        cover_sample,
                    )
                }
            };
            let glare_fraction = resolved_scene.0.lens.veiling_glare_fraction;
            let temporal_gate_average = LinearRgb::new(
                veiling_glare_gate_average.r * temporal_gain,
                veiling_glare_gate_average.g * temporal_gain,
                veiling_glare_gate_average.b * temporal_gain,
            );
            let glared = LinearRgb::new(
                covered.r + glare_fraction * (temporal_gate_average.r - covered.r),
                covered.g + glare_fraction * (temporal_gate_average.g - covered.g),
                covered.b + glare_fraction * (temporal_gate_average.b - covered.b),
            );
            let exposure_duration = plan
                .shutter_close
                .checked_sub(plan.shutter_open)
                .map_err(ApplicationError::Time)?;
            let shutter_scale = (exposure_duration.as_seconds() as f32
                * 2.0_f32.powf(-plan.shutter_motion.neutral_density_stops))
            .powf(plan.shutter_motion_amount);
            let shuttered = LinearRgb::new(
                glared.r * shutter_scale,
                glared.g * shutter_scale,
                glared.b * shutter_scale,
            );
            let selected = match plan.requested_intermediate {
                PhysicalIntermediate::SourceAcesCg => ideal[0..3].try_into().expect("RGB"),
                PhysicalIntermediate::DeviceSignal => [
                    average_device_code.r,
                    average_device_code.g,
                    average_device_code.b,
                ],
                PhysicalIntermediate::PanelEmission => continuous,
                PhysicalIntermediate::SubpixelRadiance => physical,
                PhysicalIntermediate::PanelLightSpread => spread,
                PhysicalIntermediate::RelativeGeometry => temporally_integrated,
                PhysicalIntermediate::CoverEnvironment => [covered.r, covered.g, covered.b],
                PhysicalIntermediate::CoverGlow => [covered.r, covered.g, covered.b],
                PhysicalIntermediate::LensProjection => [glared.r, glared.g, glared.b],
                PhysicalIntermediate::ShutterMotion
                | PhysicalIntermediate::ComputationalCapture => {
                    [shuttered.r, shuttered.g, shuttered.b]
                }
                PhysicalIntermediate::SensorBloom
                | PhysicalIntermediate::SensorNoise
                | PhysicalIntermediate::RawMosaic
                | PhysicalIntermediate::DevelopedAcesCg => [
                    ideal[0] + plan.screen_amount * (shuttered.r - ideal[0]),
                    ideal[1] + plan.screen_amount * (shuttered.g - ideal[1]),
                    ideal[2] + plan.screen_amount * (shuttered.b - ideal[2]),
                ],
            };
            output.push([selected[0], selected[1], selected[2], ideal[3]]);
        }
    }
    // Capture owns only the sensor/noise, RAW, and developed intermediates.
    // Earlier diagnostics must publish the selected screen/camera-domain raster
    // directly instead of being silently reinterpreted as sensor illuminance.
    if plan.sensor_enabled
        && matches!(
            plan.requested_intermediate,
            PhysicalIntermediate::SensorBloom
                | PhysicalIntermediate::SensorNoise
                | PhysicalIntermediate::RawMosaic
                | PhysicalIntermediate::DevelopedAcesCg
        )
    {
        let sensor = plan.sensor;
        let raw = expose_physical_pipeline_raw(
            &output,
            sampling.effective_width,
            sampling.effective_height,
            plan,
        )?;
        if matches!(
            plan.requested_intermediate,
            PhysicalIntermediate::SensorBloom
                | PhysicalIntermediate::SensorNoise
                | PhysicalIntermediate::RawMosaic
        ) {
            let maximum_code = ((1_u32 << raw.adc_bits) - 1) as f32;
            return Ok(PhysicalPipelineCpuResult {
                width: raw.width,
                height: raw.height,
                acescg: raw
                    .codes
                    .iter()
                    .zip(&raw.full_well_clipped)
                    .zip(&raw.adc_clipped)
                    .map(|((&code, &well), &adc)| {
                        [
                            code as f32 / maximum_code,
                            f32::from(well),
                            f32::from(adc),
                            1.0,
                        ]
                    })
                    .collect(),
                diagnostic: PhysicalPipelineDiagnostic { geometry, sampling },
            });
        }
        if !plan.development_enabled {
            return Err(ApplicationError::UnsupportedPhysicalIntermediate);
        }
        let developed = develop_raw_to_acescg(&raw, sensor, plan.development)
            .map_err(ApplicationError::CameraDevelopment)?;
        return Ok(PhysicalPipelineCpuResult {
            width: developed.width,
            height: developed.height,
            acescg: developed
                .acescg
                .into_iter()
                .map(|pixel| [pixel.r, pixel.g, pixel.b, 1.0])
                .collect(),
            diagnostic: PhysicalPipelineDiagnostic { geometry, sampling },
        });
    }
    Ok(PhysicalPipelineCpuResult {
        width: sampling.effective_width,
        height: sampling.effective_height,
        acescg: output,
        diagnostic: PhysicalPipelineDiagnostic { geometry, sampling },
    })
}

/// Reuses the historical exact rolling-row timing and analytic panel temporal
/// integral. Residual flicker remains frame-uniform unless explicit analytic
/// banding is enabled, matching the prior capture scheduler.
pub fn physical_row_temporal_gain(
    plan: PhysicalPipelineExecutionPlan,
    row: usize,
    height: usize,
) -> Result<f32, ApplicationError> {
    if matches!(plan.shutter_motion.readout, SensorReadout::Global)
        || plan.panel.temporal_emission.analytic_banding.amount == 0.0
    {
        return Ok(plan.temporal_emission_gain);
    }
    let center = match plan.shutter_motion.readout {
        SensorReadout::Rolling {
            duration,
            direction,
        } => rolling_row_center_time(plan.frame_time, duration, row, height, direction)?,
        SensorReadout::Global => unreachable!("global shutter returned above"),
    };
    let exposure_duration = plan
        .shutter_close
        .checked_sub(plan.shutter_open)
        .map_err(ApplicationError::Time)?;
    let half = exposure_duration
        .checked_mul_ratio(1, 2)
        .map_err(ApplicationError::Time)?;
    let start = center.checked_sub(half).map_err(ApplicationError::Time)?;
    let end = center.checked_add(half).map_err(ApplicationError::Time)?;
    plan.panel
        .temporal_emission
        .average_gain(start, end)
        .map_err(ApplicationError::Panel)
}

/// One exact quadrature interval scheduled by Rust for a global frame or one
/// rolling-shutter row. `row` is `None` for global shutter and otherwise names
/// the only output row to which the sample applies.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalShutterSample {
    pub row: Option<usize>,
    pub start: RationalTime,
    pub time: RationalTime,
    pub end: RationalTime,
    pub weight_seconds: f64,
}

/// Reuses the historical shutter quadrature and rolling-row center semantics.
/// The caller supplies exact open/close bounds; no frame rate or velocity is
/// inferred. Motion sample count is bounded by the historical `[1, 64]` range.
pub fn physical_shutter_schedule(
    shutter_open: RationalTime,
    shutter_close: RationalTime,
    temporal_samples: u16,
    readout: SensorReadout,
    output_height: usize,
) -> Result<Vec<PhysicalShutterSample>, ApplicationError> {
    let duration = shutter_close
        .checked_sub(shutter_open)
        .map_err(ApplicationError::Time)?;
    if duration.numerator() <= 0 || output_height == 0 {
        return Err(ApplicationError::InvalidShutter);
    }
    let center = shutter_open
        .checked_add(
            duration
                .checked_mul_ratio(1, 2)
                .map_err(ApplicationError::Time)?,
        )
        .map_err(ApplicationError::Time)?;
    let append = |row, center, output: &mut Vec<PhysicalShutterSample>| {
        for sample in shutter_quadrature(center, duration, temporal_samples)? {
            output.push(PhysicalShutterSample {
                row,
                start: sample.start,
                time: sample.time,
                end: sample.end,
                weight_seconds: sample.weight_seconds,
            });
        }
        Ok::<(), ApplicationError>(())
    };
    let mut scheduled = Vec::new();
    match readout {
        SensorReadout::Global => append(None, center, &mut scheduled)?,
        SensorReadout::Rolling {
            duration: readout_duration,
            direction,
        } => {
            scheduled.reserve(output_height * usize::from(temporal_samples));
            for row in 0..output_height {
                let row_center = rolling_row_center_time(
                    center,
                    readout_duration,
                    row,
                    output_height,
                    direction,
                )?;
                append(Some(row), row_center, &mut scheduled)?;
            }
        }
    }
    Ok(scheduled)
}

#[derive(Clone, Debug)]
struct DeviceSignalIntegral {
    width: u32,
    height: u32,
    prefix: Vec<IntegralRgb>,
}

#[derive(Clone, Copy, Debug, Default)]
struct IntegralRgb {
    r: f64,
    g: f64,
    b: f64,
}

impl DeviceSignalIntegral {
    fn new(source: &DeviceSignalRaster) -> Self {
        Self::new_mapped(source, |pixel| pixel)
    }

    fn new_mapped(source: &DeviceSignalRaster, map: impl Fn(DeviceRgb) -> DeviceRgb) -> Self {
        let stride = source.width as usize + 1;
        let mut prefix = vec![IntegralRgb::default(); stride * (source.height as usize + 1)];
        for row in 0..source.height as usize {
            let mut row_sum = IntegralRgb::default();
            for column in 0..source.width as usize {
                let pixel = map(source.pixels[row * source.width as usize + column]);
                row_sum.r += f64::from(pixel.r);
                row_sum.g += f64::from(pixel.g);
                row_sum.b += f64::from(pixel.b);
                let above = prefix[row * stride + column + 1];
                prefix[(row + 1) * stride + column + 1] = IntegralRgb {
                    r: above.r + row_sum.r,
                    g: above.g + row_sum.g,
                    b: above.b + row_sum.b,
                };
            }
        }
        Self {
            width: source.width,
            height: source.height,
            prefix,
        }
    }

    fn prefix_at(&self, column: usize, row: usize) -> IntegralRgb {
        self.prefix[row * (self.width as usize + 1) + column]
    }

    fn integer_sum(&self, x0: usize, y0: usize, x1: usize, y1: usize) -> IntegralRgb {
        let a = self.prefix_at(x0, y0);
        let b = self.prefix_at(x1, y0);
        let c = self.prefix_at(x0, y1);
        let d = self.prefix_at(x1, y1);
        IntegralRgb {
            r: d.r - b.r - c.r + a.r,
            g: d.g - b.g - c.g + a.g,
            b: d.b - b.b - c.b + a.b,
        }
    }

    fn integral_to(&self, x: f32, y: f32) -> IntegralRgb {
        let x = x.clamp(0.0, self.width as f32);
        let y = y.clamp(0.0, self.height as f32);
        let integer_x = x.floor() as usize;
        let integer_y = y.floor() as usize;
        let fraction_x = if integer_x < self.width as usize {
            x - integer_x as f32
        } else {
            0.0
        };
        let fraction_y = if integer_y < self.height as usize {
            y - integer_y as f32
        } else {
            0.0
        };
        let mut sum = self.prefix_at(integer_x, integer_y);
        if fraction_x > 0.0 {
            let column = self.integer_sum(integer_x, 0, integer_x + 1, integer_y);
            sum.r += column.r * f64::from(fraction_x);
            sum.g += column.g * f64::from(fraction_x);
            sum.b += column.b * f64::from(fraction_x);
        }
        if fraction_y > 0.0 {
            let row = self.integer_sum(0, integer_y, integer_x, integer_y + 1);
            sum.r += row.r * f64::from(fraction_y);
            sum.g += row.g * f64::from(fraction_y);
            sum.b += row.b * f64::from(fraction_y);
        }
        if fraction_x > 0.0 && fraction_y > 0.0 {
            let pixel = self.integer_sum(integer_x, integer_y, integer_x + 1, integer_y + 1);
            let weight = f64::from(fraction_x) * f64::from(fraction_y);
            sum.r += pixel.r * weight;
            sum.g += pixel.g * weight;
            sum.b += pixel.b * weight;
        }
        sum
    }

    fn sample_area_box(&self, minimum: Vec2, maximum: Vec2) -> DeviceRgb {
        let x0 = minimum.x.min(maximum.x) * self.width as f32;
        let x1 = minimum.x.max(maximum.x) * self.width as f32;
        let y0 = minimum.y.min(maximum.y) * self.height as f32;
        let y1 = minimum.y.max(maximum.y) * self.height as f32;
        let full_area = (x1 - x0).max(1.0e-8) * (y1 - y0).max(1.0e-8);
        let lower = self.integral_to(x0, y0);
        let upper_x = self.integral_to(x1, y0);
        let upper_y = self.integral_to(x0, y1);
        let upper = self.integral_to(x1, y1);
        let sum = IntegralRgb {
            r: upper.r - upper_x.r - upper_y.r + lower.r,
            g: upper.g - upper_x.g - upper_y.g + lower.g,
            b: upper.b - upper_x.b - upper_y.b + lower.b,
        };
        let full_area = f64::from(full_area);
        DeviceRgb::new(
            (sum.r / full_area) as f32,
            (sum.g / full_area) as f32,
            (sum.b / full_area) as f32,
        )
    }
}

#[derive(Clone, Copy, Debug)]
struct AreaSignalSample {
    device_code: DeviceRgb,
    linear_native_emission: LinearRgb,
}

fn linear_emission_integral(
    source: &DeviceSignalRaster,
    evaluator: ValidatedPanelEvaluator,
) -> DeviceSignalIntegral {
    DeviceSignalIntegral::new_mapped(source, |pixel| {
        DeviceRgb::new(
            evaluator.native_channel(pixel, 0),
            evaluator.native_channel(pixel, 1),
            evaluator.native_channel(pixel, 2),
        )
    })
}

pub fn decoded_frame_to_device_signal(
    frame: &DecodedFrame,
    alpha_presence: AlphaPresence,
    alpha_interpretation: AlphaInterpretation,
    color_processor: &SourceToDeviceProcessor,
) -> Result<DeviceSignalRaster, ApplicationError> {
    let expected = frame.raster.pixel_count();
    if frame.pixels.len() as u64 != expected {
        return Err(ApplicationError::DecodedPixelCountMismatch {
            expected,
            actual: frame.pixels.len() as u64,
        });
    }
    if alpha_presence == AlphaPresence::Present && alpha_interpretation == AlphaInterpretation::Auto
    {
        return Err(ApplicationError::AlphaAssociationUnresolved);
    }
    let capacity = usize::try_from(expected)
        .map_err(|_| ApplicationError::DecodedPixelStorageTooLarge)?
        .checked_mul(4)
        .ok_or(ApplicationError::DecodedPixelStorageTooLarge)?;
    let mut transformed = Vec::with_capacity(capacity);
    for pixel in &frame.pixels {
        let [r, g, b, alpha] = match (alpha_presence, alpha_interpretation) {
            (AlphaPresence::Present, AlphaInterpretation::Ignore) => {
                [pixel.r, pixel.g, pixel.b, 1.0]
            }
            (AlphaPresence::Absent, _)
            | (AlphaPresence::Present, AlphaInterpretation::Straight) => {
                [pixel.r, pixel.g, pixel.b, pixel.a]
            }
            (AlphaPresence::Present, AlphaInterpretation::Premultiplied) if pixel.a == 0.0 => {
                [0.0, 0.0, 0.0, 0.0]
            }
            (AlphaPresence::Present, AlphaInterpretation::Premultiplied) => [
                pixel.r / pixel.a,
                pixel.g / pixel.a,
                pixel.b / pixel.a,
                pixel.a,
            ],
            (AlphaPresence::Present, AlphaInterpretation::Auto) => {
                unreachable!("unresolved alpha was rejected before color processing")
            }
        };
        transformed.extend_from_slice(&[r, g, b, alpha]);
    }
    color_processor
        .apply_rgba_buffer(&mut transformed)
        .map_err(ApplicationError::Color)?;
    let pixels = transformed
        .chunks_exact(4)
        .map(|pixel| {
            let association = if alpha_presence == AlphaPresence::Present {
                pixel[3]
            } else {
                1.0
            };
            DeviceRgb::new(
                pixel[0] * association,
                pixel[1] * association,
                pixel[2] * association,
            )
        })
        .collect();
    Ok(DeviceSignalRaster {
        width: frame.raster.width,
        height: frame.raster.height,
        pixels,
    })
}

/// Maps a device-native sample position to source UV. `None` is authored empty area,
/// not a substitute sample or decoder fallback.
pub fn source_uv_for_device_uv(
    source_raster: [u32; 2],
    device_raster: [u32; 2],
    placement: RasterPlacement,
    device_uv: Vec2,
) -> Option<Vec2> {
    if source_raster.contains(&0) || device_raster.contains(&0) {
        return None;
    }
    let source_uv = source_uv_unbounded(source_raster, device_raster, placement, device_uv)?;
    ((0.0..=1.0).contains(&source_uv.x) && (0.0..=1.0).contains(&source_uv.y)).then_some(source_uv)
}

fn source_uv_unbounded(
    source_raster: [u32; 2],
    device_raster: [u32; 2],
    placement: RasterPlacement,
    device_uv: Vec2,
) -> Option<Vec2> {
    if source_raster.contains(&0) || device_raster.contains(&0) {
        return None;
    }
    let source_aspect = source_raster[0] as f32 / source_raster[1] as f32;
    let device_aspect = device_raster[0] as f32 / device_raster[1] as f32;
    let centered = |scale_x: f32, scale_y: f32| Vec2 {
        x: (device_uv.x - 0.5) * scale_x + 0.5,
        y: (device_uv.y - 0.5) * scale_y + 0.5,
    };
    Some(match placement {
        RasterPlacement::Stretch => device_uv,
        RasterPlacement::Fit if source_aspect > device_aspect => {
            centered(1.0, source_aspect / device_aspect)
        }
        RasterPlacement::Fit => centered(device_aspect / source_aspect, 1.0),
        RasterPlacement::FillCrop if source_aspect > device_aspect => {
            centered(device_aspect / source_aspect, 1.0)
        }
        RasterPlacement::FillCrop => centered(1.0, source_aspect / device_aspect),
        RasterPlacement::OneToOne => centered(
            device_raster[0] as f32 / source_raster[0] as f32,
            device_raster[1] as f32 / source_raster[1] as f32,
        ),
    })
}

fn sample_placed_area(
    source_code: &DeviceSignalIntegral,
    source_emission: &DeviceSignalIntegral,
    source_raster: [u32; 2],
    device_raster: [u32; 2],
    placement: RasterPlacement,
    minimum: Vec2,
    maximum: Vec2,
) -> AreaSignalSample {
    let Some(first) = source_uv_unbounded(source_raster, device_raster, placement, minimum) else {
        return AreaSignalSample {
            device_code: DeviceRgb::BLACK,
            linear_native_emission: LinearRgb::new(0.0, 0.0, 0.0),
        };
    };
    let Some(second) = source_uv_unbounded(source_raster, device_raster, placement, maximum) else {
        return AreaSignalSample {
            device_code: DeviceRgb::BLACK,
            linear_native_emission: LinearRgb::new(0.0, 0.0, 0.0),
        };
    };
    let device_code = source_code.sample_area_box(first, second);
    let emission = source_emission.sample_area_box(first, second);
    AreaSignalSample {
        device_code,
        linear_native_emission: LinearRgb::new(emission.r, emission.g, emission.b),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnosticView {
    Composite,
    DeviceSignal,
    Subpixels,
    EmittedRadiance,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProceduralTestPattern {
    AnimatedCheckerboard,
    EyeChart,
    PhotometricDeviceScale,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PanelTemporalEvaluation {
    /// Technical preview at one exact project time.
    Instantaneous,
    /// Shutter-integrated panel-emission gain. Optics still evaluate through the same path.
    ExposureAverage(f32),
}

pub const PHOTOMETRIC_DEVICE_CODES: [f32; 9] = [0.0, 0.05, 0.10, 0.18, 0.25, 0.50, 0.75, 0.90, 1.0];

#[derive(Clone, Debug, PartialEq)]
pub struct OpticalRequest {
    pub time: RationalTime,
    pub panel_temporal_evaluation: PanelTemporalEvaluation,
    /// Continuous-display identity to authored physical-panel interpolation. Values above one
    /// intentionally extrapolate panel structure for diagnosis and creative use.
    pub panel_character_strength: f32,
    /// Ideal-lens identity to the authored lens, including the complete PSF. Values above one
    /// intentionally extrapolate lens character for diagnosis and creative use.
    pub lens_character_strength: f32,
    pub viewport_aspect: f32,
    pub panel: LcdProfile,
    pub cover: CoverGlassProfile,
    pub environment: ProceduralEnvironment,
    pub camera: CameraRig,
    pub screen: ScreenTrack,
    pub inspection: Option<PanelRegion>,
    pub procedural_pattern: ProceduralTestPattern,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShutterRequest {
    pub optics: OpticalRequest,
    pub duration: RationalTime,
    pub temporal_samples: u16,
    pub readout: SensorReadout,
    /// Optical neutral-density attenuation applied before sensor charge collection.
    pub neutral_density_stops: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FrameCaptureRequest {
    pub optics: OpticalRequest,
    pub frame_rate: FrameRate,
    pub frame_index: i64,
    pub duration: RationalTime,
    pub temporal_samples: u16,
    pub readout: SensorReadout,
    pub neutral_density_stops: f32,
    pub noise_seed: u64,
}

impl FrameCaptureRequest {
    fn resolve(self) -> Result<(ShutterRequest, CaptureIdentity), ApplicationError> {
        if !self.neutral_density_stops.is_finite()
            || !(0.0..=16.0).contains(&self.neutral_density_stops)
        {
            return Err(ApplicationError::InvalidOpticalAttenuation);
        }
        let mut optics = self.optics;
        optics.time = self
            .frame_rate
            .time_at_frame(self.frame_index)
            .map_err(ApplicationError::Time)?;
        Ok((
            ShutterRequest {
                optics,
                duration: self.duration,
                temporal_samples: self.temporal_samples,
                readout: self.readout,
                neutral_density_stops: self.neutral_density_stops,
            },
            CaptureIdentity {
                noise_seed: self.noise_seed,
                frame_index: self.frame_index,
            },
        ))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SensorReadout {
    Global,
    Rolling {
        duration: RationalTime,
        direction: RollingDirection,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RollingDirection {
    TopToBottom,
    BottomToTop,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SimulationRequest {
    pub optics: OpticalRequest,
    pub view: DiagnosticView,
    pub preview_exposure_ev: f32,
}

impl SimulationRequest {
    pub fn optical_request(&self) -> OpticalRequest {
        self.optics.clone()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedFrame {
    pub time: RationalTime,
    pub viewport_aspect: f32,
    pub camera: CameraSample,
    pub screen: ScreenSample,
    pub inspection: Option<PanelRegion>,
    pub projected_screen: Option<ProjectedScreen>,
    pub native_raster: [u32; 2],
    pub active_size_meters: [f32; 2],
    pub pixel_pitch_meters: f32,
    pub pixels_per_inch: f32,
    pub representative_signal: DeviceRgb,
    pub representative_emission: LinearRgb,
    pub camera_yaw_degrees: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreviewPixel {
    pub rgb: PreviewRgb,
    pub on_panel: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LinearOpticalPixel {
    pub acescg_irradiance: LinearRgb,
    pub on_panel: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LinearOpticalRaster {
    pub frame: PreparedFrame,
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<LinearOpticalPixel>,
    pub projected_device_pixel_percent: f32,
    pub inspection_field_meters: Option<[f32; 2]>,
    pub subpixels_resolved_at_center: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PreparedRaster {
    pub frame: PreparedFrame,
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<PreviewPixel>,
    pub preview_scale_percent: f32,
    pub inspection_field_meters: Option<[f32; 2]>,
    pub subpixels_resolved_at_center: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RasterWindow {
    full_width: u16,
    full_height: u16,
    origin_x: u16,
    origin_y: u16,
    width: u16,
    height: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpatialRasterWindow {
    pub full_width: u16,
    pub full_height: u16,
    pub origin_x: u16,
    pub origin_y: u16,
    pub width: u16,
    pub height: u16,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SpatialSignalPlan {
    Procedural {
        pattern: ProceduralTestPattern,
        time_seconds: f32,
    },
    Raster {
        width: u32,
        height: u32,
        device_signal: Arc<[DeviceRgb]>,
        linear_native_emission: Arc<[LinearRgb]>,
        placement: RasterPlacement,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpatialPanelPlan {
    pub native_width: u32,
    pub native_height: u32,
    pub active_width_meters: f32,
    pub active_height_meters: f32,
    pub stripe_layout: screen_panel::StripeLayout,
    pub black_matrix_fraction: f32,
    pub eotf_gamma: f32,
    pub black_level_nits: f32,
    pub white_level_nits: f32,
    pub angular_emission_power: LinearRgb,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpatialOpticalPlan {
    pub frame: PreparedFrame,
    pub raster: SpatialRasterWindow,
    pub panel: SpatialPanelPlan,
    pub panel_native_to_acescg: [[f32; 3]; 3],
    pub panel_character_strength: f32,
    pub lens_character_strength: f32,
    pub cover: CoverGlassProfile,
    pub environment: ProceduralEnvironment,
    pub aperture_sample_count: u16,
    /// Gate-average lens stray-light term in linear ACEScg irradiance.
    pub veiling_glare_gate_average: LinearRgb,
    pub signal: SpatialSignalPlan,
}

impl SpatialOpticalPlan {
    fn has_identical_spatial_evaluation(&self, other: &Self) -> bool {
        self.raster == other.raster
            && self.frame.camera == other.frame.camera
            && self.frame.screen == other.frame.screen
            && self.panel == other.panel
            && self.panel_native_to_acescg == other.panel_native_to_acescg
            && self.panel_character_strength == other.panel_character_strength
            && self.lens_character_strength == other.lens_character_strength
            && self.cover == other.cover
            && self.environment == other.environment
            && self.aperture_sample_count == other.aperture_sample_count
            && self.veiling_glare_gate_average == other.veiling_glare_gate_average
            && self.signal.has_identical_spatial_evaluation(&other.signal)
    }

    fn time_varying_procedural_template_for_region(
        &self,
        time: RationalTime,
        region: SensorRegion,
    ) -> Option<Self> {
        let mut plan = self.clone();
        plan.frame.time = time;
        plan.raster.origin_x = region.origin_x;
        plan.raster.origin_y = region.origin_y;
        plan.raster.width = region.width;
        plan.raster.height = region.height;
        let SpatialSignalPlan::Procedural {
            pattern,
            time_seconds,
        } = &mut plan.signal
        else {
            return None;
        };
        *time_seconds = time.as_seconds() as f32;
        let signal = diagnostic_signal(*pattern, Vec2 { x: 0.5, y: 0.5 }, time);
        let span = plan.panel.white_level_nits - plan.panel.black_level_nits;
        let channel = |value: f32| {
            plan.panel.black_level_nits
                + span * value.abs().powf(plan.panel.eotf_gamma).copysign(value)
        };
        let native = LinearRgb::new(channel(signal.r), channel(signal.g), channel(signal.b));
        let matrix = plan.panel_native_to_acescg;
        plan.frame.representative_signal = signal;
        plan.frame.representative_emission = LinearRgb::new(
            matrix[0][0] * native.r + matrix[0][1] * native.g + matrix[0][2] * native.b,
            matrix[1][0] * native.r + matrix[1][1] * native.g + matrix[1][2] * native.b,
            matrix[2][0] * native.r + matrix[2][1] * native.g + matrix[2][2] * native.b,
        );
        plan.refresh_procedural_veiling_glare();
        Some(plan)
    }

    fn static_template_for_region(&self, time: RationalTime, region: SensorRegion) -> Self {
        let mut plan = self.clone();
        plan.frame.time = time;
        plan.raster.origin_x = region.origin_x;
        plan.raster.origin_y = region.origin_y;
        plan.raster.width = region.width;
        plan.raster.height = region.height;
        if let SpatialSignalPlan::Procedural { time_seconds, .. } = &mut plan.signal {
            *time_seconds = time.as_seconds() as f32;
            plan.refresh_procedural_veiling_glare();
        }
        plan
    }

    fn refresh_procedural_veiling_glare(&mut self) {
        let SpatialSignalPlan::Procedural { pattern, .. } = self.signal else {
            return;
        };
        if self.frame.camera.lens.veiling_glare_fraction == 0.0 {
            self.veiling_glare_gate_average = LinearRgb::new(0.0, 0.0, 0.0);
            return;
        }
        const OFFSETS: [f32; 4] = [0.125, 0.375, 0.625, 0.875];
        let mut mean = LinearRgb::new(0.0, 0.0, 0.0);
        let span = self.panel.white_level_nits - self.panel.black_level_nits;
        for y in OFFSETS {
            for x in OFFSETS {
                let code = diagnostic_signal(pattern, Vec2 { x, y }, self.frame.time);
                let channel = |value: f32| {
                    self.panel.black_level_nits
                        + span * value.abs().powf(self.panel.eotf_gamma).copysign(value)
                };
                mean.r += channel(code.r);
                mean.g += channel(code.g);
                mean.b += channel(code.b);
            }
        }
        let reciprocal = 1.0 / 16.0;
        mean = LinearRgb::new(
            mean.r * reciprocal,
            mean.g * reciprocal,
            mean.b * reciprocal,
        );
        let coverage = self
            .frame
            .projected_screen
            .map_or(0.0, projected_screen_gate_coverage);
        let facing = self
            .frame
            .projected_screen
            .map_or(0.0, |value| value.facing_ratio);
        let transmission = self
            .cover
            .evaluator(self.environment)
            .expect("prepared cover remains valid")
            .transmission(facing);
        let pupil =
            core::f32::consts::PI * 0.25 / (self.frame.camera.f_stop * self.frame.camera.f_stop);
        let weighted = LinearRgb::new(
            mean.r
                * facing.powf(self.panel.angular_emission_power.r)
                * self.frame.camera.lens.transmission_rgb[0]
                * transmission.r
                * pupil
                * coverage,
            mean.g
                * facing.powf(self.panel.angular_emission_power.g)
                * self.frame.camera.lens.transmission_rgb[1]
                * transmission.g
                * pupil
                * coverage,
            mean.b
                * facing.powf(self.panel.angular_emission_power.b)
                * self.frame.camera.lens.transmission_rgb[2]
                * transmission.b
                * pupil
                * coverage,
        );
        let matrix = self.panel_native_to_acescg;
        self.veiling_glare_gate_average = LinearRgb::new(
            matrix[0][0] * weighted.r + matrix[0][1] * weighted.g + matrix[0][2] * weighted.b,
            matrix[1][0] * weighted.r + matrix[1][1] * weighted.g + matrix[1][2] * weighted.b,
            matrix[2][0] * weighted.r + matrix[2][1] * weighted.g + matrix[2][2] * weighted.b,
        );
    }
}

impl SpatialSignalPlan {
    fn has_identical_spatial_evaluation(&self, other: &Self) -> bool {
        match (self, other) {
            (
                Self::Procedural {
                    pattern: first_pattern,
                    time_seconds: first_time,
                },
                Self::Procedural {
                    pattern,
                    time_seconds,
                },
            ) => {
                first_pattern == pattern
                    && (*first_pattern != ProceduralTestPattern::AnimatedCheckerboard
                        || first_time == time_seconds)
            }
            (
                Self::Raster {
                    width: first_width,
                    height: first_height,
                    device_signal: first_device,
                    linear_native_emission: first_emission,
                    placement: first_placement,
                },
                Self::Raster {
                    width,
                    height,
                    device_signal,
                    linear_native_emission,
                    placement,
                },
            ) => {
                first_width == width
                    && first_height == height
                    && first_placement == placement
                    && Arc::ptr_eq(first_device, device_signal)
                    && Arc::ptr_eq(first_emission, linear_native_emission)
            }
            _ => false,
        }
    }
}

pub trait SpatialOpticalBackend {
    type Error: fmt::Display;

    fn evaluate_spatial(
        &self,
        plan: &SpatialOpticalPlan,
    ) -> Result<Vec<LinearOpticalPixel>, Self::Error>;

    fn evaluate_spatial_batch(
        &self,
        plans: &[SpatialOpticalPlan],
    ) -> Result<Vec<Vec<LinearOpticalPixel>>, Self::Error> {
        plans
            .iter()
            .map(|plan| self.evaluate_spatial(plan))
            .collect()
    }
}

/// Wall-clock stage accounting for reproducible Native pipeline benchmarks.
///
/// Backend time includes command encoding, GPU execution and materializing shared-buffer results.
/// Apple silicon uses unified `StorageModeShared` buffers, so there is no separate device-to-host
/// transfer stage in the current Metal backend.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct NativeCaptureStageTimings {
    pub preparation_cpu: Duration,
    pub spatial_backend: Duration,
    pub integration_and_sensor_cpu: Duration,
    pub raw_development_backend: Duration,
    pub output_assembly_cpu: Duration,
}

impl RasterWindow {
    fn full(width: u16, height: u16) -> Self {
        Self {
            full_width: width,
            full_height: height,
            origin_x: 0,
            origin_y: 0,
            width,
            height,
        }
    }

    fn from_sensor_region(sensor: SensorProfile, region: SensorRegion) -> Self {
        Self {
            full_width: sensor.native_width,
            full_height: sensor.native_height,
            origin_x: region.origin_x,
            origin_y: region.origin_y,
            width: region.width,
            height: region.height,
        }
    }
}

impl From<RasterWindow> for SpatialRasterWindow {
    fn from(value: RasterWindow) -> Self {
        Self {
            full_width: value.full_width,
            full_height: value.full_height,
            origin_x: value.origin_x,
            origin_y: value.origin_y,
            width: value.width,
            height: value.height,
        }
    }
}

pub fn prepare_procedural_spatial_plan(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<SpatialOpticalPlan, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let region = region.validate(sensor).map_err(ApplicationError::Sensor)?;
    let pattern = request.procedural_pattern;
    let time_seconds = request.time.as_seconds() as f32;
    prepare_spatial_plan(
        request,
        RasterWindow::from_sensor_region(sensor, region),
        SpatialSignalPlan::Procedural {
            pattern,
            time_seconds,
        },
    )
}

pub fn prepare_device_signal_spatial_plan(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<SpatialOpticalPlan, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let region = region.validate(sensor).map_err(ApplicationError::Sensor)?;
    let signal = prepare_device_signal_spatial_signal(request.panel, source, placement)?;
    prepare_spatial_plan(
        request,
        RasterWindow::from_sensor_region(sensor, region),
        signal,
    )
}

fn prepare_device_signal_spatial_signal(
    panel: LcdProfile,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<SpatialSignalPlan, ApplicationError> {
    let panel_evaluator = panel.evaluator().map_err(ApplicationError::Panel)?;
    let linear_native_emission = source
        .source
        .pixels
        .iter()
        .map(|pixel| {
            LinearRgb::new(
                panel_evaluator.native_channel(*pixel, 0),
                panel_evaluator.native_channel(*pixel, 1),
                panel_evaluator.native_channel(*pixel, 2),
            )
        })
        .collect::<Vec<_>>();
    Ok(SpatialSignalPlan::Raster {
        width: source.source.width,
        height: source.source.height,
        device_signal: Arc::from(source.source.pixels.clone()),
        linear_native_emission: Arc::from(linear_native_emission),
        placement,
    })
}

fn prepare_spatial_plan(
    request: OpticalRequest,
    raster: RasterWindow,
    signal: SpatialSignalPlan,
) -> Result<SpatialOpticalPlan, ApplicationError> {
    if raster.width == 0 || raster.height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    validate_character_strength(request.panel_character_strength)?;
    validate_character_strength(request.lens_character_strength)?;
    let frame = prepare_frame(request.clone())?;
    if !raster_represents_viewport(raster.full_width, raster.full_height, frame.viewport_aspect) {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect: f32::from(raster.full_width) / f32::from(raster.full_height),
            viewport_aspect: frame.viewport_aspect,
        });
    }
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let basis = [
        panel_evaluator.native_to_acescg(LinearRgb::new(1.0, 0.0, 0.0)),
        panel_evaluator.native_to_acescg(LinearRgb::new(0.0, 1.0, 0.0)),
        panel_evaluator.native_to_acescg(LinearRgb::new(0.0, 0.0, 1.0)),
    ];
    let mean_native = match &signal {
        SpatialSignalPlan::Raster {
            linear_native_emission,
            placement,
            width,
            height,
            ..
        } => {
            let scale = placed_signal_area_fraction(
                *placement,
                *width,
                *height,
                request.panel.native_width,
                request.panel.native_height,
            ) / linear_native_emission.len() as f32;
            linear_native_emission
                .iter()
                .fold(LinearRgb::new(0.0, 0.0, 0.0), |sum, value| {
                    LinearRgb::new(
                        sum.r + value.r * scale,
                        sum.g + value.g * scale,
                        sum.b + value.b * scale,
                    )
                })
        }
        SpatialSignalPlan::Procedural { pattern, .. } => {
            diagnostic_area_signal(
                *pattern,
                Vec2 { x: 0.0, y: 0.0 },
                Vec2 { x: 1.0, y: 1.0 },
                request.time,
                panel_evaluator,
            )
            .linear_native_emission
        }
    };
    let veiling_glare_gate_average = lens_veiling_gate_average(
        &request,
        frame,
        mean_native,
        raster.full_width as f32 / raster.full_height as f32,
        1.0,
    )?;
    Ok(SpatialOpticalPlan {
        frame,
        raster: raster.into(),
        panel: SpatialPanelPlan {
            native_width: request.panel.native_width,
            native_height: request.panel.native_height,
            active_width_meters: request.panel.active_width.0,
            active_height_meters: request.panel.active_height.0,
            stripe_layout: request.panel.stripe_layout,
            black_matrix_fraction: request.panel.black_matrix_fraction,
            eotf_gamma: request.panel.eotf_gamma,
            black_level_nits: request.panel.black_level_nits,
            white_level_nits: request.panel.white_level_nits,
            angular_emission_power: request.panel.angular_emission_power,
        },
        panel_native_to_acescg: [
            [basis[0].r, basis[1].r, basis[2].r],
            [basis[0].g, basis[1].g, basis[2].g],
            [basis[0].b, basis[1].b, basis[2].b],
        ],
        panel_character_strength: request.panel_character_strength,
        lens_character_strength: request.lens_character_strength,
        cover: request.cover,
        environment: request.environment,
        aperture_sample_count: aperture_sample_count(
            frame.camera,
            frame.screen,
            request.panel,
            raster.full_width,
        ) as u16,
        veiling_glare_gate_average,
        signal,
    })
}

fn lens_veiling_gate_average(
    request: &OpticalRequest,
    frame: PreparedFrame,
    mean_native: LinearRgb,
    viewport_aspect: f32,
    temporal_gain: f32,
) -> Result<LinearRgb, ApplicationError> {
    if frame.camera.lens.veiling_glare_fraction == 0.0 {
        return Ok(LinearRgb::new(0.0, 0.0, 0.0));
    }
    let evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let cover = request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let projected = project_screen(
        frame.camera,
        frame.screen,
        request.panel.active_width,
        request.panel.active_height,
        viewport_aspect,
    );
    let coverage = projected.map_or(0.0, projected_screen_gate_coverage);
    let facing = projected.map_or(0.0, |value| value.facing_ratio);
    let transmission = cover.transmission(facing);
    let pupil = core::f32::consts::PI * 0.25 / (frame.camera.f_stop * frame.camera.f_stop);
    let native = LinearRgb::new(
        mean_native.r
            * temporal_gain
            * evaluator.angular_channel(facing, 0)
            * frame.camera.lens.transmission_rgb[0]
            * transmission.r
            * pupil
            * coverage,
        mean_native.g
            * temporal_gain
            * evaluator.angular_channel(facing, 1)
            * frame.camera.lens.transmission_rgb[1]
            * transmission.g
            * pupil
            * coverage,
        mean_native.b
            * temporal_gain
            * evaluator.angular_channel(facing, 2)
            * frame.camera.lens.transmission_rgb[2]
            * transmission.b
            * pupil
            * coverage,
    );
    Ok(evaluator.native_to_acescg(native))
}

fn validate_character_strength(strength: f32) -> Result<(), ApplicationError> {
    if strength.is_finite() && (0.0..=4.0).contains(&strength) {
        Ok(())
    } else {
        Err(ApplicationError::InvalidCharacterStrength)
    }
}

pub fn prepare_frame(request: OpticalRequest) -> Result<PreparedFrame, ApplicationError> {
    if !request.viewport_aspect.is_finite() || request.viewport_aspect <= 0.0 {
        return Err(ApplicationError::InvalidViewportAspect);
    }
    validate_character_strength(request.panel_character_strength)?;
    validate_character_strength(request.lens_character_strength)?;
    let panel = request.panel.validate().map_err(ApplicationError::Panel)?;
    request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let mut camera_rig = request.camera.clone();
    for keyframe in &mut camera_rig.intrinsics.keyframes {
        keyframe.lens = keyframe
            .lens
            .with_character_strength(request.lens_character_strength)
            .ok_or(ApplicationError::InvalidCharacterStrength)?;
    }
    camera_rig.validate().map_err(ApplicationError::Geometry)?;
    request
        .screen
        .validate()
        .map_err(ApplicationError::Geometry)?;
    let screen = request
        .screen
        .sample(request.time)
        .map_err(ApplicationError::Geometry)?;
    let camera = if let Some(region) = request.inspection {
        camera_rig
            .fit_panel_region(
                request.time,
                region,
                panel.active_width,
                panel.active_height,
                screen,
                request.viewport_aspect,
            )
            .map_err(ApplicationError::Geometry)?
    } else {
        camera_rig
            .sample(request.time)
            .map_err(ApplicationError::Geometry)?
    };
    let sensor_aspect = camera.sensor_width.0 / camera.sensor_height.0;
    if (sensor_aspect - request.viewport_aspect).abs() > 1.0e-4 {
        return Err(ApplicationError::SensorViewportAspectMismatch {
            sensor_aspect,
            viewport_aspect: request.viewport_aspect,
        });
    }
    let projected_screen = project_screen(
        camera,
        screen,
        panel.active_width,
        panel.active_height,
        request.viewport_aspect,
    );
    let signal = diagnostic_signal(
        request.procedural_pattern,
        Vec2 { x: 0.5, y: 0.5 },
        request.time,
    );
    Ok(PreparedFrame {
        time: request.time,
        viewport_aspect: request.viewport_aspect,
        camera,
        screen,
        inspection: request.inspection,
        projected_screen,
        native_raster: [panel.native_width, panel.native_height],
        active_size_meters: [panel.active_width.0, panel.active_height.0],
        pixel_pitch_meters: panel.pixel_pitch_meters(),
        pixels_per_inch: panel.pixels_per_inch(),
        representative_signal: signal,
        representative_emission: panel.emitted_radiance(signal),
        camera_yaw_degrees: camera.yaw_degrees,
    })
}

pub fn prepare_raster(
    request: SimulationRequest,
    width: u16,
    height: u16,
) -> Result<PreparedRaster, ApplicationError> {
    let panel_evaluator = request
        .optics
        .panel
        .evaluator()
        .map_err(ApplicationError::Panel)?;
    prepare_raster_with_signal(
        request.clone(),
        width,
        height,
        &|uv| diagnostic_signal(request.optics.procedural_pattern, uv, request.optics.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.optics.procedural_pattern,
                minimum,
                maximum,
                request.optics.time,
                panel_evaluator,
            )
        },
    )
}

pub fn evaluate_linear_optics(
    request: OpticalRequest,
    width: u16,
    height: u16,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    evaluate_optical_raster_with_signal(
        request.clone(),
        width,
        height,
        DiagnosticView::Composite,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
    )
}

fn evaluate_linear_optics_region(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    evaluate_optical_window_with_signal(
        request.clone(),
        RasterWindow::from_sensor_region(sensor, region),
        DiagnosticView::Composite,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
    )
}

/// Evaluates the modulation-free procedural spatial pass with the scalar CPU implementation.
///
/// This is an oracle for backend conformance tests. Product composition should select a
/// [`SpatialOpticalBackend`] at its platform boundary instead of calling this function.
pub fn evaluate_procedural_spatial_cpu_oracle(
    mut request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    request.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(1.0);
    evaluate_linear_optics_region(request, sensor, region).map(|raster| raster.pixels)
}

fn evaluate_procedural_optical_sensor_row(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    global_row: u16,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let raster = evaluate_optical_window_with_signal(
        request.clone(),
        RasterWindow {
            full_width: sensor.native_width,
            full_height: sensor.native_height,
            origin_x: region.origin_x,
            origin_y: global_row,
            width: region.width,
            height: 1,
        },
        DiagnosticView::Composite,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
    )?;
    Ok(raster.pixels)
}

pub fn integrate_procedural_shutter(
    request: ShutterRequest,
    width: u16,
    height: u16,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    match request.readout {
        SensorReadout::Global => integrate_global_shutter(request, width, height, |optics| {
            evaluate_linear_optics(optics, width, height)
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_shutter(
            request,
            width,
            height,
            duration,
            direction,
            |optics, row| evaluate_procedural_optical_row(optics, width, height, row),
        ),
    }
}

pub fn capture_procedural_frame(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
) -> Result<RawSensorRaster, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let (shutter, identity) = request.resolve()?;
    let exposure =
        integrate_procedural_shutter(shutter, sensor.native_width, sensor.native_height)?;
    expose_raw(sensor, &exposure, identity).map_err(ApplicationError::Sensor)
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapturedCameraFrame {
    pub raw: RawSensorRaster,
    pub developed: DevelopedCameraRaster,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapturedCameraRegion {
    pub raw: RawSensorRegion,
    pub developed: DevelopedCameraRegion,
}

pub fn capture_and_develop_procedural_region(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
) -> Result<CapturedCameraRegion, ApplicationError> {
    capture_and_develop_procedural_region_with_backend(
        request,
        sensor,
        development,
        requested_region,
        &CpuRawDevelopment,
    )
}

pub fn capture_and_develop_procedural_region_with_backend<B: RawDevelopmentBackend>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    backend: &B,
) -> Result<CapturedCameraRegion, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let sensor_support_region = evaluation_region.expanded_for_sensor_bloom(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_procedural_region(shutter, sensor, sensor_support_region)?;
    let raw = expose_raw_region(
        sensor,
        &exposure,
        identity,
        sensor_support_region,
        evaluation_region,
    )
    .map_err(ApplicationError::Sensor)?;
    let developed = backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

/// Product compute composition with independent spatial-optics and RAW-development ports.
pub fn capture_and_develop_procedural_region_with_compute_backends<S, R>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    spatial_backend: &S,
    raw_backend: &R,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    S: SpatialOpticalBackend,
    R: RawDevelopmentBackend,
{
    capture_and_develop_procedural_region_with_compute_backends_timed(
        request,
        sensor,
        development,
        requested_region,
        spatial_backend,
        raw_backend,
    )
    .map(|(capture, _)| capture)
}

/// The connected product pipeline with stage timings intended for performance diagnostics.
pub fn capture_and_develop_procedural_region_with_compute_backends_timed<S, R>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    spatial_backend: &S,
    raw_backend: &R,
) -> Result<(CapturedCameraRegion, NativeCaptureStageTimings), ApplicationError>
where
    S: SpatialOpticalBackend,
    R: RawDevelopmentBackend,
{
    let mut timings = NativeCaptureStageTimings::default();
    let preparation_started = Instant::now();
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let sensor_support_region = evaluation_region.expanded_for_sensor_bloom(sensor);
    let source_is_static =
        request.optics.procedural_pattern != ProceduralTestPattern::AnimatedCheckerboard;
    let (shutter, identity) = request.resolve()?;
    timings.preparation_cpu += preparation_started.elapsed();
    let exposure = integrate_spatial_region_with_backend_timed(
        shutter,
        sensor,
        sensor_support_region,
        source_is_static,
        spatial_backend,
        |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
        &mut timings,
    )?;
    let sensor_started = Instant::now();
    let raw = expose_raw_region(
        sensor,
        &exposure,
        identity,
        sensor_support_region,
        evaluation_region,
    )
    .map_err(ApplicationError::Sensor)?;
    timings.integration_and_sensor_cpu += sensor_started.elapsed();
    let raw_started = Instant::now();
    let developed = raw_backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    timings.raw_development_backend = raw_started.elapsed();
    let assembly_started = Instant::now();
    let capture = CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    };
    timings.output_assembly_cpu = assembly_started.elapsed();
    Ok((capture, timings))
}

pub fn capture_and_develop_device_signal_region(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<CapturedCameraRegion, ApplicationError> {
    capture_and_develop_device_signal_region_with_backend(
        request,
        sensor,
        development,
        requested_region,
        signal,
        placement,
        &CpuRawDevelopment,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_with_backend<B: RawDevelopmentBackend>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
    backend: &B,
) -> Result<CapturedCameraRegion, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let sensor_support_region = evaluation_region.expanded_for_sensor_bloom(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure =
        integrate_device_signal_region(shutter, sensor, sensor_support_region, signal, placement)?;
    let raw = expose_raw_region(
        sensor,
        &exposure,
        identity,
        sensor_support_region,
        evaluation_region,
    )
    .map_err(ApplicationError::Sensor)?;
    let developed = backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_with_compute_backends<S, R>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
    spatial_backend: &S,
    raw_backend: &R,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    S: SpatialOpticalBackend,
    R: RawDevelopmentBackend,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let sensor_support_region = evaluation_region.expanded_for_sensor_bloom(sensor);
    let spatial_signal =
        prepare_device_signal_spatial_signal(request.optics.panel, signal, placement)?;
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_spatial_region_with_backend(
        shutter,
        sensor,
        sensor_support_region,
        true,
        spatial_backend,
        |optics, region| {
            prepare_spatial_plan(
                optics,
                RasterWindow::from_sensor_region(sensor, region),
                spatial_signal.clone(),
            )
        },
    )?;
    let raw = expose_raw_region(
        sensor,
        &exposure,
        identity,
        sensor_support_region,
        evaluation_region,
    )
    .map_err(ApplicationError::Sensor)?;
    let developed = raw_backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

/// Region-authoritative capture for animated device content. Every temporal and rolling-shutter
/// sample resolves the source at its exact rational time; tiled capture therefore cannot freeze
/// the source at the nominal frame time.
pub fn capture_and_develop_device_signal_region_sequence<F>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    placement: RasterPlacement,
    signal_at_time: F,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    capture_and_develop_device_signal_region_sequence_with_backend(
        request,
        sensor,
        development,
        requested_region,
        placement,
        signal_at_time,
        &CpuRawDevelopment,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_sequence_with_backend<F, B>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    placement: RasterPlacement,
    mut signal_at_time: F,
    backend: &B,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
    B: RawDevelopmentBackend,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let sensor_support_region = evaluation_region.expanded_for_sensor_bloom(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure = match shutter.readout {
        SensorReadout::Global => {
            integrate_global_region(shutter, sensor_support_region, |optics| {
                let signal = signal_at_time(optics.time)?;
                evaluate_linear_optics_region_from_prepared_device_signal(
                    optics,
                    sensor,
                    sensor_support_region,
                    &signal,
                    placement,
                )
            })
        }
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_region(
            shutter,
            sensor,
            sensor_support_region,
            duration,
            direction,
            |optics, row| {
                let signal = signal_at_time(optics.time)?;
                evaluate_device_signal_optical_sensor_row(
                    optics,
                    sensor,
                    sensor_support_region,
                    row,
                    &signal,
                    placement,
                )
            },
        ),
    }?;
    let raw = expose_raw_region(
        sensor,
        &exposure,
        identity,
        sensor_support_region,
        evaluation_region,
    )
    .map_err(ApplicationError::Sensor)?;
    let developed = backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_sequence_with_compute_backends<F, S, R>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    placement: RasterPlacement,
    mut signal_at_time: F,
    spatial_backend: &S,
    raw_backend: &R,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
    S: SpatialOpticalBackend,
    R: RawDevelopmentBackend,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let sensor_support_region = evaluation_region.expanded_for_sensor_bloom(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_spatial_region_with_backend(
        shutter,
        sensor,
        sensor_support_region,
        false,
        spatial_backend,
        |optics, region| {
            let signal = signal_at_time(optics.time)?;
            prepare_device_signal_spatial_plan(optics, sensor, region, &signal, placement)
        },
    )?;
    let raw = expose_raw_region(
        sensor,
        &exposure,
        identity,
        sensor_support_region,
        evaluation_region,
    )
    .map_err(ApplicationError::Sensor)?;
    let developed = raw_backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

pub fn capture_and_develop_procedural_frame(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
) -> Result<CapturedCameraFrame, ApplicationError> {
    let raw = capture_procedural_frame(request, sensor)?;
    let developed = develop_raw_to_acescg(&raw, sensor, development)
        .map_err(ApplicationError::CameraDevelopment)?;
    Ok(CapturedCameraFrame { raw, developed })
}

pub fn integrate_shutter_from_device_signal_sequence<F>(
    request: ShutterRequest,
    width: u16,
    height: u16,
    placement: RasterPlacement,
    mut signal_at_time: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    match request.readout {
        SensorReadout::Global => integrate_global_shutter(request, width, height, |optics| {
            let signal = signal_at_time(optics.time)?;
            evaluate_linear_optics_from_prepared_device_signal(
                optics, width, height, &signal, placement,
            )
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_shutter(
            request,
            width,
            height,
            duration,
            direction,
            |optics, row| {
                let signal = signal_at_time(optics.time)?;
                evaluate_optical_row_from_prepared_device_signal(
                    optics, width, height, row, &signal, placement,
                )
            },
        ),
    }
}

pub fn capture_frame_from_device_signal_sequence<F>(
    request: FrameCaptureRequest,
    placement: RasterPlacement,
    signal_at_time: F,
    sensor: SensorProfile,
) -> Result<RawSensorRaster, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_shutter_from_device_signal_sequence(
        shutter,
        sensor.native_width,
        sensor.native_height,
        placement,
        signal_at_time,
    )?;
    expose_raw(sensor, &exposure, identity).map_err(ApplicationError::Sensor)
}

pub fn capture_and_develop_frame_from_device_signal_sequence<F>(
    request: FrameCaptureRequest,
    placement: RasterPlacement,
    signal_at_time: F,
    sensor: SensorProfile,
    development: CameraDevelopment,
) -> Result<CapturedCameraFrame, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    let raw =
        capture_frame_from_device_signal_sequence(request, placement, signal_at_time, sensor)?;
    let developed = develop_raw_to_acescg(&raw, sensor, development)
        .map_err(ApplicationError::CameraDevelopment)?;
    Ok(CapturedCameraFrame { raw, developed })
}

fn integrate_global_shutter<F>(
    request: ShutterRequest,
    width: u16,
    height: u16,
    mut optical_at_time: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    F: FnMut(OpticalRequest) -> Result<LinearOpticalRaster, ApplicationError>,
{
    if request.readout != SensorReadout::Global {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let samples = shutter_quadrature(
        request.optics.time,
        request.duration,
        request.temporal_samples,
    )?;
    if width == 0 || height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let pixel_count = usize::from(width) * usize::from(height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for sample in samples {
        let mut optics = request.optics.clone();
        optics.time = sample.time;
        optics.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(
            optics
                .panel
                .temporal_emission
                .average_gain(sample.start, sample.end)
                .map_err(ApplicationError::Panel)?,
        );
        let raster = optical_at_time(optics)?;
        if raster.width != width || raster.height != height || raster.pixels.len() != pixel_count {
            return Err(ApplicationError::OpticalSampleRasterMismatch);
        }
        for (sum, pixel) in accumulated.iter_mut().zip(raster.pixels) {
            sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
            sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
            sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
        }
    }
    finish_integrated_exposure(
        width,
        height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

fn integrate_procedural_region(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    match request.readout {
        SensorReadout::Global => integrate_global_region(request, region, |optics| {
            evaluate_linear_optics_region(optics, sensor, region)
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_region(
            request,
            sensor,
            region,
            duration,
            direction,
            |optics, row| evaluate_procedural_optical_sensor_row(optics, sensor, region, row),
        ),
    }
}

fn integrate_device_signal_region(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    match request.readout {
        SensorReadout::Global => integrate_global_region(request, region, |optics| {
            evaluate_linear_optics_region_from_prepared_device_signal(
                optics, sensor, region, signal, placement,
            )
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_region(
            request,
            sensor,
            region,
            duration,
            direction,
            |optics, row| {
                evaluate_device_signal_optical_sensor_row(
                    optics, sensor, region, row, signal, placement,
                )
            },
        ),
    }
}

fn integrate_spatial_region_with_backend<B, F>(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source_is_static: bool,
    backend: &B,
    plan_at: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    B: SpatialOpticalBackend,
    F: FnMut(OpticalRequest, SensorRegion) -> Result<SpatialOpticalPlan, ApplicationError>,
{
    integrate_spatial_region_with_backend_timed(
        request,
        sensor,
        region,
        source_is_static,
        backend,
        plan_at,
        &mut NativeCaptureStageTimings::default(),
    )
}

fn integrate_spatial_region_with_backend_timed<B, F>(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source_is_static: bool,
    backend: &B,
    mut plan_at: F,
    timings: &mut NativeCaptureStageTimings,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    B: SpatialOpticalBackend,
    F: FnMut(OpticalRequest, SensorRegion) -> Result<SpatialOpticalPlan, ApplicationError>,
{
    let preparation_started = Instant::now();
    struct BatchSample {
        plan_index: usize,
        expected_pixels: usize,
        weight_seconds: f64,
        temporal_gain: f32,
    }

    let spatial_tracks_are_static = request.optics.camera.transform.keyframes.len() == 1
        && request.optics.camera.intrinsics.keyframes.len() == 1
        && request.optics.screen.keyframes.len() == 1;
    let can_reuse_spatial_samples = source_is_static && spatial_tracks_are_static;
    let mut plans = Vec::new();
    let mut batch_samples = Vec::new();
    let intern_plan =
        |plans: &mut Vec<SpatialOpticalPlan>, search_start: usize, plan: SpatialOpticalPlan| {
            if let Some(index) = plans[search_start..]
                .iter()
                .position(|candidate| candidate.has_identical_spatial_evaluation(&plan))
            {
                search_start + index
            } else {
                plans.push(plan);
                plans.len() - 1
            }
        };
    match request.readout {
        SensorReadout::Global => {
            let mut reused_plan_index = None;
            let mut procedural_template: Option<SpatialOpticalPlan> = None;
            for sample in shutter_quadrature(
                request.optics.time,
                request.duration,
                request.temporal_samples,
            )? {
                let temporal_gain = request
                    .optics
                    .panel
                    .temporal_emission
                    .average_gain(sample.start, sample.end)
                    .map_err(ApplicationError::Panel)?;
                let mut optics = request.optics.clone();
                optics.time = sample.time;
                optics.panel_temporal_evaluation =
                    PanelTemporalEvaluation::ExposureAverage(temporal_gain);
                let plan_index = if can_reuse_spatial_samples {
                    if let Some(index) = reused_plan_index {
                        index
                    } else {
                        let index = intern_plan(&mut plans, 0, plan_at(optics, region)?);
                        reused_plan_index = Some(index);
                        index
                    }
                } else {
                    let plan = if spatial_tracks_are_static {
                        if let Some(plan) = procedural_template.as_ref().and_then(|template| {
                            template
                                .time_varying_procedural_template_for_region(sample.time, region)
                        }) {
                            plan
                        } else {
                            let plan = plan_at(optics, region)?;
                            if matches!(plan.signal, SpatialSignalPlan::Procedural { .. }) {
                                procedural_template = Some(plan.clone());
                            }
                            plan
                        }
                    } else {
                        plan_at(optics, region)?
                    };
                    intern_plan(&mut plans, 0, plan)
                };
                batch_samples.push(BatchSample {
                    plan_index,
                    expected_pixels: usize::from(region.width) * usize::from(region.height),
                    weight_seconds: sample.weight_seconds,
                    temporal_gain,
                });
            }
        }
        SensorReadout::Rolling {
            duration,
            direction,
        } => {
            if duration.numerator() <= 0 {
                return Err(ApplicationError::InvalidSensorReadout);
            }
            let frame_uniform_gains = frame_uniform_residual_gains(&request)?;
            let mut row_template: Option<SpatialOpticalPlan> = None;
            for local_row in 0..usize::from(region.height) {
                let row_plan_start = plans.len();
                let mut reused_plan_index = None;
                let global_row = usize::from(region.origin_y) + local_row;
                let row_center = rolling_row_center_time(
                    request.optics.time,
                    duration,
                    global_row,
                    usize::from(sensor.native_height),
                    direction,
                )?;
                for (sample_index, sample) in
                    shutter_quadrature(row_center, request.duration, request.temporal_samples)?
                        .into_iter()
                        .enumerate()
                {
                    let temporal_gain = rolling_temporal_gain(
                        &request,
                        frame_uniform_gains.as_deref(),
                        sample_index,
                        sample,
                    )?;
                    let mut optics = request.optics.clone();
                    optics.time = sample.time;
                    optics.panel_temporal_evaluation =
                        PanelTemporalEvaluation::ExposureAverage(temporal_gain);
                    let row_region = SensorRegion {
                        origin_x: region.origin_x,
                        origin_y: global_row as u16,
                        width: region.width,
                        height: 1,
                    };
                    let plan_index = if can_reuse_spatial_samples {
                        if let Some(index) = reused_plan_index {
                            index
                        } else {
                            let plan = if let Some(template) = &row_template {
                                template.static_template_for_region(sample.time, row_region)
                            } else {
                                let plan = plan_at(optics, row_region)?;
                                row_template = Some(plan.clone());
                                plan
                            };
                            let index = intern_plan(&mut plans, row_plan_start, plan);
                            reused_plan_index = Some(index);
                            index
                        }
                    } else {
                        let plan = if spatial_tracks_are_static {
                            if let Some(plan) = row_template.as_ref().and_then(|template| {
                                template.time_varying_procedural_template_for_region(
                                    sample.time,
                                    row_region,
                                )
                            }) {
                                plan
                            } else {
                                let plan = plan_at(optics, row_region)?;
                                if matches!(plan.signal, SpatialSignalPlan::Procedural { .. }) {
                                    row_template = Some(plan.clone());
                                }
                                plan
                            }
                        } else {
                            plan_at(optics, row_region)?
                        };
                        intern_plan(&mut plans, row_plan_start, plan)
                    };
                    batch_samples.push(BatchSample {
                        plan_index,
                        expected_pixels: usize::from(region.width),
                        weight_seconds: sample.weight_seconds,
                        temporal_gain,
                    });
                }
            }
        }
    }
    timings.preparation_cpu += preparation_started.elapsed();
    let backend_started = Instant::now();
    let batches = backend
        .evaluate_spatial_batch(&plans)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    timings.spatial_backend += backend_started.elapsed();
    if batches.len() != plans.len() {
        return Err(ApplicationError::OpticalSampleRasterMismatch);
    }
    for sample in &batch_samples {
        if batches[sample.plan_index].len() != sample.expected_pixels {
            return Err(ApplicationError::OpticalSampleRasterMismatch);
        }
    }
    let integration_started = Instant::now();
    let mut accumulated =
        vec![[0.0_f64; 3]; usize::from(region.width) * usize::from(region.height)];
    match request.readout {
        SensorReadout::Global => accumulated
            .par_iter_mut()
            .enumerate()
            .for_each(|(index, sum)| {
                for sample in &batch_samples {
                    let pixel = batches[sample.plan_index][index];
                    let scale = f64::from(sample.temporal_gain) * sample.weight_seconds;
                    sum[0] += f64::from(pixel.acescg_irradiance.r) * scale;
                    sum[1] += f64::from(pixel.acescg_irradiance.g) * scale;
                    sum[2] += f64::from(pixel.acescg_irradiance.b) * scale;
                }
            }),
        SensorReadout::Rolling { .. } => {
            let row_width = usize::from(region.width);
            let samples_per_row = usize::from(request.temporal_samples);
            accumulated
                .par_chunks_mut(row_width)
                .zip(batch_samples.par_chunks(samples_per_row))
                .for_each(|(row, samples)| {
                    for sample in samples {
                        let pixels = &batches[sample.plan_index];
                        let scale = f64::from(sample.temporal_gain) * sample.weight_seconds;
                        for (sum, pixel) in row.iter_mut().zip(pixels) {
                            sum[0] += f64::from(pixel.acescg_irradiance.r) * scale;
                            sum[1] += f64::from(pixel.acescg_irradiance.g) * scale;
                            sum[2] += f64::from(pixel.acescg_irradiance.b) * scale;
                        }
                    }
                });
        }
    }
    let exposure = finish_integrated_exposure(
        region.width,
        region.height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )?;
    timings.integration_and_sensor_cpu += integration_started.elapsed();
    Ok(exposure)
}

fn integrate_global_region(
    request: ShutterRequest,
    region: SensorRegion,
    mut optical_at_time: impl FnMut(OpticalRequest) -> Result<LinearOpticalRaster, ApplicationError>,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    let samples = shutter_quadrature(
        request.optics.time,
        request.duration,
        request.temporal_samples,
    )?;
    let pixel_count = usize::from(region.width) * usize::from(region.height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for sample in samples {
        let mut optics = request.optics.clone();
        optics.time = sample.time;
        optics.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(
            optics
                .panel
                .temporal_emission
                .average_gain(sample.start, sample.end)
                .map_err(ApplicationError::Panel)?,
        );
        let raster = optical_at_time(optics)?;
        for (sum, pixel) in accumulated.iter_mut().zip(raster.pixels) {
            sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
            sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
            sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
        }
    }
    finish_integrated_exposure(
        region.width,
        region.height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

#[allow(clippy::too_many_arguments)]
fn integrate_rolling_region(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    readout_duration: RationalTime,
    direction: RollingDirection,
    mut optical_row_at_time: impl FnMut(
        OpticalRequest,
        u16,
    ) -> Result<Vec<LinearOpticalPixel>, ApplicationError>,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    if readout_duration.numerator() <= 0 {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let mut accumulated =
        vec![[0.0_f64; 3]; usize::from(region.width) * usize::from(region.height)];
    let frame_uniform_gains = frame_uniform_residual_gains(&request)?;
    for local_row in 0..usize::from(region.height) {
        let global_row = usize::from(region.origin_y) + local_row;
        let row_center = rolling_row_center_time(
            request.optics.time,
            readout_duration,
            global_row,
            usize::from(sensor.native_height),
            direction,
        )?;
        let samples = shutter_quadrature(row_center, request.duration, request.temporal_samples)?;
        for (sample_index, sample) in samples.into_iter().enumerate() {
            let mut optics = request.optics.clone();
            optics.time = sample.time;
            optics.panel_temporal_evaluation =
                PanelTemporalEvaluation::ExposureAverage(rolling_temporal_gain(
                    &request,
                    frame_uniform_gains.as_deref(),
                    sample_index,
                    sample,
                )?);
            let row = optical_row_at_time(optics, global_row as u16)?;
            if row.len() != usize::from(region.width) {
                return Err(ApplicationError::OpticalSampleRasterMismatch);
            }
            for (column, pixel) in row.into_iter().enumerate() {
                let sum = &mut accumulated[local_row * usize::from(region.width) + column];
                sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
                sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
                sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
            }
        }
    }
    finish_integrated_exposure(
        region.width,
        region.height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

fn crop_developed_region(
    developed: DevelopedCameraRegion,
    requested: SensorRegion,
) -> DevelopedCameraRegion {
    if developed.region == requested {
        return developed;
    }
    let offset_x = usize::from(requested.origin_x - developed.region.origin_x);
    let offset_y = usize::from(requested.origin_y - developed.region.origin_y);
    let source_width = usize::from(developed.region.width);
    let requested_width = usize::from(requested.width);
    let mut acescg = Vec::with_capacity(requested_width * usize::from(requested.height));
    for row in 0..usize::from(requested.height) {
        let start = (offset_y + row) * source_width + offset_x;
        acescg.extend_from_slice(&developed.acescg[start..start + requested_width]);
    }
    DevelopedCameraRegion {
        sensor_width: developed.sensor_width,
        sensor_height: developed.sensor_height,
        region: requested,
        acescg,
    }
}

fn finish_integrated_exposure(
    width: u16,
    height: u16,
    duration: RationalTime,
    neutral_density_stops: f32,
    accumulated: Vec<[f64; 3]>,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    let duration_seconds = duration.as_seconds();
    let photometric_scale = 2.0_f64.powf(-f64::from(neutral_density_stops));
    let acescg_illuminance_seconds = accumulated
        .into_iter()
        .map(|sum| {
            LinearRgb::new(
                (sum[0] * photometric_scale) as f32,
                (sum[1] * photometric_scale) as f32,
                (sum[2] * photometric_scale) as f32,
            )
        })
        .collect();
    let exposure = IntegratedOpticalExposure {
        width: u32::from(width),
        height: u32::from(height),
        duration_seconds: duration_seconds as f32,
        acescg_illuminance_seconds,
    };
    exposure.validate().map_err(ApplicationError::Sensor)?;
    Ok(exposure)
}

#[allow(clippy::too_many_arguments)]
fn integrate_rolling_shutter<F>(
    request: ShutterRequest,
    width: u16,
    height: u16,
    readout_duration: RationalTime,
    direction: RollingDirection,
    mut optical_row_at_time: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    F: FnMut(OpticalRequest, usize) -> Result<Vec<LinearOpticalPixel>, ApplicationError>,
{
    if width == 0 || height == 0 || readout_duration.numerator() <= 0 {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let frame_uniform_gains = frame_uniform_residual_gains(&request)?;
    let row_schedules = (0..usize::from(height))
        .map(|row| {
            let row_center = rolling_row_center_time(
                request.optics.time,
                readout_duration,
                row,
                usize::from(height),
                direction,
            )?;
            Ok((
                row,
                shutter_quadrature(row_center, request.duration, request.temporal_samples)?,
            ))
        })
        .collect::<Result<Vec<_>, ApplicationError>>()?;
    let pixel_count = usize::from(width) * usize::from(height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for (row, samples) in row_schedules {
        for (sample_index, sample) in samples.into_iter().enumerate() {
            let mut optics = request.optics.clone();
            optics.time = sample.time;
            optics.panel_temporal_evaluation =
                PanelTemporalEvaluation::ExposureAverage(rolling_temporal_gain(
                    &request,
                    frame_uniform_gains.as_deref(),
                    sample_index,
                    sample,
                )?);
            let optical_row = optical_row_at_time(optics, row)?;
            if optical_row.len() != usize::from(width) {
                return Err(ApplicationError::OpticalSampleRasterMismatch);
            }
            for (column, pixel) in optical_row.into_iter().enumerate() {
                let sum = &mut accumulated[row * usize::from(width) + column];
                sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
                sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
                sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
            }
        }
    }
    finish_integrated_exposure(
        width,
        height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

fn rolling_row_center_time(
    frame_center: RationalTime,
    readout_duration: RationalTime,
    row: usize,
    height: usize,
    direction: RollingDirection,
) -> Result<RationalTime, ApplicationError> {
    if height == 0 || row >= height || readout_duration.numerator() <= 0 {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let ordered_row = match direction {
        RollingDirection::TopToBottom => row,
        RollingDirection::BottomToTop => height - 1 - row,
    };
    let numerator = i64::try_from(ordered_row * 2 + 1)
        .map_err(|_| ApplicationError::InvalidSensorReadout)?
        - i64::try_from(height).map_err(|_| ApplicationError::InvalidSensorReadout)?;
    let denominator =
        u32::try_from(height * 2).map_err(|_| ApplicationError::InvalidSensorReadout)?;
    let offset = readout_duration
        .checked_mul_ratio(numerator, denominator)
        .map_err(ApplicationError::Time)?;
    frame_center
        .checked_add(offset)
        .map_err(ApplicationError::Time)
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct TemporalSample {
    start: RationalTime,
    time: RationalTime,
    end: RationalTime,
    weight_seconds: f64,
}

/// Residual LCD flicker is a frame-global emission modulation. It must not become a spatial
/// rolling-shutter band unless the explicit analytic-banding layer is enabled.
fn frame_uniform_residual_gains(
    request: &ShutterRequest,
) -> Result<Option<Vec<f32>>, ApplicationError> {
    if request
        .optics
        .panel
        .temporal_emission
        .analytic_banding
        .amount
        != 0.0
    {
        return Ok(None);
    }
    shutter_quadrature(
        request.optics.time,
        request.duration,
        request.temporal_samples,
    )?
    .into_iter()
    .map(|sample| {
        request
            .optics
            .panel
            .temporal_emission
            .average_gain(sample.start, sample.end)
            .map_err(ApplicationError::Panel)
    })
    .collect::<Result<Vec<_>, _>>()
    .map(Some)
}

fn rolling_temporal_gain(
    request: &ShutterRequest,
    frame_uniform_gains: Option<&[f32]>,
    sample_index: usize,
    sample: TemporalSample,
) -> Result<f32, ApplicationError> {
    if let Some(gains) = frame_uniform_gains {
        return gains
            .get(sample_index)
            .copied()
            .ok_or(ApplicationError::InvalidShutter);
    }
    request
        .optics
        .panel
        .temporal_emission
        .average_gain(sample.start, sample.end)
        .map_err(ApplicationError::Panel)
}

fn shutter_quadrature(
    center: RationalTime,
    duration: RationalTime,
    temporal_samples: u16,
) -> Result<Vec<TemporalSample>, ApplicationError> {
    let duration_seconds = duration.as_seconds();
    if duration.numerator() <= 0
        || !duration_seconds.is_finite()
        || duration_seconds <= 0.0
        || duration_seconds > f64::from(f32::MAX)
        || !(1..=64).contains(&temporal_samples)
    {
        return Err(ApplicationError::InvalidShutter);
    }
    let half_duration = duration
        .checked_mul_ratio(1, 2)
        .map_err(ApplicationError::Time)?;
    let open = center
        .checked_sub(half_duration)
        .map_err(ApplicationError::Time)?;
    let mut boundaries = Vec::with_capacity(usize::from(temporal_samples) + 1);
    for index in 0..=temporal_samples {
        let offset = duration
            .checked_mul_ratio(i64::from(index), u32::from(temporal_samples))
            .map_err(ApplicationError::Time)?;
        boundaries.push(open.checked_add(offset).map_err(ApplicationError::Time)?);
    }
    boundaries
        .windows(2)
        .map(|interval| {
            let width = interval[1]
                .checked_sub(interval[0])
                .map_err(ApplicationError::Time)?;
            let midpoint = interval[0]
                .checked_add(
                    width
                        .checked_mul_ratio(1, 2)
                        .map_err(ApplicationError::Time)?,
                )
                .map_err(ApplicationError::Time)?;
            Ok(TemporalSample {
                start: interval[0],
                time: midpoint,
                end: interval[1],
                weight_seconds: width.as_seconds(),
            })
        })
        .collect()
}

pub fn prepare_raster_from_device_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    source: &DeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<PreparedRaster, ApplicationError> {
    source.validate()?;
    let source_integral = DeviceSignalIntegral::new(source);
    let panel_evaluator = request
        .optics
        .panel
        .evaluator()
        .map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(source, panel_evaluator);
    let source_raster = [source.width, source.height];
    let device_raster = [
        request.optics.panel.native_width,
        request.optics.panel.native_height,
    ];
    prepare_raster_with_signal(
        request,
        width,
        height,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source_integral,
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

pub fn prepare_raster_from_prepared_device_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<PreparedRaster, ApplicationError> {
    let source_raster = source.raster_size();
    let panel_evaluator = request
        .optics
        .panel
        .evaluator()
        .map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
    let device_raster = [
        request.optics.panel.native_width,
        request.optics.panel.native_height,
    ];
    prepare_raster_with_signal(
        request,
        width,
        height,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

pub fn evaluate_linear_optics_from_device_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    source: &DeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<LinearOpticalRaster, ApplicationError> {
    source.validate()?;
    let source_integral = DeviceSignalIntegral::new(source);
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(source, panel_evaluator);
    let source_raster = [source.width, source.height];
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_raster_with_signal(
        request,
        width,
        height,
        DiagnosticView::Composite,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source_integral,
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

pub fn evaluate_linear_optics_from_prepared_device_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let source_raster = source.raster_size();
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_raster_with_signal(
        request,
        width,
        height,
        DiagnosticView::Composite,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

fn evaluate_linear_optics_region_from_prepared_device_signal(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let source_raster = source.raster_size();
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_window_with_signal(
        request,
        RasterWindow::from_sensor_region(sensor, region),
        DiagnosticView::Composite,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

/// Evaluates the modulation-free raster spatial pass with the scalar CPU implementation.
///
/// This is retained only as an oracle for backend conformance tests.
pub fn evaluate_device_signal_spatial_cpu_oracle(
    mut request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    request.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(1.0);
    evaluate_linear_optics_region_from_prepared_device_signal(
        request, sensor, region, source, placement,
    )
    .map(|raster| raster.pixels)
}

fn evaluate_device_signal_optical_sensor_row(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    global_row: u16,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let source_raster = source.raster_size();
    let device_raster = [request.panel.native_width, request.panel.native_height];
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
    let raster = evaluate_optical_window_with_signal(
        request,
        RasterWindow {
            full_width: sensor.native_width,
            full_height: sensor.native_height,
            origin_x: region.origin_x,
            origin_y: global_row,
            width: region.width,
            height: 1,
        },
        DiagnosticView::Composite,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )?;
    Ok(raster.pixels)
}

fn evaluate_procedural_optical_row(
    request: OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    evaluate_optical_row_with_signal(
        request.clone(),
        width,
        height,
        row,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
    )
}

fn evaluate_optical_row_from_prepared_device_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let source_raster = source.raster_size();
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_row_with_signal(
        request,
        width,
        height,
        row,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

fn evaluate_optical_row_with_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    if width == 0 || height == 0 || row >= usize::from(height) {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let frame = prepare_frame(request.clone())?;
    let raster_aspect = f32::from(width) / f32::from(height);
    if !raster_represents_viewport(width, height, frame.viewport_aspect) {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect,
            viewport_aspect: frame.viewport_aspect,
        });
    }
    let evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let cover_evaluator = request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let temporal_gain = panel_temporal_gain(&request, evaluator)?;
    let full_signal = signal_area(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
    let veiling_glare_gate_average = lens_veiling_gate_average(
        &request,
        frame,
        full_signal.linear_native_emission,
        raster_aspect,
        temporal_gain,
    )?;
    macro_rules! evaluate_row {
        ($sample_count:literal) => {
            (0..usize::from(width))
                .map(|column| {
                    evaluate_optical_pixel::<$sample_count>(
                        &frame,
                        &request,
                        width,
                        height,
                        row,
                        column,
                        DiagnosticView::Composite,
                        evaluator,
                        temporal_gain,
                        cover_evaluator,
                        signal_at,
                        signal_area,
                    )
                })
                .collect()
        };
    }
    let mut pixels: Vec<LinearOpticalPixel> =
        match aperture_sample_count(frame.camera, frame.screen, request.panel, width) {
            16 => evaluate_row!(16),
            32 => evaluate_row!(32),
            64 => evaluate_row!(64),
            128 => evaluate_row!(128),
            256 => evaluate_row!(256),
            512 => evaluate_row!(512),
            _ => unreachable!("aperture sample policy only emits supported quality levels"),
        };
    let fraction = frame.camera.lens.veiling_glare_fraction;
    if fraction != 0.0 {
        for pixel in &mut pixels {
            pixel.acescg_irradiance = LinearRgb::new(
                pixel.acescg_irradiance.r
                    + fraction * (veiling_glare_gate_average.r - pixel.acescg_irradiance.r),
                pixel.acescg_irradiance.g
                    + fraction * (veiling_glare_gate_average.g - pixel.acescg_irradiance.g),
                pixel.acescg_irradiance.b
                    + fraction * (veiling_glare_gate_average.b - pixel.acescg_irradiance.b),
            );
        }
    }
    Ok(pixels)
}

fn prepare_raster_with_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> Result<PreparedRaster, ApplicationError> {
    if !request.preview_exposure_ev.is_finite() {
        return Err(ApplicationError::InvalidPreviewExposure);
    }
    let linear = evaluate_optical_raster_with_signal(
        request.optical_request(),
        width,
        height,
        request.view,
        signal_at,
        signal_area,
    )?;
    let display = DiagnosticDisplayTransform {
        reference_white_nits: 100.0,
    };
    let preview_gain = if request.view == DiagnosticView::DeviceSignal {
        1.0
    } else {
        request.preview_exposure_ev.exp2()
    };
    let pixels = linear
        .pixels
        .iter()
        .map(|pixel| {
            let value = LinearRgb::new(
                pixel.acescg_irradiance.r * preview_gain,
                pixel.acescg_irradiance.g * preview_gain,
                pixel.acescg_irradiance.b * preview_gain,
            );
            PreviewPixel {
                rgb: if request.view == DiagnosticView::DeviceSignal {
                    PreviewRgb {
                        r: value.r,
                        g: value.g,
                        b: value.b,
                    }
                } else {
                    display.scene_linear_to_srgb(value)
                },
                on_panel: pixel.on_panel,
            }
        })
        .collect();
    Ok(PreparedRaster {
        frame: linear.frame,
        width: linear.width,
        height: linear.height,
        pixels,
        preview_scale_percent: linear.projected_device_pixel_percent,
        inspection_field_meters: linear.inspection_field_meters,
        subpixels_resolved_at_center: linear.subpixels_resolved_at_center,
    })
}

fn evaluate_optical_raster_with_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    view: DiagnosticView,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> Result<LinearOpticalRaster, ApplicationError> {
    evaluate_optical_window_with_signal(
        request,
        RasterWindow::full(width, height),
        view,
        signal_at,
        signal_area,
    )
}

fn evaluate_optical_window_with_signal(
    request: OpticalRequest,
    raster: RasterWindow,
    view: DiagnosticView,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> Result<LinearOpticalRaster, ApplicationError> {
    if raster.width == 0 || raster.height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let mut frame = prepare_frame(request.clone())?;
    let raster_aspect = f32::from(raster.full_width) / f32::from(raster.full_height);
    if !raster_represents_viewport(raster.full_width, raster.full_height, frame.viewport_aspect) {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect,
            viewport_aspect: frame.viewport_aspect,
        });
    }
    frame.representative_signal = signal_at(Vec2 { x: 0.5, y: 0.5 });
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let cover_evaluator = request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let panel_temporal_gain = panel_temporal_gain(&request, panel_evaluator)?;
    let representative = request.panel.emitted_radiance(frame.representative_signal);
    frame.representative_emission = LinearRgb::new(
        representative.r * panel_temporal_gain,
        representative.g * panel_temporal_gain,
        representative.b * panel_temporal_gain,
    );
    let full_signal = signal_area(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
    let veiling_glare_gate_average = lens_veiling_gate_average(
        &request,
        frame,
        full_signal.linear_native_emission,
        raster_aspect,
        panel_temporal_gain,
    )?;
    let preview_scale_percent =
        projected_device_pixel_width(&frame, request.panel, raster.full_width)
            .ok_or(ApplicationError::ViewRayMissesPanel)?
            * 100.0;
    let subpixels_resolved_at_center = optical_footprint_device_pixels(
        &frame,
        request.panel,
        raster.full_width,
        raster.full_height,
    )
    .is_some_and(|footprint| footprint[0] <= 1.0 / 3.0 && footprint[1] <= 1.0);
    let mut pixels = vec![
        LinearOpticalPixel {
            acescg_irradiance: LinearRgb::new(0.0, 0.0, 0.0),
            on_panel: false,
        };
        usize::from(raster.width) * usize::from(raster.height)
    ];
    match aperture_sample_count(frame.camera, frame.screen, request.panel, raster.full_width) {
        16 => evaluate_optical_pixels::<16>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        32 => evaluate_optical_pixels::<32>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        64 => evaluate_optical_pixels::<64>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        128 => evaluate_optical_pixels::<128>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        256 => evaluate_optical_pixels::<256>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        512 => evaluate_optical_pixels::<512>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        _ => unreachable!("aperture sample policy only emits supported quality levels"),
    }
    if view == DiagnosticView::Composite {
        let fraction = frame.camera.lens.veiling_glare_fraction;
        if fraction != 0.0 {
            for pixel in &mut pixels {
                pixel.acescg_irradiance = LinearRgb::new(
                    pixel.acescg_irradiance.r
                        + fraction * (veiling_glare_gate_average.r - pixel.acescg_irradiance.r),
                    pixel.acescg_irradiance.g
                        + fraction * (veiling_glare_gate_average.g - pixel.acescg_irradiance.g),
                    pixel.acescg_irradiance.b
                        + fraction * (veiling_glare_gate_average.b - pixel.acescg_irradiance.b),
                );
            }
        }
    }
    let inspection_field_meters = request.inspection.map(|region| {
        [
            (region.max.x - region.min.x) * request.panel.active_width.0,
            (region.max.y - region.min.y) * request.panel.active_height.0,
        ]
    });
    Ok(LinearOpticalRaster {
        frame,
        width: raster.width,
        height: raster.height,
        pixels,
        projected_device_pixel_percent: preview_scale_percent,
        inspection_field_meters,
        subpixels_resolved_at_center,
    })
}

fn panel_temporal_gain(
    request: &OpticalRequest,
    evaluator: ValidatedPanelEvaluator,
) -> Result<f32, ApplicationError> {
    match request.panel_temporal_evaluation {
        PanelTemporalEvaluation::Instantaneous => evaluator
            .temporal_gain(request.time)
            .map_err(ApplicationError::Panel),
        PanelTemporalEvaluation::ExposureAverage(gain) if gain.is_finite() && gain >= 0.0 => {
            Ok(gain)
        }
        PanelTemporalEvaluation::ExposureAverage(_) => Err(ApplicationError::InvalidShutter),
    }
}

fn raster_represents_viewport(width: u16, height: u16, viewport_aspect: f32) -> bool {
    let expected_width = f32::from(height) * viewport_aspect;
    (f32::from(width) - expected_width).abs() <= 0.5 + f32::EPSILON
}

#[allow(clippy::too_many_arguments)]
fn evaluate_optical_pixels<const SAMPLE_COUNT: usize>(
    pixels: &mut [LinearOpticalPixel],
    frame: &PreparedFrame,
    request: &OpticalRequest,
    raster: RasterWindow,
    view: DiagnosticView,
    panel_evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    cover_evaluator: ValidatedCoverEvaluator,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) {
    pixels
        .par_chunks_mut(usize::from(raster.width))
        .enumerate()
        .for_each(|(row, output_row)| {
            for (column, output) in output_row.iter_mut().enumerate() {
                *output = evaluate_optical_pixel::<SAMPLE_COUNT>(
                    frame,
                    request,
                    raster.full_width,
                    raster.full_height,
                    row + usize::from(raster.origin_y),
                    column + usize::from(raster.origin_x),
                    view,
                    panel_evaluator,
                    panel_temporal_gain,
                    cover_evaluator,
                    signal_at,
                    signal_area,
                );
            }
        });
}

pub fn aperture_sample_count(
    camera: CameraSample,
    screen: ScreenSample,
    panel: LcdProfile,
    raster_width: u16,
) -> usize {
    let forward = Vec3 {
        x: camera.target.x - camera.position.x,
        y: camera.target.y - camera.position.y,
        z: camera.target.z - camera.position.z,
    };
    let focal_length_meters = camera.focal_length.0 * 0.001;
    let sensor_width_meters = camera.sensor_width.0 * 0.001;
    let aperture_radius = focal_length_meters / (2.0 * camera.f_stop);
    let half_width = panel.active_width.0 * 0.5;
    let half_height = panel.active_height.0 * 0.5;
    let blur_radius_pixels = [
        Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        },
        Vec3 {
            x: -half_width,
            y: -half_height,
            z: 0.0,
        },
        Vec3 {
            x: half_width,
            y: -half_height,
            z: 0.0,
        },
        Vec3 {
            x: -half_width,
            y: half_height,
            z: 0.0,
        },
        Vec3 {
            x: half_width,
            y: half_height,
            z: 0.0,
        },
    ]
    .into_iter()
    .map(|local| screen.local_to_world(local))
    .map(|point| Vec3 {
        x: point.x - camera.position.x,
        y: point.y - camera.position.y,
        z: point.z - camera.position.z,
    })
    .map(|offset| {
        let distance = (offset.x * forward.x + offset.y * forward.y + offset.z * forward.z)
            .abs()
            .max(0.001);
        let relative_defocus = (1.0 - distance / camera.focus_distance.0).abs();
        let projected_pixel_width =
            distance * sensor_width_meters / focal_length_meters / f32::from(raster_width);
        aperture_radius * relative_defocus / projected_pixel_width
    })
    .fold(0.0_f32, f32::max);
    if blur_radius_pixels < 0.5 {
        16
    } else if blur_radius_pixels < 1.5 {
        32
    } else if blur_radius_pixels < 4.0 {
        64
    } else if blur_radius_pixels < 8.0 {
        128
    } else if blur_radius_pixels < 16.0 {
        256
    } else {
        512
    }
}

#[allow(clippy::too_many_arguments)]
fn evaluate_optical_pixel<const SAMPLE_COUNT: usize>(
    frame: &PreparedFrame,
    request: &OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
    column: usize,
    view: DiagnosticView,
    panel_evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    cover_evaluator: ValidatedCoverEvaluator,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> LinearOpticalPixel {
    const RESOLVED_SENSOR_BOX: [Vec2; 16] = [
        Vec2 { x: 0.125, y: 0.125 },
        Vec2 { x: 0.375, y: 0.125 },
        Vec2 { x: 0.625, y: 0.125 },
        Vec2 { x: 0.875, y: 0.125 },
        Vec2 { x: 0.125, y: 0.375 },
        Vec2 { x: 0.375, y: 0.375 },
        Vec2 { x: 0.625, y: 0.375 },
        Vec2 { x: 0.875, y: 0.375 },
        Vec2 { x: 0.125, y: 0.625 },
        Vec2 { x: 0.375, y: 0.625 },
        Vec2 { x: 0.625, y: 0.625 },
        Vec2 { x: 0.875, y: 0.625 },
        Vec2 { x: 0.125, y: 0.875 },
        Vec2 { x: 0.375, y: 0.875 },
        Vec2 { x: 0.625, y: 0.875 },
        Vec2 { x: 0.875, y: 0.875 },
    ];
    let trace = |offset: Vec2| {
        let viewport_ndc = Vec2 {
            x: (column as f32 + offset.x) / f32::from(width) * 2.0 - 1.0,
            y: (row as f32 + offset.y) / f32::from(height) * 2.0 - 1.0,
        };
        panel_uv_aperture_samples_boxed_with_count::<SAMPLE_COUNT>(
            frame.camera,
            frame.screen,
            request.panel.active_width,
            request.panel.active_height,
            viewport_ndc,
            0.0,
        )
    };
    let pixel_center_ndc = Vec2 {
        x: (column as f32 + 0.5) / f32::from(width) * 2.0 - 1.0,
        y: (row as f32 + 0.5) / f32::from(height) * 2.0 - 1.0,
    };
    let psf_radius = approximate_psf_radius_pixels(frame.camera, width, pixel_center_ndc)
        * request.lens_character_strength;
    let minimum = 0.001 - psf_radius;
    let maximum = 0.999 + psf_radius;
    let footprint_offsets = [
        Vec2 {
            x: minimum,
            y: minimum,
        },
        Vec2 {
            x: maximum,
            y: minimum,
        },
        Vec2 {
            x: minimum,
            y: maximum,
        },
        Vec2 {
            x: maximum,
            y: maximum,
        },
    ];
    let footprint = footprint_offsets.map(trace);
    if !subpixels_resolved_for_samples(&footprint, request.panel, cover_evaluator, view) {
        let integrated = integrate_aperture_samples(
            &footprint,
            view,
            request.panel,
            request.panel_character_strength,
            panel_evaluator,
            panel_temporal_gain,
            signal_at,
            signal_area,
            cover_evaluator,
        );
        return integrated;
    }
    let aperture_samples = RESOLVED_SENSOR_BOX
        .map(|offset| expand_sensor_footprint(offset, psf_radius))
        .map(trace);
    integrate_aperture_samples(
        &aperture_samples,
        view,
        request.panel,
        request.panel_character_strength,
        panel_evaluator,
        panel_temporal_gain,
        signal_at,
        signal_area,
        cover_evaluator,
    )
}

fn expand_sensor_footprint(offset: Vec2, psf_radius_pixels: f32) -> Vec2 {
    let disk = concentric_disk_sample(offset);
    Vec2 {
        x: offset.x + disk.x * psf_radius_pixels,
        y: offset.y + disk.y * psf_radius_pixels,
    }
}

fn physical_psf_disk_sample(index: usize) -> Vec2 {
    const POINTS: [f32; 4] = [0.125, 0.375, 0.625, 0.875];
    concentric_disk_sample(Vec2 {
        x: POINTS[index % 4],
        y: POINTS[index / 4],
    })
}

fn concentric_disk_sample(sample: Vec2) -> Vec2 {
    let x = 2.0 * sample.x - 1.0;
    let y = 2.0 * sample.y - 1.0;
    if x == 0.0 && y == 0.0 {
        return Vec2 { x: 0.0, y: 0.0 };
    }
    let (radius, angle) = if x.abs() > y.abs() {
        (x, core::f32::consts::FRAC_PI_4 * (y / x))
    } else {
        (
            y,
            core::f32::consts::FRAC_PI_2 - core::f32::consts::FRAC_PI_4 * (x / y),
        )
    };
    Vec2 {
        x: radius * angle.cos(),
        y: radius * angle.sin(),
    }
}

fn approximate_psf_radius_pixels(
    camera: CameraSample,
    raster_width: u16,
    viewport_ndc: Vec2,
) -> f32 {
    const GREEN_WAVELENGTH_MM: f32 = 0.000_550;
    let photosite_pitch_mm = camera.sensor_width.0 / f32::from(raster_width);
    let airy_radius_mm = 1.22 * GREEN_WAVELENGTH_MM * camera.f_stop;
    let field_amount =
        ((viewport_ndc.x * viewport_ndc.x + viewport_ndc.y * viewport_ndc.y) * 0.5).clamp(0.0, 1.0);
    let lens_softness_micrometers = camera.lens.center_softness_micrometers
        + (camera.lens.edge_softness_micrometers - camera.lens.center_softness_micrometers)
            * field_amount;
    let lens_softness_mm = lens_softness_micrometers * 0.001;
    (lens_softness_mm + airy_radius_mm) / photosite_pitch_mm
}

#[allow(clippy::too_many_arguments)]
fn integrate_aperture_samples(
    spatial_samples: &[Box<[OpticalSample]>],
    view: DiagnosticView,
    panel: LcdProfile,
    panel_character_strength: f32,
    evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
    cover: ValidatedCoverEvaluator,
) -> LinearOpticalPixel {
    let sample_count = spatial_samples.first().map_or(0, |samples| samples.len());
    debug_assert!(
        sample_count > 0
            && spatial_samples
                .iter()
                .all(|samples| samples.len() == sample_count)
    );
    let subpixels_resolved = subpixels_resolved_for_samples(spatial_samples, panel, cover, view);
    const GLOW_ROTATION_TURNS: f32 = 0.381_966_02;
    let neutral_glow_samples = screen_cover::CoverGlowProfile::NEUTRAL
        .samples()
        .expect("neutral cover glow is valid");
    let mut sum = LinearRgb::new(0.0, 0.0, 0.0);
    let mut on_panel = false;
    let reflected = reflected_environment_average(spatial_samples, view, cover);
    if !subpixels_resolved {
        for aperture in 0..sample_count {
            for channel in 0..3 {
                let mut minimum = Vec2 {
                    x: f32::INFINITY,
                    y: f32::INFINITY,
                };
                let mut maximum = Vec2 {
                    x: f32::NEG_INFINITY,
                    y: f32::NEG_INFINITY,
                };
                let mut weight_sum = 0.0;
                let mut count = 0;
                for spatial in spatial_samples {
                    let optical = spatial[aperture];
                    let Some(uv) = transmitted_panel_uv(cover, optical, panel, view, channel)
                    else {
                        continue;
                    };
                    minimum.x = minimum.x.min(uv.x);
                    minimum.y = minimum.y.min(uv.y);
                    maximum.x = maximum.x.max(uv.x);
                    maximum.y = maximum.y.max(uv.y);
                    weight_sum += optical_channel_weight(
                        optical,
                        evaluator,
                        panel_temporal_gain,
                        view,
                        channel,
                    ) * cover_transmission_channel(cover, optical, view, channel);
                    count += 1;
                }
                if count == 0 {
                    continue;
                }
                let glow_samples = if view == DiagnosticView::Composite {
                    cover.glow_samples_rotated(aperture as f32 * GLOW_ROTATION_TURNS)
                } else {
                    neutral_glow_samples
                };
                for glow in glow_samples {
                    let offset = Vec2 {
                        x: glow.offset_meters[0] / panel.active_width.0,
                        y: glow.offset_meters[1] / panel.active_height.0,
                    };
                    let shifted_minimum = Vec2 {
                        x: (minimum.x + offset.x).clamp(0.0, 1.0),
                        y: (minimum.y + offset.y).clamp(0.0, 1.0),
                    };
                    let shifted_maximum = Vec2 {
                        x: (maximum.x + offset.x).clamp(0.0, 1.0),
                        y: (maximum.y + offset.y).clamp(0.0, 1.0),
                    };
                    if shifted_minimum.x >= shifted_maximum.x
                        || shifted_minimum.y >= shifted_maximum.y
                    {
                        continue;
                    }
                    on_panel = true;
                    let signal = signal_area(shifted_minimum, shifted_maximum);
                    let value = if view == DiagnosticView::DeviceSignal {
                        [
                            signal.device_code.r,
                            signal.device_code.g,
                            signal.device_code.b,
                        ][channel]
                    } else {
                        let ideal = [
                            signal.linear_native_emission.r,
                            signal.linear_native_emission.g,
                            signal.linear_native_emission.b,
                        ][channel];
                        let physical = evaluator.linear_native_channel_over_device_rect(
                            ideal,
                            Vec2 {
                                x: shifted_minimum.x * panel.native_width as f32,
                                y: shifted_minimum.y * panel.native_height as f32,
                            },
                            Vec2 {
                                x: shifted_maximum.x * panel.native_width as f32,
                                y: shifted_maximum.y * panel.native_height as f32,
                            },
                            channel,
                        );
                        (ideal + panel_character_strength * (physical - ideal)).max(0.0)
                    };
                    let contribution =
                        value * weight_sum * glow.weight / spatial_samples.len() as f32;
                    match channel {
                        0 => sum.r += contribution,
                        1 => sum.g += contribution,
                        _ => sum.b += contribution,
                    }
                }
            }
        }
        let scale = 1.0 / sample_count as f32;
        let native_average = LinearRgb::new(sum.r * scale, sum.g * scale, sum.b * scale);
        return LinearOpticalPixel {
            acescg_irradiance: if view == DiagnosticView::DeviceSignal {
                native_average
            } else {
                let emitted = evaluator.native_to_acescg(native_average);
                LinearRgb::new(
                    emitted.r + reflected.r,
                    emitted.g + reflected.g,
                    emitted.b + reflected.b,
                )
            },
            on_panel,
        };
    }
    for (optical_index, optical_sample) in spatial_samples
        .iter()
        .flat_map(|samples| samples.iter())
        .enumerate()
    {
        let aperture = optical_index % sample_count;
        let glow_samples = if view == DiagnosticView::Composite {
            cover.glow_samples_rotated(aperture as f32 * GLOW_ROTATION_TURNS)
        } else {
            neutral_glow_samples
        };
        for channel in 0..3 {
            let Some(uv) = transmitted_panel_uv(cover, *optical_sample, panel, view, channel)
            else {
                continue;
            };
            let optical_weight =
                optical_channel_weight(
                    *optical_sample,
                    evaluator,
                    panel_temporal_gain,
                    view,
                    channel,
                ) * cover_transmission_channel(cover, *optical_sample, view, channel);
            for glow in glow_samples {
                let shifted_uv = Vec2 {
                    x: uv.x + glow.offset_meters[0] / panel.active_width.0,
                    y: uv.y + glow.offset_meters[1] / panel.active_height.0,
                };
                if !(0.0..=1.0).contains(&shifted_uv.x) || !(0.0..=1.0).contains(&shifted_uv.y) {
                    continue;
                }
                on_panel = true;
                let signal = signal_at(shifted_uv);
                let value = match view {
                    DiagnosticView::DeviceSignal => [signal.r, signal.g, signal.b][channel],
                    DiagnosticView::Composite
                    | DiagnosticView::EmittedRadiance
                    | DiagnosticView::Subpixels
                        if subpixels_resolved =>
                    {
                        let pixel_uv = Vec2 {
                            x: (shifted_uv.x * panel.native_width as f32).fract(),
                            y: (shifted_uv.y * panel.native_height as f32).fract(),
                        };
                        let ideal = evaluator.native_channel(signal, channel);
                        let physical = evaluator.native_channel_at_pixel(signal, pixel_uv, channel);
                        (ideal + panel_character_strength * (physical - ideal)).max(0.0)
                    }
                    DiagnosticView::Composite
                    | DiagnosticView::EmittedRadiance
                    | DiagnosticView::Subpixels => evaluator.native_channel(signal, channel),
                };
                let weighted = value * optical_weight * glow.weight;
                match channel {
                    0 => sum.r += weighted,
                    1 => sum.g += weighted,
                    _ => sum.b += weighted,
                }
            }
        }
    }
    let scale = 1.0 / (sample_count * spatial_samples.len()) as f32;
    let native_average = LinearRgb::new(sum.r * scale, sum.g * scale, sum.b * scale);
    let average = if view == DiagnosticView::DeviceSignal {
        native_average
    } else {
        let emitted = evaluator.native_to_acescg(native_average);
        LinearRgb::new(
            emitted.r + reflected.r,
            emitted.g + reflected.g,
            emitted.b + reflected.b,
        )
    };
    LinearOpticalPixel {
        acescg_irradiance: average,
        on_panel,
    }
}

fn cover_transmission_channel(
    cover: ValidatedCoverEvaluator,
    optical: OpticalSample,
    view: DiagnosticView,
    channel: usize,
) -> f32 {
    if view != DiagnosticView::Composite {
        return 1.0;
    }
    let transmission = cover.transmission(optical.emission_cosine[channel]);
    [transmission.r, transmission.g, transmission.b][channel]
}

fn transmitted_panel_uv(
    cover: ValidatedCoverEvaluator,
    optical: OpticalSample,
    panel: LcdProfile,
    view: DiagnosticView,
    channel: usize,
) -> Option<Vec2> {
    let uv = optical.panel_uv[channel]?;
    if view != DiagnosticView::Composite {
        return Some(uv);
    }
    let direction = optical.reflection_direction_local[channel]?;
    let offset = cover.transmitted_lateral_offset_meters([direction.x, direction.y, direction.z]);
    Some(Vec2 {
        x: uv.x + offset[0] / panel.active_width.0,
        y: uv.y - offset[1] / panel.active_height.0,
    })
}

fn reflected_environment_average(
    spatial_samples: &[Box<[OpticalSample]>],
    view: DiagnosticView,
    cover: ValidatedCoverEvaluator,
) -> LinearRgb {
    if view != DiagnosticView::Composite {
        return LinearRgb::new(0.0, 0.0, 0.0);
    }
    let mut sum = [0.0_f32; 3];
    for optical in spatial_samples.iter().flat_map(|samples| samples.iter()) {
        for channel in 0..3 {
            let Some(_uv) = optical.panel_uv[channel]
                .filter(|uv| (0.0..=1.0).contains(&uv.x) && (0.0..=1.0).contains(&uv.y))
            else {
                continue;
            };
            let Some(direction) = optical.reflection_direction_local[channel] else {
                continue;
            };
            let reflected = cover.reflected_illuminance(CoverSurfaceSample {
                view_cosine: optical.emission_cosine[channel],
                reflection_direction_local: [direction.x, direction.y, direction.z],
                lens_irradiance_weight: LinearRgb::new(
                    optical.irradiance_weight[0],
                    optical.irradiance_weight[1],
                    optical.irradiance_weight[2],
                ),
            });
            sum[channel] += [reflected.r, reflected.g, reflected.b][channel];
        }
    }
    let sample_count = spatial_samples.first().map_or(0, |samples| samples.len());
    let scale = 1.0 / (sample_count * spatial_samples.len()) as f32;
    LinearRgb::new(sum[0] * scale, sum[1] * scale, sum[2] * scale)
}

fn optical_channel_weight(
    optical: OpticalSample,
    evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    view: DiagnosticView,
    channel: usize,
) -> f32 {
    if view == DiagnosticView::DeviceSignal {
        return 1.0;
    }
    optical.irradiance_weight[channel]
        * evaluator.angular_channel(optical.emission_cosine[channel], channel)
        * panel_temporal_gain
}

fn subpixels_resolved_for_samples(
    spatial_samples: &[Box<[OpticalSample]>],
    panel: LcdProfile,
    cover: ValidatedCoverEvaluator,
    view: DiagnosticView,
) -> bool {
    (0..3).all(|channel| {
        let mut minimum = Vec2 {
            x: f32::INFINITY,
            y: f32::INFINITY,
        };
        let mut maximum = Vec2 {
            x: f32::NEG_INFINITY,
            y: f32::NEG_INFINITY,
        };
        let mut count = 0;
        for uv in spatial_samples
            .iter()
            .flat_map(|samples| samples.iter())
            .filter_map(|sample| transmitted_panel_uv(cover, *sample, panel, view, channel))
        {
            minimum.x = minimum.x.min(uv.x);
            minimum.y = minimum.y.min(uv.y);
            maximum.x = maximum.x.max(uv.x);
            maximum.y = maximum.y.max(uv.y);
            count += 1;
        }
        count > 0
            && (maximum.x - minimum.x) * panel.native_width as f32 <= 1.0 / 3.0
            && (maximum.y - minimum.y) * panel.native_height as f32 <= 1.0
    })
}

pub fn inspection_region_from_drag(
    request: SimulationRequest,
    start_ndc: Vec2,
    end_ndc: Vec2,
) -> Result<PanelRegion, ApplicationError> {
    let frame = prepare_frame(request.optical_request())?;
    let intersect = |point| {
        panel_uv_at_viewport(
            frame.camera,
            frame.screen,
            request.optics.panel.active_width,
            request.optics.panel.active_height,
            request.optics.viewport_aspect,
            point,
        )
        .ok_or(ApplicationError::ViewRayMissesPanel)
    };
    let start = intersect(start_ndc)?;
    if !(0.0..=1.0).contains(&start.x) || !(0.0..=1.0).contains(&start.y) {
        return Err(ApplicationError::InspectionMustStartOnPanel);
    }
    let end = intersect(end_ndc)?;
    let region = PanelRegion {
        min: Vec2 {
            x: start.x.min(end.x),
            y: start.y.min(end.y),
        },
        max: Vec2 {
            x: start.x.max(end.x),
            y: start.y.max(end.y),
        },
    };
    region.validate().map_err(ApplicationError::Geometry)
}

fn projected_device_pixel_width(
    frame: &PreparedFrame,
    panel: LcdProfile,
    preview_width: u16,
) -> Option<f32> {
    let center_uv = frame
        .inspection
        .map_or(Vec2 { x: 0.5, y: 0.5 }, |region| Vec2 {
            x: (region.min.x + region.max.x) * 0.5,
            y: (region.min.y + region.max.y) * 0.5,
        });
    let point = |uv: Vec2| {
        frame.screen.local_to_world(Vec3 {
            x: (uv.x - 0.5) * panel.active_width.0,
            y: (0.5 - uv.y) * panel.active_height.0,
            z: 0.0,
        })
    };
    let first = project_scene_point(frame.camera, point(center_uv), frame.viewport_aspect)?;
    let second = project_scene_point(
        frame.camera,
        point(Vec2 {
            x: center_uv.x + 1.0 / panel.native_width as f32,
            y: center_uv.y,
        }),
        frame.viewport_aspect,
    )?;
    Some((second.x - first.x).hypot(second.y - first.y) * f32::from(preview_width) * 0.5)
}

fn optical_footprint_device_pixels(
    frame: &PreparedFrame,
    panel: LcdProfile,
    preview_width: u16,
    preview_height: u16,
) -> Option<[f32; 2]> {
    let positions = [
        Vec2 { x: 0.0, y: 0.0 },
        Vec2 {
            x: 2.0 / f32::from(preview_width),
            y: 0.0,
        },
        Vec2 {
            x: 0.0,
            y: 2.0 / f32::from(preview_height),
        },
    ];
    let mut minimum = [Vec2 {
        x: f32::INFINITY,
        y: f32::INFINITY,
    }; 3];
    let mut maximum = [Vec2 {
        x: f32::NEG_INFINITY,
        y: f32::NEG_INFINITY,
    }; 3];
    let mut count = 0;
    for sample in positions.into_iter().flat_map(|position| {
        panel_uv_aperture_samples(
            frame.camera,
            frame.screen,
            panel.active_width,
            panel.active_height,
            position,
            0.0,
        )
    }) {
        for (channel, uv) in sample.panel_uv.into_iter().enumerate() {
            if let Some(uv) = uv {
                minimum[channel].x = minimum[channel].x.min(uv.x);
                minimum[channel].y = minimum[channel].y.min(uv.y);
                maximum[channel].x = maximum[channel].x.max(uv.x);
                maximum[channel].y = maximum[channel].y.max(uv.y);
                count += 1;
            }
        }
    }
    (count > 0).then_some([
        (0..3)
            .map(|channel| (maximum[channel].x - minimum[channel].x) * panel.native_width as f32)
            .fold(0.0, f32::max),
        (0..3)
            .map(|channel| (maximum[channel].y - minimum[channel].y) * panel.native_height as f32)
            .fold(0.0, f32::max),
    ])
}

/// Current vertical-slice device signal. This is explicit authored diagnostic content,
/// not a media fallback and not reachable from media decoding.
pub fn diagnostic_signal(
    pattern: ProceduralTestPattern,
    uv: Vec2,
    time: RationalTime,
) -> DeviceRgb {
    match pattern {
        ProceduralTestPattern::AnimatedCheckerboard => checkerboard_signal(uv, time),
        ProceduralTestPattern::EyeChart => eye_chart_signal(uv),
        ProceduralTestPattern::PhotometricDeviceScale => photometric_device_scale_signal(uv),
    }
}

fn photometric_device_scale_signal(uv: Vec2) -> DeviceRgb {
    let patch = ((uv.x.clamp(0.0, 1.0 - f32::EPSILON) * PHOTOMETRIC_DEVICE_CODES.len() as f32)
        .floor() as usize)
        .min(PHOTOMETRIC_DEVICE_CODES.len() - 1);
    let code = PHOTOMETRIC_DEVICE_CODES[patch];
    DeviceRgb::new(code, code, code)
}

fn checkerboard_signal(uv: Vec2, time: RationalTime) -> DeviceRgb {
    let pulse = (time.as_seconds() as f32 * 0.8).sin() * 0.5 + 0.5;
    let grid_x = (uv.x * 12.0).floor() as i32;
    let grid_y = (uv.y * 8.0).floor() as i32;
    let checker = if (grid_x + grid_y) % 2 == 0 {
        0.18
    } else {
        0.06
    };
    let glow = (1.0 - ((uv.x - 0.5).hypot(uv.y - 0.5) * 1.8)).max(0.0);
    DeviceRgb::new(
        checker + glow * (0.45 + pulse * 0.25),
        checker + glow * (0.18 + (1.0 - pulse) * 0.18),
        checker + glow * 0.75,
    )
}

fn eye_chart_signal(uv: Vec2) -> DeviceRgb {
    const ROWS: [(f32, f32, u8); 7] = [
        (0.14, 0.18, 1),
        (0.31, 0.13, 2),
        (0.45, 0.095, 3),
        (0.57, 0.072, 4),
        (0.67, 0.055, 5),
        (0.76, 0.043, 6),
        (0.84, 0.034, 7),
    ];
    for (row, (center_y, size, count)) in ROWS.into_iter().enumerate() {
        let spacing = size * 1.45;
        let first_x = 0.5 - spacing * (f32::from(count) - 1.0) * 0.5;
        for column in 0..count {
            let center_x = first_x + spacing * f32::from(column);
            let mut local_x = (uv.x - center_x) / size;
            let mut local_y = (uv.y - center_y) / size;
            match (row + usize::from(column)) % 4 {
                1 => (local_x, local_y) = (-local_y, local_x),
                2 => (local_x, local_y) = (-local_x, -local_y),
                3 => (local_x, local_y) = (local_y, -local_x),
                _ => {}
            }
            let vertical = (-0.5..=-0.28).contains(&local_x) && (-0.5..=0.5).contains(&local_y);
            let horizontal = (-0.5..=0.5).contains(&local_x)
                && ((-0.5..=-0.30).contains(&local_y)
                    || (-0.10..=0.10).contains(&local_y)
                    || (0.30..=0.5).contains(&local_y));
            if vertical || horizontal {
                return DeviceRgb::BLACK;
            }
        }
    }
    DeviceRgb::WHITE
}

fn diagnostic_area_signal(
    pattern: ProceduralTestPattern,
    minimum: Vec2,
    maximum: Vec2,
    time: RationalTime,
    evaluator: ValidatedPanelEvaluator,
) -> AreaSignalSample {
    const OFFSETS: [f32; 4] = [0.125, 0.375, 0.625, 0.875];
    let mut sum = DeviceRgb::BLACK;
    let mut linear_sum = LinearRgb::new(0.0, 0.0, 0.0);
    for y in OFFSETS {
        for x in OFFSETS {
            let uv = Vec2 {
                x: minimum.x + (maximum.x - minimum.x) * x,
                y: minimum.y + (maximum.y - minimum.y) * y,
            };
            let value = diagnostic_signal(pattern, uv, time);
            sum.r += value.r;
            sum.g += value.g;
            sum.b += value.b;
            linear_sum.r += evaluator.native_channel(value, 0);
            linear_sum.g += evaluator.native_channel(value, 1);
            linear_sum.b += evaluator.native_channel(value, 2);
        }
    }
    AreaSignalSample {
        device_code: DeviceRgb::new(sum.r / 16.0, sum.g / 16.0, sum.b / 16.0),
        linear_native_emission: LinearRgb::new(
            linear_sum.r / 16.0,
            linear_sum.g / 16.0,
            linear_sum.b / 16.0,
        ),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ApplicationError {
    InvalidViewportAspect,
    InvalidCharacterStrength,
    UnsupportedPhysicalIntermediate,
    InvalidPreviewExposure,
    InvalidShutter,
    InvalidSensorReadout,
    InvalidOpticalAttenuation,
    InvalidRadiometricCalibration(&'static str),
    OpticalSampleRasterMismatch,
    SensorViewportAspectMismatch {
        sensor_aspect: f32,
        viewport_aspect: f32,
    },
    RasterViewportAspectMismatch {
        raster_aspect: f32,
        viewport_aspect: f32,
    },
    EmptyPreviewRaster,
    InspectionMustStartOnPanel,
    ViewRayMissesPanel,
    EmptyDeviceSignalRaster,
    NonFiniteDeviceSignal,
    DeviceSignalPixelCountMismatch {
        expected: u64,
        actual: u64,
    },
    DecodedPixelCountMismatch {
        expected: u64,
        actual: u64,
    },
    DecodedPixelStorageTooLarge,
    MediaSampleUnavailable,
    AlphaAssociationUnresolved,
    Color(ColorError),
    Panel(PanelError),
    Cover(CoverError),
    Geometry(GeometryError),
    Sensor(SensorError),
    CameraDevelopment(CameraDevelopmentError),
    NativeBackend(String),
    Time(ContractError),
}

impl fmt::Display for ApplicationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidViewportAspect => formatter.write_str("viewport aspect must be positive"),
            Self::InvalidCharacterStrength => formatter.write_str(
                "physical pipeline amounts must be finite and remain in the supported [0, 4] range",
            ),
            Self::UnsupportedPhysicalIntermediate => formatter
                .write_str("requested physical intermediate belongs to an unsupported stage"),
            Self::InvalidPreviewExposure => {
                formatter.write_str("preview exposure EV must be finite")
            }
            Self::InvalidShutter => formatter.write_str(
                "shutter duration must be positive and motion samples must be in [1, 64]",
            ),
            Self::InvalidSensorReadout => formatter.write_str(
                "sensor readout duration and row coordinates must define a valid shutter interval",
            ),
            Self::InvalidOpticalAttenuation => formatter
                .write_str("neutral-density attenuation must be finite and in [0, 16] stops"),
            Self::InvalidRadiometricCalibration(reason) => {
                write!(
                    formatter,
                    "invalid camera radiometric calibration: {reason}"
                )
            }
            Self::OpticalSampleRasterMismatch => formatter
                .write_str("all temporal optical samples must match the authored sensor raster"),
            Self::SensorViewportAspectMismatch {
                sensor_aspect,
                viewport_aspect,
            } => write!(
                formatter,
                "sensor aspect {sensor_aspect:.6} does not match authored viewport aspect {viewport_aspect:.6}"
            ),
            Self::RasterViewportAspectMismatch {
                raster_aspect,
                viewport_aspect,
            } => write!(
                formatter,
                "raster aspect {raster_aspect:.6} does not match authored viewport aspect {viewport_aspect:.6}"
            ),
            Self::EmptyPreviewRaster => formatter.write_str("preview raster must be non-empty"),
            Self::InspectionMustStartOnPanel => {
                formatter.write_str("inspection selection must start on the panel")
            }
            Self::ViewRayMissesPanel => {
                formatter.write_str("camera ray does not reach the panel plane")
            }
            Self::EmptyDeviceSignalRaster => {
                formatter.write_str("device signal raster must be non-empty")
            }
            Self::NonFiniteDeviceSignal => {
                formatter.write_str("device signal raster must contain only finite RGB values")
            }
            Self::DeviceSignalPixelCountMismatch { expected, actual } => write!(
                formatter,
                "device signal raster has {actual} pixels but requires {expected}"
            ),
            Self::DecodedPixelCountMismatch { expected, actual } => write!(
                formatter,
                "decoded source has {actual} pixels but requires {expected}"
            ),
            Self::DecodedPixelStorageTooLarge => {
                formatter.write_str("decoded source is too large for RGBA color processing")
            }
            Self::MediaSampleUnavailable => {
                formatter.write_str("media sample is unavailable at the requested exact time")
            }
            Self::AlphaAssociationUnresolved => formatter.write_str(
                "alpha metadata does not identify Straight or Premultiplied association",
            ),
            Self::Color(error) => write!(formatter, "invalid color transform: {error}"),
            Self::Panel(error) => write!(formatter, "invalid panel: {error}"),
            Self::Cover(error) => write!(formatter, "invalid optical cover: {error}"),
            Self::Geometry(error) => write!(formatter, "invalid camera: {error}"),
            Self::Sensor(error) => write!(formatter, "invalid sensor capture: {error}"),
            Self::CameraDevelopment(error) => write!(formatter, "camera development: {error}"),
            Self::NativeBackend(error) => write!(formatter, "native compute backend: {error}"),
            Self::Time(error) => write!(formatter, "invalid capture time: {error}"),
        }
    }
}

impl std::error::Error for ApplicationError {}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_color::{
        ColorEngine, DeviceColorTarget, OcioInputTransform, SourceColorInterpretation,
    };
    use screen_contracts::{Meters, Millimeters};
    use screen_cover::{COVER_GLASS_PRESETS, cover_glass_preset, environment_preset};
    use screen_geometry::lens_preset;
    use screen_panel::{AnalyticBanding, PanelTemporalEmission};
    use screen_panel::{DEVICE_PRESETS, PanelColorimetry, StripeLayout, device_preset};
    use std::collections::HashSet;
    use std::convert::Infallible;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn image_environment_roughness_owns_a_resolution_independent_angular_footprint() {
        assert_eq!(environment_reflection_footprint_texels(4096, 0.0, 0.0), 1.0);

        let semigloss = environment_reflection_footprint_texels(4096, 0.20, 0.0);
        let matte = environment_reflection_footprint_texels(4096, 0.46, 0.0);
        let matte_haze = environment_reflection_footprint_texels(4096, 0.46, 0.03);
        assert!(semigloss > 1.0);
        assert!(matte > semigloss);
        assert!(matte_haze > matte);

        let half_resolution = environment_reflection_footprint_texels(2048, 0.46, 0.03);
        assert!((half_resolution / 2048.0 - matte_haze / 4096.0).abs() < 1.0e-7);
    }

    #[test]
    fn image_environment_roughness_preserves_uniform_incident_radiance() {
        let raster = EnvironmentRadianceRaster {
            width: 8,
            height: 4,
            rgba: vec![[4.0, 2.0, 0.5, 1.0]; 32],
        };
        for (roughness, haze) in [(0.0, 0.0), (0.46, 0.03), (1.0, 1.0)] {
            assert_eq!(
                raster.sample_equirectangular([0.3, -0.2, 0.9], 37.0, roughness, haze),
                LinearRgb::new(4.0, 2.0, 0.5)
            );
        }
    }

    #[test]
    fn complete_physical_pipeline_uses_one_coherent_direct_32_ray_pupil_policy() {
        for quality in [
            FlatPanelQuality::Draft,
            FlatPanelQuality::Medium,
            FlatPanelQuality::High,
            FlatPanelQuality::Native,
        ] {
            assert_eq!(physical_pipeline_aperture_sample_count(quality), 32);
        }
    }

    struct UnitSpatialBackend {
        last_batch_size: AtomicUsize,
    }

    impl SpatialOpticalBackend for UnitSpatialBackend {
        type Error = Infallible;

        fn evaluate_spatial(
            &self,
            plan: &SpatialOpticalPlan,
        ) -> Result<Vec<LinearOpticalPixel>, Self::Error> {
            Ok(vec![
                LinearOpticalPixel {
                    acescg_irradiance: LinearRgb::new(1.0, 1.0, 1.0),
                    on_panel: true,
                };
                usize::from(plan.raster.width)
                    * usize::from(plan.raster.height)
            ])
        }

        fn evaluate_spatial_batch(
            &self,
            plans: &[SpatialOpticalPlan],
        ) -> Result<Vec<Vec<LinearOpticalPixel>>, Self::Error> {
            self.last_batch_size.store(plans.len(), Ordering::Relaxed);
            plans
                .iter()
                .map(|plan| self.evaluate_spatial(plan))
                .collect()
        }
    }

    fn request() -> SimulationRequest {
        SimulationRequest {
            optics: OpticalRequest {
                time: RationalTime::new(24, 24).expect("valid time"),
                panel_temporal_evaluation: PanelTemporalEvaluation::Instantaneous,
                panel_character_strength: 1.0,
                lens_character_strength: 1.0,
                viewport_aspect: 16.0 / 9.0,
                panel: LcdProfile {
                    native_width: 1920,
                    native_height: 1080,
                    active_width: Meters(0.531),
                    active_height: Meters(0.299),
                    stripe_layout: StripeLayout::Rgb,
                    black_matrix_fraction: 0.1,
                    eotf_gamma: 2.2,
                    black_level_nits: 0.05,
                    white_level_nits: 500.0,
                    colorimetry: PanelColorimetry::SRGB_D65,
                    angular_emission_power: LinearRgb::new(1.7, 1.5, 1.8),
                    temporal_emission: PanelTemporalEmission::continuous(),
                },
                cover: CoverGlassProfile::NEUTRAL,
                environment: ProceduralEnvironment::NONE,
                camera: CameraRig {
                    transform: screen_geometry::TransformTrack {
                        keyframes: vec![screen_geometry::TransformKeyframe {
                            id: "camera-transform-0".to_owned(),
                            time: RationalTime::new(0, 24).expect("valid time"),
                            translation: Vec3 {
                                x: 0.0,
                                y: 0.0,
                                z: 0.8,
                            },
                            rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                            interpolation: screen_geometry::KeyframeInterpolation::Smooth,
                        }],
                    },
                    intrinsics: screen_geometry::CameraIntrinsicsTrack {
                        keyframes: vec![screen_geometry::CameraIntrinsicsKeyframe {
                            id: "camera-intrinsics-0".to_owned(),
                            time: RationalTime::new(0, 24).expect("valid time"),
                            focal_length: Millimeters(50.0),
                            sensor_width: Millimeters(36.0),
                            sensor_height: Millimeters(20.25),
                            lens_shift: Vec2 { x: 0.0, y: 0.0 },
                            focus_distance: Meters(0.8),
                            f_stop: 8.0,
                            near_clip: Meters(0.01),
                            far_clip: Meters(100.0),
                            lens: screen_geometry::LensModel::REFERENCE_PHOTOGRAPHIC,
                            interpolation: screen_geometry::KeyframeInterpolation::Smooth,
                        }],
                    },
                },
                screen: screen_geometry::TransformTrack {
                    keyframes: vec![screen_geometry::TransformKeyframe {
                        id: "screen-transform-0".to_owned(),
                        time: RationalTime::new(0, 24).expect("valid time"),
                        translation: Vec3 {
                            x: 0.0,
                            y: 0.0,
                            z: 0.0,
                        },
                        rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                        interpolation: screen_geometry::KeyframeInterpolation::Hold,
                    }],
                },
                inspection: None,
                procedural_pattern: ProceduralTestPattern::AnimatedCheckerboard,
            },
            view: DiagnosticView::Composite,
            preview_exposure_ev: 6.0,
        }
    }

    #[test]
    fn prepares_one_immutable_cross_domain_result() {
        let frame = prepare_frame(request().optical_request()).expect("valid request");
        assert_eq!(frame.native_raster, [1920, 1080]);
        assert!(frame.pixels_per_inch > 90.0);
        assert!(
            frame
                .projected_screen
                .is_some_and(|screen| screen.facing_ratio > 0.9)
        );
        assert!(frame.representative_emission.b > frame.representative_emission.g);
    }

    #[test]
    fn spatial_plan_is_complete_and_excludes_display_modulation() {
        let mut optics = request().optics;
        optics.viewport_aspect = 1.0;
        optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        optics.panel.temporal_emission = PanelTemporalEmission::clean_lcd();
        optics.panel.temporal_emission.analytic_banding.amount = 1.0;
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let plan = prepare_procedural_spatial_plan(optics, sensor, SensorRegion::full(sensor))
            .expect("valid spatial plan");
        assert_eq!(plan.raster.width, 8);
        assert_eq!(plan.raster.height, 8);
        assert!(matches!(
            plan.aperture_sample_count,
            16 | 32 | 64 | 128 | 256 | 512
        ));
        assert!(matches!(
            plan.signal,
            SpatialSignalPlan::Procedural {
                pattern: ProceduralTestPattern::AnimatedCheckerboard,
                ..
            }
        ));
        assert!(
            plan.panel_native_to_acescg
                .into_iter()
                .flatten()
                .all(f32::is_finite)
        );
    }

    #[test]
    fn spatial_batch_applies_analytic_temporal_gain_exactly_once() {
        let mut optics = request().optics;
        optics.panel.temporal_emission = PanelTemporalEmission::continuous();
        optics.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 120).unwrap(),
            on_duration: RationalTime::new(1, 240).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
            amount: 0.6,
        };
        let duration = RationalTime::new(1, 48).unwrap();
        let half = RationalTime::new(1, 96).unwrap();
        let open = optics.time.checked_sub(half).unwrap();
        let close = optics.time.checked_add(half).unwrap();
        let expected_gain = optics
            .panel
            .temporal_emission
            .average_gain(open, close)
            .unwrap();
        let shutter = ShutterRequest {
            optics,
            duration,
            temporal_samples: 8,
            readout: SensorReadout::Global,
            neutral_density_stops: 0.0,
        };
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let exposure = integrate_spatial_region_with_backend(
            shutter,
            sensor,
            region,
            false,
            &backend,
            |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
        )
        .unwrap();
        assert_eq!(backend.last_batch_size.load(Ordering::Relaxed), 8);
        let expected = duration.as_seconds() as f32 * expected_gain;
        for pixel in exposure.acescg_illuminance_seconds {
            assert!((pixel.r - expected).abs() <= 2.0e-7);
            assert!((pixel.g - expected).abs() <= 2.0e-7);
            assert!((pixel.b - expected).abs() <= 2.0e-7);
        }
    }

    #[test]
    fn analytic_banding_amount_zero_is_exact_spatial_identity() {
        let mut clean = request().optics;
        clean.panel.temporal_emission = PanelTemporalEmission::continuous();
        let mut zero_amount = clean.clone();
        zero_amount.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 37).unwrap(),
            on_duration: RationalTime::new(1, 777).unwrap(),
            phase: RationalTime::new(13, 997).unwrap(),
            amount: 0.0,
        };
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 1,
            origin_y: 1,
            width: 2,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let integrate = |optics| {
            integrate_spatial_region_with_backend(
                ShutterRequest {
                    optics,
                    duration: RationalTime::new(1, 96).unwrap(),
                    temporal_samples: 8,
                    readout: SensorReadout::Global,
                    neutral_density_stops: 0.0,
                },
                sensor,
                region,
                false,
                &backend,
                |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
            )
            .unwrap()
        };
        assert_eq!(integrate(zero_amount), integrate(clean));
    }

    #[test]
    fn static_rolling_reuses_one_plan_per_row_but_integrates_all_eight_gains() {
        let mut optics = request().optics;
        optics.procedural_pattern = ProceduralTestPattern::EyeChart;
        optics.panel.temporal_emission = PanelTemporalEmission::continuous();
        optics.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 100).unwrap(),
            on_duration: RationalTime::new(1, 250).unwrap(),
            phase: RationalTime::new(1, 1_000).unwrap(),
            amount: 0.8,
        };
        let duration = RationalTime::new(1, 800).unwrap();
        let readout_duration = RationalTime::new(1, 100).unwrap();
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let plan_preparations = AtomicUsize::new(0);
        let exposure = integrate_spatial_region_with_backend(
            ShutterRequest {
                optics: optics.clone(),
                duration,
                temporal_samples: 8,
                readout: SensorReadout::Rolling {
                    duration: readout_duration,
                    direction: RollingDirection::TopToBottom,
                },
                neutral_density_stops: 0.0,
            },
            sensor,
            region,
            true,
            &backend,
            |optics, region| {
                plan_preparations.fetch_add(1, Ordering::Relaxed);
                prepare_procedural_spatial_plan(optics, sensor, region)
            },
        )
        .unwrap();
        assert_eq!(backend.last_batch_size.load(Ordering::Relaxed), 2);
        assert_eq!(plan_preparations.load(Ordering::Relaxed), 1);
        for local_row in 0..usize::from(region.height) {
            let global_row = usize::from(region.origin_y) + local_row;
            let center = rolling_row_center_time(
                optics.time,
                readout_duration,
                global_row,
                usize::from(sensor.native_height),
                RollingDirection::TopToBottom,
            )
            .unwrap();
            let expected = shutter_quadrature(center, duration, 8)
                .unwrap()
                .into_iter()
                .map(|sample| {
                    f64::from(
                        optics
                            .panel
                            .temporal_emission
                            .average_gain(sample.start, sample.end)
                            .unwrap(),
                    ) * sample.weight_seconds
                })
                .sum::<f64>() as f32;
            for column in 0..usize::from(region.width) {
                let pixel = exposure.acescg_illuminance_seconds
                    [local_row * usize::from(region.width) + column];
                assert!((pixel.r - expected).abs() <= 2.0e-7);
                assert!((pixel.g - expected).abs() <= 2.0e-7);
                assert!((pixel.b - expected).abs() <= 2.0e-7);
            }
        }
    }

    #[test]
    fn residual_flicker_stays_frame_uniform_without_explicit_banding() {
        let mut optics = request().optics;
        optics.procedural_pattern = ProceduralTestPattern::EyeChart;
        optics.panel.temporal_emission = PanelTemporalEmission::clean_lcd();
        assert_eq!(optics.panel.temporal_emission.analytic_banding.amount, 0.0);
        let duration = RationalTime::new(1, 1_000).unwrap();
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 3,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let exposure = integrate_spatial_region_with_backend(
            ShutterRequest {
                optics: optics.clone(),
                duration,
                temporal_samples: 1,
                readout: SensorReadout::Rolling {
                    duration: RationalTime::new(1, 80).unwrap(),
                    direction: RollingDirection::TopToBottom,
                },
                neutral_density_stops: 0.0,
            },
            sensor,
            region,
            true,
            &backend,
            |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
        )
        .unwrap();
        let nominal = shutter_quadrature(optics.time, duration, 1).unwrap()[0];
        let expected = optics
            .panel
            .temporal_emission
            .average_gain(nominal.start, nominal.end)
            .unwrap()
            * duration.as_seconds() as f32;
        for pixel in exposure.acescg_illuminance_seconds {
            assert!((pixel.r - expected).abs() <= 2.0e-7);
            assert!((pixel.g - expected).abs() <= 2.0e-7);
            assert!((pixel.b - expected).abs() <= 2.0e-7);
        }
    }

    #[test]
    fn static_row_template_is_exactly_the_fresh_prepared_plan() {
        let mut first = request().optics;
        first.procedural_pattern = ProceduralTestPattern::EyeChart;
        first.time = RationalTime::new(1, 24).unwrap();
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let first_region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 1,
        };
        let template =
            prepare_procedural_spatial_plan(first.clone(), sensor, first_region).unwrap();
        let second_time = RationalTime::new(7, 120).unwrap();
        let second_region = SensorRegion {
            origin_y: 3,
            ..first_region
        };
        let mut second = first;
        second.time = second_time;
        let fresh = prepare_procedural_spatial_plan(second, sensor, second_region).unwrap();
        assert_eq!(
            template.static_template_for_region(second_time, second_region),
            fresh
        );
    }

    #[test]
    fn animated_procedural_row_template_is_exactly_the_fresh_prepared_plan() {
        let mut first = request().optics;
        first.procedural_pattern = ProceduralTestPattern::AnimatedCheckerboard;
        first.time = RationalTime::new(1, 24).unwrap();
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let first_region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 1,
        };
        let template =
            prepare_procedural_spatial_plan(first.clone(), sensor, first_region).unwrap();
        let second_time = RationalTime::new(7, 120).unwrap();
        let second_region = SensorRegion {
            origin_y: 3,
            ..first_region
        };
        let mut second = first;
        second.time = second_time;
        let fresh = prepare_procedural_spatial_plan(second, sensor, second_region).unwrap();
        assert_eq!(
            template.time_varying_procedural_template_for_region(second_time, second_region),
            Some(fresh)
        );
    }

    #[test]
    fn animated_procedural_rolling_prepares_once_without_reusing_spatial_results() {
        let mut optics = request().optics;
        optics.procedural_pattern = ProceduralTestPattern::AnimatedCheckerboard;
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let plan_preparations = AtomicUsize::new(0);
        integrate_spatial_region_with_backend(
            ShutterRequest {
                optics,
                duration: RationalTime::new(1, 48).unwrap(),
                temporal_samples: 2,
                readout: SensorReadout::Rolling {
                    duration: RationalTime::new(1, 100).unwrap(),
                    direction: RollingDirection::TopToBottom,
                },
                neutral_density_stops: 0.0,
            },
            sensor,
            region,
            false,
            &backend,
            |optics, region| {
                plan_preparations.fetch_add(1, Ordering::Relaxed);
                prepare_procedural_spatial_plan(optics, sensor, region)
            },
        )
        .unwrap();
        assert_eq!(plan_preparations.load(Ordering::Relaxed), 1);
        assert_eq!(backend.last_batch_size.load(Ordering::Relaxed), 4);
    }

    #[test]
    fn parallel_spatial_integration_is_thread_count_invariant() {
        let mut optics = request().optics;
        optics.procedural_pattern = ProceduralTestPattern::AnimatedCheckerboard;
        let sensor = SensorProfile {
            native_width: 32,
            native_height: 18,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 3,
            origin_y: 2,
            width: 23,
            height: 13,
        };
        let shutter = ShutterRequest {
            optics,
            duration: RationalTime::new(1, 48).unwrap(),
            temporal_samples: 8,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 120).unwrap(),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.7,
        };
        let integrate_with_threads = |threads| {
            rayon::ThreadPoolBuilder::new()
                .num_threads(threads)
                .build()
                .unwrap()
                .install(|| {
                    let backend = UnitSpatialBackend {
                        last_batch_size: AtomicUsize::new(0),
                    };
                    integrate_spatial_region_with_backend(
                        shutter.clone(),
                        sensor,
                        region,
                        false,
                        &backend,
                        |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
                    )
                    .unwrap()
                })
        };
        assert_eq!(integrate_with_threads(1), integrate_with_threads(4));
    }

    #[test]
    fn authored_camera_motion_forces_the_complete_eight_plan_batch() {
        let mut optics = request().optics;
        optics.procedural_pattern = ProceduralTestPattern::EyeChart;
        let mut moving_key = optics.camera.transform.keyframes[0].clone();
        moving_key.id = "camera-transform-moving".to_owned();
        moving_key.time = RationalTime::new(2, 1).unwrap();
        moving_key.translation.x = 0.1;
        optics.camera.transform.keyframes.push(moving_key);
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        integrate_spatial_region_with_backend(
            ShutterRequest {
                optics,
                duration: RationalTime::new(1, 48).unwrap(),
                temporal_samples: 8,
                readout: SensorReadout::Global,
                neutral_density_stops: 0.0,
            },
            sensor,
            region,
            true,
            &backend,
            |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
        )
        .unwrap();
        assert_eq!(backend.last_batch_size.load(Ordering::Relaxed), 8);
    }

    #[test]
    fn every_device_default_resolves_to_one_current_cover_preset() {
        for device in DEVICE_PRESETS {
            assert!(
                cover_glass_preset(device.default_cover_glass_preset_id).is_some(),
                "{} references an unknown cover preset",
                device.id
            );
        }
    }

    #[test]
    fn cover_is_neutral_at_zero_and_isolated_from_emission_diagnostics() {
        let baseline = request();
        let baseline_composite =
            evaluate_linear_optics(baseline.optical_request(), 32, 18).expect("baseline composite");

        let mut neutralized = baseline.clone();
        neutralized.optics.cover = COVER_GLASS_PRESETS[1].profile;
        neutralized.optics.cover.character_strength = 0.0;
        neutralized.optics.cover.glow.character_strength = 0.0;
        neutralized.optics.environment = environment_preset("environment-studio-softboxes")
            .unwrap()
            .environment;
        neutralized.optics.environment.character_strength = 0.0;
        let neutral_composite = evaluate_linear_optics(neutralized.optical_request(), 32, 18)
            .expect("neutral composite");
        assert_eq!(baseline_composite.pixels, neutral_composite.pixels);

        let mut physical = baseline.clone();
        physical.optics.cover = COVER_GLASS_PRESETS[1].profile;
        physical.optics.environment = environment_preset("environment-studio-softboxes")
            .unwrap()
            .environment;
        let physical_composite =
            evaluate_linear_optics(physical.optical_request(), 32, 18).expect("physical composite");
        assert_ne!(baseline_composite.pixels, physical_composite.pixels);

        let mut baseline_emission = baseline;
        baseline_emission.view = DiagnosticView::EmittedRadiance;
        let mut physical_emission = physical;
        physical_emission.view = DiagnosticView::EmittedRadiance;
        let baseline_diagnostic =
            prepare_raster(baseline_emission, 32, 18).expect("baseline emission diagnostic");
        let physical_diagnostic =
            prepare_raster(physical_emission, 32, 18).expect("physical emission diagnostic");
        assert_eq!(baseline_diagnostic.pixels, physical_diagnostic.pixels);
    }

    #[test]
    fn bundled_capture_presets_are_complete_unique_authoring_templates() {
        let mut ids = HashSet::new();
        for preset in CAPTURE_DEVICE_PRESETS {
            assert!(ids.insert(preset.id));
            preset.sensor.validate().expect("valid sensor profile");
            preset
                .radiometric_calibration
                .validate()
                .expect("valid radiometric calibration");
            assert!(preset.gate_width.0 > 0.0 && preset.gate_height.0 > 0.0);
            let lens = lens_preset(preset.default_lens_preset_id)
                .expect("capture template lens must resolve");
            assert!(
                preset
                    .compatible_lens_preset_ids
                    .contains(&preset.default_lens_preset_id)
            );
            assert!(!preset.compatible_lens_preset_ids.is_empty());
            let mut compatible_ids = HashSet::new();
            for compatible_id in preset.compatible_lens_preset_ids {
                assert!(compatible_ids.insert(*compatible_id));
                assert!(lens_preset(compatible_id).is_some());
            }
            if preset.lens_association_policy == LensAssociationPolicy::Fixed {
                assert_eq!(preset.compatible_lens_preset_ids, &[lens.id]);
            }
            assert!((25.0..=12_800.0).contains(&preset.reference_exposure_index));
            assert!(preset.middle_gray_illuminance_seconds_at_reference_ei > 0.0);
            assert!(
                (preset
                    .radiometric_calibration
                    .reference_effective_sensor_exposure()
                    - preset.middle_gray_illuminance_seconds_at_reference_ei)
                    .abs()
                    < 1.0e-6,
                "{} must be anchored to its declared 18% reference exposure",
                preset.id
            );
            assert!((1.0..=360.0).contains(&preset.default_shutter_angle_degrees));
            let raster_aspect =
                f32::from(preset.sensor.native_width) / f32::from(preset.sensor.native_height);
            let gate_aspect = preset.gate_width.0 / preset.gate_height.0;
            assert!((raster_aspect - gate_aspect).abs() < 0.001);
            assert_eq!(capture_device_preset(preset.id), Some(*preset));
        }
        assert_eq!(capture_device_preset("unknown-or-retired"), None);
    }

    #[test]
    fn optical_sensor_region_is_an_exact_crop_of_the_complete_raster() {
        let mut request = request().optical_request();
        request.viewport_aspect = 1.0;
        request.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        let full = evaluate_linear_optics(request.clone(), 8, 8).expect("complete raster");
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 3,
            width: 3,
            height: 2,
        };
        let cropped =
            evaluate_linear_optics_region(request, sensor, region).expect("native sensor region");
        for local_y in 0..usize::from(region.height) {
            for local_x in 0..usize::from(region.width) {
                let full_index = (usize::from(region.origin_y) + local_y) * 8
                    + usize::from(region.origin_x)
                    + local_x;
                let region_index = local_y * usize::from(region.width) + local_x;
                assert_eq!(cropped.pixels[region_index], full.pixels[full_index]);
            }
        }
    }

    #[test]
    fn rolling_sensor_region_is_an_exact_crop_of_the_complete_exposure() {
        let mut optics = request().optical_request();
        optics.viewport_aspect = 1.0;
        optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        let shutter = ShutterRequest {
            optics,
            duration: RationalTime::new(1, 48).unwrap(),
            temporal_samples: 3,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 120).unwrap(),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
        };
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 3,
            width: 3,
            height: 2,
        };
        let full = integrate_procedural_shutter(shutter.clone(), 8, 8).expect("full exposure");
        let cropped =
            integrate_procedural_region(shutter, sensor, region).expect("region exposure");
        for local_y in 0..usize::from(region.height) {
            for local_x in 0..usize::from(region.width) {
                let full_index = (usize::from(region.origin_y) + local_y) * 8
                    + usize::from(region.origin_x)
                    + local_x;
                let region_index = local_y * usize::from(region.width) + local_x;
                assert_eq!(
                    cropped.acescg_illuminance_seconds[region_index],
                    full.acescg_illuminance_seconds[full_index]
                );
            }
        }
    }

    #[test]
    fn animated_region_capture_resolves_source_at_each_rolling_sample_time() {
        let mut optics = request().optics;
        optics.viewport_aspect = 1.0;
        optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        let capture = FrameCaptureRequest {
            optics,
            frame_rate: FrameRate::new(24, 1).unwrap(),
            frame_index: 0,
            duration: RationalTime::new(1, 48).unwrap(),
            temporal_samples: 2,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 120).unwrap(),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
            noise_seed: 4,
        };
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let mut sampled = Vec::new();
        capture_and_develop_device_signal_region_sequence(
            capture,
            sensor,
            CameraDevelopment::NEUTRAL,
            SensorRegion {
                origin_x: 3,
                origin_y: 3,
                width: 2,
                height: 2,
            },
            RasterPlacement::Stretch,
            |time| {
                sampled.push(time);
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
        )
        .expect("animated rolling region");
        sampled.sort();
        sampled.dedup();
        assert!(
            sampled.len() > 2,
            "rolling rows must not freeze one frame sample"
        );
    }

    #[test]
    fn aperture_quality_tracks_global_defocus_without_per_pixel_seams() {
        let mut camera = prepare_frame(request().optical_request())
            .expect("valid request")
            .camera;
        assert_eq!(
            aperture_sample_count(camera, ScreenSample::IDENTITY, request().optics.panel, 960),
            16
        );

        camera.position.z = 0.5;
        camera.focus_distance = Meters(0.55);
        camera.focal_length = Millimeters(63.5);
        camera.f_stop = 1.2;
        assert_eq!(
            aperture_sample_count(camera, ScreenSample::IDENTITY, request().optics.panel, 960),
            512
        );
    }

    #[test]
    fn invalid_panel_fails_at_request_boundary() {
        let mut invalid = request();
        invalid.optics.panel.native_width = 0;
        assert_eq!(
            prepare_frame(invalid.optical_request()),
            Err(ApplicationError::Panel(PanelError::EmptyNativeRaster))
        );
    }

    #[test]
    fn sensor_and_output_aspects_require_an_explicit_match() {
        let mut request = request();
        request.optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(24.0);
        assert!(matches!(
            prepare_frame(request.optical_request()),
            Err(ApplicationError::SensorViewportAspectMismatch { .. })
        ));
    }

    #[test]
    fn discrete_preview_raster_may_round_the_authored_viewport_by_half_a_pixel() {
        let authored_aspect = 27.99 / 19.22;
        assert!(raster_represents_viewport(960, 659, authored_aspect));
        assert!(!raster_represents_viewport(960, 658, authored_aspect));
        assert!(raster_represents_viewport(1_919, 1_318, authored_aspect));
        assert!(!raster_represents_viewport(1_920, 1_318, authored_aspect));
    }

    #[test]
    fn parallel_optical_reference_is_deterministic() {
        let first = prepare_raster(request(), 96, 54).expect("first optical render");
        let second = prepare_raster(request(), 96, 54).expect("second optical render");
        assert_eq!(first, second);
    }

    #[test]
    fn linear_optical_output_is_independent_of_preview_exposure() {
        let mut preview = request();
        let first =
            evaluate_linear_optics(preview.optical_request(), 32, 18).expect("linear render");
        preview.preview_exposure_ev = -12.0;
        let second =
            evaluate_linear_optics(preview.optical_request(), 32, 18).expect("linear render");
        assert_eq!(first, second);
    }

    #[test]
    fn global_shutter_uses_exact_centered_temporal_quadrature() {
        let center = RationalTime::new(1, 1).expect("valid center");
        let duration = RationalTime::new(1, 48).expect("valid shutter");
        let samples = shutter_quadrature(center, duration, 4).expect("valid samples");
        assert_eq!(
            samples.iter().map(|sample| sample.time).collect::<Vec<_>>(),
            vec![
                RationalTime::new(127, 128).expect("valid time"),
                RationalTime::new(383, 384).expect("valid time"),
                RationalTime::new(385, 384).expect("valid time"),
                RationalTime::new(129, 128).expect("valid time"),
            ]
        );
        assert!(samples.iter().all(|sample| {
            (sample.weight_seconds - RationalTime::new(1, 192).unwrap().as_seconds()).abs()
                < f64::EPSILON
        }));
        assert_eq!(
            shutter_quadrature(center, duration, 0),
            Err(ApplicationError::InvalidShutter)
        );
    }

    #[test]
    fn global_shutter_capture_is_deterministic_and_samples_the_signal_sequence() {
        let mut optics = request().optics;
        optics.time = RationalTime::new(99, 1).expect("ignored preview time");
        let capture = FrameCaptureRequest {
            optics,
            frame_rate: FrameRate::new(24, 1).expect("valid frame rate"),
            frame_index: 24,
            duration: RationalTime::new(1, 48).expect("valid shutter"),
            temporal_samples: 4,
            readout: SensorReadout::Global,
            neutral_density_stops: 0.0,
            noise_seed: 42,
        };
        let sensor = SensorProfile {
            native_width: 32,
            native_height: 18,
            ..SensorProfile::REFERENCE
        };
        let mut sampled_times = Vec::new();
        let first = capture_frame_from_device_signal_sequence(
            capture.clone(),
            RasterPlacement::Stretch,
            |time| {
                sampled_times.push(time);
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
            sensor,
        )
        .expect("first capture");
        let second = capture_frame_from_device_signal_sequence(
            capture,
            RasterPlacement::Stretch,
            |_| {
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
            sensor,
        )
        .expect("repeated capture");
        assert_eq!(sampled_times.len(), 4);
        assert!(sampled_times.iter().all(|time| {
            *time > RationalTime::new(0, 1).unwrap() && *time < RationalTime::new(2, 1).unwrap()
        }));
        assert_eq!(first, second);
        assert_eq!(first.codes.len(), 32 * 18);
    }

    #[test]
    fn application_publishes_raw_and_developed_acescg_as_distinct_immutable_results() {
        let capture = FrameCaptureRequest {
            optics: request().optics,
            frame_rate: FrameRate::new(24, 1).expect("valid frame rate"),
            frame_index: 0,
            duration: RationalTime::new(1, 48).expect("valid shutter"),
            temporal_samples: 1,
            readout: SensorReadout::Global,
            neutral_density_stops: 0.0,
            noise_seed: 7,
        };
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let frame = capture_and_develop_frame_from_device_signal_sequence(
            capture,
            RasterPlacement::Stretch,
            |_| {
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
            sensor,
            CameraDevelopment {
                white_balance: LinearRgb::new(2.0, 1.0, 1.5),
                middle_gray_illuminance_seconds: 0.18,
                develop_exposure_ev: 0.0,
            },
        )
        .expect("captured camera frame");
        assert_eq!(frame.raw.codes.len(), 144);
        assert_eq!(frame.developed.acescg.len(), 144);
        assert!(
            frame
                .developed
                .acescg
                .iter()
                .all(|pixel| pixel.r.is_finite() && pixel.g.is_finite() && pixel.b.is_finite())
        );
    }

    #[test]
    fn native_development_matches_the_ideal_camera_preview_photometry() {
        let simulation = request();
        let signal = PreparedDeviceSignalRaster::new(DeviceSignalRaster {
            width: 1,
            height: 1,
            pixels: vec![DeviceRgb::WHITE],
        })
        .expect("uniform device signal");
        let sensor = SensorProfile {
            native_width: 32,
            native_height: 18,
            saturation_illuminance_seconds: LinearRgb::new(2.4, 2.4, 2.4),
            full_well_electrons: 10_000_000.0,
            dark_current_electrons_per_second: 0.0,
            read_noise_electrons_rms: 0.0,
            adc_bits: 16,
            ..SensorProfile::REFERENCE
        };
        let shutter = RationalTime::new(1, 48).expect("valid shutter");
        let development = CameraDevelopment {
            white_balance: LinearRgb::new(1.0, 1.0, 1.0),
            middle_gray_illuminance_seconds: 0.1,
            develop_exposure_ev: 0.0,
        };
        let ideal = evaluate_linear_optics_from_prepared_device_signal(
            simulation.optics.clone(),
            sensor.native_width,
            sensor.native_height,
            &signal,
            RasterPlacement::Stretch,
        )
        .expect("ideal optical raster");
        let native = capture_and_develop_device_signal_region(
            FrameCaptureRequest {
                optics: simulation.optics,
                frame_rate: FrameRate::new(24, 1).expect("valid frame rate"),
                frame_index: 0,
                duration: shutter,
                temporal_samples: 1,
                readout: SensorReadout::Global,
                neutral_density_stops: 0.0,
                noise_seed: 1,
            },
            sensor,
            development,
            SensorRegion {
                origin_x: 0,
                origin_y: 0,
                width: sensor.native_width,
                height: sensor.native_height,
            },
            &signal,
            RasterPlacement::Stretch,
        )
        .expect("native camera result");
        let center = 9 * 32 + 16;
        let expected =
            ideal.pixels[center].acescg_irradiance.g * shutter.as_seconds() as f32 * 0.18
                / development.middle_gray_illuminance_seconds;
        let measured = native.developed.acescg[center].g;
        assert!(
            (measured / expected - 1.0).abs() < 0.015,
            "native {measured} differs from ideal preview {expected}"
        );
    }

    #[test]
    fn global_shutter_integrates_analytic_banding_without_changing_average_luminance() {
        let base_optics = request().optics;
        let signal = |_| {
            Ok(Arc::new(PreparedDeviceSignalRaster::new(
                DeviceSignalRaster {
                    width: 1,
                    height: 1,
                    pixels: vec![DeviceRgb::WHITE],
                },
            )?))
        };
        let continuous = integrate_shutter_from_device_signal_sequence(
            ShutterRequest {
                optics: base_optics.clone(),
                duration: RationalTime::new(1, 100).unwrap(),
                temporal_samples: 1,
                readout: SensorReadout::Global,
                neutral_density_stops: 0.0,
            },
            32,
            18,
            RasterPlacement::Stretch,
            signal,
        )
        .expect("continuous exposure");
        let mut pulsed_optics = base_optics;
        let mut temporal = PanelTemporalEmission::continuous();
        temporal.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 1_000).unwrap(),
            on_duration: RationalTime::new(1, 2_000).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
            amount: 1.0,
        };
        pulsed_optics.panel.temporal_emission = temporal;
        let pulsed = integrate_shutter_from_device_signal_sequence(
            ShutterRequest {
                optics: pulsed_optics,
                duration: RationalTime::new(1, 100).unwrap(),
                temporal_samples: 1,
                readout: SensorReadout::Global,
                neutral_density_stops: 0.0,
            },
            32,
            18,
            RasterPlacement::Stretch,
            signal,
        )
        .expect("pulsed exposure");
        let index = 9 * 32 + 16;
        let continuous_value = continuous.acescg_illuminance_seconds[index].g;
        let pulsed_value = pulsed.acescg_illuminance_seconds[index].g;
        assert!((pulsed_value / continuous_value - 1.0).abs() < 1.0e-5);
    }

    #[test]
    fn photometric_boundary_converts_panel_luminance_to_lux_seconds_and_nd_is_exact() {
        let shutter = RationalTime::new(1, 48).unwrap();
        let illuminance_integral = 500.0_f64 * core::f64::consts::FRAC_PI_4 / 16.0 / 48.0;
        let open = finish_integrated_exposure(1, 1, shutter, 0.0, vec![[illuminance_integral; 3]])
            .expect("calibrated exposure");
        let nd_three =
            finish_integrated_exposure(1, 1, shutter, 3.0, vec![[illuminance_integral; 3]])
                .expect("attenuated exposure");
        let expected = 500.0_f32 * core::f32::consts::FRAC_PI_4 / 16.0 / 48.0;
        let measured = open.acescg_illuminance_seconds[0].g;
        assert!((measured - expected).abs() < 1.0e-6);
        assert!((nd_three.acescg_illuminance_seconds[0].g / measured - 0.125).abs() < 1.0e-6);
    }

    #[test]
    fn rolling_shutter_offsets_each_row_in_exact_readout_order() {
        let center = RationalTime::new(0, 1).unwrap();
        let readout = RationalTime::new(1, 100).unwrap();
        assert_eq!(
            rolling_row_center_time(center, readout, 0, 4, RollingDirection::TopToBottom).unwrap(),
            RationalTime::new(-3, 800).unwrap()
        );
        assert_eq!(
            rolling_row_center_time(center, readout, 0, 4, RollingDirection::BottomToTop).unwrap(),
            RationalTime::new(3, 800).unwrap()
        );
    }

    #[test]
    fn optional_analytic_banding_uses_rolling_row_phase_without_extra_optical_samples() {
        let mut optics = request().optics;
        optics.time = RationalTime::new(0, 1).unwrap();
        let mut temporal = PanelTemporalEmission::continuous();
        temporal.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 100).unwrap(),
            on_duration: RationalTime::new(1, 200).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
            amount: 1.0,
        };
        optics.panel.temporal_emission = temporal;
        let prepared = Arc::new(
            PreparedDeviceSignalRaster::new(DeviceSignalRaster {
                width: 1,
                height: 1,
                pixels: vec![DeviceRgb::WHITE],
            })
            .unwrap(),
        );
        let shutter_request = ShutterRequest {
            optics,
            duration: RationalTime::new(1, 100_000).unwrap(),
            temporal_samples: 1,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 100).unwrap(),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
        };
        let exposure = integrate_shutter_from_device_signal_sequence(
            shutter_request.clone(),
            32,
            18,
            RasterPlacement::Stretch,
            |_| Ok(Arc::clone(&prepared)),
        )
        .expect("rolling exposure");
        let black = Arc::new(
            PreparedDeviceSignalRaster::new(DeviceSignalRaster {
                width: 1,
                height: 1,
                pixels: vec![DeviceRgb::BLACK],
            })
            .unwrap(),
        );
        let black_exposure = integrate_shutter_from_device_signal_sequence(
            shutter_request,
            32,
            18,
            RasterPlacement::Stretch,
            |_| Ok(Arc::clone(&black)),
        )
        .expect("black rolling exposure");
        let top = exposure.acescg_illuminance_seconds[2 * 32 + 16].g;
        let bottom = exposure.acescg_illuminance_seconds[15 * 32 + 16].g;
        let black_top = black_exposure.acescg_illuminance_seconds[2 * 32 + 16].g;
        let black_bottom = black_exposure.acescg_illuminance_seconds[15 * 32 + 16].g;
        assert_eq!(top, black_top);
        assert!(bottom > black_bottom);
    }

    #[test]
    fn fit_subpixel_view_integrates_unresolved_device_pixels() {
        let mut request = request();
        request.view = DiagnosticView::Subpixels;
        let raster = prepare_raster(request, 320, 180).expect("valid raster");
        assert!(!raster.subpixels_resolved_at_center);
        assert!(raster.pixels.iter().any(|pixel| pixel.on_panel));
    }

    #[test]
    fn approximate_optical_psf_scales_with_f_number_and_sensor_sampling_density() {
        let frame = prepare_frame(request().optical_request()).expect("valid frame");
        let center = Vec2 { x: 0.0, y: 0.0 };
        let edge = Vec2 { x: 1.0, y: 1.0 };
        let at_960 = approximate_psf_radius_pixels(frame.camera, 960, center);
        let at_3840 = approximate_psf_radius_pixels(frame.camera, 3_840, center);
        let at_edge = approximate_psf_radius_pixels(frame.camera, 3_840, edge);
        let mut stopped_down = frame.camera;
        stopped_down.f_stop *= 2.0;
        let at_f16 = approximate_psf_radius_pixels(stopped_down, 3_840, center);
        assert!(at_3840 > at_960);
        assert!(at_edge > at_3840);
        assert!(at_f16 > at_3840);
        let very_dense = approximate_psf_radius_pixels(stopped_down, 65_535, center);
        assert!(
            very_dense > 2.5,
            "the physical PSF must not be silently capped"
        );
    }

    #[test]
    fn physical_psf_quadrature_is_centered_bounded_and_unit_normalized() {
        let samples = core::array::from_fn::<_, 16, _>(physical_psf_disk_sample);
        let sum = samples
            .iter()
            .fold(Vec2 { x: 0.0, y: 0.0 }, |sum, sample| Vec2 {
                x: sum.x + sample.x,
                y: sum.y + sample.y,
            });
        assert!(sum.x.abs() < 1.0e-6 && sum.y.abs() < 1.0e-6);
        assert!(samples.iter().all(|sample| sample.x.hypot(sample.y) <= 1.0));
        assert!((16.0 * (1.0 / 16.0) - 1.0_f32).abs() < f32::EPSILON);
    }

    #[test]
    fn resolved_sensor_sampling_applies_the_authored_optical_psf_extent() {
        let base = expand_sensor_footprint(Vec2 { x: 0.125, y: 0.875 }, 0.0);
        assert_eq!(base, Vec2 { x: 0.125, y: 0.875 });

        let expanded = expand_sensor_footprint(Vec2 { x: 0.125, y: 0.875 }, 0.5);
        let displacement = Vec2 {
            x: expanded.x - 0.125,
            y: expanded.y - 0.875,
        };
        assert!(displacement.x.hypot(displacement.y) <= 0.5 + f32::EPSILON);
        assert!(displacement.x < 0.0 && displacement.y > 0.0);
        let opposite = expand_sensor_footprint(Vec2 { x: 0.875, y: 0.125 }, 0.5);
        assert!((expanded.x + opposite.x - 1.0).abs() < f32::EPSILON);
        assert!((expanded.y + opposite.y - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn composite_uses_physical_black_matrix_when_resolved() {
        let request = request();
        let optical = OpticalSample {
            panel_uv: [Some(Vec2 { x: 0.5, y: 0.5 }); 3],
            emission_cosine: [1.0; 3],
            reflection_direction_local: [Some(Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            }); 3],
            irradiance_weight: [1.0; 3],
        };
        let neutral_cover = CoverGlassProfile::NEUTRAL
            .evaluator(ProceduralEnvironment::NONE)
            .expect("valid neutral cover");
        let resolved_spatial = [vec![optical; APERTURE_SAMPLE_COUNT].into_boxed_slice()];
        let white_area = AreaSignalSample {
            device_code: DeviceRgb::WHITE,
            linear_native_emission: LinearRgb::new(500.0, 500.0, 500.0),
        };
        let resolved = integrate_aperture_samples(
            &resolved_spatial,
            DiagnosticView::Composite,
            request.optics.panel,
            1.0,
            request.optics.panel.evaluator().expect("valid panel"),
            1.0,
            &|_| DeviceRgb::WHITE,
            &|_, _| white_area,
            neutral_cover,
        );
        let mut offset = optical;
        offset.panel_uv = [Some(Vec2 { x: 0.51, y: 0.51 }); 3];
        let unresolved_spatial = [
            vec![optical; APERTURE_SAMPLE_COUNT].into_boxed_slice(),
            vec![offset; APERTURE_SAMPLE_COUNT].into_boxed_slice(),
        ];
        let unresolved = integrate_aperture_samples(
            &unresolved_spatial,
            DiagnosticView::Composite,
            request.optics.panel,
            1.0,
            request.optics.panel.evaluator().expect("valid panel"),
            1.0,
            &|_| DeviceRgb::WHITE,
            &|_, _| white_area,
            neutral_cover,
        );
        assert_eq!(resolved.acescg_irradiance, LinearRgb::new(0.0, 0.0, 0.0));
        assert!(unresolved.acescg_irradiance.g > 0.0);
    }

    #[test]
    fn raster_placement_is_explicit_and_deterministic() {
        let center = Vec2 { x: 0.5, y: 0.5 };
        assert_eq!(
            source_uv_for_device_uv(
                [1920, 1080],
                [3840, 2160],
                RasterPlacement::OneToOne,
                center
            ),
            Some(center)
        );
        assert_eq!(
            source_uv_for_device_uv(
                [1920, 1080],
                [3840, 2160],
                RasterPlacement::OneToOne,
                Vec2 { x: 0.1, y: 0.5 }
            ),
            None
        );
        assert!(
            source_uv_for_device_uv(
                [1080, 1080],
                [1920, 1080],
                RasterPlacement::Fit,
                Vec2 { x: 0.05, y: 0.5 }
            )
            .is_none()
        );
        assert!(
            source_uv_for_device_uv(
                [1080, 1080],
                [1920, 1080],
                RasterPlacement::FillCrop,
                Vec2 { x: 0.05, y: 0.5 }
            )
            .is_some()
        );
    }

    #[test]
    fn fit_and_fill_crop_preserve_aspect_while_stretch_is_the_only_deforming_mode() {
        let source = [1_000, 1_000];
        let device = [1_600, 900];
        let device_aspect = device[0] as f32 / device[1] as f32;
        let mapped_aspect = |placement| {
            let center = source_uv_unbounded(source, device, placement, Vec2 { x: 0.5, y: 0.5 })
                .expect("valid center");
            let horizontal =
                source_uv_unbounded(source, device, placement, Vec2 { x: 0.6, y: 0.5 })
                    .expect("valid horizontal sample");
            let vertical = source_uv_unbounded(source, device, placement, Vec2 { x: 0.5, y: 0.6 })
                .expect("valid vertical sample");
            let derivative_x = (horizontal.x - center.x) / 0.1;
            let derivative_y = (vertical.y - center.y) / 0.1;
            device_aspect * derivative_y / derivative_x
        };

        assert!((mapped_aspect(RasterPlacement::Fit) - 1.0).abs() < 1.0e-5);
        assert!((mapped_aspect(RasterPlacement::FillCrop) - 1.0).abs() < 1.0e-5);
        assert!((mapped_aspect(RasterPlacement::OneToOne) - 1.0).abs() < 1.0e-5);
        assert!((mapped_aspect(RasterPlacement::Stretch) - device_aspect).abs() < 1.0e-5);
    }

    fn flat_panel_request(
        placement: RasterPlacement,
        quality: FlatPanelQuality,
        amount: f32,
    ) -> PhysicalPipelineRequest {
        let mut panel = request().optics.panel;
        panel.native_width = 2;
        panel.native_height = 1;
        panel.active_width = Meters(0.002);
        panel.active_height = Meters(0.001);
        PhysicalPipelineRequest {
            input: PhysicalPipelineInput {
                width: 2,
                height: 1,
                acescg: vec![[1.5, -0.25, 0.5, 0.25], [0.0, 0.5, 2.0, 0.75]],
                device_signal: DeviceSignalRaster {
                    width: 2,
                    height: 1,
                    pixels: vec![
                        DeviceRgb::new(1.5, -0.25, 0.5),
                        DeviceRgb::new(0.0, 0.5, 2.0),
                    ],
                },
                environment_acescg: None,
            },
            plan: PhysicalPipelineExecutionPlan {
                panel,
                panel_light_spread: PanelLightSpreadProfile {
                    character_strength: 0.0,
                    ..PanelLightSpreadProfile::LCD_DESKTOP
                },
                placement,
                quality,
                requested_width: 4,
                requested_height: 2,
                screen_amount: amount,
                emission_amount: 1.0,
                subpixel_geometry_amount: 1.0,
                temporal_emission_amount: 0.0,
                temporal_emission_gain: 1.0,
                cover: CoverGlassProfile::NEUTRAL,
                environment: IncidentEnvironment::NONE,
                scene_geometry_lens: ResolvedSceneGeometryLensSnapshot::REFERENCE,
                camera_position: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 1.0,
                },
                camera_rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                screen_translation: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
                screen_rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                scene_geometry_amount: 0.0,
                lens_amount: 0.0,
                lens_evaluation_model: LensEvaluationModel::ThinLens,
                frame_time: RationalTime::new(0, 1).expect("valid fixture time"),
                shutter_open: RationalTime::new(-1, 96).expect("valid shutter open"),
                shutter_close: RationalTime::new(1, 96).expect("valid shutter close"),
                shutter_motion: ResolvedShutterMotionSnapshot {
                    temporal_samples: 1,
                    readout: SensorReadout::Global,
                    neutral_density_stops: 0.0,
                    noise_seed: 0,
                },
                shutter_motion_amount: 0.0,
                computational_capture: ComputationalCaptureProfile::SINGLE_EXPOSURE,
                computational_character_strength: 0.0,
                sensor: SensorProfile::REFERENCE,
                radiometric_calibration: CameraRadiometricCalibration::REFERENCE,
                sensor_enabled: false,
                sensor_noise_amount: 0.0,
                development: CameraDevelopment::NEUTRAL,
                development_enabled: false,
                frame_index: 0,
                requested_intermediate: PhysicalIntermediate::DevelopedAcesCg,
            },
        }
    }

    /// A deliberately unclipped, noiseless fixture for the radiometric
    /// contract.  It keeps the panel, shutter and sensor boundaries visible
    /// while removing CFA/noise/ADC saturation as confounding variables.
    fn radiometric_request(
        white_level_nits: f32,
        shutter_open: RationalTime,
        shutter_close: RationalTime,
        nd_stops: f32,
        analog_gain: f32,
        intermediate: PhysicalIntermediate,
    ) -> PhysicalPipelineRequest {
        let mut request = flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 1.0);
        request.input = PhysicalPipelineInput {
            width: 2,
            height: 2,
            acescg: vec![[1.0, 1.0, 1.0, 1.0]; 4],
            device_signal: DeviceSignalRaster {
                width: 2,
                height: 2,
                pixels: vec![DeviceRgb::WHITE; 4],
            },
            environment_acescg: None,
        };
        request.plan.panel.white_level_nits = white_level_nits;
        request.plan.panel_light_spread.character_strength = 0.0;
        request.plan.sensor = SensorProfile {
            native_width: 2,
            native_height: 2,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            // This keeps 1000-nit / +1-stop cases below full well and ADC
            // clipping while retaining enough code precision for stop tests.
            saturation_illuminance_seconds: LinearRgb::new(100.0, 100.0, 100.0),
            full_well_electrons: 100_000_000.0,
            dark_current_electrons_per_second: 0.0,
            read_noise_electrons_rms: 0.0,
            analog_gain,
            adc_bits: 16,
            bloom: SensorBloomProfile::NEUTRAL,
        };
        request.plan.radiometric_calibration = CameraRadiometricCalibration::REFERENCE;
        request.plan.shutter_open = shutter_open;
        request.plan.shutter_close = shutter_close;
        request.plan.shutter_motion.neutral_density_stops = nd_stops;
        request.plan.shutter_motion_amount = 1.0;
        request.plan.sensor_enabled = true;
        request.plan.sensor_noise_amount = 0.0;
        request.plan.development_enabled = true;
        request.plan.requested_intermediate = intermediate;
        request
    }

    fn raw_code_fraction(request: PhysicalPipelineRequest) -> f32 {
        let result = evaluate_physical_pipeline_cpu_oracle(request).expect("radiometric RAW");
        result.acescg[0][0]
    }

    fn developed_luminance(request: PhysicalPipelineRequest) -> f32 {
        let result = evaluate_physical_pipeline_cpu_oracle(request).expect("radiometric developed");
        let pixel = result.acescg[0];
        0.272_228_72 * pixel[0] + 0.674_081_74 * pixel[1] + 0.053_689_517 * pixel[2]
    }

    #[derive(Clone, Copy, Debug)]
    struct ProductionPatchObservation {
        raw_mean: f32,
        raw_maximum: f32,
        full_well_clipped_fraction: f32,
        adc_clipped_fraction: f32,
        developed_luminance: f32,
    }

    fn centered_shutter(seconds: f32) -> (RationalTime, RationalTime) {
        let denominator = 1_000_000_u32;
        let half_ticks = (seconds * denominator as f32 * 0.5).round() as i64;
        (
            RationalTime::new(-half_ticks, denominator).expect("valid shutter open"),
            RationalTime::new(half_ticks, denominator).expect("valid shutter close"),
        )
    }

    /// Exercises the production panel and camera profiles on a small uniform
    /// patch. Spatial character, reflections and noise are deliberately zero:
    /// this isolates the absolute panel-to-sensor exposure contract while
    /// retaining the real EOTF, sensor/CFA, ADC and RAW-development profiles.
    fn production_patch_request(
        capture_id: &str,
        display_id: &str,
        white_level_nits: f32,
        shutter_seconds: f32,
        exposure_index: f32,
        neutral_density_stops: f32,
        intermediate: PhysicalIntermediate,
    ) -> PhysicalPipelineRequest {
        let capture = capture_device_preset(capture_id).expect("known capture preset");
        let lens = lens_preset(capture.default_lens_preset_id)
            .expect("capture default Lens preset must resolve");
        let display = device_preset(display_id).expect("known display preset");
        let mut request = flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 1.0);
        request.input = PhysicalPipelineInput {
            width: 8,
            height: 8,
            acescg: vec![[1.0, 1.0, 1.0, 1.0]; 64],
            device_signal: DeviceSignalRaster {
                width: 8,
                height: 8,
                pixels: vec![DeviceRgb::WHITE; 64],
            },
            environment_acescg: None,
        };

        let mut panel = display.profile();
        panel.native_width = 8;
        panel.native_height = 8;
        panel.active_width = Meters(2.0);
        panel.active_height = Meters(1.5);
        panel.white_level_nits = white_level_nits;
        panel.temporal_emission.residual_flicker.amplitude = 0.0;
        request.plan.panel = panel;
        request.plan.requested_width = 8;
        request.plan.requested_height = 8;
        request.plan.subpixel_geometry_amount = 0.0;
        request.plan.panel_light_spread.character_strength = 0.0;
        request.plan.temporal_emission_amount = 0.0;
        request.plan.cover = CoverGlassProfile::NEUTRAL;
        request.plan.environment = IncidentEnvironment::NONE;
        request.plan.scene_geometry_amount = 1.0;
        request.plan.lens_amount = 1.0;
        request.plan.camera_position = Vec3 {
            x: 0.0,
            y: 0.0,
            z: 1.0,
        };
        request.plan.scene_geometry_lens = ResolvedSceneGeometryLensSnapshot {
            focal_length_millimeters: lens.nominal_focal_length.0,
            sensor_width_millimeters: capture.gate_width.0,
            sensor_height_millimeters: capture.gate_height.0,
            focus_distance_meters: 1.0,
            f_stop: capture.f_stop,
            lens: lens.lens,
            ..ResolvedSceneGeometryLensSnapshot::REFERENCE
        };

        let (shutter_open, shutter_close) = centered_shutter(shutter_seconds);
        request.plan.shutter_open = shutter_open;
        request.plan.shutter_close = shutter_close;
        request.plan.shutter_motion.neutral_density_stops = neutral_density_stops;
        request.plan.shutter_motion_amount = 1.0;

        request.plan.sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            analog_gain: exposure_index / capture.reference_exposure_index,
            dark_current_electrons_per_second: 0.0,
            read_noise_electrons_rms: 0.0,
            ..capture.sensor
        };
        request.plan.radiometric_calibration = capture.radiometric_calibration;
        request.plan.sensor_enabled = true;
        request.plan.sensor_noise_amount = 0.0;
        request.plan.development = CameraDevelopment {
            white_balance: LinearRgb::new(1.0, 1.0, 1.0),
            middle_gray_illuminance_seconds: capture
                .middle_gray_illuminance_seconds_at_reference_ei,
            develop_exposure_ev: 0.0,
        };
        request.plan.development_enabled = true;
        request.plan.requested_intermediate = intermediate;
        request
    }

    fn observe_production_patch(
        capture_id: &str,
        display_id: &str,
        white_level_nits: f32,
        shutter_seconds: f32,
        exposure_index: f32,
        neutral_density_stops: f32,
    ) -> ProductionPatchObservation {
        let raw = evaluate_physical_pipeline_cpu_oracle(production_patch_request(
            capture_id,
            display_id,
            white_level_nits,
            shutter_seconds,
            exposure_index,
            neutral_density_stops,
            PhysicalIntermediate::RawMosaic,
        ))
        .expect("production RAW patch");
        let count = raw.acescg.len() as f32;
        let raw_mean = raw.acescg.iter().map(|pixel| pixel[0]).sum::<f32>() / count;
        let raw_maximum = raw
            .acescg
            .iter()
            .map(|pixel| pixel[0])
            .fold(0.0_f32, f32::max);
        let full_well_clipped_fraction =
            raw.acescg.iter().map(|pixel| pixel[1]).sum::<f32>() / count;
        let adc_clipped_fraction = raw.acescg.iter().map(|pixel| pixel[2]).sum::<f32>() / count;

        let developed = evaluate_physical_pipeline_cpu_oracle(production_patch_request(
            capture_id,
            display_id,
            white_level_nits,
            shutter_seconds,
            exposure_index,
            neutral_density_stops,
            PhysicalIntermediate::DevelopedAcesCg,
        ))
        .expect("production developed patch");
        let developed_luminance = developed
            .acescg
            .iter()
            .map(|pixel| {
                0.272_228_72 * pixel[0] + 0.674_081_74 * pixel[1] + 0.053_689_517 * pixel[2]
            })
            .sum::<f32>()
            / developed.acescg.len() as f32;

        ProductionPatchObservation {
            raw_mean,
            raw_maximum,
            full_well_clipped_fraction,
            adc_clipped_fraction,
            developed_luminance,
        }
    }

    #[test]
    fn sensor_cfa_checkpoint_forces_clean_raw_and_noise_checkpoint_retains_authored_noise() {
        let open = RationalTime::new(-1, 96).expect("time");
        let close = RationalTime::new(1, 96).expect("time");
        let mut clean_request = radiometric_request(
            100.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::SensorNoise,
        );
        clean_request.plan.sensor.read_noise_electrons_rms = 500.0;
        clean_request.plan.sensor_noise_amount = 1.0;
        clean_request.plan.shutter_motion.noise_seed = 42;

        let mut noisy_request = clean_request.clone();
        noisy_request.plan.requested_intermediate = PhysicalIntermediate::RawMosaic;

        let clean_plan = clean_request
            .plan
            .clone()
            .stopped_at_requested_intermediate();
        let noisy_plan = noisy_request
            .plan
            .clone()
            .stopped_at_requested_intermediate();
        assert_eq!(clean_plan.sensor_noise_amount, 0.0);
        assert_eq!(noisy_plan.sensor_noise_amount, 1.0);

        let clean = evaluate_physical_pipeline_cpu_oracle(clean_request).expect("clean RAW");
        let noisy = evaluate_physical_pipeline_cpu_oracle(noisy_request).expect("noisy RAW");
        assert_eq!((clean.width, clean.height), (noisy.width, noisy.height));
        assert_ne!(clean.acescg, noisy.acescg);
    }

    #[test]
    fn canonical_sensor_transition_reproduces_the_cpu_oracle_raw_boundary_exactly() {
        let mut request = radiometric_request(
            350.0,
            RationalTime::new(-1, 576).expect("open"),
            RationalTime::new(1, 576).expect("close"),
            0.0,
            1.0,
            PhysicalIntermediate::SensorNoise,
        );
        request.plan.sensor = SensorProfile {
            native_width: 13,
            native_height: 9,
            adc_bits: 12,
            ..request.plan.sensor
        };
        let expected = evaluate_physical_pipeline_cpu_oracle(request.clone())
            .expect("complete CPU RAW boundary");
        let mut shutter_request = request.clone();
        shutter_request.plan.requested_intermediate = PhysicalIntermediate::ShutterMotion;
        let shuttered = evaluate_physical_pipeline_cpu_oracle(shutter_request)
            .expect("canonical shutter checkpoint");
        let raw = expose_physical_pipeline_raw(
            &shuttered.acescg,
            shuttered.width,
            shuttered.height,
            request.plan.stopped_at_requested_intermediate(),
        )
        .expect("canonical sensor transition");
        let maximum_code = ((1_u32 << raw.adc_bits) - 1) as f32;
        let published = raw
            .codes
            .iter()
            .zip(&raw.full_well_clipped)
            .zip(&raw.adc_clipped)
            .map(|((&code, &well), &adc)| {
                [
                    code as f32 / maximum_code,
                    f32::from(well),
                    f32::from(adc),
                    1.0,
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!((raw.width, raw.height), (expected.width, expected.height));
        assert_eq!(published, expected.acescg);
    }

    #[test]
    fn production_camera_display_patch_matrix_is_physically_plausible() {
        let scenarios = [
            ("arri-alexa-35-open-gate", 1.0 / 48.0, 800.0),
            ("iphone-16e-main-48mp", 1.0 / 48.0, 100.0),
            ("iphone-16e-main-48mp", 1.0 / 60.0, 80.0),
            ("iphone-16e-main-48mp", 1.0 / 82.0, 80.0),
            ("iphone-16e-main-48mp", 1.0 / 48.0, 320.0),
        ];
        let displays = [
            ("lcd-asus-proart-pa329cv", 100.0),
            ("lcd-asus-proart-pa329cv", 350.0),
            ("lcd-phone-4_7-retina", 625.0),
            ("lcd-tv-uhd-55", 1000.0),
        ];

        for (capture_id, shutter, ei) in scenarios {
            let mut previous = None;
            for (display_id, nits) in displays {
                let observation =
                    observe_production_patch(capture_id, display_id, nits, shutter, ei, 0.0);
                assert!(observation.raw_mean.is_finite());
                assert!(observation.raw_maximum.is_finite());
                assert!(observation.developed_luminance.is_finite());
                assert!((0.0..=1.0).contains(&observation.raw_mean));
                assert!((0.0..=1.0).contains(&observation.raw_maximum));
                assert!((0.0..=1.0).contains(&observation.full_well_clipped_fraction));
                assert!((0.0..=1.0).contains(&observation.adc_clipped_fraction));
                if let Some(previous_raw) = previous {
                    assert!(
                        observation.raw_mean + 1.0e-6 >= previous_raw,
                        "{capture_id} RAW response must be monotonic with panel nits"
                    );
                }
                previous = Some(observation.raw_mean);
                eprintln!(
                    "PATCH\t{capture_id}\t{display_id}\t{nits:.0}\t{shutter:.8}\t{ei:.0}\t{:.6}\t{:.6}\t{:.3}\t{:.3}\t{:.6}",
                    observation.raw_mean,
                    observation.raw_maximum,
                    observation.full_well_clipped_fraction,
                    observation.adc_clipped_fraction,
                    observation.developed_luminance,
                );
            }
        }

        let base = observe_production_patch(
            "iphone-16e-main-48mp",
            "lcd-asus-proart-pa329cv",
            5.0,
            1.0 / 82.0,
            80.0,
            0.0,
        );
        let plus_shutter = observe_production_patch(
            "iphone-16e-main-48mp",
            "lcd-asus-proart-pa329cv",
            5.0,
            1.0 / 41.0,
            80.0,
            0.0,
        );
        let plus_ei = observe_production_patch(
            "iphone-16e-main-48mp",
            "lcd-asus-proart-pa329cv",
            5.0,
            1.0 / 82.0,
            160.0,
            0.0,
        );
        let plus_nd = observe_production_patch(
            "iphone-16e-main-48mp",
            "lcd-asus-proart-pa329cv",
            5.0,
            1.0 / 82.0,
            80.0,
            1.0,
        );
        assert!((plus_shutter.raw_mean / base.raw_mean - 2.0).abs() < 0.03);
        assert!((plus_ei.raw_mean / base.raw_mean - 2.0).abs() < 0.03);
        assert!((plus_nd.raw_mean / base.raw_mean - 0.5).abs() < 0.03);

        let arri_hdr = observe_production_patch(
            "arri-alexa-35-open-gate",
            "lcd-tv-uhd-55",
            1000.0,
            1.0 / 48.0,
            800.0,
            0.0,
        );
        assert!(arri_hdr.raw_mean > 0.75 && arri_hdr.raw_mean < 0.85);
        assert_eq!(arri_hdr.full_well_clipped_fraction, 0.0);
        assert_eq!(arri_hdr.adc_clipped_fraction, 0.0);

        let iphone_sdr = observe_production_patch(
            "iphone-16e-main-48mp",
            "lcd-asus-proart-pa329cv",
            100.0,
            1.0 / 48.0,
            100.0,
            0.0,
        );
        assert!(iphone_sdr.full_well_clipped_fraction > 0.5);
        assert!(iphone_sdr.adc_clipped_fraction > 0.5);

        let iphone_shorter_exposure = observe_production_patch(
            "iphone-16e-main-48mp",
            "lcd-asus-proart-pa329cv",
            100.0,
            1.0 / 60.0,
            80.0,
            0.0,
        );
        assert!(iphone_shorter_exposure.full_well_clipped_fraction > 0.0);
        assert!(iphone_shorter_exposure.full_well_clipped_fraction < 1.0);
        assert_eq!(iphone_shorter_exposure.adc_clipped_fraction, 0.0);
        assert!(iphone_shorter_exposure.raw_mean > 0.6);
        assert!(iphone_shorter_exposure.raw_mean < 0.7);
    }

    #[test]
    fn computational_capture_protects_phone_highlights_and_is_exact_for_single_exposure_cameras() {
        let clipped_fraction = |request: PhysicalPipelineRequest| {
            let raw = evaluate_physical_pipeline_cpu_oracle(request).expect("RAW patch");
            raw.acescg.iter().map(|pixel| pixel[1]).sum::<f32>() / raw.acescg.len() as f32
        };
        let mut iphone_single = production_patch_request(
            "iphone-16e-main-48mp",
            "lcd-asus-proart-pa329cv",
            120.0,
            1.0 / 25.0,
            150.0,
            0.0,
            PhysicalIntermediate::RawMosaic,
        );
        iphone_single.plan.computational_capture = ComputationalCaptureProfile::SINGLE_EXPOSURE;
        iphone_single.plan.computational_character_strength = 1.0;
        let mut iphone_bracket = iphone_single.clone();
        iphone_bracket.plan.computational_capture = capture_device_preset("iphone-16e-main-48mp")
            .expect("iPhone preset")
            .computational_capture;
        assert!(clipped_fraction(iphone_bracket) < clipped_fraction(iphone_single));

        let mut arri = production_patch_request(
            "arri-alexa-35-open-gate",
            "lcd-asus-proart-pa329cv",
            120.0,
            1.0 / 25.0,
            800.0,
            0.0,
            PhysicalIntermediate::RawMosaic,
        );
        let baseline = evaluate_physical_pipeline_cpu_oracle(arri.clone()).expect("ARRI baseline");
        arri.plan.computational_capture = capture_device_preset("arri-alexa-35-open-gate")
            .expect("ARRI preset")
            .computational_capture;
        arri.plan.computational_character_strength = 1.0;
        assert_eq!(
            evaluate_physical_pipeline_cpu_oracle(arri).expect("ARRI computational"),
            baseline
        );
    }

    #[test]
    fn every_capture_preset_must_pass_radiometric_stop_invariants() {
        for preset in CAPTURE_DEVICE_PRESETS {
            let calibration = preset.radiometric_calibration;
            let base_nits = calibration.reference_card_luminance_nits() * 0.25;
            let shutter = calibration.reference_shutter_seconds;
            let exposure_index = calibration.base_exposure_index;
            let observe = |nits, shutter_seconds, ei, nd| {
                observe_production_patch(
                    preset.id,
                    "lcd-asus-proart-pa329cv",
                    nits,
                    shutter_seconds,
                    ei,
                    nd,
                )
            };
            let base = observe(base_nits, shutter, exposure_index, 0.0);
            let plus_nits = observe(base_nits * 2.0, shutter, exposure_index, 0.0);
            let plus_shutter = observe(base_nits, shutter * 2.0, exposure_index, 0.0);
            let plus_ei = observe(base_nits, shutter, exposure_index * 2.0, 0.0);
            let plus_nd = observe(base_nits, shutter, exposure_index, 1.0);

            for observation in [base, plus_nits, plus_shutter, plus_ei, plus_nd] {
                assert_eq!(
                    observation.full_well_clipped_fraction, 0.0,
                    "{} reference stop test must remain below full-well clipping",
                    preset.id
                );
                assert_eq!(
                    observation.adc_clipped_fraction, 0.0,
                    "{} reference stop test must remain below ADC clipping",
                    preset.id
                );
            }
            assert!(
                (plus_nits.raw_mean / base.raw_mean - 2.0).abs() < 0.05,
                "{} must gain one RAW stop when panel luminance doubles",
                preset.id
            );
            assert!(
                (plus_shutter.raw_mean / base.raw_mean - 2.0).abs() < 0.05,
                "{} must gain one RAW stop when shutter duration doubles",
                preset.id
            );
            assert!(
                (plus_ei.raw_mean / base.raw_mean - 2.0).abs() < 0.05,
                "{} must gain one RAW stop when EI doubles",
                preset.id
            );
            assert!(
                (plus_nd.raw_mean / base.raw_mean - 0.5).abs() < 0.05,
                "{} must lose one RAW stop at ND 1",
                preset.id
            );
        }
    }

    #[test]
    fn radiometric_calibration_is_anchored_to_each_capture_preset_reference() {
        for preset in CAPTURE_DEVICE_PRESETS {
            let calibration = preset.radiometric_calibration;
            calibration.validate().expect("valid required calibration");
            assert_eq!(
                calibration.base_exposure_index,
                preset.reference_exposure_index
            );
            assert!(
                (calibration.reference_effective_sensor_exposure()
                    - preset.middle_gray_illuminance_seconds_at_reference_ei)
                    .abs()
                    < 1.0e-6,
                "{} must keep its ISO-style 18% anchor explicit",
                preset.id
            );
            assert!(calibration.reference_card_luminance_nits() > 0.0);
        }
    }

    #[test]
    fn radiometric_panel_sensor_contract_preserves_nits_and_stop_ratios_before_clipping() {
        let open = RationalTime::new(-1, 96).expect("time");
        let close = RationalTime::new(1, 96).expect("time");
        let raw_100 = raw_code_fraction(radiometric_request(
            100.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        ));
        let raw_350 = raw_code_fraction(radiometric_request(
            350.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        ));
        let raw_1000 = raw_code_fraction(radiometric_request(
            1000.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        ));
        assert!(
            (raw_350 / raw_100 - 3.5).abs() < 0.01,
            "raw 100={raw_100}, 350={raw_350}, 1000={raw_1000}"
        );
        assert!((raw_1000 / raw_100 - 10.0).abs() < 0.03);

        let raw_minus_stop = raw_code_fraction(radiometric_request(
            350.0,
            RationalTime::new(-1, 192).expect("time"),
            RationalTime::new(1, 192).expect("time"),
            0.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        ));
        let raw_plus_stop = raw_code_fraction(radiometric_request(
            350.0,
            RationalTime::new(-1, 48).expect("time"),
            RationalTime::new(1, 48).expect("time"),
            0.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        ));
        assert!((raw_minus_stop / raw_350 - 0.5).abs() < 0.01);
        assert!((raw_plus_stop / raw_350 - 2.0).abs() < 0.02);

        let raw_iso_minus = raw_code_fraction(radiometric_request(
            350.0,
            open,
            close,
            0.0,
            0.5,
            PhysicalIntermediate::RawMosaic,
        ));
        let raw_iso_plus = raw_code_fraction(radiometric_request(
            350.0,
            open,
            close,
            0.0,
            2.0,
            PhysicalIntermediate::RawMosaic,
        ));
        assert!((raw_iso_minus / raw_350 - 0.5).abs() < 0.01);
        assert!((raw_iso_plus / raw_350 - 2.0).abs() < 0.02);

        let raw_nd_minus = raw_code_fraction(radiometric_request(
            350.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        ));
        let raw_nd_plus = raw_code_fraction(radiometric_request(
            350.0,
            open,
            close,
            2.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        ));
        assert!((raw_nd_plus / raw_nd_minus - 0.25).abs() < 0.01);

        // The panel stage is deliberately normalized device radiance.  The
        // physical nits conversion happens exactly once at the sensor
        // boundary, where the RAW checks above observe it.
        let emission_100 = evaluate_physical_pipeline_cpu_oracle(radiometric_request(
            100.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::PanelEmission,
        ))
        .expect("emission");
        let emission_1000 = evaluate_physical_pipeline_cpu_oracle(radiometric_request(
            1000.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::PanelEmission,
        ))
        .expect("emission");
        assert!((emission_100.acescg[0][0] - emission_1000.acescg[0][0]).abs() < 1.0e-6);

        let developed_100 = developed_luminance(radiometric_request(
            100.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::DevelopedAcesCg,
        ));
        let developed_350 = developed_luminance(radiometric_request(
            350.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::DevelopedAcesCg,
        ));
        let developed_1000 = developed_luminance(radiometric_request(
            1000.0,
            open,
            close,
            0.0,
            1.0,
            PhysicalIntermediate::DevelopedAcesCg,
        ));
        assert!(developed_100 < developed_350 && developed_350 < developed_1000);
    }

    #[test]
    fn physical_lens_aperture_is_applied_once_before_the_sensor_boundary() {
        let mut at_f2 = radiometric_request(
            350.0,
            RationalTime::new(-1, 96).expect("time"),
            RationalTime::new(1, 96).expect("time"),
            0.0,
            1.0,
            PhysicalIntermediate::RawMosaic,
        );
        at_f2.plan.scene_geometry_amount = 1.0;
        at_f2.plan.lens_amount = 1.0;
        at_f2.plan.subpixel_geometry_amount = 0.0;
        at_f2.plan.sensor.saturation_illuminance_seconds = LinearRgb::new(10.0, 10.0, 10.0);
        at_f2.plan.panel.active_width = Meters(1.0);
        at_f2.plan.panel.active_height = Meters(0.5);
        at_f2.plan.camera_position = Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.01,
        };
        at_f2.plan.scene_geometry_lens.focus_distance_meters = 0.01;
        at_f2.plan.scene_geometry_lens.focal_length_millimeters = 10.0;
        at_f2.plan.scene_geometry_lens.sensor_width_millimeters = 4.0;
        at_f2.plan.scene_geometry_lens.sensor_height_millimeters = 2.0;
        at_f2.plan.scene_geometry_lens.f_stop = 2.0;

        let mut at_f4 = at_f2.clone();
        at_f4.plan.scene_geometry_lens.f_stop = 4.0;
        let fixed_shutter_f2 = raw_code_fraction(at_f2.clone());
        let fixed_shutter_f4 = raw_code_fraction(at_f4.clone());
        assert!(
            (fixed_shutter_f4 / fixed_shutter_f2 - 0.25).abs() < 0.01,
            "f/2={fixed_shutter_f2}, f/4={fixed_shutter_f4}"
        );

        at_f2.plan.shutter_open = RationalTime::new(-1, 384).expect("time");
        at_f2.plan.shutter_close = RationalTime::new(1, 384).expect("time");
        let compensated_f2 = raw_code_fraction(at_f2);
        let compensated_f4 = raw_code_fraction(at_f4);
        assert!(
            (compensated_f2 / compensated_f4 - 1.0).abs() < 0.02,
            "f/2 short={compensated_f2}, f/4 long={compensated_f4}"
        );
    }

    #[test]
    fn flat_panel_zero_is_bit_exact_identity_including_alpha_and_extremes() {
        let mut request = flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 0.0);
        request.input.acescg[0][0] = f32::from_bits(0x7fc0_1234);
        let expected = request
            .input
            .acescg
            .iter()
            .flatten()
            .map(|value| value.to_bits())
            .collect::<Vec<_>>();
        let result = evaluate_physical_pipeline_cpu_oracle(request).expect("identity result");
        assert_eq!((result.width, result.height), (2, 1));
        assert_eq!(
            result
                .acescg
                .iter()
                .flatten()
                .map(|value| value.to_bits())
                .collect::<Vec<_>>(),
            expected
        );
    }

    #[test]
    fn flat_panel_all_placements_are_deterministic_and_preserve_alpha_semantics() {
        for placement in [
            RasterPlacement::Fit,
            RasterPlacement::FillCrop,
            RasterPlacement::Stretch,
            RasterPlacement::OneToOne,
        ] {
            let first = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
                placement,
                FlatPanelQuality::Medium,
                1.0,
            ))
            .expect("first result");
            let second = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
                placement,
                FlatPanelQuality::Medium,
                1.0,
            ))
            .expect("second result");
            assert_eq!(first, second);
            assert!(first.acescg.iter().all(|pixel| pixel[3].is_finite()));
            assert!(first.acescg.iter().any(|pixel| pixel[3] > 0.0));
        }
    }

    #[test]
    fn flat_panel_rgb_bgr_black_matrix_and_quality_geometry_are_physical() {
        let mut rgb_request =
            flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::Native, 1.0);
        rgb_request.plan.panel.native_width = 1;
        rgb_request.plan.panel.native_height = 1;
        rgb_request.input.width = 1;
        rgb_request.input.height = 1;
        rgb_request.input.acescg = vec![[1.0, 1.0, 1.0, 1.0]];
        rgb_request.input.device_signal = DeviceSignalRaster {
            width: 1,
            height: 1,
            pixels: vec![DeviceRgb::WHITE],
        };
        rgb_request.plan.requested_width = 1;
        rgb_request.plan.requested_height = 1;
        let rgb = evaluate_physical_pipeline_cpu_oracle(rgb_request.clone()).expect("RGB native");
        rgb_request.plan.panel.stripe_layout = screen_panel::StripeLayout::Bgr;
        let bgr = evaluate_physical_pipeline_cpu_oracle(rgb_request.clone()).expect("BGR native");
        assert_eq!((rgb.width, rgb.height), (3, 3));
        assert!(rgb.acescg[0][0] > rgb.acescg[2][0]);
        assert!(bgr.acescg[0][2] > bgr.acescg[2][2]);
        assert_ne!(rgb.acescg, bgr.acescg);

        rgb_request.plan.panel.black_matrix_fraction = 0.5;
        let matrix = evaluate_physical_pipeline_cpu_oracle(rgb_request).expect("matrix result");
        let rgb_energy = rgb
            .acescg
            .iter()
            .map(|pixel| pixel[0] + pixel[1] + pixel[2])
            .sum::<f32>();
        let matrix_energy = matrix
            .acescg
            .iter()
            .map(|pixel| pixel[0] + pixel[1] + pixel[2])
            .sum::<f32>();
        assert!(matrix_energy <= rgb_energy * 1.001);
        assert!(matrix.diagnostic.sampling.subpixel_geometry_resolved);
        assert_eq!(matrix.diagnostic.geometry.pitch_x_meters, 0.002);
    }

    #[test]
    fn flat_panel_quality_changes_precision_not_requested_domain() {
        let draft = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
            RasterPlacement::Stretch,
            FlatPanelQuality::Draft,
            1.0,
        ))
        .expect("draft");
        let medium = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
            RasterPlacement::Stretch,
            FlatPanelQuality::Medium,
            1.0,
        ))
        .expect("medium");
        let high = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
            RasterPlacement::Stretch,
            FlatPanelQuality::High,
            1.0,
        ))
        .expect("high");
        assert_eq!((draft.width, draft.height), (4, 2));
        assert_eq!((medium.width, medium.height), (4, 2));
        assert_eq!((high.width, high.height), (4, 2));
        assert_eq!(
            [
                draft.diagnostic.sampling.samples_per_output_pixel,
                medium.diagnostic.sampling.samples_per_output_pixel,
                high.diagnostic.sampling.samples_per_output_pixel,
            ],
            [1, 4, 16]
        );

        let artistic = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
            RasterPlacement::Stretch,
            FlatPanelQuality::High,
            2.0,
        ))
        .expect("continuous extrapolation");
        assert!(
            artistic
                .acescg
                .iter()
                .flatten()
                .all(|value| value.is_finite())
        );
        let negative = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
            RasterPlacement::Stretch,
            FlatPanelQuality::High,
            -0.1,
        ));
        assert_eq!(negative, Err(ApplicationError::InvalidCharacterStrength));
    }

    #[test]
    fn temporal_emission_is_exact_at_zero_calibrated_at_one_and_stable_above_one() {
        let baseline = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
            RasterPlacement::Stretch,
            FlatPanelQuality::High,
            1.0,
        ))
        .expect("temporal baseline");
        let mut zero = flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 1.0);
        zero.plan.temporal_emission_amount = 0.0;
        zero.plan.temporal_emission_gain = 0.75;
        assert_eq!(
            evaluate_physical_pipeline_cpu_oracle(zero)
                .expect("temporal identity")
                .acescg,
            baseline.acescg
        );

        let mut calibrated =
            flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 1.0);
        calibrated.plan.temporal_emission_amount = 1.0;
        calibrated.plan.temporal_emission_gain = 0.75;
        let calibrated = evaluate_physical_pipeline_cpu_oracle(calibrated)
            .expect("calibrated temporal emission");
        let mut artistic =
            flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 1.0);
        artistic.plan.temporal_emission_amount = 2.5;
        artistic.plan.temporal_emission_gain = 0.75;
        let artistic =
            evaluate_physical_pipeline_cpu_oracle(artistic).expect("artistic temporal emission");
        assert_ne!(calibrated.acescg, baseline.acescg);
        assert!(
            artistic
                .acescg
                .iter()
                .flatten()
                .all(|value| value.is_finite())
        );
        assert_eq!(
            artistic
                .acescg
                .iter()
                .map(|pixel| pixel[3])
                .collect::<Vec<_>>(),
            baseline
                .acescg
                .iter()
                .map(|pixel| pixel[3])
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn cover_and_environment_are_separate_and_zero_is_exact() {
        let baseline = evaluate_physical_pipeline_cpu_oracle(flat_panel_request(
            RasterPlacement::Stretch,
            FlatPanelQuality::High,
            1.0,
        ))
        .expect("neutral cover/environment");
        let mut covered_request =
            flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 1.0);
        covered_request.plan.cover = screen_cover::COVER_GLASS_PRESETS[1].profile;
        let covered = evaluate_physical_pipeline_cpu_oracle(covered_request.clone())
            .expect("cover transmission");
        assert_ne!(covered.acescg, baseline.acescg);

        covered_request.plan.environment = screen_cover::IncidentEnvironment::Procedural(
            screen_cover::environment_preset("environment-studio-softboxes")
                .unwrap()
                .environment,
        );
        let composite = evaluate_physical_pipeline_cpu_oracle(covered_request.clone())
            .expect("cover plus environment");
        assert_ne!(composite.acescg, covered.acescg);
        covered_request.plan.temporal_emission_amount = 1.0;
        covered_request.plan.temporal_emission_gain = 0.8;
        let temporal_composite = evaluate_physical_pipeline_cpu_oracle(covered_request.clone())
            .expect("temporal emission with stable reflection");
        covered_request.plan.environment = screen_cover::IncidentEnvironment::NONE;
        let temporal_covered = evaluate_physical_pipeline_cpu_oracle(covered_request)
            .expect("temporal cover without environment");
        for (((composite, covered), temporal_composite), temporal_covered) in composite
            .acescg
            .iter()
            .zip(&covered.acescg)
            .zip(&temporal_composite.acescg)
            .zip(&temporal_covered.acescg)
        {
            assert_eq!(composite[3].to_bits(), temporal_composite[3].to_bits());
            for channel in 0..3 {
                assert!(
                    ((composite[channel] - covered[channel])
                        - (temporal_composite[channel] - temporal_covered[channel]))
                        .abs()
                        <= 1.0e-6
                );
            }
        }
    }

    #[test]
    fn scene_pose_uses_quaternion_and_device_dimensions_are_the_only_scale() {
        let mut first = flat_panel_request(RasterPlacement::Stretch, FlatPanelQuality::High, 1.0);
        first.plan.scene_geometry_amount = 1.0;
        first.plan.lens_amount = 1.0;
        first.plan.camera_position = Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.01,
        };
        first.plan.scene_geometry_lens.focus_distance_meters = 0.01;
        first.plan.scene_geometry_lens.focal_length_millimeters = 10.0;
        first.plan.scene_geometry_lens.sensor_width_millimeters = 4.0;
        first.plan.scene_geometry_lens.sensor_height_millimeters = 2.0;
        let narrow =
            evaluate_physical_pipeline_cpu_oracle(first.clone()).expect("resolved scene geometry");
        first.plan.panel.active_width = Meters(0.004);
        let wide = evaluate_physical_pipeline_cpu_oracle(first)
            .expect("same pose with wider physical device");
        assert_ne!(narrow.acescg, wide.acescg);
        assert!(wide.acescg.iter().flatten().all(|value| value.is_finite()));
    }

    #[test]
    fn device_signal_area_filter_integrates_piecewise_constant_native_pixels() {
        let raster = DeviceSignalRaster {
            width: 2,
            height: 2,
            pixels: vec![
                DeviceRgb::BLACK,
                DeviceRgb::WHITE,
                DeviceRgb::WHITE,
                DeviceRgb::BLACK,
            ],
        };
        let integral = DeviceSignalIntegral::new(&raster);
        let average = integral.sample_area_box(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        assert_eq!(average, DeviceRgb::new(0.5, 0.5, 0.5));
        let with_black_outside =
            integral.sample_area_box(Vec2 { x: -1.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        assert_eq!(with_black_outside, DeviceRgb::new(0.25, 0.25, 0.25));

        let high = f32::MAX / 4.0;
        let hdr = DeviceSignalRaster {
            width: 2,
            height: 2,
            pixels: vec![DeviceRgb::new(high, high, high); 4],
        };
        let hdr_average = DeviceSignalIntegral::new(&hdr)
            .sample_area_box(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        assert_eq!(hdr_average, DeviceRgb::new(high, high, high));
        assert!(hdr_average.r.is_finite());
    }

    #[test]
    fn unresolved_filter_averages_emission_after_eotf() {
        let panel = request().optics.panel;
        let evaluator = panel.evaluator().expect("valid panel");
        let raster = DeviceSignalRaster {
            width: 2,
            height: 1,
            pixels: vec![DeviceRgb::BLACK, DeviceRgb::WHITE],
        };
        let emission = linear_emission_integral(&raster, evaluator)
            .sample_area_box(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        let expected = (evaluator.native_channel(DeviceRgb::BLACK, 0)
            + evaluator.native_channel(DeviceRgb::WHITE, 0))
            * 0.5;
        assert!((emission.r - expected).abs() < 1.0e-5);
        assert!(
            (emission.r - evaluator.native_channel(DeviceRgb::new(0.5, 0.5, 0.5), 0)).abs() > 1.0
        );
    }

    #[test]
    fn prepared_device_signal_preview_is_identical_to_direct_device_signal_preview() {
        let source = DeviceSignalRaster {
            width: 2,
            height: 2,
            pixels: vec![
                DeviceRgb::new(0.1, 0.2, 0.3),
                DeviceRgb::new(0.7, 0.3, 0.1),
                DeviceRgb::new(0.2, 0.8, 0.4),
                DeviceRgb::new(0.9, 0.9, 0.9),
            ],
        };
        let prepared = PreparedDeviceSignalRaster::new(source.clone()).expect("valid signal");
        let direct =
            prepare_raster_from_device_signal(request(), 64, 36, &source, RasterPlacement::Stretch)
                .expect("direct preview");
        let reused = prepare_raster_from_prepared_device_signal(
            request(),
            64,
            36,
            &prepared,
            RasterPlacement::Stretch,
        )
        .expect("prepared preview");
        assert_eq!(direct, reused);
    }

    #[test]
    fn alpha_association_is_resolved_before_panel_evaluation() {
        use screen_media::{DecodedRgba, RasterSize};

        let frame = DecodedFrame {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            timestamp: RationalTime::new(0, 24).expect("valid time"),
            pixels: vec![DecodedRgba {
                r: 0.8,
                g: 0.4,
                b: 0.2,
                a: 0.5,
            }],
        };
        let processor = ColorEngine::bundled()
            .expect("bundled color engine")
            .source_to_device_processor(
                SourceColorInterpretation::Ocio(OcioInputTransform::SrgbEncodedRec709),
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("identity processor");
        assert_eq!(
            decoded_frame_to_device_signal(
                &frame,
                AlphaPresence::Present,
                AlphaInterpretation::Auto,
                &processor,
            ),
            Err(ApplicationError::AlphaAssociationUnresolved)
        );
        let straight = decoded_frame_to_device_signal(
            &frame,
            AlphaPresence::Present,
            AlphaInterpretation::Straight,
            &processor,
        )
        .expect("explicit straight alpha");
        let premultiplied = decoded_frame_to_device_signal(
            &frame,
            AlphaPresence::Present,
            AlphaInterpretation::Premultiplied,
            &processor,
        )
        .expect("explicit premultiplied alpha");
        let ignored = decoded_frame_to_device_signal(
            &frame,
            AlphaPresence::Present,
            AlphaInterpretation::Ignore,
            &processor,
        )
        .expect("explicit ignored alpha");
        assert_eq!(straight.pixels[0], DeviceRgb::new(0.4, 0.2, 0.1));
        assert_eq!(premultiplied.pixels[0], DeviceRgb::new(0.8, 0.4, 0.2));
        assert_eq!(ignored.pixels[0], DeviceRgb::new(0.8, 0.4, 0.2));
    }

    #[test]
    fn ignored_alpha_treats_zero_alpha_rgb_as_opaque_content() {
        use screen_media::{DecodedRgba, RasterSize};

        let frame = DecodedFrame {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            timestamp: RationalTime::new(0, 24).expect("valid time"),
            pixels: vec![DecodedRgba {
                r: 0.7,
                g: 0.3,
                b: 0.1,
                a: 0.0,
            }],
        };
        let processor = ColorEngine::bundled()
            .expect("bundled color engine")
            .source_to_device_processor(
                SourceColorInterpretation::Ocio(OcioInputTransform::SrgbEncodedRec709),
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("identity processor");
        let ignored = decoded_frame_to_device_signal(
            &frame,
            AlphaPresence::Present,
            AlphaInterpretation::Ignore,
            &processor,
        )
        .expect("ignored alpha signal");
        assert_eq!(ignored.pixels[0], DeviceRgb::new(0.7, 0.3, 0.1));
    }

    #[test]
    fn equivalent_straight_and_premultiplied_sources_match_after_ocio() {
        use screen_color::OcioInputTransform;
        use screen_media::{DecodedRgba, RasterSize};

        let make_frame = |rgb: [f32; 3]| DecodedFrame {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            timestamp: RationalTime::new(0, 24).expect("valid time"),
            pixels: vec![DecodedRgba {
                r: rgb[0],
                g: rgb[1],
                b: rgb[2],
                a: 0.5,
            }],
        };
        let processor = ColorEngine::bundled()
            .expect("bundled color engine")
            .source_to_device_processor(
                SourceColorInterpretation::Ocio(OcioInputTransform::ArriLogC4),
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("LogC4 processor");
        let straight = decoded_frame_to_device_signal(
            &make_frame([0.4, 0.2, 0.1]),
            AlphaPresence::Present,
            AlphaInterpretation::Straight,
            &processor,
        )
        .expect("straight signal");
        let premultiplied = decoded_frame_to_device_signal(
            &make_frame([0.2, 0.1, 0.05]),
            AlphaPresence::Present,
            AlphaInterpretation::Premultiplied,
            &processor,
        )
        .expect("premultiplied signal");
        assert_eq!(straight, premultiplied);
    }

    #[test]
    fn inspection_camera_resolves_physical_subpixels() {
        let mut request = request();
        request.optics.camera.intrinsics.keyframes[0]
            .lens
            .longitudinal_chromatic_meters = [0.0; 3];
        request.optics.camera.intrinsics.keyframes[0]
            .lens
            .lateral_chromatic_scale = [1.0; 3];
        request.view = DiagnosticView::Subpixels;
        request.optics.inspection = Some(PanelRegion {
            min: Vec2 { x: 0.499, y: 0.499 },
            max: Vec2 { x: 0.501, y: 0.501 },
        });
        let raster = prepare_raster(request, 320, 180).expect("valid inspection raster");
        assert!(raster.subpixels_resolved_at_center);
        assert!(raster.inspection_field_meters.is_some());
    }

    #[test]
    fn deep_oblique_inspection_does_not_require_the_full_panel_outline() {
        let mut request = request();
        request.optics.time = RationalTime::new(48, 24).expect("valid time");
        let yaw = 80.0_f32.to_radians();
        request.optics.camera.transform.keyframes[0].translation = Vec3 {
            x: 0.8 * yaw.sin(),
            y: 0.0,
            z: 0.8 * yaw.cos(),
        };
        request.optics.camera.transform.keyframes[0].rotation =
            screen_geometry::Quaternion::from_yaw_degrees(80.0);
        request.optics.inspection = Some(PanelRegion {
            min: Vec2 { x: 0.499, y: 0.499 },
            max: Vec2 { x: 0.501, y: 0.501 },
        });
        let raster = prepare_raster(request, 320, 180).expect("valid deep inspection raster");
        assert!(raster.frame.projected_screen.is_none());
        assert!(raster.pixels.iter().any(|pixel| pixel.on_panel));
    }

    #[test]
    fn inspection_drag_maps_back_to_panel_coordinates() {
        let region = inspection_region_from_drag(
            request(),
            Vec2 { x: -0.1, y: -0.1 },
            Vec2 { x: 0.1, y: 0.1 },
        )
        .expect("selection starts on panel");
        assert!(region.min.x < 0.5);
        assert!(region.max.x > 0.5);
    }

    #[test]
    fn eye_chart_is_an_explicit_bounded_black_on_white_device_signal() {
        let time = RationalTime::new(0, 24).expect("valid time");
        assert_eq!(
            diagnostic_signal(
                ProceduralTestPattern::EyeChart,
                Vec2 { x: 0.5, y: 0.14 },
                time,
            ),
            DeviceRgb::BLACK
        );
        assert_eq!(
            diagnostic_signal(
                ProceduralTestPattern::EyeChart,
                Vec2 { x: 0.05, y: 0.05 },
                time,
            ),
            DeviceRgb::WHITE
        );
        for y in 0..=100 {
            for x in 0..=100 {
                let value = diagnostic_signal(
                    ProceduralTestPattern::EyeChart,
                    Vec2 {
                        x: x as f32 / 100.0,
                        y: y as f32 / 100.0,
                    },
                    time,
                );
                assert!(
                    [value.r, value.g, value.b]
                        .into_iter()
                        .all(|channel| (0.0..=1.0).contains(&channel))
                );
            }
        }
    }

    #[test]
    fn photometric_scale_publishes_exact_achromatic_device_codes() {
        let time = RationalTime::new(0, 24).expect("valid time");
        for (index, expected) in PHOTOMETRIC_DEVICE_CODES.into_iter().enumerate() {
            let value = diagnostic_signal(
                ProceduralTestPattern::PhotometricDeviceScale,
                Vec2 {
                    x: (index as f32 + 0.5) / PHOTOMETRIC_DEVICE_CODES.len() as f32,
                    y: 0.5,
                },
                time,
            );
            assert_eq!(value, DeviceRgb::new(expected, expected, expected));
        }
    }

    #[test]
    fn known_device_code_follows_authored_panel_eotf_through_optics() {
        let mut optics = request().optical_request();
        optics.panel.black_level_nits = 0.0;
        let uniform = |code| DeviceSignalRaster {
            width: 1,
            height: 1,
            pixels: vec![DeviceRgb::new(code, code, code)],
        };
        let white = evaluate_linear_optics_from_device_signal(
            optics.clone(),
            16,
            9,
            &uniform(1.0),
            RasterPlacement::Stretch,
        )
        .expect("white optical reference");
        let half = evaluate_linear_optics_from_device_signal(
            optics.clone(),
            16,
            9,
            &uniform(0.5),
            RasterPlacement::Stretch,
        )
        .expect("half-code optical reference");
        let center = 4 * 16 + 8;
        let measured =
            half.pixels[center].acescg_irradiance.g / white.pixels[center].acescg_irradiance.g;
        let expected = 0.5_f32.powf(optics.panel.eotf_gamma);
        assert!((measured - expected).abs() < 1.0e-5);

        optics.camera.intrinsics.keyframes[0].focus_distance = Meters(0.4);
        let defocused_white = evaluate_linear_optics_from_device_signal(
            optics,
            16,
            9,
            &uniform(1.0),
            RasterPlacement::Stretch,
        )
        .expect("defocused uniform optical reference");
        let focused_energy = white.pixels[center].acescg_irradiance.g;
        let defocused_energy = defocused_white.pixels[center].acescg_irradiance.g;
        let energy_ratio = defocused_energy / focused_energy;
        assert!(
            (energy_ratio - 1.0).abs() < 5.0e-4,
            "uniform defocus energy ratio {energy_ratio}"
        );
    }

    #[test]
    fn cover_glow_multiscale_scatter_preserves_uniform_linear_energy() {
        let mut glowed = request().optical_request();
        glowed.panel.black_level_nits = 0.0;
        glowed.cover = screen_cover::cover_glass_preset("cover-matte-ar")
            .expect("matte cover")
            .profile;
        let mut clean = glowed.clone();
        clean.cover.glow.character_strength = 0.0;
        let uniform = DeviceSignalRaster {
            width: 1,
            height: 1,
            pixels: vec![DeviceRgb::WHITE],
        };
        let clean = evaluate_linear_optics_from_device_signal(
            clean,
            16,
            9,
            &uniform,
            RasterPlacement::Stretch,
        )
        .expect("clean uniform optical reference");
        let glowed = evaluate_linear_optics_from_device_signal(
            glowed,
            16,
            9,
            &uniform,
            RasterPlacement::Stretch,
        )
        .expect("glowed uniform optical reference");
        let center = 4 * 16 + 8;
        let ratio =
            glowed.pixels[center].acescg_irradiance.g / clean.pixels[center].acescg_irradiance.g;
        assert!(
            (ratio - 1.0).abs() < 5.0e-4,
            "uniform glow energy ratio {ratio}"
        );
    }

    #[test]
    fn cover_glow_collects_panel_emission_for_a_ray_just_outside_the_active_outline() {
        let mut optics = request().optical_request();
        optics.panel.black_level_nits = 0.0;
        optics.cover = screen_cover::cover_glass_preset("cover-thick-crt")
            .expect("thick cover")
            .profile;
        optics.cover.glow.character_strength = 4.0;
        optics.cover.glow.scatter_fraction = 0.20;
        optics.cover.glow.core_radius_millimeters = 5.0;
        optics.cover.glow.tail_radius_millimeters = 30.0;
        optics.cover.glow.tail_fraction = 1.0;
        let evaluator = optics.panel.evaluator().expect("panel evaluator");
        let cover = optics
            .cover
            .evaluator(optics.environment)
            .expect("cover evaluator");
        let ray = OpticalSample {
            panel_uv: [Some(Vec2 { x: -0.02, y: 0.5 }); 3],
            emission_cosine: [1.0; 3],
            reflection_direction_local: [Some(Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            }); 3],
            irradiance_weight: [1.0; 3],
        };
        let samples = [vec![ray; 16].into_boxed_slice()];
        let output = integrate_aperture_samples(
            &samples,
            DiagnosticView::Composite,
            optics.panel,
            0.0,
            evaluator,
            1.0,
            &|_| DeviceRgb::WHITE,
            &|_, _| AreaSignalSample {
                device_code: DeviceRgb::WHITE,
                linear_native_emission: LinearRgb::new(1.0, 1.0, 1.0),
            },
            cover,
        );
        assert!(output.on_panel);
        assert!(output.acescg_irradiance.r > 0.0);
        assert!(output.acescg_irradiance.g > 0.0);
        assert!(output.acescg_irradiance.b > 0.0);
    }

    #[test]
    fn lens_veiling_glare_reaches_black_gate_pixels_outside_the_panel_projection() {
        let mut clean = request().optical_request();
        clean.panel.black_level_nits = 0.0;
        clean.cover = CoverGlassProfile::NEUTRAL;
        clean.environment = ProceduralEnvironment::NONE;
        clean.camera.intrinsics.keyframes[0]
            .lens
            .veiling_glare_fraction = 0.0;
        let mut glared = clean.clone();
        glared.camera.intrinsics.keyframes[0]
            .lens
            .veiling_glare_fraction = 0.05;
        let white = DeviceSignalRaster {
            width: 1,
            height: 1,
            pixels: vec![DeviceRgb::WHITE],
        };
        let clean = evaluate_linear_optics_from_device_signal(
            clean,
            32,
            18,
            &white,
            RasterPlacement::Stretch,
        )
        .expect("clean optical reference");
        let glared = evaluate_linear_optics_from_device_signal(
            glared,
            32,
            18,
            &white,
            RasterPlacement::Stretch,
        )
        .expect("glared optical reference");
        let (clean_outside, glared_outside) = clean
            .pixels
            .iter()
            .zip(&glared.pixels)
            .find(|(clean, glared)| !clean.on_panel && !glared.on_panel)
            .expect("camera gate includes support outside the panel projection");
        assert!(glared_outside.acescg_irradiance.g > clean_outside.acescg_irradiance.g);
    }
}
