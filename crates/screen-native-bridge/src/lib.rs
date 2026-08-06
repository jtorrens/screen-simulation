//! Coarse stable C ABI for the native shell's future Rust physical engine.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, c_float, c_void};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

#[cfg(target_os = "macos")]
use metal::foreign_types::{ForeignType, ForeignTypeRef};
#[cfg(target_os = "macos")]
use metal::{MTLTexture, TextureRef};
use screen_application::{
    FlatPanelPlan, ProceduralTestPattern, RasterPlacement, diagnostic_signal,
};
use screen_contracts::{DeviceRgb, LinearRgb, Meters, RationalTime, Vec2};
use screen_cover::{COVER_GLASS_PRESETS, CoverGlassPresetAuthority, CoverGlassProfile};
use screen_panel::{
    AnalyticBanding, Chromaticity, DEVICE_PRESETS, FlatPanelQuality, LcdProfile, PanelColorimetry,
    PanelTechnology, PanelTemporalEmission, ResidualFlicker, StripeLayout, ValidatedPanelEvaluator,
};
#[cfg(target_os = "macos")]
use screen_platform::{MetalFlatPanel, MetalFlatPanelError, MetalFlatPanelResult};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenUtf8View {
    bytes: *const u8,
    count: usize,
}

pub const SCREEN_PHYSICAL_FRAME_ABI_VERSION: u32 = 1;
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

pub struct ScreenPhysicalFrameInput {
    source_acescg: ScreenPhysicalTexture,
    device_signal: ScreenPhysicalTexture,
    raster_placement: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalIdentity128 {
    high: u64,
    low: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalStageContributionV1 {
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
    reserved: [u8; 2],
}

#[repr(C)]
pub struct ScreenPhysicalFrameRequestV1 {
    abi_version: u32,
    frame_index: i64,
    frame_time_numerator: i64,
    frame_time_denominator: u32,
    input: *const ScreenPhysicalFrameInput,
    resolved_device: *const ScreenDeviceProfile,
    quality: u32,
    screen_amount: f32,
    capture_amount: f32,
    stage_contributions: *const ScreenPhysicalStageContributionV1,
    stage_contribution_count: usize,
    requested_width: u32,
    requested_height: u32,
    cancellation_identity: ScreenPhysicalIdentity128,
    progress_identity: ScreenPhysicalIdentity128,
    parameter_revision: u64,
    parameter_hash: [u8; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenPhysicalStageDiagnosticV1 {
    abi_version: u32,
    domain_id: u32,
    stage_id: u32,
    state: u32,
    progress: f32,
    message: ScreenUtf8View,
}

#[repr(C)]
pub struct ScreenPhysicalFrameResultV1 {
    abi_version: u32,
    acescg_texture: *const ScreenPhysicalTexture,
    native_width: u32,
    native_height: u32,
    effective_width: u32,
    effective_height: u32,
    computed_quality: u32,
    state: u32,
    progress: f32,
    stage_diagnostics: *const ScreenPhysicalStageDiagnosticV1,
    stage_diagnostic_count: usize,
    parameter_revision: u64,
    parameter_hash: [u8; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
}

const STATE_RENDERING: u32 = 2;
const STATE_CANCELLED: u32 = 3;
const STATE_FAILED: u32 = 4;
const STATE_COMPLETE: u32 = 5;
const DOMAIN_SCREEN: u32 = 0x100;
const STAGE_SCREEN_EMISSION: u32 = 0x101;
const STAGE_SCREEN_SUBPIXEL_GEOMETRY: u32 = 0x102;
const EXPECTED_STAGE_IDS: [u32; 11] = [
    0x101, 0x102, 0x103, 0x104, 0x105, 0x201, 0x202, 0x203, 0x204, 0x205, 0x206,
];

#[cfg(target_os = "macos")]
enum PhysicalJobOutcome {
    Rendering,
    Complete(MetalFlatPanelResult),
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
    diagnostics: Box<[ScreenPhysicalStageDiagnosticV1]>,
}

pub struct ScreenPhysicalFrameJob {
    shared: Arc<PhysicalJobShared>,
    cancellation_identity: ScreenPhysicalIdentity128,
    quality: u32,
    native_width: u32,
    native_height: u32,
    parameter_revision: u64,
    parameter_hash: [u8; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
    worker: Mutex<Option<JoinHandle<()>>>,
    output_views: Mutex<Vec<Box<ScreenPhysicalTexture>>>,
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_input_create(
    source_acescg: *const ScreenPhysicalTexture,
    device_signal: *const ScreenPhysicalTexture,
    raster_placement: u32,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalFrameInput {
    if source_acescg.is_null()
        || device_signal.is_null()
        || raster_placement > SCREEN_PHYSICAL_RASTER_ONE_TO_ONE
    {
        unsafe { set_error(error_message, b"invalid physical frame input\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: both non-null texture wrappers are borrowed for this call. The
    // copied views do not duplicate the underlying Metal textures.
    let source_acescg = unsafe { *source_acescg };
    let device_signal = unsafe { *device_signal };
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenPhysicalFrameInput {
        source_acescg,
        device_signal,
        raster_placement,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_input_release(input: *mut ScreenPhysicalFrameInput) {
    if !input.is_null() {
        // SAFETY: the ABI requires the uniquely owned input returned by create.
        unsafe { drop(Box::from_raw(input)) };
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

fn contribution_amounts(
    contributions: &[ScreenPhysicalStageContributionV1],
    screen_amount: f32,
) -> Option<(f32, f32)> {
    if contributions.len() != EXPECTED_STAGE_IDS.len() {
        return None;
    }
    for (index, contribution) in contributions.iter().enumerate() {
        let expected_domain = if index < 5 { 0x100 } else { 0x200 };
        let discrete = matches!(index, 8 | 10);
        if contribution.abi_version != SCREEN_PHYSICAL_FRAME_ABI_VERSION
            || contribution.domain_id != expected_domain
            || contribution.stage_id != EXPECTED_STAGE_IDS[index]
            || contribution.control_semantics != u32::from(discrete)
            || contribution.reserved != [0, 0]
            || contribution.visual_minimum != 0.0
            || contribution.visual_maximum != 2.0
            || contribution.safe_maximum != 4.0
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
    if screen_amount > 0.0 && contributions[2..5].iter().any(|value| value.amount != 0.0) {
        return None;
    }
    Some((contributions[0].amount, contributions[1].amount))
}

fn diagnostic_snapshot(
    state: u32,
    progress: f32,
    emission_message: String,
    geometry_message: String,
) -> Box<OwnedDiagnosticSnapshot> {
    let messages = vec![
        emission_message.into_bytes().into_boxed_slice(),
        geometry_message.into_bytes().into_boxed_slice(),
    ];
    let diagnostics = vec![
        ScreenPhysicalStageDiagnosticV1 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            domain_id: DOMAIN_SCREEN,
            stage_id: STAGE_SCREEN_EMISSION,
            state,
            progress,
            message: ScreenUtf8View {
                bytes: messages[0].as_ptr(),
                count: messages[0].len(),
            },
        },
        ScreenPhysicalStageDiagnosticV1 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            domain_id: DOMAIN_SCREEN,
            stage_id: STAGE_SCREEN_SUBPIXEL_GEOMETRY,
            state,
            progress,
            message: ScreenUtf8View {
                bytes: messages[1].as_ptr(),
                count: messages[1].len(),
            },
        },
    ]
    .into_boxed_slice();
    Box::new(OwnedDiagnosticSnapshot {
        _messages: messages,
        diagnostics,
    })
}

#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_submit(
    request: *const ScreenPhysicalFrameRequestV1,
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
        || request.frame_time_denominator == 0
        || request.input.is_null()
        || request.resolved_device.is_null()
        || quality(request.quality).is_none()
        || request.requested_width == 0
        || request.requested_height == 0
        || !request.screen_amount.is_finite()
        || !(0.0..=4.0).contains(&request.screen_amount)
        || request.capture_amount != 0.0
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
    let Some((emission_amount, subpixel_geometry_amount)) =
        contribution_amounts(contributions, request.screen_amount)
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
    let input = unsafe { &*request.input };
    let device = unsafe { &*request.resolved_device };
    let Some(placement) = placement(input.raster_placement) else {
        unsafe { set_error(error_message, b"invalid physical raster placement\0") };
        return std::ptr::null_mut();
    };
    let Some(quality) = quality(request.quality) else {
        unsafe { set_error(error_message, b"invalid physical quality\0") };
        return std::ptr::null_mut();
    };
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
    let plan = FlatPanelPlan {
        panel: device.profile,
        placement,
        quality,
        requested_width: request.requested_width,
        requested_height: request.requested_height,
        screen_amount: request.screen_amount,
        emission_amount,
        subpixel_geometry_amount,
    };
    let shared = Arc::new(PhysicalJobShared {
        outcome: Mutex::new(PhysicalJobOutcome::Rendering),
        progress_bits: AtomicU32::new(0.0_f32.to_bits()),
        cancelled: AtomicBool::new(false),
    });
    let worker_shared = Arc::clone(&shared);
    let source = input.source_acescg.metal_texture;
    let signal = input.device_signal.metal_texture;
    let worker = std::thread::spawn(move || {
        // SAFETY: the ABI requires the host to retain both Metal textures through job release.
        let source = unsafe { TextureRef::from_ptr(source as *mut MTLTexture) };
        // SAFETY: same lifetime and ownership rule as the source texture above.
        let signal = unsafe { TextureRef::from_ptr(signal as *mut MTLTexture) };
        let result = MetalFlatPanel::new(source.device()).and_then(|backend| {
            backend.evaluate(
                source,
                signal,
                plan,
                |progress| {
                    worker_shared
                        .progress_bits
                        .store(progress.to_bits(), Ordering::Release);
                },
                || worker_shared.cancelled.load(Ordering::Acquire),
            )
        });
        let outcome = match result {
            Ok(result) => PhysicalJobOutcome::Complete(result),
            Err(MetalFlatPanelError::Cancelled) => PhysicalJobOutcome::Cancelled,
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
        native_width: native.effective_width,
        native_height: native.effective_height,
        parameter_revision: request.parameter_revision,
        parameter_hash: request.parameter_hash,
        worker: Mutex::new(Some(worker)),
        output_views: Mutex::new(Vec::new()),
        snapshots: Mutex::new(Vec::new()),
    }))
}

#[cfg(not(target_os = "macos"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_frame_submit(
    _request: *const ScreenPhysicalFrameRequestV1,
    error_message: *mut *const c_char,
) -> *mut ScreenPhysicalFrameJob {
    unsafe { set_error(error_message, b"Metal flat panel backend requires macOS\0") };
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
    result: *mut ScreenPhysicalFrameResultV1,
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
    let (state, effective_width, effective_height, texture_pointer, emission, geometry) =
        match &*outcome {
            PhysicalJobOutcome::Rendering => (
                STATE_RENDERING,
                0,
                0,
                0,
                "flat panel emission rendering".to_owned(),
                "subpixel geometry rendering".to_owned(),
            ),
            PhysicalJobOutcome::Cancelled => (
                STATE_CANCELLED,
                0,
                0,
                0,
                "flat panel emission cancelled".to_owned(),
                "subpixel geometry cancelled".to_owned(),
            ),
            PhysicalJobOutcome::Failed(message) => (
                STATE_FAILED,
                0,
                0,
                0,
                format!("flat panel backend failed: {message}"),
                format!("subpixel geometry failed: {message}"),
            ),
            PhysicalJobOutcome::Complete(value) => {
                let resolved = if value.sampling.subpixel_geometry_resolved {
                    "resolved"
                } else {
                    "unresolved"
                };
                (
                    STATE_COMPLETE,
                    value.sampling.effective_width,
                    value.sampling.effective_height,
                    value.texture.as_ptr() as usize,
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
    let snapshot = diagnostic_snapshot(state, progress, emission, geometry);
    let mut snapshots = job
        .snapshots
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    snapshots.push(snapshot);
    let snapshot = snapshots.last().expect("just pushed diagnostic snapshot");
    // SAFETY: result is writable and all borrowed views remain job-owned until release.
    unsafe {
        *result = ScreenPhysicalFrameResultV1 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            acescg_texture: output_texture,
            native_width: job.native_width,
            native_height: job.native_height,
            effective_width,
            effective_height,
            computed_quality: job.quality,
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
    _result: *mut ScreenPhysicalFrameResultV1,
    error_message: *mut *const c_char,
) -> bool {
    unsafe { set_error(error_message, b"Metal flat panel backend requires macOS\0") };
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
pub struct ScreenDeviceParametersV1 {
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
    evaluator: ValidatedPanelEvaluator,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ScreenCoverGlassParametersV1 {
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

pub struct ScreenCoverGlassProfile {
    _profile: CoverGlassProfile,
}

#[repr(C)]
pub struct ScreenDeviceEvaluationParametersV1 {
    abi_version: u32,
    native_to_acescg: [f32; 9],
    eotf_gamma: f32,
    black_level_nits: f32,
    white_level_nits: f32,
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
    parameters: *mut ScreenCoverGlassParametersV1,
) -> bool {
    let Some(preset) = cover_preset_at(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    // SAFETY: the caller provided writable V1 parameter storage.
    unsafe { *parameters = cover_parameters(preset.authority, preset.profile) };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_cover_glass_profile_create(
    parameters: *const ScreenCoverGlassParametersV1,
    error_message: *mut *const c_char,
) -> *mut ScreenCoverGlassProfile {
    if parameters.is_null() {
        unsafe { set_error(error_message, b"missing cover glass parameters\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null parameters pointer is valid for this call.
    let parameters = unsafe { *parameters };
    if parameters.abi_version != 1 || parameters.authority > 1 {
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

fn cover_parameters(
    authority: CoverGlassPresetAuthority,
    profile: CoverGlassProfile,
) -> ScreenCoverGlassParametersV1 {
    ScreenCoverGlassParametersV1 {
        abi_version: 1,
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
    parameters: *mut ScreenDeviceParametersV1,
) -> bool {
    let Some(preset) = preset_at(index) else {
        return false;
    };
    if parameters.is_null() {
        return false;
    }
    // SAFETY: the caller provided a writable V1 parameter structure.
    unsafe { *parameters = parameters_from_profile(preset.profile(), preset.panel_technology) };
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_create(
    parameters: *const ScreenDeviceParametersV1,
    error_message: *mut *const c_char,
) -> *mut ScreenDeviceProfile {
    if parameters.is_null() {
        unsafe { set_error(error_message, b"missing device parameters\0") };
        return std::ptr::null_mut();
    }
    // SAFETY: the non-null parameters pointer is valid for this call.
    let parameters = unsafe { *parameters };
    let profile = match profile_from_parameters(parameters) {
        Ok(profile) => profile,
        Err(message) => {
            unsafe { set_error(error_message, message) };
            return std::ptr::null_mut();
        }
    };
    let evaluator = match profile.evaluator() {
        Ok(evaluator) => evaluator,
        Err(_) => {
            unsafe { set_error(error_message, b"invalid physical device evaluator\0") };
            return std::ptr::null_mut();
        }
    };
    unsafe { set_error(error_message, b"\0") };
    Box::into_raw(Box::new(ScreenDeviceProfile { profile, evaluator }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_release(profile: *mut ScreenDeviceProfile) {
    if !profile.is_null() {
        // SAFETY: the ABI requires the uniquely owned handle returned by create.
        unsafe { drop(Box::from_raw(profile)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_evaluation_parameters(
    profile: *const ScreenDeviceProfile,
    parameters: *mut ScreenDeviceEvaluationParametersV1,
) -> bool {
    if profile.is_null() || parameters.is_null() {
        return false;
    }
    // SAFETY: both pointers were validated for the duration of this call.
    let values = unsafe { (*profile).evaluator }.device_stage_parameters();
    // SAFETY: the caller provided a writable V1 parameter structure.
    unsafe {
        *parameters = ScreenDeviceEvaluationParametersV1 {
            abi_version: 1,
            native_to_acescg: [
                values.native_to_acescg[0][0],
                values.native_to_acescg[0][1],
                values.native_to_acescg[0][2],
                values.native_to_acescg[1][0],
                values.native_to_acescg[1][1],
                values.native_to_acescg[1][2],
                values.native_to_acescg[2][0],
                values.native_to_acescg[2][1],
                values.native_to_acescg[2][2],
            ],
            eotf_gamma: values.eotf_gamma,
            black_level_nits: values.black_level_nits,
            white_level_nits: values.white_level_nits,
        };
    }
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_device_profile_evaluate_rgba32f(
    profile: *const ScreenDeviceProfile,
    device_code: *const c_float,
    acescg: *mut c_float,
    pixel_count: usize,
) -> bool {
    if profile.is_null()
        || (device_code.is_null() && pixel_count != 0)
        || (acescg.is_null() && pixel_count != 0)
    {
        return false;
    }
    // SAFETY: the ABI requires complete RGBA arrays for pixel_count pixels.
    let source = unsafe { std::slice::from_raw_parts(device_code, pixel_count * 4) };
    // SAFETY: the ABI requires writable RGBA storage for pixel_count pixels.
    let destination = unsafe { std::slice::from_raw_parts_mut(acescg, pixel_count * 4) };
    // SAFETY: the non-null handle is immutable for the duration of this call.
    let evaluator = unsafe { (*profile).evaluator };
    for (input, output) in source.chunks_exact(4).zip(destination.chunks_exact_mut(4)) {
        let value =
            evaluator.normalized_device_emission(DeviceRgb::new(input[0], input[1], input[2]));
        output.copy_from_slice(&[value.r, value.g, value.b, input[3]]);
    }
    true
}

fn parameters_from_profile(
    profile: LcdProfile,
    technology: PanelTechnology,
) -> ScreenDeviceParametersV1 {
    ScreenDeviceParametersV1 {
        abi_version: 1,
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
    parameters: ScreenDeviceParametersV1,
) -> Result<LcdProfile, &'static [u8]> {
    if parameters.abi_version != 1 {
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
    profile
        .validate()
        .map_err(|_| b"invalid physical device profile\0" as &'static [u8])
}

pub struct ScreenPhysicalPipeline;

#[unsafe(no_mangle)]
pub extern "C" fn screen_physical_pipeline_create() -> *mut ScreenPhysicalPipeline {
    Box::into_raw(Box::new(ScreenPhysicalPipeline))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_pipeline_release(pipeline: *mut ScreenPhysicalPipeline) {
    if !pipeline.is_null() {
        // SAFETY: the ABI requires the uniquely owned handle returned by create.
        unsafe { drop(Box::from_raw(pipeline)) };
    }
}

/// Exact in-place identity over one complete linear ACEScg image.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn screen_physical_pipeline_process_rgba32f(
    pipeline: *const ScreenPhysicalPipeline,
    pixels: *mut c_float,
    pixel_count: usize,
    error_message: *mut *const c_char,
) -> bool {
    if pipeline.is_null() || (pixels.is_null() && pixel_count != 0) {
        static ERROR: &[u8] = b"invalid PhysicalPipeline identity buffer\0";
        if !error_message.is_null() {
            // SAFETY: the optional out parameter is writable for the call.
            unsafe { *error_message = ERROR.as_ptr().cast() };
        }
        return false;
    }
    if !error_message.is_null() {
        // SAFETY: the optional out parameter is writable for the call.
        unsafe { *error_message = std::ptr::null() };
    }
    true
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

    fn contributions() -> [ScreenPhysicalStageContributionV1; 11] {
        core::array::from_fn(|index| {
            let discrete = matches!(index, 8 | 10);
            ScreenPhysicalStageContributionV1 {
                abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                domain_id: if index < 5 { 0x100 } else { 0x200 },
                stage_id: EXPECTED_STAGE_IDS[index],
                control_semantics: u32::from(discrete),
                amount: if index < 2 { 1.0 } else { 0.0 },
                visual_minimum: 0.0,
                visual_maximum: 2.0,
                safe_maximum: 4.0,
                discrete_enabled: discrete,
                exact_identity_at_zero: !discrete,
                reserved: [0, 0],
            }
        })
    }

    #[test]
    fn identity_preserves_every_float_bit() {
        let pipeline = screen_physical_pipeline_create();
        let mut values = [-0.5, 0.0, 1.0, 0.25, 4.0, f32::NAN, f32::INFINITY, 1.0];
        let expected = values.map(f32::to_bits);
        assert!(unsafe {
            screen_physical_pipeline_process_rgba32f(
                pipeline,
                values.as_mut_ptr(),
                values.len() / 4,
                std::ptr::null_mut(),
            )
        });
        assert_eq!(values.map(f32::to_bits), expected);
        unsafe { screen_physical_pipeline_release(pipeline) };
    }

    #[test]
    fn physical_frame_input_keeps_both_typed_texture_views_and_placement() {
        let source_storage = 1_u8;
        let device_storage = 2_u8;
        let source_pointer = (&source_storage as *const u8).cast::<c_void>();
        let device_pointer = (&device_storage as *const u8).cast::<c_void>();
        let mut error = std::ptr::null();
        let source =
            unsafe { screen_physical_texture_create_borrowed_metal(source_pointer, &mut error) };
        let device =
            unsafe { screen_physical_texture_create_borrowed_metal(device_pointer, &mut error) };
        assert!(!source.is_null());
        assert!(!device.is_null());
        let input = unsafe {
            screen_physical_frame_input_create(
                source,
                device,
                SCREEN_PHYSICAL_RASTER_FILL_CROP,
                &mut error,
            )
        };
        assert!(!input.is_null());
        unsafe {
            screen_physical_texture_release(source);
            screen_physical_texture_release(device);
        }
        // SAFETY: the input owns copied non-owning views until release.
        assert_eq!(
            unsafe { (*input).source_acescg.metal_texture },
            source_pointer as usize
        );
        // SAFETY: the input owns copied non-owning views until release.
        assert_eq!(
            unsafe { (*input).device_signal.metal_texture },
            device_pointer as usize
        );
        // SAFETY: the input remains live until the final release below.
        assert_eq!(
            unsafe { (*input).raster_placement },
            SCREEN_PHYSICAL_RASTER_FILL_CROP
        );
        unsafe { screen_physical_frame_input_release(input) };

        let invalid = unsafe {
            screen_physical_frame_input_create(
                std::ptr::null(),
                std::ptr::null(),
                SCREEN_PHYSICAL_RASTER_ONE_TO_ONE + 1,
                &mut error,
            )
        };
        assert!(invalid.is_null());
        assert!(!error.is_null());
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
        let input = unsafe {
            screen_physical_frame_input_create(
                source,
                signal,
                SCREEN_PHYSICAL_RASTER_STRETCH,
                std::ptr::null_mut(),
            )
        };
        let mut panel = DEVICE_PRESETS[0].profile();
        panel.native_width = 2;
        panel.native_height = 1;
        panel.active_width = Meters(0.002);
        panel.active_height = Meters(0.001);
        let parameters = parameters_from_profile(panel, PanelTechnology::IpsLcd);
        let profile = unsafe { screen_device_profile_create(&parameters, std::ptr::null_mut()) };
        let contributions = contributions();
        let identity = ScreenPhysicalIdentity128 { high: 7, low: 9 };
        let request = ScreenPhysicalFrameRequestV1 {
            abi_version: SCREEN_PHYSICAL_FRAME_ABI_VERSION,
            frame_index: 0,
            frame_time_numerator: 0,
            frame_time_denominator: 24,
            input,
            resolved_device: profile,
            quality: 1,
            screen_amount: 1.0,
            capture_amount: 0.0,
            stage_contributions: contributions.as_ptr(),
            stage_contribution_count: contributions.len(),
            requested_width: 4,
            requested_height: 2,
            cancellation_identity: identity,
            progress_identity: ScreenPhysicalIdentity128 { high: 1, low: 2 },
            parameter_revision: 42,
            parameter_hash: [0x5a; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE],
        };
        let job = unsafe { screen_physical_frame_submit(&request, std::ptr::null_mut()) };
        assert!(!job.is_null());
        assert!(!unsafe {
            screen_physical_frame_job_cancel(job, ScreenPhysicalIdentity128 { high: 7, low: 8 })
        });
        let mut result = unsafe { core::mem::zeroed::<ScreenPhysicalFrameResultV1>() };
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
        assert_eq!((result.native_width, result.native_height), (6, 3));
        assert_eq!((result.effective_width, result.effective_height), (4, 2));
        assert_eq!(result.parameter_revision, 42);
        assert_eq!(
            result.parameter_hash,
            [0x5a; SCREEN_PHYSICAL_PARAMETER_HASH_SIZE]
        );
        assert!(!result.acescg_texture.is_null());
        assert_eq!(result.stage_diagnostic_count, 2);
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

        let mut unsupported = contributions;
        unsupported[2].amount = 1.0;
        let invalid_request = ScreenPhysicalFrameRequestV1 {
            stage_contributions: unsupported.as_ptr(),
            ..request
        };
        let invalid =
            unsafe { screen_physical_frame_submit(&invalid_request, std::ptr::null_mut()) };
        assert!(invalid.is_null());

        unsafe {
            screen_physical_frame_job_release(job);
            screen_device_profile_release(profile);
            screen_physical_frame_input_release(input);
            screen_physical_texture_release(source);
            screen_physical_texture_release(signal);
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
            let mut parameters = ScreenDeviceParametersV1 {
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
            assert_eq!(parameters.abi_version, 1);
            let profile =
                unsafe { screen_device_profile_create(&parameters, std::ptr::null_mut()) };
            assert!(!profile.is_null());
            unsafe { screen_device_profile_release(profile) };
        }
    }

    #[test]
    fn cover_glass_catalog_exposes_valid_profiles_through_opaque_handles() {
        assert_eq!(screen_cover_glass_preset_count(), COVER_GLASS_PRESETS.len());
        for index in 0..screen_cover_glass_preset_count() {
            let mut parameters = ScreenCoverGlassParametersV1 {
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
            assert_eq!(parameters.abi_version, 1);
            let profile =
                unsafe { screen_cover_glass_profile_create(&parameters, std::ptr::null_mut()) };
            assert!(!profile.is_null());
            unsafe { screen_cover_glass_profile_release(profile) };
        }
    }
}
