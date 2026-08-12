//! Host-neutral authoring descriptors for the ordered Test surface.

use crate::{CAPTURE_DEVICE_PRESETS, CaptureDevicePreset, capture_device_preset};
use screen_color::{DeviceColorTarget, OcioInputTransform};
use screen_cover::{
    COVER_GLASS_PRESETS, ENVIRONMENT_PRESETS, cover_glass_preset, environment_preset,
};
use screen_geometry::{LensPreset, lens_preset};
use screen_panel::{DEVICE_PRESETS, DevicePreset, PanelColorMode};

pub const TEST_AUTHORING_SCHEMA_VERSION: u32 = 13;

pub const ORIGIN_PHASE_ID: &str = "origin";
pub const FEEDER_SIGNAL_PHASE_ID: &str = "feeder-signal";
pub const DEVICE_INTERPRETATION_PHASE_ID: &str = "device-interpretation";
pub const PANEL_STRUCTURE_PHASE_ID: &str = "panel-structure";
pub const PANEL_UNIFORMITY_PHASE_ID: &str = "panel-uniformity";
pub const PANEL_LIGHT_SPREAD_PHASE_ID: &str = "panel-light-spread";
pub const RELATIVE_GEOMETRY_PHASE_ID: &str = "relative-geometry";
pub const COVER_ENVIRONMENT_PHASE_ID: &str = "cover-environment";
pub const COVER_GLOW_PHASE_ID: &str = "cover-glow";
pub const LENS_PROJECTION_PHASE_ID: &str = "lens-projection";
pub const SHUTTER_EXPOSURE_PHASE_ID: &str = "shutter-exposure";
pub const COMPUTATIONAL_CAPTURE_PHASE_ID: &str = "computational-capture";
pub const SENSOR_BLOOM_PHASE_ID: &str = "sensor-bloom";
pub const SENSOR_CFA_PHASE_ID: &str = "sensor-cfa";
pub const SENSOR_NOISE_PHASE_ID: &str = "sensor-noise";
pub const DEVELOP_DEMOSAIC_PHASE_ID: &str = "develop-demosaic";
pub const OUTPUT_SIGNAL_CONTROL_ID: &str = "output-signal";
pub const DEVICE_CONTROL_ID: &str = "device";
pub const COLOR_MODE_CONTROL_ID: &str = "color-mode";
pub const WHITE_LUMINANCE_CONTROL_ID: &str = "white-luminance";
pub const PLACEMENT_CONTROL_ID: &str = "placement";
pub const PREVIEW_QUALITY_CONTROL_ID: &str = "preview-quality";
pub const SUBPIXEL_GEOMETRY_CONTROL_ID: &str = "subpixel-geometry-amount";
pub const PANEL_UNIFORMITY_CONTROL_ID: &str = "panel-uniformity-amount";
pub const PANEL_LIGHT_SPREAD_CONTROL_ID: &str = "panel-light-spread-amount";
pub const CAPTURE_PRESET_CONTROL_ID: &str = "capture-preset";
pub const GEOMETRY_MODE_CONTROL_ID: &str = "geometry-mode";
pub const CAMERA_DISTANCE_CONTROL_ID: &str = "camera-distance-meters";
pub const CAMERA_ORBIT_X_CONTROL_ID: &str = "camera-orbit-x-degrees";
pub const CAMERA_ORBIT_Y_CONTROL_ID: &str = "camera-orbit-y-degrees";
pub const CAMERA_POSITION_X_CONTROL_ID: &str = "camera-position-x-meters";
pub const CAMERA_POSITION_Y_CONTROL_ID: &str = "camera-position-y-meters";
pub const CAMERA_POSITION_Z_CONTROL_ID: &str = "camera-position-z-meters";
pub const CAMERA_ROTATION_X_CONTROL_ID: &str = "camera-rotation-x-degrees";
pub const CAMERA_ROTATION_Y_CONTROL_ID: &str = "camera-rotation-y-degrees";
pub const CAMERA_ROTATION_Z_CONTROL_ID: &str = "camera-rotation-z-degrees";
pub const SCREEN_POSITION_X_CONTROL_ID: &str = "screen-position-x-meters";
pub const SCREEN_POSITION_Y_CONTROL_ID: &str = "screen-position-y-meters";
pub const SCREEN_POSITION_Z_CONTROL_ID: &str = "screen-position-z-meters";
pub const SCREEN_YAW_CONTROL_ID: &str = "screen-yaw-degrees";
pub const SCREEN_ROTATION_X_CONTROL_ID: &str = "screen-rotation-x-degrees";
pub const SCREEN_ROTATION_Z_CONTROL_ID: &str = "screen-rotation-z-degrees";
pub const COVER_GLASS_CONTROL_ID: &str = "cover-glass-preset";
pub const COVER_GLASS_AMOUNT_CONTROL_ID: &str = "cover-glass-amount";
pub const COVER_AG_MICROTEXTURE_AMOUNT_CONTROL_ID: &str = "cover-ag-microtexture-amount";
pub const ENVIRONMENT_CONTROL_ID: &str = "environment-preset";
pub const ENVIRONMENT_AMOUNT_CONTROL_ID: &str = "environment-amount";
pub const COVER_GLOW_AMOUNT_CONTROL_ID: &str = "cover-glow-amount";
pub const LENS_PRESET_CONTROL_ID: &str = "lens-preset";
pub const LENS_AMOUNT_CONTROL_ID: &str = "lens-amount";
pub const AUTOFOCUS_CONTROL_ID: &str = "autofocus";
pub const FOCUS_DISTANCE_CONTROL_ID: &str = "focus-distance-meters";
pub const F_STOP_CONTROL_ID: &str = "f-stop";
pub const SHUTTER_ANGLE_CONTROL_ID: &str = "shutter-angle-degrees";
pub const SHUTTER_RECIPROCAL_CONTROL_ID: &str = "shutter-reciprocal-seconds";
pub const SHUTTER_AMOUNT_CONTROL_ID: &str = "shutter-motion-amount";
pub const COMPUTATIONAL_CAPTURE_AMOUNT_CONTROL_ID: &str = "computational-capture-amount";
pub const COMPUTATIONAL_EXPOSURE_COUNT_CONTROL_ID: &str = "computational-exposure-count";
pub const COMPUTATIONAL_BRACKET_SPACING_CONTROL_ID: &str = "computational-bracket-spacing-stops";
pub const SENSOR_NOISE_AMOUNT_CONTROL_ID: &str = "sensor-noise-amount";
pub const SENSOR_BLOOM_AMOUNT_CONTROL_ID: &str = "sensor-bloom-amount";
pub const SENSOR_BLOOM_CROSSTALK_CONTROL_ID: &str = "sensor-bloom-crosstalk-fraction";
pub const SENSOR_BLOOM_OVERFLOW_CONTROL_ID: &str = "sensor-bloom-overflow-transfer-fraction";

const PLACEMENTS: [TestChoiceOption; 4] = [
    TestChoiceOption {
        id: "fit",
        label: "Fit",
    },
    TestChoiceOption {
        id: "fill-crop",
        label: "Fill / Crop",
    },
    TestChoiceOption {
        id: "stretch",
        label: "Stretch",
    },
    TestChoiceOption {
        id: "one-to-one",
        label: "One to One",
    },
];

const PREVIEW_QUALITIES: [TestChoiceOption; 4] = [
    TestChoiceOption {
        id: "draft",
        label: "Draft",
    },
    TestChoiceOption {
        id: "medium",
        label: "Media",
    },
    TestChoiceOption {
        id: "high",
        label: "Alta",
    },
    TestChoiceOption {
        id: "native",
        label: "Nativa",
    },
];

const GEOMETRY_MODES: [TestChoiceOption; 2] = [
    TestChoiceOption {
        id: "look-at",
        label: "Look At",
    },
    TestChoiceOption {
        id: "free",
        label: "Libre",
    },
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TestAuthoringSelection<'a> {
    pub input_transform_id: &'a str,
    pub output_signal_id: &'a str,
    pub device_id: &'a str,
    pub color_mode_id: &'a str,
    pub white_luminance_nits: f32,
    pub placement_id: &'a str,
    pub preview_quality_id: &'a str,
    pub frame_rate: f32,
    pub subpixel_geometry_amount: f32,
    pub panel_uniformity_amount: f32,
    pub panel_light_spread_amount: f32,
    pub capture_preset_id: &'a str,
    pub geometry_mode_id: &'a str,
    pub camera_distance_meters: f32,
    pub camera_orbit_x_degrees: f32,
    pub camera_orbit_y_degrees: f32,
    pub camera_position_x_meters: f32,
    pub camera_position_y_meters: f32,
    pub camera_position_z_meters: f32,
    pub camera_rotation_x_degrees: f32,
    pub camera_rotation_y_degrees: f32,
    pub camera_rotation_z_degrees: f32,
    pub screen_position_x_meters: f32,
    pub screen_position_y_meters: f32,
    pub screen_position_z_meters: f32,
    pub screen_yaw_degrees: f32,
    pub screen_rotation_x_degrees: f32,
    pub screen_rotation_z_degrees: f32,
    pub cover_glass_preset_id: &'a str,
    pub cover_glass_amount: f32,
    pub cover_ag_microtexture_amount: f32,
    pub environment_preset_id: &'a str,
    pub environment_amount: f32,
    pub cover_glow_amount: f32,
    pub lens_preset_id: &'a str,
    pub lens_amount: f32,
    pub autofocus_enabled: bool,
    pub focus_distance_meters: f32,
    pub f_stop: f32,
    pub exposure_time_seconds: f32,
    pub shutter_motion_amount: f32,
    pub computational_character_strength: f32,
    pub computational_exposure_count: f32,
    pub computational_bracket_spacing_stops: f32,
    pub sensor_bloom_amount: f32,
    pub sensor_bloom_crosstalk_fraction: f32,
    pub sensor_bloom_overflow_transfer_fraction: f32,
    pub sensor_noise_amount: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedTestAuthoringSelection {
    pub input_transform_id: &'static str,
    pub output_signal_id: &'static str,
    pub device_id: &'static str,
    pub color_mode_id: &'static str,
    pub device_eotf_gamma: f32,
    pub white_luminance_nits: f32,
    pub placement_id: &'static str,
    pub preview_quality_id: &'static str,
    pub frame_rate: f32,
    pub subpixel_geometry_amount: f32,
    pub panel_uniformity_amount: f32,
    pub panel_light_spread_amount: f32,
    pub capture_preset_id: &'static str,
    pub geometry_mode_id: &'static str,
    pub camera_distance_meters: f32,
    pub camera_orbit_x_degrees: f32,
    pub camera_orbit_y_degrees: f32,
    pub camera_position_x_meters: f32,
    pub camera_position_y_meters: f32,
    pub camera_position_z_meters: f32,
    pub camera_rotation_x_degrees: f32,
    pub camera_rotation_y_degrees: f32,
    pub camera_rotation_z_degrees: f32,
    pub screen_position_x_meters: f32,
    pub screen_position_y_meters: f32,
    pub screen_position_z_meters: f32,
    pub screen_yaw_degrees: f32,
    pub screen_rotation_x_degrees: f32,
    pub screen_rotation_z_degrees: f32,
    pub cover_glass_preset_id: &'static str,
    pub cover_glass_amount: f32,
    pub cover_ag_microtexture_amount: f32,
    pub environment_preset_id: &'static str,
    pub environment_amount: f32,
    pub cover_glow_amount: f32,
    pub lens_preset_id: &'static str,
    pub lens_amount: f32,
    pub autofocus_enabled: bool,
    pub focus_distance_meters: f32,
    pub f_stop: f32,
    pub exposure_time_seconds: f32,
    pub shutter_motion_amount: f32,
    pub computational_character_strength: f32,
    pub computational_exposure_count: f32,
    pub computational_bracket_spacing_stops: f32,
    pub sensor_bloom_amount: f32,
    pub sensor_bloom_crosstalk_fraction: f32,
    pub sensor_bloom_overflow_transfer_fraction: f32,
    pub sensor_noise_amount: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TestChoiceOption {
    pub id: &'static str,
    pub label: &'static str,
}

#[derive(Clone, Debug, PartialEq)]
pub enum TestControlRequirement {
    Choice {
        id: &'static str,
        label: &'static str,
        options: Vec<TestChoiceOption>,
        selected_id: &'static str,
        reset_id: &'static str,
    },
    Scalar {
        id: &'static str,
        label: &'static str,
        value: f32,
        minimum: f32,
        maximum: f32,
        step: f32,
        slider_visible: bool,
        reset_value: f32,
        unit: &'static str,
    },
    Toggle {
        id: &'static str,
        label: &'static str,
        value: bool,
        reset_value: bool,
    },
}

fn choice_control(
    id: &'static str,
    label: &'static str,
    options: Vec<TestChoiceOption>,
    selected_id: &'static str,
    reset_id: &'static str,
) -> TestControlRequirement {
    TestControlRequirement::Choice {
        id,
        label,
        options,
        selected_id,
        reset_id,
    }
}

fn scalar_control(
    id: &'static str,
    label: &'static str,
    value: f32,
    minimum: f32,
    maximum: f32,
    reset_value: f32,
    unit: &'static str,
) -> TestControlRequirement {
    TestControlRequirement::Scalar {
        id,
        label,
        value,
        minimum,
        maximum,
        step: (maximum - minimum) * 0.05,
        slider_visible: true,
        reset_value,
        unit,
    }
}

fn scalar_field_control(
    id: &'static str,
    label: &'static str,
    value: f32,
    minimum: f32,
    maximum: f32,
    reset_value: f32,
    unit: &'static str,
) -> TestControlRequirement {
    let mut control = scalar_control(id, label, value, minimum, maximum, reset_value, unit);
    if let TestControlRequirement::Scalar { slider_visible, .. } = &mut control {
        *slider_visible = false;
    }
    control
}

fn toggle_control(
    id: &'static str,
    label: &'static str,
    value: bool,
    reset_value: bool,
) -> TestControlRequirement {
    TestControlRequirement::Toggle {
        id,
        label,
        value,
        reset_value,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TestPhaseDescriptor {
    pub id: &'static str,
    pub label: &'static str,
    pub effect_summary: &'static str,
    pub header_control_id: Option<&'static str>,
    pub input_artifact: &'static str,
    pub output_artifact: &'static str,
    pub preview_result: TestPreviewResult,
    pub controls: Vec<TestControlRequirement>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum TestPreviewResult {
    SourceAcesCg = 0,
    FeederSignal = 1,
    DeviceInterpretation = 2,
    PanelStructure = 3,
    PanelUniformity = 4,
    PanelLightSpread = 5,
    RelativeGeometry = 6,
    CoverEnvironment = 7,
    CoverGlow = 8,
    LensProjection = 9,
    ShutterExposure = 10,
    ComputationalCapture = 11,
    SensorBloom = 12,
    SensorCfa = 13,
    SensorNoise = 14,
    DevelopDemosaic = 15,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TestPageDescriptor {
    pub schema_version: u32,
    pub default_preview_phase_id: &'static str,
    pub phases: Vec<TestPhaseDescriptor>,
    pub preview_controls: Vec<TestControlRequirement>,
    pub selection: ResolvedTestAuthoringSelection,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TestAuthoringError {
    UnknownInputTransform,
    UnknownOutputSignal,
    UnknownDevice,
    UnknownColorMode,
    UnsupportedColorMode,
    InvalidWhiteLuminance,
    InvalidSubpixelGeometryAmount,
    InvalidPanelUniformityAmount,
    InvalidPanelLightSpreadAmount,
    UnknownCapturePreset,
    UnknownLensPreset,
    UnsupportedLensPreset,
    InvalidGeometry,
    UnknownCoverGlassPreset,
    InvalidCoverGlassAmount,
    InvalidCoverAgMicrotextureAmount,
    UnknownEnvironmentPreset,
    InvalidEnvironmentAmount,
    InvalidCoverGlowAmount,
    InvalidLensAmount,
    InvalidFocusDistance,
    InvalidAperture,
    InvalidExposureTime,
    InvalidShutterMotionAmount,
    InvalidComputationalCapture,
    InvalidSensorBloomAmount,
    InvalidSensorBloomProfile,
    InvalidSensorNoiseAmount,
    UnknownPlacement,
    UnknownPreviewQuality,
    UnknownControl,
    WrongControlType,
}

impl core::fmt::Display for TestAuthoringError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str(match self {
            Self::UnknownInputTransform => "unknown Test Input Transform",
            Self::UnknownOutputSignal => "unknown Test Output Signal",
            Self::UnknownDevice => "unknown Test device preset",
            Self::UnknownColorMode => "unknown Test Color Mode",
            Self::UnsupportedColorMode => "Color Mode is not supported by the selected device",
            Self::InvalidWhiteLuminance => "White Luminance is outside the device capability",
            Self::InvalidSubpixelGeometryAmount => "Subpixel Geometry amount is outside 0..=4",
            Self::InvalidPanelUniformityAmount => "Panel Uniformity amount is outside 0..=4",
            Self::InvalidPanelLightSpreadAmount => "Panel Light Spread amount is outside 0..=4",
            Self::UnknownCapturePreset => "unknown Test Capture preset",
            Self::UnknownLensPreset => "unknown Test Lens preset",
            Self::UnsupportedLensPreset => "Lens preset is not compatible with the selected Camera",
            Self::InvalidGeometry => "Test relative geometry is invalid",
            Self::UnknownCoverGlassPreset => "unknown Test Cover Glass preset",
            Self::InvalidCoverGlassAmount => "Cover Glass amount is outside 0..=2",
            Self::InvalidCoverAgMicrotextureAmount => {
                "Cover AG Microtexture amount is outside 0..=4"
            }
            Self::UnknownEnvironmentPreset => "unknown Test Environment preset",
            Self::InvalidEnvironmentAmount => "Environment amount is outside 0..=4",
            Self::InvalidCoverGlowAmount => "Cover Glow amount is outside 0..=4",
            Self::InvalidLensAmount => "Lens amount is outside 0..=4",
            Self::InvalidFocusDistance => "Focus Distance is invalid",
            Self::InvalidAperture => "Aperture is outside f/0.7..=f/64",
            Self::InvalidExposureTime => "Exposure Time is outside 1/32000..=60 seconds",
            Self::InvalidShutterMotionAmount => "Shutter amount is outside 0..=4",
            Self::InvalidComputationalCapture => {
                "Computational Capture requires 1-8 exposures and a valid EV bracket"
            }
            Self::InvalidSensorBloomAmount => "Sensor Bloom amount is outside 0..=4",
            Self::InvalidSensorBloomProfile => {
                "Sensor Bloom profile is outside its physical bounds"
            }
            Self::InvalidSensorNoiseAmount => "Sensor Noise amount is outside 0..=4",
            Self::UnknownPlacement => "unknown Test placement",
            Self::UnknownPreviewQuality => "unknown Test preview quality",
            Self::UnknownControl => "unknown Test control",
            Self::WrongControlType => "Test intent does not match the control type",
        })
    }
}

fn preset(id: &str) -> Result<DevicePreset, TestAuthoringError> {
    DEVICE_PRESETS
        .iter()
        .copied()
        .find(|candidate| candidate.id == id)
        .ok_or(TestAuthoringError::UnknownDevice)
}

fn capture(id: &str) -> Result<CaptureDevicePreset, TestAuthoringError> {
    capture_device_preset(id).ok_or(TestAuthoringError::UnknownCapturePreset)
}

fn lens(id: &str) -> Result<LensPreset, TestAuthoringError> {
    lens_preset(id).ok_or(TestAuthoringError::UnknownLensPreset)
}

fn color_target(
    id: &str,
    error: TestAuthoringError,
) -> Result<DeviceColorTarget, TestAuthoringError> {
    DeviceColorTarget::from_stable_id(id).ok_or(error)
}

fn selected_option(
    options: &'static [TestChoiceOption],
    id: &str,
    error: TestAuthoringError,
) -> Result<&'static str, TestAuthoringError> {
    options
        .iter()
        .find(|candidate| candidate.id == id)
        .map(|candidate| candidate.id)
        .ok_or(error)
}

fn default_output_for_input(input: OcioInputTransform) -> DeviceColorTarget {
    match input {
        OcioInputTransform::SrgbEncodedRec709 => DeviceColorTarget::SrgbDisplay,
        OcioInputTransform::Rec709Gamma24Display => DeviceColorTarget::Rec1886Rec709Display,
        _ => DeviceColorTarget::SrgbDisplay,
    }
}

pub fn default_test_authoring_selection(
    input_transform_id: &str,
    device_id: &str,
    frame_rate: f32,
) -> Result<ResolvedTestAuthoringSelection, TestAuthoringError> {
    let input = OcioInputTransform::from_stable_id(input_transform_id)
        .ok_or(TestAuthoringError::UnknownInputTransform)?;
    let output = default_output_for_input(input);
    let device = preset(device_id)?;
    let capture = capture("iphone-16e-main-48mp")?;
    let seed_distance = 0.15_f32;
    let seed_orbit_y = -5.0_f32;
    resolve_test_authoring_selection(TestAuthoringSelection {
        input_transform_id: input.stable_id(),
        output_signal_id: output.stable_id(),
        device_id: device.id,
        color_mode_id: device.default_color_mode_id,
        white_luminance_nits: device.reference_white_nits,
        placement_id: "fit",
        preview_quality_id: "draft",
        frame_rate,
        subpixel_geometry_amount: 1.0,
        panel_uniformity_amount: device.uniformity.character_strength,
        panel_light_spread_amount: device.light_spread.character_strength,
        capture_preset_id: capture.id,
        geometry_mode_id: "look-at",
        camera_distance_meters: seed_distance,
        camera_orbit_x_degrees: 0.0,
        camera_orbit_y_degrees: seed_orbit_y,
        camera_position_x_meters: seed_distance * seed_orbit_y.to_radians().sin(),
        camera_position_y_meters: 0.0,
        camera_position_z_meters: seed_distance * seed_orbit_y.to_radians().cos(),
        camera_rotation_x_degrees: 0.0,
        camera_rotation_y_degrees: seed_orbit_y,
        camera_rotation_z_degrees: 0.0,
        screen_position_x_meters: 0.0,
        screen_position_y_meters: 0.0,
        screen_position_z_meters: 0.0,
        screen_yaw_degrees: 0.0,
        screen_rotation_x_degrees: 0.0,
        screen_rotation_z_degrees: 0.0,
        cover_glass_preset_id: device.default_cover_glass_preset_id,
        cover_glass_amount: 1.0,
        cover_ag_microtexture_amount: cover_glass_preset(device.default_cover_glass_preset_id)
            .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?
            .profile
            .anti_glare_microtexture
            .character_strength,
        environment_preset_id: "environment-none",
        environment_amount: 0.0,
        cover_glow_amount: 1.0,
        lens_preset_id: capture.default_lens_preset_id,
        lens_amount: 1.0,
        autofocus_enabled: true,
        focus_distance_meters: 0.15,
        f_stop: capture.f_stop,
        exposure_time_seconds: capture.default_shutter_angle_degrees / 360.0 / frame_rate,
        shutter_motion_amount: 1.0,
        computational_character_strength: 1.0,
        computational_exposure_count: f32::from(capture.computational_capture.exposure_count),
        computational_bracket_spacing_stops: capture.computational_capture.bracket_spacing_stops,
        sensor_bloom_amount: 1.0,
        sensor_bloom_crosstalk_fraction: capture.sensor.bloom.crosstalk_fraction,
        sensor_bloom_overflow_transfer_fraction: capture.sensor.bloom.overflow_transfer_fraction,
        sensor_noise_amount: 1.0,
    })
}

pub fn resolve_test_authoring_selection(
    selection: TestAuthoringSelection<'_>,
) -> Result<ResolvedTestAuthoringSelection, TestAuthoringError> {
    let input = OcioInputTransform::from_stable_id(selection.input_transform_id)
        .ok_or(TestAuthoringError::UnknownInputTransform)?;
    let output = color_target(
        selection.output_signal_id,
        TestAuthoringError::UnknownOutputSignal,
    )?;
    let device = preset(selection.device_id)?;
    let mode = PanelColorMode::from_stable_id(selection.color_mode_id)
        .ok_or(TestAuthoringError::UnknownColorMode)?;
    if !device.color_mode_ids.contains(&mode.stable_id()) {
        return Err(TestAuthoringError::UnsupportedColorMode);
    }
    if !selection.white_luminance_nits.is_finite()
        || selection.white_luminance_nits < device.minimum_white_nits
        || selection.white_luminance_nits > device.maximum_white_nits
    {
        return Err(TestAuthoringError::InvalidWhiteLuminance);
    }
    let placement_id = selected_option(
        &PLACEMENTS,
        selection.placement_id,
        TestAuthoringError::UnknownPlacement,
    )?;
    let preview_quality_id = selected_option(
        &PREVIEW_QUALITIES,
        selection.preview_quality_id,
        TestAuthoringError::UnknownPreviewQuality,
    )?;
    if !selection.frame_rate.is_finite() || selection.frame_rate <= 0.0 {
        return Err(TestAuthoringError::InvalidExposureTime);
    }
    let geometry_mode_id = selected_option(
        &GEOMETRY_MODES,
        selection.geometry_mode_id,
        TestAuthoringError::InvalidGeometry,
    )?;
    if !selection.subpixel_geometry_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.subpixel_geometry_amount)
    {
        return Err(TestAuthoringError::InvalidSubpixelGeometryAmount);
    }
    if !selection.panel_uniformity_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.panel_uniformity_amount)
    {
        return Err(TestAuthoringError::InvalidPanelUniformityAmount);
    }
    if !selection.panel_light_spread_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.panel_light_spread_amount)
    {
        return Err(TestAuthoringError::InvalidPanelLightSpreadAmount);
    }
    let capture = capture(selection.capture_preset_id)?;
    let lens = lens(selection.lens_preset_id)?;
    if !capture.compatible_lens_preset_ids.contains(&lens.id) {
        return Err(TestAuthoringError::UnsupportedLensPreset);
    }
    let geometry = [
        selection.camera_distance_meters,
        selection.camera_orbit_x_degrees,
        selection.camera_orbit_y_degrees,
        selection.camera_position_x_meters,
        selection.camera_position_y_meters,
        selection.camera_position_z_meters,
        selection.camera_rotation_x_degrees,
        selection.camera_rotation_y_degrees,
        selection.camera_rotation_z_degrees,
        selection.screen_position_x_meters,
        selection.screen_position_y_meters,
        selection.screen_position_z_meters,
        selection.screen_yaw_degrees,
        selection.screen_rotation_x_degrees,
        selection.screen_rotation_z_degrees,
    ];
    if geometry.into_iter().any(|value| !value.is_finite())
        || !(0.01..=100.0).contains(&selection.camera_distance_meters)
        || selection.camera_orbit_x_degrees.abs() > 89.0
        || selection.camera_orbit_y_degrees.abs() > 180.0
        || selection.screen_yaw_degrees.abs() > 180.0
        || [
            selection.camera_position_x_meters,
            selection.camera_position_y_meters,
            selection.camera_position_z_meters,
            selection.screen_position_x_meters,
            selection.screen_position_y_meters,
            selection.screen_position_z_meters,
        ]
        .into_iter()
        .any(|value| value.abs() > 100.0)
        || [
            selection.camera_rotation_x_degrees,
            selection.camera_rotation_y_degrees,
            selection.camera_rotation_z_degrees,
            selection.screen_rotation_x_degrees,
            selection.screen_rotation_z_degrees,
        ]
        .into_iter()
        .any(|value| value.abs() > 180.0)
    {
        return Err(TestAuthoringError::InvalidGeometry);
    }
    let cover = cover_glass_preset(selection.cover_glass_preset_id)
        .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?;
    if !selection.cover_glass_amount.is_finite()
        || !(0.0..=2.0).contains(&selection.cover_glass_amount)
    {
        return Err(TestAuthoringError::InvalidCoverGlassAmount);
    }
    if !selection.cover_ag_microtexture_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.cover_ag_microtexture_amount)
    {
        return Err(TestAuthoringError::InvalidCoverAgMicrotextureAmount);
    }
    let environment = environment_preset(selection.environment_preset_id)
        .ok_or(TestAuthoringError::UnknownEnvironmentPreset)?;
    if !selection.environment_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.environment_amount)
    {
        return Err(TestAuthoringError::InvalidEnvironmentAmount);
    }
    if !selection.cover_glow_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.cover_glow_amount)
    {
        return Err(TestAuthoringError::InvalidCoverGlowAmount);
    }
    if !selection.lens_amount.is_finite() || !(0.0..=4.0).contains(&selection.lens_amount) {
        return Err(TestAuthoringError::InvalidLensAmount);
    }
    if !selection.focus_distance_meters.is_finite()
        || !(0.01..=100.0).contains(&selection.focus_distance_meters)
    {
        return Err(TestAuthoringError::InvalidFocusDistance);
    }
    if !selection.f_stop.is_finite() || !(0.7..=64.0).contains(&selection.f_stop) {
        return Err(TestAuthoringError::InvalidAperture);
    }
    if !selection.exposure_time_seconds.is_finite()
        || !(1.0 / 32_000.0..=60.0).contains(&selection.exposure_time_seconds)
    {
        return Err(TestAuthoringError::InvalidExposureTime);
    }
    let resolved_focus_distance_meters = if selection.autofocus_enabled {
        if geometry_mode_id == "look-at" {
            selection.camera_distance_meters
        } else {
            free_focus_distance(&selection)?
        }
    } else {
        selection.focus_distance_meters
    };
    if !selection.shutter_motion_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.shutter_motion_amount)
    {
        return Err(TestAuthoringError::InvalidShutterMotionAmount);
    }
    if !selection.computational_character_strength.is_finite()
        || !(0.0..=1.5).contains(&selection.computational_character_strength)
        || !selection.computational_exposure_count.is_finite()
        || !(1.0..=8.0).contains(&selection.computational_exposure_count)
        || selection.computational_exposure_count.fract() != 0.0
        || !selection.computational_bracket_spacing_stops.is_finite()
        || !(0.0..=1.0).contains(&selection.computational_bracket_spacing_stops)
    {
        return Err(TestAuthoringError::InvalidComputationalCapture);
    }
    if !selection.sensor_bloom_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.sensor_bloom_amount)
    {
        return Err(TestAuthoringError::InvalidSensorBloomAmount);
    }
    if !selection.sensor_bloom_crosstalk_fraction.is_finite()
        || !(0.0..=0.20).contains(&selection.sensor_bloom_crosstalk_fraction)
        || !selection
            .sensor_bloom_overflow_transfer_fraction
            .is_finite()
        || !(0.0..=1.0).contains(&selection.sensor_bloom_overflow_transfer_fraction)
        || selection.sensor_bloom_crosstalk_fraction * selection.sensor_bloom_amount > 0.80
        || selection.sensor_bloom_overflow_transfer_fraction * selection.sensor_bloom_amount > 1.0
    {
        return Err(TestAuthoringError::InvalidSensorBloomProfile);
    }
    if !selection.sensor_noise_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.sensor_noise_amount)
    {
        return Err(TestAuthoringError::InvalidSensorNoiseAmount);
    }
    Ok(ResolvedTestAuthoringSelection {
        input_transform_id: input.stable_id(),
        output_signal_id: output.stable_id(),
        device_id: device.id,
        color_mode_id: mode.stable_id(),
        device_eotf_gamma: mode.eotf_gamma(),
        white_luminance_nits: selection.white_luminance_nits,
        placement_id,
        preview_quality_id,
        frame_rate: selection.frame_rate,
        subpixel_geometry_amount: selection.subpixel_geometry_amount,
        panel_uniformity_amount: selection.panel_uniformity_amount,
        panel_light_spread_amount: selection.panel_light_spread_amount,
        capture_preset_id: capture.id,
        geometry_mode_id,
        camera_distance_meters: selection.camera_distance_meters,
        camera_orbit_x_degrees: selection.camera_orbit_x_degrees,
        camera_orbit_y_degrees: selection.camera_orbit_y_degrees,
        camera_position_x_meters: selection.camera_position_x_meters,
        camera_position_y_meters: selection.camera_position_y_meters,
        camera_position_z_meters: selection.camera_position_z_meters,
        camera_rotation_x_degrees: selection.camera_rotation_x_degrees,
        camera_rotation_y_degrees: selection.camera_rotation_y_degrees,
        camera_rotation_z_degrees: selection.camera_rotation_z_degrees,
        screen_position_x_meters: selection.screen_position_x_meters,
        screen_position_y_meters: selection.screen_position_y_meters,
        screen_position_z_meters: selection.screen_position_z_meters,
        screen_yaw_degrees: selection.screen_yaw_degrees,
        screen_rotation_x_degrees: selection.screen_rotation_x_degrees,
        screen_rotation_z_degrees: selection.screen_rotation_z_degrees,
        cover_glass_preset_id: cover.id,
        cover_glass_amount: selection.cover_glass_amount,
        cover_ag_microtexture_amount: selection.cover_ag_microtexture_amount,
        environment_preset_id: environment.id,
        environment_amount: selection.environment_amount,
        cover_glow_amount: selection.cover_glow_amount,
        lens_preset_id: lens.id,
        lens_amount: selection.lens_amount,
        autofocus_enabled: selection.autofocus_enabled,
        focus_distance_meters: resolved_focus_distance_meters,
        f_stop: selection.f_stop,
        exposure_time_seconds: selection.exposure_time_seconds,
        shutter_motion_amount: selection.shutter_motion_amount,
        computational_character_strength: selection.computational_character_strength,
        computational_exposure_count: selection.computational_exposure_count,
        computational_bracket_spacing_stops: selection.computational_bracket_spacing_stops,
        sensor_bloom_amount: selection.sensor_bloom_amount,
        sensor_bloom_crosstalk_fraction: selection.sensor_bloom_crosstalk_fraction,
        sensor_bloom_overflow_transfer_fraction: selection.sensor_bloom_overflow_transfer_fraction,
        sensor_noise_amount: selection.sensor_noise_amount,
    })
}

fn free_focus_distance(selection: &TestAuthoringSelection<'_>) -> Result<f32, TestAuthoringError> {
    let camera = euler_quaternion([
        selection.camera_rotation_x_degrees,
        selection.camera_rotation_y_degrees,
        selection.camera_rotation_z_degrees,
    ]);
    let screen = euler_quaternion([
        selection.screen_rotation_x_degrees,
        selection.screen_yaw_degrees,
        selection.screen_rotation_z_degrees,
    ]);
    let forward = [
        -2.0 * (camera[0] * camera[2] + camera[3] * camera[1]),
        -2.0 * (camera[1] * camera[2] - camera[3] * camera[0]),
        -(1.0 - 2.0 * (camera[0] * camera[0] + camera[1] * camera[1])),
    ];
    let normal = [
        2.0 * (screen[0] * screen[2] + screen[3] * screen[1]),
        2.0 * (screen[1] * screen[2] - screen[3] * screen[0]),
        1.0 - 2.0 * (screen[0] * screen[0] + screen[1] * screen[1]),
    ];
    let offset = [
        selection.screen_position_x_meters - selection.camera_position_x_meters,
        selection.screen_position_y_meters - selection.camera_position_y_meters,
        selection.screen_position_z_meters - selection.camera_position_z_meters,
    ];
    let denominator = dot3(forward, normal);
    if denominator.abs() <= 1.0e-6 {
        return Err(TestAuthoringError::InvalidGeometry);
    }
    let distance = dot3(offset, normal) / denominator;
    if !distance.is_finite() || !(0.01..=100.0).contains(&distance) {
        return Err(TestAuthoringError::InvalidGeometry);
    }
    Ok(distance)
}

fn euler_quaternion(degrees: [f32; 3]) -> [f32; 4] {
    let half_x = degrees[0].to_radians() * 0.5;
    let half_y = degrees[1].to_radians() * 0.5;
    let half_z = degrees[2].to_radians() * 0.5;
    let (sx, cx) = half_x.sin_cos();
    let (sy, cy) = half_y.sin_cos();
    let (sz, cz) = half_z.sin_cos();
    [
        sx * cy * cz - cx * sy * sz,
        cx * sy * cz + sx * cy * sz,
        cx * cy * sz - sx * sy * cz,
        cx * cy * cz + sx * sy * sz,
    ]
}

fn dot3(lhs: [f32; 3], rhs: [f32; 3]) -> f32 {
    lhs[0] * rhs[0] + lhs[1] * rhs[1] + lhs[2] * rhs[2]
}

pub fn test_page_descriptor(
    selection: TestAuthoringSelection<'_>,
) -> Result<TestPageDescriptor, TestAuthoringError> {
    let selection = resolve_test_authoring_selection(selection)?;
    let device = preset(selection.device_id)?;
    let output_options = DeviceColorTarget::ALL
        .into_iter()
        .map(|target| TestChoiceOption {
            id: target.stable_id(),
            label: target.label(),
        })
        .collect();
    let device_options = DEVICE_PRESETS
        .iter()
        .map(|preset| TestChoiceOption {
            id: preset.id,
            label: preset.label,
        })
        .collect();
    let color_options = device
        .color_mode_ids
        .iter()
        .map(|id| {
            let mode = PanelColorMode::from_stable_id(id)
                .expect("validated Device presets use known Color Modes");
            TestChoiceOption {
                id: mode.stable_id(),
                label: mode.label(),
            }
        })
        .collect();
    let capture = capture(selection.capture_preset_id)?;
    let capture_options = CAPTURE_DEVICE_PRESETS
        .iter()
        .map(|preset| TestChoiceOption {
            id: preset.id,
            label: preset.label,
        })
        .collect();
    let lens_options = capture
        .compatible_lens_preset_ids
        .iter()
        .map(|id| {
            let preset = lens(id).expect("validated Camera presets reference current Lenses");
            TestChoiceOption {
                id: preset.id,
                label: preset.label,
            }
        })
        .collect();
    let cover_options = COVER_GLASS_PRESETS
        .iter()
        .map(|preset| TestChoiceOption {
            id: preset.id,
            label: preset.label,
        })
        .collect();
    let environment_options = ENVIRONMENT_PRESETS
        .iter()
        .map(|preset| TestChoiceOption {
            id: preset.id,
            label: preset.label,
        })
        .collect();
    let input = OcioInputTransform::from_stable_id(selection.input_transform_id)
        .ok_or(TestAuthoringError::UnknownInputTransform)?;
    let reset_output_signal_id = default_output_for_input(input).stable_id();
    let reset_device = preset("lcd-asus-proart-pa329cv")?;
    let reset_capture = capture_device_preset("iphone-16e-main-48mp")
        .ok_or(TestAuthoringError::UnknownCapturePreset)?;
    let selected_cover = cover_glass_preset(selection.cover_glass_preset_id)
        .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?;
    let selected_environment = environment_preset(selection.environment_preset_id)
        .ok_or(TestAuthoringError::UnknownEnvironmentPreset)?;
    let seed_distance = 0.15_f32;
    let seed_orbit_y = -5.0_f32;
    let seed_camera_x = seed_distance * seed_orbit_y.to_radians().sin();
    let seed_camera_z = seed_distance * seed_orbit_y.to_radians().cos();
    let mut geometry_controls = vec![
        choice_control(
            CAPTURE_PRESET_CONTROL_ID,
            "Cámara",
            capture_options,
            selection.capture_preset_id,
            reset_capture.id,
        ),
        choice_control(
            GEOMETRY_MODE_CONTROL_ID,
            "Modo",
            GEOMETRY_MODES.to_vec(),
            selection.geometry_mode_id,
            "look-at",
        ),
    ];
    if selection.geometry_mode_id == "look-at" {
        geometry_controls.extend([
            scalar_control(
                CAMERA_DISTANCE_CONTROL_ID,
                "Distancia cámara",
                selection.camera_distance_meters,
                0.05,
                5.0,
                seed_distance,
                "m",
            ),
            scalar_control(
                CAMERA_ORBIT_X_CONTROL_ID,
                "Orientación X cámara",
                selection.camera_orbit_x_degrees,
                -89.0,
                89.0,
                0.0,
                "°",
            ),
            scalar_control(
                CAMERA_ORBIT_Y_CONTROL_ID,
                "Orientación Y cámara",
                selection.camera_orbit_y_degrees,
                -180.0,
                180.0,
                seed_orbit_y,
                "°",
            ),
            scalar_control(
                SCREEN_POSITION_X_CONTROL_ID,
                "Pantalla X",
                selection.screen_position_x_meters,
                -5.0,
                5.0,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Y_CONTROL_ID,
                "Pantalla Y",
                selection.screen_position_y_meters,
                -5.0,
                5.0,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Z_CONTROL_ID,
                "Pantalla Z",
                selection.screen_position_z_meters,
                -5.0,
                5.0,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_YAW_CONTROL_ID,
                "Rotación Y pantalla",
                selection.screen_yaw_degrees,
                -180.0,
                180.0,
                0.0,
                "°",
            ),
        ]);
    } else {
        geometry_controls.extend([
            scalar_control(
                CAMERA_POSITION_X_CONTROL_ID,
                "Cámara X",
                selection.camera_position_x_meters,
                -5.0,
                5.0,
                seed_camera_x,
                "m",
            ),
            scalar_control(
                CAMERA_POSITION_Y_CONTROL_ID,
                "Cámara Y",
                selection.camera_position_y_meters,
                -5.0,
                5.0,
                0.0,
                "m",
            ),
            scalar_control(
                CAMERA_POSITION_Z_CONTROL_ID,
                "Cámara Z",
                selection.camera_position_z_meters,
                -5.0,
                5.0,
                seed_camera_z,
                "m",
            ),
            scalar_control(
                CAMERA_ROTATION_X_CONTROL_ID,
                "Rotación X cámara",
                selection.camera_rotation_x_degrees,
                -180.0,
                180.0,
                0.0,
                "°",
            ),
            scalar_control(
                CAMERA_ROTATION_Y_CONTROL_ID,
                "Rotación Y cámara",
                selection.camera_rotation_y_degrees,
                -180.0,
                180.0,
                seed_orbit_y,
                "°",
            ),
            scalar_control(
                CAMERA_ROTATION_Z_CONTROL_ID,
                "Rotación Z cámara",
                selection.camera_rotation_z_degrees,
                -180.0,
                180.0,
                0.0,
                "°",
            ),
            scalar_control(
                SCREEN_POSITION_X_CONTROL_ID,
                "Pantalla X",
                selection.screen_position_x_meters,
                -5.0,
                5.0,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Y_CONTROL_ID,
                "Pantalla Y",
                selection.screen_position_y_meters,
                -5.0,
                5.0,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Z_CONTROL_ID,
                "Pantalla Z",
                selection.screen_position_z_meters,
                -5.0,
                5.0,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_ROTATION_X_CONTROL_ID,
                "Rotación X pantalla",
                selection.screen_rotation_x_degrees,
                -180.0,
                180.0,
                0.0,
                "°",
            ),
            scalar_control(
                SCREEN_YAW_CONTROL_ID,
                "Rotación Y pantalla",
                selection.screen_yaw_degrees,
                -180.0,
                180.0,
                0.0,
                "°",
            ),
            scalar_control(
                SCREEN_ROTATION_Z_CONTROL_ID,
                "Rotación Z pantalla",
                selection.screen_rotation_z_degrees,
                -180.0,
                180.0,
                0.0,
                "°",
            ),
        ]);
    }
    let mut lens_controls = vec![
        choice_control(
            LENS_PRESET_CONTROL_ID,
            "Objetivo",
            lens_options,
            selection.lens_preset_id,
            capture.default_lens_preset_id,
        ),
        scalar_control(
            LENS_AMOUNT_CONTROL_ID,
            "Carácter del objetivo",
            selection.lens_amount,
            0.0,
            4.0,
            1.0,
            "×",
        ),
        toggle_control(
            AUTOFOCUS_CONTROL_ID,
            "Autofocus",
            selection.autofocus_enabled,
            true,
        ),
        scalar_control(
            F_STOP_CONTROL_ID,
            "Diafragma",
            selection.f_stop,
            0.7,
            64.0,
            capture.f_stop,
            "f/",
        ),
    ];
    if !selection.autofocus_enabled {
        lens_controls.push(scalar_control(
            FOCUS_DISTANCE_CONTROL_ID,
            "Distancia de foco",
            selection.focus_distance_meters,
            0.05,
            5.0,
            seed_distance,
            "m",
        ));
    }
    Ok(TestPageDescriptor {
        schema_version: TEST_AUTHORING_SCHEMA_VERSION,
        default_preview_phase_id: DEVELOP_DEMOSAIC_PHASE_ID,
        selection,
        phases: vec![
            TestPhaseDescriptor {
                id: ORIGIN_PHASE_ID,
                label: "Origen",
                effect_summary: "Interpreta la fuente y establece el raster lineal ACEScg canónico.",
                header_control_id: None,
                input_artifact: "encoded-source-raster-v1",
                output_artifact: "linear-acescg-raster-v1",
                preview_result: TestPreviewResult::SourceAcesCg,
                controls: Vec::new(),
            },
            TestPhaseDescriptor {
                id: FEEDER_SIGNAL_PHASE_ID,
                label: "Salida del feeder",
                effect_summary: "Codifica y coloca la señal que recibe el dispositivo.",
                header_control_id: None,
                input_artifact: "linear-acescg-raster-v1",
                output_artifact: "placed-feeder-signal-v1",
                preview_result: TestPreviewResult::FeederSignal,
                controls: vec![
                    choice_control(
                        OUTPUT_SIGNAL_CONTROL_ID,
                        "Output Signal",
                        output_options,
                        selection.output_signal_id,
                        reset_output_signal_id,
                    ),
                    choice_control(
                        PLACEMENT_CONTROL_ID,
                        "Colocación",
                        PLACEMENTS.to_vec(),
                        selection.placement_id,
                        "fit",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: DEVICE_INTERPRETATION_PHASE_ID,
                label: "Mapeo e interpretación del dispositivo",
                effect_summary: "Interpreta la señal según el modo de color y luminancia del dispositivo.",
                header_control_id: None,
                input_artifact: "placed-feeder-signal-v1",
                output_artifact: "panel-emission-radiance-v1",
                preview_result: TestPreviewResult::DeviceInterpretation,
                controls: vec![
                    choice_control(
                        DEVICE_CONTROL_ID,
                        "Device",
                        device_options,
                        device.id,
                        reset_device.id,
                    ),
                    choice_control(
                        COLOR_MODE_CONTROL_ID,
                        "Color Mode",
                        color_options,
                        selection.color_mode_id,
                        device.default_color_mode_id,
                    ),
                    scalar_control(
                        WHITE_LUMINANCE_CONTROL_ID,
                        "White Luminance",
                        selection.white_luminance_nits,
                        device.minimum_white_nits,
                        device.maximum_white_nits,
                        device.reference_white_nits,
                        "cd/m²",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: PANEL_STRUCTURE_PHASE_ID,
                label: "Trama del panel",
                effect_summary: "Introduce trama RGB/BGR, subpíxeles y matriz negra; determina el moiré espacial.",
                header_control_id: Some(SUBPIXEL_GEOMETRY_CONTROL_ID),
                input_artifact: "panel-emission-radiance-v1",
                output_artifact: "subpixel-radiance-v1",
                preview_result: TestPreviewResult::PanelStructure,
                controls: vec![scalar_control(
                    SUBPIXEL_GEOMETRY_CONTROL_ID,
                    "Trama / subpíxel",
                    selection.subpixel_geometry_amount,
                    0.0,
                    4.0,
                    1.0,
                    "×",
                )],
            },
            TestPhaseDescriptor {
                id: PANEL_UNIFORMITY_PHASE_ID,
                label: "Uniformidad del panel",
                effect_summary: "Introduce la variación espacial fija de luminancia y color residual del dispositivo.",
                header_control_id: Some(PANEL_UNIFORMITY_CONTROL_ID),
                input_artifact: "subpixel-radiance-v1",
                output_artifact: "uniform-panel-radiance-v1",
                preview_result: TestPreviewResult::PanelUniformity,
                controls: vec![scalar_control(
                    PANEL_UNIFORMITY_CONTROL_ID,
                    "Uniformidad espacial",
                    selection.panel_uniformity_amount,
                    0.0,
                    4.0,
                    device.uniformity.character_strength,
                    "×",
                )],
            },
            TestPhaseDescriptor {
                id: PANEL_LIGHT_SPREAD_PHASE_ID,
                label: "Dispersión de luz del panel",
                effect_summary: "Difunde la emisión entre celdas y suaviza la estructura fina del panel.",
                header_control_id: Some(PANEL_LIGHT_SPREAD_CONTROL_ID),
                input_artifact: "uniform-panel-radiance-v1",
                output_artifact: "spread-panel-radiance-v1",
                preview_result: TestPreviewResult::PanelLightSpread,
                controls: vec![scalar_control(
                    PANEL_LIGHT_SPREAD_CONTROL_ID,
                    "Dispersión del panel",
                    selection.panel_light_spread_amount,
                    0.0,
                    4.0,
                    device.light_spread.character_strength,
                    "×",
                )],
            },
            TestPhaseDescriptor {
                id: RELATIVE_GEOMETRY_PHASE_ID,
                label: "Geometría relativa",
                effect_summary: "Sitúa cámara y pantalla y determina perspectiva, encuadre e incidencia.",
                header_control_id: None,
                input_artifact: "spread-panel-radiance-v1",
                output_artifact: "resolved-observation-geometry-v1",
                preview_result: TestPreviewResult::RelativeGeometry,
                controls: geometry_controls,
            },
            TestPhaseDescriptor {
                id: COVER_ENVIRONMENT_PHASE_ID,
                label: "Cristal y entorno",
                effect_summary: "Añade transmisión, reflejos, contraste angular y carácter superficial.",
                header_control_id: Some(COVER_GLASS_AMOUNT_CONTROL_ID),
                input_artifact: "resolved-observation-geometry-v1",
                output_artifact: "covered-directional-radiance-v1",
                preview_result: TestPreviewResult::CoverEnvironment,
                controls: vec![
                    choice_control(
                        COVER_GLASS_CONTROL_ID,
                        "Cristal",
                        cover_options,
                        selection.cover_glass_preset_id,
                        device.default_cover_glass_preset_id,
                    ),
                    scalar_control(
                        COVER_GLASS_AMOUNT_CONTROL_ID,
                        "Carácter del cristal",
                        selection.cover_glass_amount,
                        0.0,
                        2.0,
                        selected_cover.profile.character_strength,
                        "×",
                    ),
                    scalar_control(
                        COVER_AG_MICROTEXTURE_AMOUNT_CONTROL_ID,
                        "Microtextura antirreflejos",
                        selection.cover_ag_microtexture_amount,
                        0.0,
                        4.0,
                        selected_cover
                            .profile
                            .anti_glare_microtexture
                            .character_strength,
                        "×",
                    ),
                    choice_control(
                        ENVIRONMENT_CONTROL_ID,
                        "Entorno",
                        environment_options,
                        selection.environment_preset_id,
                        "environment-none",
                    ),
                    scalar_control(
                        ENVIRONMENT_AMOUNT_CONTROL_ID,
                        "Carácter del entorno",
                        selection.environment_amount,
                        0.0,
                        1.5,
                        selected_environment.environment.character_strength,
                        "×",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: COVER_GLOW_PHASE_ID,
                label: "Resplandor del cristal",
                effect_summary: "Redistribuye luz intensa dentro del cristal, incluso fuera del área activa.",
                header_control_id: Some(COVER_GLOW_AMOUNT_CONTROL_ID),
                input_artifact: "covered-directional-radiance-v1",
                output_artifact: "glass-scattered-radiance-v1",
                preview_result: TestPreviewResult::CoverGlow,
                controls: vec![scalar_control(
                    COVER_GLOW_AMOUNT_CONTROL_ID,
                    "Carácter del resplandor",
                    selection.cover_glow_amount,
                    0.0,
                    4.0,
                    selected_cover.profile.glow.character_strength,
                    "×",
                )],
            },
            TestPhaseDescriptor {
                id: LENS_PROJECTION_PHASE_ID,
                label: "Objetivo y proyección",
                effect_summary: "Aplica proyección, foco, distorsión, aberración cromática, viñeteo y PSF.",
                header_control_id: Some(LENS_AMOUNT_CONTROL_ID),
                input_artifact: "glass-scattered-radiance-v1",
                output_artifact: "image-plane-illuminance-acescg-v1",
                preview_result: TestPreviewResult::LensProjection,
                controls: lens_controls,
            },
            TestPhaseDescriptor {
                id: SHUTTER_EXPOSURE_PHASE_ID,
                label: "Exposición y obturador",
                effect_summary: "Integra diafragma, tiempo de exposición, ND y comportamiento temporal.",
                header_control_id: Some(SHUTTER_AMOUNT_CONTROL_ID),
                input_artifact: "image-plane-illuminance-acescg-v1",
                output_artifact: "integrated-optical-exposure-v1",
                preview_result: TestPreviewResult::ShutterExposure,
                controls: vec![
                    scalar_control(
                        SHUTTER_AMOUNT_CONTROL_ID,
                        "Carácter del obturador",
                        selection.shutter_motion_amount,
                        0.0,
                        1.0,
                        1.0,
                        "×",
                    ),
                    scalar_control(
                        SHUTTER_ANGLE_CONTROL_ID,
                        "Ángulo de obturación",
                        selection.exposure_time_seconds * selection.frame_rate * 360.0,
                        1.0,
                        360.0,
                        capture.default_shutter_angle_degrees,
                        "°",
                    ),
                    scalar_field_control(
                        SHUTTER_RECIPROCAL_CONTROL_ID,
                        "Velocidad de obturación",
                        1.0 / selection.exposure_time_seconds,
                        1.0 / 60.0,
                        32_000.0,
                        360.0 * selection.frame_rate / capture.default_shutter_angle_degrees,
                        "1/s",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: COMPUTATIONAL_CAPTURE_PHASE_ID,
                label: "Captura computacional",
                effect_summary: "Combina analíticamente una horquilla de exposiciones sin repetir la óptica.",
                header_control_id: Some(COMPUTATIONAL_CAPTURE_AMOUNT_CONTROL_ID),
                input_artifact: "integrated-optical-exposure-v1",
                output_artifact: "computational-capture-exposure-v2",
                preview_result: TestPreviewResult::ComputationalCapture,
                controls: vec![
                    scalar_control(
                        COMPUTATIONAL_CAPTURE_AMOUNT_CONTROL_ID,
                        "Carácter de captura computacional",
                        selection.computational_character_strength,
                        0.0,
                        4.0,
                        1.0,
                        "×",
                    ),
                    scalar_field_control(
                        COMPUTATIONAL_EXPOSURE_COUNT_CONTROL_ID,
                        "Número de exposiciones",
                        selection.computational_exposure_count,
                        1.0,
                        8.0,
                        f32::from(capture.computational_capture.exposure_count),
                        "exposiciones",
                    ),
                    scalar_control(
                        COMPUTATIONAL_BRACKET_SPACING_CONTROL_ID,
                        "Separación de la horquilla",
                        selection.computational_bracket_spacing_stops,
                        0.0,
                        4.0,
                        capture.computational_capture.bracket_spacing_stops,
                        "EV",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: SENSOR_BLOOM_PHASE_ID,
                label: "Crosstalk y bloom del sensor",
                effect_summary: "Transfiere carga entre fotositos y desborda altas luces saturadas.",
                header_control_id: Some(SENSOR_BLOOM_AMOUNT_CONTROL_ID),
                input_artifact: "computational-capture-exposure-v2",
                output_artifact: "coupled-sensor-charge-v1",
                preview_result: TestPreviewResult::SensorBloom,
                controls: vec![
                    scalar_control(
                        SENSOR_BLOOM_AMOUNT_CONTROL_ID,
                        "Carácter del bloom",
                        selection.sensor_bloom_amount,
                        0.0,
                        4.0,
                        capture.sensor.bloom.character_strength,
                        "×",
                    ),
                    scalar_control(
                        SENSOR_BLOOM_CROSSTALK_CONTROL_ID,
                        "Crosstalk entre fotositos",
                        selection.sensor_bloom_crosstalk_fraction,
                        0.0,
                        0.20,
                        capture.sensor.bloom.crosstalk_fraction,
                        "fracción",
                    ),
                    scalar_control(
                        SENSOR_BLOOM_OVERFLOW_CONTROL_ID,
                        "Transferencia de desborde",
                        selection.sensor_bloom_overflow_transfer_fraction,
                        0.0,
                        1.0,
                        capture.sensor.bloom.overflow_transfer_fraction,
                        "fracción",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: SENSOR_CFA_PHASE_ID,
                label: "Sensor y CFA",
                effect_summary: "Convierte la exposición óptica en carga mosaico Bayer limpia.",
                header_control_id: None,
                input_artifact: "coupled-sensor-charge-v1",
                output_artifact: "raw-mosaic-clean-v1",
                preview_result: TestPreviewResult::SensorCfa,
                controls: Vec::new(),
            },
            TestPhaseDescriptor {
                id: SENSOR_NOISE_PHASE_ID,
                label: "Ruido del sensor",
                effect_summary: "Añade ruido físico de lectura, corriente oscura y cuantización.",
                header_control_id: Some(SENSOR_NOISE_AMOUNT_CONTROL_ID),
                input_artifact: "raw-mosaic-clean-v1",
                output_artifact: "raw-mosaic-noisy-v1",
                preview_result: TestPreviewResult::SensorNoise,
                controls: vec![scalar_control(
                    SENSOR_NOISE_AMOUNT_CONTROL_ID,
                    "Carácter del ruido",
                    selection.sensor_noise_amount,
                    0.0,
                    4.0,
                    1.0,
                    "×",
                )],
            },
            TestPhaseDescriptor {
                id: DEVELOP_DEMOSAIC_PHASE_ID,
                label: "Revelado y demosaico",
                effect_summary: "Aplica balance, revelado y demosaico para obtener ACEScg de cámara.",
                header_control_id: None,
                input_artifact: "raw-mosaic-noisy-v1",
                output_artifact: "developed-camera-acescg-v1",
                preview_result: TestPreviewResult::DevelopDemosaic,
                controls: Vec::new(),
            },
        ],
        preview_controls: vec![choice_control(
            PREVIEW_QUALITY_CONTROL_ID,
            "Calidad",
            PREVIEW_QUALITIES.to_vec(),
            selection.preview_quality_id,
            "draft",
        )],
    })
}

pub fn apply_test_choice(
    selection: TestAuthoringSelection<'_>,
    control_id: &str,
    option_id: &str,
) -> Result<ResolvedTestAuthoringSelection, TestAuthoringError> {
    let current = resolve_test_authoring_selection(selection)?;
    let mut next = unresolved_test_selection(current);
    match control_id {
        OUTPUT_SIGNAL_CONTROL_ID => next.output_signal_id = option_id,
        DEVICE_CONTROL_ID => {
            let device = preset(option_id)?;
            next.device_id = device.id;
            next.color_mode_id = device.default_color_mode_id;
            next.white_luminance_nits = device.reference_white_nits;
            next.panel_uniformity_amount = device.uniformity.character_strength;
            next.panel_light_spread_amount = device.light_spread.character_strength;
            next.cover_glass_preset_id = device.default_cover_glass_preset_id;
            next.cover_glass_amount = cover_glass_preset(device.default_cover_glass_preset_id)
                .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?
                .profile
                .character_strength;
            next.cover_ag_microtexture_amount =
                cover_glass_preset(device.default_cover_glass_preset_id)
                    .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?
                    .profile
                    .anti_glare_microtexture
                    .character_strength;
            next.cover_glow_amount = cover_glass_preset(device.default_cover_glass_preset_id)
                .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?
                .profile
                .glow
                .character_strength;
        }
        COLOR_MODE_CONTROL_ID => next.color_mode_id = option_id,
        PLACEMENT_CONTROL_ID => next.placement_id = option_id,
        PREVIEW_QUALITY_CONTROL_ID => next.preview_quality_id = option_id,
        CAPTURE_PRESET_CONTROL_ID => {
            let capture = capture(option_id)?;
            next.capture_preset_id = capture.id;
            next.lens_preset_id = capture.default_lens_preset_id;
            next.f_stop = capture.f_stop;
            next.exposure_time_seconds =
                capture.default_shutter_angle_degrees / 360.0 / current.frame_rate;
            next.computational_character_strength = 1.0;
            next.computational_exposure_count =
                f32::from(capture.computational_capture.exposure_count);
            next.computational_bracket_spacing_stops =
                capture.computational_capture.bracket_spacing_stops;
            next.sensor_bloom_amount = capture.sensor.bloom.character_strength;
            next.sensor_bloom_crosstalk_fraction = capture.sensor.bloom.crosstalk_fraction;
            next.sensor_bloom_overflow_transfer_fraction =
                capture.sensor.bloom.overflow_transfer_fraction;
        }
        GEOMETRY_MODE_CONTROL_ID => apply_geometry_mode(&mut next, option_id)?,
        COVER_GLASS_CONTROL_ID => {
            let cover =
                cover_glass_preset(option_id).ok_or(TestAuthoringError::UnknownCoverGlassPreset)?;
            next.cover_glass_preset_id = cover.id;
            next.cover_glass_amount = cover.profile.character_strength;
            next.cover_ag_microtexture_amount =
                cover.profile.anti_glare_microtexture.character_strength;
            next.cover_glow_amount = cover.profile.glow.character_strength;
        }
        ENVIRONMENT_CONTROL_ID => {
            let environment = environment_preset(option_id)
                .ok_or(TestAuthoringError::UnknownEnvironmentPreset)?;
            next.environment_preset_id = environment.id;
            next.environment_amount = environment.environment.character_strength;
        }
        LENS_PRESET_CONTROL_ID => next.lens_preset_id = option_id,
        WHITE_LUMINANCE_CONTROL_ID
        | SUBPIXEL_GEOMETRY_CONTROL_ID
        | PANEL_UNIFORMITY_CONTROL_ID
        | PANEL_LIGHT_SPREAD_CONTROL_ID
        | CAMERA_DISTANCE_CONTROL_ID
        | CAMERA_ORBIT_X_CONTROL_ID
        | CAMERA_ORBIT_Y_CONTROL_ID
        | CAMERA_POSITION_X_CONTROL_ID
        | CAMERA_POSITION_Y_CONTROL_ID
        | CAMERA_POSITION_Z_CONTROL_ID
        | CAMERA_ROTATION_X_CONTROL_ID
        | CAMERA_ROTATION_Y_CONTROL_ID
        | CAMERA_ROTATION_Z_CONTROL_ID
        | SCREEN_POSITION_X_CONTROL_ID
        | SCREEN_POSITION_Y_CONTROL_ID
        | SCREEN_POSITION_Z_CONTROL_ID
        | SCREEN_YAW_CONTROL_ID
        | SCREEN_ROTATION_X_CONTROL_ID
        | SCREEN_ROTATION_Z_CONTROL_ID
        | COVER_GLASS_AMOUNT_CONTROL_ID
        | COVER_AG_MICROTEXTURE_AMOUNT_CONTROL_ID
        | ENVIRONMENT_AMOUNT_CONTROL_ID
        | COVER_GLOW_AMOUNT_CONTROL_ID
        | LENS_AMOUNT_CONTROL_ID
        | AUTOFOCUS_CONTROL_ID
        | F_STOP_CONTROL_ID
        | SHUTTER_ANGLE_CONTROL_ID
        | SHUTTER_RECIPROCAL_CONTROL_ID
        | FOCUS_DISTANCE_CONTROL_ID
        | SHUTTER_AMOUNT_CONTROL_ID
        | COMPUTATIONAL_CAPTURE_AMOUNT_CONTROL_ID
        | COMPUTATIONAL_EXPOSURE_COUNT_CONTROL_ID
        | COMPUTATIONAL_BRACKET_SPACING_CONTROL_ID
        | SENSOR_BLOOM_AMOUNT_CONTROL_ID
        | SENSOR_BLOOM_CROSSTALK_CONTROL_ID
        | SENSOR_BLOOM_OVERFLOW_CONTROL_ID
        | SENSOR_NOISE_AMOUNT_CONTROL_ID => return Err(TestAuthoringError::WrongControlType),
        _ => return Err(TestAuthoringError::UnknownControl),
    }
    resolve_test_authoring_selection(next)
}

fn unresolved_test_selection(
    current: ResolvedTestAuthoringSelection,
) -> TestAuthoringSelection<'static> {
    TestAuthoringSelection {
        input_transform_id: current.input_transform_id,
        output_signal_id: current.output_signal_id,
        device_id: current.device_id,
        color_mode_id: current.color_mode_id,
        white_luminance_nits: current.white_luminance_nits,
        placement_id: current.placement_id,
        preview_quality_id: current.preview_quality_id,
        frame_rate: current.frame_rate,
        subpixel_geometry_amount: current.subpixel_geometry_amount,
        panel_uniformity_amount: current.panel_uniformity_amount,
        panel_light_spread_amount: current.panel_light_spread_amount,
        capture_preset_id: current.capture_preset_id,
        geometry_mode_id: current.geometry_mode_id,
        camera_distance_meters: current.camera_distance_meters,
        camera_orbit_x_degrees: current.camera_orbit_x_degrees,
        camera_orbit_y_degrees: current.camera_orbit_y_degrees,
        camera_position_x_meters: current.camera_position_x_meters,
        camera_position_y_meters: current.camera_position_y_meters,
        camera_position_z_meters: current.camera_position_z_meters,
        camera_rotation_x_degrees: current.camera_rotation_x_degrees,
        camera_rotation_y_degrees: current.camera_rotation_y_degrees,
        camera_rotation_z_degrees: current.camera_rotation_z_degrees,
        screen_position_x_meters: current.screen_position_x_meters,
        screen_position_y_meters: current.screen_position_y_meters,
        screen_position_z_meters: current.screen_position_z_meters,
        screen_yaw_degrees: current.screen_yaw_degrees,
        screen_rotation_x_degrees: current.screen_rotation_x_degrees,
        screen_rotation_z_degrees: current.screen_rotation_z_degrees,
        cover_glass_preset_id: current.cover_glass_preset_id,
        cover_glass_amount: current.cover_glass_amount,
        cover_ag_microtexture_amount: current.cover_ag_microtexture_amount,
        environment_preset_id: current.environment_preset_id,
        environment_amount: current.environment_amount,
        cover_glow_amount: current.cover_glow_amount,
        lens_preset_id: current.lens_preset_id,
        lens_amount: current.lens_amount,
        autofocus_enabled: current.autofocus_enabled,
        focus_distance_meters: current.focus_distance_meters,
        f_stop: current.f_stop,
        exposure_time_seconds: current.exposure_time_seconds,
        shutter_motion_amount: current.shutter_motion_amount,
        computational_character_strength: current.computational_character_strength,
        computational_exposure_count: current.computational_exposure_count,
        computational_bracket_spacing_stops: current.computational_bracket_spacing_stops,
        sensor_bloom_amount: current.sensor_bloom_amount,
        sensor_bloom_crosstalk_fraction: current.sensor_bloom_crosstalk_fraction,
        sensor_bloom_overflow_transfer_fraction: current.sensor_bloom_overflow_transfer_fraction,
        sensor_noise_amount: current.sensor_noise_amount,
    }
}

fn apply_geometry_mode(
    selection: &mut TestAuthoringSelection<'_>,
    mode_id: &str,
) -> Result<(), TestAuthoringError> {
    selected_option(
        &GEOMETRY_MODES,
        mode_id,
        TestAuthoringError::InvalidGeometry,
    )?;
    if selection.geometry_mode_id == mode_id {
        return Ok(());
    }
    if mode_id == "free" {
        let pitch = selection.camera_orbit_x_degrees.to_radians();
        let yaw = selection.camera_orbit_y_degrees.to_radians();
        let cos_pitch = pitch.cos();
        selection.camera_position_x_meters = selection.screen_position_x_meters
            + yaw.sin() * cos_pitch * selection.camera_distance_meters;
        selection.camera_position_y_meters =
            selection.screen_position_y_meters - pitch.sin() * selection.camera_distance_meters;
        selection.camera_position_z_meters = selection.screen_position_z_meters
            + yaw.cos() * cos_pitch * selection.camera_distance_meters;
        let euler = look_at_euler_degrees(
            [
                selection.camera_position_x_meters,
                selection.camera_position_y_meters,
                selection.camera_position_z_meters,
            ],
            [
                selection.screen_position_x_meters,
                selection.screen_position_y_meters,
                selection.screen_position_z_meters,
            ],
        );
        selection.camera_rotation_x_degrees = euler[0];
        selection.camera_rotation_y_degrees = euler[1];
        selection.camera_rotation_z_degrees = euler[2];
    } else {
        let offset = [
            selection.camera_position_x_meters - selection.screen_position_x_meters,
            selection.camera_position_y_meters - selection.screen_position_y_meters,
            selection.camera_position_z_meters - selection.screen_position_z_meters,
        ];
        let distance =
            (offset[0] * offset[0] + offset[1] * offset[1] + offset[2] * offset[2]).sqrt();
        if !distance.is_finite() || distance < 0.01 {
            return Err(TestAuthoringError::InvalidGeometry);
        }
        selection.camera_distance_meters = distance;
        selection.camera_orbit_x_degrees =
            (-offset[1] / distance).clamp(-1.0, 1.0).asin().to_degrees();
        selection.camera_orbit_y_degrees = offset[0].atan2(offset[2]).to_degrees();
    }
    selection.geometry_mode_id = if mode_id == "free" { "free" } else { "look-at" };
    Ok(())
}

fn look_at_euler_degrees(position: [f32; 3], target: [f32; 3]) -> [f32; 3] {
    let mut direction = [
        target[0] - position[0],
        target[1] - position[1],
        target[2] - position[2],
    ];
    let length =
        (direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2])
            .sqrt();
    if length <= 1.0e-6 {
        return [0.0, 0.0, 0.0];
    }
    direction.iter_mut().for_each(|value| *value /= length);
    let dot = -direction[2];
    let quaternion = if dot < -0.999_999 {
        [0.0, 1.0, 0.0, 0.0]
    } else {
        let raw = [direction[1], -direction[0], 0.0, 1.0 + dot];
        let norm = (raw[0] * raw[0] + raw[1] * raw[1] + raw[3] * raw[3]).sqrt();
        [raw[0] / norm, raw[1] / norm, 0.0, raw[3] / norm]
    };
    let [x, y, z, w] = quaternion;
    let rotation_x = (2.0 * (w * x + y * z)).atan2(1.0 - 2.0 * (x * x + y * y));
    let rotation_y = (2.0 * (w * y - z * x)).clamp(-1.0, 1.0).asin();
    let rotation_z = (2.0 * (w * z + x * y)).atan2(1.0 - 2.0 * (y * y + z * z));
    [
        rotation_x.to_degrees(),
        rotation_y.to_degrees(),
        rotation_z.to_degrees(),
    ]
}

pub fn apply_test_scalar(
    selection: TestAuthoringSelection<'_>,
    control_id: &str,
    value: f32,
) -> Result<ResolvedTestAuthoringSelection, TestAuthoringError> {
    let current = resolve_test_authoring_selection(selection)?;
    let mut next = unresolved_test_selection(current);
    match control_id {
        WHITE_LUMINANCE_CONTROL_ID => next.white_luminance_nits = value,
        SUBPIXEL_GEOMETRY_CONTROL_ID => next.subpixel_geometry_amount = value,
        PANEL_UNIFORMITY_CONTROL_ID => next.panel_uniformity_amount = value,
        PANEL_LIGHT_SPREAD_CONTROL_ID => next.panel_light_spread_amount = value,
        CAMERA_DISTANCE_CONTROL_ID => next.camera_distance_meters = value,
        CAMERA_ORBIT_X_CONTROL_ID => next.camera_orbit_x_degrees = value,
        CAMERA_ORBIT_Y_CONTROL_ID => next.camera_orbit_y_degrees = value,
        CAMERA_POSITION_X_CONTROL_ID => next.camera_position_x_meters = value,
        CAMERA_POSITION_Y_CONTROL_ID => next.camera_position_y_meters = value,
        CAMERA_POSITION_Z_CONTROL_ID => next.camera_position_z_meters = value,
        CAMERA_ROTATION_X_CONTROL_ID => next.camera_rotation_x_degrees = value,
        CAMERA_ROTATION_Y_CONTROL_ID => next.camera_rotation_y_degrees = value,
        CAMERA_ROTATION_Z_CONTROL_ID => next.camera_rotation_z_degrees = value,
        SCREEN_POSITION_X_CONTROL_ID => next.screen_position_x_meters = value,
        SCREEN_POSITION_Y_CONTROL_ID => next.screen_position_y_meters = value,
        SCREEN_POSITION_Z_CONTROL_ID => next.screen_position_z_meters = value,
        SCREEN_ROTATION_X_CONTROL_ID => next.screen_rotation_x_degrees = value,
        SCREEN_YAW_CONTROL_ID => next.screen_yaw_degrees = value,
        SCREEN_ROTATION_Z_CONTROL_ID => next.screen_rotation_z_degrees = value,
        COVER_GLASS_AMOUNT_CONTROL_ID => next.cover_glass_amount = value,
        COVER_AG_MICROTEXTURE_AMOUNT_CONTROL_ID => next.cover_ag_microtexture_amount = value,
        ENVIRONMENT_AMOUNT_CONTROL_ID => next.environment_amount = value,
        COVER_GLOW_AMOUNT_CONTROL_ID => next.cover_glow_amount = value,
        LENS_AMOUNT_CONTROL_ID => next.lens_amount = value,
        F_STOP_CONTROL_ID => next.f_stop = value,
        SHUTTER_ANGLE_CONTROL_ID => next.exposure_time_seconds = value / 360.0 / current.frame_rate,
        SHUTTER_RECIPROCAL_CONTROL_ID => next.exposure_time_seconds = 1.0 / value,
        FOCUS_DISTANCE_CONTROL_ID => next.focus_distance_meters = value,
        SHUTTER_AMOUNT_CONTROL_ID => next.shutter_motion_amount = value,
        COMPUTATIONAL_CAPTURE_AMOUNT_CONTROL_ID => next.computational_character_strength = value,
        COMPUTATIONAL_EXPOSURE_COUNT_CONTROL_ID => next.computational_exposure_count = value,
        COMPUTATIONAL_BRACKET_SPACING_CONTROL_ID => {
            next.computational_bracket_spacing_stops = value
        }
        SENSOR_BLOOM_AMOUNT_CONTROL_ID => next.sensor_bloom_amount = value,
        SENSOR_BLOOM_CROSSTALK_CONTROL_ID => next.sensor_bloom_crosstalk_fraction = value,
        SENSOR_BLOOM_OVERFLOW_CONTROL_ID => next.sensor_bloom_overflow_transfer_fraction = value,
        SENSOR_NOISE_AMOUNT_CONTROL_ID => next.sensor_noise_amount = value,
        OUTPUT_SIGNAL_CONTROL_ID
        | DEVICE_CONTROL_ID
        | COLOR_MODE_CONTROL_ID
        | PLACEMENT_CONTROL_ID
        | PREVIEW_QUALITY_CONTROL_ID
        | CAPTURE_PRESET_CONTROL_ID
        | GEOMETRY_MODE_CONTROL_ID
        | COVER_GLASS_CONTROL_ID
        | ENVIRONMENT_CONTROL_ID
        | LENS_PRESET_CONTROL_ID
        | AUTOFOCUS_CONTROL_ID => return Err(TestAuthoringError::WrongControlType),
        _ => return Err(TestAuthoringError::UnknownControl),
    }
    resolve_test_authoring_selection(next)
}

pub fn apply_test_toggle(
    selection: TestAuthoringSelection<'_>,
    control_id: &str,
    value: bool,
) -> Result<ResolvedTestAuthoringSelection, TestAuthoringError> {
    let current = resolve_test_authoring_selection(selection)?;
    let mut next = unresolved_test_selection(current);
    match control_id {
        AUTOFOCUS_CONTROL_ID => next.autofocus_enabled = value,
        _ => return Err(TestAuthoringError::WrongControlType),
    }
    resolve_test_authoring_selection(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asus() -> TestAuthoringSelection<'static> {
        TestAuthoringSelection {
            input_transform_id: "srgb-encoded-rec709",
            output_signal_id: "srgb",
            device_id: "lcd-asus-proart-pa329cv",
            color_mode_id: "srgb",
            white_luminance_nits: 350.0,
            placement_id: "fit",
            preview_quality_id: "draft",
            frame_rate: 24.0,
            subpixel_geometry_amount: 1.0,
            panel_uniformity_amount: 1.0,
            panel_light_spread_amount: 1.0,
            capture_preset_id: "iphone-16e-main-48mp",
            geometry_mode_id: "look-at",
            camera_distance_meters: 0.15,
            camera_orbit_x_degrees: 0.0,
            camera_orbit_y_degrees: -5.0,
            camera_position_x_meters: -0.013_073_361,
            camera_position_y_meters: 0.0,
            camera_position_z_meters: 0.149_429_2,
            camera_rotation_x_degrees: 0.0,
            camera_rotation_y_degrees: -5.0,
            camera_rotation_z_degrees: 0.0,
            screen_position_x_meters: 0.0,
            screen_position_y_meters: 0.0,
            screen_position_z_meters: 0.0,
            screen_rotation_x_degrees: 0.0,
            screen_yaw_degrees: 0.0,
            screen_rotation_z_degrees: 0.0,
            cover_glass_preset_id: "cover-matte-ar",
            cover_glass_amount: 1.0,
            cover_ag_microtexture_amount: 1.0,
            environment_preset_id: "environment-none",
            environment_amount: 0.0,
            cover_glow_amount: 1.0,
            lens_preset_id: "iphone-16e-main-integrated",
            lens_amount: 1.0,
            autofocus_enabled: true,
            focus_distance_meters: 0.15,
            f_stop: 1.64,
            exposure_time_seconds: 1.0 / 288.0,
            shutter_motion_amount: 1.0,
            computational_character_strength: 1.0,
            computational_exposure_count: 8.0,
            computational_bracket_spacing_stops: 1.0,
            sensor_bloom_amount: 1.0,
            sensor_bloom_crosstalk_fraction: 0.020,
            sensor_bloom_overflow_transfer_fraction: 0.30,
            sensor_noise_amount: 1.0,
        }
    }

    #[test]
    fn page_separates_feeder_from_device_interpretation() {
        let page = test_page_descriptor(asus()).unwrap();
        assert_eq!(page.schema_version, 13);
        assert_eq!(page.default_preview_phase_id, DEVELOP_DEMOSAIC_PHASE_ID);
        assert_eq!(
            page.phases.iter().map(|phase| phase.id).collect::<Vec<_>>(),
            [
                ORIGIN_PHASE_ID,
                FEEDER_SIGNAL_PHASE_ID,
                DEVICE_INTERPRETATION_PHASE_ID,
                PANEL_STRUCTURE_PHASE_ID,
                PANEL_UNIFORMITY_PHASE_ID,
                PANEL_LIGHT_SPREAD_PHASE_ID,
                RELATIVE_GEOMETRY_PHASE_ID,
                COVER_ENVIRONMENT_PHASE_ID,
                COVER_GLOW_PHASE_ID,
                LENS_PROJECTION_PHASE_ID,
                SHUTTER_EXPOSURE_PHASE_ID,
                COMPUTATIONAL_CAPTURE_PHASE_ID,
                SENSOR_BLOOM_PHASE_ID,
                SENSOR_CFA_PHASE_ID,
                SENSOR_NOISE_PHASE_ID,
                DEVELOP_DEMOSAIC_PHASE_ID,
            ]
        );
        assert!(matches!(
            &page.phases[1].controls[0],
            TestControlRequirement::Choice {
                id: OUTPUT_SIGNAL_CONTROL_ID,
                ..
            }
        ));
        for adjacent in page.phases.windows(2) {
            assert_eq!(adjacent[0].output_artifact, adjacent[1].input_artifact);
        }
        assert!(matches!(
            &page.phases[6].controls[0],
            TestControlRequirement::Choice {
                id: CAPTURE_PRESET_CONTROL_ID,
                selected_id: "iphone-16e-main-48mp",
                ..
            }
        ));
        assert!(matches!(
            &page.phases[9].controls[0],
            TestControlRequirement::Choice {
                id: LENS_PRESET_CONTROL_ID,
                options,
                selected_id: "iphone-16e-main-integrated",
                ..
            } if options.len() == 1
        ));
        assert!(page.phases[1].controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Choice {
                id: PLACEMENT_CONTROL_ID,
                ..
            }
        )));
        assert!(!page.phases[2].controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Choice {
                id: PLACEMENT_CONTROL_ID,
                ..
            }
        )));
        assert!(page.phases[2].controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Choice {
                id: COLOR_MODE_CONTROL_ID,
                ..
            }
        )));
        assert_eq!(
            page.phases[2].output_artifact,
            page.phases[3].input_artifact
        );
        assert!(matches!(
            &page.phases[3].controls[0],
            TestControlRequirement::Scalar {
                id: SUBPIXEL_GEOMETRY_CONTROL_ID,
                value: 1.0,
                minimum: 0.0,
                maximum: 4.0,
                ..
            }
        ));
        assert!(matches!(
            &page.phases[4].controls[0],
            TestControlRequirement::Scalar {
                id: PANEL_UNIFORMITY_CONTROL_ID,
                value: 1.0,
                minimum: 0.0,
                maximum: 4.0,
                ..
            }
        ));
    }

    #[test]
    fn default_output_signal_matches_display_referred_input() {
        assert_eq!(
            default_test_authoring_selection(
                "srgb-encoded-rec709",
                "lcd-asus-proart-pa329cv",
                24.0
            )
            .unwrap()
            .output_signal_id,
            "srgb"
        );
        assert_eq!(
            default_test_authoring_selection(
                "display-rec709-gamma24",
                "lcd-asus-proart-pa329cv",
                24.0
            )
            .unwrap()
            .output_signal_id,
            "rec709-gamma24"
        );
    }

    #[test]
    fn autofocus_tracks_look_at_distance_and_manual_focus_remains_authored() {
        let mut selection = asus();
        selection.camera_distance_meters = 0.5;
        let automatic = resolve_test_authoring_selection(selection).unwrap();
        assert!((automatic.focus_distance_meters - 0.5).abs() < 1.0e-6);

        selection.autofocus_enabled = false;
        selection.focus_distance_meters = 0.22;
        let manual = resolve_test_authoring_selection(selection).unwrap();
        assert!((manual.focus_distance_meters - 0.22).abs() < 1.0e-6);
    }

    #[test]
    fn lens_and_exposure_publish_real_aperture_time_and_autofocus_controls() {
        let page = test_page_descriptor(asus()).unwrap();
        let lens = &page.phases[9].controls;
        assert!(matches!(
            lens.iter().find(|control| matches!(
                control,
                TestControlRequirement::Toggle {
                    id: AUTOFOCUS_CONTROL_ID,
                    ..
                }
            )),
            Some(_)
        ));
        assert!(matches!(
            lens.iter().find(|control| matches!(
                control,
                TestControlRequirement::Scalar {
                    id: F_STOP_CONTROL_ID,
                    ..
                }
            )),
            Some(_)
        ));
        assert!(!lens.iter().any(|control| matches!(
            control,
            TestControlRequirement::Scalar {
                id: FOCUS_DISTANCE_CONTROL_ID,
                ..
            }
        )));
        assert!(page.phases[10].controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Scalar {
                id: SHUTTER_ANGLE_CONTROL_ID,
                ..
            }
        )));
    }

    #[test]
    fn shutter_angle_and_reciprocal_are_synchronized_through_one_exposure_time() {
        let from_angle = apply_test_scalar(asus(), SHUTTER_ANGLE_CONTROL_ID, 180.0).unwrap();
        assert!((from_angle.exposure_time_seconds - 1.0 / 48.0).abs() < 1.0e-6);
        let angle_page = test_page_descriptor(unresolved_test_selection(from_angle)).unwrap();
        assert!(matches!(
            angle_page.phases[10]
                .controls
                .iter()
                .find(|control| matches!(
                    control,
                    TestControlRequirement::Scalar {
                        id: SHUTTER_RECIPROCAL_CONTROL_ID,
                        value,
                        ..
                    } if (*value - 48.0).abs() < 1.0e-4
                )),
            Some(_)
        ));

        let from_reciprocal =
            apply_test_scalar(asus(), SHUTTER_RECIPROCAL_CONTROL_ID, 96.0).unwrap();
        assert!((from_reciprocal.exposure_time_seconds - 1.0 / 96.0).abs() < 1.0e-6);
        assert!((from_reciprocal.exposure_time_seconds * 24.0 * 360.0 - 90.0).abs() < 1.0e-4);
    }

    #[test]
    fn sensor_bloom_publishes_and_restores_the_selected_camera_profile() {
        let page = test_page_descriptor(asus()).unwrap();
        let ids = page.phases[12]
            .controls
            .iter()
            .map(|control| match control {
                TestControlRequirement::Choice { id, .. }
                | TestControlRequirement::Scalar { id, .. }
                | TestControlRequirement::Toggle { id, .. } => *id,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            ids,
            [
                SENSOR_BLOOM_AMOUNT_CONTROL_ID,
                SENSOR_BLOOM_CROSSTALK_CONTROL_ID,
                SENSOR_BLOOM_OVERFLOW_CONTROL_ID,
            ]
        );
        let edited = apply_test_scalar(asus(), SENSOR_BLOOM_CROSSTALK_CONTROL_ID, 0.01).unwrap();
        assert!((edited.sensor_bloom_crosstalk_fraction - 0.01).abs() < f32::EPSILON);
        let changed_camera = apply_test_choice(
            unresolved_test_selection(edited),
            CAPTURE_PRESET_CONTROL_ID,
            "arri-alexa-35-open-gate",
        )
        .unwrap();
        assert_eq!(
            changed_camera.sensor_bloom_crosstalk_fraction,
            capture("arri-alexa-35-open-gate")
                .unwrap()
                .sensor
                .bloom
                .crosstalk_fraction
        );
        assert_eq!(
            changed_camera.sensor_bloom_overflow_transfer_fraction,
            capture("arri-alexa-35-open-gate")
                .unwrap()
                .sensor
                .bloom
                .overflow_transfer_fraction
        );
    }

    #[test]
    fn fit_and_fill_crop_remain_distinct_authored_placement_intents() {
        let fill = apply_test_choice(asus(), PLACEMENT_CONTROL_ID, "fill-crop").unwrap();
        assert_eq!(fill.placement_id, "fill-crop");
        let fit = apply_test_choice(asus(), PLACEMENT_CONTROL_ID, "fit").unwrap();
        assert_eq!(fit.placement_id, "fit");
    }

    #[test]
    fn color_mode_does_not_mutate_the_feeder_signal() {
        let selection = apply_test_choice(asus(), COLOR_MODE_CONTROL_ID, "rec709-gamma24").unwrap();
        assert_eq!(selection.output_signal_id, "srgb");
        assert_eq!(selection.color_mode_id, "rec709-gamma24");
        assert_eq!(selection.device_eotf_gamma, 2.4);
    }

    #[test]
    fn device_choice_preserves_feeder_and_resolves_device_defaults() {
        let selection = apply_test_choice(asus(), DEVICE_CONTROL_ID, "lcd-tv-hd-32").unwrap();
        assert_eq!(selection.output_signal_id, "srgb");
        assert_eq!(selection.device_id, "lcd-tv-hd-32");
        assert_eq!(selection.color_mode_id, "rec709-gamma24");
        assert_eq!(selection.white_luminance_nits, 250.0);
        let device = preset(selection.device_id).unwrap();
        let cover = cover_glass_preset(device.default_cover_glass_preset_id).unwrap();
        assert_eq!(
            selection.cover_ag_microtexture_amount,
            cover.profile.anti_glare_microtexture.character_strength
        );
    }

    #[test]
    fn cover_microtexture_is_model_authored_and_resets_with_the_cover_preset() {
        let page = test_page_descriptor(asus()).unwrap();
        assert!(matches!(
            page.phases[7].controls.iter().find(|control| matches!(
                control,
                TestControlRequirement::Scalar {
                    id: COVER_AG_MICROTEXTURE_AMOUNT_CONTROL_ID,
                    ..
                }
            )),
            Some(TestControlRequirement::Scalar {
                value: 1.0,
                minimum: 0.0,
                maximum: 4.0,
                slider_visible: true,
                reset_value: 1.0,
                ..
            })
        ));
        let edited =
            apply_test_scalar(asus(), COVER_AG_MICROTEXTURE_AMOUNT_CONTROL_ID, 2.5).unwrap();
        assert_eq!(edited.cover_ag_microtexture_amount, 2.5);
        let changed = apply_test_choice(
            unresolved_test_selection(edited),
            COVER_GLASS_CONTROL_ID,
            "cover-glossy-strong-ar",
        )
        .unwrap();
        assert_eq!(
            changed.cover_ag_microtexture_amount,
            cover_glass_preset("cover-glossy-strong-ar")
                .unwrap()
                .profile
                .anti_glare_microtexture
                .character_strength
        );
        assert_eq!(
            apply_test_scalar(asus(), COVER_AG_MICROTEXTURE_AMOUNT_CONTROL_ID, 4.1),
            Err(TestAuthoringError::InvalidCoverAgMicrotextureAmount)
        );
    }

    #[test]
    fn invalid_intents_fail_at_the_application_boundary() {
        assert_eq!(
            apply_test_choice(asus(), COLOR_MODE_CONTROL_ID, "rec709-gamma22"),
            Err(TestAuthoringError::UnsupportedColorMode)
        );
        assert_eq!(
            apply_test_choice(asus(), PLACEMENT_CONTROL_ID, "center-ish"),
            Err(TestAuthoringError::UnknownPlacement)
        );
        assert_eq!(
            apply_test_scalar(asus(), SUBPIXEL_GEOMETRY_CONTROL_ID, 4.1),
            Err(TestAuthoringError::InvalidSubpixelGeometryAmount)
        );
    }

    #[test]
    fn geometry_mode_publishes_only_its_owned_controls() {
        let look_at = test_page_descriptor(asus()).unwrap();
        let controls = &look_at.phases[6].controls;
        assert!(controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Scalar {
                id: CAMERA_ORBIT_X_CONTROL_ID,
                ..
            }
        )));
        assert!(controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Scalar {
                id: CAMERA_ORBIT_Y_CONTROL_ID,
                ..
            }
        )));
        assert!(!controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Scalar {
                id: CAMERA_POSITION_X_CONTROL_ID,
                ..
            }
        )));

        let free = apply_test_choice(asus(), GEOMETRY_MODE_CONTROL_ID, "free").unwrap();
        let free = test_page_descriptor(unresolved_test_selection(free)).unwrap();
        let controls = &free.phases[6].controls;
        for id in [
            CAMERA_POSITION_X_CONTROL_ID,
            CAMERA_POSITION_Y_CONTROL_ID,
            CAMERA_POSITION_Z_CONTROL_ID,
            CAMERA_ROTATION_X_CONTROL_ID,
            CAMERA_ROTATION_Y_CONTROL_ID,
            CAMERA_ROTATION_Z_CONTROL_ID,
            SCREEN_ROTATION_X_CONTROL_ID,
            SCREEN_YAW_CONTROL_ID,
            SCREEN_ROTATION_Z_CONTROL_ID,
        ] {
            assert!(controls.iter().any(|control| matches!(
                control,
                TestControlRequirement::Scalar { id: actual, .. } if *actual == id
            )));
        }
    }

    #[test]
    fn scalar_contracts_publish_five_percent_slider_steps_and_explicit_resets() {
        let page = test_page_descriptor(asus()).unwrap();
        for scalar in page.phases.iter().flat_map(|phase| &phase.controls) {
            if let TestControlRequirement::Scalar {
                minimum,
                maximum,
                step,
                reset_value,
                ..
            } = scalar
            {
                assert!((*step - (*maximum - *minimum) * 0.05).abs() < 1.0e-6);
                assert!((*minimum..=*maximum).contains(reset_value));
            }
        }
        let resolved = apply_test_scalar(asus(), CAMERA_DISTANCE_CONTROL_ID, 0.123).unwrap();
        assert_eq!(resolved.camera_distance_meters, 0.123);
    }
}
