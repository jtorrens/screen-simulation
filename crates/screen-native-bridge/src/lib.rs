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
    CAPTURE_DEVICE_PRESETS, PhysicalIntermediate, PhysicalPipelineExecutionPlan,
    PhysicalPipelineSnapshot, ProceduralTestPattern, RasterPlacement,
    ResolvedSceneGeometryLensSnapshot, ResolvedShutterMotionSnapshot, RollingDirection,
    SensorReadout, diagnostic_signal, physical_shutter_schedule,
};
use screen_camera::CameraDevelopment;
use screen_contracts::{LinearRgb, Meters, RationalTime, Vec2, Vec3};
use screen_cover::{
    AcesCgRadiance, COVER_GLASS_PRESETS, CoverGlassPresetAuthority, CoverGlassProfile,
    EnvironmentPattern, ProceduralEnvironment,
};
use screen_geometry::{
    KeyframeInterpolation, LensModel, Quaternion, TransformKeyframe, TransformTrack,
};
use screen_panel::{
    AnalyticBanding, Chromaticity, DEVICE_PRESETS, FlatPanelQuality, LcdProfile, PanelColorimetry,
    PanelLightSpreadProfile, PanelTechnology, PanelTemporalEmission, ResidualFlicker, StripeLayout,
};
#[cfg(target_os = "macos")]
use screen_platform::{
    MetalPhysicalPipeline, MetalPhysicalPipelineError, MetalPhysicalPipelineResult,
};
use screen_sensor::{BayerPattern, SensorProfile};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenUtf8View {
    bytes: *const u8,
    count: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenCapturePresetParametersV2 {
    abi_version: u32,
    sensor: ScreenSensorNoiseParametersV2,
    gate_width_millimeters: f32,
    gate_height_millimeters: f32,
    focal_length_millimeters: f32,
    f_stop: f32,
    reference_exposure_index: f32,
    middle_gray_illuminance_seconds: f32,
    default_shutter_angle_degrees: f32,
    default_temporal_samples: u16,
    optics_authority: u16,
    default_readout_duration_milliseconds: f32,
}

pub const SCREEN_PHYSICAL_FRAME_ABI_VERSION: u32 = 2;
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
pub struct ScreenPhysicalStageContributionV2 {
    abi_version: u32,
    domain_id: u32,
    stage_id: u32,
    control_semantics: u32,
    amount: f32,
    visual_minimum: f32,
    visual_maximum: f32,
    safe_maximum: f32,
    discrete_enabled: bool,
    exact_identity_at_zero: bool,
}

#[repr(C)]
pub struct ScreenPhysicalFrameRequestV2 {
    abi_version: u32,
    frame_index: i64,
    timed_inputs: *const ScreenPhysicalTimedInputSetV2,
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
    stage_contributions: *const ScreenPhysicalStageContributionV2,
    stage_contribution_count: usize,
    requested_width: u32,
    requested_height: u32,
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
const DOMAIN_SCREEN: u32 = 0x100;
const EXPECTED_STAGE_IDS: [u32; 12] = [
    0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x201, 0x202, 0x203, 0x204, 0x205, 0x206,
];

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
    match value {
        0 => Some(FlatPanelQuality::Draft),
        1 => Some(FlatPanelQuality::Medium),
        2 => Some(FlatPanelQuality::High),
        3 => Some(FlatPanelQuality::Native),
        _ => None,
    }
}

fn placement(value: u32) -> Option<RasterPlacement> {
    match value {
        SCREEN_PHYSICAL_RASTER_FIT => Some(RasterPlacement::Fit),
        SCREEN_PHYSICAL_RASTER_FILL_CROP => Some(RasterPlacement::FillCrop),
        SCREEN_PHYSICAL_RASTER_STRETCH => Some(RasterPlacement::Stretch),
        SCREEN_PHYSICAL_RASTER_ONE_TO_ONE => Some(RasterPlacement::OneToOne),
        _ => None,
    }
}

fn intermediate(value: u32) -> Option<PhysicalIntermediate> {
    Some(match value {
        0 => PhysicalIntermediate::SourceAcesCg,
        1 => PhysicalIntermediate::DeviceSignal,
        2 => PhysicalIntermediate::PanelEmission,
        3 => PhysicalIntermediate::SubpixelRadiance,
        4 => PhysicalIntermediate::PanelLightSpread,
        5 => PhysicalIntermediate::CoverEnvironment,
        6 => PhysicalIntermediate::SceneGeometryLens,
        7 => PhysicalIntermediate::ShutterMotion,
        8 => PhysicalIntermediate::SensorNoise,
        9 => PhysicalIntermediate::RawMosaic,
        10 => PhysicalIntermediate::DevelopedAcesCg,
        _ => return None,
    })
}

fn contribution_amounts(
    contributions: &[ScreenPhysicalStageContributionV2],
) -> Option<(f32, f32, f32, f32, f32, f32)> {
    if contributions.len() != EXPECTED_STAGE_IDS.len() {
        return None;
    }
    for (index, contribution) in contributions.iter().enumerate() {
        let expected_domain = if index < 6 { 0x100 } else { 0x200 };
        let discrete = matches!(index, 9 | 11);
        let expected_safe_maximum = if index == 4 { 2.0 } else { 4.0 };
        if contribution.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION
            || contribution.domain_id != expected_domain
            || contribution.stage_id != EXPECTED_STAGE_IDS[index]
            || contribution.control_semantics != u32::from(discrete)
            || contribution.visual_minimum != 0.0
            || contribution.visual_maximum != 2.0
            || contribution.safe_maximum != expected_safe_maximum
        {
            return None;
        }
        if discrete {
            if contribution.amount != 0.0 {
                return None;
            }
        } else if !contribution.amount.is_finite()
            || !(0.0..=contribution.safe_maximum).contains(&contribution.amount)
        {
            return None;
        }
    }
    if (contributions[10].amount != 0.0 || contributions[11].discrete_enabled)
        && !contributions[9].discrete_enabled
    {
        return None;
    }
    Some((
        contributions[0].amount,
        contributions[1].amount,
        contributions[2].amount,
        contributions[3].amount,
        contributions[4].amount,
        contributions[5].amount,
    ))
}

fn diagnostic_snapshot(
    state: u32,
    progress: f32,
    stage_elapsed_nanoseconds: [u64; 12],
    stage_messages: [String; 12],
) -> Box<OwnedDiagnosticSnapshot> {
    let messages = Vec::from(stage_messages)
        .into_iter()
        .map(|message| message.into_bytes().into_boxed_slice())
        .collect::<Vec<_>>();
    let diagnostics = EXPECTED_STAGE_IDS
        .iter()
        .enumerate()
        .map(|(index, stage_id)| ScreenPhysicalStageDiagnosticV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            domain_id: if index < 6 { DOMAIN_SCREEN } else { 0x200 },
            stage_id: *stage_id,
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
    // SAFETY: the request owns a complete immutable contribution array for this call.
    let contributions = unsafe {
        std::slice::from_raw_parts(
            request.stage_contributions,
            request.stage_contribution_count,
        )
    };
    let Some((
        emission_amount,
        subpixel_geometry_amount,
        light_spread_amount,
        temporal_amount,
        cover_amount,
        environment_amount,
    )) = contribution_amounts(contributions)
    else {
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
            | PhysicalIntermediate::PanelLightSpread
            | PhysicalIntermediate::CoverEnvironment
            | PhysicalIntermediate::SceneGeometryLens
            | PhysicalIntermediate::ShutterMotion
            | PhysicalIntermediate::SensorNoise
            | PhysicalIntermediate::RawMosaic
            | PhysicalIntermediate::DevelopedAcesCg
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
        PhysicalIntermediate::SensorNoise | PhysicalIntermediate::RawMosaic
    ) && !contributions[9].discrete_enabled
        || requested_intermediate == PhysicalIntermediate::DevelopedAcesCg
            && contributions[9].discrete_enabled
            && !contributions[11].discrete_enabled
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
        panel_light_spread: device.light_spread,
        cover: pipeline.cover,
        environment: pipeline.environment,
        scene_geometry_lens: pipeline.scene_geometry_lens,
        shutter_motion: pipeline.shutter_motion,
        sensor: pipeline.sensor,
        development: pipeline.development,
    };
    if device.light_spread.character_strength != light_spread_amount {
        unsafe {
            set_error(
                error_message,
                b"light spread contribution does not match the resolved snapshot\0",
            )
        };
        return std::ptr::null_mut();
    }
    if pipeline.cover.character_strength != cover_amount
        || pipeline.environment.character_strength != environment_amount
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
        panel_light_spread: device.light_spread,
        placement,
        quality,
        requested_width: request.requested_width,
        requested_height: request.requested_height,
        screen_amount: request.screen_amount,
        emission_amount,
        subpixel_geometry_amount,
        temporal_emission_amount: temporal_amount,
        temporal_emission_gain: temporal_gain,
        cover: pipeline.cover,
        environment: pipeline.environment,
        scene_geometry_lens: pipeline.scene_geometry_lens,
        camera_position: camera_pose.translation,
        camera_rotation: camera_pose.rotation,
        screen_translation: screen_pose.translation,
        screen_rotation: screen_pose.rotation,
        scene_geometry_amount: contributions[6].amount,
        lens_amount: contributions[7].amount,
        frame_time,
        shutter_open,
        shutter_close,
        shutter_motion: pipeline.shutter_motion,
        shutter_motion_amount: contributions[8].amount,
        sensor: pipeline.sensor,
        sensor_enabled: contributions[9].discrete_enabled,
        sensor_noise_amount: contributions[10].amount,
        development: pipeline.development,
        development_enabled: contributions[11].discrete_enabled,
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
            backend.evaluate_temporal(
                &borrowed,
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
        native_width: if contributions[9].discrete_enabled {
            u32::from(pipeline.sensor.native_width)
        } else {
            native.effective_width
        },
        native_height: if contributions[9].discrete_enabled {
            u32::from(pipeline.sensor.native_height)
        } else {
            native.effective_height
        },
        parameter_revision: request.parameter_revision,
        parameter_hash: request.parameter_hash,
        static_input: !temporally_varying,
        sensor_enabled: contributions[9].discrete_enabled,
        sensor_noise_amount: contributions[10].amount,
        development_enabled: contributions[11].discrete_enabled,
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
        spread,
        temporal,
        cover,
        environment,
        scene,
        lens,
    ) = match &*outcome {
        PhysicalJobOutcome::Rendering => (
            STATE_RENDERING,
            0,
            0,
            0,
            0,
            [0; 12],
            "physical pipeline emission rendering".to_owned(),
            "subpixel geometry rendering".to_owned(),
            "panel light spread rendering".to_owned(),
            "panel temporal emission rendering".to_owned(),
            "cover glass rendering".to_owned(),
            "environment reflection rendering".to_owned(),
            "scene geometry rendering".to_owned(),
            "generalized lens rendering".to_owned(),
        ),
        PhysicalJobOutcome::Cancelled => (
            STATE_CANCELLED,
            0,
            0,
            0,
            0,
            [0; 12],
            "physical pipeline emission cancelled".to_owned(),
            "subpixel geometry cancelled".to_owned(),
            "panel light spread cancelled".to_owned(),
            "panel temporal emission cancelled".to_owned(),
            "cover glass cancelled".to_owned(),
            "environment reflection cancelled".to_owned(),
            "scene geometry cancelled".to_owned(),
            "generalized lens cancelled".to_owned(),
        ),
        PhysicalJobOutcome::Failed(message) => (
            STATE_FAILED,
            0,
            0,
            0,
            0,
            [0; 12],
            format!("physical pipeline backend failed: {message}"),
            format!("subpixel geometry failed: {message}"),
            format!("panel light spread failed: {message}"),
            format!("panel temporal emission failed: {message}"),
            format!("cover glass failed: {message}"),
            format!("environment reflection failed: {message}"),
            format!("scene geometry failed: {message}"),
            format!("generalized lens failed: {message}"),
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
                "9 taps/channel; physical radii in micrometers; fused Metal elapsed time reported"
                    .to_owned(),
                "exact rational shutter integral; residual flicker is frame-uniform unless analytic banding is enabled"
                    .to_owned(),
                "Beer-Lambert transmission + Fresnel/AR + roughness/haze; flat view cosine 1"
                    .to_owned(),
                "synthetic HDR environment sampled independently from panel temporal emission"
                    .to_owned(),
                "position + quaternion pose; device active dimensions are the sole screen scale"
                    .to_owned(),
                "thin lens + distortion/CA/vignette/transmission/PSF; focal-length generalized"
                    .to_owned(),
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
            spread,
            temporal,
            cover,
            environment,
            scene,
            lens,
            if job.static_input {
                "STATIC_INPUT: exact shutter/rolling/banding evaluation; motion blur inactive"
                    .to_owned()
            } else {
                "MOTION_ACTIVE: Rust-scheduled exact-time samples accumulated by Metal".to_owned()
            },
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
pub struct ScreenDeviceParametersV2 {
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
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenEnvironmentParametersV2 {
    abi_version: u32,
    character_strength: f32,
    ambient_radiance_acescg: [f32; 3],
    key_radiance_acescg: [f32; 3],
    key_direction_local: [f32; 3],
    key_angular_radius_degrees: f32,
    rotation_degrees: f32,
    pattern: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenSceneGeometryLensParametersV2 {
    abi_version: u32,
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
pub struct ScreenPhysicalPipelineParametersV2 {
    abi_version: u32,
    cover: ScreenCoverGlassParametersV2,
    environment: ScreenEnvironmentParametersV2,
    scene_geometry_lens: ScreenSceneGeometryLensParametersV2,
    shutter_motion: ScreenShutterMotionParametersV2,
    sensor_noise: ScreenSensorNoiseParametersV2,
    raw_develop: ScreenRawDevelopParametersV2,
}

pub struct ScreenPhysicalPipelineSnapshot {
    cover: CoverGlassProfile,
    environment: ProceduralEnvironment,
    scene_geometry_lens: ResolvedSceneGeometryLensSnapshot,
    shutter_motion: ResolvedShutterMotionSnapshot,
    sensor: SensorProfile,
    development: CameraDevelopment,
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
        parameters.sensor_noise.abi_version,
        parameters.raw_develop.abi_version,
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
    };
    let pattern = match parameters.environment.pattern {
        0 => EnvironmentPattern::UniformNeutral,
        1 => EnvironmentPattern::StudioSoftboxes,
        2 => EnvironmentPattern::CalibrationGrid,
        _ => {
            unsafe { set_error(error_message, b"unsupported environment pattern\0") };
            return std::ptr::null_mut();
        }
    };
    let environment = ProceduralEnvironment {
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
        rotation_degrees: parameters.environment.rotation_degrees,
        pattern,
    };
    let scene = parameters.scene_geometry_lens;
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
    if cover.validate().is_err()
        || environment.validate().is_err()
        || development.validate().is_err()
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
        shutter_motion,
        sensor,
        development,
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
pub unsafe extern "C" fn screen_capture_preset_parameters(
    index: usize,
    parameters: *mut ScreenCapturePresetParametersV2,
) -> bool {
    let Some(preset) = CAPTURE_DEVICE_PRESETS.get(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    let sensor = preset.sensor;
    unsafe {
        *parameters = ScreenCapturePresetParametersV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
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
            },
            gate_width_millimeters: preset.gate_width.0,
            gate_height_millimeters: preset.gate_height.0,
            focal_length_millimeters: preset.focal_length.0,
            f_stop: preset.f_stop,
            reference_exposure_index: preset.reference_exposure_index,
            middle_gray_illuminance_seconds: preset.middle_gray_illuminance_seconds_at_reference_ei,
            default_shutter_angle_degrees: preset.default_shutter_angle_degrees,
            default_temporal_samples: preset.default_temporal_samples,
            optics_authority: match preset.optics_authority {
                screen_application::CaptureOpticsAuthority::InterchangeableReferenceLens => 0,
                screen_application::CaptureOpticsAuthority::IntegratedFixedLens => 1,
            },
            default_readout_duration_milliseconds: preset.default_readout_duration_milliseconds,
        };
    }
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
pub extern "C" fn screen_device_preset_default_cover_id(index: usize) -> ScreenUtf8View {
    preset_at(index).map_or(utf8_view(""), |preset| {
        utf8_view(preset.default_cover_glass_preset_id)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_preset_parameters(
    index: usize,
    parameters: *mut ScreenDeviceParametersV2,
) -> bool {
    let Some(preset) = preset_at(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    // SAFETY: the caller provided a writable current-version parameter structure.
    let light_spread = match preset.category {
        "Phone" => PanelLightSpreadProfile::LCD_MOBILE,
        "Television" => PanelLightSpreadProfile::LCD_TV,
        _ => PanelLightSpreadProfile::LCD_DESKTOP,
    };
    unsafe {
        *parameters =
            parameters_from_profile(preset.profile(), preset.panel_technology, light_spread)
    };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_create(
    parameters: *const ScreenDeviceParametersV2,
    error_message: *mut *const c_char,
) -> *mut ScreenDeviceProfile {
    if parameters.is_null() {
        unsafe { set_error(error_message, b"missing device parameters\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null parameters pointer is valid for this call.
    let parameters = unsafe { *parameters };
    let (profile, light_spread) = match profile_from_parameters(parameters) {
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
    light_spread: PanelLightSpreadProfile,
) -> ScreenDeviceParametersV2 {
    ScreenDeviceParametersV2 {
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
    parameters: ScreenDeviceParametersV2,
) -> Result<(LcdProfile, PanelLightSpreadProfile), &'static [u8]> {
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
    let profile = profile
        .validate()
        .map_err(|_| b"invalid physical device profile\0" as &'static [u8])?;
    Ok((profile, light_spread))
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_test_pattern_dimensions(
    pattern: u32,
    width: *mut u32,
    height: *mut u32,
) -> bool {
    if width.is_null() || height.is_null() || pattern > 5 {
        return false;
    }
    let (resolved_width, resolved_height) = if (2..=4).contains(&pattern) {
        (EMBEDDED_WIDTH, EMBEDDED_HEIGHT)
    } else {
        (PROCEDURAL_WIDTH, PROCEDURAL_HEIGHT)
    };
    // SAFETY: both output pointers were validated and belong to the caller.
    unsafe {
        *width = resolved_width;
        *height = resolved_height;
    }
    true
}

/// Renders the exact six test-pattern choices exposed by the current Slint shell.
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

    fn contributions() -> [ScreenPhysicalStageContributionV2; 12] {
        core::array::from_fn(|index| {
            let discrete = matches!(index, 9 | 11);
            ScreenPhysicalStageContributionV2 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                domain_id: if index < 6 { 0x100 } else { 0x200 },
                stage_id: EXPECTED_STAGE_IDS[index],
                control_semantics: u32::from(discrete),
                amount: if index < 3 { 1.0 } else { 0.0 },
                visual_minimum: 0.0,
                visual_maximum: 2.0,
                safe_maximum: if index == 4 { 2.0 } else { 4.0 },
                discrete_enabled: false,
                exact_identity_at_zero: !discrete,
            }
        })
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
            },
            environment: ScreenEnvironmentParametersV2 {
                abi_version: version,
                character_strength: 0.0,
                ambient_radiance_acescg: [0.0; 3],
                key_radiance_acescg: [0.0; 3],
                key_direction_local: [0.0, 0.0, 1.0],
                key_angular_radius_degrees: 20.0,
                rotation_degrees: 0.0,
                pattern: 0,
            },
            scene_geometry_lens: ScreenSceneGeometryLensParametersV2 {
                abi_version: version,
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
            },
            raw_develop: ScreenRawDevelopParametersV2 {
                abi_version: version,
                white_balance: [1.0; 3],
                middle_gray_illuminance_seconds: 0.18,
                develop_exposure_ev: 0.0,
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
            PanelLightSpreadProfile::LCD_DESKTOP,
        );
        let profile = unsafe { screen_device_profile_create(&parameters, std::ptr::null_mut()) };
        let mut pipeline_parameters = pipeline_parameters();
        pipeline_parameters.sensor_noise.native_width = 4;
        pipeline_parameters.sensor_noise.native_height = 2;
        let pipeline = unsafe {
            screen_physical_pipeline_snapshot_create(&pipeline_parameters, std::ptr::null_mut())
        };
        assert!(!pipeline.is_null());
        let mut contributions = contributions();
        contributions[3].amount = 1.0;
        contributions[6].amount = 1.0;
        contributions[7].amount = 1.0;
        contributions[8].amount = 1.0;
        contributions[9].discrete_enabled = true;
        contributions[10].amount = 1.0;
        contributions[11].discrete_enabled = true;
        let identity = ScreenPhysicalIdentity128 { high: 7, low: 9 };
        let request = ScreenPhysicalFrameRequestV2 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            frame_index: 0,
            timed_inputs: input,
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
            requested_intermediate: PhysicalIntermediate::DevelopedAcesCg as u32,
            cancellation_identity: identity,
            progress_identity: ScreenPhysicalIdentity128 { high: 1, low: 2 },
            parameter_revision: 42,
            parameter_hash: [0x5a; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
        };
        let job = unsafe { screen_physical_frame_submit(&request, std::ptr::null_mut()) };
        assert!(!job.is_null());
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
        assert_eq!(result.stage_diagnostic_count, 12);
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
        assert!(messages[2].contains("9 taps/channel"));
        assert!(messages[3].contains("exact rational shutter integral"));
        assert!(messages[4].contains("Beer-Lambert"));
        assert!(messages[5].contains("synthetic HDR"));
        assert!(messages[6].contains("position + quaternion"));
        assert!(messages[7].contains("thin lens"));
        assert!(messages[8].contains("STATIC_INPUT"));
        assert!(messages[9].contains("sensor CFA"));
        assert!(messages[10].contains("deterministic"));
        assert!(messages[11].contains("demosaic"));
        assert!(
            diagnostics[..9]
                .iter()
                .all(|diagnostic| diagnostic.elapsed_nanoseconds > 0)
        );
        assert!(
            diagnostics[9..]
                .iter()
                .all(|diagnostic| diagnostic.elapsed_nanoseconds > 0)
        );
        assert!(
            diagnostics[..9]
                .windows(2)
                .all(|pair| pair[0].elapsed_nanoseconds == pair[1].elapsed_nanoseconds)
        );
        assert_eq!(
            diagnostics[9].elapsed_nanoseconds,
            diagnostics[10].elapsed_nanoseconds
        );
        assert_eq!(
            diagnostics[10].elapsed_nanoseconds,
            diagnostics[11].elapsed_nanoseconds
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
    }

    #[test]
    fn device_catalog_exposes_complete_profiles_through_opaque_handles() {
        assert_eq!(screen_device_preset_count(), 9);
        for index in 0..screen_device_preset_count() {
            let mut parameters = ScreenDeviceParametersV2 {
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
            let profile =
                unsafe { screen_device_profile_create(&parameters, std::ptr::null_mut()) };
            assert!(!profile.is_null());
            unsafe { screen_device_profile_release(profile) };
        }
    }

    #[test]
    fn capture_catalog_exposes_the_two_authoritative_camera_presets() {
        assert_eq!(screen_capture_preset_count(), CAPTURE_DEVICE_PRESETS.len());
        assert_eq!(screen_capture_preset_count(), 2);
        for index in 0..screen_capture_preset_count() {
            let mut parameters: ScreenCapturePresetParametersV2 = unsafe { std::mem::zeroed() };
            assert!(unsafe { screen_capture_preset_parameters(index, &mut parameters) });
            assert_eq!(parameters.abi_version, SCREEN_PHYSICAL_FRAME_ABI_VERSION);
            assert!(parameters.sensor.native_width > 0);
            assert!(parameters.sensor.native_height > 0);
            assert!(parameters.gate_width_millimeters > 0.0);
            assert!(parameters.gate_height_millimeters > 0.0);
            assert!(parameters.focal_length_millimeters > 0.0);
            assert!(parameters.f_stop > 0.0);
            assert!(parameters.default_temporal_samples > 0);
            assert!(parameters.default_readout_duration_milliseconds >= 0.0);
            assert!(!screen_capture_preset_id(index).bytes.is_null());
            assert!(!screen_capture_preset_label(index).bytes.is_null());
            assert!(!screen_capture_preset_default_lens_id(index).bytes.is_null());
        }
        let mut invalid: ScreenCapturePresetParametersV2 = unsafe { std::mem::zeroed() };
        assert!(!unsafe {
            screen_capture_preset_parameters(screen_capture_preset_count(), &mut invalid)
        });
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
            };
            assert!(unsafe { screen_cover_glass_preset_parameters(index, &mut parameters) });
            assert_eq!(parameters.abi_version, SCREEN_PHYSICAL_FRAME_ABI_VERSION);
            let profile =
                unsafe { screen_cover_glass_profile_create(&parameters, std::ptr::null_mut()) };
            assert!(!profile.is_null());
            unsafe { screen_cover_glass_profile_release(profile) };
        }
    }
}
