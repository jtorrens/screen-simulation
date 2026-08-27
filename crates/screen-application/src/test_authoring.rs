//! Host-neutral authoring descriptors for the ordered Test surface.

use crate::{
    CAPTURE_DEVICE_PRESETS, CaptureDevicePreset, PhysicalIntermediate, RecordingSelection,
    capture_device_preset, prepare_recording_request,
};
use screen_camera::CameraRenderingIntent;
use screen_color::{
    DeviceColorTarget, OcioInputTransform, RecordingOutputTransform, SceneLinearAdjustment,
};
use screen_contracts::{FrameRate, LinearRgb};
use screen_cover::{
    COVER_GLASS_PRESETS, ENVIRONMENT_PRESETS, ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
    ENVIRONMENT_TANGENT_SCALE_MIN, cover_glass_preset, environment_preset,
};
use screen_geometry::{LensPreset, lens_preset};
use screen_panel::{DEVICE_PRESETS, DevicePreset, PanelColorMode};
use screen_recording::{
    EncoderExecutionPolicy, GENERIC_H264_HIGH_VIDEO_PROFILE_ID, GENERIC_HEVC_MAIN_VIDEO_PROFILE_ID,
    GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID, GENERIC_JPEG_PHOTO_PROFILE_ID,
    GENERIC_PRORES_422_HQ_PROFILE_ID, GENERIC_PRORES_4444_PROFILE_ID, IPHONE_HEIC_PHOTO_PROFILE_ID,
    RecordingMedium, bundled_profiles,
};

pub const TEST_AUTHORING_SCHEMA_VERSION: u32 = 35;

pub const ORIGIN_PHASE_ID: &str = "origin";
pub const SOURCE_ADJUSTMENT_PHASE_ID: &str = "source-adjustment";
pub const FEEDER_SIGNAL_PHASE_ID: &str = "feeder-signal";
pub const DEVICE_INTERPRETATION_PHASE_ID: &str = "device-interpretation";
pub const PANEL_STRUCTURE_PHASE_ID: &str = "panel-structure";
pub const PANEL_UNIFORMITY_PHASE_ID: &str = "panel-uniformity";
pub const PANEL_LIGHT_SPREAD_PHASE_ID: &str = "panel-light-spread";
pub const PANEL_TEMPORAL_PHASE_ID: &str = "panel-temporal";
pub const RELATIVE_GEOMETRY_PHASE_ID: &str = "relative-geometry";
pub const COVER_ENVIRONMENT_PHASE_ID: &str = "cover-environment";
pub const COVER_GLOW_PHASE_ID: &str = "cover-glow";
pub const LENS_PROJECTION_PHASE_ID: &str = "lens-projection";
pub const SHUTTER_EXPOSURE_PHASE_ID: &str = "shutter-exposure";
pub const COMPUTATIONAL_CAPTURE_PHASE_ID: &str = "computational-capture";
pub const SENSOR_COLLECTION_PHASE_ID: &str = "sensor-collection";
pub const SENSOR_BLOOM_PHASE_ID: &str = "sensor-bloom";
pub const SENSOR_READOUT_RAW_PHASE_ID: &str = "sensor-readout-raw";
pub const DEVELOP_DEMOSAIC_PHASE_ID: &str = "develop-demosaic";
pub const CAMERA_RENDERING_INTENT_PHASE_ID: &str = "camera-rendering-intent";
pub const DEVICE_VFX_TRANSPARENCY_PHASE_ID: &str = "device-vfx-transparency";
pub const DELIVERY_RASTER_PHASE_ID: &str = "delivery-raster";
pub const RECORDING_OUTPUT_PHASE_ID: &str = "recording-output";
pub const RECORDING_CODEC_PHASE_ID: &str = "recording-codec";
pub const OUTPUT_SIGNAL_CONTROL_ID: &str = "output-signal";
pub const SOURCE_EXPOSURE_CONTROL_ID: &str = "source-exposure-ev";
pub const SOURCE_CONTRAST_CONTROL_ID: &str = "source-contrast";
pub const SOURCE_SATURATION_CONTROL_ID: &str = "source-saturation";
pub const SOURCE_TEMPERATURE_CONTROL_ID: &str = "source-temperature-kelvin";
pub const SOURCE_TINT_CONTROL_ID: &str = "source-tint";
pub const DEVICE_CONTROL_ID: &str = "device";
pub const COLOR_MODE_CONTROL_ID: &str = "color-mode";
pub const WHITE_LUMINANCE_CONTROL_ID: &str = "white-luminance";
pub const PLACEMENT_CONTROL_ID: &str = "placement";
pub const PREVIEW_QUALITY_CONTROL_ID: &str = "preview-quality";
pub const SUBPIXEL_GEOMETRY_CONTROL_ID: &str = "subpixel-geometry-amount";
pub const MOIRE_INTENSITY_CONTROL_ID: &str = "moire-intensity";
pub const MOIRE_SATURATION_CONTROL_ID: &str = "moire-saturation";
pub const MOIRE_FILTER_CONTROL_ID: &str = "moire-antialias-filter";
pub const PANEL_UNIFORMITY_CONTROL_ID: &str = "panel-uniformity-amount";
pub const PANEL_LIGHT_SPREAD_CONTROL_ID: &str = "panel-light-spread-amount";
pub const CAPTURE_PRESET_CONTROL_ID: &str = "capture-preset";
pub const CAPTURE_RASTER_MODE_CONTROL_ID: &str = "capture-raster-mode";
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
pub const COVER_THICKNESS_CONTROL_ID: &str = "cover-thickness-millimeters";
pub const COVER_REFRACTIVE_INDEX_CONTROL_ID: &str = "cover-refractive-index";
pub const COVER_AR_EFFICIENCY_CONTROL_ID: &str = "cover-ar-efficiency";
pub const COVER_ABSORPTION_R_CONTROL_ID: &str = "cover-absorption-r";
pub const COVER_ABSORPTION_G_CONTROL_ID: &str = "cover-absorption-g";
pub const COVER_ABSORPTION_B_CONTROL_ID: &str = "cover-absorption-b";
pub const COVER_ROUGHNESS_CONTROL_ID: &str = "cover-roughness";
pub const COVER_HAZE_CONTROL_ID: &str = "cover-haze";
pub const COVER_AG_RMS_SLOPE_CONTROL_ID: &str = "cover-ag-rms-slope";
pub const COVER_AG_CORRELATION_CONTROL_ID: &str = "cover-ag-correlation-micrometers";
pub const COVER_AG_ANISOTROPY_CONTROL_ID: &str = "cover-ag-anisotropy";
pub const ENVIRONMENT_CONTROL_ID: &str = "environment-source";
pub const ENVIRONMENT_BROWSE_CONTROL_ID: &str = "environment-browse";
pub const ENVIRONMENT_AMOUNT_CONTROL_ID: &str = "environment-amount";
pub const ENVIRONMENT_ROTATION_X_CONTROL_ID: &str = "environment-rotation-x-degrees";
pub const ENVIRONMENT_ROTATION_Y_CONTROL_ID: &str = "environment-rotation-y-degrees";
pub const ENVIRONMENT_ANCHOR_LONGITUDE_CONTROL_ID: &str = "environment-anchor-longitude-degrees";
pub const ENVIRONMENT_ANCHOR_LATITUDE_CONTROL_ID: &str = "environment-anchor-latitude-degrees";
pub const ENVIRONMENT_MOBIUS_A_REAL_CONTROL_ID: &str = "environment-mobius-a-real";
pub const ENVIRONMENT_MOBIUS_A_IMAG_CONTROL_ID: &str = "environment-mobius-a-imag";
pub const ENVIRONMENT_MOBIUS_C_REAL_CONTROL_ID: &str = "environment-mobius-c-real";
pub const ENVIRONMENT_MOBIUS_C_IMAG_CONTROL_ID: &str = "environment-mobius-c-imag";
pub const ENVIRONMENT_EXPOSURE_CONTROL_ID: &str = "environment-exposure-ev";
pub const ENVIRONMENT_CONTRAST_CONTROL_ID: &str = "environment-contrast";
pub const ENVIRONMENT_SATURATION_CONTROL_ID: &str = "environment-saturation";
pub const ENVIRONMENT_TEMPERATURE_CONTROL_ID: &str = "environment-temperature-kelvin";
pub const ENVIRONMENT_TINT_CONTROL_ID: &str = "environment-tint";
pub const ENVIRONMENT_PROJECTION_CONTROL_ID: &str = "environment-projection";
pub const ENVIRONMENT_CENTER_X_CONTROL_ID: &str = "environment-sphere-center-x-meters";
pub const ENVIRONMENT_CENTER_Y_CONTROL_ID: &str = "environment-sphere-center-y-meters";
pub const ENVIRONMENT_CENTER_Z_CONTROL_ID: &str = "environment-sphere-center-z-meters";
pub const ENVIRONMENT_RADIUS_CONTROL_ID: &str = "environment-sphere-radius-meters";
pub const IMAGE_ENVIRONMENT_SOURCE_ID: &str = "environment-image";
pub const COVER_GLOW_AMOUNT_CONTROL_ID: &str = "cover-glow-amount";
pub const COVER_GLOW_INTENSITY_CONTROL_ID: &str = "cover-glow-intensity";
pub const COVER_GLOW_RADIUS_CONTROL_ID: &str = "cover-glow-radius-millimeters";
pub const COVER_GLOW_THRESHOLD_CONTROL_ID: &str = "cover-glow-threshold-relative-white";
pub const COVER_GLOW_EXTERIOR_INTENSITY_CONTROL_ID: &str = "cover-glow-exterior-intensity";
pub const LENS_PRESET_CONTROL_ID: &str = "lens-preset";
pub const FOCAL_LENGTH_CONTROL_ID: &str = "focal-length-millimeters";
pub const LENS_EVALUATION_MODEL_CONTROL_ID: &str = "lens-evaluation-model";
pub const LENS_AMOUNT_CONTROL_ID: &str = "lens-amount";
pub const AUTOFOCUS_CONTROL_ID: &str = "autofocus";
pub const AUTOFOCUS_TARGET_U_CONTROL_ID: &str = "autofocus-target-u";
pub const AUTOFOCUS_TARGET_V_CONTROL_ID: &str = "autofocus-target-v";
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
pub const CAMERA_LOOK_EXPOSURE_CONTROL_ID: &str = "camera-look-exposure-ev";
pub const CAMERA_LOOK_CONTRAST_CONTROL_ID: &str = "camera-look-contrast";
pub const CAMERA_LOOK_SATURATION_CONTROL_ID: &str = "camera-look-saturation";
pub const CAMERA_LOOK_TEMPERATURE_CONTROL_ID: &str = "camera-look-temperature-kelvin";
pub const CAMERA_LOOK_TINT_CONTROL_ID: &str = "camera-look-tint";
pub const DEVICE_VFX_ALPHA_MODE_CONTROL_ID: &str = "device-vfx-alpha-mode";
pub const DELIVERY_PRESET_CONTROL_ID: &str = "delivery-preset";
pub const DELIVERY_WIDTH_CONTROL_ID: &str = "delivery-width-pixels";
pub const DELIVERY_HEIGHT_CONTROL_ID: &str = "delivery-height-pixels";
pub const DELIVERY_PLACEMENT_CONTROL_ID: &str = "delivery-placement";
pub const DELIVERY_BACKGROUND_CONTROL_ID: &str = "delivery-background";
pub const RECORDING_OUTPUT_TRANSFORM_CONTROL_ID: &str = "recording-output-transform";
pub const RECORDING_PROFILE_CONTROL_ID: &str = "recording-profile";
pub const RECORDING_CHARACTER_CONTROL_ID: &str = "recording-character";

pub const DEVICE_VFX_ALPHA_MODES: [TestChoiceOption; 2] = [
    TestChoiceOption {
        id: "ignore",
        label: "Ignorar alpha",
    },
    TestChoiceOption {
        id: "device-transparency",
        label: "Transparencia del Device",
    },
];

fn focal_length_bounds() -> (f32, f32) {
    (
        // A selected lens preset supplies optical character, not a hard
        // capture-camera focal restriction. Imported tracking focal length is
        // authoritative while the preset continues to supply all other lens
        // characteristics.
        0.1, 500.0,
    )
}

fn recording_profile_options(capture: &TestCaptureAuthoringProfile<'_>) -> Vec<TestChoiceOption> {
    bundled_profiles()
        .into_iter()
        .map(|profile| {
            let common = capture
                .recommended_recording_profile_ids
                .contains(&profile.id);
            let label = match (profile.id, common) {
                (IPHONE_HEIC_PHOTO_PROFILE_ID, true) => "Habitual · HEIC · foto",
                (GENERIC_JPEG_PHOTO_PROFILE_ID, true) => "Habitual · JPEG · foto",
                (GENERIC_HEVC_MAIN_VIDEO_PROFILE_ID, true) => "Habitual · HEVC Main · vídeo",
                (GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID, true) => "Habitual · HEVC Main 10 · vídeo",
                (GENERIC_H264_HIGH_VIDEO_PROFILE_ID, true) => "Habitual · H.264 High · vídeo",
                (GENERIC_PRORES_422_HQ_PROFILE_ID, true) => "Habitual · ProRes 422 HQ · vídeo",
                (GENERIC_PRORES_4444_PROFILE_ID, true) => "Habitual · ProRes 4444 · vídeo",
                (IPHONE_HEIC_PHOTO_PROFILE_ID, false) => "Disponible · HEIC · foto",
                (GENERIC_JPEG_PHOTO_PROFILE_ID, false) => "Disponible · JPEG · foto",
                (GENERIC_HEVC_MAIN_VIDEO_PROFILE_ID, false) => "Disponible · HEVC Main · vídeo",
                (GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID, false) => {
                    "Disponible · HEVC Main 10 · vídeo"
                }
                (GENERIC_H264_HIGH_VIDEO_PROFILE_ID, false) => "Disponible · H.264 High · vídeo",
                (GENERIC_PRORES_422_HQ_PROFILE_ID, false) => "Disponible · ProRes 422 HQ · vídeo",
                (GENERIC_PRORES_4444_PROFILE_ID, false) => "Disponible · ProRes 4444 · vídeo",
                _ => "Disponible · formato de grabación",
            };
            TestChoiceOption {
                id: profile.id,
                label,
            }
        })
        .collect()
}

pub fn recording_output_transform_for_profile(
    profile_id: &str,
) -> Result<RecordingOutputTransform, TestAuthoringError> {
    match profile_id {
        IPHONE_HEIC_PHOTO_PROFILE_ID => Ok(RecordingOutputTransform::IphoneHeicDisplayP3SrgbFull),
        GENERIC_JPEG_PHOTO_PROFILE_ID => Ok(RecordingOutputTransform::GenericSrgbFull),
        GENERIC_H264_HIGH_VIDEO_PROFILE_ID => Ok(RecordingOutputTransform::GenericRec709Full),
        GENERIC_HEVC_MAIN10_VIDEO_PROFILE_ID
        | GENERIC_PRORES_422_HQ_PROFILE_ID
        | GENERIC_PRORES_4444_PROFILE_ID => Ok(RecordingOutputTransform::GenericRec2100PqFull),
        _ => Err(TestAuthoringError::InvalidRecording),
    }
}

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

const DELIVERY_PLACEMENTS: [TestChoiceOption; 3] = [
    TestChoiceOption {
        id: "fit",
        label: "Fit",
    },
    TestChoiceOption {
        id: "fill-crop",
        label: "Fill / Crop",
    },
    TestChoiceOption {
        id: "one-to-one",
        label: "1:1",
    },
];

const DELIVERY_PRESETS: [TestChoiceOption; 8] = [
    TestChoiceOption {
        id: "uhd",
        label: "UHD · 3840 × 2160",
    },
    TestChoiceOption {
        id: "dci-4k",
        label: "DCI 4K · 4096 × 2160",
    },
    TestChoiceOption {
        id: "hd",
        label: "HD · 1920 × 1080",
    },
    TestChoiceOption {
        id: "dci-2k",
        label: "DCI 2K · 2048 × 1080",
    },
    TestChoiceOption {
        id: "vertical-uhd",
        label: "Vertical · 2160 × 3840",
    },
    TestChoiceOption {
        id: "square-2160",
        label: "Cuadrado · 2160 × 2160",
    },
    TestChoiceOption {
        id: "camera-native",
        label: "Raster de cámara",
    },
    TestChoiceOption {
        id: "custom",
        label: "Personalizado",
    },
];

fn materialize_delivery_preset<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    selection: &mut TestAuthoringSelection<'_>,
    preset_id: &str,
) -> Result<(), TestAuthoringError> {
    let preset_id = selected_option(
        &DELIVERY_PRESETS,
        preset_id,
        TestAuthoringError::InvalidDeliveryRaster,
    )?;
    let (width, height, placement) = match preset_id {
        "uhd" => (3_840.0, 2_160.0, "fit"),
        "dci-4k" => (4_096.0, 2_160.0, "fit"),
        "hd" => (1_920.0, 1_080.0, "fit"),
        "dci-2k" => (2_048.0, 1_080.0, "fit"),
        "vertical-uhd" => (2_160.0, 3_840.0, "fit"),
        "square-2160" => (2_160.0, 2_160.0, "fit"),
        "camera-native" => {
            let capture = capture(profiles, selection.capture_preset_id)?;
            let raster = capture
                .raster_modes
                .iter()
                .find(|mode| mode.id == selection.capture_raster_mode_id)
                .ok_or(TestAuthoringError::InvalidCaptureRasterMode)?;
            (raster.width as f32, raster.height as f32, "one-to-one")
        }
        "custom" => {
            selection.delivery_preset_id = "custom";
            return Ok(());
        }
        _ => return Err(TestAuthoringError::InvalidDeliveryRaster),
    };
    selection.delivery_preset_id = preset_id;
    selection.delivery_width = width;
    selection.delivery_height = height;
    selection.delivery_placement_id = placement;
    selection.delivery_background_id = "black";
    Ok(())
}
const DELIVERY_BACKGROUNDS: [TestChoiceOption; 2] = [
    TestChoiceOption {
        id: "transparent",
        label: "Transparente",
    },
    TestChoiceOption {
        id: "black",
        label: "Negro",
    },
];

const SETUP_PREVIEW_QUALITIES: [TestChoiceOption; 3] = [
    TestChoiceOption {
        id: "setup",
        label: "Setup Device",
    },
    TestChoiceOption {
        id: "environment-setup",
        label: "Setup entorno",
    },
    TestChoiceOption {
        id: "focus-setup",
        label: "Setup foco",
    },
];

// Reference and adapter tests may still request the evaluator qualities
// directly. They are intentionally not offered by the interactive picker;
// Native is launched by its permanent render action.
const PREVIEW_QUALITIES: [TestChoiceOption; 7] = [
    SETUP_PREVIEW_QUALITIES[0],
    SETUP_PREVIEW_QUALITIES[1],
    SETUP_PREVIEW_QUALITIES[2],
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
    pub frame_rate: FrameRate,
    pub source_adjustment: SceneLinearAdjustment,
    pub subpixel_geometry_amount: f32,
    pub moire_intensity: f32,
    pub moire_saturation: f32,
    pub moire_filter_strength: f32,
    pub panel_uniformity_amount: f32,
    pub panel_light_spread_amount: f32,
    pub capture_preset_id: &'a str,
    pub capture_raster_mode_id: &'a str,
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
    pub cover_thickness_millimeters: f32,
    pub cover_refractive_index: f32,
    pub cover_ar_efficiency: f32,
    pub cover_absorption_rgb: [f32; 3],
    pub cover_roughness: f32,
    pub cover_haze: f32,
    pub cover_ag_rms_slope: f32,
    pub cover_ag_correlation_micrometers: f32,
    pub cover_ag_anisotropy: f32,
    pub environment_source_id: &'a str,
    pub environment_amount: f32,
    pub environment_rotation_x_degrees: f32,
    pub environment_rotation_y_degrees: f32,
    pub environment_anchor_longitude_degrees: f32,
    pub environment_anchor_latitude_degrees: f32,
    pub environment_tangent_transform: [f32; 4],
    pub environment_exposure_ev: f32,
    pub environment_contrast: f32,
    pub environment_saturation: f32,
    pub environment_temperature_kelvin: f32,
    pub environment_tint: f32,
    pub environment_projection_id: &'a str,
    pub environment_sphere_center_x_meters: f32,
    pub environment_sphere_center_y_meters: f32,
    pub environment_sphere_center_z_meters: f32,
    pub environment_sphere_radius_meters: f32,
    pub cover_glow_amount: f32,
    pub cover_glow_intensity: f32,
    pub cover_glow_radius_millimeters: f32,
    pub cover_glow_threshold_relative_white: f32,
    /// Gain applied only to the additive spill where the Device matte falls
    /// away. One preserves the calibrated interior/exterior balance.
    pub cover_glow_exterior_intensity: f32,
    pub lens_preset_id: &'a str,
    pub focal_length_millimeters: f32,
    pub lens_evaluation_model_id: &'a str,
    pub lens_amount: f32,
    pub autofocus_enabled: bool,
    pub autofocus_target_u: f32,
    pub autofocus_target_v: f32,
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
    pub camera_rendering_intent: CameraRenderingIntent,
    pub device_vfx_alpha_mode_id: &'a str,
    pub delivery_preset_id: &'a str,
    pub delivery_width: f32,
    pub delivery_height: f32,
    pub delivery_placement_id: &'a str,
    pub delivery_background_id: &'a str,
    pub recording_output_transform_id: &'a str,
    pub recording_profile_id: &'a str,
    pub recording_character: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedTestAuthoringSelection<'a> {
    pub input_transform_id: &'a str,
    pub output_signal_id: &'a str,
    pub device_id: &'a str,
    pub color_mode_id: &'a str,
    pub device_eotf_gamma: f32,
    pub white_luminance_nits: f32,
    pub placement_id: &'a str,
    pub preview_quality_id: &'a str,
    pub frame_rate: FrameRate,
    pub source_adjustment: SceneLinearAdjustment,
    pub subpixel_geometry_amount: f32,
    pub moire_intensity: f32,
    pub moire_saturation: f32,
    pub moire_filter_strength: f32,
    pub panel_uniformity_amount: f32,
    pub panel_light_spread_amount: f32,
    pub capture_preset_id: &'a str,
    pub capture_raster_mode_id: &'a str,
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
    pub cover_thickness_millimeters: f32,
    pub cover_refractive_index: f32,
    pub cover_ar_efficiency: f32,
    pub cover_absorption_rgb: [f32; 3],
    pub cover_roughness: f32,
    pub cover_haze: f32,
    pub cover_ag_rms_slope: f32,
    pub cover_ag_correlation_micrometers: f32,
    pub cover_ag_anisotropy: f32,
    pub environment_source_id: &'a str,
    pub environment_amount: f32,
    pub environment_rotation_x_degrees: f32,
    pub environment_rotation_y_degrees: f32,
    pub environment_anchor_longitude_degrees: f32,
    pub environment_anchor_latitude_degrees: f32,
    pub environment_tangent_transform: [f32; 4],
    pub environment_exposure_ev: f32,
    pub environment_contrast: f32,
    pub environment_saturation: f32,
    pub environment_temperature_kelvin: f32,
    pub environment_tint: f32,
    pub environment_projection_id: &'a str,
    pub environment_sphere_center_x_meters: f32,
    pub environment_sphere_center_y_meters: f32,
    pub environment_sphere_center_z_meters: f32,
    pub environment_sphere_radius_meters: f32,
    pub cover_glow_amount: f32,
    pub cover_glow_intensity: f32,
    pub cover_glow_radius_millimeters: f32,
    pub cover_glow_threshold_relative_white: f32,
    pub cover_glow_exterior_intensity: f32,
    pub lens_preset_id: &'a str,
    pub focal_length_millimeters: f32,
    pub lens_evaluation_model_id: &'a str,
    pub lens_amount: f32,
    pub autofocus_enabled: bool,
    pub autofocus_target_u: f32,
    pub autofocus_target_v: f32,
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
    pub camera_rendering_intent: CameraRenderingIntent,
    pub device_vfx_alpha_mode_id: &'a str,
    pub delivery_preset_id: &'a str,
    pub delivery_width: u32,
    pub delivery_height: u32,
    pub delivery_placement_id: &'a str,
    pub delivery_background_id: &'a str,
    pub recording_output_transform_id: &'a str,
    pub recording_profile_id: &'a str,
    pub recording_character: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TestChoiceOption {
    pub id: &'static str,
    pub label: &'static str,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TestOwnedChoiceOption {
    pub id: String,
    pub label: String,
}

fn lens_evaluation_model_id(model: crate::LensEvaluationModel) -> &'static str {
    match model {
        crate::LensEvaluationModel::ThinLens => "thin-lens",
        crate::LensEvaluationModel::VfxDepthBlur => "vfx-2d-dof",
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum TestControlRequirement {
    Choice {
        id: &'static str,
        label: &'static str,
        options: Vec<TestOwnedChoiceOption>,
        selected_id: String,
        reset_id: String,
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
    Action {
        id: &'static str,
        label: &'static str,
    },
}

impl TestControlRequirement {
    pub const fn stable_id(&self) -> &'static str {
        match self {
            Self::Choice { id, .. }
            | Self::Scalar { id, .. }
            | Self::Toggle { id, .. }
            | Self::Action { id, .. } => id,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TestInspectorLocation {
    pub group_id: &'static str,
    pub group_label: &'static str,
    pub group_order: u32,
    pub section_id: &'static str,
    pub section_label: &'static str,
    pub section_order: u32,
}

const fn inspector_location(
    group_id: &'static str,
    group_label: &'static str,
    group_order: u32,
    section_id: &'static str,
    section_label: &'static str,
    section_order: u32,
) -> TestInspectorLocation {
    TestInspectorLocation {
        group_id,
        group_label,
        group_order,
        section_id,
        section_label,
        section_order,
    }
}

/// Application-owned inspector placement. The host must never infer this from
/// phase labels, control names, list position, or model identity.
pub fn test_inspector_location(phase_id: &str, control_id: &str) -> Option<TestInspectorLocation> {
    const DEVICE_SOURCE: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.source-adjustment",
        "Origen y ajuste de la fuente",
        0,
    );
    const DEVICE_TRANSPARENCY: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.vfx-transparency",
        "Transparencia VFX",
        1,
    );
    const DEVICE_FEEDER: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.feeder",
        "Salida del feeder",
        2,
    );
    const DEVICE_EMISSION: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.emission",
        "Emisión del panel",
        3,
    );
    const DEVICE_STRUCTURE: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.panel-structure",
        "Estructura del panel",
        4,
    );
    const DEVICE_UNIFORMITY: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.panel-uniformity",
        "Uniformidad del panel",
        5,
    );
    const DEVICE_SPREAD: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.panel-spread",
        "Difusión del panel",
        6,
    );
    const DEVICE_GEOMETRY: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.geometry",
        "Geometría del Device",
        7,
    );
    const DEVICE_GLASS: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.glass",
        "Cristal",
        8,
    );
    const DEVICE_GLOW: TestInspectorLocation = inspector_location(
        "device",
        "Device en escena",
        0,
        "device.glow",
        "Replandor del Device",
        9,
    );
    const ENVIRONMENT: TestInspectorLocation = inspector_location(
        "environment",
        "Entorno",
        1,
        "environment.main",
        "Entorno",
        0,
    );
    const CAMERA_GEOMETRY: TestInspectorLocation = inspector_location(
        "camera",
        "Cámara",
        2,
        "camera.geometry",
        "Geometría de cámara",
        0,
    );
    const CAMERA_LENS: TestInspectorLocation = inspector_location(
        "camera",
        "Cámara",
        2,
        "camera.lens",
        "Objetivo y proyección",
        1,
    );
    const CAMERA_SENSOR: TestInspectorLocation = inspector_location(
        "camera",
        "Cámara",
        2,
        "camera.exposure",
        "Exposición y obturador",
        2,
    );
    const CAMERA_COLLECTION: TestInspectorLocation = inspector_location(
        "camera",
        "Cámara",
        2,
        "camera.sensor-collection",
        "Fotositos, CFA y ruido",
        3,
    );
    const CAMERA_BLOOM: TestInspectorLocation = inspector_location(
        "camera",
        "Cámara",
        2,
        "camera.sensor-bloom",
        "Crosstalk y bloom",
        4,
    );
    const CAMERA_COMPUTATIONAL: TestInspectorLocation = inspector_location(
        "camera",
        "Cámara",
        2,
        "camera.computational",
        "Captura computacional",
        5,
    );
    const CAMERA_INTENT: TestInspectorLocation = inspector_location(
        "camera",
        "Cámara",
        2,
        "camera.intent",
        "Intención de render",
        6,
    );
    const CAMERA_CODEC: TestInspectorLocation =
        inspector_location("camera", "Cámara", 2, "camera.codec", "Códec", 7);
    const DELIVERY: TestInspectorLocation = inspector_location(
        "delivery",
        "Raster de entrega",
        3,
        "delivery.main",
        "Raster de entrega",
        0,
    );

    match phase_id {
        SOURCE_ADJUSTMENT_PHASE_ID => Some(DEVICE_SOURCE),
        DEVICE_VFX_TRANSPARENCY_PHASE_ID => Some(DEVICE_TRANSPARENCY),
        FEEDER_SIGNAL_PHASE_ID => Some(DEVICE_FEEDER),
        DEVICE_INTERPRETATION_PHASE_ID => Some(DEVICE_EMISSION),
        PANEL_STRUCTURE_PHASE_ID => Some(DEVICE_STRUCTURE),
        PANEL_UNIFORMITY_PHASE_ID => Some(DEVICE_UNIFORMITY),
        PANEL_LIGHT_SPREAD_PHASE_ID => Some(DEVICE_SPREAD),
        PANEL_TEMPORAL_PHASE_ID => None,
        RELATIVE_GEOMETRY_PHASE_ID => match control_id {
            SCREEN_POSITION_X_CONTROL_ID
            | SCREEN_POSITION_Y_CONTROL_ID
            | SCREEN_POSITION_Z_CONTROL_ID
            | SCREEN_YAW_CONTROL_ID
            | SCREEN_ROTATION_X_CONTROL_ID
            | SCREEN_ROTATION_Z_CONTROL_ID => Some(DEVICE_GEOMETRY),
            _ => Some(CAMERA_GEOMETRY),
        },
        COVER_ENVIRONMENT_PHASE_ID => match control_id {
            ENVIRONMENT_CONTROL_ID
            | ENVIRONMENT_BROWSE_CONTROL_ID
            | ENVIRONMENT_AMOUNT_CONTROL_ID
            | ENVIRONMENT_ROTATION_X_CONTROL_ID
            | ENVIRONMENT_ROTATION_Y_CONTROL_ID
            | ENVIRONMENT_ANCHOR_LONGITUDE_CONTROL_ID
            | ENVIRONMENT_ANCHOR_LATITUDE_CONTROL_ID
            | ENVIRONMENT_MOBIUS_A_REAL_CONTROL_ID
            | ENVIRONMENT_MOBIUS_A_IMAG_CONTROL_ID
            | ENVIRONMENT_MOBIUS_C_REAL_CONTROL_ID
            | ENVIRONMENT_MOBIUS_C_IMAG_CONTROL_ID
            | ENVIRONMENT_EXPOSURE_CONTROL_ID
            | ENVIRONMENT_CONTRAST_CONTROL_ID
            | ENVIRONMENT_SATURATION_CONTROL_ID
            | ENVIRONMENT_TEMPERATURE_CONTROL_ID
            | ENVIRONMENT_TINT_CONTROL_ID
            | ENVIRONMENT_PROJECTION_CONTROL_ID
            | ENVIRONMENT_CENTER_X_CONTROL_ID
            | ENVIRONMENT_CENTER_Y_CONTROL_ID
            | ENVIRONMENT_CENTER_Z_CONTROL_ID
            | ENVIRONMENT_RADIUS_CONTROL_ID => Some(ENVIRONMENT),
            _ => Some(DEVICE_GLASS),
        },
        COVER_GLOW_PHASE_ID => Some(DEVICE_GLOW),
        LENS_PROJECTION_PHASE_ID => Some(CAMERA_LENS),
        SHUTTER_EXPOSURE_PHASE_ID => Some(CAMERA_SENSOR),
        SENSOR_COLLECTION_PHASE_ID => Some(CAMERA_COLLECTION),
        SENSOR_BLOOM_PHASE_ID => Some(CAMERA_BLOOM),
        COMPUTATIONAL_CAPTURE_PHASE_ID => Some(CAMERA_COMPUTATIONAL),
        CAMERA_RENDERING_INTENT_PHASE_ID => Some(CAMERA_INTENT),
        RECORDING_CODEC_PHASE_ID => Some(CAMERA_CODEC),
        DELIVERY_RASTER_PHASE_ID => Some(DELIVERY),
        ORIGIN_PHASE_ID
        | SENSOR_READOUT_RAW_PHASE_ID
        | DEVELOP_DEMOSAIC_PHASE_ID
        | RECORDING_OUTPUT_PHASE_ID => None,
        _ => None,
    }
}

fn choice_control(
    id: &'static str,
    label: &'static str,
    options: Vec<TestChoiceOption>,
    selected_id: &str,
    reset_id: &str,
) -> TestControlRequirement {
    TestControlRequirement::Choice {
        id,
        label,
        options: options
            .into_iter()
            .map(|option| TestOwnedChoiceOption {
                id: option.id.to_owned(),
                label: option.label.to_owned(),
            })
            .collect(),
        selected_id: selected_id.to_owned(),
        reset_id: reset_id.to_owned(),
    }
}

fn owned_choice_control(
    id: &'static str,
    label: &'static str,
    options: Vec<TestOwnedChoiceOption>,
    selected_id: &str,
    reset_id: &str,
) -> TestControlRequirement {
    TestControlRequirement::Choice {
        id,
        label,
        options,
        selected_id: selected_id.to_owned(),
        reset_id: reset_id.to_owned(),
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

fn action_control(id: &'static str, label: &'static str) -> TestControlRequirement {
    TestControlRequirement::Action { id, label }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PhysicalArtifactId {
    EncodedSourceRasterV1,
    LinearAcesCgRasterV1,
    SourceGradedAcesCgV1,
    PlacedFeederSignalV1,
    PanelEmissionRadianceV1,
    SubpixelRadianceV1,
    UniformPanelRadianceV1,
    SpreadPanelRadianceV1,
    TemporallyIntegratedPanelRadianceV1,
    ResolvedObservationGeometryV1,
    CoveredDirectionalRadianceV1,
    GlassScatteredRadianceV1,
    ImagePlaneIlluminanceAcesCgV1,
    IntegratedOpticalExposureV1,
    ComputationalCaptureExposureV2,
    CollectedSensorChargeV1,
    CoupledSensorChargeV1,
    RawMosaicNoisyV1,
    DevelopedCameraAcesCgV1,
    CameraRenderedAcesCgV1,
    DeviceVfxCompositeV1,
    DeliveryAcesCgRasterV1,
    RecordingOutputSignalV2,
    DecodedRecordingSignalV1,
}

impl PhysicalArtifactId {
    pub const fn stable_id(self) -> &'static str {
        match self {
            Self::EncodedSourceRasterV1 => "encoded-source-raster-v1",
            Self::LinearAcesCgRasterV1 => "linear-acescg-raster-v1",
            Self::SourceGradedAcesCgV1 => "source-graded-acescg-v1",
            Self::PlacedFeederSignalV1 => "placed-feeder-signal-v1",
            Self::PanelEmissionRadianceV1 => "panel-emission-radiance-v1",
            Self::SubpixelRadianceV1 => "subpixel-radiance-v1",
            Self::UniformPanelRadianceV1 => "uniform-panel-radiance-v1",
            Self::SpreadPanelRadianceV1 => "spread-panel-radiance-v1",
            Self::TemporallyIntegratedPanelRadianceV1 => "temporally-integrated-panel-radiance-v1",
            Self::ResolvedObservationGeometryV1 => "resolved-observation-geometry-v1",
            Self::CoveredDirectionalRadianceV1 => "covered-directional-radiance-v1",
            Self::GlassScatteredRadianceV1 => "glass-scattered-radiance-v1",
            Self::ImagePlaneIlluminanceAcesCgV1 => "image-plane-illuminance-acescg-v1",
            Self::IntegratedOpticalExposureV1 => "integrated-optical-exposure-v1",
            Self::ComputationalCaptureExposureV2 => "computational-capture-exposure-v2",
            Self::CollectedSensorChargeV1 => "collected-sensor-charge-v1",
            Self::CoupledSensorChargeV1 => "coupled-sensor-charge-v1",
            Self::RawMosaicNoisyV1 => "raw-mosaic-noisy-v1",
            Self::DevelopedCameraAcesCgV1 => "developed-camera-acescg-v1",
            Self::CameraRenderedAcesCgV1 => "camera-rendered-acescg-v1",
            Self::DeviceVfxCompositeV1 => "device-vfx-composite-v1",
            Self::DeliveryAcesCgRasterV1 => "delivery-acescg-raster-v1",
            Self::RecordingOutputSignalV2 => "recording-output-signal-v2",
            Self::DecodedRecordingSignalV1 => "decoded-recording-signal-v1",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TestPhaseDescriptor {
    pub id: &'static str,
    pub label: &'static str,
    pub effect_summary: &'static str,
    pub header_control_id: Option<&'static str>,
    pub input_artifact: PhysicalArtifactId,
    pub output_artifact: PhysicalArtifactId,
    pub preview_result: TestPreviewResult,
    pub controls: Vec<TestControlRequirement>,
}

impl TestPhaseDescriptor {
    pub fn calculation_domain(&self) -> &'static str {
        match self.id {
            ORIGIN_PHASE_ID
            | SOURCE_ADJUSTMENT_PHASE_ID
            | DEVELOP_DEMOSAIC_PHASE_ID
            | CAMERA_RENDERING_INTENT_PHASE_ID
            | DEVICE_VFX_TRANSPARENCY_PHASE_ID
            | DELIVERY_RASTER_PHASE_ID => "ACEScg lineal",
            FEEDER_SIGNAL_PHASE_ID => "Señal Device no lineal",
            DEVICE_INTERPRETATION_PHASE_ID
            | PANEL_STRUCTURE_PHASE_ID
            | PANEL_UNIFORMITY_PHASE_ID
            | PANEL_LIGHT_SPREAD_PHASE_ID
            | PANEL_TEMPORAL_PHASE_ID
            | COVER_ENVIRONMENT_PHASE_ID
            | COVER_GLOW_PHASE_ID => "Radiancia espectral RGB",
            RELATIVE_GEOMETRY_PHASE_ID => "Geometría física",
            LENS_PROJECTION_PHASE_ID => "Iluminancia ACEScg",
            SHUTTER_EXPOSURE_PHASE_ID | COMPUTATIONAL_CAPTURE_PHASE_ID => "Exposición ACEScg",
            SENSOR_COLLECTION_PHASE_ID | SENSOR_BLOOM_PHASE_ID => "Carga de fotositos",
            SENSOR_READOUT_RAW_PHASE_ID => "RAW mosaico",
            RECORDING_OUTPUT_PHASE_ID | RECORDING_CODEC_PHASE_ID => "Señal de grabación",
            _ => unreachable!("all Test phases own a calculation domain"),
        }
    }

    pub const fn preview_route(&self) -> &'static str {
        "Preview ODT seleccionado"
    }

    /// Returns the exact physical checkpoint required to publish this phase.
    /// Application is the sole authority for this mapping; hosts must not
    /// reconstruct it from phase labels, ids, order, or preview result values.
    pub const fn physical_intermediate(&self) -> Option<PhysicalIntermediate> {
        self.preview_result.physical_intermediate()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum TestPreviewResult {
    SourceAcesCg = 0,
    SourceAdjustment = 1,
    FeederSignal = 2,
    DeviceInterpretation = 3,
    PanelStructure = 4,
    PanelUniformity = 5,
    PanelLightSpread = 6,
    RelativeGeometry = 7,
    CoverEnvironment = 8,
    CoverGlow = 9,
    LensProjection = 10,
    ShutterExposure = 11,
    ComputationalCapture = 12,
    SensorCollection = 13,
    SensorBloom = 14,
    SensorReadoutRaw = 15,
    DevelopDemosaic = 16,
    CameraRenderingIntent = 17,
    DeliveryRaster = 18,
    RecordingOutput = 19,
    RecordingCodec = 20,
    DeviceVfxTransparency = 21,
    PanelTemporal = 22,
}

// Tracking solutions may use an arbitrary world origin. Only relative camera/device
// geometry is physically constrained, while absolute coordinates need a large finite guard.
const MAX_WORLD_COORDINATE_METERS: f32 = 1_000_000.0;

impl TestPreviewResult {
    pub const fn physical_intermediate(self) -> Option<PhysicalIntermediate> {
        match self {
            Self::SourceAcesCg | Self::SourceAdjustment => None,
            Self::FeederSignal => Some(PhysicalIntermediate::DeviceSignal),
            Self::DeviceInterpretation => Some(PhysicalIntermediate::PanelEmission),
            Self::PanelStructure => Some(PhysicalIntermediate::SubpixelRadiance),
            Self::PanelUniformity => Some(PhysicalIntermediate::PanelUniformity),
            Self::PanelLightSpread => Some(PhysicalIntermediate::PanelLightSpread),
            Self::PanelTemporal => Some(PhysicalIntermediate::PanelTemporal),
            Self::RelativeGeometry => Some(PhysicalIntermediate::RelativeGeometry),
            Self::CoverEnvironment => Some(PhysicalIntermediate::CoverEnvironment),
            Self::CoverGlow => Some(PhysicalIntermediate::CoverGlow),
            Self::LensProjection => Some(PhysicalIntermediate::LensProjection),
            Self::ShutterExposure => Some(PhysicalIntermediate::ShutterMotion),
            Self::ComputationalCapture => Some(PhysicalIntermediate::ComputationalCapture),
            Self::SensorCollection => Some(PhysicalIntermediate::SensorCollection),
            Self::SensorBloom => Some(PhysicalIntermediate::SensorBloom),
            Self::SensorReadoutRaw => Some(PhysicalIntermediate::SensorReadoutRaw),
            Self::DevelopDemosaic => Some(PhysicalIntermediate::DevelopedAcesCg),
            Self::CameraRenderingIntent
            | Self::DeviceVfxTransparency
            | Self::DeliveryRaster
            | Self::RecordingOutput
            | Self::RecordingCodec => Some(PhysicalIntermediate::CameraRenderedAcesCg),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TestPageDescriptor {
    pub schema_version: u32,
    pub default_preview_phase_id: &'static str,
    pub phases: Vec<TestPhaseDescriptor>,
    pub preview_controls: Vec<TestControlRequirement>,
    pub visible_preview_choice_ids: Vec<&'static str>,
    /// Model-owned presentation references for the frequently used controls.
    /// These are references to canonical controls in `phases`, never duplicate
    /// control definitions or UI-authored physical semantics.
    pub quick_control_ids: Vec<&'static str>,
    pub featured_phase_id: &'static str,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TestAuthoringError {
    UnknownInputTransform,
    UnknownOutputSignal,
    UnknownDevice,
    UnknownColorMode,
    UnsupportedColorMode,
    InvalidWhiteLuminance,
    InvalidSourceAdjustment,
    InvalidSubpixelGeometryAmount,
    InvalidMoireIntensity,
    InvalidMoireSaturation,
    InvalidMoireFilterStrength,
    InvalidPanelUniformityAmount,
    InvalidPanelLightSpreadAmount,
    UnknownCapturePreset,
    InvalidCaptureRasterMode,
    UnknownLensPreset,
    UnsupportedLensPreset,
    InvalidGeometry,
    UnknownCoverGlassPreset,
    InvalidCoverGlassAmount,
    InvalidCoverGlassProfile,
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
    InvalidCameraRenderingIntent,
    InvalidDeliveryRaster,
    UnknownRecordingOutputTransform,
    InvalidRecording,
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
            Self::InvalidSourceAdjustment => "Source Adjustment is invalid",
            Self::InvalidSubpixelGeometryAmount => "Subpixel Geometry amount is outside 0..=4",
            Self::InvalidMoireIntensity => "Moiré intensity is outside 0..=4",
            Self::InvalidMoireSaturation => "Moiré saturation is outside 0..=4",
            Self::InvalidMoireFilterStrength => "Moiré filter strength is outside 0..=4",
            Self::InvalidPanelUniformityAmount => "Panel Uniformity amount is outside 0..=4",
            Self::InvalidPanelLightSpreadAmount => "Panel Light Spread amount is outside 0..=4",
            Self::UnknownCapturePreset => "unknown Test Capture preset",
            Self::InvalidCaptureRasterMode => "invalid Test capture raster mode",
            Self::UnknownLensPreset => "unknown Test Lens preset",
            Self::UnsupportedLensPreset => "Lens preset is not compatible with the selected Camera",
            Self::InvalidGeometry => "Test relative geometry is invalid",
            Self::UnknownCoverGlassPreset => "unknown Test Cover Glass preset",
            Self::InvalidCoverGlassAmount => "Cover Glass amount is outside 0..=2",
            Self::InvalidCoverGlassProfile => {
                "Cover Glass parameters are outside their physical bounds"
            }
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
            Self::InvalidCameraRenderingIntent => "Camera Rendering Intent is invalid",
            Self::InvalidDeliveryRaster => "Delivery Raster is invalid",
            Self::UnknownRecordingOutputTransform => "unknown Recording Output transform",
            Self::InvalidRecording => "Recording selection is invalid",
            Self::UnknownPlacement => "unknown Test placement",
            Self::UnknownPreviewQuality => "unknown Test preview quality",
            Self::UnknownControl => "unknown Test control",
            Self::WrongControlType => "Test intent does not match the control type",
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TestDeviceAuthoringProfile<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub color_mode_ids: Vec<&'a str>,
    pub default_color_mode_id: &'a str,
    pub reference_white_nits: f32,
    pub minimum_white_nits: f32,
    pub maximum_white_nits: f32,
    pub white_step_nits: f32,
    pub uniformity_character_strength: f32,
    pub light_spread_character_strength: f32,
    pub default_cover_glass_profile_id: &'a str,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TestCoverAuthoringProfile<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub profile: screen_cover::CoverGlassProfile,
    pub character_strength: f32,
    pub anti_glare_character_strength: f32,
    pub thickness_millimeters: f32,
    pub refractive_index: f32,
    pub anti_reflective_efficiency: f32,
    pub absorption_rgb: [f32; 3],
    pub roughness: f32,
    pub haze: f32,
    pub anti_glare_rms_slope: f32,
    pub anti_glare_correlation_micrometers: f32,
    pub anti_glare_anisotropy: f32,
    pub glow_character_strength: f32,
    pub glow_intensity: f32,
    pub glow_radius_millimeters: f32,
    pub glow_threshold_relative_white: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TestCaptureRasterMode<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TestCaptureAuthoringProfile<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub raster_modes: Vec<TestCaptureRasterMode<'a>>,
    pub default_raster_mode_id: &'a str,
    pub default_recording_profile_id: &'a str,
    pub recommended_recording_profile_ids: Vec<&'a str>,
    pub default_lens_evaluation_model: crate::LensEvaluationModel,
    pub computational_capture: crate::ComputationalCaptureProfile,
    pub rendering_intent: CameraRenderingIntent,
    pub sensor_bloom: screen_sensor::SensorBloomProfile,
    pub default_lens_preset_id: &'a str,
    pub compatible_lens_preset_ids: Vec<&'a str>,
    pub f_stop: f32,
    pub default_shutter_angle_degrees: f32,
}

impl TestCaptureAuthoringProfile<'_> {
    fn raster_mode(&self, id: &str) -> Option<TestCaptureRasterMode<'_>> {
        self.raster_modes.iter().copied().find(|mode| mode.id == id)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TestLensAuthoringProfile<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub nominal_focal_length_millimeters: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TestEnvironmentAuthoringProfile<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub environment: screen_cover::ProceduralEnvironment,
}

pub trait TestAuthoringProfileSource {
    fn device<'a>(&'a self, id: &str) -> Option<TestDeviceAuthoringProfile<'a>>;
    fn cover<'a>(&'a self, id: &str) -> Option<TestCoverAuthoringProfile<'a>>;
    fn capture<'a>(&'a self, id: &str) -> Option<TestCaptureAuthoringProfile<'a>>;
    fn lens<'a>(&'a self, id: &str) -> Option<TestLensAuthoringProfile<'a>>;
    fn environment<'a>(&'a self, id: &str) -> Option<TestEnvironmentAuthoringProfile<'a>>;
    fn device_options(&self) -> Vec<TestOwnedChoiceOption>;
    fn cover_options(&self) -> Vec<TestOwnedChoiceOption>;
    fn capture_options(&self) -> Vec<TestOwnedChoiceOption>;
    fn environment_options(&self) -> Vec<TestOwnedChoiceOption>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct BuiltInTestAuthoringProfiles;

pub static BUILT_IN_TEST_AUTHORING_PROFILES: BuiltInTestAuthoringProfiles =
    BuiltInTestAuthoringProfiles;

impl TestAuthoringProfileSource for BuiltInTestAuthoringProfiles {
    fn device<'a>(&'a self, id: &str) -> Option<TestDeviceAuthoringProfile<'a>> {
        DEVICE_PRESETS
            .iter()
            .find(|candidate| candidate.id == id)
            .map(|device| device_profile(*device))
    }

    fn cover<'a>(&'a self, id: &str) -> Option<TestCoverAuthoringProfile<'a>> {
        cover_glass_preset(id).map(cover_profile)
    }

    fn capture<'a>(&'a self, id: &str) -> Option<TestCaptureAuthoringProfile<'a>> {
        capture_device_preset(id).map(capture_profile)
    }

    fn lens<'a>(&'a self, id: &str) -> Option<TestLensAuthoringProfile<'a>> {
        lens_preset(id).map(lens_profile)
    }

    fn environment<'a>(&'a self, id: &str) -> Option<TestEnvironmentAuthoringProfile<'a>> {
        environment_preset(id).map(environment_profile)
    }

    fn device_options(&self) -> Vec<TestOwnedChoiceOption> {
        DEVICE_PRESETS
            .iter()
            .map(|profile| TestOwnedChoiceOption {
                id: profile.id.to_owned(),
                label: profile.label.to_owned(),
            })
            .collect()
    }

    fn cover_options(&self) -> Vec<TestOwnedChoiceOption> {
        COVER_GLASS_PRESETS
            .iter()
            .map(|profile| TestOwnedChoiceOption {
                id: profile.id.to_owned(),
                label: profile.label.to_owned(),
            })
            .collect()
    }

    fn capture_options(&self) -> Vec<TestOwnedChoiceOption> {
        CAPTURE_DEVICE_PRESETS
            .iter()
            .map(|profile| TestOwnedChoiceOption {
                id: profile.id.to_owned(),
                label: profile.label.to_owned(),
            })
            .collect()
    }

    fn environment_options(&self) -> Vec<TestOwnedChoiceOption> {
        ENVIRONMENT_PRESETS
            .iter()
            .map(|profile| TestOwnedChoiceOption {
                id: profile.id.to_owned(),
                label: profile.label.to_owned(),
            })
            .collect()
    }
}

fn capture_profile(capture: CaptureDevicePreset) -> TestCaptureAuthoringProfile<'static> {
    TestCaptureAuthoringProfile {
        id: capture.id,
        label: capture.label,
        raster_modes: capture
            .raster_modes
            .into_iter()
            .map(|mode| TestCaptureRasterMode {
                id: mode.id,
                label: mode.label,
                width: u32::from(mode.width),
                height: u32::from(mode.height),
            })
            .collect(),
        default_raster_mode_id: capture.default_raster_mode_id,
        default_recording_profile_id: capture.default_recording_profile_id,
        recommended_recording_profile_ids: capture.recommended_recording_profile_ids.to_vec(),
        default_lens_evaluation_model: capture.default_lens_evaluation_model,
        computational_capture: capture.computational_capture,
        rendering_intent: capture.rendering_intent,
        sensor_bloom: capture.sensor.bloom,
        default_lens_preset_id: capture.default_lens_preset_id,
        compatible_lens_preset_ids: capture.compatible_lens_preset_ids.to_vec(),
        f_stop: capture.f_stop,
        default_shutter_angle_degrees: capture.default_shutter_angle_degrees,
    }
}

fn lens_profile(lens: LensPreset) -> TestLensAuthoringProfile<'static> {
    TestLensAuthoringProfile {
        id: lens.id,
        label: lens.label,
        nominal_focal_length_millimeters: lens.nominal_focal_length.0,
    }
}

fn environment_profile(
    environment: screen_cover::EnvironmentPreset,
) -> TestEnvironmentAuthoringProfile<'static> {
    TestEnvironmentAuthoringProfile {
        id: environment.id,
        label: environment.label,
        environment: environment.environment,
    }
}

fn device_profile(device: DevicePreset) -> TestDeviceAuthoringProfile<'static> {
    TestDeviceAuthoringProfile {
        id: device.id,
        label: device.label,
        color_mode_ids: device.color_mode_ids.to_vec(),
        default_color_mode_id: device.default_color_mode_id,
        reference_white_nits: device.reference_white_nits,
        minimum_white_nits: device.minimum_white_nits,
        maximum_white_nits: device.maximum_white_nits,
        white_step_nits: device.white_step_nits,
        uniformity_character_strength: device.uniformity.character_strength,
        light_spread_character_strength: device.light_spread.character_strength,
        default_cover_glass_profile_id: device.default_cover_glass_preset_id,
    }
}

fn cover_profile(cover: screen_cover::CoverGlassPreset) -> TestCoverAuthoringProfile<'static> {
    TestCoverAuthoringProfile {
        id: cover.id,
        label: cover.label,
        profile: cover.profile,
        character_strength: cover.profile.character_strength,
        anti_glare_character_strength: cover.profile.anti_glare_microtexture.character_strength,
        thickness_millimeters: cover.profile.thickness_millimeters,
        refractive_index: cover.profile.refractive_index,
        anti_reflective_efficiency: cover.profile.anti_reflective_efficiency,
        absorption_rgb: [
            cover.profile.absorption_per_millimeter.r,
            cover.profile.absorption_per_millimeter.g,
            cover.profile.absorption_per_millimeter.b,
        ],
        roughness: cover.profile.roughness,
        haze: cover.profile.haze,
        anti_glare_rms_slope: cover.profile.anti_glare_microtexture.rms_slope,
        anti_glare_correlation_micrometers: cover
            .profile
            .anti_glare_microtexture
            .correlation_length_micrometers,
        anti_glare_anisotropy: cover.profile.anti_glare_microtexture.anisotropy,
        glow_character_strength: cover.profile.glow.character_strength,
        glow_intensity: cover.profile.glow.intensity,
        glow_radius_millimeters: cover.profile.glow.radius_millimeters,
        glow_threshold_relative_white: cover.profile.glow.threshold_relative_to_panel_white,
    }
}

fn preset<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    id: &str,
) -> Result<TestDeviceAuthoringProfile<'a>, TestAuthoringError> {
    profiles.device(id).ok_or(TestAuthoringError::UnknownDevice)
}

fn capture<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    id: &str,
) -> Result<TestCaptureAuthoringProfile<'a>, TestAuthoringError> {
    profiles
        .capture(id)
        .ok_or(TestAuthoringError::UnknownCapturePreset)
}

fn lens<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    id: &str,
) -> Result<TestLensAuthoringProfile<'a>, TestAuthoringError> {
    profiles
        .lens(id)
        .ok_or(TestAuthoringError::UnknownLensPreset)
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
        OcioInputTransform::SrgbEncodedRec709 | OcioInputTransform::DisplaySrgbAces2Sdr => {
            DeviceColorTarget::SrgbDisplay
        }
        OcioInputTransform::DisplayRec709Gamma22Dcm
        | OcioInputTransform::DisplayRec709Gamma22Aces2Sdr => {
            DeviceColorTarget::Gamma22Rec709Display
        }
        OcioInputTransform::Rec709Gamma24Display | OcioInputTransform::DisplayRec709Aces2Sdr => {
            DeviceColorTarget::Rec1886Rec709Display
        }
        OcioInputTransform::DisplayRec2100PqDcm
        | OcioInputTransform::DisplayRec2100PqAces2Hdr1000 => {
            DeviceColorTarget::Rec2100Pq1000Display
        }
        OcioInputTransform::DisplayRec2100HlgDcm
        | OcioInputTransform::DisplayRec2100HlgAces2Hdr1000 => {
            DeviceColorTarget::Rec2100Hlg1000Display
        }
        _ => DeviceColorTarget::SrgbDisplay,
    }
}

pub fn default_test_authoring_selection(
    input_transform_id: &str,
    device_id: &str,
    frame_rate: FrameRate,
) -> Result<ResolvedTestAuthoringSelection<'static>, TestAuthoringError> {
    default_test_authoring_selection_with_profiles(
        &BUILT_IN_TEST_AUTHORING_PROFILES,
        input_transform_id,
        device_id,
        frame_rate,
    )
}

pub fn default_test_authoring_selection_with_profiles<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    input_transform_id: &str,
    device_id: &str,
    frame_rate: FrameRate,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    let input = OcioInputTransform::from_stable_id(input_transform_id)
        .ok_or(TestAuthoringError::UnknownInputTransform)?;
    let output = default_output_for_input(input);
    let device = preset(profiles, device_id)?;
    let capture = capture(profiles, "iphone-16e-main-48mp")?;
    let seed_distance = 0.15_f32;
    let seed_orbit_y = -5.0_f32;
    let cover = profiles
        .cover(device.default_cover_glass_profile_id)
        .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?;
    resolve_test_authoring_selection_with_profiles(
        profiles,
        TestAuthoringSelection {
            input_transform_id: input.stable_id(),
            output_signal_id: output.stable_id(),
            device_id: device.id,
            color_mode_id: device.default_color_mode_id,
            white_luminance_nits: device.reference_white_nits,
            placement_id: "fit",
            preview_quality_id: "setup",
            frame_rate,
            source_adjustment: SceneLinearAdjustment::NEUTRAL,
            subpixel_geometry_amount: 1.0,
            moire_intensity: 1.0,
            moire_saturation: 1.0,
            moire_filter_strength: 0.0,
            panel_uniformity_amount: device.uniformity_character_strength,
            panel_light_spread_amount: device.light_spread_character_strength,
            capture_preset_id: capture.id,
            capture_raster_mode_id: capture.default_raster_mode_id,
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
            cover_glass_preset_id: device.default_cover_glass_profile_id,
            cover_glass_amount: 1.0,
            cover_ag_microtexture_amount: cover.anti_glare_character_strength,
            cover_thickness_millimeters: cover.thickness_millimeters,
            cover_refractive_index: cover.refractive_index,
            cover_ar_efficiency: cover.anti_reflective_efficiency,
            cover_absorption_rgb: cover.absorption_rgb,
            cover_roughness: cover.roughness,
            cover_haze: cover.haze,
            cover_ag_rms_slope: cover.anti_glare_rms_slope,
            cover_ag_correlation_micrometers: cover.anti_glare_correlation_micrometers,
            cover_ag_anisotropy: cover.anti_glare_anisotropy,
            environment_source_id: "environment-none",
            environment_amount: 0.0,
            environment_rotation_x_degrees: 0.0,
            environment_rotation_y_degrees: 0.0,
            environment_anchor_longitude_degrees: 0.0,
            environment_anchor_latitude_degrees: 0.0,
            environment_tangent_transform: [1.0, 0.0, 0.0, 0.0],
            environment_exposure_ev: 0.0,
            environment_contrast: 1.0,
            environment_saturation: 1.0,
            environment_temperature_kelvin: 6500.0,
            environment_tint: 0.0,
            environment_projection_id: "distant",
            environment_sphere_center_x_meters: 0.0,
            environment_sphere_center_y_meters: 0.0,
            environment_sphere_center_z_meters: 0.0,
            environment_sphere_radius_meters: 5.0,
            cover_glow_amount: cover.glow_character_strength,
            cover_glow_intensity: cover.glow_intensity,
            cover_glow_radius_millimeters: cover.glow_radius_millimeters,
            cover_glow_threshold_relative_white: cover.glow_threshold_relative_white,
            cover_glow_exterior_intensity: 1.0,
            lens_preset_id: capture.default_lens_preset_id,
            focal_length_millimeters: lens(profiles, capture.default_lens_preset_id)?
                .nominal_focal_length_millimeters,
            lens_evaluation_model_id: lens_evaluation_model_id(
                capture.default_lens_evaluation_model,
            ),
            lens_amount: 1.0,
            autofocus_enabled: true,
            autofocus_target_u: 0.5,
            autofocus_target_v: 0.5,
            focus_distance_meters: 0.15,
            f_stop: capture.f_stop,
            exposure_time_seconds: capture.default_shutter_angle_degrees
                / 360.0
                / frame_rate.as_f32(),
            shutter_motion_amount: 1.0,
            computational_character_strength: 1.0,
            computational_exposure_count: f32::from(capture.computational_capture.exposure_count),
            computational_bracket_spacing_stops: capture
                .computational_capture
                .bracket_spacing_stops,
            sensor_bloom_amount: 1.0,
            sensor_bloom_crosstalk_fraction: capture.sensor_bloom.crosstalk_fraction,
            sensor_bloom_overflow_transfer_fraction: capture
                .sensor_bloom
                .overflow_transfer_fraction,
            sensor_noise_amount: 1.0,
            camera_rendering_intent: capture.rendering_intent,
            device_vfx_alpha_mode_id: "device-transparency",
            delivery_preset_id: "uhd",
            delivery_width: 3_840.0,
            delivery_height: 2_160.0,
            delivery_placement_id: "fit",
            delivery_background_id: "black",
            recording_output_transform_id: screen_color::IPHONE_HEIC_RECORDING_OUTPUT_TRANSFORM_ID,
            recording_profile_id: IPHONE_HEIC_PHOTO_PROFILE_ID,
            recording_character: 1.0,
        },
    )
}

pub fn resolve_test_authoring_selection<'a>(
    selection: TestAuthoringSelection<'a>,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    resolve_test_authoring_selection_with_profiles(&BUILT_IN_TEST_AUTHORING_PROFILES, selection)
}

pub fn resolve_test_authoring_selection_with_profiles<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    selection: TestAuthoringSelection<'a>,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    let input = OcioInputTransform::from_stable_id(selection.input_transform_id)
        .ok_or(TestAuthoringError::UnknownInputTransform)?;
    let output = color_target(
        selection.output_signal_id,
        TestAuthoringError::UnknownOutputSignal,
    )?;
    let device = preset(profiles, selection.device_id)?;
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
    selection
        .source_adjustment
        .validate()
        .map_err(|_| TestAuthoringError::InvalidSourceAdjustment)?;
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
    if !selection.moire_intensity.is_finite() || !(0.0..=4.0).contains(&selection.moire_intensity) {
        return Err(TestAuthoringError::InvalidMoireIntensity);
    }
    if !selection.moire_saturation.is_finite() || !(0.0..=4.0).contains(&selection.moire_saturation)
    {
        return Err(TestAuthoringError::InvalidMoireSaturation);
    }
    if !selection.moire_filter_strength.is_finite()
        || !(0.0..=4.0).contains(&selection.moire_filter_strength)
    {
        return Err(TestAuthoringError::InvalidMoireFilterStrength);
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
    let capture = capture(profiles, selection.capture_preset_id)?;
    let _capture_raster_mode = capture
        .raster_mode(selection.capture_raster_mode_id)
        .ok_or(TestAuthoringError::InvalidCaptureRasterMode)?;
    let lens = lens(profiles, selection.lens_preset_id)?;
    let (minimum_focal_length, maximum_focal_length) = focal_length_bounds();
    if !selection.focal_length_millimeters.is_finite()
        || !(minimum_focal_length..=maximum_focal_length)
            .contains(&selection.focal_length_millimeters)
    {
        return Err(TestAuthoringError::InvalidGeometry);
    }
    let lens_evaluation_model_id = match selection.lens_evaluation_model_id {
        "thin-lens" => "thin-lens",
        "vfx-2d-dof" => "vfx-2d-dof",
        _ => return Err(TestAuthoringError::UnknownControl),
    };
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
        .any(|value| value.abs() > MAX_WORLD_COORDINATE_METERS)
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
    let cover = profiles
        .cover(selection.cover_glass_preset_id)
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
    let mut authored_cover = cover.profile;
    authored_cover.character_strength = selection.cover_glass_amount;
    authored_cover.thickness_millimeters = selection.cover_thickness_millimeters;
    authored_cover.refractive_index = selection.cover_refractive_index;
    authored_cover.anti_reflective_efficiency = selection.cover_ar_efficiency;
    authored_cover.absorption_per_millimeter = LinearRgb::new(
        selection.cover_absorption_rgb[0],
        selection.cover_absorption_rgb[1],
        selection.cover_absorption_rgb[2],
    );
    authored_cover.roughness = selection.cover_roughness;
    authored_cover.haze = selection.cover_haze;
    authored_cover.anti_glare_microtexture.character_strength =
        selection.cover_ag_microtexture_amount;
    authored_cover.anti_glare_microtexture.rms_slope = selection.cover_ag_rms_slope;
    authored_cover
        .anti_glare_microtexture
        .correlation_length_micrometers = selection.cover_ag_correlation_micrometers;
    authored_cover.anti_glare_microtexture.anisotropy = selection.cover_ag_anisotropy;
    authored_cover.glow.character_strength = selection.cover_glow_amount;
    authored_cover.glow.intensity = selection.cover_glow_intensity;
    authored_cover.glow.radius_millimeters = selection.cover_glow_radius_millimeters;
    authored_cover.glow.threshold_relative_to_panel_white =
        selection.cover_glow_threshold_relative_white;
    authored_cover
        .validate()
        .map_err(|_| TestAuthoringError::InvalidCoverGlassProfile)?;
    let environment = profiles.environment(selection.environment_source_id);
    if environment.is_none() && selection.environment_source_id != IMAGE_ENVIRONMENT_SOURCE_ID {
        return Err(TestAuthoringError::UnknownEnvironmentPreset);
    }
    if !selection.environment_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.environment_amount)
    {
        return Err(TestAuthoringError::InvalidEnvironmentAmount);
    }
    if !selection.environment_rotation_x_degrees.is_finite()
        || !(-90.0..=90.0).contains(&selection.environment_rotation_x_degrees)
        || !selection.environment_rotation_y_degrees.is_finite()
        || !(-180.0..=180.0).contains(&selection.environment_rotation_y_degrees)
        || !selection.environment_anchor_longitude_degrees.is_finite()
        || !(-180.0..=180.0).contains(&selection.environment_anchor_longitude_degrees)
        || !selection.environment_anchor_latitude_degrees.is_finite()
        || !(-90.0..=90.0).contains(&selection.environment_anchor_latitude_degrees)
        || selection
            .environment_tangent_transform
            .iter()
            .any(|value| !value.is_finite() || value.abs() > ENVIRONMENT_TANGENT_COEFFICIENT_MAX)
        || (selection.environment_tangent_transform[0] * selection.environment_tangent_transform[0]
            + selection.environment_tangent_transform[1]
                * selection.environment_tangent_transform[1])
            .sqrt()
            < ENVIRONMENT_TANGENT_SCALE_MIN
        || !selection.environment_exposure_ev.is_finite()
        || !(-8.0..=8.0).contains(&selection.environment_exposure_ev)
    {
        return Err(TestAuthoringError::InvalidEnvironmentAmount);
    }
    if environment.is_some()
        && (selection.environment_exposure_ev != 0.0
            || selection.environment_contrast != 1.0
            || selection.environment_saturation != 1.0
            || selection.environment_temperature_kelvin != 6500.0
            || selection.environment_tint != 0.0)
    {
        return Err(TestAuthoringError::InvalidEnvironmentAmount);
    }
    SceneLinearAdjustment {
        exposure_ev: selection.environment_exposure_ev,
        contrast: selection.environment_contrast,
        saturation: selection.environment_saturation,
        temperature_kelvin: selection.environment_temperature_kelvin,
        tint: selection.environment_tint,
    }
    .validate()
    .map_err(|_| TestAuthoringError::InvalidEnvironmentAmount)?;
    let environment_projection_id = match selection.environment_projection_id {
        "distant" => "distant",
        "finite-sphere" => "finite-sphere",
        _ => return Err(TestAuthoringError::InvalidEnvironmentAmount),
    };
    if [
        selection.environment_sphere_center_x_meters,
        selection.environment_sphere_center_y_meters,
        selection.environment_sphere_center_z_meters,
    ]
    .into_iter()
    .any(|value| !value.is_finite() || value.abs() > 1_000.0)
        || !selection.environment_sphere_radius_meters.is_finite()
        || selection.environment_sphere_radius_meters <= 0.0
        || selection.environment_sphere_radius_meters > 1_000.0
        || (selection.environment_source_id != IMAGE_ENVIRONMENT_SOURCE_ID
            && selection.environment_projection_id != "distant")
    {
        return Err(TestAuthoringError::InvalidEnvironmentAmount);
    }
    if !selection.cover_glow_amount.is_finite()
        || !(0.0..=4.0).contains(&selection.cover_glow_amount)
        || !selection.cover_glow_exterior_intensity.is_finite()
        || !(0.0..=4.0).contains(&selection.cover_glow_exterior_intensity)
    {
        return Err(TestAuthoringError::InvalidCoverGlowAmount);
    }
    if !selection.lens_amount.is_finite() || !(0.0..=4.0).contains(&selection.lens_amount) {
        return Err(TestAuthoringError::InvalidLensAmount);
    }
    if !selection.focus_distance_meters.is_finite()
        || !(0.01..=100.0).contains(&selection.focus_distance_meters)
        || !selection.autofocus_target_u.is_finite()
        || !(0.0..=1.0).contains(&selection.autofocus_target_u)
        || !selection.autofocus_target_v.is_finite()
        || !(0.0..=1.0).contains(&selection.autofocus_target_v)
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
    // Autofocus is an unresolved scene intent. The scene resolver owns its distance after
    // sampling the exact camera and Device pose for the requested time.
    let resolved_focus_distance_meters = selection.focus_distance_meters;
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
    selection
        .camera_rendering_intent
        .validate()
        .map_err(|_| TestAuthoringError::InvalidCameraRenderingIntent)?;
    let device_vfx_alpha_mode_id = selected_option(
        &DEVICE_VFX_ALPHA_MODES,
        selection.device_vfx_alpha_mode_id,
        TestAuthoringError::UnknownControl,
    )?;
    let delivery_preset_id = selected_option(
        &DELIVERY_PRESETS,
        selection.delivery_preset_id,
        TestAuthoringError::InvalidDeliveryRaster,
    )?;
    if !selection.delivery_width.is_finite()
        || !selection.delivery_height.is_finite()
        || selection.delivery_width.fract() != 0.0
        || selection.delivery_height.fract() != 0.0
        || !(1.0..=16_384.0).contains(&selection.delivery_width)
        || !(1.0..=16_384.0).contains(&selection.delivery_height)
    {
        return Err(TestAuthoringError::InvalidDeliveryRaster);
    }
    let delivery_placement_id = selected_option(
        &DELIVERY_PLACEMENTS,
        selection.delivery_placement_id,
        TestAuthoringError::InvalidDeliveryRaster,
    )?;
    let delivery_background_id = selected_option(
        &DELIVERY_BACKGROUNDS,
        selection.delivery_background_id,
        TestAuthoringError::InvalidDeliveryRaster,
    )?;
    let recording_output_transform =
        recording_output_transform_for_profile(selection.recording_profile_id)?;
    if recording_output_transform.stable_id() != selection.recording_output_transform_id {
        return Err(TestAuthoringError::UnknownRecordingOutputTransform);
    }
    let selected_profile = bundled_profiles()
        .into_iter()
        .find(|profile| profile.id == selection.recording_profile_id)
        .ok_or(TestAuthoringError::InvalidRecording)?;
    let recording_frame_rate = if selected_profile.codec.medium() == RecordingMedium::MovingImage {
        Some(selection.frame_rate)
    } else {
        None
    };
    let recording = prepare_recording_request(RecordingSelection {
        profile_id: selection.recording_profile_id,
        character: selection.recording_character,
        frame_rate: recording_frame_rate,
        first_frame_index: 0,
        frame_count: 1,
        execution: EncoderExecutionPolicy::SINGLE_PASS,
    })
    .map_err(|_| TestAuthoringError::InvalidRecording)?;
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
        source_adjustment: selection.source_adjustment,
        subpixel_geometry_amount: selection.subpixel_geometry_amount,
        moire_intensity: selection.moire_intensity,
        moire_saturation: selection.moire_saturation,
        moire_filter_strength: selection.moire_filter_strength,
        panel_uniformity_amount: selection.panel_uniformity_amount,
        panel_light_spread_amount: selection.panel_light_spread_amount,
        capture_preset_id: capture.id,
        capture_raster_mode_id: selection.capture_raster_mode_id,
        delivery_width: selection.delivery_width as u32,
        delivery_height: selection.delivery_height as u32,
        delivery_placement_id,
        delivery_background_id,
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
        cover_thickness_millimeters: selection.cover_thickness_millimeters,
        cover_refractive_index: selection.cover_refractive_index,
        cover_ar_efficiency: selection.cover_ar_efficiency,
        cover_absorption_rgb: selection.cover_absorption_rgb,
        cover_roughness: selection.cover_roughness,
        cover_haze: selection.cover_haze,
        cover_ag_rms_slope: selection.cover_ag_rms_slope,
        cover_ag_correlation_micrometers: selection.cover_ag_correlation_micrometers,
        cover_ag_anisotropy: selection.cover_ag_anisotropy,
        environment_source_id: environment
            .map(|environment| environment.id)
            .unwrap_or(IMAGE_ENVIRONMENT_SOURCE_ID),
        environment_amount: selection.environment_amount,
        environment_rotation_x_degrees: selection.environment_rotation_x_degrees,
        environment_rotation_y_degrees: selection.environment_rotation_y_degrees,
        environment_anchor_longitude_degrees: selection.environment_anchor_longitude_degrees,
        environment_anchor_latitude_degrees: selection.environment_anchor_latitude_degrees,
        environment_tangent_transform: selection.environment_tangent_transform,
        environment_exposure_ev: selection.environment_exposure_ev,
        environment_contrast: selection.environment_contrast,
        environment_saturation: selection.environment_saturation,
        environment_temperature_kelvin: selection.environment_temperature_kelvin,
        environment_tint: selection.environment_tint,
        environment_projection_id,
        environment_sphere_center_x_meters: selection.environment_sphere_center_x_meters,
        environment_sphere_center_y_meters: selection.environment_sphere_center_y_meters,
        environment_sphere_center_z_meters: selection.environment_sphere_center_z_meters,
        environment_sphere_radius_meters: selection.environment_sphere_radius_meters,
        cover_glow_amount: selection.cover_glow_amount,
        cover_glow_intensity: selection.cover_glow_intensity,
        cover_glow_radius_millimeters: selection.cover_glow_radius_millimeters,
        cover_glow_threshold_relative_white: selection.cover_glow_threshold_relative_white,
        cover_glow_exterior_intensity: selection.cover_glow_exterior_intensity,
        lens_preset_id: lens.id,
        focal_length_millimeters: selection.focal_length_millimeters,
        lens_evaluation_model_id,
        lens_amount: selection.lens_amount,
        autofocus_enabled: selection.autofocus_enabled,
        autofocus_target_u: selection.autofocus_target_u,
        autofocus_target_v: selection.autofocus_target_v,
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
        camera_rendering_intent: selection.camera_rendering_intent,
        device_vfx_alpha_mode_id,
        delivery_preset_id,
        recording_output_transform_id: recording_output_transform.stable_id(),
        recording_profile_id: recording.profile.id,
        recording_character: recording.character,
    })
}

pub fn test_page_descriptor(
    selection: TestAuthoringSelection<'_>,
) -> Result<TestPageDescriptor, TestAuthoringError> {
    test_page_descriptor_with_profiles(&BUILT_IN_TEST_AUTHORING_PROFILES, selection)
}

pub fn test_page_descriptor_with_profiles<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    selection: TestAuthoringSelection<'a>,
) -> Result<TestPageDescriptor, TestAuthoringError> {
    let selection = resolve_test_authoring_selection_with_profiles(profiles, selection)?;
    let device = preset(profiles, selection.device_id)?;
    let output_options = DeviceColorTarget::ALL
        .into_iter()
        .map(|target| TestChoiceOption {
            id: target.stable_id(),
            label: target.label(),
        })
        .collect();
    let device_options = profiles.device_options();
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
    let capture = capture(profiles, selection.capture_preset_id)?;
    let capture_options = profiles.capture_options();
    let lens_options: Vec<TestOwnedChoiceOption> = capture
        .compatible_lens_preset_ids
        .iter()
        .map(|id| {
            let preset =
                lens(profiles, id).expect("validated Camera profiles reference current Lenses");
            TestOwnedChoiceOption {
                id: preset.id.to_owned(),
                label: preset.label.to_owned(),
            }
        })
        .collect();
    let cover_options = profiles.cover_options();
    let mut environment_options = profiles.environment_options();
    environment_options.push(TestOwnedChoiceOption {
        id: IMAGE_ENVIRONMENT_SOURCE_ID.to_owned(),
        label: "HDRI / EXR seleccionado".to_owned(),
    });
    let recording_profile_options = recording_profile_options(&capture);
    let input = OcioInputTransform::from_stable_id(selection.input_transform_id)
        .ok_or(TestAuthoringError::UnknownInputTransform)?;
    let reset_output_signal_id = default_output_for_input(input).stable_id();
    let reset_device = preset(profiles, "lcd-asus-proart-pa329cv")?;
    let reset_capture = profiles
        .capture("iphone-16e-main-48mp")
        .ok_or(TestAuthoringError::UnknownCapturePreset)?;
    let selected_cover = profiles
        .cover(selection.cover_glass_preset_id)
        .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?;
    let selected_environment = profiles.environment(selection.environment_source_id);
    let environment_reset_amount = selected_environment
        .map(|environment| environment.environment.character_strength)
        .unwrap_or(1.0);
    let seed_distance = 0.15_f32;
    let seed_orbit_y = -5.0_f32;
    let seed_camera_x = seed_distance * seed_orbit_y.to_radians().sin();
    let seed_camera_z = seed_distance * seed_orbit_y.to_radians().cos();
    let mut geometry_controls = vec![
        owned_choice_control(
            CAPTURE_PRESET_CONTROL_ID,
            "Cámara",
            capture_options,
            selection.capture_preset_id,
            reset_capture.id,
        ),
        owned_choice_control(
            CAPTURE_RASTER_MODE_CONTROL_ID,
            "Resolución de captura",
            capture
                .raster_modes
                .iter()
                .map(|mode| TestOwnedChoiceOption {
                    id: mode.id.to_owned(),
                    label: mode.label.to_owned(),
                })
                .collect(),
            selection.capture_raster_mode_id,
            capture.default_raster_mode_id,
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
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Y_CONTROL_ID,
                "Pantalla Y",
                selection.screen_position_y_meters,
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Z_CONTROL_ID,
                "Pantalla Z",
                selection.screen_position_z_meters,
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
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
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
                seed_camera_x,
                "m",
            ),
            scalar_control(
                CAMERA_POSITION_Y_CONTROL_ID,
                "Cámara Y",
                selection.camera_position_y_meters,
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
                0.0,
                "m",
            ),
            scalar_control(
                CAMERA_POSITION_Z_CONTROL_ID,
                "Cámara Z",
                selection.camera_position_z_meters,
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
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
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Y_CONTROL_ID,
                "Pantalla Y",
                selection.screen_position_y_meters,
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
                0.0,
                "m",
            ),
            scalar_control(
                SCREEN_POSITION_Z_CONTROL_ID,
                "Pantalla Z",
                selection.screen_position_z_meters,
                -MAX_WORLD_COORDINATE_METERS,
                MAX_WORLD_COORDINATE_METERS,
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
            LENS_EVALUATION_MODEL_CONTROL_ID,
            "Modelo óptico",
            vec![
                TestChoiceOption {
                    id: "thin-lens",
                    label: "Lente física · 32 rayos",
                },
                TestChoiceOption {
                    id: "vfx-2d-dof",
                    label: "VFX 2D · footprint continuo",
                },
            ],
            selection.lens_evaluation_model_id,
            lens_evaluation_model_id(capture.default_lens_evaluation_model),
        ),
        owned_choice_control(
            LENS_PRESET_CONTROL_ID,
            "Objetivo",
            lens_options,
            selection.lens_preset_id,
            capture.default_lens_preset_id,
        ),
        scalar_control(
            FOCAL_LENGTH_CONTROL_ID,
            "Distancia focal",
            selection.focal_length_millimeters,
            focal_length_bounds().0,
            focal_length_bounds().1,
            lens(profiles, selection.lens_preset_id)?.nominal_focal_length_millimeters,
            "mm",
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
        scalar_control(
            MOIRE_INTENSITY_CONTROL_ID,
            "Intensidad de moiré",
            selection.moire_intensity,
            0.0,
            4.0,
            1.0,
            "×",
        ),
        scalar_control(
            MOIRE_SATURATION_CONTROL_ID,
            "Saturación del moiré",
            selection.moire_saturation,
            0.0,
            4.0,
            1.0,
            "×",
        ),
        scalar_control(
            MOIRE_FILTER_CONTROL_ID,
            "Suavizado antialias",
            selection.moire_filter_strength,
            0.0,
            4.0,
            0.0,
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
    if selection.autofocus_enabled {
        lens_controls.push(scalar_control(
            AUTOFOCUS_TARGET_U_CONTROL_ID,
            "Punto de foco X",
            selection.autofocus_target_u,
            0.0,
            1.0,
            0.5,
            "UV",
        ));
        lens_controls.push(scalar_control(
            AUTOFOCUS_TARGET_V_CONTROL_ID,
            "Punto de foco Y",
            selection.autofocus_target_v,
            0.0,
            1.0,
            0.5,
            "UV",
        ));
    }
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
        default_preview_phase_id: RECORDING_CODEC_PHASE_ID,
        phases: vec![
            TestPhaseDescriptor {
                id: ORIGIN_PHASE_ID,
                label: "Origen",
                effect_summary: "Interpreta la fuente y establece el raster lineal ACEScg canónico.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::EncodedSourceRasterV1,
                output_artifact: PhysicalArtifactId::LinearAcesCgRasterV1,
                preview_result: TestPreviewResult::SourceAcesCg,
                controls: Vec::new(),
            },
            TestPhaseDescriptor {
                id: SOURCE_ADJUSTMENT_PHASE_ID,
                label: "Ajuste de fuente",
                effect_summary: "Ajusta únicamente el contenido que alimentará el Device antes de codificarlo.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::LinearAcesCgRasterV1,
                output_artifact: PhysicalArtifactId::SourceGradedAcesCgV1,
                preview_result: TestPreviewResult::SourceAdjustment,
                controls: vec![
                    scalar_control(
                        SOURCE_EXPOSURE_CONTROL_ID,
                        "Exposición",
                        selection.source_adjustment.exposure_ev,
                        -8.0,
                        8.0,
                        0.0,
                        "EV",
                    ),
                    scalar_control(
                        SOURCE_CONTRAST_CONTROL_ID,
                        "Contraste",
                        selection.source_adjustment.contrast,
                        0.25,
                        4.0,
                        1.0,
                        "×",
                    ),
                    scalar_control(
                        SOURCE_SATURATION_CONTROL_ID,
                        "Saturación",
                        selection.source_adjustment.saturation,
                        0.0,
                        4.0,
                        1.0,
                        "×",
                    ),
                    scalar_control(
                        SOURCE_TEMPERATURE_CONTROL_ID,
                        "Temperatura",
                        selection.source_adjustment.temperature_kelvin,
                        2000.0,
                        12_000.0,
                        6500.0,
                        "K",
                    ),
                    scalar_control(
                        SOURCE_TINT_CONTROL_ID,
                        "Tinte",
                        selection.source_adjustment.tint,
                        -1.0,
                        1.0,
                        0.0,
                        "G/M",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: FEEDER_SIGNAL_PHASE_ID,
                label: "Salida del feeder",
                effect_summary: "Codifica y coloca la señal que recibe el dispositivo.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::SourceGradedAcesCgV1,
                output_artifact: PhysicalArtifactId::PlacedFeederSignalV1,
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
                input_artifact: PhysicalArtifactId::PlacedFeederSignalV1,
                output_artifact: PhysicalArtifactId::PanelEmissionRadianceV1,
                preview_result: TestPreviewResult::DeviceInterpretation,
                controls: vec![
                    owned_choice_control(
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
                input_artifact: PhysicalArtifactId::PanelEmissionRadianceV1,
                output_artifact: PhysicalArtifactId::SubpixelRadianceV1,
                preview_result: TestPreviewResult::PanelStructure,
                controls: vec![scalar_control(
                    SUBPIXEL_GEOMETRY_CONTROL_ID,
                    "Contraste de estructura",
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
                input_artifact: PhysicalArtifactId::SubpixelRadianceV1,
                output_artifact: PhysicalArtifactId::UniformPanelRadianceV1,
                preview_result: TestPreviewResult::PanelUniformity,
                controls: vec![scalar_control(
                    PANEL_UNIFORMITY_CONTROL_ID,
                    "Uniformidad espacial",
                    selection.panel_uniformity_amount,
                    0.0,
                    4.0,
                    device.uniformity_character_strength,
                    "×",
                )],
            },
            TestPhaseDescriptor {
                id: PANEL_LIGHT_SPREAD_PHASE_ID,
                label: "Dispersión de luz del panel",
                effect_summary: "Difunde la emisión entre celdas y suaviza la estructura fina del panel.",
                header_control_id: Some(PANEL_LIGHT_SPREAD_CONTROL_ID),
                input_artifact: PhysicalArtifactId::UniformPanelRadianceV1,
                output_artifact: PhysicalArtifactId::SpreadPanelRadianceV1,
                preview_result: TestPreviewResult::PanelLightSpread,
                controls: vec![scalar_control(
                    PANEL_LIGHT_SPREAD_CONTROL_ID,
                    "Dispersión del panel",
                    selection.panel_light_spread_amount,
                    0.0,
                    4.0,
                    device.light_spread_character_strength,
                    "×",
                )],
            },
            TestPhaseDescriptor {
                id: PANEL_TEMPORAL_PHASE_ID,
                label: "Emisión temporal del panel",
                effect_summary: "Integra la emisión resuelta del panel durante el intervalo temporal de captura.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::SpreadPanelRadianceV1,
                output_artifact: PhysicalArtifactId::TemporallyIntegratedPanelRadianceV1,
                preview_result: TestPreviewResult::PanelTemporal,
                controls: vec![],
            },
            TestPhaseDescriptor {
                id: RELATIVE_GEOMETRY_PHASE_ID,
                label: "Geometría relativa",
                effect_summary: "Sitúa cámara y pantalla y determina perspectiva, encuadre e incidencia.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::TemporallyIntegratedPanelRadianceV1,
                output_artifact: PhysicalArtifactId::ResolvedObservationGeometryV1,
                preview_result: TestPreviewResult::RelativeGeometry,
                controls: geometry_controls,
            },
            TestPhaseDescriptor {
                id: COVER_ENVIRONMENT_PHASE_ID,
                label: "Cristal y entorno",
                effect_summary: "Añade transmisión, reflejos, contraste angular y carácter superficial.",
                header_control_id: Some(COVER_GLASS_AMOUNT_CONTROL_ID),
                input_artifact: PhysicalArtifactId::ResolvedObservationGeometryV1,
                output_artifact: PhysicalArtifactId::CoveredDirectionalRadianceV1,
                preview_result: TestPreviewResult::CoverEnvironment,
                controls: {
                    let mut controls = vec![
                        owned_choice_control(
                            COVER_GLASS_CONTROL_ID,
                            "Cristal",
                            cover_options,
                            selection.cover_glass_preset_id,
                            device.default_cover_glass_profile_id,
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
                        scalar_control(
                            COVER_THICKNESS_CONTROL_ID,
                            "Grosor",
                            selection.cover_thickness_millimeters,
                            0.01,
                            20.0,
                            selected_cover.profile.thickness_millimeters,
                            "mm",
                        ),
                        scalar_control(
                            COVER_REFRACTIVE_INDEX_CONTROL_ID,
                            "Índice de refracción",
                            selection.cover_refractive_index,
                            1.0,
                            2.5,
                            selected_cover.profile.refractive_index,
                            "n",
                        ),
                        scalar_control(
                            COVER_AR_EFFICIENCY_CONTROL_ID,
                            "Eficiencia antirreflejos",
                            selection.cover_ar_efficiency,
                            0.0,
                            1.0,
                            selected_cover.profile.anti_reflective_efficiency,
                            "×",
                        ),
                        scalar_control(
                            COVER_ABSORPTION_R_CONTROL_ID,
                            "Absorción R",
                            selection.cover_absorption_rgb[0],
                            0.0,
                            2.0,
                            selected_cover.profile.absorption_per_millimeter.r,
                            "/mm",
                        ),
                        scalar_control(
                            COVER_ABSORPTION_G_CONTROL_ID,
                            "Absorción G",
                            selection.cover_absorption_rgb[1],
                            0.0,
                            2.0,
                            selected_cover.profile.absorption_per_millimeter.g,
                            "/mm",
                        ),
                        scalar_control(
                            COVER_ABSORPTION_B_CONTROL_ID,
                            "Absorción B",
                            selection.cover_absorption_rgb[2],
                            0.0,
                            2.0,
                            selected_cover.profile.absorption_per_millimeter.b,
                            "/mm",
                        ),
                        scalar_control(
                            COVER_ROUGHNESS_CONTROL_ID,
                            "Rugosidad",
                            selection.cover_roughness,
                            0.0,
                            1.0,
                            selected_cover.profile.roughness,
                            "α",
                        ),
                        scalar_control(
                            COVER_HAZE_CONTROL_ID,
                            "Haze",
                            selection.cover_haze,
                            0.0,
                            1.0,
                            selected_cover.profile.haze,
                            "×",
                        ),
                        scalar_control(
                            COVER_AG_RMS_SLOPE_CONTROL_ID,
                            "Pendiente RMS microtextura",
                            selection.cover_ag_rms_slope,
                            0.0,
                            1.0,
                            selected_cover.profile.anti_glare_microtexture.rms_slope,
                            "Δh/Δx",
                        ),
                        scalar_control(
                            COVER_AG_CORRELATION_CONTROL_ID,
                            "Escala microtextura",
                            selection.cover_ag_correlation_micrometers,
                            0.1,
                            1_000.0,
                            selected_cover
                                .profile
                                .anti_glare_microtexture
                                .correlation_length_micrometers,
                            "µm",
                        ),
                        scalar_control(
                            COVER_AG_ANISOTROPY_CONTROL_ID,
                            "Anisotropía microtextura",
                            selection.cover_ag_anisotropy,
                            0.0,
                            1.0,
                            selected_cover.profile.anti_glare_microtexture.anisotropy,
                            "×",
                        ),
                        owned_choice_control(
                            ENVIRONMENT_CONTROL_ID,
                            "Entorno",
                            environment_options,
                            selection.environment_source_id,
                            "environment-none",
                        ),
                        action_control(ENVIRONMENT_BROWSE_CONTROL_ID, "Seleccionar HDRI / EXR…"),
                        scalar_control(
                            ENVIRONMENT_AMOUNT_CONTROL_ID,
                            "Carácter del entorno",
                            selection.environment_amount,
                            0.0,
                            1.5,
                            environment_reset_amount,
                            "×",
                        ),
                        scalar_control(
                            ENVIRONMENT_ROTATION_X_CONTROL_ID,
                            "Rotación X",
                            selection.environment_rotation_x_degrees,
                            -90.0,
                            90.0,
                            selected_environment
                                .map(|environment| environment.environment.rotation_x_degrees)
                                .unwrap_or(0.0),
                            "°",
                        ),
                        scalar_control(
                            ENVIRONMENT_ROTATION_Y_CONTROL_ID,
                            "Rotación Y",
                            selection.environment_rotation_y_degrees,
                            -180.0,
                            180.0,
                            selected_environment
                                .map(|environment| environment.environment.rotation_y_degrees)
                                .unwrap_or(0.0),
                            "°",
                        ),
                    ];
                    if selection.environment_source_id == IMAGE_ENVIRONMENT_SOURCE_ID {
                        controls.extend([
                            scalar_control(
                                ENVIRONMENT_ANCHOR_LONGITUDE_CONTROL_ID,
                                "Anclaje horizontal",
                                selection.environment_anchor_longitude_degrees,
                                -180.0,
                                180.0,
                                0.0,
                                "°",
                            ),
                            scalar_control(
                                ENVIRONMENT_ANCHOR_LATITUDE_CONTROL_ID,
                                "Anclaje vertical",
                                selection.environment_anchor_latitude_degrees,
                                -90.0,
                                90.0,
                                0.0,
                                "°",
                            ),
                            scalar_control(
                                ENVIRONMENT_MOBIUS_A_REAL_CONTROL_ID,
                                "Transformación esférica · escala real",
                                selection.environment_tangent_transform[0],
                                -ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                1.0,
                                "×",
                            ),
                            scalar_control(
                                ENVIRONMENT_MOBIUS_A_IMAG_CONTROL_ID,
                                "Transformación esférica · escala imaginaria",
                                selection.environment_tangent_transform[1],
                                -ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                0.0,
                                "×",
                            ),
                            scalar_control(
                                ENVIRONMENT_MOBIUS_C_REAL_CONTROL_ID,
                                "Transformación esférica · proyecto real",
                                selection.environment_tangent_transform[2],
                                -ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                0.0,
                                "×",
                            ),
                            scalar_control(
                                ENVIRONMENT_MOBIUS_C_IMAG_CONTROL_ID,
                                "Transformación esférica · proyecto imaginario",
                                selection.environment_tangent_transform[3],
                                -ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                ENVIRONMENT_TANGENT_COEFFICIENT_MAX,
                                0.0,
                                "×",
                            ),
                            choice_control(
                                ENVIRONMENT_PROJECTION_CONTROL_ID,
                                "Proyección",
                                vec![
                                    TestChoiceOption {
                                        id: "distant",
                                        label: "Distante",
                                    },
                                    TestChoiceOption {
                                        id: "finite-sphere",
                                        label: "Esfera finita",
                                    },
                                ],
                                selection.environment_projection_id,
                                "distant",
                            ),
                            scalar_control(
                                ENVIRONMENT_EXPOSURE_CONTROL_ID,
                                "Exposición",
                                selection.environment_exposure_ev,
                                -8.0,
                                8.0,
                                0.0,
                                "EV",
                            ),
                            scalar_control(
                                ENVIRONMENT_CONTRAST_CONTROL_ID,
                                "Contraste",
                                selection.environment_contrast,
                                0.25,
                                4.0,
                                1.0,
                                "×",
                            ),
                            scalar_control(
                                ENVIRONMENT_SATURATION_CONTROL_ID,
                                "Saturación",
                                selection.environment_saturation,
                                0.0,
                                4.0,
                                1.0,
                                "×",
                            ),
                            scalar_control(
                                ENVIRONMENT_TEMPERATURE_CONTROL_ID,
                                "Temperatura",
                                selection.environment_temperature_kelvin,
                                2000.0,
                                12_000.0,
                                6500.0,
                                "K",
                            ),
                            scalar_control(
                                ENVIRONMENT_TINT_CONTROL_ID,
                                "Tinte",
                                selection.environment_tint,
                                -1.0,
                                1.0,
                                0.0,
                                "G/M",
                            ),
                        ]);
                        if selection.environment_projection_id == "finite-sphere" {
                            controls.extend([
                                scalar_control(
                                    ENVIRONMENT_CENTER_X_CONTROL_ID,
                                    "Centro X del entorno",
                                    selection.environment_sphere_center_x_meters,
                                    -1_000.0,
                                    1_000.0,
                                    0.0,
                                    "m",
                                ),
                                scalar_control(
                                    ENVIRONMENT_CENTER_Y_CONTROL_ID,
                                    "Centro Y del entorno",
                                    selection.environment_sphere_center_y_meters,
                                    -1_000.0,
                                    1_000.0,
                                    0.0,
                                    "m",
                                ),
                                scalar_control(
                                    ENVIRONMENT_CENTER_Z_CONTROL_ID,
                                    "Centro Z del entorno",
                                    selection.environment_sphere_center_z_meters,
                                    -1_000.0,
                                    1_000.0,
                                    0.0,
                                    "m",
                                ),
                                scalar_control(
                                    ENVIRONMENT_RADIUS_CONTROL_ID,
                                    "Radio del entorno",
                                    selection.environment_sphere_radius_meters,
                                    0.001,
                                    1_000.0,
                                    5.0,
                                    "m",
                                ),
                            ]);
                        }
                    }
                    controls
                },
            },
            TestPhaseDescriptor {
                id: COVER_GLOW_PHASE_ID,
                label: "Resplandor de emisión del Device",
                effect_summary: "Añade un halo suave desde la emisión ya resuelta del panel, dentro y fuera del Device.",
                header_control_id: Some(COVER_GLOW_AMOUNT_CONTROL_ID),
                input_artifact: PhysicalArtifactId::CoveredDirectionalRadianceV1,
                output_artifact: PhysicalArtifactId::GlassScatteredRadianceV1,
                preview_result: TestPreviewResult::CoverGlow,
                controls: vec![
                    scalar_control(
                        COVER_GLOW_AMOUNT_CONTROL_ID,
                        "Intensidad del resplandor",
                        selection.cover_glow_amount,
                        0.0,
                        4.0,
                        selected_cover.profile.glow.character_strength,
                        "×",
                    ),
                    scalar_control(
                        COVER_GLOW_INTENSITY_CONTROL_ID,
                        "Ganancia del halo",
                        selection.cover_glow_intensity,
                        0.0,
                        1.0,
                        selected_cover.profile.glow.intensity,
                        "×",
                    ),
                    scalar_control(
                        COVER_GLOW_RADIUS_CONTROL_ID,
                        "Radio y suavidad",
                        selection.cover_glow_radius_millimeters,
                        0.01,
                        30.0,
                        selected_cover.profile.glow.radius_millimeters,
                        "mm",
                    ),
                    scalar_control(
                        COVER_GLOW_THRESHOLD_CONTROL_ID,
                        "Umbral de altas luces",
                        selection.cover_glow_threshold_relative_white,
                        0.0,
                        1.0,
                        selected_cover
                            .profile
                            .glow
                            .threshold_relative_to_panel_white,
                        "blanco relativo",
                    ),
                    scalar_control(
                        COVER_GLOW_EXTERIOR_INTENSITY_CONTROL_ID,
                        "Spill exterior",
                        selection.cover_glow_exterior_intensity,
                        0.0,
                        4.0,
                        1.0,
                        "×",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: LENS_PROJECTION_PHASE_ID,
                label: "Objetivo y proyección",
                effect_summary: "Aplica proyección, foco, distorsión, aberración cromática, viñeteo y PSF.",
                header_control_id: Some(LENS_AMOUNT_CONTROL_ID),
                input_artifact: PhysicalArtifactId::GlassScatteredRadianceV1,
                output_artifact: PhysicalArtifactId::ImagePlaneIlluminanceAcesCgV1,
                preview_result: TestPreviewResult::LensProjection,
                controls: lens_controls,
            },
            TestPhaseDescriptor {
                id: SHUTTER_EXPOSURE_PHASE_ID,
                label: "Exposición y obturador",
                effect_summary: "Integra diafragma, tiempo de exposición, ND y comportamiento temporal.",
                header_control_id: Some(SHUTTER_AMOUNT_CONTROL_ID),
                input_artifact: PhysicalArtifactId::ImagePlaneIlluminanceAcesCgV1,
                output_artifact: PhysicalArtifactId::IntegratedOpticalExposureV1,
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
                        selection.exposure_time_seconds * selection.frame_rate.as_f32() * 360.0,
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
                        360.0 * selection.frame_rate.as_f32()
                            / capture.default_shutter_angle_degrees,
                        "1/s",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: COMPUTATIONAL_CAPTURE_PHASE_ID,
                label: "Captura computacional",
                effect_summary: "Combina analíticamente una horquilla de exposiciones sin repetir la óptica.",
                header_control_id: Some(COMPUTATIONAL_CAPTURE_AMOUNT_CONTROL_ID),
                input_artifact: PhysicalArtifactId::IntegratedOpticalExposureV1,
                output_artifact: PhysicalArtifactId::ComputationalCaptureExposureV2,
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
                id: SENSOR_COLLECTION_PHASE_ID,
                label: "Colección del fotosito, CFA y ruido",
                effect_summary: "Selecciona el canal Bayer y convierte la exposición en carga con ruido físico.",
                header_control_id: Some(SENSOR_NOISE_AMOUNT_CONTROL_ID),
                input_artifact: PhysicalArtifactId::ComputationalCaptureExposureV2,
                output_artifact: PhysicalArtifactId::CollectedSensorChargeV1,
                preview_result: TestPreviewResult::SensorCollection,
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
                id: SENSOR_BLOOM_PHASE_ID,
                label: "Crosstalk y bloom del sensor",
                effect_summary: "Transfiere carga entre fotositos y desborda altas luces saturadas.",
                header_control_id: Some(SENSOR_BLOOM_AMOUNT_CONTROL_ID),
                input_artifact: PhysicalArtifactId::CollectedSensorChargeV1,
                output_artifact: PhysicalArtifactId::CoupledSensorChargeV1,
                preview_result: TestPreviewResult::SensorBloom,
                controls: vec![
                    scalar_control(
                        SENSOR_BLOOM_AMOUNT_CONTROL_ID,
                        "Carácter del bloom",
                        selection.sensor_bloom_amount,
                        0.0,
                        4.0,
                        capture.sensor_bloom.character_strength,
                        "×",
                    ),
                    scalar_control(
                        SENSOR_BLOOM_CROSSTALK_CONTROL_ID,
                        "Crosstalk entre fotositos",
                        selection.sensor_bloom_crosstalk_fraction,
                        0.0,
                        0.20,
                        capture.sensor_bloom.crosstalk_fraction,
                        "fracción",
                    ),
                    scalar_control(
                        SENSOR_BLOOM_OVERFLOW_CONTROL_ID,
                        "Transferencia de desborde",
                        selection.sensor_bloom_overflow_transfer_fraction,
                        0.0,
                        1.0,
                        capture.sensor_bloom.overflow_transfer_fraction,
                        "fracción",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: SENSOR_READOUT_RAW_PHASE_ID,
                label: "Lectura del sensor y RAW",
                effect_summary: "Aplica full-well, ruido de lectura, ganancia analógica y cuantización ADC.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::CoupledSensorChargeV1,
                output_artifact: PhysicalArtifactId::RawMosaicNoisyV1,
                preview_result: TestPreviewResult::SensorReadoutRaw,
                controls: Vec::new(),
            },
            TestPhaseDescriptor {
                id: DEVELOP_DEMOSAIC_PHASE_ID,
                label: "Revelado y demosaico",
                effect_summary: "Aplica balance, revelado y demosaico para obtener ACEScg de cámara.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::RawMosaicNoisyV1,
                output_artifact: PhysicalArtifactId::DevelopedCameraAcesCgV1,
                preview_result: TestPreviewResult::DevelopDemosaic,
                controls: Vec::new(),
            },
            TestPhaseDescriptor {
                id: CAMERA_RENDERING_INTENT_PHASE_ID,
                label: "Intención de render de cámara",
                effect_summary: "Aplica el acabado del fabricante a la imagen desarrollada lineal.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::DevelopedCameraAcesCgV1,
                output_artifact: PhysicalArtifactId::CameraRenderedAcesCgV1,
                preview_result: TestPreviewResult::CameraRenderingIntent,
                controls: vec![
                    scalar_control(
                        CAMERA_LOOK_EXPOSURE_CONTROL_ID,
                        "Exposición del look",
                        selection.camera_rendering_intent.exposure_ev,
                        -8.0,
                        8.0,
                        capture.rendering_intent.exposure_ev,
                        "EV",
                    ),
                    scalar_control(
                        CAMERA_LOOK_CONTRAST_CONTROL_ID,
                        "Contraste",
                        selection.camera_rendering_intent.contrast,
                        0.25,
                        4.0,
                        capture.rendering_intent.contrast,
                        "×",
                    ),
                    scalar_control(
                        CAMERA_LOOK_SATURATION_CONTROL_ID,
                        "Saturación",
                        selection.camera_rendering_intent.saturation,
                        0.0,
                        4.0,
                        capture.rendering_intent.saturation,
                        "×",
                    ),
                    scalar_control(
                        CAMERA_LOOK_TEMPERATURE_CONTROL_ID,
                        "Temperatura",
                        selection.camera_rendering_intent.temperature_kelvin,
                        2000.0,
                        12_000.0,
                        capture.rendering_intent.temperature_kelvin,
                        "K",
                    ),
                    scalar_control(
                        CAMERA_LOOK_TINT_CONTROL_ID,
                        "Tinte",
                        selection.camera_rendering_intent.tint,
                        -1.0,
                        1.0,
                        capture.rendering_intent.tint,
                        "G/M",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: DEVICE_VFX_TRANSPARENCY_PHASE_ID,
                label: "Transparencia VFX del Device",
                effect_summary: "Transporta el alpha como matte no cromático y compone la contribución completa del Device.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::CameraRenderedAcesCgV1,
                output_artifact: PhysicalArtifactId::DeviceVfxCompositeV1,
                preview_result: TestPreviewResult::DeviceVfxTransparency,
                controls: vec![choice_control(
                    DEVICE_VFX_ALPHA_MODE_CONTROL_ID,
                    "Uso del alpha",
                    DEVICE_VFX_ALPHA_MODES.to_vec(),
                    selection.device_vfx_alpha_mode_id,
                    "device-transparency",
                )],
            },
            TestPhaseDescriptor {
                id: DELIVERY_RASTER_PHASE_ID,
                label: "Raster de entrega",
                effect_summary: "Ajusta el resultado de cámara al raster final sin cambiar óptica, sensor ni look.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::DeviceVfxCompositeV1,
                output_artifact: PhysicalArtifactId::DeliveryAcesCgRasterV1,
                preview_result: TestPreviewResult::DeliveryRaster,
                controls: vec![
                    choice_control(
                        DELIVERY_PRESET_CONTROL_ID,
                        "Preset de entrega",
                        DELIVERY_PRESETS.to_vec(),
                        selection.delivery_preset_id,
                        "uhd",
                    ),
                    scalar_field_control(
                        DELIVERY_WIDTH_CONTROL_ID,
                        "Anchura de entrega",
                        selection.delivery_width as f32,
                        1.0,
                        16_384.0,
                        3_840.0,
                        "px",
                    ),
                    scalar_field_control(
                        DELIVERY_HEIGHT_CONTROL_ID,
                        "Altura de entrega",
                        selection.delivery_height as f32,
                        1.0,
                        16_384.0,
                        2_160.0,
                        "px",
                    ),
                    choice_control(
                        DELIVERY_PLACEMENT_CONTROL_ID,
                        "Colocación de entrega",
                        DELIVERY_PLACEMENTS.to_vec(),
                        selection.delivery_placement_id,
                        "fit",
                    ),
                    choice_control(
                        DELIVERY_BACKGROUND_CONTROL_ID,
                        "Fondo",
                        DELIVERY_BACKGROUNDS.to_vec(),
                        selection.delivery_background_id,
                        "black",
                    ),
                ],
            },
            TestPhaseDescriptor {
                id: RECORDING_OUTPUT_PHASE_ID,
                label: "Señal de grabación · diagnóstico",
                effect_summary: "Muestra la señal interna que recibirá el códec; la previsualización normal vuelve después al monitor.",
                header_control_id: None,
                input_artifact: PhysicalArtifactId::DeliveryAcesCgRasterV1,
                output_artifact: PhysicalArtifactId::RecordingOutputSignalV2,
                preview_result: TestPreviewResult::RecordingOutput,
                controls: Vec::new(),
            },
            TestPhaseDescriptor {
                id: RECORDING_CODEC_PHASE_ID,
                label: "Códec de grabación",
                effect_summary: "Codifica y decodifica la señal con el perfil seleccionado para mostrar su degradación acumulada.",
                header_control_id: Some(RECORDING_CHARACTER_CONTROL_ID),
                input_artifact: PhysicalArtifactId::RecordingOutputSignalV2,
                output_artifact: PhysicalArtifactId::DecodedRecordingSignalV1,
                preview_result: TestPreviewResult::RecordingCodec,
                controls: vec![
                    choice_control(
                        RECORDING_PROFILE_CONTROL_ID,
                        "Formato de grabación",
                        recording_profile_options,
                        selection.recording_profile_id,
                        capture.default_recording_profile_id,
                    ),
                    scalar_control(
                        RECORDING_CHARACTER_CONTROL_ID,
                        "Carácter del códec",
                        selection.recording_character,
                        0.0,
                        4.0,
                        1.0,
                        "×",
                    ),
                ],
            },
        ],
        preview_controls: vec![choice_control(
            PREVIEW_QUALITY_CONTROL_ID,
            "Calidad",
            PREVIEW_QUALITIES.to_vec(),
            selection.preview_quality_id,
            "setup",
        )],
        visible_preview_choice_ids: SETUP_PREVIEW_QUALITIES.iter().map(|item| item.id).collect(),
        quick_control_ids: vec![
            SUBPIXEL_GEOMETRY_CONTROL_ID,
            MOIRE_INTENSITY_CONTROL_ID,
            MOIRE_SATURATION_CONTROL_ID,
            MOIRE_FILTER_CONTROL_ID,
            COVER_GLOW_AMOUNT_CONTROL_ID,
            COVER_GLOW_EXTERIOR_INTENSITY_CONTROL_ID,
            WHITE_LUMINANCE_CONTROL_ID,
            F_STOP_CONTROL_ID,
            SHUTTER_ANGLE_CONTROL_ID,
            SHUTTER_RECIPROCAL_CONTROL_ID,
            AUTOFOCUS_CONTROL_ID,
        ],
        featured_phase_id: DELIVERY_RASTER_PHASE_ID,
    })
}

pub fn apply_test_choice<'a>(
    selection: TestAuthoringSelection<'a>,
    control_id: &str,
    option_id: &'a str,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    apply_test_choice_with_profiles(
        &BUILT_IN_TEST_AUTHORING_PROFILES,
        selection,
        control_id,
        option_id,
    )
}

pub fn apply_test_choice_with_profiles<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    selection: TestAuthoringSelection<'a>,
    control_id: &str,
    option_id: &'a str,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    let current = resolve_test_authoring_selection_with_profiles(profiles, selection)?;
    let mut next = unresolved_test_selection(current);
    match control_id {
        OUTPUT_SIGNAL_CONTROL_ID => next.output_signal_id = option_id,
        DEVICE_CONTROL_ID => {
            let device = preset(profiles, option_id)?;
            next.device_id = device.id;
            next.color_mode_id = device.default_color_mode_id;
            next.white_luminance_nits = device.reference_white_nits;
            next.panel_uniformity_amount = device.uniformity_character_strength;
            next.panel_light_spread_amount = device.light_spread_character_strength;
            next.cover_glass_preset_id = device.default_cover_glass_profile_id;
            materialize_cover_profile(profiles, &mut next, device.default_cover_glass_profile_id)?;
        }
        COLOR_MODE_CONTROL_ID => next.color_mode_id = option_id,
        PLACEMENT_CONTROL_ID => next.placement_id = option_id,
        PREVIEW_QUALITY_CONTROL_ID => next.preview_quality_id = option_id,
        CAPTURE_PRESET_CONTROL_ID => {
            let capture = capture(profiles, option_id)?;
            next.capture_preset_id = capture.id;
            next.capture_raster_mode_id = capture.default_raster_mode_id;
            next.lens_preset_id = capture.default_lens_preset_id;
            next.focal_length_millimeters =
                lens(profiles, capture.default_lens_preset_id)?.nominal_focal_length_millimeters;
            next.lens_evaluation_model_id =
                lens_evaluation_model_id(capture.default_lens_evaluation_model);
            next.f_stop = capture.f_stop;
            next.exposure_time_seconds =
                capture.default_shutter_angle_degrees / 360.0 / current.frame_rate.as_f32();
            next.computational_character_strength = 1.0;
            next.computational_exposure_count =
                f32::from(capture.computational_capture.exposure_count);
            next.computational_bracket_spacing_stops =
                capture.computational_capture.bracket_spacing_stops;
            next.sensor_bloom_amount = capture.sensor_bloom.character_strength;
            next.sensor_bloom_crosstalk_fraction = capture.sensor_bloom.crosstalk_fraction;
            next.sensor_bloom_overflow_transfer_fraction =
                capture.sensor_bloom.overflow_transfer_fraction;
            next.camera_rendering_intent = capture.rendering_intent;
            next.recording_profile_id = capture.default_recording_profile_id;
            next.recording_output_transform_id =
                recording_output_transform_for_profile(capture.default_recording_profile_id)?
                    .stable_id();
        }
        CAPTURE_RASTER_MODE_CONTROL_ID => next.capture_raster_mode_id = option_id,
        DELIVERY_PRESET_CONTROL_ID => materialize_delivery_preset(profiles, &mut next, option_id)?,
        DELIVERY_PLACEMENT_CONTROL_ID => {
            next.delivery_placement_id = option_id;
            next.delivery_preset_id = "custom";
        }
        DELIVERY_BACKGROUND_CONTROL_ID => {
            next.delivery_background_id = option_id;
            next.delivery_preset_id = "custom";
        }
        GEOMETRY_MODE_CONTROL_ID => apply_geometry_mode(&mut next, option_id)?,
        COVER_GLASS_CONTROL_ID => {
            let cover = profiles
                .cover(option_id)
                .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?;
            next.cover_glass_preset_id = cover.id;
            materialize_cover_profile(profiles, &mut next, cover.id)?;
        }
        ENVIRONMENT_CONTROL_ID => {
            if option_id == IMAGE_ENVIRONMENT_SOURCE_ID {
                next.environment_source_id = IMAGE_ENVIRONMENT_SOURCE_ID;
                next.environment_amount = 1.0;
                next.environment_rotation_x_degrees = 0.0;
                next.environment_rotation_y_degrees = 0.0;
                next.environment_anchor_longitude_degrees = 0.0;
                next.environment_anchor_latitude_degrees = 0.0;
                next.environment_tangent_transform = [1.0, 0.0, 0.0, 0.0];
                next.environment_exposure_ev = 0.0;
                next.environment_contrast = 1.0;
                next.environment_saturation = 1.0;
                next.environment_temperature_kelvin = 6500.0;
                next.environment_tint = 0.0;
                next.environment_projection_id = "distant";
                next.environment_sphere_center_x_meters = 0.0;
                next.environment_sphere_center_y_meters = 0.0;
                next.environment_sphere_center_z_meters = 0.0;
                next.environment_sphere_radius_meters = 5.0;
            } else {
                let environment = profiles
                    .environment(option_id)
                    .ok_or(TestAuthoringError::UnknownEnvironmentPreset)?;
                next.environment_source_id = environment.id;
                next.environment_amount = environment.environment.character_strength;
                next.environment_rotation_x_degrees = environment.environment.rotation_x_degrees;
                next.environment_rotation_y_degrees = environment.environment.rotation_y_degrees;
                next.environment_anchor_longitude_degrees = 0.0;
                next.environment_anchor_latitude_degrees = 0.0;
                next.environment_tangent_transform = [1.0, 0.0, 0.0, 0.0];
                next.environment_exposure_ev = 0.0;
                next.environment_contrast = 1.0;
                next.environment_saturation = 1.0;
                next.environment_temperature_kelvin = 6500.0;
                next.environment_tint = 0.0;
                next.environment_projection_id = "distant";
                next.environment_sphere_center_x_meters = 0.0;
                next.environment_sphere_center_y_meters = 0.0;
                next.environment_sphere_center_z_meters = 0.0;
                next.environment_sphere_radius_meters = 5.0;
            }
        }
        LENS_PRESET_CONTROL_ID => {
            next.lens_preset_id = option_id;
            next.focal_length_millimeters =
                lens(profiles, option_id)?.nominal_focal_length_millimeters;
        }
        LENS_EVALUATION_MODEL_CONTROL_ID => match option_id {
            "thin-lens" | "vfx-2d-dof" => next.lens_evaluation_model_id = option_id,
            _ => return Err(TestAuthoringError::UnknownControl),
        },
        DEVICE_VFX_ALPHA_MODE_CONTROL_ID => {
            next.device_vfx_alpha_mode_id = selected_option(
                &DEVICE_VFX_ALPHA_MODES,
                option_id,
                TestAuthoringError::UnknownControl,
            )?;
        }
        RECORDING_PROFILE_CONTROL_ID => {
            next.recording_profile_id = option_id;
            next.recording_output_transform_id =
                recording_output_transform_for_profile(option_id)?.stable_id();
        }
        ENVIRONMENT_PROJECTION_CONTROL_ID => match option_id {
            "distant" | "finite-sphere" => next.environment_projection_id = option_id,
            _ => return Err(TestAuthoringError::UnknownControl),
        },
        WHITE_LUMINANCE_CONTROL_ID
        | SUBPIXEL_GEOMETRY_CONTROL_ID
        | MOIRE_INTENSITY_CONTROL_ID
        | MOIRE_SATURATION_CONTROL_ID
        | MOIRE_FILTER_CONTROL_ID
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
        | ENVIRONMENT_ROTATION_X_CONTROL_ID
        | ENVIRONMENT_ROTATION_Y_CONTROL_ID
        | ENVIRONMENT_ANCHOR_LONGITUDE_CONTROL_ID
        | ENVIRONMENT_ANCHOR_LATITUDE_CONTROL_ID
        | ENVIRONMENT_MOBIUS_A_REAL_CONTROL_ID
        | ENVIRONMENT_MOBIUS_A_IMAG_CONTROL_ID
        | ENVIRONMENT_MOBIUS_C_REAL_CONTROL_ID
        | ENVIRONMENT_MOBIUS_C_IMAG_CONTROL_ID
        | ENVIRONMENT_EXPOSURE_CONTROL_ID
        | SOURCE_EXPOSURE_CONTROL_ID
        | SOURCE_CONTRAST_CONTROL_ID
        | SOURCE_SATURATION_CONTROL_ID
        | SOURCE_TEMPERATURE_CONTROL_ID
        | SOURCE_TINT_CONTROL_ID
        | ENVIRONMENT_CONTRAST_CONTROL_ID
        | ENVIRONMENT_SATURATION_CONTROL_ID
        | ENVIRONMENT_TEMPERATURE_CONTROL_ID
        | ENVIRONMENT_TINT_CONTROL_ID
        | ENVIRONMENT_CENTER_X_CONTROL_ID
        | ENVIRONMENT_CENTER_Y_CONTROL_ID
        | ENVIRONMENT_CENTER_Z_CONTROL_ID
        | ENVIRONMENT_RADIUS_CONTROL_ID
        | COVER_GLOW_AMOUNT_CONTROL_ID
        | LENS_AMOUNT_CONTROL_ID
        | FOCAL_LENGTH_CONTROL_ID
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
        | SENSOR_NOISE_AMOUNT_CONTROL_ID
        | CAMERA_LOOK_EXPOSURE_CONTROL_ID
        | CAMERA_LOOK_CONTRAST_CONTROL_ID
        | CAMERA_LOOK_SATURATION_CONTROL_ID
        | CAMERA_LOOK_TEMPERATURE_CONTROL_ID
        | CAMERA_LOOK_TINT_CONTROL_ID
        | DELIVERY_WIDTH_CONTROL_ID
        | DELIVERY_HEIGHT_CONTROL_ID
        | RECORDING_CHARACTER_CONTROL_ID => return Err(TestAuthoringError::WrongControlType),
        _ => return Err(TestAuthoringError::UnknownControl),
    }
    if control_id != PREVIEW_QUALITY_CONTROL_ID {
        next.preview_quality_id = "setup";
    }
    resolve_test_authoring_selection_with_profiles(profiles, next)
}

fn materialize_cover_profile<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    selection: &mut TestAuthoringSelection<'a>,
    preset_id: &str,
) -> Result<(), TestAuthoringError> {
    let cover = profiles
        .cover(preset_id)
        .ok_or(TestAuthoringError::UnknownCoverGlassPreset)?;
    selection.cover_glass_preset_id = cover.id;
    selection.cover_glass_amount = cover.character_strength;
    selection.cover_ag_microtexture_amount = cover.anti_glare_character_strength;
    selection.cover_thickness_millimeters = cover.thickness_millimeters;
    selection.cover_refractive_index = cover.refractive_index;
    selection.cover_ar_efficiency = cover.anti_reflective_efficiency;
    selection.cover_absorption_rgb = cover.absorption_rgb;
    selection.cover_roughness = cover.roughness;
    selection.cover_haze = cover.haze;
    selection.cover_ag_rms_slope = cover.anti_glare_rms_slope;
    selection.cover_ag_correlation_micrometers = cover.anti_glare_correlation_micrometers;
    selection.cover_ag_anisotropy = cover.anti_glare_anisotropy;
    selection.cover_glow_amount = cover.glow_character_strength;
    selection.cover_glow_intensity = cover.glow_intensity;
    selection.cover_glow_radius_millimeters = cover.glow_radius_millimeters;
    selection.cover_glow_threshold_relative_white = cover.glow_threshold_relative_white;
    selection.cover_glow_exterior_intensity = 1.0;
    Ok(())
}

fn unresolved_test_selection<'a>(
    current: ResolvedTestAuthoringSelection<'a>,
) -> TestAuthoringSelection<'a> {
    TestAuthoringSelection {
        input_transform_id: current.input_transform_id,
        output_signal_id: current.output_signal_id,
        device_id: current.device_id,
        color_mode_id: current.color_mode_id,
        white_luminance_nits: current.white_luminance_nits,
        placement_id: current.placement_id,
        preview_quality_id: current.preview_quality_id,
        frame_rate: current.frame_rate,
        source_adjustment: current.source_adjustment,
        subpixel_geometry_amount: current.subpixel_geometry_amount,
        moire_intensity: current.moire_intensity,
        moire_saturation: current.moire_saturation,
        moire_filter_strength: current.moire_filter_strength,
        panel_uniformity_amount: current.panel_uniformity_amount,
        panel_light_spread_amount: current.panel_light_spread_amount,
        capture_preset_id: current.capture_preset_id,
        capture_raster_mode_id: current.capture_raster_mode_id,
        lens_evaluation_model_id: current.lens_evaluation_model_id,
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
        cover_thickness_millimeters: current.cover_thickness_millimeters,
        cover_refractive_index: current.cover_refractive_index,
        cover_ar_efficiency: current.cover_ar_efficiency,
        cover_absorption_rgb: current.cover_absorption_rgb,
        cover_roughness: current.cover_roughness,
        cover_haze: current.cover_haze,
        cover_ag_rms_slope: current.cover_ag_rms_slope,
        cover_ag_correlation_micrometers: current.cover_ag_correlation_micrometers,
        cover_ag_anisotropy: current.cover_ag_anisotropy,
        environment_source_id: current.environment_source_id,
        environment_amount: current.environment_amount,
        environment_rotation_x_degrees: current.environment_rotation_x_degrees,
        environment_rotation_y_degrees: current.environment_rotation_y_degrees,
        environment_anchor_longitude_degrees: current.environment_anchor_longitude_degrees,
        environment_anchor_latitude_degrees: current.environment_anchor_latitude_degrees,
        environment_tangent_transform: current.environment_tangent_transform,
        environment_exposure_ev: current.environment_exposure_ev,
        environment_contrast: current.environment_contrast,
        environment_saturation: current.environment_saturation,
        environment_temperature_kelvin: current.environment_temperature_kelvin,
        environment_tint: current.environment_tint,
        environment_projection_id: current.environment_projection_id,
        environment_sphere_center_x_meters: current.environment_sphere_center_x_meters,
        environment_sphere_center_y_meters: current.environment_sphere_center_y_meters,
        environment_sphere_center_z_meters: current.environment_sphere_center_z_meters,
        environment_sphere_radius_meters: current.environment_sphere_radius_meters,
        cover_glow_amount: current.cover_glow_amount,
        cover_glow_intensity: current.cover_glow_intensity,
        cover_glow_radius_millimeters: current.cover_glow_radius_millimeters,
        cover_glow_threshold_relative_white: current.cover_glow_threshold_relative_white,
        cover_glow_exterior_intensity: current.cover_glow_exterior_intensity,
        lens_preset_id: current.lens_preset_id,
        focal_length_millimeters: current.focal_length_millimeters,
        lens_amount: current.lens_amount,
        autofocus_enabled: current.autofocus_enabled,
        autofocus_target_u: current.autofocus_target_u,
        autofocus_target_v: current.autofocus_target_v,
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
        camera_rendering_intent: current.camera_rendering_intent,
        device_vfx_alpha_mode_id: current.device_vfx_alpha_mode_id,
        delivery_width: current.delivery_width as f32,
        delivery_height: current.delivery_height as f32,
        delivery_preset_id: current.delivery_preset_id,
        delivery_placement_id: current.delivery_placement_id,
        delivery_background_id: current.delivery_background_id,
        recording_output_transform_id: current.recording_output_transform_id,
        recording_profile_id: current.recording_profile_id,
        recording_character: current.recording_character,
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

pub fn apply_test_scalar<'a>(
    selection: TestAuthoringSelection<'a>,
    control_id: &str,
    value: f32,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    apply_test_scalar_with_profiles(
        &BUILT_IN_TEST_AUTHORING_PROFILES,
        selection,
        control_id,
        value,
    )
}

pub fn apply_test_scalar_with_profiles<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    selection: TestAuthoringSelection<'a>,
    control_id: &str,
    value: f32,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    let current = resolve_test_authoring_selection_with_profiles(profiles, selection)?;
    let mut next = unresolved_test_selection(current);
    match control_id {
        WHITE_LUMINANCE_CONTROL_ID => next.white_luminance_nits = value,
        SUBPIXEL_GEOMETRY_CONTROL_ID => next.subpixel_geometry_amount = value,
        MOIRE_INTENSITY_CONTROL_ID => next.moire_intensity = value,
        MOIRE_SATURATION_CONTROL_ID => next.moire_saturation = value,
        MOIRE_FILTER_CONTROL_ID => next.moire_filter_strength = value,
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
        COVER_THICKNESS_CONTROL_ID => next.cover_thickness_millimeters = value,
        COVER_REFRACTIVE_INDEX_CONTROL_ID => next.cover_refractive_index = value,
        COVER_AR_EFFICIENCY_CONTROL_ID => next.cover_ar_efficiency = value,
        COVER_ABSORPTION_R_CONTROL_ID => next.cover_absorption_rgb[0] = value,
        COVER_ABSORPTION_G_CONTROL_ID => next.cover_absorption_rgb[1] = value,
        COVER_ABSORPTION_B_CONTROL_ID => next.cover_absorption_rgb[2] = value,
        COVER_ROUGHNESS_CONTROL_ID => next.cover_roughness = value,
        COVER_HAZE_CONTROL_ID => next.cover_haze = value,
        COVER_AG_RMS_SLOPE_CONTROL_ID => next.cover_ag_rms_slope = value,
        COVER_AG_CORRELATION_CONTROL_ID => next.cover_ag_correlation_micrometers = value,
        COVER_AG_ANISOTROPY_CONTROL_ID => next.cover_ag_anisotropy = value,
        ENVIRONMENT_AMOUNT_CONTROL_ID => next.environment_amount = value,
        ENVIRONMENT_ROTATION_X_CONTROL_ID => next.environment_rotation_x_degrees = value,
        ENVIRONMENT_ROTATION_Y_CONTROL_ID => next.environment_rotation_y_degrees = value,
        ENVIRONMENT_ANCHOR_LONGITUDE_CONTROL_ID => {
            next.environment_anchor_longitude_degrees = value
        }
        ENVIRONMENT_ANCHOR_LATITUDE_CONTROL_ID => next.environment_anchor_latitude_degrees = value,
        ENVIRONMENT_MOBIUS_A_REAL_CONTROL_ID => next.environment_tangent_transform[0] = value,
        ENVIRONMENT_MOBIUS_A_IMAG_CONTROL_ID => next.environment_tangent_transform[1] = value,
        ENVIRONMENT_MOBIUS_C_REAL_CONTROL_ID => next.environment_tangent_transform[2] = value,
        ENVIRONMENT_MOBIUS_C_IMAG_CONTROL_ID => next.environment_tangent_transform[3] = value,
        ENVIRONMENT_EXPOSURE_CONTROL_ID => next.environment_exposure_ev = value,
        SOURCE_EXPOSURE_CONTROL_ID => next.source_adjustment.exposure_ev = value,
        SOURCE_CONTRAST_CONTROL_ID => next.source_adjustment.contrast = value,
        SOURCE_SATURATION_CONTROL_ID => next.source_adjustment.saturation = value,
        SOURCE_TEMPERATURE_CONTROL_ID => next.source_adjustment.temperature_kelvin = value,
        SOURCE_TINT_CONTROL_ID => next.source_adjustment.tint = value,
        ENVIRONMENT_CONTRAST_CONTROL_ID => next.environment_contrast = value,
        ENVIRONMENT_SATURATION_CONTROL_ID => next.environment_saturation = value,
        ENVIRONMENT_TEMPERATURE_CONTROL_ID => next.environment_temperature_kelvin = value,
        ENVIRONMENT_TINT_CONTROL_ID => next.environment_tint = value,
        ENVIRONMENT_CENTER_X_CONTROL_ID => next.environment_sphere_center_x_meters = value,
        ENVIRONMENT_CENTER_Y_CONTROL_ID => next.environment_sphere_center_y_meters = value,
        ENVIRONMENT_CENTER_Z_CONTROL_ID => next.environment_sphere_center_z_meters = value,
        ENVIRONMENT_RADIUS_CONTROL_ID => next.environment_sphere_radius_meters = value,
        COVER_GLOW_AMOUNT_CONTROL_ID => next.cover_glow_amount = value,
        COVER_GLOW_INTENSITY_CONTROL_ID => next.cover_glow_intensity = value,
        COVER_GLOW_RADIUS_CONTROL_ID => next.cover_glow_radius_millimeters = value,
        COVER_GLOW_THRESHOLD_CONTROL_ID => next.cover_glow_threshold_relative_white = value,
        COVER_GLOW_EXTERIOR_INTENSITY_CONTROL_ID => next.cover_glow_exterior_intensity = value,
        LENS_AMOUNT_CONTROL_ID => next.lens_amount = value,
        FOCAL_LENGTH_CONTROL_ID => next.focal_length_millimeters = value,
        F_STOP_CONTROL_ID => next.f_stop = value,
        SHUTTER_ANGLE_CONTROL_ID => {
            next.exposure_time_seconds = value / 360.0 / current.frame_rate.as_f32()
        }
        SHUTTER_RECIPROCAL_CONTROL_ID => next.exposure_time_seconds = 1.0 / value,
        FOCUS_DISTANCE_CONTROL_ID => next.focus_distance_meters = value,
        AUTOFOCUS_TARGET_U_CONTROL_ID => next.autofocus_target_u = value,
        AUTOFOCUS_TARGET_V_CONTROL_ID => next.autofocus_target_v = value,
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
        CAMERA_LOOK_EXPOSURE_CONTROL_ID => next.camera_rendering_intent.exposure_ev = value,
        CAMERA_LOOK_CONTRAST_CONTROL_ID => next.camera_rendering_intent.contrast = value,
        CAMERA_LOOK_SATURATION_CONTROL_ID => next.camera_rendering_intent.saturation = value,
        CAMERA_LOOK_TEMPERATURE_CONTROL_ID => {
            next.camera_rendering_intent.temperature_kelvin = value
        }
        CAMERA_LOOK_TINT_CONTROL_ID => next.camera_rendering_intent.tint = value,
        DELIVERY_WIDTH_CONTROL_ID => {
            next.delivery_width = value;
            next.delivery_preset_id = "custom";
        }
        DELIVERY_HEIGHT_CONTROL_ID => {
            next.delivery_height = value;
            next.delivery_preset_id = "custom";
        }
        RECORDING_CHARACTER_CONTROL_ID => next.recording_character = value,
        OUTPUT_SIGNAL_CONTROL_ID
        | DEVICE_CONTROL_ID
        | COLOR_MODE_CONTROL_ID
        | PLACEMENT_CONTROL_ID
        | PREVIEW_QUALITY_CONTROL_ID
        | CAPTURE_PRESET_CONTROL_ID
        | CAPTURE_RASTER_MODE_CONTROL_ID
        | DELIVERY_PRESET_CONTROL_ID
        | DELIVERY_PLACEMENT_CONTROL_ID
        | DELIVERY_BACKGROUND_CONTROL_ID
        | GEOMETRY_MODE_CONTROL_ID
        | COVER_GLASS_CONTROL_ID
        | ENVIRONMENT_CONTROL_ID
        | LENS_PRESET_CONTROL_ID
        | DEVICE_VFX_ALPHA_MODE_CONTROL_ID
        | RECORDING_OUTPUT_TRANSFORM_CONTROL_ID
        | RECORDING_PROFILE_CONTROL_ID
        | AUTOFOCUS_CONTROL_ID => return Err(TestAuthoringError::WrongControlType),
        _ => return Err(TestAuthoringError::UnknownControl),
    }
    next.preview_quality_id = "setup";
    resolve_test_authoring_selection_with_profiles(profiles, next)
}

pub fn apply_test_toggle<'a>(
    selection: TestAuthoringSelection<'a>,
    control_id: &str,
    value: bool,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    apply_test_toggle_with_profiles(
        &BUILT_IN_TEST_AUTHORING_PROFILES,
        selection,
        control_id,
        value,
    )
}

pub fn apply_test_toggle_with_profiles<'a>(
    profiles: &'a impl TestAuthoringProfileSource,
    selection: TestAuthoringSelection<'a>,
    control_id: &str,
    value: bool,
) -> Result<ResolvedTestAuthoringSelection<'a>, TestAuthoringError> {
    let current = resolve_test_authoring_selection_with_profiles(profiles, selection)?;
    let mut next = unresolved_test_selection(current);
    match control_id {
        AUTOFOCUS_CONTROL_ID => next.autofocus_enabled = value,
        _ => return Err(TestAuthoringError::WrongControlType),
    }
    next.preview_quality_id = "setup";
    resolve_test_authoring_selection_with_profiles(profiles, next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linear_acescg_source_resolves_through_the_test_authoring_boundary() {
        let selection = default_test_authoring_selection(
            "acescg",
            "lcd-asus-proart-pa329cv",
            FrameRate::new(24, 1).expect("valid frame rate"),
        )
        .expect("ACEScg is a valid explicit input transform");

        assert_eq!(selection.input_transform_id, "acescg");
    }

    fn asus() -> TestAuthoringSelection<'static> {
        TestAuthoringSelection {
            input_transform_id: "srgb-encoded-rec709",
            output_signal_id: "srgb",
            device_id: "lcd-asus-proart-pa329cv",
            color_mode_id: "srgb",
            white_luminance_nits: 350.0,
            placement_id: "fit",
            preview_quality_id: "setup",
            frame_rate: FrameRate::new(24, 1).expect("valid test frame rate"),
            source_adjustment: SceneLinearAdjustment::NEUTRAL,
            subpixel_geometry_amount: 1.0,
            moire_intensity: 1.0,
            moire_saturation: 1.0,
            moire_filter_strength: 0.0,
            panel_uniformity_amount: 1.0,
            panel_light_spread_amount: 1.0,
            capture_preset_id: "iphone-16e-main-48mp",
            capture_raster_mode_id: "half",
            lens_evaluation_model_id: "vfx-2d-dof",
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
            cover_thickness_millimeters: 0.8,
            cover_refractive_index: 1.5,
            cover_ar_efficiency: 0.62,
            cover_absorption_rgb: [0.012; 3],
            cover_roughness: 0.18,
            cover_haze: 0.03,
            cover_ag_rms_slope: 0.03,
            cover_ag_correlation_micrometers: 60.0,
            cover_ag_anisotropy: 0.12,
            environment_source_id: "environment-none",
            environment_amount: 0.0,
            environment_rotation_x_degrees: 0.0,
            environment_rotation_y_degrees: 0.0,
            environment_anchor_longitude_degrees: 0.0,
            environment_anchor_latitude_degrees: 0.0,
            environment_tangent_transform: [1.0, 0.0, 0.0, 0.0],
            environment_exposure_ev: 0.0,
            environment_contrast: 1.0,
            environment_saturation: 1.0,
            environment_temperature_kelvin: 6500.0,
            environment_tint: 0.0,
            environment_projection_id: "distant",
            environment_sphere_center_x_meters: 0.0,
            environment_sphere_center_y_meters: 0.0,
            environment_sphere_center_z_meters: 0.0,
            environment_sphere_radius_meters: 5.0,
            cover_glow_amount: 1.0,
            cover_glow_intensity: 0.10,
            cover_glow_radius_millimeters: 3.5,
            cover_glow_threshold_relative_white: 0.15,
            cover_glow_exterior_intensity: 1.0,
            lens_preset_id: "iphone-16e-main-integrated",
            focal_length_millimeters: 4.2,
            lens_amount: 1.0,
            autofocus_enabled: true,
            autofocus_target_u: 0.5,
            autofocus_target_v: 0.5,
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
            camera_rendering_intent: capture(
                &BUILT_IN_TEST_AUTHORING_PROFILES,
                "iphone-16e-main-48mp",
            )
            .unwrap()
            .rendering_intent,
            device_vfx_alpha_mode_id: "device-transparency",
            delivery_preset_id: "uhd",
            delivery_width: 3_840.0,
            delivery_height: 2_160.0,
            delivery_placement_id: "fit",
            delivery_background_id: "black",
            recording_output_transform_id: screen_color::IPHONE_HEIC_RECORDING_OUTPUT_TRANSFORM_ID,
            recording_profile_id: IPHONE_HEIC_PHOTO_PROFILE_ID,
            recording_character: 1.0,
        }
    }

    #[test]
    fn page_separates_feeder_from_device_interpretation() {
        let page = test_page_descriptor(asus()).unwrap();
        assert_eq!(page.schema_version, TEST_AUTHORING_SCHEMA_VERSION);
        assert_eq!(page.default_preview_phase_id, RECORDING_CODEC_PHASE_ID);
        assert_eq!(
            page.visible_preview_choice_ids,
            ["setup", "environment-setup", "focus-setup"]
        );
        assert_eq!(page.featured_phase_id, DELIVERY_RASTER_PHASE_ID);
        assert_eq!(
            page.quick_control_ids,
            [
                SUBPIXEL_GEOMETRY_CONTROL_ID,
                MOIRE_INTENSITY_CONTROL_ID,
                MOIRE_SATURATION_CONTROL_ID,
                MOIRE_FILTER_CONTROL_ID,
                COVER_GLOW_AMOUNT_CONTROL_ID,
                COVER_GLOW_EXTERIOR_INTENSITY_CONTROL_ID,
                WHITE_LUMINANCE_CONTROL_ID,
                F_STOP_CONTROL_ID,
                SHUTTER_ANGLE_CONTROL_ID,
                SHUTTER_RECIPROCAL_CONTROL_ID,
                AUTOFOCUS_CONTROL_ID,
            ]
        );
        assert_eq!(
            page.phases.iter().map(|phase| phase.id).collect::<Vec<_>>(),
            [
                ORIGIN_PHASE_ID,
                SOURCE_ADJUSTMENT_PHASE_ID,
                FEEDER_SIGNAL_PHASE_ID,
                DEVICE_INTERPRETATION_PHASE_ID,
                PANEL_STRUCTURE_PHASE_ID,
                PANEL_UNIFORMITY_PHASE_ID,
                PANEL_LIGHT_SPREAD_PHASE_ID,
                PANEL_TEMPORAL_PHASE_ID,
                RELATIVE_GEOMETRY_PHASE_ID,
                COVER_ENVIRONMENT_PHASE_ID,
                COVER_GLOW_PHASE_ID,
                LENS_PROJECTION_PHASE_ID,
                SHUTTER_EXPOSURE_PHASE_ID,
                COMPUTATIONAL_CAPTURE_PHASE_ID,
                SENSOR_COLLECTION_PHASE_ID,
                SENSOR_BLOOM_PHASE_ID,
                SENSOR_READOUT_RAW_PHASE_ID,
                DEVELOP_DEMOSAIC_PHASE_ID,
                CAMERA_RENDERING_INTENT_PHASE_ID,
                DEVICE_VFX_TRANSPARENCY_PHASE_ID,
                DELIVERY_RASTER_PHASE_ID,
                RECORDING_OUTPUT_PHASE_ID,
                RECORDING_CODEC_PHASE_ID,
            ]
        );
        assert!(matches!(
            &page.phases[2].controls[0],
            TestControlRequirement::Choice {
                id: OUTPUT_SIGNAL_CONTROL_ID,
                ..
            }
        ));
        for adjacent in page.phases.windows(2) {
            assert_eq!(adjacent[0].output_artifact, adjacent[1].input_artifact);
        }
        assert_eq!(
            page.phases
                .iter()
                .map(TestPhaseDescriptor::physical_intermediate)
                .collect::<Vec<_>>(),
            [
                None,
                None,
                Some(PhysicalIntermediate::DeviceSignal),
                Some(PhysicalIntermediate::PanelEmission),
                Some(PhysicalIntermediate::SubpixelRadiance),
                Some(PhysicalIntermediate::PanelUniformity),
                Some(PhysicalIntermediate::PanelLightSpread),
                Some(PhysicalIntermediate::PanelTemporal),
                Some(PhysicalIntermediate::RelativeGeometry),
                Some(PhysicalIntermediate::CoverEnvironment),
                Some(PhysicalIntermediate::CoverGlow),
                Some(PhysicalIntermediate::LensProjection),
                Some(PhysicalIntermediate::ShutterMotion),
                Some(PhysicalIntermediate::ComputationalCapture),
                Some(PhysicalIntermediate::SensorCollection),
                Some(PhysicalIntermediate::SensorBloom),
                Some(PhysicalIntermediate::SensorReadoutRaw),
                Some(PhysicalIntermediate::DevelopedAcesCg),
                Some(PhysicalIntermediate::CameraRenderedAcesCg),
                Some(PhysicalIntermediate::CameraRenderedAcesCg),
                Some(PhysicalIntermediate::CameraRenderedAcesCg),
                Some(PhysicalIntermediate::CameraRenderedAcesCg),
                Some(PhysicalIntermediate::CameraRenderedAcesCg),
            ]
        );
        assert!(matches!(
            &page.phases[8].controls[0],
            TestControlRequirement::Choice {
                id: CAPTURE_PRESET_CONTROL_ID,
                selected_id,
                ..
            } if selected_id == "iphone-16e-main-48mp"
        ));
        assert!(matches!(
            &page.phases[11].controls[0],
            TestControlRequirement::Choice {
                id: LENS_EVALUATION_MODEL_CONTROL_ID,
                selected_id,
                ..
            } if selected_id == "vfx-2d-dof"
        ));
        assert!(matches!(
            &page.phases[11].controls[1],
            TestControlRequirement::Choice {
                id: LENS_PRESET_CONTROL_ID,
                options,
                selected_id,
                ..
            } if options.len() == 1 && selected_id == "iphone-16e-main-integrated"
        ));
        assert!(page.phases[2].controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Choice {
                id: PLACEMENT_CONTROL_ID,
                ..
            }
        )));
        assert!(!page.phases[3].controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Choice {
                id: PLACEMENT_CONTROL_ID,
                ..
            }
        )));
        assert!(page.phases[3].controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Choice {
                id: COLOR_MODE_CONTROL_ID,
                ..
            }
        )));
        assert_eq!(
            page.phases[3].output_artifact,
            page.phases[4].input_artifact
        );
        assert!(matches!(
            &page.phases[4].controls[0],
            TestControlRequirement::Scalar {
                id: SUBPIXEL_GEOMETRY_CONTROL_ID,
                value: 1.0,
                minimum: 0.0,
                maximum: 4.0,
                ..
            }
        ));
        assert!(matches!(
            &page.phases[5].controls[0],
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
    fn delivery_presets_materialize_values_and_manual_edits_become_custom() {
        let selected = apply_test_choice(asus(), DELIVERY_PRESET_CONTROL_ID, "dci-4k").unwrap();
        assert_eq!(selected.delivery_preset_id, "dci-4k");
        assert_eq!(
            (selected.delivery_width, selected.delivery_height),
            (4096, 2160)
        );
        assert_eq!(selected.delivery_placement_id, "fit");

        let edited = apply_test_scalar(
            unresolved_test_selection(selected),
            DELIVERY_WIDTH_CONTROL_ID,
            4000.0,
        )
        .unwrap();
        assert_eq!(edited.delivery_preset_id, "custom");
        assert_eq!(
            (edited.delivery_width, edited.delivery_height),
            (4000, 2160)
        );

        let native =
            apply_test_choice(asus(), DELIVERY_PRESET_CONTROL_ID, "camera-native").unwrap();
        assert_eq!(native.delivery_preset_id, "camera-native");
        assert_eq!(
            (native.delivery_width, native.delivery_height),
            (5712, 4284)
        );
        assert_eq!(native.delivery_placement_id, "one-to-one");
    }

    #[test]
    fn recording_profiles_are_all_available_and_camera_defaults_are_explicit() {
        let iphone = test_page_descriptor(asus()).unwrap();
        let codec = iphone
            .phases
            .iter()
            .find(|phase| phase.id == RECORDING_CODEC_PHASE_ID)
            .unwrap();
        let TestControlRequirement::Choice {
            options, reset_id, ..
        } = &codec.controls[0]
        else {
            panic!("recording profile must be a choice");
        };
        assert_eq!(options.len(), bundled_profiles().len());
        assert_eq!(*reset_id, IPHONE_HEIC_PHOTO_PROFILE_ID);
        assert!(options.iter().any(|option| {
            option.id == GENERIC_PRORES_422_HQ_PROFILE_ID && option.label.starts_with("Disponible")
        }));

        let arri = apply_test_choice(asus(), CAPTURE_PRESET_CONTROL_ID, "arri-alexa-35-open-gate")
            .unwrap();
        assert_eq!(arri.recording_profile_id, GENERIC_PRORES_422_HQ_PROFILE_ID);
        assert_eq!(
            arri.recording_output_transform_id,
            screen_color::GENERIC_REC2100_PQ_RECORDING_OUTPUT_TRANSFORM_ID
        );
        let arri_page = test_page_descriptor(unresolved_test_selection(arri)).unwrap();
        let arri_codec = arri_page
            .phases
            .iter()
            .find(|phase| phase.id == RECORDING_CODEC_PHASE_ID)
            .unwrap();
        let TestControlRequirement::Choice { options, .. } = &arri_codec.controls[0] else {
            panic!("recording profile must be a choice");
        };
        assert!(options.iter().any(|option| {
            option.id == IPHONE_HEIC_PHOTO_PROFILE_ID && option.label.starts_with("Disponible")
        }));
        assert!(options.iter().any(|option| {
            option.id == GENERIC_PRORES_422_HQ_PROFILE_ID && option.label.starts_with("Habitual")
        }));
    }

    #[test]
    fn image_environment_is_explicit_and_owns_xy_rotation_and_exposure_controls() {
        let selected =
            apply_test_choice(asus(), ENVIRONMENT_CONTROL_ID, IMAGE_ENVIRONMENT_SOURCE_ID).unwrap();
        assert_eq!(selected.environment_source_id, IMAGE_ENVIRONMENT_SOURCE_ID);
        let selected = apply_test_scalar(
            unresolved_test_selection(selected),
            ENVIRONMENT_ROTATION_X_CONTROL_ID,
            -32.0,
        )
        .unwrap();
        let selected = apply_test_scalar(
            unresolved_test_selection(selected),
            ENVIRONMENT_ROTATION_Y_CONTROL_ID,
            78.0,
        )
        .unwrap();
        let selected = apply_test_scalar(
            unresolved_test_selection(selected),
            ENVIRONMENT_EXPOSURE_CONTROL_ID,
            -1.0,
        )
        .unwrap();
        let selected = apply_test_scalar(
            unresolved_test_selection(selected),
            ENVIRONMENT_MOBIUS_A_REAL_CONTROL_ID,
            0.5,
        )
        .unwrap();
        assert_eq!(selected.environment_rotation_x_degrees, -32.0);
        assert_eq!(selected.environment_rotation_y_degrees, 78.0);
        assert_eq!(selected.environment_exposure_ev, -1.0);
        assert_eq!(selected.environment_tangent_transform[0], 0.5);
        assert!(
            apply_test_scalar(
                unresolved_test_selection(selected),
                ENVIRONMENT_MOBIUS_A_REAL_CONTROL_ID,
                ENVIRONMENT_TANGENT_COEFFICIENT_MAX * 2.0,
            )
            .is_err()
        );

        let page = test_page_descriptor(unresolved_test_selection(selected)).unwrap();
        let controls = &page
            .phases
            .iter()
            .find(|phase| phase.id == COVER_ENVIRONMENT_PHASE_ID)
            .unwrap()
            .controls;
        for id in [
            ENVIRONMENT_ROTATION_X_CONTROL_ID,
            ENVIRONMENT_ROTATION_Y_CONTROL_ID,
            ENVIRONMENT_EXPOSURE_CONTROL_ID,
        ] {
            assert!(controls.iter().any(|control| matches!(
                control,
                TestControlRequirement::Scalar { id: control_id, .. } if *control_id == id
            )));
        }

        let finite = apply_test_choice(
            unresolved_test_selection(selected),
            ENVIRONMENT_PROJECTION_CONTROL_ID,
            "finite-sphere",
        )
        .unwrap();
        let finite = apply_test_scalar(
            unresolved_test_selection(finite),
            ENVIRONMENT_CENTER_X_CONTROL_ID,
            4.0,
        )
        .unwrap();
        let finite_page = test_page_descriptor(unresolved_test_selection(finite)).unwrap();
        let radius = finite_page
            .phases
            .iter()
            .find(|phase| phase.id == COVER_ENVIRONMENT_PHASE_ID)
            .unwrap()
            .controls
            .iter()
            .find_map(|control| match control {
                TestControlRequirement::Scalar { id, minimum, .. }
                    if *id == ENVIRONMENT_RADIUS_CONTROL_ID =>
                {
                    Some(*minimum)
                }
                _ => None,
            })
            .unwrap();
        assert_eq!(radius, 0.001);
        // Presentation exposes the authored positive domain only. The exact resolved
        // scene/timeline evaluator owns enclosure, so a static base camera cannot
        // invalidate a radius derived from animated camera samples.
        let mut small_but_authored = unresolved_test_selection(finite);
        small_but_authored.environment_sphere_radius_meters = 0.1;
        assert!(resolve_test_authoring_selection(small_but_authored).is_ok());
    }

    #[test]
    fn default_output_signal_matches_display_referred_input() {
        assert_eq!(
            default_test_authoring_selection(
                "srgb-encoded-rec709",
                "lcd-asus-proart-pa329cv",
                FrameRate::new(24, 1).unwrap()
            )
            .unwrap()
            .output_signal_id,
            "srgb"
        );
        assert_eq!(
            default_test_authoring_selection(
                "display-rec709-gamma24-dcm",
                "lcd-asus-proart-pa329cv",
                FrameRate::new(24, 1).unwrap()
            )
            .unwrap()
            .output_signal_id,
            "rec709-gamma24"
        );
        let camera_rec709 = default_test_authoring_selection(
            "input-rec709",
            "lcd-asus-proart-pa329cv",
            FrameRate::new(25, 1).unwrap(),
        )
        .unwrap();
        assert_eq!(camera_rec709.input_transform_id, "input-rec709");
        assert_eq!(camera_rec709.output_signal_id, "srgb");
        assert_eq!(
            default_test_authoring_selection(
                "camera-rec709",
                "lcd-asus-proart-pa329cv",
                FrameRate::new(25, 1).unwrap(),
            ),
            Err(TestAuthoringError::UnknownInputTransform)
        );
    }

    #[test]
    fn every_color_owned_input_transform_materializes_without_identity_substitution() {
        for input in OcioInputTransform::ALL {
            let selection = default_test_authoring_selection(
                input.stable_id(),
                "lcd-asus-proart-pa329cv",
                FrameRate::new(25, 1).unwrap(),
            )
            .unwrap_or_else(|error| panic!("{} failed: {error}", input.stable_id()));
            assert_eq!(selection.input_transform_id, input.stable_id());
        }
    }

    #[test]
    fn test_authoring_preserves_fractional_frame_rates_exactly() {
        for rate in [
            FrameRate::new(24_000, 1_001).unwrap(),
            FrameRate::new(30_000, 1_001).unwrap(),
        ] {
            let resolved = default_test_authoring_selection(
                "srgb-encoded-rec709",
                "lcd-asus-proart-pa329cv",
                rate,
            )
            .unwrap();
            assert_eq!(resolved.frame_rate, rate);
        }
    }

    #[test]
    fn free_geometry_accepts_a_tracking_world_with_a_large_absolute_origin() {
        let mut selection = unresolved_test_selection(
            default_test_authoring_selection(
                "srgb-encoded-rec709",
                "lcd-asus-proart-pa329cv",
                FrameRate::new(24, 1).unwrap(),
            )
            .unwrap(),
        );
        selection.geometry_mode_id = "free";
        selection.camera_position_x_meters = 12_001.0;
        selection.camera_position_y_meters = -7_500.0;
        selection.camera_position_z_meters = 320.0;
        selection.screen_position_x_meters = 12_000.0;
        selection.screen_position_y_meters = -7_500.0;
        selection.screen_position_z_meters = 319.85;
        let resolved = resolve_test_authoring_selection(selection);
        assert!(resolved.is_ok(), "{resolved:?}");

        selection.screen_position_x_meters = MAX_WORLD_COORDINATE_METERS + 1.0;
        assert_eq!(
            resolve_test_authoring_selection(selection),
            Err(TestAuthoringError::InvalidGeometry)
        );
    }

    #[test]
    fn imported_tracking_focal_overrides_the_nominal_lens_focal() {
        let mut selection = asus();
        selection.lens_preset_id = "iphone-16e-main-integrated";
        selection.focal_length_millimeters = 39.548_26;
        let resolved = resolve_test_authoring_selection(selection).unwrap();
        assert!((resolved.focal_length_millimeters - 39.548_26).abs() < 1.0e-5);
    }

    #[test]
    fn autofocus_remains_a_scene_intent_and_manual_focus_remains_authored() {
        let mut selection = asus();
        let authored_manual_distance = selection.focus_distance_meters;
        selection.camera_distance_meters = 0.5;
        let automatic = resolve_test_authoring_selection(selection).unwrap();
        assert!(automatic.autofocus_enabled);
        assert_eq!(automatic.focus_distance_meters, authored_manual_distance);

        selection.autofocus_enabled = false;
        selection.focus_distance_meters = 0.22;
        let manual = resolve_test_authoring_selection(selection).unwrap();
        assert!((manual.focus_distance_meters - 0.22).abs() < 1.0e-6);
    }

    #[test]
    fn autofocus_target_does_not_bake_a_distance_before_scene_resolution() {
        let mut selection = asus();
        selection.geometry_mode_id = "free";
        selection.camera_position_x_meters = 0.0;
        selection.camera_position_y_meters = 0.0;
        selection.camera_position_z_meters = 0.5;
        selection.camera_rotation_x_degrees = 0.0;
        selection.camera_rotation_y_degrees = 0.0;
        selection.camera_rotation_z_degrees = 0.0;
        selection.screen_yaw_degrees = 30.0;
        selection.autofocus_target_u = 0.0;
        let left = resolve_test_authoring_selection(selection).unwrap();
        selection.autofocus_target_u = 1.0;
        let right = resolve_test_authoring_selection(selection).unwrap();
        assert_eq!(left.focus_distance_meters, right.focus_distance_meters);
        assert_ne!(left.autofocus_target_u, right.autofocus_target_u);

        selection.autofocus_enabled = false;
        selection.focus_distance_meters = 0.31;
        selection.autofocus_target_u = 0.25;
        let manual = resolve_test_authoring_selection(selection).unwrap();
        assert!((manual.focus_distance_meters - 0.31).abs() < 1.0e-6);
    }

    #[test]
    fn lens_and_exposure_publish_real_aperture_time_and_autofocus_controls() {
        let page = test_page_descriptor(asus()).unwrap();
        let lens = &page.phases[11].controls;
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
        for id in [AUTOFOCUS_TARGET_U_CONTROL_ID, AUTOFOCUS_TARGET_V_CONTROL_ID] {
            assert!(lens.iter().any(|control| matches!(
                control,
                TestControlRequirement::Scalar {
                    id: control_id,
                    minimum: 0.0,
                    maximum: 1.0,
                    unit: "UV",
                    ..
                } if *control_id == id
            )));
        }
        assert!(matches!(
            lens.iter().find(|control| matches!(
                control,
                TestControlRequirement::Scalar {
                    id: FOCAL_LENGTH_CONTROL_ID,
                    minimum,
                    maximum,
                    unit: "mm",
                    ..
                } if (*minimum - 0.1).abs() < 1.0e-6
                    && (*maximum - 500.0).abs() < 1.0e-6
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
        let authored = apply_test_scalar(asus(), FOCAL_LENGTH_CONTROL_ID, 6.5).unwrap();
        assert!((authored.focal_length_millimeters - 6.5).abs() < 1.0e-6);
        assert!(page.phases[12].controls.iter().any(|control| matches!(
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
            angle_page.phases[12]
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
        let ids = page.phases[15]
            .controls
            .iter()
            .map(|control| match control {
                TestControlRequirement::Choice { id, .. }
                | TestControlRequirement::Scalar { id, .. }
                | TestControlRequirement::Toggle { id, .. }
                | TestControlRequirement::Action { id, .. } => *id,
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
            capture(&BUILT_IN_TEST_AUTHORING_PROFILES, "arri-alexa-35-open-gate")
                .unwrap()
                .sensor_bloom
                .crosstalk_fraction
        );
        assert_eq!(
            changed_camera.sensor_bloom_overflow_transfer_fraction,
            capture(&BUILT_IN_TEST_AUTHORING_PROFILES, "arri-alexa-35-open-gate")
                .unwrap()
                .sensor_bloom
                .overflow_transfer_fraction
        );
        assert_eq!(changed_camera.lens_evaluation_model_id, "vfx-2d-dof");
    }

    #[test]
    fn capture_raster_modes_are_explicit_and_camera_defaults_are_authoritative() {
        assert!(CAPTURE_DEVICE_PRESETS.iter().all(|preset| {
            preset.default_lens_evaluation_model == crate::LensEvaluationModel::VfxDepthBlur
        }));
        let iphone = CAPTURE_DEVICE_PRESETS
            .iter()
            .copied()
            .find(|preset| preset.id == "iphone-16e-main-48mp")
            .unwrap();
        assert_eq!(iphone.default_raster_mode_id, "half");
        let half = iphone.sensor_for_raster_mode("half").unwrap();
        assert_eq!((half.native_width, half.native_height), (5_712, 4_284));
        assert!(iphone.sensor_for_raster_mode("unknown").is_none());

        let arri = CAPTURE_DEVICE_PRESETS
            .iter()
            .copied()
            .find(|preset| preset.id == "arri-alexa-35-open-gate")
            .unwrap();
        assert_eq!(arri.default_raster_mode_id, "full");
        let full = arri.sensor_for_raster_mode("full").unwrap();
        assert_eq!((full.native_width, full.native_height), (4_608, 3_164));

        let quarter = apply_test_choice(asus(), CAPTURE_RASTER_MODE_CONTROL_ID, "quarter").unwrap();
        assert_eq!(quarter.capture_raster_mode_id, "quarter");
        let invalid = apply_test_choice(asus(), CAPTURE_RASTER_MODE_CONTROL_ID, "unknown");
        assert_eq!(invalid, Err(TestAuthoringError::InvalidCaptureRasterMode));
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
        let device = preset(&BUILT_IN_TEST_AUTHORING_PROFILES, selection.device_id).unwrap();
        let cover = BUILT_IN_TEST_AUTHORING_PROFILES
            .cover(device.default_cover_glass_profile_id)
            .unwrap();
        assert_eq!(
            selection.cover_ag_microtexture_amount,
            cover.profile.anti_glare_microtexture.character_strength
        );
    }

    #[test]
    fn cover_microtexture_is_model_authored_and_resets_with_the_cover_preset() {
        let page = test_page_descriptor(asus()).unwrap();
        assert!(matches!(
            page.phases[9].controls.iter().find(|control| matches!(
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
    fn cover_and_glow_publish_the_complete_model_authored_parameter_sets() {
        let page = test_page_descriptor(asus()).unwrap();
        let cover = page
            .phases
            .iter()
            .find(|phase| phase.id == COVER_ENVIRONMENT_PHASE_ID)
            .unwrap();
        let glow = page
            .phases
            .iter()
            .find(|phase| phase.id == COVER_GLOW_PHASE_ID)
            .unwrap();
        let control_id = |control: &TestControlRequirement| match control {
            TestControlRequirement::Scalar { id, .. }
            | TestControlRequirement::Choice { id, .. }
            | TestControlRequirement::Toggle { id, .. }
            | TestControlRequirement::Action { id, .. } => *id,
        };
        let cover_ids = cover.controls.iter().map(control_id).collect::<Vec<_>>();
        let glow_ids = glow.controls.iter().map(control_id).collect::<Vec<_>>();
        for expected in [
            COVER_THICKNESS_CONTROL_ID,
            COVER_REFRACTIVE_INDEX_CONTROL_ID,
            COVER_AR_EFFICIENCY_CONTROL_ID,
            COVER_ABSORPTION_R_CONTROL_ID,
            COVER_ABSORPTION_G_CONTROL_ID,
            COVER_ABSORPTION_B_CONTROL_ID,
            COVER_ROUGHNESS_CONTROL_ID,
            COVER_HAZE_CONTROL_ID,
            COVER_AG_RMS_SLOPE_CONTROL_ID,
            COVER_AG_CORRELATION_CONTROL_ID,
            COVER_AG_ANISOTROPY_CONTROL_ID,
        ] {
            assert!(
                cover_ids.contains(&expected),
                "missing Cover control {expected}"
            );
        }
        for expected in [
            COVER_GLOW_AMOUNT_CONTROL_ID,
            COVER_GLOW_INTENSITY_CONTROL_ID,
            COVER_GLOW_RADIUS_CONTROL_ID,
            COVER_GLOW_THRESHOLD_CONTROL_ID,
        ] {
            assert!(
                glow_ids.contains(&expected),
                "missing Cover Glow control {expected}"
            );
        }

        let edited = apply_test_scalar(asus(), COVER_GLOW_RADIUS_CONTROL_ID, 12.0).unwrap();
        let changed = apply_test_choice(
            unresolved_test_selection(edited),
            COVER_GLASS_CONTROL_ID,
            "cover-glossy-strong-ar",
        )
        .unwrap();
        assert_eq!(
            changed.cover_glow_radius_millimeters,
            cover_glass_preset("cover-glossy-strong-ar")
                .unwrap()
                .profile
                .glow
                .radius_millimeters
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
        assert_eq!(
            apply_test_scalar(asus(), MOIRE_FILTER_CONTROL_ID, 4.1),
            Err(TestAuthoringError::InvalidMoireFilterStrength)
        );
        assert_eq!(
            apply_test_scalar(asus(), MOIRE_INTENSITY_CONTROL_ID, 4.1),
            Err(TestAuthoringError::InvalidMoireIntensity)
        );
    }

    #[test]
    fn physical_artifact_identities_are_typed_stable_and_unique() {
        let artifacts = [
            PhysicalArtifactId::EncodedSourceRasterV1,
            PhysicalArtifactId::LinearAcesCgRasterV1,
            PhysicalArtifactId::SourceGradedAcesCgV1,
            PhysicalArtifactId::PlacedFeederSignalV1,
            PhysicalArtifactId::PanelEmissionRadianceV1,
            PhysicalArtifactId::SubpixelRadianceV1,
            PhysicalArtifactId::UniformPanelRadianceV1,
            PhysicalArtifactId::SpreadPanelRadianceV1,
            PhysicalArtifactId::TemporallyIntegratedPanelRadianceV1,
            PhysicalArtifactId::ResolvedObservationGeometryV1,
            PhysicalArtifactId::CoveredDirectionalRadianceV1,
            PhysicalArtifactId::GlassScatteredRadianceV1,
            PhysicalArtifactId::ImagePlaneIlluminanceAcesCgV1,
            PhysicalArtifactId::IntegratedOpticalExposureV1,
            PhysicalArtifactId::ComputationalCaptureExposureV2,
            PhysicalArtifactId::CollectedSensorChargeV1,
            PhysicalArtifactId::CoupledSensorChargeV1,
            PhysicalArtifactId::RawMosaicNoisyV1,
            PhysicalArtifactId::DevelopedCameraAcesCgV1,
            PhysicalArtifactId::CameraRenderedAcesCgV1,
            PhysicalArtifactId::DeviceVfxCompositeV1,
            PhysicalArtifactId::DeliveryAcesCgRasterV1,
            PhysicalArtifactId::RecordingOutputSignalV2,
            PhysicalArtifactId::DecodedRecordingSignalV1,
        ];
        let stable_ids = artifacts
            .iter()
            .map(|artifact| artifact.stable_id())
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(stable_ids.len(), artifacts.len());
        assert_eq!(
            PhysicalArtifactId::CollectedSensorChargeV1.stable_id(),
            "collected-sensor-charge-v1"
        );
        assert_eq!(
            PhysicalArtifactId::RecordingOutputSignalV2.stable_id(),
            "recording-output-signal-v2"
        );
    }

    #[test]
    fn geometry_mode_publishes_only_its_owned_controls() {
        let look_at = test_page_descriptor(asus()).unwrap();
        let controls = &look_at.phases[8].controls;
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
        let controls = &free.phases[8].controls;
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

    #[test]
    fn device_vfx_transparency_is_an_explicit_typed_choice() {
        let page = test_page_descriptor(asus()).unwrap();
        let phase = page
            .phases
            .iter()
            .find(|phase| phase.id == DEVICE_VFX_TRANSPARENCY_PHASE_ID)
            .expect("Device VFX Transparency phase");
        assert_eq!(
            phase.input_artifact,
            PhysicalArtifactId::CameraRenderedAcesCgV1
        );
        assert_eq!(
            phase.output_artifact,
            PhysicalArtifactId::DeviceVfxCompositeV1
        );
        assert!(phase.controls.iter().any(|control| matches!(
            control,
            TestControlRequirement::Choice {
                id: DEVICE_VFX_ALPHA_MODE_CONTROL_ID,
                selected_id,
                ..
            } if selected_id == "device-transparency"
        )));

        let ignored =
            apply_test_choice(asus(), DEVICE_VFX_ALPHA_MODE_CONTROL_ID, "ignore").unwrap();
        assert_eq!(ignored.device_vfx_alpha_mode_id, "ignore");
        assert_eq!(
            apply_test_choice(asus(), DEVICE_VFX_ALPHA_MODE_CONTROL_ID, "opaque"),
            Err(TestAuthoringError::UnknownControl)
        );
        assert_eq!(
            apply_test_scalar(asus(), DEVICE_VFX_ALPHA_MODE_CONTROL_ID, 1.0),
            Err(TestAuthoringError::WrongControlType)
        );
    }

    #[test]
    fn every_editable_control_has_one_application_owned_inspector_location() {
        let page = test_page_descriptor(asus()).unwrap();
        for phase in &page.phases {
            for control in &phase.controls {
                let location = test_inspector_location(phase.id, control.stable_id())
                    .unwrap_or_else(|| {
                        panic!("missing inspector location for {}", control.stable_id())
                    });
                assert!(!location.group_id.is_empty());
                assert!(!location.group_label.is_empty());
                assert!(!location.section_id.is_empty());
                assert!(!location.section_label.is_empty());
            }
        }
        assert_eq!(
            test_inspector_location(RELATIVE_GEOMETRY_PHASE_ID, SCREEN_POSITION_X_CONTROL_ID)
                .unwrap()
                .section_id,
            "device.geometry"
        );
        assert_eq!(
            test_inspector_location(RELATIVE_GEOMETRY_PHASE_ID, CAMERA_POSITION_X_CONTROL_ID)
                .unwrap()
                .section_id,
            "camera.geometry"
        );
        assert_eq!(
            test_inspector_location(COVER_ENVIRONMENT_PHASE_ID, COVER_ROUGHNESS_CONTROL_ID)
                .unwrap()
                .section_id,
            "device.glass"
        );
        assert_eq!(
            test_inspector_location(COVER_ENVIRONMENT_PHASE_ID, ENVIRONMENT_AMOUNT_CONTROL_ID)
                .unwrap()
                .section_id,
            "environment.main"
        );
    }
}
