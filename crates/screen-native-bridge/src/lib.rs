//! Coarse stable C ABI for the native shell's future Rust physical engine.

#![deny(unsafe_op_in_unsafe_fn)]
// C-callable safety obligations are owned by the normative bridge header; the
// Rust static library is not a separately consumable unsafe Rust API.
#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, c_float, c_void};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

#[cfg(target_os = "macos")]
use metal::foreign_types::{ForeignType, ForeignTypeRef};
#[cfg(target_os = "macos")]
use metal::{MTLTexture, Texture, TextureRef};
use screen_application::{
    CAPTURE_DEVICE_PRESETS, CameraRadiometricCalibration, DeliveryRasterBackground,
    DeliveryRasterPlacement, DeliveryRasterRequest, PHYSICAL_STAGE_DESCRIPTORS,
    PhysicalIntermediate, PhysicalPipelineExecutionPlan, PhysicalPipelineSnapshot,
    PhysicalStageControl, ProceduralTestPattern, RasterPlacement, ReflectionEmitter,
    ReflectionEnvironmentRig, ReflectionLightAppearance, ReflectionPracticalLight,
    ReflectionSunLight, ReflectionWindowLight, ResolvedSceneGeometryLensSnapshot,
    ResolvedShutterMotionSnapshot, RollingDirection, SensorReadout, TestAuthoringError,
    TestAuthoringSelection, TestControlRequirement,
    TestPageDescriptor as ApplicationTestPageDescriptor, apply_test_choice, apply_test_scalar,
    apply_test_toggle, compile_reflection_environment, default_test_authoring_selection,
    diagnostic_signal, evaluate_delivery_raster_rgba32f, physical_shutter_schedule,
    resolve_physical_stage_contributions, test_page_descriptor,
};
use screen_camera::{CameraDevelopment, CameraRenderingIntent};
use screen_color::{ColorEngine, RecordingOutputTransform, SceneLinearAdjustment};
use screen_contracts::{FrameRate, LinearRgb, Meters, RationalTime, Vec2, Vec3};
use screen_cover::{
    AcesCgRadiance, COVER_GLASS_PRESETS, CoverGlassPresetAuthority, CoverGlassProfile,
    ENVIRONMENT_PRESETS, EnvironmentPattern, EquirectangularEnvironment, IncidentEnvironment,
    ProceduralEnvironment,
};
use screen_geometry::{
    KeyframeInterpolation, LENS_PRESETS, LensModel, LensPresetAuthority, PlanarReferenceMatch,
    Quaternion, TransformKeyframe, TransformTrack, solve_planar_reference_camera,
};
use screen_panel::{
    AnalyticBanding, Chromaticity, DEVICE_PRESETS, FlatPanelQuality, LcdProfile, PanelColorimetry,
    PanelLightSpreadProfile, PanelTechnology, PanelTemporalEmission, PanelUniformityProfile,
    ResidualFlicker, StripeLayout,
};

pub const SCREEN_REFLECTION_ENVIRONMENT_ABI_VERSION: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenReflectionEmitterV2 {
    pub abi_version: u32,
    /// 0 circular practical, 1 convex window, 2 distant sun.
    pub kind: u32,
    /// Practical/sun use the first direction; window uses four ordered corners.
    pub directions_xyz: [f32; 12],
    pub angular_diameter_degrees: f32,
    pub distance_meters: f32,
    pub radiance_candelas_per_square_meter: f32,
    pub temperature_kelvin: f32,
    pub tint: f32,
    pub edge_softness_degrees: f32,
}
#[cfg(target_os = "macos")]
use screen_platform::{
    MetalPhysicalPipeline, MetalPhysicalPipelineError, MetalPhysicalPipelineResult,
    MetalSceneAdjustment,
};
use screen_sensor::{BayerPattern, ComputationalCaptureProfile, SensorBloomProfile, SensorProfile};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenUtf8View {
    bytes: *const u8,
    count: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPlanarReferenceMatchV1 {
    abi_version: u32,
    device_corners_xyz: [f32; 12],
    image_corners_xy: [f32; 8],
    image_width: u32,
    image_height: u32,
    focal_length_millimeters: f32,
    sensor_width_millimeters: f32,
    sensor_height_millimeters: f32,
    lens_shift_xy: [f32; 2],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenMatchedCameraPoseV1 {
    camera_position: [f32; 3],
    camera_rotation_xyzw: [f32; 4],
    maximum_reprojection_error_pixels: f32,
}

pub const SCREEN_PLANAR_REFERENCE_MATCH_ABI_VERSION: u32 = 1;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_geometry_solve_planar_reference_v1(
    request: *const ScreenPlanarReferenceMatchV1,
    result: *mut ScreenMatchedCameraPoseV1,
    error_message: *mut *const c_char,
) -> bool {
    if request.is_null() || result.is_null() {
        unsafe { set_error(error_message, b"invalid planar reference request\0") };
        return false;
    }
    let request = unsafe { *request };
    if request.abi_version != SCREEN_PLANAR_REFERENCE_MATCH_ABI_VERSION {
        unsafe { set_error(error_message, b"invalid planar reference ABI\0") };
        return false;
    }
    let device_corners = core::array::from_fn(|index| Vec3 {
        x: request.device_corners_xyz[index * 3],
        y: request.device_corners_xyz[index * 3 + 1],
        z: request.device_corners_xyz[index * 3 + 2],
    });
    let image_corners = core::array::from_fn(|index| Vec2 {
        x: request.image_corners_xy[index * 2],
        y: request.image_corners_xy[index * 2 + 1],
    });
    let matched = match solve_planar_reference_camera(PlanarReferenceMatch {
        device_corners,
        image_corners,
        image_width: request.image_width,
        image_height: request.image_height,
        focal_length: screen_contracts::Millimeters(request.focal_length_millimeters),
        sensor_width: screen_contracts::Millimeters(request.sensor_width_millimeters),
        sensor_height: screen_contracts::Millimeters(request.sensor_height_millimeters),
        lens_shift: Vec2 {
            x: request.lens_shift_xy[0],
            y: request.lens_shift_xy[1],
        },
    }) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"planar reference match failed\0") };
            return false;
        }
    };
    unsafe {
        *result = ScreenMatchedCameraPoseV1 {
            camera_position: [matched.position.x, matched.position.y, matched.position.z],
            camera_rotation_xyzw: [
                matched.rotation.x,
                matched.rotation.y,
                matched.rotation.z,
                matched.rotation.w,
            ],
            maximum_reprojection_error_pixels: matched.maximum_reprojection_error_pixels,
        };
        set_error(error_message, b"\0");
    }
    true
}

pub const SCREEN_TEST_AUTHORING_ABI_VERSION: u32 = 29;
pub const SCREEN_TEST_CONTROL_CHOICE: u32 = 0;
pub const SCREEN_TEST_CONTROL_SCALAR: u32 = 1;
pub const SCREEN_TEST_CONTROL_TOGGLE: u32 = 2;
pub const SCREEN_TEST_CONTROL_ACTION: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenTestAuthoringSelectionV22 {
    abi_version: u32,
    input_transform_id: ScreenUtf8View,
    output_signal_id: ScreenUtf8View,
    device_id: ScreenUtf8View,
    color_mode_id: ScreenUtf8View,
    device_eotf_gamma: f32,
    white_luminance_nits: f32,
    placement_id: ScreenUtf8View,
    preview_quality_id: ScreenUtf8View,
    frame_rate_numerator: u32,
    frame_rate_denominator: u32,
    source_exposure_ev: f32,
    source_contrast: f32,
    source_saturation: f32,
    source_temperature_kelvin: f32,
    source_tint: f32,
    subpixel_geometry_amount: f32,
    panel_uniformity_amount: f32,
    panel_light_spread_amount: f32,
    capture_preset_id: ScreenUtf8View,
    capture_raster_mode_id: ScreenUtf8View,
    lens_evaluation_model_id: ScreenUtf8View,
    geometry_mode_id: ScreenUtf8View,
    camera_distance_meters: f32,
    camera_orbit_x_degrees: f32,
    camera_orbit_y_degrees: f32,
    camera_position_x_meters: f32,
    camera_position_y_meters: f32,
    camera_position_z_meters: f32,
    camera_rotation_x_degrees: f32,
    camera_rotation_y_degrees: f32,
    camera_rotation_z_degrees: f32,
    screen_position_x_meters: f32,
    screen_position_y_meters: f32,
    screen_position_z_meters: f32,
    screen_rotation_x_degrees: f32,
    screen_yaw_degrees: f32,
    screen_rotation_z_degrees: f32,
    cover_glass_preset_id: ScreenUtf8View,
    cover_glass_amount: f32,
    cover_ag_microtexture_amount: f32,
    environment_source_id: ScreenUtf8View,
    environment_amount: f32,
    environment_rotation_x_degrees: f32,
    environment_rotation_y_degrees: f32,
    environment_exposure_ev: f32,
    environment_contrast: f32,
    environment_saturation: f32,
    environment_temperature_kelvin: f32,
    environment_tint: f32,
    environment_projection_id: ScreenUtf8View,
    environment_sphere_radius_meters: f32,
    cover_glow_amount: f32,
    lens_preset_id: ScreenUtf8View,
    focal_length_millimeters: f32,
    lens_amount: f32,
    autofocus_enabled: bool,
    focus_distance_meters: f32,
    f_stop: f32,
    exposure_time_seconds: f32,
    shutter_motion_amount: f32,
    computational_character_strength: f32,
    computational_exposure_count: f32,
    computational_bracket_spacing_stops: f32,
    sensor_bloom_amount: f32,
    sensor_bloom_crosstalk_fraction: f32,
    sensor_bloom_overflow_transfer_fraction: f32,
    sensor_noise_amount: f32,
    camera_look_exposure_ev: f32,
    camera_look_contrast: f32,
    camera_look_saturation: f32,
    camera_look_temperature_kelvin: f32,
    camera_look_tint: f32,
    delivery_preset_id: ScreenUtf8View,
    delivery_width: u32,
    delivery_height: u32,
    delivery_placement_id: ScreenUtf8View,
    delivery_background_id: ScreenUtf8View,
    recording_output_transform_id: ScreenUtf8View,
    recording_profile_id: ScreenUtf8View,
    recording_character: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenTestPhaseDescriptorV5 {
    abi_version: u32,
    id: ScreenUtf8View,
    label: ScreenUtf8View,
    effect_summary: ScreenUtf8View,
    header_control_id: ScreenUtf8View,
    input_artifact: ScreenUtf8View,
    output_artifact: ScreenUtf8View,
    preview_result: u32,
    has_physical_intermediate: bool,
    physical_intermediate: u32,
    calculation_domain: ScreenUtf8View,
    preview_route: ScreenUtf8View,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenTestControlDescriptorV5 {
    abi_version: u32,
    kind: u32,
    id: ScreenUtf8View,
    label: ScreenUtf8View,
    selected_id: ScreenUtf8View,
    reset_id: ScreenUtf8View,
    value: f32,
    reset_value: f32,
    minimum: f32,
    maximum: f32,
    step: f32,
    slider_visible: bool,
    unit: ScreenUtf8View,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenTestChoiceOptionV2 {
    abi_version: u32,
    id: ScreenUtf8View,
    label: ScreenUtf8View,
}

pub struct ScreenTestPageDescriptor {
    page: ApplicationTestPageDescriptor,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenCaptureRasterModeV1 {
    id: ScreenUtf8View,
    label: ScreenUtf8View,
    width: u32,
    height: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenCapturePresetParametersV4 {
    abi_version: u32,
    sensor: ScreenSensorNoiseParametersV2,
    computational_capture: ScreenComputationalCaptureParametersV3,
    camera_rendering_intent: ScreenCameraRenderingIntentParametersV1,
    gate_width_millimeters: f32,
    gate_height_millimeters: f32,
    default_f_stop: f32,
    reference_exposure_index: f32,
    middle_gray_illuminance_seconds: f32,
    default_shutter_angle_degrees: f32,
    default_temporal_samples: u16,
    lens_association_policy: u16,
    default_readout_duration_milliseconds: f32,
    radiometric_calibration: ScreenCameraRadiometricCalibrationV2,
    raster_modes: [ScreenCaptureRasterModeV1; 3],
    default_raster_mode_id: ScreenUtf8View,
    default_lens_evaluation_model: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenLensPresetParametersV1 {
    abi_version: u32,
    nominal_focal_length_millimeters: f32,
    radial_distortion: [f32; 3],
    tangential_distortion: [f32; 2],
    longitudinal_chromatic_meters: [f32; 3],
    lateral_chromatic_scale: [f32; 3],
    vignetting_strength: f32,
    transmission_rgb: [f32; 3],
    center_softness_micrometers: f32,
    edge_softness_micrometers: f32,
    veiling_glare_fraction: f32,
}

pub const SCREEN_PHYSICAL_FRAME_ABI_VERSION: u32 = 17;
pub const SCREEN_AUTHORING_CATALOG_ABI_VERSION: u32 = 7;
pub const SCREEN_PHYSICAL_PARAMETER_HASH_SIZE: usize = 32;
pub const SCREEN_PHYSICAL_RASTER_FIT: u32 = 0;
pub const SCREEN_PHYSICAL_RASTER_FILL_CROP: u32 = 1;
pub const SCREEN_PHYSICAL_RASTER_STRETCH: u32 = 2;
pub const SCREEN_PHYSICAL_RASTER_ONE_TO_ONE: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalTexture {
    metal_texture: usize,
}

#[cfg(target_os = "macos")]
pub struct ScreenEnvironmentRadianceTexture {
    _texture: Texture,
    view: ScreenPhysicalTexture,
}

#[cfg(target_os = "macos")]
pub struct ScreenAdjustedSceneTexture {
    _texture: Texture,
    view: ScreenPhysicalTexture,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalTimedInputSampleV2 {
    abi_version: u32,
    time_numerator: i64,
    time_denominator: u32,
    source_acescg: *const ScreenPhysicalTexture,
    device_signal: *const ScreenPhysicalTexture,
}

#[cfg(target_os = "macos")]
struct OwnedTimedInputSample {
    time: RationalTime,
    source_acescg: Texture,
    device_signal: Texture,
}

#[cfg(not(target_os = "macos"))]
struct OwnedTimedInputSample {
    time: RationalTime,
    source_acescg: usize,
    device_signal: usize,
}

pub struct ScreenPhysicalTimedInputSetV2 {
    samples: Vec<OwnedTimedInputSample>,
    raster_placement: u32,
    sampling_policy: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalPoseKnotV2 {
    abi_version: u32,
    time_numerator: i64,
    time_denominator: u32,
    position: [f32; 3],
    rotation_xyzw: [f32; 4],
    interpolation: u32,
}

pub struct ScreenPhysicalCameraPoseTrackV2 {
    track: TransformTrack,
}

pub struct ScreenPhysicalScreenPoseTrackV2 {
    track: TransformTrack,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalIdentity128 {
    high: u64,
    low: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalStageDescriptorV1 {
    abi_version: u32,
    domain_id: u32,
    stage_id: u32,
    control_semantics: u32,
    visual_minimum: f32,
    visual_maximum: f32,
    safe_maximum: f32,
    exact_identity_at_zero: bool,
    general_overview: bool,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalStageContributionV3 {
    abi_version: u32,
    stage_id: u32,
    amount: f32,
    discrete_enabled: bool,
}

#[repr(C)]
pub struct ScreenPhysicalFrameRequestV2 {
    abi_version: u32,
    frame_index: i64,
    timed_inputs: *const ScreenPhysicalTimedInputSetV2,
    environment_acescg: *const ScreenPhysicalTexture,
    camera_pose_track: *const ScreenPhysicalCameraPoseTrackV2,
    screen_pose_track: *const ScreenPhysicalScreenPoseTrackV2,
    shutter_open_numerator: i64,
    shutter_open_denominator: u32,
    shutter_close_numerator: i64,
    shutter_close_denominator: u32,
    resolved_device: *const ScreenDeviceProfile,
    resolved_pipeline: *const ScreenPhysicalPipelineSnapshot,
    quality: u32,
    screen_amount: f32,
    stage_contributions: *const ScreenPhysicalStageContributionV3,
    stage_contribution_count: usize,
    requested_width: u32,
    requested_height: u32,
    render_full_width: u32,
    render_full_height: u32,
    render_window_x: u32,
    render_window_y: u32,
    render_window_width: u32,
    render_window_height: u32,
    render_scale_x_numerator: u32,
    render_scale_x_denominator: u32,
    render_scale_y_numerator: u32,
    render_scale_y_denominator: u32,
    pixel_aspect_numerator: u32,
    pixel_aspect_denominator: u32,
    requested_intermediate: u32,
    cancellation_identity: ScreenPhysicalIdentity128,
    progress_identity: ScreenPhysicalIdentity128,
    parameter_revision: u64,
    parameter_hash: [u8; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalStageDiagnosticV2 {
    abi_version: u32,
    domain_id: u32,
    stage_id: u32,
    state: u32,
    progress: f32,
    elapsed_nanoseconds: u64,
    message: ScreenUtf8View,
}

#[repr(C)]
pub struct ScreenPhysicalFrameResultV2 {
    abi_version: u32,
    output_texture: *const ScreenPhysicalTexture,
    native_width: u32,
    native_height: u32,
    effective_width: u32,
    effective_height: u32,
    computed_quality: u32,
    returned_intermediate: u32,
    state: u32,
    progress: f32,
    stage_diagnostics: *const ScreenPhysicalStageDiagnosticV2,
    stage_diagnostic_count: usize,
    parameter_revision: u64,
    parameter_hash: [u8; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
}

const STATE_RENDERING: u32 = 2;
const STATE_CANCELLED: u32 = 3;
const STATE_FAILED: u32 = 4;
const STATE_COMPLETE: u32 = 5;
#[unsafe(no_mangle)]
pub extern "C" fn screen_physical_stage_descriptor_count() -> usize {
    PHYSICAL_STAGE_DESCRIPTORS.len()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_stage_descriptor(
    index: usize,
    destination: *mut ScreenPhysicalStageDescriptorV1,
) -> bool {
    let Some(source) = PHYSICAL_STAGE_DESCRIPTORS.get(index) else {
        return false;
    };
    let Some(destination) = (unsafe { destination.as_mut() }) else {
        return false;
    };
    *destination = ScreenPhysicalStageDescriptorV1 {
        abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
        domain_id: source.domain as u32,
        stage_id: source.stage as u32,
        control_semantics: source.control_semantics as u32,
        visual_minimum: source.visual_minimum,
        visual_maximum: source.visual_maximum,
        safe_maximum: source.safe_maximum,
        exact_identity_at_zero: source.exact_identity_at_zero,
        general_overview: source.general_overview,
    };
    true
}

#[cfg(target_os = "macos")]
enum PhysicalJobOutcome {
    Rendering,
    Complete {
        result: MetalPhysicalPipelineResult,
        elapsed_nanoseconds: u64,
    },
    Cancelled,
    Failed(String),
}

#[cfg(not(target_os = "macos"))]
enum PhysicalJobOutcome {
    Failed(String),
}

struct PhysicalJobShared {
    outcome: Mutex<PhysicalJobOutcome>,
    progress_bits: AtomicU32,
    cancelled: AtomicBool,
}

struct OwnedDiagnosticSnapshot {
    _messages: Vec<Box<[u8]>>,
    diagnostics: Box<[ScreenPhysicalStageDiagnosticV2]>,
}

pub struct ScreenPhysicalFrameJob {
    shared: Arc<PhysicalJobShared>,
    cancellation_identity: ScreenPhysicalIdentity128,
    quality: u32,
    requested_intermediate: u32,
    native_width: u32,
    native_height: u32,
    parameter_revision: u64,
    parameter_hash: [u8; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
    static_input: bool,
    sensor_enabled: bool,
    sensor_noise_amount: f32,
    development_enabled: bool,
    worker: Mutex<Option<JoinHandle<()>>>,
    // Boxes keep every C-borrowed pointer stable when the owning vectors grow.
    #[allow(clippy::vec_box)]
    output_views: Mutex<Vec<Box<ScreenPhysicalTexture>>>,
    #[allow(clippy::vec_box)]
    snapshots: Mutex<Vec<Box<OwnedDiagnosticSnapshot>>>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_texture_create_borrowed_metal(
    metal_texture: *const c_void,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalTexture {
    if metal_texture.is_null() {
        unsafe { set_error(error_message, b"missing borrowed Metal texture\0") };
        return std::ptr::null_mut();
    }
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenPhysicalTexture {
        metal_texture: metal_texture as usize,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_texture_borrow_metal(
    texture: *const ScreenPhysicalTexture,
) -> *const c_void {
    if texture.is_null() {
        return std::ptr::null();
    }
    // SAFETY: the non-null wrapper is borrowed for this call.
    unsafe { (*texture).metal_texture as *const c_void }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_texture_release(texture: *mut ScreenPhysicalTexture) {
    if !texture.is_null() {
        // SAFETY: the ABI requires the uniquely owned wrapper returned by create.
        unsafe { drop(Box::from_raw(texture)) };
    }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_scene_adjustment_texture_create_metal(
    source_metal_texture: *const c_void,
    exposure_ev: f32,
    contrast: f32,
    saturation: f32,
    temperature_kelvin: f32,
    tint: f32,
    incident_radiance: bool,
    error_message: *mut *const c_char,
) -> *mut ScreenAdjustedSceneTexture {
    if source_metal_texture.is_null() {
        unsafe { set_error(error_message, b"missing scene adjustment source texture\0") };
        return std::ptr::null_mut();
    }
    let source = unsafe { TextureRef::from_ptr(source_metal_texture as *mut MTLTexture) };
    let adjustment = SceneLinearAdjustment {
        exposure_ev,
        contrast,
        saturation,
        temperature_kelvin,
        tint,
    };
    let result = MetalSceneAdjustment::new(source.device())
        .and_then(|backend| backend.evaluate(source, adjustment, incident_radiance));
    match result {
        Ok(texture) => {
            let view = ScreenPhysicalTexture {
                metal_texture: texture.as_ptr() as usize,
            };
            unsafe { set_error(error_message, b"\0") };
            Box::into_raw(Box::new(ScreenAdjustedSceneTexture {
                _texture: texture,
                view,
            }))
        }
        Err(_) => {
            unsafe { set_error(error_message, b"scene adjustment failed\0") };
            std::ptr::null_mut()
        }
    }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_scene_adjustment_texture_borrow_physical(
    texture: *const ScreenAdjustedSceneTexture,
) -> *const ScreenPhysicalTexture {
    if texture.is_null() {
        return std::ptr::null();
    }
    unsafe { &(*texture).view }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_scene_adjustment_texture_borrow_metal(
    texture: *const ScreenAdjustedSceneTexture,
) -> *const c_void {
    if texture.is_null() {
        return std::ptr::null();
    }
    unsafe { (*texture).view.metal_texture as *const c_void }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_scene_adjustment_texture_release(
    texture: *mut ScreenAdjustedSceneTexture,
) {
    if !texture.is_null() {
        unsafe { drop(Box::from_raw(texture)) };
    }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_environment_radiance_texture_create_metal(
    source_metal_texture: *const c_void,
    error_message: *mut *const c_char,
) -> *mut ScreenEnvironmentRadianceTexture {
    if source_metal_texture.is_null() {
        unsafe { set_error(error_message, b"missing environment Metal texture\0") };
        return std::ptr::null_mut();
    }
    let source = unsafe { TextureRef::from_ptr(source_metal_texture as *mut MTLTexture) };
    let result = MetalPhysicalPipeline::new(source.device())
        .and_then(|backend| backend.prepare_equirectangular_environment(source));
    match result {
        Ok(texture) => {
            let view = ScreenPhysicalTexture {
                metal_texture: texture.as_ptr() as usize,
            };
            unsafe { set_error(error_message, b"\0") };
            Box::into_raw(Box::new(ScreenEnvironmentRadianceTexture {
                _texture: texture,
                view,
            }))
        }
        Err(_error) => {
            unsafe { set_error(error_message, b"environment radiance preparation failed\0") };
            std::ptr::null_mut()
        }
    }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_environment_radiance_texture_borrow_physical(
    texture: *const ScreenEnvironmentRadianceTexture,
) -> *const ScreenPhysicalTexture {
    if texture.is_null() {
        return std::ptr::null();
    }
    unsafe { &(*texture).view }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_environment_radiance_texture_release(
    texture: *mut ScreenEnvironmentRadianceTexture,
) {
    if !texture.is_null() {
        unsafe { drop(Box::from_raw(texture)) };
    }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_timed_input_set_v2_create(
    samples: *const ScreenPhysicalTimedInputSampleV2,
    sample_count: usize,
    raster_placement: u32,
    sampling_policy: u32,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalTimedInputSetV2 {
    if samples.is_null()
        || sample_count == 0
        || raster_placement > SCREEN_PHYSICAL_RASTER_ONE_TO_ONE
        || sampling_policy > 2
    {
        unsafe { set_error(error_message, b"invalid timed physical input set\0") };
        return std::ptr::null_mut();
    }
    let samples = unsafe { std::slice::from_raw_parts(samples, sample_count) };
    let mut owned = Vec::with_capacity(sample_count);
    let mut previous = None;
    for sample in samples {
        if sample.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION
            || sample.source_acescg.is_null()
            || sample.device_signal.is_null()
        {
            unsafe { set_error(error_message, b"invalid timed physical input sample\0") };
            return std::ptr::null_mut();
        }
        let Ok(time) = RationalTime::new(sample.time_numerator, sample.time_denominator) else {
            unsafe { set_error(error_message, b"invalid timed input rational time\0") };
            return std::ptr::null_mut();
        };
        if previous.is_some_and(|value| value >= time) {
            unsafe {
                set_error(
                    error_message,
                    b"timed input samples must be strictly ordered\0",
                )
            };
            return std::ptr::null_mut();
        }
        previous = Some(time);
        let source_pointer = unsafe { (*sample.source_acescg).metal_texture as *mut MTLTexture };
        let signal_pointer = unsafe { (*sample.device_signal).metal_texture as *mut MTLTexture };
        let source = unsafe { TextureRef::from_ptr(source_pointer) }.to_owned();
        let signal = unsafe { TextureRef::from_ptr(signal_pointer) }.to_owned();
        if source.width() != signal.width() || source.height() != signal.height() {
            unsafe { set_error(error_message, b"timed source/device rasters differ\0") };
            return std::ptr::null_mut();
        }
        owned.push(OwnedTimedInputSample {
            time,
            source_acescg: source,
            device_signal: signal,
        });
    }
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenPhysicalTimedInputSetV2 {
        samples: owned,
        raster_placement,
        sampling_policy,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_timed_input_set_v2_release(
    input: *mut ScreenPhysicalTimedInputSetV2,
) {
    if !input.is_null() {
        unsafe { drop(Box::from_raw(input)) };
    }
}

fn pose_track(knots: &[ScreenPhysicalPoseKnotV2], prefix: &str) -> Option<TransformTrack> {
    let keyframes = knots
        .iter()
        .enumerate()
        .map(|(index, knot)| {
            if knot.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION {
                return None;
            }
            let interpolation = match knot.interpolation {
                0 => KeyframeInterpolation::Hold,
                1 => KeyframeInterpolation::Linear,
                2 => KeyframeInterpolation::Smooth,
                _ => return None,
            };
            Some(TransformKeyframe {
                id: format!("{prefix}-{index}"),
                time: RationalTime::new(knot.time_numerator, knot.time_denominator).ok()?,
                translation: Vec3 {
                    x: knot.position[0],
                    y: knot.position[1],
                    z: knot.position[2],
                },
                rotation: Quaternion {
                    x: knot.rotation_xyzw[0],
                    y: knot.rotation_xyzw[1],
                    z: knot.rotation_xyzw[2],
                    w: knot.rotation_xyzw[3],
                },
                interpolation,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let track = TransformTrack { keyframes };
    track.validate().ok()?;
    Some(track)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_camera_pose_track_v2_create(
    knots: *const ScreenPhysicalPoseKnotV2,
    knot_count: usize,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalCameraPoseTrackV2 {
    if knots.is_null() || knot_count == 0 {
        unsafe { set_error(error_message, b"invalid camera pose track\0") };
        return std::ptr::null_mut();
    }
    let knots = unsafe { std::slice::from_raw_parts(knots, knot_count) };
    let Some(track) = pose_track(knots, "camera") else {
        unsafe { set_error(error_message, b"invalid camera pose knots\0") };
        return std::ptr::null_mut();
    };
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenPhysicalCameraPoseTrackV2 { track }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_screen_pose_track_v2_create(
    knots: *const ScreenPhysicalPoseKnotV2,
    knot_count: usize,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalScreenPoseTrackV2 {
    if knots.is_null() || knot_count == 0 {
        unsafe { set_error(error_message, b"invalid screen pose track\0") };
        return std::ptr::null_mut();
    }
    let knots = unsafe { std::slice::from_raw_parts(knots, knot_count) };
    let Some(track) = pose_track(knots, "screen") else {
        unsafe { set_error(error_message, b"invalid screen pose knots\0") };
        return std::ptr::null_mut();
    };
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenPhysicalScreenPoseTrackV2 { track }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_camera_pose_track_v2_release(
    track: *mut ScreenPhysicalCameraPoseTrackV2,
) {
    if !track.is_null() {
        unsafe { drop(Box::from_raw(track)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_screen_pose_track_v2_release(
    track: *mut ScreenPhysicalScreenPoseTrackV2,
) {
    if !track.is_null() {
        unsafe { drop(Box::from_raw(track)) };
    }
}

fn identity_matches(first: ScreenPhysicalIdentity128, second: ScreenPhysicalIdentity128) -> bool {
    first.high == second.high && first.low == second.low
}

fn quality(value: u32) -> Option<FlatPanelQuality> {
    FlatPanelQuality::try_from(value).ok()
}

fn placement(value: u32) -> Option<RasterPlacement> {
    RasterPlacement::try_from(value).ok()
}

fn intermediate(value: u32) -> Option<PhysicalIntermediate> {
    PhysicalIntermediate::try_from(value).ok()
}

fn contribution_amounts(
    contributions: &[ScreenPhysicalStageContributionV3],
) -> Option<screen_application::ResolvedPhysicalStageContributions> {
    if contributions.len() != PHYSICAL_STAGE_DESCRIPTORS.len() {
        return None;
    }
    let controls = contributions
        .iter()
        .zip(PHYSICAL_STAGE_DESCRIPTORS)
        .map(|(contribution, descriptor)| {
            if contribution.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION
                || contribution.stage_id != descriptor.stage as u32
            {
                return None;
            }
            Some(PhysicalStageControl {
                stage: descriptor.stage,
                amount: contribution.amount,
                enabled: contribution.discrete_enabled,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    resolve_physical_stage_contributions(&controls).ok()
}

fn diagnostic_snapshot(
    state: u32,
    progress: f32,
    stage_elapsed_nanoseconds: [u64; 16],
    stage_messages: [String; 16],
) -> Box<OwnedDiagnosticSnapshot> {
    let messages = Vec::from(stage_messages)
        .into_iter()
        .map(|message| message.into_bytes().into_boxed_slice())
        .collect::<Vec<_>>();
    let diagnostics = PHYSICAL_STAGE_DESCRIPTORS
        .iter()
        .enumerate()
        .map(|(index, descriptor)| ScreenPhysicalStageDiagnosticV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            domain_id: descriptor.domain as u32,
            stage_id: descriptor.stage as u32,
            state,
            progress,
            elapsed_nanoseconds: stage_elapsed_nanoseconds[index],
            message: ScreenUtf8View {
                bytes: messages[index].as_ptr(),
                count: messages[index].len(),
            },
        })
        .collect::<Vec<_>>()
        .into_boxed_slice();
    Box::new(OwnedDiagnosticSnapshot {
        _messages: messages,
        diagnostics,
    })
}

fn timed_sample_index(
    samples: &[OwnedTimedInputSample],
    requested: RationalTime,
    policy: u32,
) -> Option<usize> {
    let times = samples.iter().map(|sample| sample.time).collect::<Vec<_>>();
    sample_index_for_times(&times, requested, policy)
}

fn sample_index_for_times(
    times: &[RationalTime],
    requested: RationalTime,
    policy: u32,
) -> Option<usize> {
    if times.len() == 1 {
        return Some(0);
    }
    match times.binary_search(&requested) {
        Ok(index) => Some(index),
        Err(_) if policy == 0 => None,
        Err(index) if policy == 1 => index.checked_sub(1),
        Err(index) => match (index.checked_sub(1), (index < times.len()).then_some(index)) {
            (Some(left), Some(right)) => {
                let left_distance = requested.checked_sub(times[left]).ok()?.as_seconds().abs();
                let right_distance = times[right].checked_sub(requested).ok()?.as_seconds().abs();
                Some(if left_distance <= right_distance {
                    left
                } else {
                    right
                })
            }
            (Some(left), None) => Some(left),
            (None, Some(right)) => Some(right),
            (None, None) => None,
        },
    }
}

fn track_covers(track: &TransformTrack, open: RationalTime, close: RationalTime) -> bool {
    track.keyframes.len() == 1
        || track.keyframes.first().is_some_and(|key| key.time <= open)
            && track.keyframes.last().is_some_and(|key| key.time >= close)
}

fn track_is_constant(track: &TransformTrack) -> bool {
    let Some(first) = track.keyframes.first() else {
        return false;
    };
    track
        .keyframes
        .iter()
        .all(|key| key.translation == first.translation && key.rotation == first.rotation)
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct EffectiveCaptureCheckpoint {
    sensor_enabled: bool,
    sensor_noise_amount: f32,
    development_enabled: bool,
}

fn effective_capture_checkpoint(
    intermediate: PhysicalIntermediate,
    authored_sensor_enabled: bool,
    authored_sensor_noise_amount: f32,
    authored_development_enabled: bool,
) -> EffectiveCaptureCheckpoint {
    let sensor_enabled = authored_sensor_enabled
        && matches!(
            intermediate,
            PhysicalIntermediate::SensorCollection
                | PhysicalIntermediate::SensorBloom
                | PhysicalIntermediate::SensorReadoutRaw
                | PhysicalIntermediate::DevelopedAcesCg
        );
    let sensor_noise_amount = if sensor_enabled
        && matches!(
            intermediate,
            PhysicalIntermediate::SensorCollection
                | PhysicalIntermediate::SensorBloom
                | PhysicalIntermediate::SensorReadoutRaw
                | PhysicalIntermediate::DevelopedAcesCg
        ) {
        authored_sensor_noise_amount
    } else {
        0.0
    };
    let development_enabled = sensor_enabled
        && authored_development_enabled
        && intermediate == PhysicalIntermediate::DevelopedAcesCg;
    EffectiveCaptureCheckpoint {
        sensor_enabled,
        sensor_noise_amount,
        development_enabled,
    }
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_submit(
    request: *const ScreenPhysicalFrameRequestV2,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalFrameJob {
    if request.is_null() {
        unsafe { set_error(error_message, b"missing physical frame request\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null request is immutable for this call.
    let request = unsafe { &*request };
    let render_window_end_x = request
        .render_window_x
        .checked_add(request.render_window_width);
    let render_window_end_y = request
        .render_window_y
        .checked_add(request.render_window_height);
    if request.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION
        || request.frame_index < 0
        || request.timed_inputs.is_null()
        || request.camera_pose_track.is_null()
        || request.screen_pose_track.is_null()
        || request.shutter_open_denominator == 0
        || request.shutter_close_denominator == 0
        || request.resolved_device.is_null()
        || request.resolved_pipeline.is_null()
        || quality(request.quality).is_none()
        || request.requested_width == 0
        || request.requested_height == 0
        || request.render_full_width == 0
        || request.render_full_height == 0
        || request.render_window_width == 0
        || request.render_window_height == 0
        || request.render_scale_x_numerator == 0
        || request.render_scale_x_denominator == 0
        || request.render_scale_y_numerator == 0
        || request.render_scale_y_denominator == 0
        || request.pixel_aspect_numerator == 0
        || request.pixel_aspect_denominator == 0
        || render_window_end_x.is_none()
        || render_window_end_y.is_none()
        || render_window_end_x.is_some_and(|end| end > request.render_full_width)
        || render_window_end_y.is_some_and(|end| end > request.render_full_height)
        || !request.screen_amount.is_finite()
        || !(0.0..=4.0).contains(&request.screen_amount)
        || request.stage_contributions.is_null()
    {
        unsafe {
            set_error(
                error_message,
                b"invalid or unsupported physical frame request\0",
            )
        };
        return std::ptr::null_mut();
    }
    if request.render_full_width != request.requested_width
        || request.render_full_height != request.requested_height
        || request.render_window_x != 0
        || request.render_window_y != 0
        || request.render_window_width != request.render_full_width
        || request.render_window_height != request.render_full_height
        || request.render_scale_x_numerator != request.render_scale_x_denominator
        || request.render_scale_y_numerator != request.render_scale_y_denominator
        || request.pixel_aspect_numerator != request.pixel_aspect_denominator
    {
        unsafe {
            set_error(
                error_message,
                b"unsupported render window, scale, or pixel aspect\0",
            )
        };
        return std::ptr::null_mut();
    }
    // SAFETY: the request owns a complete immutable contribution array for this call.
    let contributions = unsafe {
        std::slice::from_raw_parts(
            request.stage_contributions,
            request.stage_contribution_count,
        )
    };
    let Some(amounts) = contribution_amounts(contributions) else {
        unsafe {
            set_error(
                error_message,
                b"invalid or active unsupported physical stages\0",
            )
        };
        return std::ptr::null_mut();
    };
    // SAFETY: validated opaque handles remain borrowed for the job lifetime by ABI contract.
    let input = unsafe { &*request.timed_inputs };
    let camera_track = unsafe { &*request.camera_pose_track };
    let screen_track = unsafe { &*request.screen_pose_track };
    let device = unsafe { &*request.resolved_device };
    let pipeline = unsafe { &*request.resolved_pipeline };
    let environment_texture = match (pipeline.environment, request.environment_acescg.is_null()) {
        (IncidentEnvironment::Procedural(_), true) => None,
        (IncidentEnvironment::Equirectangular(_), false) => {
            let pointer = unsafe { (*request.environment_acescg).metal_texture as *mut MTLTexture };
            Some(unsafe { TextureRef::from_ptr(pointer) }.to_owned())
        }
        _ => {
            unsafe {
                set_error(
                    error_message,
                    b"resolved environment source and frame texture do not match\0",
                )
            };
            return std::ptr::null_mut();
        }
    };
    let Some(placement) = placement(input.raster_placement) else {
        unsafe { set_error(error_message, b"invalid physical raster placement\0") };
        return std::ptr::null_mut();
    };
    let shutter_open = match RationalTime::new(
        request.shutter_open_numerator,
        request.shutter_open_denominator,
    ) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid shutter-open rational time\0") };
            return std::ptr::null_mut();
        }
    };
    let shutter_close = match RationalTime::new(
        request.shutter_close_numerator,
        request.shutter_close_denominator,
    ) {
        Ok(value) if value > shutter_open => value,
        _ => {
            unsafe { set_error(error_message, b"invalid shutter interval\0") };
            return std::ptr::null_mut();
        }
    };
    let exposure_duration = match shutter_close.checked_sub(shutter_open) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid shutter duration\0") };
            return std::ptr::null_mut();
        }
    };
    let frame_time = match shutter_open.checked_add(
        exposure_duration
            .checked_mul_ratio(1, 2)
            .expect("validated exposure can be halved"),
    ) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid shutter midpoint\0") };
            return std::ptr::null_mut();
        }
    };
    let Some(source_index) = timed_sample_index(&input.samples, frame_time, input.sampling_policy)
    else {
        unsafe {
            set_error(
                error_message,
                b"no source sample at required shutter time\0",
            )
        };
        return std::ptr::null_mut();
    };
    let Some(quality) = quality(request.quality) else {
        unsafe { set_error(error_message, b"invalid physical quality\0") };
        return std::ptr::null_mut();
    };
    let Some(requested_intermediate) = intermediate(request.requested_intermediate) else {
        unsafe { set_error(error_message, b"invalid physical intermediate selector\0") };
        return std::ptr::null_mut();
    };
    if !matches!(
        requested_intermediate,
        PhysicalIntermediate::SourceAcesCg
            | PhysicalIntermediate::DeviceSignal
            | PhysicalIntermediate::PanelEmission
            | PhysicalIntermediate::SubpixelRadiance
            | PhysicalIntermediate::PanelUniformity
            | PhysicalIntermediate::PanelLightSpread
            | PhysicalIntermediate::RelativeGeometry
            | PhysicalIntermediate::CoverEnvironment
            | PhysicalIntermediate::CoverGlow
            | PhysicalIntermediate::LensProjection
            | PhysicalIntermediate::ShutterMotion
            | PhysicalIntermediate::ComputationalCapture
            | PhysicalIntermediate::SensorCollection
            | PhysicalIntermediate::SensorBloom
            | PhysicalIntermediate::SensorReadoutRaw
            | PhysicalIntermediate::DevelopedAcesCg
            | PhysicalIntermediate::CameraRenderedAcesCg
    ) {
        unsafe {
            set_error(
                error_message,
                b"requested physical intermediate is unsupported\0",
            )
        };
        return std::ptr::null_mut();
    }
    if matches!(
        requested_intermediate,
        PhysicalIntermediate::SensorCollection
            | PhysicalIntermediate::SensorBloom
            | PhysicalIntermediate::SensorReadoutRaw
    ) && !amounts.sensor_readout_enabled
        || matches!(
            requested_intermediate,
            PhysicalIntermediate::DevelopedAcesCg | PhysicalIntermediate::CameraRenderedAcesCg
        ) && amounts.sensor_readout_enabled
            && !amounts.raw_develop_enabled
    {
        unsafe {
            set_error(
                error_message,
                b"requested sensor/develop intermediate is not enabled\0",
            )
        };
        return std::ptr::null_mut();
    }
    let native = match device
        .profile
        .flat_panel_sampling(FlatPanelQuality::Native, 1, 1)
    {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid physical device geometry\0") };
            return std::ptr::null_mut();
        }
    };
    let work_sampling = match device.profile.flat_panel_sampling(
        quality,
        request.requested_width,
        request.requested_height,
    ) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid requested physical sampling\0") };
            return std::ptr::null_mut();
        }
    };
    let _typed_snapshot = PhysicalPipelineSnapshot {
        panel: device.profile,
        panel_uniformity: device.uniformity,
        panel_light_spread: device.light_spread,
        cover: pipeline.cover,
        environment: pipeline.environment,
        scene_geometry_lens: pipeline.scene_geometry_lens,
        shutter_motion: pipeline.shutter_motion,
        computational_capture: pipeline.computational_capture,
        sensor: pipeline.sensor,
        development: pipeline.development,
        rendering_intent: pipeline.rendering_intent,
    };
    if device.uniformity.character_strength != amounts.panel_uniformity {
        unsafe {
            set_error(
                error_message,
                b"panel uniformity contribution does not match the resolved snapshot\0",
            )
        };
        return std::ptr::null_mut();
    }
    if device.light_spread.character_strength != amounts.panel_light_spread {
        unsafe {
            set_error(
                error_message,
                b"light spread contribution does not match the resolved snapshot\0",
            )
        };
        return std::ptr::null_mut();
    }
    if pipeline.cover.character_strength != amounts.cover
        || pipeline.cover.glow.character_strength != amounts.cover_glow
        || match pipeline.environment {
            IncidentEnvironment::Procedural(environment) => environment.character_strength,
            IncidentEnvironment::Equirectangular(environment) => environment.character_strength,
        } != amounts.environment
        || pipeline.sensor.bloom.character_strength != amounts.sensor_bloom
    {
        unsafe {
            set_error(
                error_message,
                b"cover/environment contributions do not match the resolved snapshot\0",
            )
        };
        return std::ptr::null_mut();
    }
    let half_exposure = match exposure_duration.checked_mul_ratio(1, 2) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid temporal exposure interval\0") };
            return std::ptr::null_mut();
        }
    };
    let temporal_gain = frame_time
        .checked_sub(half_exposure)
        .and_then(|start| {
            frame_time
                .checked_add(half_exposure)
                .map(|end| (start, end))
        })
        .map_err(screen_panel::PanelError::Time)
        .and_then(|(start, end)| device.profile.temporal_emission.average_gain(start, end));
    let Ok(temporal_gain) = temporal_gain else {
        unsafe { set_error(error_message, b"invalid panel temporal emission interval\0") };
        return std::ptr::null_mut();
    };
    let camera_pose = match camera_track.track.sample(frame_time) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"camera pose cannot be sampled\0") };
            return std::ptr::null_mut();
        }
    };
    let screen_pose = match screen_track.track.sample(frame_time) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"screen pose cannot be sampled\0") };
            return std::ptr::null_mut();
        }
    };
    let plan = PhysicalPipelineExecutionPlan {
        panel: device.profile,
        panel_uniformity: device.uniformity,
        panel_light_spread: device.light_spread,
        placement,
        quality,
        requested_width: request.requested_width,
        requested_height: request.requested_height,
        screen_amount: request.screen_amount,
        emission_amount: amounts.emission,
        subpixel_geometry_amount: amounts.subpixel_geometry,
        temporal_emission_amount: amounts.temporal_emission,
        temporal_emission_gain: temporal_gain,
        cover: pipeline.cover,
        environment: pipeline.environment,
        scene_geometry_lens: pipeline.scene_geometry_lens,
        camera_position: camera_pose.translation,
        camera_rotation: camera_pose.rotation,
        screen_translation: screen_pose.translation,
        screen_rotation: screen_pose.rotation,
        scene_geometry_amount: amounts.scene_geometry,
        lens_amount: amounts.lens,
        lens_evaluation_model: pipeline.lens_evaluation_model,
        frame_time,
        shutter_open,
        shutter_close,
        shutter_motion: pipeline.shutter_motion,
        shutter_motion_amount: amounts.shutter_motion,
        computational_capture: pipeline.computational_capture,
        computational_character_strength: amounts.computational_capture,
        sensor: pipeline.sensor,
        radiometric_calibration: pipeline.radiometric_calibration,
        sensor_enabled: amounts.sensor_readout_enabled,
        sensor_noise_amount: amounts.sensor_collection,
        development: pipeline.development,
        development_enabled: amounts.raw_develop_enabled,
        rendering_intent: pipeline.rendering_intent,
        rendering_intent_enabled: requested_intermediate
            == PhysicalIntermediate::CameraRenderedAcesCg,
        frame_index: request.frame_index,
        requested_intermediate,
    };
    let temporally_varying = input.samples.len() > 1
        || !track_is_constant(&camera_track.track)
        || !track_is_constant(&screen_track.track);
    let schedule = match physical_shutter_schedule(
        shutter_open,
        shutter_close,
        pipeline.shutter_motion.temporal_samples,
        pipeline.shutter_motion.readout,
        work_sampling.effective_height as usize,
    ) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid shutter integration schedule\0") };
            return std::ptr::null_mut();
        }
    };
    let required_open = schedule
        .iter()
        .map(|sample| sample.start)
        .min()
        .expect("validated schedule is non-empty");
    let required_close = schedule
        .iter()
        .map(|sample| sample.end)
        .max()
        .expect("validated schedule is non-empty");
    if !track_covers(&camera_track.track, required_open, required_close)
        || !track_covers(&screen_track.track, required_open, required_close)
    {
        unsafe {
            set_error(
                error_message,
                b"pose tracks do not cover the required shutter/readout range\0",
            )
        };
        return std::ptr::null_mut();
    }
    if input.samples.len() > 1
        && (input
            .samples
            .first()
            .is_none_or(|sample| sample.time > required_open)
            || input
                .samples
                .last()
                .is_none_or(|sample| sample.time < required_close))
    {
        unsafe {
            set_error(
                error_message,
                b"timed input range does not cover the required shutter/readout range\0",
            )
        };
        return std::ptr::null_mut();
    }
    let mut temporal_inputs = Vec::new();
    if temporally_varying {
        for sample in &schedule {
            let Some(index) =
                timed_sample_index(&input.samples, sample.time, input.sampling_policy)
            else {
                unsafe {
                    set_error(
                        error_message,
                        b"source sampling policy cannot resolve a required shutter time\0",
                    )
                };
                return std::ptr::null_mut();
            };
            let camera_pose = match camera_track.track.sample(sample.time) {
                Ok(value) => value,
                Err(_) => {
                    unsafe {
                        set_error(
                            error_message,
                            b"camera track cannot resolve shutter sample\0",
                        )
                    };
                    return std::ptr::null_mut();
                }
            };
            let screen_pose = match screen_track.track.sample(sample.time) {
                Ok(value) => value,
                Err(_) => {
                    unsafe {
                        set_error(
                            error_message,
                            b"screen track cannot resolve shutter sample\0",
                        )
                    };
                    return std::ptr::null_mut();
                }
            };
            let temporal_gain = match device
                .profile
                .temporal_emission
                .average_gain(sample.start, sample.end)
            {
                Ok(value) => value,
                Err(_) => {
                    unsafe {
                        set_error(
                            error_message,
                            b"panel temporal sample cannot be integrated\0",
                        )
                    };
                    return std::ptr::null_mut();
                }
            };
            let mut sample_plan = plan;
            sample_plan.frame_time = sample.time;
            sample_plan.camera_position = camera_pose.translation;
            sample_plan.camera_rotation = camera_pose.rotation;
            sample_plan.screen_translation = screen_pose.translation;
            sample_plan.screen_rotation = screen_pose.rotation;
            sample_plan.temporal_emission_gain = temporal_gain;
            temporal_inputs.push((
                input.samples[index].source_acescg.to_owned(),
                input.samples[index].device_signal.to_owned(),
                sample_plan,
                sample.weight_seconds as f32,
                sample.row.map(|row| row as u32),
            ));
        }
    } else {
        temporal_inputs.push((
            input.samples[source_index].source_acescg.to_owned(),
            input.samples[source_index].device_signal.to_owned(),
            plan,
            1.0,
            None,
        ));
    }
    let capture_checkpoint = effective_capture_checkpoint(
        requested_intermediate,
        amounts.sensor_readout_enabled,
        amounts.sensor_collection,
        amounts.raw_develop_enabled,
    );
    let shared = Arc::new(PhysicalJobShared {
        outcome: Mutex::new(PhysicalJobOutcome::Rendering),
        progress_bits: AtomicU32::new(0.0_f32.to_bits()),
        cancelled: AtomicBool::new(false),
    });
    let worker_shared = Arc::clone(&shared);
    let worker = std::thread::spawn(move || {
        let started = Instant::now();
        let device = temporal_inputs[0].0.device();
        let result = MetalPhysicalPipeline::new(device).and_then(|backend| {
            let borrowed = temporal_inputs
                .iter()
                .map(|(source, signal, plan, weight, row)| {
                    (&**source, &**signal, *plan, *weight, *row)
                })
                .collect::<Vec<_>>();
            backend.evaluate_temporal_with_environment(
                &borrowed,
                environment_texture.as_deref(),
                |progress| {
                    worker_shared
                        .progress_bits
                        .store(progress.to_bits(), Ordering::Release);
                },
                || worker_shared.cancelled.load(Ordering::Acquire),
            )
        });
        let outcome = match result {
            Ok(result) => PhysicalJobOutcome::Complete {
                result,
                elapsed_nanoseconds: started.elapsed().as_nanos().min(u128::from(u64::MAX)) as u64,
            },
            Err(MetalPhysicalPipelineError::Cancelled) => PhysicalJobOutcome::Cancelled,
            Err(error) => PhysicalJobOutcome::Failed(error.to_string()),
        };
        let mut current = worker_shared
            .outcome
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *current = outcome;
    });
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenPhysicalFrameJob {
        shared,
        cancellation_identity: request.cancellation_identity,
        quality: request.quality,
        requested_intermediate: request.requested_intermediate,
        native_width: if capture_checkpoint.sensor_enabled {
            u32::from(pipeline.sensor.native_width)
        } else {
            native.effective_width
        },
        native_height: if capture_checkpoint.sensor_enabled {
            u32::from(pipeline.sensor.native_height)
        } else {
            native.effective_height
        },
        parameter_revision: request.parameter_revision,
        parameter_hash: request.parameter_hash,
        static_input: !temporally_varying,
        sensor_enabled: capture_checkpoint.sensor_enabled,
        sensor_noise_amount: capture_checkpoint.sensor_noise_amount,
        development_enabled: capture_checkpoint.development_enabled,
        worker: Mutex::new(Some(worker)),
        output_views: Mutex::new(Vec::new()),
        snapshots: Mutex::new(Vec::new()),
    }))
}

#[cfg(not(target_os = "macos"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_submit(
    _request: *const ScreenPhysicalFrameRequestV2,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalFrameJob {
    unsafe {
        set_error(
            error_message,
            b"Metal physical pipeline backend requires macOS\0",
        )
    };
    std::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_job_cancel(
    job: *mut ScreenPhysicalFrameJob,
    cancellation_identity: ScreenPhysicalIdentity128,
) -> bool {
    if job.is_null() {
        return false;
    }
    // SAFETY: the non-null job remains owned by the caller for this call.
    let job = unsafe { &*job };
    if !identity_matches(job.cancellation_identity, cancellation_identity) {
        return false;
    }
    job.shared.cancelled.store(true, Ordering::Release);
    true
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_job_snapshot(
    job: *mut ScreenPhysicalFrameJob,
    result: *mut ScreenPhysicalFrameResultV2,
    error_message: *mut *const c_char,
) -> bool {
    if job.is_null() || result.is_null() {
        unsafe { set_error(error_message, b"invalid physical frame snapshot request\0") };
        return false;
    }
    // SAFETY: both non-null pointers remain valid for this call.
    let job = unsafe { &*job };
    let progress = f32::from_bits(job.shared.progress_bits.load(Ordering::Acquire));
    let outcome = job
        .shared
        .outcome
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (
        state,
        effective_width,
        effective_height,
        texture_pointer,
        _elapsed_nanoseconds,
        stage_elapsed_nanoseconds,
        emission,
        geometry,
        uniformity,
        spread,
        temporal,
        cover,
        environment,
        glass_glow,
        scene,
        lens,
        sensor_bloom,
    ) = match &*outcome {
        PhysicalJobOutcome::Rendering => (
            STATE_RENDERING,
            0,
            0,
            0,
            0,
            [0; 16],
            "physical pipeline emission rendering".to_owned(),
            "subpixel geometry rendering".to_owned(),
            "panel uniformity rendering".to_owned(),
            "panel light spread rendering".to_owned(),
            "panel temporal emission rendering".to_owned(),
            "cover glass rendering".to_owned(),
            "environment reflection rendering".to_owned(),
            "cover glow rendering".to_owned(),
            "scene geometry rendering".to_owned(),
            "generalized lens rendering".to_owned(),
            "sensor bloom rendering".to_owned(),
        ),
        PhysicalJobOutcome::Cancelled => (
            STATE_CANCELLED,
            0,
            0,
            0,
            0,
            [0; 16],
            "physical pipeline emission cancelled".to_owned(),
            "subpixel geometry cancelled".to_owned(),
            "panel uniformity cancelled".to_owned(),
            "panel light spread cancelled".to_owned(),
            "panel temporal emission cancelled".to_owned(),
            "cover glass cancelled".to_owned(),
            "environment reflection cancelled".to_owned(),
            "cover glow cancelled".to_owned(),
            "scene geometry cancelled".to_owned(),
            "generalized lens cancelled".to_owned(),
            "sensor bloom cancelled".to_owned(),
        ),
        PhysicalJobOutcome::Failed(message) => (
            STATE_FAILED,
            0,
            0,
            0,
            0,
            [0; 16],
            format!("physical pipeline backend failed: {message}"),
            format!("subpixel geometry failed: {message}"),
            format!("panel uniformity failed: {message}"),
            format!("panel light spread failed: {message}"),
            format!("panel temporal emission failed: {message}"),
            format!("cover glass failed: {message}"),
            format!("environment reflection failed: {message}"),
            format!("cover glow failed: {message}"),
            format!("scene geometry failed: {message}"),
            format!("generalized lens failed: {message}"),
            format!("sensor bloom failed: {message}"),
        ),
        PhysicalJobOutcome::Complete {
            result: value,
            elapsed_nanoseconds,
        } => {
            let resolved = if value.sampling.subpixel_geometry_resolved {
                "resolved"
            } else {
                "unresolved"
            };
            (
                STATE_COMPLETE,
                value.texture.width() as u32,
                value.texture.height() as u32,
                value.texture.as_ptr() as usize,
                *elapsed_nanoseconds,
                value.stage_elapsed_nanoseconds,
                format!(
                    "active {:.6} x {:.6} m; PPI {:.3}; pitch {:.3} x {:.3} um",
                    value.geometry.active_width_meters,
                    value.geometry.active_height_meters,
                    value.geometry.pixels_per_inch,
                    value.geometry.pitch_x_meters * 1_000_000.0,
                    value.geometry.pitch_y_meters * 1_000_000.0,
                ),
                format!(
                    "{} samples/pixel; geometry {resolved}; RGB/BGR topology is discrete",
                    value.sampling.samples_per_output_pixel,
                ),
                "fixed device-space luminance/chromatic residuals; deterministic across frames"
                    .to_owned(),
                "9 taps/channel; physical radii in micrometers; fused Metal elapsed time reported"
                    .to_owned(),
                "exact rational shutter integral; residual flicker is frame-uniform unless analytic banding is enabled"
                    .to_owned(),
                "Beer-Lambert transmission + Fresnel/AR + roughness/haze; flat view cosine 1"
                    .to_owned(),
                "synthetic HDR environment sampled independently from panel temporal emission"
                    .to_owned(),
                "energy-preserving cover glow with physical core/tail radii".to_owned(),
                "position + quaternion pose; device active dimensions are the sole screen scale"
                    .to_owned(),
                "thin lens + distortion/CA/vignette/transmission/PSF; focal-length generalized"
                    .to_owned(),
                "global-coordinate photosite crosstalk and full-well overflow transfer".to_owned(),
            )
        }
    };
    let output_texture = if texture_pointer == 0 {
        std::ptr::null()
    } else {
        let mut views = job
            .output_views
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        views.push(Box::new(ScreenPhysicalTexture {
            metal_texture: texture_pointer,
        }));
        &**views.last().expect("just pushed output view") as *const ScreenPhysicalTexture
    };
    let snapshot = diagnostic_snapshot(
        state,
        progress,
        stage_elapsed_nanoseconds,
        [
            emission,
            geometry,
            uniformity,
            spread,
            temporal,
            scene,
            cover,
            environment,
            glass_glow,
            lens,
            if job.static_input {
                "STATIC_INPUT: exact shutter/rolling/banding evaluation; motion blur inactive"
                    .to_owned()
            } else {
                "MOTION_ACTIVE: Rust-scheduled exact-time samples accumulated by Metal".to_owned()
            },
            "analytic exposure bracket materialized once; no repeated lens evaluation".to_owned(),
            sensor_bloom,
            if job.sensor_enabled {
                "sensor CFA/full-well/ADC active at the resolved native photosite raster".to_owned()
            } else {
                "sensor CFA disabled: exact typed-domain bypass".to_owned()
            },
            if job.sensor_enabled {
                format!(
                    "shot/dark/read noise amount {:.3}; deterministic capture identity",
                    job.sensor_noise_amount
                )
            } else {
                "sensor noise disabled with CFA domain".to_owned()
            },
            if job.development_enabled {
                "RAW demosaic + white balance + sensor-to-ACEScg development active".to_owned()
            } else {
                "RAW development disabled: no implicit developed output".to_owned()
            },
        ],
    );
    let mut snapshots = job
        .snapshots
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    snapshots.push(snapshot);
    let snapshot = snapshots.last().expect("just pushed diagnostic snapshot");
    // SAFETY: result is writable and all borrowed views remain job-owned until release.
    unsafe {
        *result = ScreenPhysicalFrameResultV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            output_texture,
            native_width: job.native_width,
            native_height: job.native_height,
            effective_width,
            effective_height,
            computed_quality: job.quality,
            returned_intermediate: job.requested_intermediate,
            state,
            progress,
            stage_diagnostics: snapshot.diagnostics.as_ptr(),
            stage_diagnostic_count: snapshot.diagnostics.len(),
            parameter_revision: job.parameter_revision,
            parameter_hash: job.parameter_hash,
        };
        set_error(error_message, b"\0");
    }
    true
}

#[cfg(not(target_os = "macos"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_job_snapshot(
    _job: *mut ScreenPhysicalFrameJob,
    _result: *mut ScreenPhysicalFrameResultV2,
    error_message: *mut *const c_char,
) -> bool {
    unsafe {
        set_error(
            error_message,
            b"Metal physical pipeline backend requires macOS\0",
        )
    };
    false
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_job_release(job: *mut ScreenPhysicalFrameJob) {
    if job.is_null() {
        return;
    }
    // SAFETY: the ABI requires the uniquely owned job returned by submit.
    let job = unsafe { Box::from_raw(job) };
    job.shared.cancelled.store(true, Ordering::Release);
    if let Some(worker) = job
        .worker
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        let _ = worker.join();
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenDeviceParametersV3 {
    abi_version: u32,
    native_width: u32,
    native_height: u32,
    panel_technology: u32,
    stripe_layout: u32,
    active_width_meters: f32,
    active_height_meters: f32,
    black_matrix_fraction: f32,
    eotf_gamma: f32,
    black_level_nits: f32,
    white_level_nits: f32,
    primary_xy: [f32; 6],
    white_xy: [f32; 2],
    angular_emission_power: [f32; 3],
    uniformity_character_strength: f32,
    uniformity_seed: u32,
    uniformity_broad_luminance_peak_to_peak: f32,
    uniformity_mid_luminance_peak_to_peak: f32,
    uniformity_fine_luminance_peak_to_peak: f32,
    uniformity_chromatic_peak_to_peak: f32,
    uniformity_mid_scale_millimeters: f32,
    uniformity_fine_scale_millimeters: f32,
    uniformity_low_drive_emphasis: f32,
    light_spread_character_strength: f32,
    light_spread_core_radius_micrometers: [f32; 3],
    light_spread_core_weight: [f32; 3],
    light_spread_tail_radius_micrometers: [f32; 3],
    light_spread_tail_weight: [f32; 3],
    residual_period_numerator: i64,
    residual_period_denominator: u32,
    residual_amplitude: f32,
    residual_phase_numerator: i64,
    residual_phase_denominator: u32,
    banding_period_numerator: i64,
    banding_period_denominator: u32,
    banding_on_numerator: i64,
    banding_on_denominator: u32,
    banding_phase_numerator: i64,
    banding_phase_denominator: u32,
    banding_amount: f32,
}

pub struct ScreenDeviceProfile {
    profile: LcdProfile,
    uniformity: PanelUniformityProfile,
    light_spread: PanelLightSpreadProfile,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenCoverGlassParametersV2 {
    abi_version: u32,
    authority: u32,
    character_strength: f32,
    thickness_millimeters: f32,
    refractive_index: f32,
    anti_reflective_efficiency: f32,
    absorption_per_millimeter: [f32; 3],
    roughness: f32,
    haze: f32,
    ag_microtexture_character_strength: f32,
    ag_microtexture_rms_slope: f32,
    ag_microtexture_correlation_length_micrometers: f32,
    ag_microtexture_anisotropy: f32,
    ag_microtexture_seed: u32,
    glow_character_strength: f32,
    glow_scatter_fraction: f32,
    glow_core_radius_millimeters: f32,
    glow_tail_radius_millimeters: f32,
    glow_tail_fraction: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenEnvironmentParametersV2 {
    abi_version: u32,
    source_kind: u32,
    character_strength: f32,
    source_unit_radiance_candelas_per_square_meter: f32,
    exposure_stops: f32,
    ambient_radiance_acescg: [f32; 3],
    key_radiance_acescg: [f32; 3],
    key_direction_local: [f32; 3],
    key_angular_radius_degrees: f32,
    rotation_x_degrees: f32,
    rotation_y_degrees: f32,
    projection_mode: u32,
    sphere_radius_meters: f32,
    pattern: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenSceneGeometryLensParametersV2 {
    abi_version: u32,
    lens_evaluation_model: u32,
    focal_length_millimeters: f32,
    sensor_width_millimeters: f32,
    sensor_height_millimeters: f32,
    lens_shift: [f32; 2],
    focus_distance_meters: f32,
    f_stop: f32,
    near_clip_meters: f32,
    far_clip_meters: f32,
    lens_radial_distortion: [f32; 3],
    lens_tangential_distortion: [f32; 2],
    lens_longitudinal_chromatic_meters: [f32; 3],
    lens_lateral_chromatic_scale: [f32; 3],
    lens_vignetting_strength: f32,
    lens_transmission_rgb: [f32; 3],
    lens_center_softness_micrometers: f32,
    lens_edge_softness_micrometers: f32,
    lens_veiling_glare_fraction: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenShutterMotionParametersV2 {
    abi_version: u32,
    temporal_samples: u16,
    readout_kind: u16,
    readout_duration_numerator: i64,
    readout_duration_denominator: u32,
    readout_direction: u32,
    neutral_density_stops: f32,
    noise_seed: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenSensorNoiseParametersV2 {
    abi_version: u32,
    native_width: u32,
    native_height: u32,
    bayer_pattern: u32,
    acescg_to_sensor: [f32; 9],
    saturation_illuminance_seconds: [f32; 3],
    full_well_electrons: f32,
    dark_current_electrons_per_second: f32,
    read_noise_electrons_rms: f32,
    analog_gain: f32,
    adc_bits: u32,
    bloom_character_strength: f32,
    bloom_crosstalk_fraction: f32,
    bloom_overflow_transfer_fraction: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenComputationalCaptureParametersV3 {
    abi_version: u32,
    exposure_count: u32,
    bracket_spacing_stops: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenRawDevelopParametersV2 {
    abi_version: u32,
    white_balance: [f32; 3],
    middle_gray_illuminance_seconds: f32,
    develop_exposure_ev: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenCameraRenderingIntentParametersV1 {
    abi_version: u32,
    exposure_ev: f32,
    contrast: f32,
    saturation: f32,
    temperature_kelvin: f32,
    tint: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenCameraRadiometricCalibrationV2 {
    abi_version: u32,
    base_exposure_index: f32,
    reference_lambertian_reflectance: f32,
    reference_illuminance_lux: f32,
    reference_t_stop: f32,
    reference_shutter_seconds: f32,
    effective_sensor_exposure_scale: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalPipelineParametersV2 {
    abi_version: u32,
    cover: ScreenCoverGlassParametersV2,
    environment: ScreenEnvironmentParametersV2,
    scene_geometry_lens: ScreenSceneGeometryLensParametersV2,
    shutter_motion: ScreenShutterMotionParametersV2,
    computational_capture: ScreenComputationalCaptureParametersV3,
    sensor_noise: ScreenSensorNoiseParametersV2,
    raw_develop: ScreenRawDevelopParametersV2,
    camera_rendering_intent: ScreenCameraRenderingIntentParametersV1,
    radiometric_calibration: ScreenCameraRadiometricCalibrationV2,
}

pub struct ScreenPhysicalPipelineSnapshot {
    cover: CoverGlassProfile,
    environment: IncidentEnvironment,
    scene_geometry_lens: ResolvedSceneGeometryLensSnapshot,
    lens_evaluation_model: screen_application::LensEvaluationModel,
    shutter_motion: ResolvedShutterMotionSnapshot,
    computational_capture: ComputationalCaptureProfile,
    sensor: SensorProfile,
    development: CameraDevelopment,
    rendering_intent: CameraRenderingIntent,
    radiometric_calibration: CameraRadiometricCalibration,
}

pub struct ScreenCoverGlassProfile {
    _profile: CoverGlassProfile,
}

fn utf8_view(value: &'static str) -> ScreenUtf8View {
    ScreenUtf8View {
        bytes: value.as_ptr(),
        count: value.len(),
    }
}

unsafe fn borrowed_utf8<'a>(view: ScreenUtf8View) -> Option<&'a str> {
    if view.bytes.is_null() || view.count == 0 {
        return None;
    }
    // SAFETY: the ABI caller keeps the immutable bytes alive for this call.
    let bytes = unsafe { std::slice::from_raw_parts(view.bytes, view.count) };
    std::str::from_utf8(bytes).ok()
}

unsafe fn test_selection<'a>(
    selection: *const ScreenTestAuthoringSelectionV22,
) -> Option<TestAuthoringSelection<'a>> {
    let selection = unsafe { selection.as_ref() }?;
    if selection.abi_version != SCREEN_TEST_AUTHORING_ABI_VERSION {
        return None;
    }
    Some(TestAuthoringSelection {
        input_transform_id: unsafe { borrowed_utf8(selection.input_transform_id) }?,
        output_signal_id: unsafe { borrowed_utf8(selection.output_signal_id) }?,
        device_id: unsafe { borrowed_utf8(selection.device_id) }?,
        color_mode_id: unsafe { borrowed_utf8(selection.color_mode_id) }?,
        white_luminance_nits: selection.white_luminance_nits,
        placement_id: unsafe { borrowed_utf8(selection.placement_id) }?,
        preview_quality_id: unsafe { borrowed_utf8(selection.preview_quality_id) }?,
        frame_rate: FrameRate::new(
            selection.frame_rate_numerator,
            selection.frame_rate_denominator,
        )
        .ok()?,
        source_adjustment: SceneLinearAdjustment {
            exposure_ev: selection.source_exposure_ev,
            contrast: selection.source_contrast,
            saturation: selection.source_saturation,
            temperature_kelvin: selection.source_temperature_kelvin,
            tint: selection.source_tint,
        },
        subpixel_geometry_amount: selection.subpixel_geometry_amount,
        panel_uniformity_amount: selection.panel_uniformity_amount,
        panel_light_spread_amount: selection.panel_light_spread_amount,
        capture_preset_id: unsafe { borrowed_utf8(selection.capture_preset_id) }?,
        capture_raster_mode_id: unsafe { borrowed_utf8(selection.capture_raster_mode_id) }?,
        lens_evaluation_model_id: unsafe { borrowed_utf8(selection.lens_evaluation_model_id) }?,
        geometry_mode_id: unsafe { borrowed_utf8(selection.geometry_mode_id) }?,
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
        screen_rotation_x_degrees: selection.screen_rotation_x_degrees,
        screen_yaw_degrees: selection.screen_yaw_degrees,
        screen_rotation_z_degrees: selection.screen_rotation_z_degrees,
        cover_glass_preset_id: unsafe { borrowed_utf8(selection.cover_glass_preset_id) }?,
        cover_glass_amount: selection.cover_glass_amount,
        cover_ag_microtexture_amount: selection.cover_ag_microtexture_amount,
        environment_source_id: unsafe { borrowed_utf8(selection.environment_source_id) }?,
        environment_amount: selection.environment_amount,
        environment_rotation_x_degrees: selection.environment_rotation_x_degrees,
        environment_rotation_y_degrees: selection.environment_rotation_y_degrees,
        environment_exposure_ev: selection.environment_exposure_ev,
        environment_contrast: selection.environment_contrast,
        environment_saturation: selection.environment_saturation,
        environment_temperature_kelvin: selection.environment_temperature_kelvin,
        environment_tint: selection.environment_tint,
        environment_projection_id: unsafe { borrowed_utf8(selection.environment_projection_id) }?,
        environment_sphere_radius_meters: selection.environment_sphere_radius_meters,
        cover_glow_amount: selection.cover_glow_amount,
        lens_preset_id: unsafe { borrowed_utf8(selection.lens_preset_id) }?,
        focal_length_millimeters: selection.focal_length_millimeters,
        lens_amount: selection.lens_amount,
        autofocus_enabled: selection.autofocus_enabled,
        focus_distance_meters: selection.focus_distance_meters,
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
        camera_rendering_intent: CameraRenderingIntent {
            exposure_ev: selection.camera_look_exposure_ev,
            contrast: selection.camera_look_contrast,
            saturation: selection.camera_look_saturation,
            temperature_kelvin: selection.camera_look_temperature_kelvin,
            tint: selection.camera_look_tint,
        },
        delivery_preset_id: unsafe { borrowed_utf8(selection.delivery_preset_id) }?,
        delivery_width: selection.delivery_width as f32,
        delivery_height: selection.delivery_height as f32,
        delivery_placement_id: unsafe { borrowed_utf8(selection.delivery_placement_id) }?,
        delivery_background_id: unsafe { borrowed_utf8(selection.delivery_background_id) }?,
        recording_output_transform_id: unsafe {
            borrowed_utf8(selection.recording_output_transform_id)
        }?,
        recording_profile_id: unsafe { borrowed_utf8(selection.recording_profile_id) }?,
        recording_character: selection.recording_character,
    })
}

fn test_authoring_error(error: TestAuthoringError) -> &'static [u8] {
    match error {
        TestAuthoringError::UnknownInputTransform => b"unknown Test Input Transform\0",
        TestAuthoringError::UnknownOutputSignal => b"unknown Test Output Signal\0",
        TestAuthoringError::UnknownDevice => b"unknown Test device preset\0",
        TestAuthoringError::UnknownColorMode => b"unknown Test Color Mode\0",
        TestAuthoringError::UnsupportedColorMode => {
            b"Color Mode is not supported by the selected device\0"
        }
        TestAuthoringError::InvalidWhiteLuminance => {
            b"White Luminance is outside the selected device capability\0"
        }
        TestAuthoringError::InvalidSourceAdjustment => b"invalid Source Adjustment\0",
        TestAuthoringError::InvalidSubpixelGeometryAmount => {
            b"Subpixel Geometry amount is outside 0..=4\0"
        }
        TestAuthoringError::InvalidPanelUniformityAmount => {
            b"Panel Uniformity amount is outside 0..=4\0"
        }
        TestAuthoringError::InvalidPanelLightSpreadAmount => {
            b"Panel Light Spread amount is outside 0..=4\0"
        }
        TestAuthoringError::InvalidCaptureRasterMode => b"invalid capture raster mode\0",
        TestAuthoringError::UnknownCapturePreset => b"unknown Test Capture preset\0",
        TestAuthoringError::UnknownLensPreset => b"unknown Test Lens preset\0",
        TestAuthoringError::UnsupportedLensPreset => {
            b"Lens is not compatible with the selected Camera\0"
        }
        TestAuthoringError::InvalidGeometry => b"invalid Test relative geometry\0",
        TestAuthoringError::UnknownCoverGlassPreset => b"unknown Test Cover Glass preset\0",
        TestAuthoringError::InvalidCoverGlassAmount => b"Cover Glass amount is outside 0..=2\0",
        TestAuthoringError::InvalidCoverAgMicrotextureAmount => {
            b"Cover AG Microtexture amount is outside 0..=4\0"
        }
        TestAuthoringError::UnknownEnvironmentPreset => b"unknown Test Environment preset\0",
        TestAuthoringError::InvalidEnvironmentAmount => b"Environment amount is outside 0..=4\0",
        TestAuthoringError::InvalidCoverGlowAmount => b"Cover Glow amount is outside 0..=4\0",
        TestAuthoringError::InvalidLensAmount => b"Lens amount is outside 0..=4\0",
        TestAuthoringError::InvalidFocusDistance => b"invalid Test Focus Distance\0",
        TestAuthoringError::InvalidAperture => b"invalid Test Aperture\0",
        TestAuthoringError::InvalidExposureTime => b"invalid Test Exposure Time\0",
        TestAuthoringError::InvalidShutterMotionAmount => b"Shutter amount is outside 0..=4\0",
        TestAuthoringError::InvalidComputationalCapture => {
            b"invalid computational capture bracket\0"
        }
        TestAuthoringError::InvalidSensorBloomAmount => b"Sensor Bloom amount is outside 0..=4\0",
        TestAuthoringError::InvalidSensorBloomProfile => {
            b"Sensor Bloom profile is outside its physical bounds\0"
        }
        TestAuthoringError::InvalidSensorNoiseAmount => b"Sensor Noise amount is outside 0..=4\0",
        TestAuthoringError::InvalidCameraRenderingIntent => b"invalid Camera Rendering Intent\0",
        TestAuthoringError::InvalidDeliveryRaster => b"invalid Delivery Raster\0",
        TestAuthoringError::UnknownRecordingOutputTransform => {
            b"unknown Recording Output Transform\0"
        }
        TestAuthoringError::InvalidRecording => b"invalid Recording request\0",
        TestAuthoringError::UnknownPlacement => b"unknown Test placement\0",
        TestAuthoringError::UnknownPreviewQuality => b"unknown Test preview quality\0",
        TestAuthoringError::UnknownControl => b"unknown Test control\0",
        TestAuthoringError::WrongControlType => b"Test intent has the wrong control type\0",
    }
}

fn resolved_test_selection(
    selection: screen_application::ResolvedTestAuthoringSelection,
) -> ScreenTestAuthoringSelectionV22 {
    ScreenTestAuthoringSelectionV22 {
        abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
        input_transform_id: utf8_view(selection.input_transform_id),
        output_signal_id: utf8_view(selection.output_signal_id),
        device_id: utf8_view(selection.device_id),
        color_mode_id: utf8_view(selection.color_mode_id),
        device_eotf_gamma: selection.device_eotf_gamma,
        white_luminance_nits: selection.white_luminance_nits,
        placement_id: utf8_view(selection.placement_id),
        preview_quality_id: utf8_view(selection.preview_quality_id),
        frame_rate_numerator: selection.frame_rate.numerator(),
        frame_rate_denominator: selection.frame_rate.denominator(),
        source_exposure_ev: selection.source_adjustment.exposure_ev,
        source_contrast: selection.source_adjustment.contrast,
        source_saturation: selection.source_adjustment.saturation,
        source_temperature_kelvin: selection.source_adjustment.temperature_kelvin,
        source_tint: selection.source_adjustment.tint,
        subpixel_geometry_amount: selection.subpixel_geometry_amount,
        panel_uniformity_amount: selection.panel_uniformity_amount,
        panel_light_spread_amount: selection.panel_light_spread_amount,
        capture_preset_id: utf8_view(selection.capture_preset_id),
        capture_raster_mode_id: utf8_view(selection.capture_raster_mode_id),
        lens_evaluation_model_id: utf8_view(selection.lens_evaluation_model_id),
        geometry_mode_id: utf8_view(selection.geometry_mode_id),
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
        screen_rotation_x_degrees: selection.screen_rotation_x_degrees,
        screen_yaw_degrees: selection.screen_yaw_degrees,
        screen_rotation_z_degrees: selection.screen_rotation_z_degrees,
        cover_glass_preset_id: utf8_view(selection.cover_glass_preset_id),
        cover_glass_amount: selection.cover_glass_amount,
        cover_ag_microtexture_amount: selection.cover_ag_microtexture_amount,
        environment_source_id: utf8_view(selection.environment_source_id),
        environment_amount: selection.environment_amount,
        environment_rotation_x_degrees: selection.environment_rotation_x_degrees,
        environment_rotation_y_degrees: selection.environment_rotation_y_degrees,
        environment_exposure_ev: selection.environment_exposure_ev,
        environment_contrast: selection.environment_contrast,
        environment_saturation: selection.environment_saturation,
        environment_temperature_kelvin: selection.environment_temperature_kelvin,
        environment_tint: selection.environment_tint,
        environment_projection_id: utf8_view(selection.environment_projection_id),
        environment_sphere_radius_meters: selection.environment_sphere_radius_meters,
        cover_glow_amount: selection.cover_glow_amount,
        lens_preset_id: utf8_view(selection.lens_preset_id),
        focal_length_millimeters: selection.focal_length_millimeters,
        lens_amount: selection.lens_amount,
        autofocus_enabled: selection.autofocus_enabled,
        focus_distance_meters: selection.focus_distance_meters,
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
        camera_look_exposure_ev: selection.camera_rendering_intent.exposure_ev,
        camera_look_contrast: selection.camera_rendering_intent.contrast,
        camera_look_saturation: selection.camera_rendering_intent.saturation,
        camera_look_temperature_kelvin: selection.camera_rendering_intent.temperature_kelvin,
        camera_look_tint: selection.camera_rendering_intent.tint,
        delivery_preset_id: utf8_view(selection.delivery_preset_id),
        delivery_width: selection.delivery_width,
        delivery_height: selection.delivery_height,
        delivery_placement_id: utf8_view(selection.delivery_placement_id),
        delivery_background_id: utf8_view(selection.delivery_background_id),
        recording_output_transform_id: utf8_view(selection.recording_output_transform_id),
        recording_profile_id: utf8_view(selection.recording_profile_id),
        recording_character: selection.recording_character,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_authoring_default_selection(
    input_transform_id: ScreenUtf8View,
    device_id: ScreenUtf8View,
    frame_rate_numerator: u32,
    frame_rate_denominator: u32,
    resolved: *mut ScreenTestAuthoringSelectionV22,
    error_message: *mut *const c_char,
) -> bool {
    let Some(input_transform_id) = (unsafe { borrowed_utf8(input_transform_id) }) else {
        unsafe { set_error(error_message, b"invalid Test Input Transform UTF-8\0") };
        return false;
    };
    let Some(device_id) = (unsafe { borrowed_utf8(device_id) }) else {
        unsafe { set_error(error_message, b"invalid Test Device UTF-8\0") };
        return false;
    };
    let Some(destination) = (unsafe { resolved.as_mut() }) else {
        unsafe {
            set_error(
                error_message,
                b"missing Test default-selection destination\0",
            )
        };
        return false;
    };
    let Ok(frame_rate) = FrameRate::new(frame_rate_numerator, frame_rate_denominator) else {
        unsafe { set_error(error_message, b"invalid exact Test frame rate\0") };
        return false;
    };
    match default_test_authoring_selection(input_transform_id, device_id, frame_rate) {
        Ok(selection) => {
            *destination = resolved_test_selection(selection);
            unsafe { set_error(error_message, b"\0") };
            true
        }
        Err(error) => {
            unsafe { set_error(error_message, test_authoring_error(error)) };
            false
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_descriptor_create(
    selection: *const ScreenTestAuthoringSelectionV22,
    error_message: *mut *const c_char,
) -> *mut ScreenTestPageDescriptor {
    let Some(selection) = (unsafe { test_selection(selection) }) else {
        unsafe { set_error(error_message, b"invalid Test authoring selection ABI\0") };
        return std::ptr::null_mut();
    };
    match test_page_descriptor(selection) {
        Ok(page) => {
            unsafe { set_error(error_message, b"\0") };
            Box::into_raw(Box::new(ScreenTestPageDescriptor { page }))
        }
        Err(error) => {
            unsafe { set_error(error_message, test_authoring_error(error)) };
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_descriptor_release(
    descriptor: *mut ScreenTestPageDescriptor,
) {
    if !descriptor.is_null() {
        // SAFETY: the ABI requires the unique pointer returned by create.
        unsafe { drop(Box::from_raw(descriptor)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_phase_count(
    descriptor: *const ScreenTestPageDescriptor,
) -> usize {
    unsafe { descriptor.as_ref() }.map_or(0, |value| value.page.phases.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_default_preview_phase_id(
    descriptor: *const ScreenTestPageDescriptor,
) -> ScreenUtf8View {
    unsafe { descriptor.as_ref() }.map_or(utf8_view(""), |value| {
        utf8_view(value.page.default_preview_phase_id)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_phase_descriptor(
    descriptor: *const ScreenTestPageDescriptor,
    phase_index: usize,
    phase: *mut ScreenTestPhaseDescriptorV5,
) -> bool {
    let Some(source) =
        unsafe { descriptor.as_ref() }.and_then(|value| value.page.phases.get(phase_index))
    else {
        return false;
    };
    let Some(destination) = (unsafe { phase.as_mut() }) else {
        return false;
    };
    let physical_intermediate = source.physical_intermediate();
    *destination = ScreenTestPhaseDescriptorV5 {
        abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
        id: utf8_view(source.id),
        label: utf8_view(source.label),
        effect_summary: utf8_view(source.effect_summary),
        header_control_id: utf8_view(source.header_control_id.unwrap_or("")),
        input_artifact: utf8_view(source.input_artifact.stable_id()),
        output_artifact: utf8_view(source.output_artifact.stable_id()),
        preview_result: source.preview_result as u32,
        has_physical_intermediate: physical_intermediate.is_some(),
        physical_intermediate: physical_intermediate.map_or(0, |value| value as u32),
        calculation_domain: utf8_view(source.calculation_domain()),
        preview_route: utf8_view(source.preview_route()),
    };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_control_count(
    descriptor: *const ScreenTestPageDescriptor,
    phase_index: usize,
) -> usize {
    unsafe { descriptor.as_ref() }
        .and_then(|value| value.page.phases.get(phase_index))
        .map_or(0, |phase| phase.controls.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_control_descriptor(
    descriptor: *const ScreenTestPageDescriptor,
    phase_index: usize,
    control_index: usize,
    control: *mut ScreenTestControlDescriptorV5,
) -> bool {
    let Some(source) = unsafe { descriptor.as_ref() }
        .and_then(|value| value.page.phases.get(phase_index))
        .and_then(|phase| phase.controls.get(control_index))
    else {
        return false;
    };
    let Some(destination) = (unsafe { control.as_mut() }) else {
        return false;
    };
    *destination = test_control_descriptor(source);
    true
}

fn test_control_descriptor(source: &TestControlRequirement) -> ScreenTestControlDescriptorV5 {
    match source {
        TestControlRequirement::Choice {
            id,
            label,
            selected_id,
            reset_id,
            ..
        } => ScreenTestControlDescriptorV5 {
            abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
            kind: SCREEN_TEST_CONTROL_CHOICE,
            id: utf8_view(id),
            label: utf8_view(label),
            selected_id: utf8_view(selected_id),
            reset_id: utf8_view(reset_id),
            value: 0.0,
            reset_value: 0.0,
            minimum: 0.0,
            maximum: 0.0,
            step: 0.0,
            slider_visible: false,
            unit: utf8_view(""),
        },
        TestControlRequirement::Scalar {
            id,
            label,
            value,
            minimum,
            maximum,
            step,
            slider_visible,
            unit,
            reset_value,
        } => ScreenTestControlDescriptorV5 {
            abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
            kind: SCREEN_TEST_CONTROL_SCALAR,
            id: utf8_view(id),
            label: utf8_view(label),
            selected_id: utf8_view(""),
            reset_id: utf8_view(""),
            value: *value,
            reset_value: *reset_value,
            minimum: *minimum,
            maximum: *maximum,
            step: *step,
            slider_visible: *slider_visible,
            unit: utf8_view(unit),
        },
        TestControlRequirement::Toggle {
            id,
            label,
            value,
            reset_value,
        } => ScreenTestControlDescriptorV5 {
            abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
            kind: SCREEN_TEST_CONTROL_TOGGLE,
            id: utf8_view(id),
            label: utf8_view(label),
            selected_id: utf8_view(""),
            reset_id: utf8_view(""),
            value: if *value { 1.0 } else { 0.0 },
            reset_value: if *reset_value { 1.0 } else { 0.0 },
            minimum: 0.0,
            maximum: 1.0,
            step: 1.0,
            slider_visible: false,
            unit: utf8_view(""),
        },
        TestControlRequirement::Action { id, label } => ScreenTestControlDescriptorV5 {
            abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
            kind: SCREEN_TEST_CONTROL_ACTION,
            id: utf8_view(id),
            label: utf8_view(label),
            selected_id: utf8_view(""),
            reset_id: utf8_view(""),
            value: 0.0,
            reset_value: 0.0,
            minimum: 0.0,
            maximum: 0.0,
            step: 0.0,
            slider_visible: false,
            unit: utf8_view(""),
        },
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_choice_option_count(
    descriptor: *const ScreenTestPageDescriptor,
    phase_index: usize,
    control_index: usize,
) -> usize {
    let Some(TestControlRequirement::Choice { options, .. }) = (unsafe { descriptor.as_ref() })
        .and_then(|value| value.page.phases.get(phase_index))
        .and_then(|phase| phase.controls.get(control_index))
    else {
        return 0;
    };
    options.len()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_choice_option(
    descriptor: *const ScreenTestPageDescriptor,
    phase_index: usize,
    control_index: usize,
    option_index: usize,
    option: *mut ScreenTestChoiceOptionV2,
) -> bool {
    let Some(TestControlRequirement::Choice { options, .. }) = (unsafe { descriptor.as_ref() })
        .and_then(|value| value.page.phases.get(phase_index))
        .and_then(|phase| phase.controls.get(control_index))
    else {
        return false;
    };
    let Some(source) = options.get(option_index) else {
        return false;
    };
    let Some(destination) = (unsafe { option.as_mut() }) else {
        return false;
    };
    *destination = ScreenTestChoiceOptionV2 {
        abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
        id: utf8_view(source.id),
        label: utf8_view(source.label),
    };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_preview_control_count(
    descriptor: *const ScreenTestPageDescriptor,
) -> usize {
    unsafe { descriptor.as_ref() }.map_or(0, |value| value.page.preview_controls.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_preview_control_descriptor(
    descriptor: *const ScreenTestPageDescriptor,
    control_index: usize,
    control: *mut ScreenTestControlDescriptorV5,
) -> bool {
    let Some(source) = (unsafe { descriptor.as_ref() })
        .and_then(|value| value.page.preview_controls.get(control_index))
    else {
        return false;
    };
    let Some(destination) = (unsafe { control.as_mut() }) else {
        return false;
    };
    *destination = test_control_descriptor(source);
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_preview_choice_option_count(
    descriptor: *const ScreenTestPageDescriptor,
    control_index: usize,
) -> usize {
    let Some(TestControlRequirement::Choice { options, .. }) = (unsafe { descriptor.as_ref() })
        .and_then(|value| value.page.preview_controls.get(control_index))
    else {
        return 0;
    };
    options.len()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_page_preview_choice_option(
    descriptor: *const ScreenTestPageDescriptor,
    control_index: usize,
    option_index: usize,
    option: *mut ScreenTestChoiceOptionV2,
) -> bool {
    let Some(TestControlRequirement::Choice { options, .. }) = (unsafe { descriptor.as_ref() })
        .and_then(|value| value.page.preview_controls.get(control_index))
    else {
        return false;
    };
    let Some(source) = options.get(option_index) else {
        return false;
    };
    let Some(destination) = (unsafe { option.as_mut() }) else {
        return false;
    };
    *destination = ScreenTestChoiceOptionV2 {
        abi_version: SCREEN_TEST_AUTHORING_ABI_VERSION,
        id: utf8_view(source.id),
        label: utf8_view(source.label),
    };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_authoring_apply_choice(
    selection: *const ScreenTestAuthoringSelectionV22,
    control_id: ScreenUtf8View,
    option_id: ScreenUtf8View,
    resolved: *mut ScreenTestAuthoringSelectionV22,
    error_message: *mut *const c_char,
) -> bool {
    let Some(selection) = (unsafe { test_selection(selection) }) else {
        unsafe { set_error(error_message, b"invalid Test authoring selection ABI\0") };
        return false;
    };
    let Some(control_id) = (unsafe { borrowed_utf8(control_id) }) else {
        unsafe { set_error(error_message, b"invalid Test control id\0") };
        return false;
    };
    let Some(option_id) = (unsafe { borrowed_utf8(option_id) }) else {
        unsafe { set_error(error_message, b"invalid Test option id\0") };
        return false;
    };
    let Some(destination) = (unsafe { resolved.as_mut() }) else {
        unsafe { set_error(error_message, b"missing resolved Test selection output\0") };
        return false;
    };
    match apply_test_choice(selection, control_id, option_id) {
        Ok(selection) => {
            *destination = resolved_test_selection(selection);
            unsafe { set_error(error_message, b"\0") };
            true
        }
        Err(error) => {
            unsafe { set_error(error_message, test_authoring_error(error)) };
            false
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_authoring_apply_scalar(
    selection: *const ScreenTestAuthoringSelectionV22,
    control_id: ScreenUtf8View,
    value: f32,
    resolved: *mut ScreenTestAuthoringSelectionV22,
    error_message: *mut *const c_char,
) -> bool {
    let Some(selection) = (unsafe { test_selection(selection) }) else {
        unsafe { set_error(error_message, b"invalid Test authoring selection ABI\0") };
        return false;
    };
    let Some(control_id) = (unsafe { borrowed_utf8(control_id) }) else {
        unsafe { set_error(error_message, b"invalid Test control id\0") };
        return false;
    };
    let Some(destination) = (unsafe { resolved.as_mut() }) else {
        unsafe { set_error(error_message, b"missing resolved Test selection output\0") };
        return false;
    };
    match apply_test_scalar(selection, control_id, value) {
        Ok(selection) => {
            *destination = resolved_test_selection(selection);
            unsafe { set_error(error_message, b"\0") };
            true
        }
        Err(error) => {
            unsafe { set_error(error_message, test_authoring_error(error)) };
            false
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_authoring_apply_toggle(
    selection: *const ScreenTestAuthoringSelectionV22,
    control_id: ScreenUtf8View,
    value: bool,
    resolved: *mut ScreenTestAuthoringSelectionV22,
    error_message: *mut *const c_char,
) -> bool {
    let Some(selection) = (unsafe { test_selection(selection) }) else {
        unsafe { set_error(error_message, b"invalid Test authoring selection ABI\0") };
        return false;
    };
    let Some(control_id) = (unsafe { borrowed_utf8(control_id) }) else {
        unsafe { set_error(error_message, b"invalid Test control id\0") };
        return false;
    };
    let Some(destination) = (unsafe { resolved.as_mut() }) else {
        unsafe { set_error(error_message, b"missing resolved Test selection output\0") };
        return false;
    };
    match apply_test_toggle(selection, control_id, value) {
        Ok(selection) => {
            *destination = resolved_test_selection(selection);
            unsafe { set_error(error_message, b"\0") };
            true
        }
        Err(error) => {
            unsafe { set_error(error_message, test_authoring_error(error)) };
            false
        }
    }
}

fn preset_at(index: usize) -> Option<screen_panel::DevicePreset> {
    DEVICE_PRESETS.get(index).copied()
}

fn cover_preset_at(index: usize) -> Option<screen_cover::CoverGlassPreset> {
    COVER_GLASS_PRESETS.get(index).copied()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_cover_glass_preset_count() -> usize {
    COVER_GLASS_PRESETS.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_cover_glass_preset_id(index: usize) -> ScreenUtf8View {
    cover_preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.id))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_cover_glass_preset_label(index: usize) -> ScreenUtf8View {
    cover_preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.label))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_cover_glass_preset_parameters(
    index: usize,
    parameters: *mut ScreenCoverGlassParametersV2,
) -> bool {
    let Some(preset) = cover_preset_at(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    // SAFETY: the caller provided writable current-version parameter storage.
    unsafe { *parameters = cover_parameters(preset.authority, preset.profile) };
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_environment_preset_count() -> usize {
    ENVIRONMENT_PRESETS.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_environment_preset_id(index: usize) -> ScreenUtf8View {
    ENVIRONMENT_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| utf8_view(preset.id))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_environment_preset_label(index: usize) -> ScreenUtf8View {
    ENVIRONMENT_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| utf8_view(preset.label))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_environment_preset_parameters(
    index: usize,
    parameters: *mut ScreenEnvironmentParametersV2,
) -> bool {
    let Some(preset) = ENVIRONMENT_PRESETS.get(index) else {
        return false;
    };
    let Some(destination) = (unsafe { parameters.as_mut() }) else {
        return false;
    };
    let environment = preset.environment;
    *destination = ScreenEnvironmentParametersV2 {
        abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
        source_kind: 0,
        character_strength: environment.character_strength,
        source_unit_radiance_candelas_per_square_meter: 0.0,
        exposure_stops: 0.0,
        ambient_radiance_acescg: [
            environment.ambient_radiance.0.r,
            environment.ambient_radiance.0.g,
            environment.ambient_radiance.0.b,
        ],
        key_radiance_acescg: [
            environment.key_radiance.0.r,
            environment.key_radiance.0.g,
            environment.key_radiance.0.b,
        ],
        key_direction_local: environment.key_direction_local,
        key_angular_radius_degrees: environment.key_angular_radius_degrees,
        rotation_x_degrees: environment.rotation_x_degrees,
        rotation_y_degrees: environment.rotation_y_degrees,
        projection_mode: 0,
        sphere_radius_meters: 5.0,
        pattern: match environment.pattern {
            EnvironmentPattern::UniformNeutral => 0,
            EnvironmentPattern::StudioSoftboxes => 1,
            EnvironmentPattern::CalibrationGrid => 2,
            EnvironmentPattern::OfficeCeiling => 3,
            EnvironmentPattern::DaylightWindow => 4,
            EnvironmentPattern::WarmPracticals => 5,
            EnvironmentPattern::MixedProduction => 6,
        },
    };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_cover_glass_profile_create(
    parameters: *const ScreenCoverGlassParametersV2,
    error_message: *mut *const c_char,
) -> *mut ScreenCoverGlassProfile {
    if parameters.is_null() {
        unsafe { set_error(error_message, b"missing cover glass parameters\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null parameters pointer is valid for this call.
    let parameters = unsafe { *parameters };
    if parameters.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION || parameters.authority > 1 {
        unsafe { set_error(error_message, b"unsupported cover glass parameter ABI\0") };
        return std::ptr::null_mut();
    }
    let profile = CoverGlassProfile {
        character_strength: parameters.character_strength,
        thickness_millimeters: parameters.thickness_millimeters,
        refractive_index: parameters.refractive_index,
        anti_reflective_efficiency: parameters.anti_reflective_efficiency,
        absorption_per_millimeter: LinearRgb::new(
            parameters.absorption_per_millimeter[0],
            parameters.absorption_per_millimeter[1],
            parameters.absorption_per_millimeter[2],
        ),
        roughness: parameters.roughness,
        haze: parameters.haze,
        anti_glare_microtexture: screen_cover::AntiGlareMicrotextureProfile {
            character_strength: parameters.ag_microtexture_character_strength,
            rms_slope: parameters.ag_microtexture_rms_slope,
            correlation_length_micrometers: parameters
                .ag_microtexture_correlation_length_micrometers,
            anisotropy: parameters.ag_microtexture_anisotropy,
            seed: parameters.ag_microtexture_seed,
        },
        glow: screen_cover::CoverGlowProfile {
            character_strength: parameters.glow_character_strength,
            scatter_fraction: parameters.glow_scatter_fraction,
            core_radius_millimeters: parameters.glow_core_radius_millimeters,
            tail_radius_millimeters: parameters.glow_tail_radius_millimeters,
            tail_fraction: parameters.glow_tail_fraction,
        },
    };
    let Ok(profile) = profile.validate() else {
        unsafe { set_error(error_message, b"invalid physical cover glass profile\0") };
        return std::ptr::null_mut();
    };
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenCoverGlassProfile { _profile: profile }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_cover_glass_profile_release(profile: *mut ScreenCoverGlassProfile) {
    if !profile.is_null() {
        // SAFETY: the ABI requires the uniquely owned handle returned by create.
        unsafe { drop(Box::from_raw(profile)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_pipeline_snapshot_create(
    parameters: *const ScreenPhysicalPipelineParametersV2,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalPipelineSnapshot {
    if parameters.is_null() {
        unsafe { set_error(error_message, b"missing physical pipeline parameters\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null parameter block is immutable for this call.
    let parameters = unsafe { *parameters };
    if [
        parameters.abi_version,
        parameters.cover.abi_version,
        parameters.environment.abi_version,
        parameters.scene_geometry_lens.abi_version,
        parameters.shutter_motion.abi_version,
        parameters.computational_capture.abi_version,
        parameters.sensor_noise.abi_version,
        parameters.raw_develop.abi_version,
        parameters.radiometric_calibration.abi_version,
    ]
    .into_iter()
    .any(|version| version != SCREEN_PHYSICAL_FRAME_ABI_VERSION)
    {
        unsafe { set_error(error_message, b"unsupported physical snapshot ABI\0") };
        return std::ptr::null_mut();
    }
    let cover = CoverGlassProfile {
        character_strength: parameters.cover.character_strength,
        thickness_millimeters: parameters.cover.thickness_millimeters,
        refractive_index: parameters.cover.refractive_index,
        anti_reflective_efficiency: parameters.cover.anti_reflective_efficiency,
        absorption_per_millimeter: LinearRgb::new(
            parameters.cover.absorption_per_millimeter[0],
            parameters.cover.absorption_per_millimeter[1],
            parameters.cover.absorption_per_millimeter[2],
        ),
        roughness: parameters.cover.roughness,
        haze: parameters.cover.haze,
        anti_glare_microtexture: screen_cover::AntiGlareMicrotextureProfile {
            character_strength: parameters.cover.ag_microtexture_character_strength,
            rms_slope: parameters.cover.ag_microtexture_rms_slope,
            correlation_length_micrometers: parameters
                .cover
                .ag_microtexture_correlation_length_micrometers,
            anisotropy: parameters.cover.ag_microtexture_anisotropy,
            seed: parameters.cover.ag_microtexture_seed,
        },
        glow: screen_cover::CoverGlowProfile {
            character_strength: parameters.cover.glow_character_strength,
            scatter_fraction: parameters.cover.glow_scatter_fraction,
            core_radius_millimeters: parameters.cover.glow_core_radius_millimeters,
            tail_radius_millimeters: parameters.cover.glow_tail_radius_millimeters,
            tail_fraction: parameters.cover.glow_tail_fraction,
        },
    };
    let environment = match parameters.environment.source_kind {
        0 => {
            let pattern = match parameters.environment.pattern {
                0 => EnvironmentPattern::UniformNeutral,
                1 => EnvironmentPattern::StudioSoftboxes,
                2 => EnvironmentPattern::CalibrationGrid,
                3 => EnvironmentPattern::OfficeCeiling,
                4 => EnvironmentPattern::DaylightWindow,
                5 => EnvironmentPattern::WarmPracticals,
                6 => EnvironmentPattern::MixedProduction,
                _ => {
                    unsafe { set_error(error_message, b"unsupported environment pattern\0") };
                    return std::ptr::null_mut();
                }
            };
            IncidentEnvironment::Procedural(ProceduralEnvironment {
                character_strength: parameters.environment.character_strength,
                ambient_radiance: AcesCgRadiance(LinearRgb::new(
                    parameters.environment.ambient_radiance_acescg[0],
                    parameters.environment.ambient_radiance_acescg[1],
                    parameters.environment.ambient_radiance_acescg[2],
                )),
                key_radiance: AcesCgRadiance(LinearRgb::new(
                    parameters.environment.key_radiance_acescg[0],
                    parameters.environment.key_radiance_acescg[1],
                    parameters.environment.key_radiance_acescg[2],
                )),
                key_direction_local: parameters.environment.key_direction_local,
                key_angular_radius_degrees: parameters.environment.key_angular_radius_degrees,
                rotation_x_degrees: parameters.environment.rotation_x_degrees,
                rotation_y_degrees: parameters.environment.rotation_y_degrees,
                pattern,
            })
        }
        1 => {
            if parameters.environment.ambient_radiance_acescg != [0.0; 3]
                || parameters.environment.key_radiance_acescg != [0.0; 3]
                || parameters.environment.pattern != 0
            {
                unsafe {
                    set_error(
                        error_message,
                        b"image-backed environment contains procedural parameters\0",
                    )
                };
                return std::ptr::null_mut();
            }
            IncidentEnvironment::Equirectangular(EquirectangularEnvironment {
                character_strength: parameters.environment.character_strength,
                source_unit_radiance_candelas_per_square_meter: parameters
                    .environment
                    .source_unit_radiance_candelas_per_square_meter,
                exposure_stops: parameters.environment.exposure_stops,
                rotation_x_degrees: parameters.environment.rotation_x_degrees,
                rotation_y_degrees: parameters.environment.rotation_y_degrees,
                projection: match parameters.environment.projection_mode {
                    0 => screen_cover::EnvironmentProjection::Distant,
                    1 => screen_cover::EnvironmentProjection::FiniteSphere {
                        radius_meters: parameters.environment.sphere_radius_meters,
                    },
                    _ => {
                        unsafe { set_error(error_message, b"invalid environment projection\0") };
                        return std::ptr::null_mut();
                    }
                },
            })
        }
        _ => {
            unsafe { set_error(error_message, b"unsupported environment source kind\0") };
            return std::ptr::null_mut();
        }
    };
    if environment.validate().is_err() {
        unsafe { set_error(error_message, b"invalid resolved environment\0") };
        return std::ptr::null_mut();
    }
    let scene = parameters.scene_geometry_lens;
    let lens_evaluation_model = match scene.lens_evaluation_model {
        0 => screen_application::LensEvaluationModel::ThinLens,
        1 => screen_application::LensEvaluationModel::VfxDepthBlur,
        _ => {
            unsafe { set_error(error_message, b"unknown lens evaluation model\0") };
            return std::ptr::null_mut();
        }
    };
    let scene_geometry_lens = ResolvedSceneGeometryLensSnapshot {
        focal_length_millimeters: scene.focal_length_millimeters,
        sensor_width_millimeters: scene.sensor_width_millimeters,
        sensor_height_millimeters: scene.sensor_height_millimeters,
        lens_shift: Vec2 {
            x: scene.lens_shift[0],
            y: scene.lens_shift[1],
        },
        focus_distance_meters: scene.focus_distance_meters,
        f_stop: scene.f_stop,
        near_clip_meters: scene.near_clip_meters,
        far_clip_meters: scene.far_clip_meters,
        lens: LensModel {
            radial_distortion: scene.lens_radial_distortion,
            tangential_distortion: scene.lens_tangential_distortion,
            longitudinal_chromatic_meters: scene.lens_longitudinal_chromatic_meters,
            lateral_chromatic_scale: scene.lens_lateral_chromatic_scale,
            vignetting_strength: scene.lens_vignetting_strength,
            transmission_rgb: scene.lens_transmission_rgb,
            center_softness_micrometers: scene.lens_center_softness_micrometers,
            edge_softness_micrometers: scene.lens_edge_softness_micrometers,
            veiling_glare_fraction: scene.lens_veiling_glare_fraction,
        },
    };
    let finite_scene = [scene.focal_length_millimeters]
        .into_iter()
        .chain([
            scene.sensor_width_millimeters,
            scene.sensor_height_millimeters,
        ])
        .chain(scene.lens_shift)
        .chain([scene.focus_distance_meters, scene.f_stop])
        .chain([scene.near_clip_meters, scene.far_clip_meters])
        .chain(scene.lens_radial_distortion)
        .chain(scene.lens_tangential_distortion)
        .chain(scene.lens_longitudinal_chromatic_meters)
        .chain(scene.lens_lateral_chromatic_scale)
        .chain([scene.lens_vignetting_strength])
        .chain(scene.lens_transmission_rgb)
        .chain([
            scene.lens_center_softness_micrometers,
            scene.lens_edge_softness_micrometers,
            scene.lens_veiling_glare_fraction,
        ])
        .all(f32::is_finite);
    if !finite_scene
        || scene.focal_length_millimeters <= 0.0
        || scene.sensor_width_millimeters <= 0.0
        || scene.sensor_height_millimeters <= 0.0
        || scene.focus_distance_meters <= 0.0
        || scene.f_stop <= 0.0
        || scene.near_clip_meters <= 0.0
        || scene.far_clip_meters <= scene.near_clip_meters
        || !(0.0..=0.25).contains(&scene.lens_veiling_glare_fraction)
    {
        unsafe { set_error(error_message, b"invalid scene/geometry/lens snapshot\0") };
        return std::ptr::null_mut();
    }
    let shutter = parameters.shutter_motion;
    let readout = match shutter.readout_kind {
        0 => SensorReadout::Global,
        1 => {
            let duration = match RationalTime::new(
                shutter.readout_duration_numerator,
                shutter.readout_duration_denominator,
            ) {
                Ok(value) if value.numerator() > 0 => value,
                _ => {
                    unsafe { set_error(error_message, b"invalid rolling readout duration\0") };
                    return std::ptr::null_mut();
                }
            };
            let direction = match shutter.readout_direction {
                0 => RollingDirection::TopToBottom,
                1 => RollingDirection::BottomToTop,
                _ => {
                    unsafe { set_error(error_message, b"unsupported rolling direction\0") };
                    return std::ptr::null_mut();
                }
            };
            SensorReadout::Rolling {
                duration,
                direction,
            }
        }
        _ => {
            unsafe { set_error(error_message, b"unsupported shutter readout\0") };
            return std::ptr::null_mut();
        }
    };
    if shutter.temporal_samples == 0
        || !shutter.neutral_density_stops.is_finite()
        || !(0.0..=16.0).contains(&shutter.neutral_density_stops)
    {
        unsafe { set_error(error_message, b"invalid shutter/motion snapshot\0") };
        return std::ptr::null_mut();
    }
    let shutter_motion = ResolvedShutterMotionSnapshot {
        temporal_samples: shutter.temporal_samples,
        readout,
        neutral_density_stops: shutter.neutral_density_stops,
        noise_seed: shutter.noise_seed,
    };
    let computational = parameters.computational_capture;
    let Ok(exposure_count) = u8::try_from(computational.exposure_count) else {
        unsafe {
            set_error(
                error_message,
                b"computational exposure count exceeds domain\0",
            )
        };
        return std::ptr::null_mut();
    };
    let computational_capture = ComputationalCaptureProfile {
        exposure_count,
        bracket_spacing_stops: computational.bracket_spacing_stops,
    };
    if computational_capture.validate().is_err() {
        unsafe { set_error(error_message, b"invalid computational capture snapshot\0") };
        return std::ptr::null_mut();
    }
    let sensor = parameters.sensor_noise;
    let bayer_pattern = match sensor.bayer_pattern {
        0 => BayerPattern::Rggb,
        1 => BayerPattern::Bggr,
        2 => BayerPattern::Grbg,
        3 => BayerPattern::Gbrg,
        _ => {
            unsafe { set_error(error_message, b"unsupported Bayer pattern\0") };
            return std::ptr::null_mut();
        }
    };
    let Ok(native_width) = u16::try_from(sensor.native_width) else {
        unsafe { set_error(error_message, b"sensor width exceeds physical domain\0") };
        return std::ptr::null_mut();
    };
    let Ok(native_height) = u16::try_from(sensor.native_height) else {
        unsafe { set_error(error_message, b"sensor height exceeds physical domain\0") };
        return std::ptr::null_mut();
    };
    let sensor = SensorProfile {
        native_width,
        native_height,
        bayer_pattern,
        acescg_to_sensor: [
            sensor.acescg_to_sensor[0..3]
                .try_into()
                .expect("fixed matrix row"),
            sensor.acescg_to_sensor[3..6]
                .try_into()
                .expect("fixed matrix row"),
            sensor.acescg_to_sensor[6..9]
                .try_into()
                .expect("fixed matrix row"),
        ],
        saturation_illuminance_seconds: LinearRgb::new(
            sensor.saturation_illuminance_seconds[0],
            sensor.saturation_illuminance_seconds[1],
            sensor.saturation_illuminance_seconds[2],
        ),
        full_well_electrons: sensor.full_well_electrons,
        dark_current_electrons_per_second: sensor.dark_current_electrons_per_second,
        read_noise_electrons_rms: sensor.read_noise_electrons_rms,
        analog_gain: sensor.analog_gain,
        adc_bits: match u8::try_from(sensor.adc_bits) {
            Ok(value) => value,
            Err(_) => {
                unsafe { set_error(error_message, b"ADC precision exceeds physical domain\0") };
                return std::ptr::null_mut();
            }
        },
        bloom: SensorBloomProfile {
            character_strength: sensor.bloom_character_strength,
            crosstalk_fraction: sensor.bloom_crosstalk_fraction,
            overflow_transfer_fraction: sensor.bloom_overflow_transfer_fraction,
        },
    };
    if sensor.validate().is_err() {
        unsafe { set_error(error_message, b"invalid sensor/noise snapshot\0") };
        return std::ptr::null_mut();
    }
    let development = CameraDevelopment {
        white_balance: LinearRgb::new(
            parameters.raw_develop.white_balance[0],
            parameters.raw_develop.white_balance[1],
            parameters.raw_develop.white_balance[2],
        ),
        middle_gray_illuminance_seconds: parameters.raw_develop.middle_gray_illuminance_seconds,
        develop_exposure_ev: parameters.raw_develop.develop_exposure_ev,
    };
    let rendering = parameters.camera_rendering_intent;
    let rendering_intent = CameraRenderingIntent {
        exposure_ev: rendering.exposure_ev,
        contrast: rendering.contrast,
        saturation: rendering.saturation,
        temperature_kelvin: rendering.temperature_kelvin,
        tint: rendering.tint,
    };
    let calibration = parameters.radiometric_calibration;
    let radiometric_calibration = CameraRadiometricCalibration {
        base_exposure_index: calibration.base_exposure_index,
        reference_lambertian_reflectance: calibration.reference_lambertian_reflectance,
        reference_illuminance_lux: calibration.reference_illuminance_lux,
        reference_t_stop: calibration.reference_t_stop,
        reference_shutter_seconds: calibration.reference_shutter_seconds,
        effective_sensor_exposure_scale: calibration.effective_sensor_exposure_scale,
        provenance: "Snapshot V2; authored from the selected camera calibration.",
    };
    if cover.validate().is_err()
        || environment.validate().is_err()
        || development.validate().is_err()
        || rendering_intent.validate().is_err()
        || radiometric_calibration.validate().is_err()
    {
        unsafe {
            set_error(
                error_message,
                b"invalid cover/environment/development snapshot\0",
            )
        };
        return std::ptr::null_mut();
    }
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenPhysicalPipelineSnapshot {
        cover,
        environment,
        scene_geometry_lens,
        lens_evaluation_model,
        shutter_motion,
        computational_capture,
        sensor,
        development,
        rendering_intent,
        radiometric_calibration,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_pipeline_snapshot_release(
    snapshot: *mut ScreenPhysicalPipelineSnapshot,
) {
    if !snapshot.is_null() {
        // SAFETY: the ABI requires the uniquely owned snapshot returned by create.
        unsafe { drop(Box::from_raw(snapshot)) };
    }
}

fn cover_parameters(
    authority: CoverGlassPresetAuthority,
    profile: CoverGlassProfile,
) -> ScreenCoverGlassParametersV2 {
    ScreenCoverGlassParametersV2 {
        abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
        authority: match authority {
            CoverGlassPresetAuthority::GenericApproximation => 0,
            CoverGlassPresetAuthority::PublishedCategoryApproximation => 1,
        },
        character_strength: profile.character_strength,
        thickness_millimeters: profile.thickness_millimeters,
        refractive_index: profile.refractive_index,
        anti_reflective_efficiency: profile.anti_reflective_efficiency,
        absorption_per_millimeter: [
            profile.absorption_per_millimeter.r,
            profile.absorption_per_millimeter.g,
            profile.absorption_per_millimeter.b,
        ],
        roughness: profile.roughness,
        haze: profile.haze,
        ag_microtexture_character_strength: profile.anti_glare_microtexture.character_strength,
        ag_microtexture_rms_slope: profile.anti_glare_microtexture.rms_slope,
        ag_microtexture_correlation_length_micrometers: profile
            .anti_glare_microtexture
            .correlation_length_micrometers,
        ag_microtexture_anisotropy: profile.anti_glare_microtexture.anisotropy,
        ag_microtexture_seed: profile.anti_glare_microtexture.seed,
        glow_character_strength: profile.glow.character_strength,
        glow_scatter_fraction: profile.glow.scatter_fraction,
        glow_core_radius_millimeters: profile.glow.core_radius_millimeters,
        glow_tail_radius_millimeters: profile.glow.tail_radius_millimeters,
        glow_tail_fraction: profile.glow.tail_fraction,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_count() -> usize {
    DEVICE_PRESETS.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_capture_preset_count() -> usize {
    CAPTURE_DEVICE_PRESETS.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_capture_preset_id(index: usize) -> ScreenUtf8View {
    CAPTURE_DEVICE_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| utf8_view(preset.id))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_capture_preset_label(index: usize) -> ScreenUtf8View {
    CAPTURE_DEVICE_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| utf8_view(preset.label))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_capture_preset_calibration(index: usize) -> ScreenUtf8View {
    CAPTURE_DEVICE_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| utf8_view(preset.calibration))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_capture_preset_default_lens_id(index: usize) -> ScreenUtf8View {
    CAPTURE_DEVICE_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| {
            utf8_view(preset.default_lens_preset_id)
        })
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_capture_preset_compatible_lens_count(index: usize) -> usize {
    CAPTURE_DEVICE_PRESETS
        .get(index)
        .map_or(0, |preset| preset.compatible_lens_preset_ids.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_capture_preset_compatible_lens_id(
    index: usize,
    lens_index: usize,
) -> ScreenUtf8View {
    CAPTURE_DEVICE_PRESETS
        .get(index)
        .and_then(|preset| preset.compatible_lens_preset_ids.get(lens_index))
        .map_or(utf8_view(""), |id| utf8_view(id))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_capture_preset_parameters(
    index: usize,
    parameters: *mut ScreenCapturePresetParametersV4,
) -> bool {
    let Some(preset) = CAPTURE_DEVICE_PRESETS.get(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    let sensor = preset.sensor;
    unsafe {
        *parameters = ScreenCapturePresetParametersV4 {
            abi_version: SCREEN_AUTHORING_CATALOG_ABI_VERSION,
            sensor: ScreenSensorNoiseParametersV2 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                native_width: u32::from(sensor.native_width),
                native_height: u32::from(sensor.native_height),
                bayer_pattern: match sensor.bayer_pattern {
                    BayerPattern::Rggb => 0,
                    BayerPattern::Bggr => 1,
                    BayerPattern::Grbg => 2,
                    BayerPattern::Gbrg => 3,
                },
                acescg_to_sensor: [
                    sensor.acescg_to_sensor[0][0],
                    sensor.acescg_to_sensor[0][1],
                    sensor.acescg_to_sensor[0][2],
                    sensor.acescg_to_sensor[1][0],
                    sensor.acescg_to_sensor[1][1],
                    sensor.acescg_to_sensor[1][2],
                    sensor.acescg_to_sensor[2][0],
                    sensor.acescg_to_sensor[2][1],
                    sensor.acescg_to_sensor[2][2],
                ],
                saturation_illuminance_seconds: [
                    sensor.saturation_illuminance_seconds.r,
                    sensor.saturation_illuminance_seconds.g,
                    sensor.saturation_illuminance_seconds.b,
                ],
                full_well_electrons: sensor.full_well_electrons,
                dark_current_electrons_per_second: sensor.dark_current_electrons_per_second,
                read_noise_electrons_rms: sensor.read_noise_electrons_rms,
                analog_gain: sensor.analog_gain,
                adc_bits: u32::from(sensor.adc_bits),
                bloom_character_strength: sensor.bloom.character_strength,
                bloom_crosstalk_fraction: sensor.bloom.crosstalk_fraction,
                bloom_overflow_transfer_fraction: sensor.bloom.overflow_transfer_fraction,
            },
            computational_capture: ScreenComputationalCaptureParametersV3 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                exposure_count: u32::from(preset.computational_capture.exposure_count),
                bracket_spacing_stops: preset.computational_capture.bracket_spacing_stops,
            },
            camera_rendering_intent: ScreenCameraRenderingIntentParametersV1 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                exposure_ev: preset.rendering_intent.exposure_ev,
                contrast: preset.rendering_intent.contrast,
                saturation: preset.rendering_intent.saturation,
                temperature_kelvin: preset.rendering_intent.temperature_kelvin,
                tint: preset.rendering_intent.tint,
            },
            gate_width_millimeters: preset.gate_width.0,
            gate_height_millimeters: preset.gate_height.0,
            default_f_stop: preset.f_stop,
            reference_exposure_index: preset.reference_exposure_index,
            middle_gray_illuminance_seconds: preset.middle_gray_illuminance_seconds_at_reference_ei,
            default_shutter_angle_degrees: preset.default_shutter_angle_degrees,
            default_temporal_samples: preset.default_temporal_samples,
            lens_association_policy: match preset.lens_association_policy {
                screen_application::LensAssociationPolicy::Interchangeable => 0,
                screen_application::LensAssociationPolicy::Fixed => 1,
            },
            default_readout_duration_milliseconds: preset.default_readout_duration_milliseconds,
            radiometric_calibration: ScreenCameraRadiometricCalibrationV2 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                base_exposure_index: preset.radiometric_calibration.base_exposure_index,
                reference_lambertian_reflectance: preset
                    .radiometric_calibration
                    .reference_lambertian_reflectance,
                reference_illuminance_lux: preset.radiometric_calibration.reference_illuminance_lux,
                reference_t_stop: preset.radiometric_calibration.reference_t_stop,
                reference_shutter_seconds: preset.radiometric_calibration.reference_shutter_seconds,
                effective_sensor_exposure_scale: preset
                    .radiometric_calibration
                    .effective_sensor_exposure_scale,
            },
            raster_modes: preset.raster_modes.map(|mode| ScreenCaptureRasterModeV1 {
                id: utf8_view(mode.id),
                label: utf8_view(mode.label),
                width: u32::from(mode.width),
                height: u32::from(mode.height),
            }),
            default_raster_mode_id: utf8_view(preset.default_raster_mode_id),
            default_lens_evaluation_model: match preset.default_lens_evaluation_model {
                screen_application::LensEvaluationModel::ThinLens => 0,
                screen_application::LensEvaluationModel::VfxDepthBlur => 1,
            },
        };
    }
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_lens_preset_count() -> usize {
    LENS_PRESETS.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_lens_preset_id(index: usize) -> ScreenUtf8View {
    LENS_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| utf8_view(preset.id))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_lens_preset_label(index: usize) -> ScreenUtf8View {
    LENS_PRESETS
        .get(index)
        .map_or(utf8_view(""), |preset| utf8_view(preset.label))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_lens_preset_authority(index: usize) -> u32 {
    LENS_PRESETS
        .get(index)
        .map_or(u32::MAX, |preset| match preset.authority {
            LensPresetAuthority::GenericApproximation => 0,
            LensPresetAuthority::CalibratedApproximation => 1,
        })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_lens_preset_parameters(
    index: usize,
    parameters: *mut ScreenLensPresetParametersV1,
) -> bool {
    let Some(preset) = LENS_PRESETS.get(index) else {
        return false;
    };
    let Some(destination) = (unsafe { parameters.as_mut() }) else {
        return false;
    };
    *destination = ScreenLensPresetParametersV1 {
        abi_version: SCREEN_AUTHORING_CATALOG_ABI_VERSION,
        nominal_focal_length_millimeters: preset.nominal_focal_length.0,
        radial_distortion: preset.lens.radial_distortion,
        tangential_distortion: preset.lens.tangential_distortion,
        longitudinal_chromatic_meters: preset.lens.longitudinal_chromatic_meters,
        lateral_chromatic_scale: preset.lens.lateral_chromatic_scale,
        vignetting_strength: preset.lens.vignetting_strength,
        transmission_rgb: preset.lens.transmission_rgb,
        center_softness_micrometers: preset.lens.center_softness_micrometers,
        edge_softness_micrometers: preset.lens.edge_softness_micrometers,
        veiling_glare_fraction: preset.lens.veiling_glare_fraction,
    };
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_id(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.id))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_label(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.label))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_category(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.category))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_white_basis(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| utf8_view(preset.white_basis))
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_color_mode_count(index: usize) -> usize {
    preset_at(index).map_or(0, |preset| preset.color_mode_ids.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_color_mode_id(
    index: usize,
    color_mode_index: usize,
) -> ScreenUtf8View {
    preset_at(index)
        .and_then(|preset| preset.color_mode_ids.get(color_mode_index).copied())
        .map_or(utf8_view(""), utf8_view)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_default_color_mode_id(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| {
        utf8_view(preset.default_color_mode_id)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_minimum_white_nits(index: usize) -> f32 {
    preset_at(index).map_or(0.0, |preset| preset.minimum_white_nits)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_maximum_white_nits(index: usize) -> f32 {
    preset_at(index).map_or(0.0, |preset| preset.maximum_white_nits)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_white_step_nits(index: usize) -> f32 {
    preset_at(index).map_or(0.0, |preset| preset.white_step_nits)
}

#[unsafe(no_mangle)]
pub extern "C" fn screen_device_preset_default_cover_id(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| {
        utf8_view(preset.default_cover_glass_preset_id)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_preset_parameters(
    index: usize,
    parameters: *mut ScreenDeviceParametersV3,
) -> bool {
    let Some(preset) = preset_at(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    // SAFETY: the caller provided a writable current-version parameter structure.
    unsafe {
        *parameters = parameters_from_profile(
            preset.profile(),
            preset.panel_technology,
            preset.uniformity,
            preset.light_spread,
        )
    };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_create(
    parameters: *const ScreenDeviceParametersV3,
    error_message: *mut *const c_char,
) -> *mut ScreenDeviceProfile {
    if parameters.is_null() {
        unsafe { set_error(error_message, b"missing device parameters\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null parameters pointer is valid for this call.
    let parameters = unsafe { *parameters };
    let (profile, uniformity, light_spread) = match profile_from_parameters(parameters) {
        Ok(profile) => profile,
        Err(message) => {
            unsafe { set_error(error_message, message) };
            return std::ptr::null_mut();
        }
    };
    if profile.evaluator().is_err() {
        unsafe { set_error(error_message, b"invalid physical device evaluator\0") };
        return std::ptr::null_mut();
    }
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenDeviceProfile {
        profile,
        uniformity,
        light_spread,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_release(profile: *mut ScreenDeviceProfile) {
    if !profile.is_null() {
        // SAFETY: the ABI requires the uniquely owned handle returned by create.
        unsafe { drop(Box::from_raw(profile)) };
    }
}

fn parameters_from_profile(
    profile: LcdProfile,
    technology: PanelTechnology,
    uniformity: PanelUniformityProfile,
    light_spread: PanelLightSpreadProfile,
) -> ScreenDeviceParametersV3 {
    ScreenDeviceParametersV3 {
        abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
        native_width: profile.native_width,
        native_height: profile.native_height,
        panel_technology: match technology {
            PanelTechnology::IpsLcd => 0,
        },
        stripe_layout: match profile.stripe_layout {
            StripeLayout::Rgb => 0,
            StripeLayout::Bgr => 1,
        },
        active_width_meters: profile.active_width.0,
        active_height_meters: profile.active_height.0,
        black_matrix_fraction: profile.black_matrix_fraction,
        eotf_gamma: profile.eotf_gamma,
        black_level_nits: profile.black_level_nits,
        white_level_nits: profile.white_level_nits,
        primary_xy: [
            profile.colorimetry.red.x,
            profile.colorimetry.red.y,
            profile.colorimetry.green.x,
            profile.colorimetry.green.y,
            profile.colorimetry.blue.x,
            profile.colorimetry.blue.y,
        ],
        white_xy: [profile.colorimetry.white.x, profile.colorimetry.white.y],
        angular_emission_power: [
            profile.angular_emission_power.r,
            profile.angular_emission_power.g,
            profile.angular_emission_power.b,
        ],
        uniformity_character_strength: uniformity.character_strength,
        uniformity_seed: uniformity.seed,
        uniformity_broad_luminance_peak_to_peak: uniformity.broad_luminance_peak_to_peak,
        uniformity_mid_luminance_peak_to_peak: uniformity.mid_luminance_peak_to_peak,
        uniformity_fine_luminance_peak_to_peak: uniformity.fine_luminance_peak_to_peak,
        uniformity_chromatic_peak_to_peak: uniformity.chromatic_peak_to_peak,
        uniformity_mid_scale_millimeters: uniformity.mid_scale_millimeters,
        uniformity_fine_scale_millimeters: uniformity.fine_scale_millimeters,
        uniformity_low_drive_emphasis: uniformity.low_drive_emphasis,
        light_spread_character_strength: light_spread.character_strength,
        light_spread_core_radius_micrometers: [
            light_spread.core_radius_micrometers.r,
            light_spread.core_radius_micrometers.g,
            light_spread.core_radius_micrometers.b,
        ],
        light_spread_core_weight: [
            light_spread.core_weight.r,
            light_spread.core_weight.g,
            light_spread.core_weight.b,
        ],
        light_spread_tail_radius_micrometers: [
            light_spread.tail_radius_micrometers.r,
            light_spread.tail_radius_micrometers.g,
            light_spread.tail_radius_micrometers.b,
        ],
        light_spread_tail_weight: [
            light_spread.tail_weight.r,
            light_spread.tail_weight.g,
            light_spread.tail_weight.b,
        ],
        residual_period_numerator: profile
            .temporal_emission
            .residual_flicker
            .period
            .numerator(),
        residual_period_denominator: profile
            .temporal_emission
            .residual_flicker
            .period
            .denominator(),
        residual_amplitude: profile.temporal_emission.residual_flicker.amplitude,
        residual_phase_numerator: profile.temporal_emission.residual_flicker.phase.numerator(),
        residual_phase_denominator: profile
            .temporal_emission
            .residual_flicker
            .phase
            .denominator(),
        banding_period_numerator: profile
            .temporal_emission
            .analytic_banding
            .period
            .numerator(),
        banding_period_denominator: profile
            .temporal_emission
            .analytic_banding
            .period
            .denominator(),
        banding_on_numerator: profile
            .temporal_emission
            .analytic_banding
            .on_duration
            .numerator(),
        banding_on_denominator: profile
            .temporal_emission
            .analytic_banding
            .on_duration
            .denominator(),
        banding_phase_numerator: profile.temporal_emission.analytic_banding.phase.numerator(),
        banding_phase_denominator: profile
            .temporal_emission
            .analytic_banding
            .phase
            .denominator(),
        banding_amount: profile.temporal_emission.analytic_banding.amount,
    }
}

fn profile_from_parameters(
    parameters: ScreenDeviceParametersV3,
) -> Result<(LcdProfile, PanelUniformityProfile, PanelLightSpreadProfile), &'static [u8]> {
    if parameters.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION {
        return Err(b"unsupported device parameter ABI\0");
    }
    if parameters.panel_technology != 0 {
        return Err(b"unsupported panel technology\0");
    }
    let stripe_layout = match parameters.stripe_layout {
        0 => StripeLayout::Rgb,
        1 => StripeLayout::Bgr,
        _ => return Err(b"unsupported subpixel layout\0"),
    };
    let time = |numerator, denominator| {
        RationalTime::new(numerator, denominator).map_err(|_| b"invalid device exact time\0" as _)
    };
    let profile = LcdProfile {
        native_width: parameters.native_width,
        native_height: parameters.native_height,
        active_width: Meters(parameters.active_width_meters),
        active_height: Meters(parameters.active_height_meters),
        stripe_layout,
        black_matrix_fraction: parameters.black_matrix_fraction,
        eotf_gamma: parameters.eotf_gamma,
        black_level_nits: parameters.black_level_nits,
        white_level_nits: parameters.white_level_nits,
        colorimetry: PanelColorimetry {
            red: Chromaticity {
                x: parameters.primary_xy[0],
                y: parameters.primary_xy[1],
            },
            green: Chromaticity {
                x: parameters.primary_xy[2],
                y: parameters.primary_xy[3],
            },
            blue: Chromaticity {
                x: parameters.primary_xy[4],
                y: parameters.primary_xy[5],
            },
            white: Chromaticity {
                x: parameters.white_xy[0],
                y: parameters.white_xy[1],
            },
        },
        angular_emission_power: LinearRgb::new(
            parameters.angular_emission_power[0],
            parameters.angular_emission_power[1],
            parameters.angular_emission_power[2],
        ),
        temporal_emission: PanelTemporalEmission {
            residual_flicker: ResidualFlicker {
                period: time(
                    parameters.residual_period_numerator,
                    parameters.residual_period_denominator,
                )?,
                amplitude: parameters.residual_amplitude,
                phase: time(
                    parameters.residual_phase_numerator,
                    parameters.residual_phase_denominator,
                )?,
            },
            analytic_banding: AnalyticBanding {
                period: time(
                    parameters.banding_period_numerator,
                    parameters.banding_period_denominator,
                )?,
                on_duration: time(
                    parameters.banding_on_numerator,
                    parameters.banding_on_denominator,
                )?,
                phase: time(
                    parameters.banding_phase_numerator,
                    parameters.banding_phase_denominator,
                )?,
                amount: parameters.banding_amount,
            },
        },
    };
    let light_spread = PanelLightSpreadProfile {
        character_strength: parameters.light_spread_character_strength,
        core_radius_micrometers: LinearRgb::new(
            parameters.light_spread_core_radius_micrometers[0],
            parameters.light_spread_core_radius_micrometers[1],
            parameters.light_spread_core_radius_micrometers[2],
        ),
        core_weight: LinearRgb::new(
            parameters.light_spread_core_weight[0],
            parameters.light_spread_core_weight[1],
            parameters.light_spread_core_weight[2],
        ),
        tail_radius_micrometers: LinearRgb::new(
            parameters.light_spread_tail_radius_micrometers[0],
            parameters.light_spread_tail_radius_micrometers[1],
            parameters.light_spread_tail_radius_micrometers[2],
        ),
        tail_weight: LinearRgb::new(
            parameters.light_spread_tail_weight[0],
            parameters.light_spread_tail_weight[1],
            parameters.light_spread_tail_weight[2],
        ),
    }
    .validate()
    .map_err(|_| b"invalid panel light spread profile\0" as &'static [u8])?;
    let uniformity = PanelUniformityProfile {
        character_strength: parameters.uniformity_character_strength,
        seed: parameters.uniformity_seed,
        broad_luminance_peak_to_peak: parameters.uniformity_broad_luminance_peak_to_peak,
        mid_luminance_peak_to_peak: parameters.uniformity_mid_luminance_peak_to_peak,
        fine_luminance_peak_to_peak: parameters.uniformity_fine_luminance_peak_to_peak,
        chromatic_peak_to_peak: parameters.uniformity_chromatic_peak_to_peak,
        mid_scale_millimeters: parameters.uniformity_mid_scale_millimeters,
        fine_scale_millimeters: parameters.uniformity_fine_scale_millimeters,
        low_drive_emphasis: parameters.uniformity_low_drive_emphasis,
    }
    .validate()
    .map_err(|_| b"invalid panel uniformity profile\0" as &'static [u8])?;
    let profile = profile
        .validate()
        .map_err(|_| b"invalid physical device profile\0" as &'static [u8])?;
    Ok((profile, uniformity, light_spread))
}

const PROCEDURAL_WIDTH: u32 = 960;
const PROCEDURAL_HEIGHT: u32 = 540;
const EMBEDDED_WIDTH: u32 = 3_840;
const EMBEDDED_HEIGHT: u32 = 2_160;

const EDITORIAL_REFERENCE: &[u8] =
    include_bytes!("../../../apps/screen-desktop/assets/editorial-text-reference.png");
const CAMERA_REFERENCE: &[u8] =
    include_bytes!("../../../apps/screen-desktop/assets/camera-color-reference.png");
const FREQUENCY_REFERENCE: &[u8] =
    include_bytes!("../../../apps/screen-desktop/assets/frequency-moire-reference.png");
const VFX_COMPARISON_REFERENCE: &[u8] =
    include_bytes!("../../../apps/screen-desktop/assets/vfx-comparison-reference.png");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_pattern_dimensions(
    pattern: u32,
    width: *mut u32,
    height: *mut u32,
) -> bool {
    if width.is_null() || height.is_null() || pattern > 6 {
        return false;
    }
    let (resolved_width, resolved_height) = match pattern {
        2..=4 | 6 => (EMBEDDED_WIDTH, EMBEDDED_HEIGHT),
        _ => (PROCEDURAL_WIDTH, PROCEDURAL_HEIGHT),
    };
    // SAFETY: both output pointers were validated and belong to the caller.
    unsafe {
        *width = resolved_width;
        *height = resolved_height;
    }
    true
}

/// Renders the exact seven test-pattern choices exposed by the current Slint shell.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_pattern_render_rgba32f(
    pattern: u32,
    time_seconds: f64,
    pixels: *mut c_float,
    pixel_count: usize,
    error_message: *mut *const c_char,
) -> bool {
    static INVALID: &[u8] = b"invalid SCREEN test-pattern request\0";
    static DECODE: &[u8] = b"bundled SCREEN test-pattern PNG is invalid\0";
    let mut width = 0;
    let mut height = 0;
    if !unsafe { screen_test_pattern_dimensions(pattern, &mut width, &mut height) }
        || pixels.is_null()
        || pixel_count != width as usize * height as usize
        || !time_seconds.is_finite()
    {
        unsafe { set_error(error_message, INVALID) };
        return false;
    }
    let output = unsafe { std::slice::from_raw_parts_mut(pixels, pixel_count * 4) };
    if let Some(encoded) = match pattern {
        2 => Some(EDITORIAL_REFERENCE),
        3 => Some(CAMERA_REFERENCE),
        4 => Some(FREQUENCY_REFERENCE),
        6 => Some(VFX_COMPARISON_REFERENCE),
        _ => None,
    } {
        let Ok(decoded) = image::load_from_memory_with_format(encoded, image::ImageFormat::Png)
            .map(image::DynamicImage::into_rgb8)
        else {
            unsafe { set_error(error_message, DECODE) };
            return false;
        };
        if decoded.dimensions() != (width, height) {
            unsafe { set_error(error_message, DECODE) };
            return false;
        }
        for (target, source) in output.chunks_exact_mut(4).zip(decoded.pixels()) {
            target[0] = f32::from(source[0]) / 255.0;
            target[1] = f32::from(source[1]) / 255.0;
            target[2] = f32::from(source[2]) / 255.0;
            target[3] = 1.0;
        }
    } else {
        let procedural = match pattern {
            0 => ProceduralTestPattern::AnimatedCheckerboard,
            1 => ProceduralTestPattern::EyeChart,
            5 => ProceduralTestPattern::PhotometricDeviceScale,
            _ => unreachable!(),
        };
        let time = RationalTime::new((time_seconds * 1_000_000.0).round() as i64, 1_000_000)
            .expect("fixed non-zero time denominator");
        for y in 0..height {
            for x in 0..width {
                let uv = Vec2 {
                    x: x as f32 / (width - 1) as f32,
                    y: y as f32 / (height - 1) as f32,
                };
                let value = diagnostic_signal(procedural, uv, time);
                let offset = (y as usize * width as usize + x as usize) * 4;
                output[offset] = value.r;
                output[offset + 1] = value.g;
                output[offset + 2] = value.b;
                output[offset + 3] = 1.0;
            }
        }
    }
    unsafe { set_error(error_message, b"\0") };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_delivery_raster_rgba32f(
    input_rgba: *const f32,
    input_width: u32,
    input_height: u32,
    output_rgba: *mut f32,
    output_width: u32,
    output_height: u32,
    placement: u32,
    background: u32,
    error_message: *mut *const c_char,
) -> bool {
    let input_count = input_width as usize * input_height as usize;
    let output_count = output_width as usize * output_height as usize;
    if input_rgba.is_null() || output_rgba.is_null() || input_count == 0 || output_count == 0 {
        unsafe { set_error(error_message, b"invalid Delivery Raster buffers\0") };
        return false;
    }
    let input = unsafe { std::slice::from_raw_parts(input_rgba.cast::<[f32; 4]>(), input_count) };
    let request = DeliveryRasterRequest {
        width: output_width,
        height: output_height,
        placement: match placement {
            0 => DeliveryRasterPlacement::Fit,
            1 => DeliveryRasterPlacement::OneToOne,
            2 => DeliveryRasterPlacement::FillCrop,
            _ => {
                unsafe { set_error(error_message, b"invalid Delivery Raster placement\0") };
                return false;
            }
        },
        background: match background {
            0 => DeliveryRasterBackground::Transparent,
            1 => DeliveryRasterBackground::Black,
            _ => {
                unsafe { set_error(error_message, b"invalid Delivery Raster background\0") };
                return false;
            }
        },
    };
    let Ok(result) = evaluate_delivery_raster_rgba32f(input, input_width, input_height, request)
    else {
        unsafe { set_error(error_message, b"Delivery Raster evaluation failed\0") };
        return false;
    };
    let output =
        unsafe { std::slice::from_raw_parts_mut(output_rgba.cast::<[f32; 4]>(), output_count) };
    output.copy_from_slice(&result);
    unsafe { set_error(error_message, b"\0") };
    true
}

/// Color-owned ACEScg -> recording-output-signal-v2 CPU reference boundary.
/// The caller owns both buffers and supplies exact stable transform identity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_recording_output_transform_rgba32f(
    transform_id: ScreenUtf8View,
    input_rgba: *const f32,
    output_rgba: *mut f32,
    width: u32,
    height: u32,
    error_message: *mut *const c_char,
) -> bool {
    let Some(transform_id) = (unsafe { borrowed_utf8(transform_id) }) else {
        unsafe { set_error(error_message, b"invalid Recording Output transform UTF-8\0") };
        return false;
    };
    let Some(transform) = RecordingOutputTransform::from_stable_id(transform_id) else {
        unsafe { set_error(error_message, b"unknown Recording Output transform\0") };
        return false;
    };
    let Some(pixel_count) = usize::try_from(width).ok().and_then(|width| {
        usize::try_from(height)
            .ok()
            .and_then(|height| width.checked_mul(height))
    }) else {
        unsafe { set_error(error_message, b"invalid Recording Output raster\0") };
        return false;
    };
    let Some(component_count) = pixel_count.checked_mul(4) else {
        unsafe { set_error(error_message, b"invalid Recording Output raster\0") };
        return false;
    };
    if width == 0 || height == 0 || input_rgba.is_null() || output_rgba.is_null() {
        unsafe { set_error(error_message, b"missing Recording Output raster\0") };
        return false;
    }
    let input = unsafe { std::slice::from_raw_parts(input_rgba, component_count) };
    let pixels = input
        .chunks_exact(4)
        .map(|value| LinearRgb::new(value[0], value[1], value[2]))
        .collect::<Vec<_>>();
    let result = ColorEngine::bundled()
        .and_then(|engine| engine.recording_output_processor(transform))
        .and_then(|processor| processor.apply_acescg_raster(width, height, &pixels));
    let signal = match result {
        Ok(signal) => signal,
        Err(_) => {
            unsafe { set_error(error_message, b"Recording Output transform failed\0") };
            return false;
        }
    };
    let output = unsafe { std::slice::from_raw_parts_mut(output_rgba, component_count) };
    for (destination, source) in output.chunks_exact_mut(4).zip(signal.rgba) {
        destination.copy_from_slice(&source);
    }
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_recording_output_inverse_rgba32f(
    transform_id: ScreenUtf8View,
    rgba: *mut f32,
    width: u32,
    height: u32,
    error_message: *mut *const c_char,
) -> bool {
    let Some(transform_id) = (unsafe { borrowed_utf8(transform_id) }) else {
        unsafe { set_error(error_message, b"invalid Recording Output transform UTF-8\0") };
        return false;
    };
    let Some(transform) = RecordingOutputTransform::from_stable_id(transform_id) else {
        unsafe { set_error(error_message, b"unknown Recording Output transform\0") };
        return false;
    };
    let Some(pixel_count) = usize::try_from(width).ok().and_then(|width| {
        usize::try_from(height)
            .ok()
            .and_then(|height| width.checked_mul(height))
    }) else {
        unsafe { set_error(error_message, b"invalid decoded Recording raster\0") };
        return false;
    };
    if width == 0 || height == 0 || rgba.is_null() {
        unsafe { set_error(error_message, b"missing decoded Recording raster\0") };
        return false;
    }
    let storage = unsafe { std::slice::from_raw_parts_mut(rgba, pixel_count * 4) };
    let mut pixels = storage
        .chunks_exact(4)
        .map(|pixel| [pixel[0], pixel[1], pixel[2], pixel[3]])
        .collect::<Vec<_>>();
    let result = ColorEngine::bundled()
        .and_then(|engine| engine.recording_output_inverse_processor(transform))
        .and_then(|processor| processor.apply_rgba(&mut pixels));
    if result.is_err() {
        unsafe { set_error(error_message, b"Recording Output inverse failed\0") };
        return false;
    }
    for (destination, source) in storage.chunks_exact_mut(4).zip(pixels) {
        destination.copy_from_slice(&source);
    }
    true
}

/// Compiles a typed reflection-light rig into a caller-owned 2:1 linear ACEScg raster.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_reflection_environment_compile_rgba32f(
    emitters: *const ScreenReflectionEmitterV2,
    emitter_count: usize,
    output_rgba: *mut f32,
    width: u32,
    height: u32,
    error_message: *mut *const c_char,
) -> bool {
    unsafe { set_error(error_message, b"\0") };
    if emitters.is_null() || emitter_count == 0 || output_rgba.is_null() {
        unsafe { set_error(error_message, b"reflection environment input is missing\0") };
        return false;
    }
    let raw = unsafe { std::slice::from_raw_parts(emitters, emitter_count) };
    let mut resolved = Vec::with_capacity(raw.len());
    for emitter in raw {
        if emitter.abi_version != SCREEN_REFLECTION_ENVIRONMENT_ABI_VERSION {
            unsafe {
                set_error(
                    error_message,
                    b"reflection environment ABI version is unsupported\0",
                )
            };
            return false;
        }
        let direction = |index: usize| Vec3 {
            x: emitter.directions_xyz[index * 3],
            y: emitter.directions_xyz[index * 3 + 1],
            z: emitter.directions_xyz[index * 3 + 2],
        };
        let appearance = ReflectionLightAppearance {
            radiance_candelas_per_square_meter: emitter.radiance_candelas_per_square_meter,
            temperature_kelvin: emitter.temperature_kelvin,
            tint: emitter.tint,
            edge_softness_degrees: emitter.edge_softness_degrees,
        };
        resolved.push(match emitter.kind {
            0 => ReflectionEmitter::Practical(ReflectionPracticalLight {
                center_direction: direction(0),
                angular_diameter_degrees: emitter.angular_diameter_degrees,
                distance_meters: emitter.distance_meters,
                appearance,
            }),
            1 => ReflectionEmitter::Window(ReflectionWindowLight {
                corner_directions: [direction(0), direction(1), direction(2), direction(3)],
                distance_meters: emitter.distance_meters,
                appearance,
            }),
            2 => ReflectionEmitter::Sun(ReflectionSunLight {
                direction: direction(0),
                angular_diameter_degrees: emitter.angular_diameter_degrees,
                appearance,
            }),
            _ => {
                unsafe { set_error(error_message, b"reflection emitter kind is unsupported\0") };
                return false;
            }
        });
    }
    let rig = ReflectionEnvironmentRig {
        emitters: resolved,
        background_radiance_acescg: LinearRgb::new(0.0, 0.0, 0.0),
    };
    let raster = match compile_reflection_environment(&rig, width, height) {
        Ok(value) => value,
        Err(_) => {
            unsafe { set_error(error_message, b"reflection environment rig is invalid\0") };
            return false;
        }
    };
    let component_count = raster.rgba_acescg.len() * 4;
    let output = unsafe { std::slice::from_raw_parts_mut(output_rgba, component_count) };
    for (destination, source) in output.chunks_exact_mut(4).zip(raster.rgba_acescg) {
        destination.copy_from_slice(&source);
    }
    true
}

unsafe fn set_error(destination: *mut *const c_char, message: &'static [u8]) {
    if !destination.is_null() {
        // SAFETY: the optional out parameter is writable for the call.
        unsafe {
            *destination = if message.len() == 1 {
                std::ptr::null()
            } else {
                message.as_ptr().cast()
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reflection_environment_bridge_compiles_typed_emitters_and_rejects_old_abi() {
        let emitter = ScreenReflectionEmitterV2 {
            abi_version: SCREEN_REFLECTION_ENVIRONMENT_ABI_VERSION,
            kind: 0,
            directions_xyz: [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            angular_diameter_degrees: 12.0,
            distance_meters: 2.0,
            radiance_candelas_per_square_meter: 1_000.0,
            temperature_kelvin: 3_200.0,
            tint: 0.0,
            edge_softness_degrees: 0.5,
        };
        let mut pixels = vec![0.0_f32; 64 * 32 * 4];
        let mut error = core::ptr::null();
        assert!(unsafe {
            screen_reflection_environment_compile_rgba32f(
                &emitter,
                1,
                pixels.as_mut_ptr(),
                64,
                32,
                &mut error,
            )
        });
        assert!(
            pixels
                .iter()
                .all(|value| value.is_finite() && *value >= 0.0)
        );
        assert!(
            pixels
                .chunks_exact(4)
                .any(|pixel| pixel[0] > 0.0 || pixel[1] > 0.0 || pixel[2] > 0.0)
        );

        let mut obsolete = emitter;
        obsolete.abi_version -= 1;
        assert!(!unsafe {
            screen_reflection_environment_compile_rgba32f(
                &obsolete,
                1,
                pixels.as_mut_ptr(),
                64,
                32,
                &mut error,
            )
        });
    }

    #[test]
    fn planar_reference_bridge_returns_only_a_rigid_camera_pose() {
        let request = ScreenPlanarReferenceMatchV1 {
            abi_version: SCREEN_PLANAR_REFERENCE_MATCH_ABI_VERSION,
            device_corners_xyz: [
                -0.36, 0.20, 0.0, 0.36, 0.20, 0.0, 0.36, -0.20, 0.0, -0.36, -0.20, 0.0,
            ],
            image_corners_xy: [479.5, 269.5, 1439.5, 269.5, 1439.5, 809.5, 479.5, 809.5],
            image_width: 1920,
            image_height: 1080,
            focal_length_millimeters: 50.0,
            sensor_width_millimeters: 36.0,
            sensor_height_millimeters: 20.0,
            lens_shift_xy: [0.0, 0.0],
        };
        let mut result = ScreenMatchedCameraPoseV1 {
            camera_position: [0.0; 3],
            camera_rotation_xyzw: [0.0; 4],
            maximum_reprojection_error_pixels: f32::INFINITY,
        };
        let mut error = core::ptr::null();
        assert!(unsafe {
            screen_geometry_solve_planar_reference_v1(&request, &mut result, &mut error)
        });
        assert!(result.maximum_reprojection_error_pixels < 1.0e-3);
        assert!(result.camera_position[2] > 0.0);

        let mut invalid = request;
        invalid.abi_version = SCREEN_PLANAR_REFERENCE_MATCH_ABI_VERSION + 1;
        assert!(!unsafe {
            screen_geometry_solve_planar_reference_v1(&invalid, &mut result, &mut error)
        });
    }

    #[cfg(target_os = "macos")]
    fn metal_texture(values: &[[f32; 4]], width: u32, height: u32) -> metal::Texture {
        use metal::{MTLPixelFormat, MTLRegion, TextureDescriptor};
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(metal::MTLTextureType::D2);
        descriptor.set_pixel_format(MTLPixelFormat::RGBA32Float);
        descriptor.set_width(u64::from(width));
        descriptor.set_height(u64::from(height));
        descriptor.set_storage_mode(metal::MTLStorageMode::Shared);
        descriptor.set_usage(metal::MTLTextureUsage::ShaderRead);
        let texture = device.new_texture(&descriptor);
        texture.replace_region(
            MTLRegion::new_2d(0, 0, u64::from(width), u64::from(height)),
            0,
            values.as_ptr().cast(),
            u64::from(width) * core::mem::size_of::<[f32; 4]>() as u64,
        );
        texture
    }

    fn contributions() -> [ScreenPhysicalStageContributionV3; 16] {
        core::array::from_fn(|index| ScreenPhysicalStageContributionV3 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            stage_id: PHYSICAL_STAGE_DESCRIPTORS[index].stage as u32,
            amount: if index < 4 { 1.0 } else { 0.0 },
            discrete_enabled: false,
        })
    }

    #[test]
    fn physical_stage_descriptors_are_published_from_application_authority() {
        assert_eq!(screen_physical_stage_descriptor_count(), 16);
        for (index, expected) in PHYSICAL_STAGE_DESCRIPTORS.iter().enumerate() {
            let mut actual = ScreenPhysicalStageDescriptorV1 {
                abi_version: 0,
                domain_id: 0,
                stage_id: 0,
                control_semantics: 0,
                visual_minimum: 0.0,
                visual_maximum: 0.0,
                safe_maximum: 0.0,
                exact_identity_at_zero: false,
                general_overview: false,
            };
            assert!(unsafe { screen_physical_stage_descriptor(index, &mut actual) });
            assert_eq!(actual.abi_version, SCREEN_PHYSICAL_FRAME_ABI_VERSION);
            assert_eq!(actual.domain_id, expected.domain as u32);
            assert_eq!(actual.stage_id, expected.stage as u32);
            assert_eq!(actual.control_semantics, expected.control_semantics as u32);
            assert_eq!(actual.visual_minimum, expected.visual_minimum);
            assert_eq!(actual.visual_maximum, expected.visual_maximum);
            assert_eq!(actual.safe_maximum, expected.safe_maximum);
            assert_eq!(
                actual.exact_identity_at_zero,
                expected.exact_identity_at_zero
            );
            assert_eq!(actual.general_overview, expected.general_overview);
        }
    }

    #[test]
    fn scene_geometry_and_environment_keep_independent_stage_amounts() {
        let mut values = contributions();
        values[5].amount = 1.0;
        values[7].amount = 0.0;
        let resolved = contribution_amounts(&values).expect("valid contribution contract");
        assert_eq!(resolved.scene_geometry, 1.0);
        assert_eq!(resolved.environment, 0.0);

        values[5].amount = 0.0;
        values[7].amount = 1.0;
        let resolved = contribution_amounts(&values).expect("valid contribution contract");
        assert_eq!(resolved.scene_geometry, 0.0);
        assert_eq!(resolved.environment, 1.0);
    }

    #[test]
    fn capture_diagnostics_describe_the_effective_requested_checkpoint() {
        let before_sensor =
            effective_capture_checkpoint(PhysicalIntermediate::ShutterMotion, true, 1.0, true);
        assert_eq!(
            before_sensor,
            EffectiveCaptureCheckpoint {
                sensor_enabled: false,
                sensor_noise_amount: 0.0,
                development_enabled: false,
            }
        );

        let collected =
            effective_capture_checkpoint(PhysicalIntermediate::SensorCollection, true, 1.0, true);
        assert_eq!(collected.sensor_noise_amount, 1.0);
        assert!(collected.sensor_enabled);
        assert!(!collected.development_enabled);

        let noisy_raw =
            effective_capture_checkpoint(PhysicalIntermediate::SensorReadoutRaw, true, 1.0, true);
        assert_eq!(noisy_raw.sensor_noise_amount, 1.0);
        assert!(noisy_raw.sensor_enabled);
        assert!(!noisy_raw.development_enabled);

        let developed =
            effective_capture_checkpoint(PhysicalIntermediate::DevelopedAcesCg, true, 1.0, true);
        assert!(developed.development_enabled);
    }

    fn pipeline_parameters() -> ScreenPhysicalPipelineParametersV2 {
        let version = SCREEN_PHYSICAL_FRAME_ABI_VERSION;
        ScreenPhysicalPipelineParametersV2 {
            abi_version: version,
            cover: ScreenCoverGlassParametersV2 {
                abi_version: version,
                authority: 0,
                character_strength: 0.0,
                thickness_millimeters: 1.0,
                refractive_index: 1.5,
                anti_reflective_efficiency: 0.0,
                absorption_per_millimeter: [0.0; 3],
                roughness: 0.0,
                haze: 0.0,
                ag_microtexture_character_strength: 0.0,
                ag_microtexture_rms_slope: 0.0,
                ag_microtexture_correlation_length_micrometers: 1.0,
                ag_microtexture_anisotropy: 0.0,
                ag_microtexture_seed: 0,
                glow_character_strength: 1.0,
                glow_scatter_fraction: 0.03,
                glow_core_radius_millimeters: 0.1,
                glow_tail_radius_millimeters: 1.0,
                glow_tail_fraction: 0.0,
            },
            environment: ScreenEnvironmentParametersV2 {
                abi_version: version,
                source_kind: 0,
                character_strength: 0.0,
                source_unit_radiance_candelas_per_square_meter: 0.0,
                exposure_stops: 0.0,
                ambient_radiance_acescg: [0.0; 3],
                key_radiance_acescg: [0.0; 3],
                key_direction_local: [0.0, 0.0, 1.0],
                key_angular_radius_degrees: 20.0,
                rotation_x_degrees: 0.0,
                rotation_y_degrees: 0.0,
                projection_mode: 0,
                sphere_radius_meters: 5.0,
                pattern: 0,
            },
            scene_geometry_lens: ScreenSceneGeometryLensParametersV2 {
                abi_version: version,
                lens_evaluation_model: 0,
                focal_length_millimeters: 50.0,
                sensor_width_millimeters: 36.0,
                sensor_height_millimeters: 24.0,
                lens_shift: [0.0; 2],
                focus_distance_meters: 1.0,
                f_stop: 2.8,
                near_clip_meters: 0.01,
                far_clip_meters: 100.0,
                lens_radial_distortion: [0.0; 3],
                lens_tangential_distortion: [0.0; 2],
                lens_longitudinal_chromatic_meters: [0.0; 3],
                lens_lateral_chromatic_scale: [1.0; 3],
                lens_vignetting_strength: 0.0,
                lens_transmission_rgb: [1.0; 3],
                lens_center_softness_micrometers: 0.0,
                lens_edge_softness_micrometers: 0.0,
                lens_veiling_glare_fraction: 0.0,
            },
            shutter_motion: ScreenShutterMotionParametersV2 {
                abi_version: version,
                temporal_samples: 1,
                readout_kind: 0,
                readout_duration_numerator: 1,
                readout_duration_denominator: 48,
                readout_direction: 0,
                neutral_density_stops: 0.0,
                noise_seed: 7,
            },
            computational_capture: ScreenComputationalCaptureParametersV3 {
                abi_version: version,
                exposure_count: 1,
                bracket_spacing_stops: 0.0,
            },
            camera_rendering_intent: ScreenCameraRenderingIntentParametersV1 {
                abi_version: version,
                exposure_ev: 0.0,
                contrast: 1.0,
                saturation: 1.0,
                temperature_kelvin: 6_500.0,
                tint: 0.0,
            },
            sensor_noise: ScreenSensorNoiseParametersV2 {
                abi_version: version,
                native_width: 3_840,
                native_height: 2_160,
                bayer_pattern: 0,
                acescg_to_sensor: [0.72, 0.21, 0.07, 0.10, 0.82, 0.08, 0.03, 0.16, 0.81],
                saturation_illuminance_seconds: [2.4; 3],
                full_well_electrons: 45_000.0,
                dark_current_electrons_per_second: 0.1,
                read_noise_electrons_rms: 2.0,
                analog_gain: 1.0,
                adc_bits: 14,
                bloom_character_strength: 1.0,
                bloom_crosstalk_fraction: 0.012,
                bloom_overflow_transfer_fraction: 0.22,
            },
            raw_develop: ScreenRawDevelopParametersV2 {
                abi_version: version,
                white_balance: [1.0; 3],
                middle_gray_illuminance_seconds: 0.18,
                develop_exposure_ev: 0.0,
            },
            radiometric_calibration: ScreenCameraRadiometricCalibrationV2 {
                abi_version: version,
                base_exposure_index: 100.0,
                reference_lambertian_reflectance: 0.18,
                reference_illuminance_lux: 100.0,
                reference_t_stop: 4.0,
                reference_shutter_seconds: 1.0 / 48.0,
                effective_sensor_exposure_scale: 1.0,
            },
        }
    }

    #[test]
    fn pose_tracks_preserve_exact_ordered_rational_knots() {
        let knots = [
            ScreenPhysicalPoseKnotV2 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                time_numerator: -1,
                time_denominator: 48,
                position: [0.0, 0.0, 1.0],
                rotation_xyzw: [0.0, 0.0, 0.0, 1.0],
                interpolation: 1,
            },
            ScreenPhysicalPoseKnotV2 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                time_numerator: 1,
                time_denominator: 48,
                position: [0.25, 0.0, 1.0],
                rotation_xyzw: [0.0, 0.0, 0.0, 1.0],
                interpolation: 1,
            },
        ];
        let track = unsafe {
            screen_physical_camera_pose_track_v2_create(
                knots.as_ptr(),
                knots.len(),
                std::ptr::null_mut(),
            )
        };
        assert!(!track.is_null());
        let midpoint = unsafe { &*track }
            .track
            .sample(RationalTime::new(0, 1).expect("exact midpoint"))
            .expect("sampled pose");
        assert!((midpoint.translation.x - 0.125).abs() <= 1.0e-7);
        unsafe { screen_physical_camera_pose_track_v2_release(track) };
    }

    #[test]
    fn source_sampling_policies_are_exact_floor_and_nearest_with_earlier_ties() {
        let times = [
            RationalTime::new(0, 1).expect("zero"),
            RationalTime::new(1, 24).expect("one frame"),
        ];
        let midpoint = RationalTime::new(1, 48).expect("midpoint");
        assert_eq!(sample_index_for_times(&times, times[1], 0), Some(1));
        assert_eq!(sample_index_for_times(&times, midpoint, 0), None);
        assert_eq!(sample_index_for_times(&times, midpoint, 1), Some(0));
        assert_eq!(sample_index_for_times(&times, midpoint, 2), Some(0));
        assert_eq!(
            sample_index_for_times(&times, RationalTime::new(3, 96).expect("nearer later"), 2,),
            Some(1)
        );
    }

    #[test]
    fn one_pose_knot_is_explicitly_constant_but_multi_knot_trajectory_is_motion() {
        let constant = TransformTrack {
            keyframes: vec![TransformKeyframe {
                id: "constant".to_owned(),
                time: RationalTime::new(0, 1).expect("zero"),
                translation: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 1.0,
                },
                rotation: Quaternion::from_yaw_degrees(0.0),
                interpolation: KeyframeInterpolation::Hold,
            }],
        };
        let mut animated = constant.clone();
        animated.keyframes.push(TransformKeyframe {
            id: "animated".to_owned(),
            time: RationalTime::new(1, 24).expect("one frame"),
            translation: Vec3 {
                x: 0.25,
                y: 0.0,
                z: 1.0,
            },
            rotation: Quaternion::from_orbit_yaw_pitch_degrees(15.0, -5.0),
            interpolation: KeyframeInterpolation::Linear,
        });
        assert!(track_is_constant(&constant));
        assert!(!track_is_constant(&animated));
        assert!(track_covers(
            &constant,
            RationalTime::new(-1, 48).expect("open"),
            RationalTime::new(1, 48).expect("close")
        ));
        assert!(!track_covers(
            &animated,
            RationalTime::new(-1, 48).expect("open"),
            RationalTime::new(1, 48).expect("close")
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn physical_frame_job_executes_metal_and_reports_owned_diagnostics() {
        let source_values = [[-0.25, 0.5, 1.5, 0.25], [1.0, 0.0, 0.2, 0.75]];
        let signal_values = [[0.0, 0.5, 1.5, 1.0], [1.0, -0.2, 0.25, 1.0]];
        let source_texture = metal_texture(&source_values, 2, 1);
        let signal_texture = metal_texture(&signal_values, 2, 1);
        let source = unsafe {
            screen_physical_texture_create_borrowed_metal(
                source_texture.as_ptr().cast(),
                std::ptr::null_mut(),
            )
        };
        let signal = unsafe {
            screen_physical_texture_create_borrowed_metal(
                signal_texture.as_ptr().cast(),
                std::ptr::null_mut(),
            )
        };
        let timed_sample = ScreenPhysicalTimedInputSampleV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            time_numerator: 0,
            time_denominator: 1,
            source_acescg: source,
            device_signal: signal,
        };
        let input = unsafe {
            screen_physical_timed_input_set_v2_create(
                &timed_sample,
                1,
                SCREEN_PHYSICAL_RASTER_STRETCH,
                0,
                std::ptr::null_mut(),
            )
        };
        let camera_knot = ScreenPhysicalPoseKnotV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            time_numerator: 0,
            time_denominator: 1,
            position: [0.0, 0.0, 1.0],
            rotation_xyzw: [0.0, 0.0, 0.0, 1.0],
            interpolation: 0,
        };
        let screen_knot = ScreenPhysicalPoseKnotV2 {
            position: [0.0, 0.0, 0.0],
            ..camera_knot
        };
        let camera_track = unsafe {
            screen_physical_camera_pose_track_v2_create(&camera_knot, 1, std::ptr::null_mut())
        };
        let screen_track = unsafe {
            screen_physical_screen_pose_track_v2_create(&screen_knot, 1, std::ptr::null_mut())
        };
        let mut panel = DEVICE_PRESETS[0].profile();
        panel.native_width = 2;
        panel.native_height = 1;
        panel.active_width = Meters(0.002);
        panel.active_height = Meters(0.001);
        let parameters = parameters_from_profile(
            panel,
            PanelTechnology::IpsLcd,
            PanelUniformityProfile::PROFESSIONAL_COMPENSATED,
            PanelLightSpreadProfile::LCD_DESKTOP,
        );
        let profile = unsafe { screen_device_profile_create(&parameters, std::ptr::null_mut()) };
        let mut pipeline_parameters = pipeline_parameters();
        pipeline_parameters.sensor_noise.native_width = 4;
        pipeline_parameters.sensor_noise.native_height = 2;
        pipeline_parameters.environment.character_strength = 1.0;
        pipeline_parameters.environment.ambient_radiance_acescg = [50.0; 3];
        let pipeline = unsafe {
            screen_physical_pipeline_snapshot_create(&pipeline_parameters, std::ptr::null_mut())
        };
        assert!(!pipeline.is_null());
        let mut contributions = contributions();
        contributions[2].amount = 1.0;
        contributions[3].amount = 1.0;
        contributions[4].amount = 1.0;
        contributions[5].amount = 1.0;
        contributions[7].amount = 1.0;
        contributions[8].amount = 1.0;
        contributions[9].amount = 1.0;
        contributions[10].amount = 1.0;
        contributions[11].amount = 1.0;
        contributions[12].amount = 1.0;
        contributions[13].amount = 1.0;
        contributions[14].discrete_enabled = true;
        contributions[15].discrete_enabled = true;
        assert!(contribution_amounts(&contributions).is_some());
        let identity = ScreenPhysicalIdentity128 { high: 7, low: 9 };
        let mut request = ScreenPhysicalFrameRequestV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            frame_index: 0,
            timed_inputs: input,
            environment_acescg: std::ptr::null(),
            camera_pose_track: camera_track,
            screen_pose_track: screen_track,
            shutter_open_numerator: -1,
            shutter_open_denominator: 96,
            shutter_close_numerator: 1,
            shutter_close_denominator: 96,
            resolved_device: profile,
            resolved_pipeline: pipeline,
            quality: 1,
            screen_amount: 1.0,
            stage_contributions: contributions.as_ptr(),
            stage_contribution_count: contributions.len(),
            requested_width: 4,
            requested_height: 2,
            render_full_width: 4,
            render_full_height: 2,
            render_window_x: 0,
            render_window_y: 0,
            render_window_width: 4,
            render_window_height: 2,
            render_scale_x_numerator: 1,
            render_scale_x_denominator: 1,
            render_scale_y_numerator: 1,
            render_scale_y_denominator: 1,
            pixel_aspect_numerator: 1,
            pixel_aspect_denominator: 1,
            requested_intermediate: PhysicalIntermediate::DevelopedAcesCg as u32,
            cancellation_identity: identity,
            progress_identity: ScreenPhysicalIdentity128 { high: 1, low: 2 },
            parameter_revision: 42,
            parameter_hash: [0x5a; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
        };
        request.render_window_width = 2;
        let mut unsupported_error = std::ptr::null();
        let unsupported_job =
            unsafe { screen_physical_frame_submit(&request, &mut unsupported_error) };
        assert!(unsupported_job.is_null());
        assert!(
            unsafe { std::ffi::CStr::from_ptr(unsupported_error) }
                .to_string_lossy()
                .contains("unsupported render window")
        );
        request.render_window_width = 4;
        let mut error = std::ptr::null();
        let job = unsafe { screen_physical_frame_submit(&request, &mut error) };
        let message = if error.is_null() {
            "".to_owned()
        } else {
            unsafe { std::ffi::CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned()
        };
        assert!(!job.is_null(), "{message}");
        unsafe {
            screen_physical_timed_input_set_v2_release(input);
            screen_physical_camera_pose_track_v2_release(camera_track);
            screen_physical_screen_pose_track_v2_release(screen_track);
            screen_physical_texture_release(source);
            screen_physical_texture_release(signal);
        }
        drop(source_texture);
        drop(signal_texture);
        assert!(!unsafe {
            screen_physical_frame_job_cancel(job, ScreenPhysicalIdentity128 { high: 7, low: 8 })
        });
        let mut result = unsafe { core::mem::zeroed::<ScreenPhysicalFrameResultV2>() };
        for _ in 0..2_000 {
            assert!(unsafe {
                screen_physical_frame_job_snapshot(job, &mut result, std::ptr::null_mut())
            });
            if result.state != STATE_RENDERING {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(result.state, STATE_COMPLETE);
        assert_eq!(result.progress, 1.0);
        assert_eq!((result.native_width, result.native_height), (4, 2));
        assert_eq!((result.effective_width, result.effective_height), (4, 2));
        assert_eq!(result.parameter_revision, 42);
        assert_eq!(
            result.parameter_hash,
            [0x5a; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE]
        );
        assert!(!result.output_texture.is_null());
        assert_eq!(result.stage_diagnostic_count, 16);
        assert_eq!(
            result.returned_intermediate,
            PhysicalIntermediate::DevelopedAcesCg as u32
        );
        let diagnostics = unsafe {
            std::slice::from_raw_parts(result.stage_diagnostics, result.stage_diagnostic_count)
        };
        let messages = diagnostics
            .iter()
            .map(|value| {
                String::from_utf8_lossy(unsafe {
                    std::slice::from_raw_parts(value.message.bytes, value.message.count)
                })
                .into_owned()
            })
            .collect::<Vec<_>>();
        assert!(messages[0].contains("PPI") && messages[0].contains("pitch"));
        assert!(messages[1].contains("samples/pixel"));
        assert!(messages[2].contains("device-space"));
        assert!(messages[3].contains("9 taps/channel"));
        assert!(messages[4].contains("exact rational shutter integral"));
        assert!(messages[5].contains("position + quaternion"));
        assert!(messages[6].contains("Beer-Lambert"));
        assert!(messages[7].contains("synthetic HDR"));
        assert!(messages[8].contains("physical core/tail radii"));
        assert!(messages[9].contains("thin lens"));
        assert!(messages[10].contains("STATIC_INPUT"));
        assert!(messages[11].contains("analytic exposure bracket"));
        assert!(messages[12].contains("crosstalk"));
        assert!(messages[13].contains("sensor CFA"));
        assert!(messages[14].contains("deterministic"));
        assert!(messages[15].contains("demosaic"));
        assert!(
            diagnostics[..11]
                .iter()
                .all(|diagnostic| diagnostic.elapsed_nanoseconds > 0)
        );
        assert_eq!(diagnostics[11].elapsed_nanoseconds, 0);
        assert!(
            diagnostics[12..]
                .iter()
                .all(|diagnostic| diagnostic.elapsed_nanoseconds > 0)
        );
        assert!(
            diagnostics[..11]
                .windows(2)
                .all(|pair| pair[0].elapsed_nanoseconds == pair[1].elapsed_nanoseconds)
        );
        assert_eq!(
            diagnostics[12].elapsed_nanoseconds,
            diagnostics[13].elapsed_nanoseconds
        );
        assert_eq!(
            diagnostics[13].elapsed_nanoseconds,
            diagnostics[14].elapsed_nanoseconds
        );
        assert_eq!(
            diagnostics[14].elapsed_nanoseconds,
            diagnostics[15].elapsed_nanoseconds
        );

        unsafe {
            screen_physical_frame_job_release(job);
            screen_device_profile_release(profile);
            screen_physical_pipeline_snapshot_release(pipeline);
        }
    }

    #[test]
    fn native_pattern_bridge_uses_the_application_pattern_authority() {
        let mut values = vec![0.0; PROCEDURAL_WIDTH as usize * PROCEDURAL_HEIGHT as usize * 4];
        assert!(unsafe {
            screen_test_pattern_render_rgba32f(
                5,
                0.0,
                values.as_mut_ptr(),
                values.len() / 4,
                std::ptr::null_mut(),
            )
        });
        let first = diagnostic_signal(
            ProceduralTestPattern::PhotometricDeviceScale,
            Vec2 { x: 0.0, y: 0.0 },
            RationalTime::new(0, 1).unwrap(),
        );
        let last = diagnostic_signal(
            ProceduralTestPattern::PhotometricDeviceScale,
            Vec2 { x: 1.0, y: 1.0 },
            RationalTime::new(0, 1).unwrap(),
        );
        assert_eq!(&values[..4], &[first.r, first.g, first.b, 1.0]);
        assert_eq!(&values[values.len() - 4..], &[last.r, last.g, last.b, 1.0]);
        for pattern in 2..=4 {
            let (mut width, mut height) = (0, 0);
            assert!(unsafe { screen_test_pattern_dimensions(pattern, &mut width, &mut height) });
            assert_eq!((width, height), (EMBEDDED_WIDTH, EMBEDDED_HEIGHT));
        }
        let (mut width, mut height) = (0, 0);
        assert!(unsafe { screen_test_pattern_dimensions(6, &mut width, &mut height) });
        assert_eq!((width, height), (EMBEDDED_WIDTH, EMBEDDED_HEIGHT));
    }

    #[test]
    fn device_catalog_exposes_complete_profiles_through_opaque_handles() {
        assert_eq!(screen_device_preset_count(), 9);
        for index in 0..screen_device_preset_count() {
            let mut parameters = ScreenDeviceParametersV3 {
                abi_version: 0,
                native_width: 0,
                native_height: 0,
                panel_technology: 0,
                stripe_layout: 0,
                active_width_meters: 0.0,
                active_height_meters: 0.0,
                black_matrix_fraction: 0.0,
                eotf_gamma: 0.0,
                black_level_nits: 0.0,
                white_level_nits: 0.0,
                primary_xy: [0.0; 6],
                white_xy: [0.0; 2],
                angular_emission_power: [0.0; 3],
                uniformity_character_strength: 0.0,
                uniformity_seed: 0,
                uniformity_broad_luminance_peak_to_peak: 0.0,
                uniformity_mid_luminance_peak_to_peak: 0.0,
                uniformity_fine_luminance_peak_to_peak: 0.0,
                uniformity_chromatic_peak_to_peak: 0.0,
                uniformity_mid_scale_millimeters: 0.0,
                uniformity_fine_scale_millimeters: 0.0,
                uniformity_low_drive_emphasis: 0.0,
                light_spread_character_strength: 0.0,
                light_spread_core_radius_micrometers: [0.0; 3],
                light_spread_core_weight: [0.0; 3],
                light_spread_tail_radius_micrometers: [0.0; 3],
                light_spread_tail_weight: [0.0; 3],
                residual_period_numerator: 0,
                residual_period_denominator: 0,
                residual_amplitude: 0.0,
                residual_phase_numerator: 0,
                residual_phase_denominator: 0,
                banding_period_numerator: 0,
                banding_period_denominator: 0,
                banding_on_numerator: 0,
                banding_on_denominator: 0,
                banding_phase_numerator: 0,
                banding_phase_denominator: 0,
                banding_amount: 0.0,
            };
            assert!(unsafe { screen_device_preset_parameters(index, &mut parameters) });
            assert_eq!(parameters.abi_version, SCREEN_PHYSICAL_FRAME_ABI_VERSION);
            let mode_count = screen_device_preset_color_mode_count(index);
            assert!(mode_count > 0);
            for mode_index in 0..mode_count {
                assert!(
                    !screen_device_preset_color_mode_id(index, mode_index)
                        .bytes
                        .is_null()
                );
            }
            assert!(
                !screen_device_preset_default_color_mode_id(index)
                    .bytes
                    .is_null()
            );
            let minimum = screen_device_preset_minimum_white_nits(index);
            let maximum = screen_device_preset_maximum_white_nits(index);
            let reference = parameters.white_level_nits;
            assert!(minimum.is_finite() && maximum.is_finite());
            assert!(minimum > 0.0 && minimum <= reference && reference <= maximum);
            assert!(screen_device_preset_white_step_nits(index) > 0.0);
            let profile =
                unsafe { screen_device_profile_create(&parameters, std::ptr::null_mut()) };
            assert!(!profile.is_null());
            unsafe { screen_device_profile_release(profile) };
        }
    }

    #[test]
    fn capture_catalog_exposes_the_two_authoritative_camera_presets() {
        assert_eq!(screen_capture_preset_count(), CAPTURE_DEVICE_PRESETS.len());
        assert_eq!(screen_capture_preset_count(), 5);
        for index in 0..screen_capture_preset_count() {
            let mut parameters: ScreenCapturePresetParametersV4 = unsafe { std::mem::zeroed() };
            assert!(unsafe { screen_capture_preset_parameters(index, &mut parameters) });
            assert_eq!(parameters.abi_version, SCREEN_AUTHORING_CATALOG_ABI_VERSION);
            assert!(parameters.sensor.native_width > 0);
            assert!(parameters.sensor.native_height > 0);
            assert!(parameters.gate_width_millimeters > 0.0);
            assert!(parameters.gate_height_millimeters > 0.0);
            assert!(parameters.default_f_stop > 0.0);
            assert!(parameters.default_temporal_samples > 0);
            assert!(parameters.default_readout_duration_milliseconds >= 0.0);
            assert!(parameters.lens_association_policy <= 1);
            assert!(!screen_capture_preset_id(index).bytes.is_null());
            assert!(!screen_capture_preset_label(index).bytes.is_null());
            assert!(!screen_capture_preset_default_lens_id(index).bytes.is_null());
            let compatible_count = screen_capture_preset_compatible_lens_count(index);
            assert!(compatible_count > 0);
            for lens_index in 0..compatible_count {
                assert!(
                    !screen_capture_preset_compatible_lens_id(index, lens_index)
                        .bytes
                        .is_null()
                );
            }
        }
        let mut invalid: ScreenCapturePresetParametersV4 = unsafe { std::mem::zeroed() };
        assert!(!unsafe {
            screen_capture_preset_parameters(screen_capture_preset_count(), &mut invalid)
        });
    }

    #[test]
    fn lens_catalog_exposes_integrated_and_interchangeable_optics_uniformly() {
        assert_eq!(screen_lens_preset_count(), LENS_PRESETS.len());
        assert!(screen_lens_preset_count() > 1);
        for index in 0..screen_lens_preset_count() {
            let mut parameters: ScreenLensPresetParametersV1 = unsafe { std::mem::zeroed() };
            assert!(unsafe { screen_lens_preset_parameters(index, &mut parameters) });
            assert_eq!(parameters.abi_version, SCREEN_AUTHORING_CATALOG_ABI_VERSION);
            assert!(parameters.nominal_focal_length_millimeters > 0.0);
            assert!(screen_lens_preset_authority(index) <= 1);
            assert!(!screen_lens_preset_id(index).bytes.is_null());
            assert!(!screen_lens_preset_label(index).bytes.is_null());
        }
    }

    #[test]
    fn cover_glass_catalog_exposes_valid_profiles_through_opaque_handles() {
        assert_eq!(screen_cover_glass_preset_count(), COVER_GLASS_PRESETS.len());
        for index in 0..screen_cover_glass_preset_count() {
            let mut parameters = ScreenCoverGlassParametersV2 {
                abi_version: 0,
                authority: 0,
                character_strength: 0.0,
                thickness_millimeters: 0.0,
                refractive_index: 0.0,
                anti_reflective_efficiency: 0.0,
                absorption_per_millimeter: [0.0; 3],
                roughness: 0.0,
                haze: 0.0,
                ag_microtexture_character_strength: 0.0,
                ag_microtexture_rms_slope: 0.0,
                ag_microtexture_correlation_length_micrometers: 0.0,
                ag_microtexture_anisotropy: 0.0,
                ag_microtexture_seed: 0,
                glow_character_strength: 0.0,
                glow_scatter_fraction: 0.0,
                glow_core_radius_millimeters: 0.0,
                glow_tail_radius_millimeters: 0.0,
                glow_tail_fraction: 0.0,
            };
            assert!(unsafe { screen_cover_glass_preset_parameters(index, &mut parameters) });
            assert_eq!(parameters.abi_version, SCREEN_PHYSICAL_FRAME_ABI_VERSION);
            let preset = COVER_GLASS_PRESETS[index].profile.anti_glare_microtexture;
            assert_eq!(
                parameters.ag_microtexture_character_strength,
                preset.character_strength
            );
            assert_eq!(parameters.ag_microtexture_rms_slope, preset.rms_slope);
            assert_eq!(
                parameters.ag_microtexture_correlation_length_micrometers,
                preset.correlation_length_micrometers
            );
            assert_eq!(parameters.ag_microtexture_anisotropy, preset.anisotropy);
            assert_eq!(parameters.ag_microtexture_seed, preset.seed);
            let profile =
                unsafe { screen_cover_glass_profile_create(&parameters, std::ptr::null_mut()) };
            assert!(!profile.is_null());
            unsafe { screen_cover_glass_profile_release(profile) };
        }
    }

    #[test]
    fn cover_glass_rejects_the_retired_physical_abi() {
        let mut parameters = cover_parameters(
            COVER_GLASS_PRESETS[0].authority,
            COVER_GLASS_PRESETS[0].profile,
        );
        parameters.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION - 1;
        let profile =
            unsafe { screen_cover_glass_profile_create(&parameters, std::ptr::null_mut()) };
        assert!(profile.is_null());

        let mut pipeline = pipeline_parameters();
        pipeline.cover.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION - 1;
        let snapshot =
            unsafe { screen_physical_pipeline_snapshot_create(&pipeline, std::ptr::null_mut()) };
        assert!(snapshot.is_null());
    }

    #[test]
    fn test_authoring_rejects_the_previous_selection_abi() {
        let selection = default_test_authoring_selection(
            "srgb-encoded-rec709",
            "lcd-asus-proart-pa329cv",
            FrameRate::new(24, 1).unwrap(),
        )
        .unwrap();
        let mut raw = resolved_test_selection(selection);
        raw.abi_version = SCREEN_TEST_AUTHORING_ABI_VERSION - 1;
        let descriptor = unsafe { screen_test_page_descriptor_create(&raw, std::ptr::null_mut()) };
        assert!(descriptor.is_null());
    }

    #[test]
    fn test_authoring_abi_preserves_fractional_frame_rate() {
        let rate = FrameRate::new(24_000, 1_001).unwrap();
        let selection = default_test_authoring_selection(
            "srgb-encoded-rec709",
            "lcd-asus-proart-pa329cv",
            rate,
        )
        .unwrap();
        let raw = resolved_test_selection(selection);
        assert_eq!(raw.frame_rate_numerator, 24_000);
        assert_eq!(raw.frame_rate_denominator, 1_001);
        let borrowed = unsafe { test_selection(&raw) }.expect("current exact selection");
        assert_eq!(borrowed.frame_rate, rate);
    }
}
