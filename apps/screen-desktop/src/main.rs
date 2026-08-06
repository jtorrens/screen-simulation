//! Screen Simulation desktop composition root.

#![deny(unsafe_code)]

pub mod project_mapping;

use std::cell::RefCell;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use image::ImageEncoder;
use screen_application::{
    ApplicationError, CAPTURE_DEVICE_PRESETS, CaptureOpticsAuthority, DeviceSignalRaster,
    DiagnosticView, FrameCaptureRequest, OpticalRequest, PHOTOMETRIC_DEVICE_CODES,
    PanelTemporalEvaluation, PreparedDeviceSignalRaster, PreparedRaster, PreviewPixel,
    ProceduralTestPattern, RasterPlacement, SensorReadout, SimulationRequest,
    capture_and_develop_device_signal_region_sequence_with_compute_backends,
    capture_and_develop_device_signal_region_with_compute_backends,
    capture_and_develop_procedural_region_with_compute_backends, capture_device_preset,
    decoded_frame_to_device_signal, evaluate_linear_optics,
    evaluate_linear_optics_from_device_signal, evaluate_linear_optics_from_prepared_device_signal,
    inspection_region_from_drag, prepare_raster, prepare_raster_from_device_signal,
    prepare_raster_from_prepared_device_signal,
};
use screen_camera::{CameraDevelopment, apply_sensor_white_balance_to_acescg};
use screen_color::{
    CameraOutputTransform, ColorEngine, DeviceColorTarget, OcioInputTransform, PreviewRgb,
    SourceColorInterpretation, SourceToDeviceProcessor, propose_ocio_input,
};
use screen_contracts::{
    DeviceRgb, FrameRate, LinearRgb, Meters, Millimeters, RationalTime, Vec2, Vec3,
};
use screen_cover::{
    COVER_GLASS_PRESETS, CoverGlassProfile, ENVIRONMENT_PRESETS, ProceduralEnvironment,
    cover_glass_preset, environment_preset,
};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation,
    LENS_PRESETS, LensModel, PanelRegion, Quaternion, ScreenTrack, TransformKeyframe,
    TransformTrack, lens_preset,
};
use screen_media::{
    AlphaInterpretation, AlphaPresence, DecodedFrame, FrameCadence, FrameSelectionPolicy,
    MediaDescriptor, ResolvedSignalRange, ResolvedSourceDecode, ResolvedYuvMatrix,
    SignalRangeSelection, SourceDecodeInterpretation, YuvMatrixSelection,
};
use screen_panel::{
    AnalyticBanding, DEVICE_PRESETS, LcdProfile, PanelColorimetry, PanelTemporalEmission,
    ResidualFlicker, StripeLayout, device_preset,
};
use screen_platform::{DisplayPublicationBackend, MetalDisplayPublication, MetalRawDevelopment};
use screen_platform::{decode_frame_at_time, probe_media};
use screen_sensor::{SensorProfile, SensorRegion};
use slint::{Image, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};

const DURATION_FRAMES: u32 = 96;
const DRAFT_PREVIEW_WIDTH: u16 = 360;
const PREVIEW_WIDTH: u16 = 960;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PreviewQuality {
    Draft,
    Medium,
    High,
}

slint::include_modules!();

#[derive(Clone, Copy, Debug, PartialEq)]
struct RenderControls {
    white_nits: f32,
    gamma: f32,
    black_matrix: f32,
    distance_m: f32,
    focal_mm: f32,
    focus_distance_m: f32,
    f_stop: f32,
    preview_exposure_ev: f32,
    white_balance_r: f32,
    white_balance_g: f32,
    white_balance_b: f32,
    camera_exposure_ev: f32,
    capture_exposure_index: f32,
    shutter_angle_degrees: f32,
    temporal_samples: f32,
    sensor_readout_index: i32,
    readout_duration_ms: f32,
    sensor_noise_seed: f32,
    neutral_density_stops: f32,
    output_transform_index: i32,
    capture_preset_index: i32,
    lens_preset_index: i32,
    cover_preset_index: i32,
    cover_strength: f32,
    panel_character_strength: f32,
    lens_character_strength: f32,
    environment_preset_index: i32,
    environment_strength: f32,
    environment_rotation_degrees: f32,
    capture_sensor_width: f32,
    capture_sensor_height: f32,
    capture_gate_width_mm: f32,
    capture_gate_height_mm: f32,
    render_quality_index: i32,
    device_native_width: f32,
    device_native_height: f32,
    device_active_width_mm: f32,
    device_active_height_mm: f32,
    yaw_degrees: f32,
    pitch_degrees: f32,
    focus_mode_index: i32,
    camera_interpolation_index: i32,
    stripe_index: i32,
    view_index: i32,
    frame_number: i32,
    placement_index: i32,
    idt_index: i32,
    alpha_index: i32,
    matrix_index: i32,
    range_index: i32,
    sample_policy_index: i32,
    project_fps_index: i32,
    procedural_pattern_index: i32,
    custom_fps_numerator: i32,
    custom_fps_denominator: i32,
}

fn render_controls(window: &MainWindow) -> RenderControls {
    RenderControls {
        white_nits: window.get_white_nits(),
        gamma: window.get_gamma(),
        black_matrix: window.get_black_matrix(),
        distance_m: window.get_distance_m(),
        focal_mm: window.get_focal_mm(),
        focus_distance_m: window.get_focus_distance_m(),
        f_stop: window.get_f_stop(),
        preview_exposure_ev: window.get_preview_exposure_ev(),
        white_balance_r: window.get_white_balance_r(),
        white_balance_g: window.get_white_balance_g(),
        white_balance_b: window.get_white_balance_b(),
        camera_exposure_ev: window.get_camera_exposure_ev(),
        capture_exposure_index: window.get_capture_exposure_index(),
        shutter_angle_degrees: window.get_shutter_angle_degrees(),
        temporal_samples: window.get_temporal_samples(),
        sensor_readout_index: window.get_sensor_readout_index(),
        readout_duration_ms: window.get_readout_duration_ms(),
        sensor_noise_seed: window.get_sensor_noise_seed(),
        neutral_density_stops: window.get_neutral_density_stops(),
        output_transform_index: window.get_output_transform_index(),
        capture_preset_index: window.get_capture_preset_index(),
        lens_preset_index: window.get_lens_preset_index(),
        cover_preset_index: window.get_cover_preset_index(),
        cover_strength: window.get_cover_strength(),
        panel_character_strength: window.get_panel_character_strength(),
        lens_character_strength: window.get_lens_character_strength(),
        environment_preset_index: window.get_environment_preset_index(),
        environment_strength: window.get_environment_strength(),
        environment_rotation_degrees: window.get_environment_rotation_degrees(),
        capture_sensor_width: window.get_capture_sensor_width(),
        capture_sensor_height: window.get_capture_sensor_height(),
        capture_gate_width_mm: window.get_capture_gate_width_mm(),
        capture_gate_height_mm: window.get_capture_gate_height_mm(),
        render_quality_index: window.get_render_quality_index(),
        device_native_width: window.get_device_native_width(),
        device_native_height: window.get_device_native_height(),
        device_active_width_mm: window.get_device_active_width_mm(),
        device_active_height_mm: window.get_device_active_height_mm(),
        yaw_degrees: window.get_yaw_degrees(),
        pitch_degrees: window.get_pitch_degrees(),
        focus_mode_index: window.get_focus_mode_index(),
        camera_interpolation_index: window.get_camera_interpolation_index(),
        stripe_index: window.get_stripe_index(),
        view_index: window.get_view_index(),
        frame_number: window.get_frame_number(),
        placement_index: window.get_placement_index(),
        idt_index: window.get_idt_index(),
        alpha_index: window.get_alpha_index(),
        matrix_index: window.get_matrix_index(),
        range_index: window.get_range_index(),
        sample_policy_index: window.get_sample_policy_index(),
        project_fps_index: window.get_project_fps_index(),
        procedural_pattern_index: window.get_procedural_pattern_index(),
        custom_fps_numerator: window.get_custom_fps_numerator(),
        custom_fps_denominator: window.get_custom_fps_denominator(),
    }
}

fn camera_edit_from_controls(controls: RenderControls, lens: LensModel) -> CameraEdit {
    CameraEdit {
        distance: controls.distance_m,
        yaw_degrees: controls.yaw_degrees,
        pitch_degrees: controls.pitch_degrees,
        focal_mm: controls.focal_mm,
        focus_distance_m: if controls.focus_mode_index == 0 {
            controls.distance_m
        } else {
            controls.focus_distance_m
        },
        f_stop: controls.f_stop,
        lens,
        interpolation: match controls.camera_interpolation_index {
            0 => KeyframeInterpolation::Hold,
            1 => KeyframeInterpolation::Linear,
            _ => KeyframeInterpolation::Smooth,
        },
    }
}

fn timeline_selection_changed(previous: RenderControls, current: RenderControls) -> bool {
    previous.frame_number != current.frame_number
        || previous.project_fps_index != current.project_fps_index
        || previous.custom_fps_numerator != current.custom_fps_numerator
        || previous.custom_fps_denominator != current.custom_fps_denominator
}

struct InteractionState {
    inspection: Option<PanelRegion>,
    source: Option<LoadedSource>,
    color_engine: ColorEngine,
    last_tick: Instant,
    playback_accumulator_seconds: f64,
    camera_editor: CameraEditor,
    screen: ScreenTrack,
    last_render_controls: Option<RenderControls>,
    last_capture_controls: Option<RenderControls>,
    capture_sensor: SensorProfile,
    capture_reference_exposure_index: f32,
    capture_middle_gray_at_reference_ei: f32,
    active_lens: LensModel,
    active_cover: CoverGlassProfile,
    active_environment: ProceduralEnvironment,
    capture_render_requested: bool,
    capture_cancel: Option<Arc<AtomicBool>>,
    latest_native_export: Arc<Mutex<Option<NativeExportFrame>>>,
    preview_pending: bool,
    embedded_source: Option<(i32, Arc<PreparedDeviceSignalRaster>)>,
}

struct CameraEditor {
    committed: CameraRig,
    preview: Option<CameraRig>,
    preview_inserted_key: bool,
    undo: Vec<CameraRig>,
    redo: Vec<CameraRig>,
    next_key_id: u64,
}

impl CameraEditor {
    fn new(committed: CameraRig, next_key_id: u64) -> Self {
        Self {
            committed,
            preview: None,
            preview_inserted_key: false,
            undo: Vec::new(),
            redo: Vec::new(),
            next_key_id,
        }
    }

    fn effective(&self) -> &CameraRig {
        self.preview.as_ref().unwrap_or(&self.committed)
    }

    fn preview_edit(&mut self, time: RationalTime, edit: CameraEdit) {
        let (preview, inserted) = camera_with_edit(
            &self.committed,
            time,
            edit,
            format!("camera-key-{}", self.next_key_id),
        );
        self.preview = Some(preview);
        self.preview_inserted_key = inserted;
    }

    fn commit_preview(&mut self) -> bool {
        let Some(preview) = self.preview.take() else {
            return false;
        };
        if preview == self.committed {
            self.preview_inserted_key = false;
            return false;
        }
        self.undo.push(self.committed.clone());
        self.committed = preview;
        self.redo.clear();
        if self.preview_inserted_key {
            self.next_key_id += 1;
        }
        self.preview_inserted_key = false;
        true
    }

    fn undo(&mut self) -> bool {
        if self.preview.take().is_some() {
            self.preview_inserted_key = false;
            return true;
        }
        let Some(previous) = self.undo.pop() else {
            return false;
        };
        self.redo.push(self.committed.clone());
        self.committed = previous;
        true
    }

    fn redo(&mut self) -> bool {
        if self.preview.is_some() {
            return false;
        }
        let Some(next) = self.redo.pop() else {
            return false;
        };
        self.undo.push(self.committed.clone());
        self.committed = next;
        true
    }

    fn cancel_preview(&mut self) -> bool {
        let changed = self.preview.take().is_some();
        self.preview_inserted_key = false;
        changed
    }

    fn can_undo(&self) -> bool {
        self.preview.is_some() || !self.undo.is_empty()
    }

    fn can_redo(&self) -> bool {
        self.preview.is_none() && !self.redo.is_empty()
    }
}

struct LoadedSource {
    path: PathBuf,
    descriptor: MediaDescriptor,
    decoded_sample_key: Option<DecodedSampleKey>,
    decoded_timestamp: Option<RationalTime>,
    decoded_frame: Option<DecodedFrame>,
    processor_interpretation: Option<SourceColorInterpretation>,
    color_processor: Option<SourceToDeviceProcessor>,
    prepared_signal_key: Option<(SourceColorInterpretation, AlphaInterpretation)>,
    device_signal: Option<DeviceSignalRaster>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DecodedSampleKey {
    requested_time: RationalTime,
    sample_policy: FrameSelectionPolicy,
    interpretation: ResolvedSourceDecode,
}

impl InteractionState {
    fn new(color_engine: ColorEngine) -> Self {
        Self {
            inspection: None,
            source: None,
            color_engine,
            last_tick: Instant::now(),
            playback_accumulator_seconds: 0.0,
            camera_editor: CameraEditor::new(
                camera_rig(vec![camera_keyframes(
                    "camera-key-0".to_owned(),
                    RationalTime::new(0, 1).expect("initial camera time is valid"),
                    CameraEdit {
                        distance: 0.82,
                        yaw_degrees: 0.0,
                        pitch_degrees: 0.0,
                        focal_mm: 50.0,
                        focus_distance_m: 0.82,
                        f_stop: 8.0,
                        lens: LensModel::REFERENCE_PHOTOGRAPHIC,
                        interpolation: KeyframeInterpolation::Smooth,
                    },
                )]),
                1,
            ),
            screen: TransformTrack {
                keyframes: vec![TransformKeyframe {
                    id: "screen-transform-0".to_owned(),
                    time: RationalTime::new(0, 1).expect("initial screen time is valid"),
                    translation: Vec3 {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                    },
                    rotation: Quaternion {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                        w: 1.0,
                    },
                    interpolation: KeyframeInterpolation::Hold,
                }],
            },
            last_render_controls: None,
            last_capture_controls: None,
            capture_sensor: CAPTURE_DEVICE_PRESETS[0].sensor,
            capture_reference_exposure_index: CAPTURE_DEVICE_PRESETS[0].reference_exposure_index,
            capture_middle_gray_at_reference_ei: CAPTURE_DEVICE_PRESETS[0]
                .middle_gray_illuminance_seconds_at_reference_ei,
            active_lens: lens_preset(CAPTURE_DEVICE_PRESETS[0].default_lens_preset_id)
                .expect("initial capture template lens must resolve")
                .lens,
            active_cover: cover_glass_preset("cover-glossy-strong-ar")
                .expect("initial cover preset must resolve")
                .profile,
            active_environment: environment_preset("environment-uniform-neutral")
                .expect("initial environment preset must resolve")
                .environment,
            capture_render_requested: false,
            capture_cancel: None,
            latest_native_export: Arc::new(Mutex::new(None)),
            preview_pending: false,
            embedded_source: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct CameraEdit {
    distance: f32,
    yaw_degrees: f32,
    pitch_degrees: f32,
    focal_mm: f32,
    focus_distance_m: f32,
    f_stop: f32,
    lens: LensModel,
    interpolation: KeyframeInterpolation,
}

fn camera_edit_from_window(window: &MainWindow, lens: LensModel) -> CameraEdit {
    CameraEdit {
        distance: window.get_distance_m(),
        yaw_degrees: window.get_yaw_degrees(),
        pitch_degrees: window.get_pitch_degrees(),
        focal_mm: window.get_focal_mm(),
        focus_distance_m: if window.get_focus_mode_index() == 0 {
            window.get_distance_m()
        } else {
            window.get_focus_distance_m()
        },
        f_stop: window.get_f_stop(),
        lens,
        interpolation: match window.get_camera_interpolation_index() {
            0 => KeyframeInterpolation::Hold,
            1 => KeyframeInterpolation::Linear,
            _ => KeyframeInterpolation::Smooth,
        },
    }
}

fn camera_keyframes(
    id: String,
    time: RationalTime,
    edit: CameraEdit,
) -> (TransformKeyframe, CameraIntrinsicsKeyframe) {
    let yaw = edit.yaw_degrees.to_radians();
    let pitch = edit.pitch_degrees.to_radians();
    let horizontal_distance = edit.distance * pitch.cos();
    (
        TransformKeyframe {
            id: format!("{id}-transform"),
            time,
            translation: Vec3 {
                x: horizontal_distance * yaw.sin(),
                y: edit.distance * pitch.sin(),
                z: horizontal_distance * yaw.cos(),
            },
            rotation: Quaternion::from_orbit_yaw_pitch_degrees(
                edit.yaw_degrees,
                edit.pitch_degrees,
            ),
            interpolation: edit.interpolation,
        },
        CameraIntrinsicsKeyframe {
            id: format!("{id}-intrinsics"),
            time,
            focal_length: Millimeters(edit.focal_mm),
            sensor_width: Millimeters(36.0),
            sensor_height: Millimeters(20.25),
            lens_shift: Vec2 { x: 0.0, y: 0.0 },
            focus_distance: Meters(edit.focus_distance_m),
            f_stop: edit.f_stop,
            near_clip: Meters(0.01),
            far_clip: Meters(100.0),
            lens: edit.lens,
            interpolation: edit.interpolation,
        },
    )
}

fn camera_rig(keys: Vec<(TransformKeyframe, CameraIntrinsicsKeyframe)>) -> CameraRig {
    let (transform, intrinsics): (Vec<_>, Vec<_>) = keys.into_iter().unzip();
    CameraRig {
        transform: TransformTrack {
            keyframes: transform,
        },
        intrinsics: CameraIntrinsicsTrack {
            keyframes: intrinsics,
        },
    }
}

fn camera_with_edit(
    committed: &CameraRig,
    time: RationalTime,
    edit: CameraEdit,
    inserted_id: String,
) -> (CameraRig, bool) {
    let mut result = committed.clone();
    match result
        .transform
        .keyframes
        .binary_search_by_key(&time, |item| item.time)
    {
        Ok(index) => {
            let transform_id = result.transform.keyframes[index].id.clone();
            let intrinsics_id = result.intrinsics.keyframes[index].id.clone();
            let (mut transform, mut intrinsics) = camera_keyframes(inserted_id, time, edit);
            transform.id = transform_id;
            intrinsics.id = intrinsics_id;
            result.transform.keyframes[index] = transform;
            result.intrinsics.keyframes[index] = intrinsics;
            (result, false)
        }
        Err(index) => {
            let (transform, intrinsics) = camera_keyframes(inserted_id, time, edit);
            result.transform.keyframes.insert(index, transform);
            result.intrinsics.keyframes.insert(index, intrinsics);
            (result, true)
        }
    }
}

fn set_camera_controls_from_committed(
    window: &MainWindow,
    editor: &CameraEditor,
    time: RationalTime,
) -> Result<LensModel, String> {
    let sample = editor
        .committed
        .sample(time)
        .map_err(|error| error.to_string())?;
    let distance = (sample.position.x * sample.position.x
        + sample.position.y * sample.position.y
        + sample.position.z * sample.position.z)
        .sqrt();
    let yaw_degrees = sample.position.x.atan2(sample.position.z).to_degrees();
    let pitch_degrees = (sample.position.y / distance)
        .clamp(-1.0, 1.0)
        .asin()
        .to_degrees();
    window.set_distance_m(distance);
    window.set_yaw_degrees(yaw_degrees);
    window.set_pitch_degrees(pitch_degrees);
    window.set_focal_mm(sample.focal_length.0);
    window.set_focus_distance_m(sample.focus_distance.0);
    window.set_f_stop(sample.f_stop);
    let lens_index = LENS_PRESETS
        .iter()
        .position(|preset| {
            preset.lens == sample.lens
                && (preset.nominal_focal_length.0 - sample.focal_length.0).abs() < 1.0e-4
        })
        .unwrap_or(LENS_PRESETS.len());
    window.set_lens_preset_index(lens_index as i32);
    window.set_lens_summary(
        if lens_index == LENS_PRESETS.len() {
            "Custom / animated lens parameters"
        } else {
            match LENS_PRESETS[lens_index].authority {
                screen_geometry::LensPresetAuthority::GenericApproximation => {
                    "Generic photographic approximation"
                }
                screen_geometry::LensPresetAuthority::CalibratedApproximation => {
                    "Calibrated integrated-lens approximation"
                }
            }
        }
        .into(),
    );
    let interpolation = editor
        .committed
        .transform
        .keyframes
        .binary_search_by_key(&time, |item| item.time)
        .map(|index| editor.committed.transform.keyframes[index].interpolation)
        .unwrap_or_else(|index| {
            editor.committed.transform.keyframes[index.saturating_sub(1)].interpolation
        });
    window.set_camera_interpolation_index(match interpolation {
        KeyframeInterpolation::Hold => 0,
        KeyframeInterpolation::Linear => 1,
        KeyframeInterpolation::Smooth => 2,
    });
    Ok(sample.lens)
}

fn update_undo_availability(window: &MainWindow, editor: &CameraEditor) {
    window.set_can_undo(editor.can_undo());
    window.set_can_redo(editor.can_redo());
    window.set_camera_edit_pending(editor.preview.is_some());
}

fn source_color_interpretation(
    window: &MainWindow,
) -> Option<(SourceColorInterpretation, &'static str)> {
    match window.get_idt_index() {
        0 => None,
        1 => Some((
            SourceColorInterpretation::IdentityDeviceSignal,
            "Identity device signal",
        )),
        index => OcioInputTransform::ALL
            .get(usize::try_from(index - 2).ok()?)
            .copied()
            .map(|input| (SourceColorInterpretation::Ocio(input), input.label())),
    }
}

fn project_frame_rate(window: &MainWindow) -> Result<FrameRate, String> {
    let fraction = match window.get_project_fps_index() {
        0 => (24_000, 1_001),
        1 => (24, 1),
        2 => (25, 1),
        3 => (30_000, 1_001),
        4 => (30, 1),
        5 => (50, 1),
        6 => (60_000, 1_001),
        7 => (60, 1),
        _ => {
            let numerator = u32::try_from(window.get_custom_fps_numerator())
                .map_err(|_| "custom FPS numerator must be positive".to_owned())?;
            let denominator = u32::try_from(window.get_custom_fps_denominator())
                .map_err(|_| "custom FPS denominator must be positive".to_owned())?;
            (numerator, denominator)
        }
    };
    FrameRate::new(fraction.0, fraction.1).map_err(|error| error.to_string())
}

fn frame_selection_policy(window: &MainWindow) -> FrameSelectionPolicy {
    match window.get_sample_policy_index() {
        0 => FrameSelectionPolicy::Exact,
        2 => FrameSelectionPolicy::Nearest,
        _ => FrameSelectionPolicy::Floor,
    }
}

fn source_decode_interpretation(window: &MainWindow) -> SourceDecodeInterpretation {
    SourceDecodeInterpretation {
        matrix: match window.get_matrix_index() {
            1 => YuvMatrixSelection::Bt709,
            2 => YuvMatrixSelection::Bt601,
            3 => YuvMatrixSelection::Bt2020,
            _ => YuvMatrixSelection::Auto,
        },
        range: match window.get_range_index() {
            1 => SignalRangeSelection::Limited,
            2 => SignalRangeSelection::Full,
            _ => SignalRangeSelection::Auto,
        },
    }
}

fn decode_interpretation_description(interpretation: ResolvedSourceDecode) -> &'static str {
    match interpretation {
        ResolvedSourceDecode::Rgb => "RGB",
        ResolvedSourceDecode::Monochrome(ResolvedSignalRange::Limited) => "Mono Limited",
        ResolvedSourceDecode::Monochrome(ResolvedSignalRange::Full) => "Mono Full",
        ResolvedSourceDecode::Yuv(yuv) => match (yuv.matrix, yuv.range) {
            (ResolvedYuvMatrix::Bt601, ResolvedSignalRange::Limited) => "YUV Rec.601 Limited",
            (ResolvedYuvMatrix::Bt601, ResolvedSignalRange::Full) => "YUV Rec.601 Full",
            (ResolvedYuvMatrix::Bt709, ResolvedSignalRange::Limited) => "YUV Rec.709 Limited",
            (ResolvedYuvMatrix::Bt709, ResolvedSignalRange::Full) => "YUV Rec.709 Full",
            (ResolvedYuvMatrix::Bt2020, ResolvedSignalRange::Limited) => "YUV Rec.2020 Limited",
            (ResolvedYuvMatrix::Bt2020, ResolvedSignalRange::Full) => "YUV Rec.2020 Full",
        },
    }
}

fn simulation_request(
    window: &MainWindow,
    inspection: Option<PanelRegion>,
    camera: &CameraRig,
    screen: &ScreenTrack,
    authored_cover: CoverGlassProfile,
    authored_environment: ProceduralEnvironment,
) -> Result<SimulationRequest, String> {
    let frame_rate = project_frame_rate(window)?;
    let (native_width, native_height, active_width, active_height) = device_geometry(window)?;
    let view = match window.get_view_index() {
        1 => DiagnosticView::DeviceSignal,
        2 => DiagnosticView::Subpixels,
        3 => DiagnosticView::EmittedRadiance,
        _ => DiagnosticView::Composite,
    };
    let gate_width = window.get_capture_gate_width_mm();
    let gate_height = window.get_capture_gate_height_mm();
    if !gate_width.is_finite()
        || !gate_height.is_finite()
        || gate_width <= 0.0
        || gate_height <= 0.0
    {
        return Err("capture gate must have finite positive dimensions".to_owned());
    }
    let mut camera = camera.clone();
    let lens_character_strength = window.get_lens_character_strength();
    if !lens_character_strength.is_finite() || !(0.0..=4.0).contains(&lens_character_strength) {
        return Err("lens amount must be finite and within 0–4".to_owned());
    }
    for keyframe in &mut camera.intrinsics.keyframes {
        keyframe.sensor_width = Millimeters(gate_width);
        keyframe.sensor_height = Millimeters(gate_height);
    }
    let viewport_aspect = gate_width / gate_height;
    window.set_preview_aspect(viewport_aspect);
    let flicker_hz = window.get_panel_flicker_hz();
    let flicker_percent = window.get_panel_flicker_percent();
    let banding_hz = window.get_panel_banding_hz();
    let banding_duty_percent = window.get_panel_banding_duty_percent();
    let banding_amount = window.get_panel_banding_amount();
    if !flicker_hz.is_finite()
        || !(10.0..=4_000.0).contains(&flicker_hz)
        || !flicker_percent.is_finite()
        || !(0.0..=10.0).contains(&flicker_percent)
        || !banding_hz.is_finite()
        || !(10.0..=4_000.0).contains(&banding_hz)
        || !banding_duty_percent.is_finite()
        || !(1.0..=100.0).contains(&banding_duty_percent)
        || !banding_amount.is_finite()
        || !(0.0..=1.0).contains(&banding_amount)
    {
        return Err("panel temporal controls are outside the certified range".to_owned());
    }
    let flicker_period =
        RationalTime::new(1, flicker_hz.round() as u32).map_err(|error| error.to_string())?;
    let banding_frequency = banding_hz.round() as u32;
    let banding_period =
        RationalTime::new(1, banding_frequency).map_err(|error| error.to_string())?;
    let banding_on_duration =
        RationalTime::new(banding_duty_percent.round() as i64, banding_frequency * 100)
            .map_err(|error| error.to_string())?;
    let mut cover = authored_cover;
    cover.character_strength = window.get_cover_strength();
    let mut environment = authored_environment;
    environment.character_strength = window.get_environment_strength();
    environment.rotation_degrees = window.get_environment_rotation_degrees();
    Ok(SimulationRequest {
        optics: OpticalRequest {
            time: frame_rate
                .time_at_frame(i64::from(window.get_frame_number()))
                .map_err(|error| error.to_string())?,
            panel_temporal_evaluation: PanelTemporalEvaluation::Instantaneous,
            panel_character_strength: window.get_panel_character_strength(),
            lens_character_strength,
            viewport_aspect,
            panel: LcdProfile {
                native_width,
                native_height,
                active_width,
                active_height,
                stripe_layout: if window.get_stripe_index() == 1 {
                    StripeLayout::Bgr
                } else {
                    StripeLayout::Rgb
                },
                black_matrix_fraction: window.get_black_matrix(),
                eotf_gamma: window.get_gamma(),
                black_level_nits: 0.08,
                white_level_nits: window.get_white_nits(),
                colorimetry: PanelColorimetry::SRGB_D65,
                angular_emission_power: LinearRgb::new(1.7, 1.5, 1.8),
                temporal_emission: PanelTemporalEmission {
                    residual_flicker: ResidualFlicker {
                        period: flicker_period,
                        amplitude: flicker_percent / 100.0,
                        phase: RationalTime::new(0, 1).expect("zero phase is valid"),
                    },
                    analytic_banding: AnalyticBanding {
                        period: banding_period,
                        on_duration: banding_on_duration,
                        phase: RationalTime::new(0, 1).expect("zero phase is valid"),
                        amount: banding_amount,
                    },
                },
            },
            cover,
            environment,
            camera,
            screen: screen.clone(),
            inspection,
            procedural_pattern: match window.get_procedural_pattern_index() {
                1 => ProceduralTestPattern::EyeChart,
                5 => ProceduralTestPattern::PhotometricDeviceScale,
                _ => ProceduralTestPattern::AnimatedCheckerboard,
            },
        },
        view,
        preview_exposure_ev: window.get_preview_exposure_ev(),
    })
}

fn preview_raster(window: &MainWindow, width: u16) -> Result<(u16, u16), String> {
    let aspect = window.get_preview_aspect();
    if !aspect.is_finite() || aspect <= 0.0 {
        return Err("capture preview aspect must be finite and positive".to_owned());
    }
    let height = (f32::from(width) / aspect).round();
    if !(1.0..=f32::from(u16::MAX)).contains(&height) {
        return Err("capture preview raster is outside the supported range".to_owned());
    }
    let height = height as u16;
    let quantized_width = (f32::from(height) * aspect).round();
    if !(1.0..=f32::from(u16::MAX)).contains(&quantized_width) {
        return Err("capture preview raster is outside the supported range".to_owned());
    }
    Ok((quantized_width as u16, height))
}

fn device_geometry(window: &MainWindow) -> Result<(u32, u32, Meters, Meters), String> {
    let width = window.get_device_native_width();
    let height = window.get_device_native_height();
    let active_width_mm = window.get_device_active_width_mm();
    let active_height_mm = window.get_device_active_height_mm();
    if !width.is_finite()
        || !height.is_finite()
        || width.fract() != 0.0
        || height.fract() != 0.0
        || !(320.0..=8_192.0).contains(&width)
        || !(240.0..=8_192.0).contains(&height)
    {
        return Err(
            "device native resolution must contain complete pixels in the supported range"
                .to_owned(),
        );
    }
    if !active_width_mm.is_finite()
        || !active_height_mm.is_finite()
        || !(40.0..=2_000.0).contains(&active_width_mm)
        || !(40.0..=1_200.0).contains(&active_height_mm)
    {
        return Err("device active dimensions must be finite physical millimeters".to_owned());
    }
    Ok((
        width as u32,
        height as u32,
        Meters(active_width_mm * 0.001),
        Meters(active_height_mm * 0.001),
    ))
}

fn update_device_summary(window: &MainWindow) {
    let Ok((width, height, active_width, active_height)) = device_geometry(window) else {
        window.set_device_summary("Invalid device geometry".into());
        return;
    };
    let diagonal_pixels = (width as f32).hypot(height as f32);
    let diagonal_meters = active_width.0.hypot(active_height.0);
    let ppi = diagonal_pixels / (diagonal_meters / 0.0254);
    let pitch_mm = active_width.0 * 1_000.0 / width as f32;
    window.set_device_summary(
        format!(
            "{:.1} in · {:.1} PPI · {:.3} mm pixel pitch",
            diagonal_meters / 0.0254,
            ppi,
            pitch_mm
        )
        .into(),
    );
}

fn apply_device_preset(
    window: &MainWindow,
    state: &mut InteractionState,
    id: &str,
) -> Result<(), String> {
    if id == "custom" {
        window.set_device_reference_white_nits(window.get_white_nits());
        window.set_device_white_basis("Custom authored operating white".into());
        update_device_summary(window);
        return Ok(());
    }
    let preset =
        device_preset(id).ok_or_else(|| format!("unknown current device preset id {id}"))?;
    window.set_device_native_width(preset.native_width as f32);
    window.set_device_native_height(preset.native_height as f32);
    window.set_device_active_width_mm(preset.active_width.0 * 1_000.0);
    window.set_device_active_height_mm(preset.active_height.0 * 1_000.0);
    window.set_white_nits(preset.reference_white_nits);
    window.set_device_reference_white_nits(preset.reference_white_nits);
    window.set_device_white_basis(preset.white_basis.into());
    apply_cover_preset(window, state, preset.default_cover_glass_preset_id)?;
    update_device_summary(window);
    Ok(())
}

fn apply_cover_preset(
    window: &MainWindow,
    state: &mut InteractionState,
    id: &str,
) -> Result<(), String> {
    if id == "custom" {
        window.set_cover_preset_index(COVER_GLASS_PRESETS.len() as i32);
        window.set_cover_summary("Custom complete optical-cover parameters".into());
        return Ok(());
    }
    let preset = cover_glass_preset(id)
        .ok_or_else(|| format!("unknown current cover-glass preset id {id}"))?;
    let index = COVER_GLASS_PRESETS
        .iter()
        .position(|candidate| candidate.id == id)
        .expect("resolved cover preset belongs to the current catalog");
    state.active_cover = preset.profile;
    window.set_cover_preset_index(index as i32);
    window.set_cover_strength(preset.profile.character_strength);
    window.set_cover_summary(
        format!(
            "{:.2} mm · IOR {:.2} · roughness {:.2}",
            preset.profile.thickness_millimeters,
            preset.profile.refractive_index,
            preset.profile.roughness
        )
        .into(),
    );
    Ok(())
}

fn apply_environment_preset(
    window: &MainWindow,
    state: &mut InteractionState,
    id: &str,
) -> Result<(), String> {
    if id == "custom" {
        window.set_environment_preset_index(ENVIRONMENT_PRESETS.len() as i32);
        window.set_environment_summary("Custom synthetic linear HDR environment".into());
        return Ok(());
    }
    let preset = environment_preset(id)
        .ok_or_else(|| format!("unknown current environment preset id {id}"))?;
    let index = ENVIRONMENT_PRESETS
        .iter()
        .position(|candidate| candidate.id == id)
        .expect("resolved environment preset belongs to the current catalog");
    state.active_environment = preset.environment;
    window.set_environment_preset_index(index as i32);
    window.set_environment_strength(preset.environment.character_strength);
    window.set_environment_rotation_degrees(preset.environment.rotation_degrees);
    window.set_environment_summary("Synthetic latitude-longitude HDR · linear ACEScg".into());
    Ok(())
}

fn apply_capture_preset(
    window: &MainWindow,
    state: &mut InteractionState,
    id: &str,
) -> Result<(), String> {
    if id == "custom" {
        window.set_capture_preset_index(CAPTURE_DEVICE_PRESETS.len() as i32);
        window.set_capture_fixed_optics(false);
        window.set_capture_summary("Custom complete capture profile".into());
        state.last_capture_controls = None;
        return Ok(());
    }
    let preset = capture_device_preset(id)
        .ok_or_else(|| format!("unknown current capture preset id {id}"))?;
    let preset_index = CAPTURE_DEVICE_PRESETS
        .iter()
        .position(|candidate| candidate.id == id)
        .expect("resolved capture preset belongs to the current catalog");
    window.set_capture_preset_index(preset_index as i32);
    state.capture_sensor = preset.sensor;
    state.capture_reference_exposure_index = preset.reference_exposure_index;
    state.capture_middle_gray_at_reference_ei =
        preset.middle_gray_illuminance_seconds_at_reference_ei;
    state.last_capture_controls = None;
    window.set_capture_sensor_width(f32::from(preset.sensor.native_width));
    window.set_capture_sensor_height(f32::from(preset.sensor.native_height));
    window.set_capture_gate_width_mm(preset.gate_width.0);
    window.set_capture_gate_height_mm(preset.gate_height.0);
    window.set_focal_mm(preset.focal_length.0);
    window.set_f_stop(preset.f_stop);
    window.set_capture_exposure_index(preset.reference_exposure_index);
    window.set_shutter_angle_degrees(preset.default_shutter_angle_degrees);
    window.set_temporal_samples(f32::from(preset.default_temporal_samples));
    window.set_sensor_readout_index(1);
    window.set_readout_duration_ms(preset.default_readout_duration_milliseconds);
    window.set_neutral_density_stops(0.0);
    window.set_capture_fixed_optics(
        preset.optics_authority == CaptureOpticsAuthority::IntegratedFixedLens,
    );
    apply_lens_preset(window, state, preset.default_lens_preset_id)?;
    window.set_capture_summary(preset.calibration.into());
    window.set_preview_aspect(preset.gate_width.0 / preset.gate_height.0);
    Ok(())
}

fn apply_lens_preset(
    window: &MainWindow,
    state: &mut InteractionState,
    id: &str,
) -> Result<(), String> {
    if id == "custom" {
        window.set_lens_preset_index(LENS_PRESETS.len() as i32);
        window.set_lens_summary("Custom complete lens parameters".into());
        return Ok(());
    }
    let preset = lens_preset(id).ok_or_else(|| format!("unknown current lens preset id {id}"))?;
    let index = LENS_PRESETS
        .iter()
        .position(|candidate| candidate.id == id)
        .expect("resolved lens preset belongs to the current catalog");
    state.active_lens = preset.lens;
    window.set_lens_preset_index(index as i32);
    window.set_focal_mm(preset.nominal_focal_length.0);
    window.set_lens_summary(
        match preset.authority {
            screen_geometry::LensPresetAuthority::GenericApproximation => {
                "Generic photographic approximation"
            }
            screen_geometry::LensPresetAuthority::CalibratedApproximation => {
                "Calibrated integrated-lens approximation"
            }
        }
        .into(),
    );
    Ok(())
}

fn capture_sensor(window: &MainWindow, state: &InteractionState) -> Result<SensorProfile, String> {
    let width = window.get_capture_sensor_width();
    let height = window.get_capture_sensor_height();
    if !width.is_finite()
        || !height.is_finite()
        || width.fract() != 0.0
        || height.fract() != 0.0
        || !(64.0..=f32::from(u16::MAX)).contains(&width)
        || !(64.0..=f32::from(u16::MAX)).contains(&height)
    {
        return Err(
            "capture raster must contain complete photosites in the supported range".into(),
        );
    }
    let sensor = SensorProfile {
        native_width: width as u16,
        native_height: height as u16,
        ..state.capture_sensor
    };
    sensor.validate().map_err(|error| error.to_string())
}

fn selected_sensor_region(window: &MainWindow, sensor: SensorProfile) -> SensorRegion {
    if window.get_render_quality_index() == 4 {
        return SensorRegion::full(sensor);
    }
    let width = sensor.native_width.min(1_024);
    let height = sensor.native_height.min(1_024);
    SensorRegion {
        origin_x: (sensor.native_width - width) / 2,
        origin_y: (sensor.native_height - height) / 2,
        width,
        height,
    }
}

fn embedded_test_signal(
    state: &mut InteractionState,
    pattern_index: i32,
) -> Result<Option<Arc<PreparedDeviceSignalRaster>>, String> {
    let encoded = match pattern_index {
        2 => include_bytes!("../assets/editorial-text-reference.png").as_slice(),
        3 => include_bytes!("../assets/camera-color-reference.png").as_slice(),
        4 => include_bytes!("../assets/frequency-moire-reference.png").as_slice(),
        _ => {
            state.embedded_source = None;
            return Ok(None);
        }
    };
    if let Some((cached_index, signal)) = &state.embedded_source
        && *cached_index == pattern_index
    {
        return Ok(Some(Arc::clone(signal)));
    }
    let decoded = image::load_from_memory_with_format(encoded, image::ImageFormat::Png)
        .map_err(|error| format!("bundled test image cannot be decoded: {error}"))?
        .into_rgb8();
    let width = decoded.width();
    let height = decoded.height();
    if [width, height] != [3_840, 2_160] {
        return Err(format!(
            "bundled test image must be 3840 × 2160, got {width} × {height}"
        ));
    }
    let pixels = decoded
        .pixels()
        .map(|pixel| {
            DeviceRgb::new(
                f32::from(pixel[0]) / 255.0,
                f32::from(pixel[1]) / 255.0,
                f32::from(pixel[2]) / 255.0,
            )
        })
        .collect();
    let signal = Arc::new(
        PreparedDeviceSignalRaster::new(DeviceSignalRaster {
            width,
            height,
            pixels,
        })
        .map_err(|error| error.to_string())?,
    );
    state.embedded_source = Some((pattern_index, Arc::clone(&signal)));
    Ok(Some(signal))
}

fn render_preview(window: &MainWindow, state: &mut InteractionState) {
    let current_controls = render_controls(window);
    if window.get_capture_rendering() {
        if state.last_capture_controls != Some(current_controls) {
            if let Some(cancel) = &state.capture_cancel {
                cancel.store(true, Ordering::Relaxed);
            }
            window.set_render_text("Cancelling stale native capture…".into());
            window.set_native_capture_stale(window.get_native_capture_ready());
        }
        return;
    }
    if window.get_preview_rendering() {
        state.preview_pending = true;
        window.set_preview_invalidated(true);
        window.set_render_text("Cancelling stale preview · selected quality queued".into());
        return;
    }
    let preview_quality = match window.get_render_quality_index() {
        0 => PreviewQuality::Draft,
        1 => PreviewQuality::Medium,
        2 => PreviewQuality::High,
        _ => PreviewQuality::Medium,
    };
    let native_quality = window.get_render_quality_index() >= 3;
    window.set_preview_invalidated(false);
    state.last_render_controls = Some(current_controls);
    if state.source.is_none() {
        present_procedural_source(window);
    }
    let started = Instant::now();
    let request = match simulation_request(
        window,
        state.inspection,
        state.camera_editor.effective(),
        &state.screen,
        state.active_cover,
        state.active_environment,
    ) {
        Ok(request) => request,
        Err(error) => {
            block_preview(window, &error);
            return;
        }
    };
    let raster_width = match preview_quality {
        PreviewQuality::Draft => DRAFT_PREVIEW_WIDTH,
        PreviewQuality::Medium => PREVIEW_WIDTH,
        PreviewQuality::High => PREVIEW_WIDTH * 2,
    };
    let (preview_width, preview_height) = match preview_raster(window, raster_width) {
        Ok(value) => value,
        Err(error) => {
            block_preview(window, &error);
            return;
        }
    };
    let capture_selection =
        if window.get_view_index() == 4 && native_quality && state.capture_render_requested {
            match capture_sensor(window, state) {
                Ok(sensor) => {
                    let cancel = Arc::new(AtomicBool::new(false));
                    state.capture_cancel = Some(Arc::clone(&cancel));
                    window.set_capture_rendering(true);
                    Some((sensor, selected_sensor_region(window, sensor), cancel))
                }
                Err(error) => {
                    block_preview(window, &error);
                    state.capture_render_requested = false;
                    return;
                }
            }
        } else {
            None
        };
    if window.get_view_index() == 4 && native_quality && !state.capture_render_requested {
        if state.last_capture_controls != Some(current_controls) {
            window.set_native_capture_stale(window.get_native_capture_ready());
            window.set_scale_text(if window.get_native_capture_ready() {
                "PREVIOUS COMPLETE CAPTURE · STALE".into()
            } else {
                "NATIVE CAPTURE NOT RENDERED".into()
            });
            window.set_render_text("Ready for one explicit frame".into());
            window.set_inspection_text("CAPTURE DEVICE · SENSOR SPACE".into());
            window.set_hint_text("Render controls are beside the camera selector".into());
            window.set_error_text("".into());
        }
        return;
    }
    let embedded_signal = if state.source.is_none() {
        match embedded_test_signal(state, window.get_procedural_pattern_index()) {
            Ok(signal) => signal,
            Err(error) => {
                block_preview(window, &error);
                return;
            }
        }
    } else {
        None
    };
    let color_engine = &state.color_engine;
    if window.get_view_index() == 4 && native_quality && state.source.is_none() {
        let (sensor, region, cancel) = capture_selection.expect("capture selection resolved above");
        render_camera_result(
            window,
            request,
            embedded_signal.map_or(NativeCaptureSource::Procedural, |signal| {
                NativeCaptureSource::Static {
                    signal,
                    placement: RasterPlacement::Fit,
                }
            }),
            CapturePhotometricProfile {
                sensor,
                reference_exposure_index: state.capture_reference_exposure_index,
                middle_gray_at_reference_ei: state.capture_middle_gray_at_reference_ei,
            },
            region,
            NativeRenderSession {
                started,
                cancel,
                latest_export: Arc::clone(&state.latest_native_export),
            },
        );
        state.capture_render_requested = false;
        state.last_capture_controls = Some(current_controls);
        return;
    }
    let preview_source = match &mut state.source {
        None => embedded_signal.map_or(PreviewJobSource::Procedural, |signal| {
            PreviewJobSource::PreparedDeviceSignal(signal, RasterPlacement::Fit)
        }),
        Some(source) => {
            let decode_interpretation = match source
                .descriptor
                .resolve_decode_interpretation(source_decode_interpretation(window))
            {
                Ok(interpretation) => interpretation,
                Err(error) => {
                    block_preview(window, &error.to_string());
                    return;
                }
            };
            let Some((interpretation, _)) = source_color_interpretation(window) else {
                block_preview(window, "Select an authoritative source IDT");
                return;
            };
            if source.descriptor.alpha == AlphaPresence::Present
                && !matches!(window.get_alpha_index(), 1 | 2)
            {
                block_preview(
                    window,
                    "Alpha metadata cannot resolve association; choose Straight or Premultiplied",
                );
                return;
            }
            let alpha_interpretation = match (source.descriptor.alpha, window.get_alpha_index()) {
                (AlphaPresence::Absent, _) | (AlphaPresence::Present, 1) => {
                    AlphaInterpretation::Straight
                }
                (AlphaPresence::Present, 2) => AlphaInterpretation::Premultiplied,
                _ => unreachable!("alpha association was validated before sample refresh"),
            };
            let sample_policy = frame_selection_policy(window);
            let sample_key = DecodedSampleKey {
                requested_time: request.optics.time,
                sample_policy,
                interpretation: decode_interpretation,
            };
            if source.decoded_sample_key != Some(sample_key)
                && let Err(error) = refresh_loaded_source(source, sample_key)
            {
                block_preview(window, &error);
                return;
            }
            if let Err(error) =
                ensure_device_signal(source, color_engine, interpretation, alpha_interpretation)
            {
                block_preview(window, &error.to_string());
                return;
            }
            let signal = source
                .device_signal
                .as_ref()
                .expect("source interpretation was prepared before raster evaluation");
            let placement = match window.get_placement_index() {
                1 => RasterPlacement::FillCrop,
                2 => RasterPlacement::Stretch,
                3 => RasterPlacement::OneToOne,
                _ => RasterPlacement::Fit,
            };
            if window.get_view_index() == 4 && native_quality {
                let (sensor, region, cancel) =
                    capture_selection.expect("capture selection resolved above");
                render_camera_result(
                    window,
                    request,
                    NativeCaptureSource::Media(Box::new(NativeMediaSource {
                        path: source.path.clone(),
                        descriptor: source.descriptor.clone(),
                        decode_interpretation,
                        color_interpretation: interpretation,
                        alpha_interpretation,
                        sample_policy,
                        placement,
                    })),
                    CapturePhotometricProfile {
                        sensor,
                        reference_exposure_index: state.capture_reference_exposure_index,
                        middle_gray_at_reference_ei: state.capture_middle_gray_at_reference_ei,
                    },
                    region,
                    NativeRenderSession {
                        started,
                        cancel,
                        latest_export: Arc::clone(&state.latest_native_export),
                    },
                );
                state.capture_render_requested = false;
                state.last_capture_controls = Some(current_controls);
                return;
            }
            present_loaded_source_interpretation(window, source, sample_key, decode_interpretation);
            PreviewJobSource::DeviceSignal(signal.clone(), placement)
        }
    };
    let camera_preview_settings = if window.get_view_index() == 4 {
        match capture_pipeline_settings(
            window,
            CapturePhotometricProfile {
                sensor: state.capture_sensor,
                reference_exposure_index: state.capture_reference_exposure_index,
                middle_gray_at_reference_ei: state.capture_middle_gray_at_reference_ei,
            },
        ) {
            Ok(settings) => Some(settings),
            Err(error) => {
                block_preview(window, &error);
                return;
            }
        }
    } else {
        None
    };
    state.last_render_controls = Some(current_controls);
    render_preview_async(
        window,
        PreviewRenderJob {
            request,
            source: preview_source,
            width: preview_width,
            height: preview_height,
            started,
            quality: preview_quality,
            camera_settings: camera_preview_settings,
        },
    );
}

enum PreviewJobSource {
    Procedural,
    DeviceSignal(DeviceSignalRaster, RasterPlacement),
    PreparedDeviceSignal(Arc<PreparedDeviceSignalRaster>, RasterPlacement),
}

struct PreviewRenderJob {
    request: SimulationRequest,
    source: PreviewJobSource,
    width: u16,
    height: u16,
    started: Instant,
    quality: PreviewQuality,
    camera_settings: Option<CapturePipelineSettings>,
}

#[derive(Clone, Copy)]
struct PreviewPresentation {
    width: u16,
    height: u16,
    rendered_view_index: i32,
    started: Instant,
    quality: PreviewQuality,
    camera_preview: bool,
}

fn render_preview_async(window: &MainWindow, job: PreviewRenderJob) {
    let PreviewRenderJob {
        request,
        source,
        width,
        height,
        started,
        quality,
        camera_settings,
    } = job;
    window.set_preview_rendering(true);
    window.set_render_progress_visible(true);
    window.set_render_progress(0.05);
    let quality_label = match quality {
        PreviewQuality::Draft => "Draft",
        PreviewQuality::Medium => "Medium",
        PreviewQuality::High => "High",
    };
    window
        .set_render_progress_label(format!("{quality_label} preview · {width} × {height}").into());
    window.set_render_text(format!("Rendering {quality_label} preview…").into());
    window.set_error_text("".into());
    let rendered_view_index = window.get_view_index();
    let camera_preview = camera_settings.is_some();
    let weak_window = window.as_weak();
    thread::spawn(move || {
        let result = if let Some(settings) = camera_settings {
            prepare_camera_preview_raster(request, source, width, height, settings)
        } else {
            match source {
                PreviewJobSource::Procedural => prepare_raster(request, width, height),
                PreviewJobSource::DeviceSignal(signal, placement) => {
                    prepare_raster_from_device_signal(request, width, height, &signal, placement)
                }
                PreviewJobSource::PreparedDeviceSignal(signal, placement) => {
                    prepare_raster_from_prepared_device_signal(
                        request, width, height, &signal, placement,
                    )
                }
            }
            .map_err(|error| error.to_string())
        };
        let _ = weak_window.upgrade_in_event_loop(move |window| {
            window.set_preview_rendering(false);
            window.set_render_progress(1.0);
            window.set_render_progress_visible(false);
            match result {
                Ok(raster) => present_preview_raster(
                    &window,
                    raster,
                    PreviewPresentation {
                        width,
                        height,
                        rendered_view_index,
                        started,
                        quality,
                        camera_preview,
                    },
                ),
                Err(error) => block_preview(&window, &error),
            }
            window.invoke_continue_preview_render();
        });
    });
}

fn prepare_camera_preview_raster(
    request: SimulationRequest,
    source: PreviewJobSource,
    width: u16,
    height: u16,
    settings: CapturePipelineSettings,
) -> Result<PreparedRaster, String> {
    let linear = match source {
        PreviewJobSource::Procedural => evaluate_linear_optics(request.optics, width, height),
        PreviewJobSource::DeviceSignal(signal, placement) => {
            evaluate_linear_optics_from_device_signal(
                request.optics,
                width,
                height,
                &signal,
                placement,
            )
        }
        PreviewJobSource::PreparedDeviceSignal(signal, placement) => {
            evaluate_linear_optics_from_prepared_device_signal(
                request.optics,
                width,
                height,
                &signal,
                placement,
            )
        }
    }
    .map_err(|error| error.to_string())?;
    let development = settings.development;
    let exposure_scale = camera_preview_exposure_scale(settings);
    let mut rgba = Vec::with_capacity(linear.pixels.len() * 4);
    for pixel in &linear.pixels {
        let exposed = LinearRgb::new(
            pixel.acescg_irradiance.r * exposure_scale,
            pixel.acescg_irradiance.g * exposure_scale,
            pixel.acescg_irradiance.b * exposure_scale,
        );
        let corrected = apply_sensor_white_balance_to_acescg(
            exposed,
            settings.sensor,
            development.white_balance,
        )
        .map_err(|error| error.to_string())?;
        rgba.extend_from_slice(&[corrected.r, corrected.g, corrected.b, 1.0]);
    }
    ColorEngine::bundled()
        .map_err(|error| error.to_string())?
        .camera_output_processor(settings.transform)
        .map_err(|error| error.to_string())?
        .apply_acescg_rgba_buffer(&mut rgba)
        .map_err(|error| error.to_string())?;
    let pixels = linear
        .pixels
        .iter()
        .zip(rgba.chunks_exact(4))
        .map(|(source, output)| PreviewPixel {
            rgb: PreviewRgb {
                r: output[0],
                g: output[1],
                b: output[2],
            },
            on_panel: source.on_panel,
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

fn camera_preview_exposure_scale(settings: CapturePipelineSettings) -> f32 {
    settings.shutter_duration.as_seconds() as f32 * (-settings.neutral_density_stops).exp2() * 0.18
        / settings.development.middle_gray_illuminance_seconds
        * settings.development.develop_exposure_ev.exp2()
}

fn present_preview_raster(
    window: &MainWindow,
    raster: PreparedRaster,
    presentation: PreviewPresentation,
) {
    let PreviewPresentation {
        width,
        height,
        rendered_view_index,
        started,
        quality,
        camera_preview,
    } = presentation;
    if window.get_preview_invalidated() {
        return;
    }
    window.set_native_pyramid_ready(false);
    let mut buffer = SharedPixelBuffer::<Rgba8Pixel>::new(u32::from(width), u32::from(height));
    for (target, source) in buffer.make_mut_slice().iter_mut().zip(&raster.pixels) {
        let channel = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
        *target = if source.on_panel {
            Rgba8Pixel {
                r: channel(source.rgb.r),
                g: channel(source.rgb.g),
                b: channel(source.rgb.b),
                a: 255,
            }
        } else {
            Rgba8Pixel {
                r: 7,
                g: 9,
                b: 12,
                a: 255,
            }
        };
    }
    window.set_preview_image(Image::from_rgba8(buffer));
    let device_pixel_width = raster.preview_scale_percent / 100.0;
    let subpixel_width = device_pixel_width / 3.0;
    let resolution = if raster.subpixels_resolved_at_center {
        "RESOLVED"
    } else {
        "UNRESOLVED"
    };
    window.set_scale_text(if camera_preview {
        format!(
            "CAMERA PREVIEW · DEVICE PIXEL {device_pixel_width:.2} px · RGB STRIPE {subpixel_width:.2} px · {resolution}"
        )
        .into()
    } else {
        format!(
            "DEVICE PIXEL {device_pixel_width:.2} px · RGB STRIPE {subpixel_width:.2} px · {resolution}"
        )
        .into()
    });
    let quality_label = match quality {
        PreviewQuality::Draft => "DRAFT",
        PreviewQuality::Medium => "MEDIUM",
        PreviewQuality::High => "HIGH",
    };
    window.set_render_text(
        format!(
            "{quality_label} · {width} × {height} · {:.1} ms",
            started.elapsed().as_secs_f64() * 1_000.0
        )
        .into(),
    );
    window.set_inspection_text(match raster.inspection_field_meters {
        Some([field_width, field_height]) => format!(
            "INSPECTION · FIELD {:.2} × {:.2} mm",
            field_width * 1_000.0,
            field_height * 1_000.0
        )
        .into(),
        None => "FIT · MAIN CAMERA".into(),
    });
    window.set_hint_text(
        if rendered_view_index == 2 && !raster.subpixels_resolved_at_center {
            "Hold Z and drag on the panel to resolve physical subpixels".into()
        } else if raster.frame.inspection.is_some() {
            "Esc or Shift+Z · return to main camera".into()
        } else {
            "Hold Z and drag · physical inspection camera".into()
        },
    );
    window.set_error_text("".into());
}

fn present_loaded_source_interpretation(
    window: &MainWindow,
    source: &LoadedSource,
    sample_key: DecodedSampleKey,
    decode_interpretation: ResolvedSourceDecode,
) {
    let (interpretation, interpretation_label) =
        source_color_interpretation(window).expect("prepared media has an explicit interpretation");
    let interpretation_description = match interpretation {
        SourceColorInterpretation::IdentityDeviceSignal => interpretation_label.to_owned(),
        SourceColorInterpretation::Ocio(_) => format!("{interpretation_label} → sRGB device"),
    };
    let alpha = match source.descriptor.alpha {
        AlphaPresence::Absent => "opaque",
        AlphaPresence::Present if window.get_alpha_index() == 1 => "straight → opaque black",
        AlphaPresence::Present => "premultiplied → opaque black",
    };
    let decoded_timestamp = source
        .decoded_timestamp
        .expect("prepared media has an exact decoded timestamp");
    window.set_source_interpretation(
        format!(
            "{} · {interpretation_description} · {alpha} · sample {}/{} s · {:?}",
            decode_interpretation_description(decode_interpretation),
            decoded_timestamp.numerator(),
            decoded_timestamp.denominator(),
            sample_key.sample_policy
        )
        .into(),
    );
}

fn present_procedural_source(window: &MainWindow) {
    match window.get_procedural_pattern_index() {
        1 => {
            window.set_source_title("Eye chart".into());
            window.set_source_details("3840 × 2160 · black optotypes on white".into());
            window.set_source_interpretation("Explicit sRGB device signal · bounded 0–1".into());
        }
        2 => {
            window.set_source_title("Editorial text reference".into());
            window.set_source_details("3840 × 2160 · common document and UI text sizes".into());
            window.set_source_interpretation("Explicit sRGB device signal · bounded 0–1".into());
        }
        3 => {
            window.set_source_title("Camera color reference".into());
            window
                .set_source_details("3840 × 2160 · skin, textiles, neutrals and materials".into());
            window.set_source_interpretation("Explicit sRGB device signal · bounded 0–1".into());
        }
        4 => {
            window.set_source_title("Frequency and moire reference".into());
            window.set_source_details(
                "3840 × 2160 · MTF, line pairs, slanted edges and channel ramps".into(),
            );
            window.set_source_interpretation("Explicit sRGB device signal · bounded 0–1".into());
        }
        5 => {
            window.set_source_title("Photometric device-code scale".into());
            window.set_source_details(
                format!(
                    "9 achromatic patches · left→right codes {}",
                    PHOTOMETRIC_DEVICE_CODES
                        .iter()
                        .map(|value| format!("{value:.2}"))
                        .collect::<Vec<_>>()
                        .join(" · ")
                )
                .into(),
            );
            window.set_source_interpretation(
                "Explicit device signal · panel EOTF and physical nits remain authoritative".into(),
            );
        }
        _ => {
            window.set_source_title("Procedural diagnostic".into());
            window.set_source_details("3840 × 2160 · animated checkerboard".into());
            window.set_source_interpretation("Explicit device signal".into());
        }
    }
}

fn render_camera_result(
    window: &MainWindow,
    request: SimulationRequest,
    source: NativeCaptureSource,
    capture_profile: CapturePhotometricProfile,
    region: SensorRegion,
    session: NativeRenderSession,
) {
    let sensor = capture_profile.sensor;
    window.set_render_progress_visible(true);
    window.set_render_progress(0.0);
    window.set_render_progress_label("Native sensor capture".into());
    let settings = match capture_pipeline_settings(window, capture_profile) {
        Ok(value) => value,
        Err(error) => {
            window.set_capture_rendering(false);
            block_preview(window, &error);
            return;
        }
    };
    let capture = FrameCaptureRequest {
        optics: request.optics,
        frame_rate: settings.frame_rate,
        frame_index: i64::from(window.get_frame_number()),
        duration: settings.shutter_duration,
        temporal_samples: settings.temporal_samples,
        readout: settings.readout,
        neutral_density_stops: settings.neutral_density_stops,
        noise_seed: settings.noise_seed,
    };
    window.set_native_staging_ready(false);
    window.set_preview_aspect(f32::from(region.width) / f32::from(region.height));
    let weak_window = window.as_weak();
    let NativeRenderSession {
        started,
        cancel,
        latest_export,
    } = session;
    thread::spawn(move || {
        let progress_window = weak_window.clone();
        let result = run_native_capture_job(
            capture,
            source,
            sensor,
            settings.development,
            region,
            settings.transform,
            &cancel,
            move |completed, total, tile, staging| {
                let _ = progress_window.upgrade_in_event_loop(move |window| {
                    window.set_render_progress(completed as f32 / total as f32);
                    window.set_render_progress_label(
                        format!("Native sensor capture · tile {completed}/{total}").into(),
                    );
                    window.set_render_text(
                        format!(
                            "Native tile {completed} / {total} · {} × {}",
                            tile.width, tile.height
                        )
                        .into(),
                    );
                    if let Some(staging) = staging {
                        present_native_staging(&window, staging);
                    }
                });
            },
        );
        let _ = weak_window.upgrade_in_event_loop(move |window| {
            window.set_capture_rendering(false);
            window.set_native_staging_ready(false);
            match result {
                Ok(output) => {
                    if let Ok(mut current) = latest_export.lock() {
                        *current = Some(NativeExportFrame {
                            width: output.width,
                            height: output.height,
                            pixels: Arc::clone(&output.pixels),
                            transform: output.transform,
                        });
                    }
                    window.set_render_progress(1.0);
                    window.set_render_progress_visible(false);
                    present_native_capture(&window, output, started);
                    window.set_native_capture_ready(true);
                    window.set_native_capture_stale(false);
                }
                Err(NativeCaptureError::Cancelled) => {
                    window.set_render_progress_visible(false);
                    window.set_render_text("Native capture cancelled".into());
                    window.set_hint_text("No partial frame was published".into());
                }
                Err(NativeCaptureError::Failed(error)) => {
                    window.set_render_progress_visible(false);
                    block_preview(&window, &error);
                }
            }
        });
    });
}

struct NativeCaptureOutput {
    width: u16,
    height: u16,
    pixels: Arc<[u8]>,
    display_levels: [NativeDisplayLevel; 3],
    full_well_clipped: usize,
    adc_clipped: usize,
    sensor: SensorProfile,
    region: SensorRegion,
    transform: CameraOutputTransform,
    timings: NativeCaptureTimings,
    backend: String,
}

struct NativeRenderSession {
    started: Instant,
    cancel: Arc<AtomicBool>,
    latest_export: Arc<Mutex<Option<NativeExportFrame>>>,
}

struct NativeDisplayLevel {
    width: u16,
    height: u16,
    pixels: Vec<u8>,
}

#[derive(Clone)]
struct NativeExportFrame {
    width: u16,
    height: u16,
    pixels: Arc<[u8]>,
    transform: CameraOutputTransform,
}

#[derive(Clone, Copy, Default)]
struct NativeCaptureTimings {
    setup: Duration,
    capture_and_develop: Duration,
    output_and_assembly: Duration,
    display_pyramid: Duration,
}

#[derive(Clone, Copy)]
struct CapturePhotometricProfile {
    sensor: SensorProfile,
    reference_exposure_index: f32,
    middle_gray_at_reference_ei: f32,
}

#[derive(Clone, Copy)]
struct CapturePipelineSettings {
    sensor: SensorProfile,
    frame_rate: FrameRate,
    shutter_duration: RationalTime,
    temporal_samples: u16,
    readout: SensorReadout,
    noise_seed: u64,
    neutral_density_stops: f32,
    development: CameraDevelopment,
    transform: CameraOutputTransform,
}

fn capture_pipeline_settings(
    window: &MainWindow,
    capture_profile: CapturePhotometricProfile,
) -> Result<CapturePipelineSettings, String> {
    let frame_rate = project_frame_rate(window)?;
    let shutter_angle = window.get_shutter_angle_degrees();
    if !shutter_angle.is_finite() || !(1.0..=360.0).contains(&shutter_angle) {
        return Err("shutter angle must be finite and in [1, 360] degrees".into());
    }
    let frame_duration =
        RationalTime::new(i64::from(frame_rate.denominator()), frame_rate.numerator())
            .map_err(|error| error.to_string())?;
    let shutter_duration = frame_duration
        .checked_mul_ratio((shutter_angle * 10.0).round() as i64, 3_600)
        .map_err(|error| error.to_string())?;
    let temporal_samples_value = window.get_temporal_samples();
    if !temporal_samples_value.is_finite() || !(1.0..=64.0).contains(&temporal_samples_value) {
        return Err("motion samples must be finite and in [1, 64]".into());
    }
    let temporal_samples = temporal_samples_value.round() as u16;
    let readout = match window.get_sensor_readout_index() {
        0 => SensorReadout::Global,
        direction @ (1 | 2) => {
            let milliseconds = window.get_readout_duration_ms();
            if !milliseconds.is_finite() || !(0.1..=100.0).contains(&milliseconds) {
                return Err("sensor readout must be finite and in [0.1, 100] ms".into());
            }
            let duration = RationalTime::new((milliseconds * 1_000.0).round() as i64, 1_000_000)
                .map_err(|error| error.to_string())?;
            SensorReadout::Rolling {
                duration,
                direction: if direction == 1 {
                    screen_application::RollingDirection::TopToBottom
                } else {
                    screen_application::RollingDirection::BottomToTop
                },
            }
        }
        _ => return Err("select an explicit sensor readout mode".into()),
    };
    let noise_seed_value = window.get_sensor_noise_seed();
    if !noise_seed_value.is_finite() || !(0.0..=16_777_215.0).contains(&noise_seed_value) {
        return Err("sensor noise seed must be finite and in [0, 16777215]".into());
    }
    let noise_seed = noise_seed_value.round() as u64;
    let exposure_index = window.get_capture_exposure_index();
    if !exposure_index.is_finite() || !(25.0..=12_800.0).contains(&exposure_index) {
        return Err("EI / ISO must be finite and in [25, 12800]".into());
    }
    let neutral_density_stops = window.get_neutral_density_stops();
    if !neutral_density_stops.is_finite() || !(0.0..=16.0).contains(&neutral_density_stops) {
        return Err("optical ND must be finite and in [0, 16] stops".into());
    }
    let development = CameraDevelopment {
        white_balance: LinearRgb::new(
            window.get_white_balance_r(),
            window.get_white_balance_g(),
            window.get_white_balance_b(),
        ),
        middle_gray_illuminance_seconds: capture_profile.middle_gray_at_reference_ei
            * capture_profile.reference_exposure_index
            / exposure_index,
        develop_exposure_ev: window.get_camera_exposure_ev(),
    }
    .validate()
    .map_err(|error| error.to_string())?;
    let transform = match window.get_output_transform_index() {
        0 => CameraOutputTransform::SrgbSdr100,
        1 => CameraOutputTransform::Rec709Sdr100,
        2 => CameraOutputTransform::Rec2100Pq1000,
        _ => return Err("select an explicit camera output transform".into()),
    };
    Ok(CapturePipelineSettings {
        sensor: capture_profile.sensor,
        frame_rate,
        shutter_duration,
        temporal_samples,
        readout,
        noise_seed,
        neutral_density_stops,
        development,
        transform,
    })
}

struct NativeStagingPreview {
    width: u16,
    height: u16,
    pixels: Vec<[u8; 4]>,
}

struct NativeStagingAccumulator {
    width: u16,
    height: u16,
    source_width: u16,
    source_height: u16,
    sums: Vec<[u64; 3]>,
    samples: Vec<u32>,
}

impl NativeStagingAccumulator {
    fn new(region: SensorRegion, maximum_width: u16) -> Self {
        let width = region.width.min(maximum_width);
        let height = ((u32::from(region.height) * u32::from(width)) / u32::from(region.width))
            .max(1)
            .min(u32::from(u16::MAX)) as u16;
        let pixel_count = usize::from(width) * usize::from(height);
        Self {
            width,
            height,
            source_width: region.width,
            source_height: region.height,
            sums: vec![[0; 3]; pixel_count],
            samples: vec![0; pixel_count],
        }
    }

    fn add_pixel(&mut self, source_x: usize, source_y: usize, pixel: [u8; 4]) {
        let target_x = source_x * usize::from(self.width) / usize::from(self.source_width);
        let target_y = source_y * usize::from(self.height) / usize::from(self.source_height);
        let target = target_y * usize::from(self.width) + target_x;
        self.sums[target][0] += u64::from(pixel[0]);
        self.sums[target][1] += u64::from(pixel[1]);
        self.sums[target][2] += u64::from(pixel[2]);
        self.samples[target] += 1;
    }

    fn snapshot(&self) -> NativeStagingPreview {
        let pixels = self
            .sums
            .iter()
            .zip(&self.samples)
            .enumerate()
            .map(|(index, (sum, samples))| {
                if *samples == 0 {
                    let x = index % usize::from(self.width);
                    let y = index / usize::from(self.width);
                    let pending = if (x / 12 + y / 12).is_multiple_of(2) {
                        17
                    } else {
                        23
                    };
                    [pending, pending, pending, 255]
                } else {
                    let samples = u64::from(*samples);
                    [
                        ((sum[0] + samples / 2) / samples) as u8,
                        ((sum[1] + samples / 2) / samples) as u8,
                        ((sum[2] + samples / 2) / samples) as u8,
                        255,
                    ]
                }
            })
            .collect();
        NativeStagingPreview {
            width: self.width,
            height: self.height,
            pixels,
        }
    }
}

enum NativeCaptureError {
    Cancelled,
    Failed(String),
}

enum NativeCaptureSource {
    Procedural,
    Static {
        signal: Arc<PreparedDeviceSignalRaster>,
        placement: RasterPlacement,
    },
    Media(Box<NativeMediaSource>),
}

struct NativeMediaSource {
    path: PathBuf,
    descriptor: MediaDescriptor,
    decode_interpretation: ResolvedSourceDecode,
    color_interpretation: SourceColorInterpretation,
    alpha_interpretation: AlphaInterpretation,
    sample_policy: FrameSelectionPolicy,
    placement: RasterPlacement,
}

#[allow(clippy::too_many_arguments)]
fn run_native_capture_job(
    capture: FrameCaptureRequest,
    source: NativeCaptureSource,
    sensor: SensorProfile,
    development: CameraDevelopment,
    region: SensorRegion,
    transform: CameraOutputTransform,
    cancel: &AtomicBool,
    mut progress: impl FnMut(usize, usize, SensorRegion, Option<NativeStagingPreview>),
) -> Result<NativeCaptureOutput, NativeCaptureError> {
    let setup_started = Instant::now();
    let color_engine =
        ColorEngine::bundled().map_err(|error| NativeCaptureError::Failed(error.to_string()))?;
    let publication_backend = MetalDisplayPublication::new(transform)
        .map_err(|error| NativeCaptureError::Failed(error.to_string()))?;
    let media_processor = match &source {
        NativeCaptureSource::Media(media) => Some(
            color_engine
                .source_to_device_processor(
                    media.color_interpretation,
                    DeviceColorTarget::SrgbDisplay,
                )
                .map_err(|error| NativeCaptureError::Failed(error.to_string()))?,
        ),
        _ => None,
    };
    let mut media_cache: Vec<(RationalTime, Arc<PreparedDeviceSignalRaster>)> = Vec::new();
    let mut timings = NativeCaptureTimings {
        setup: setup_started.elapsed(),
        ..NativeCaptureTimings::default()
    };
    let metal = MetalRawDevelopment::new()
        .map_err(|error| NativeCaptureError::Failed(error.to_string()))?;
    let backend = format!("Metal · {}", metal.device_name());
    let mut pixels = vec![0_u8; usize::from(region.width) * usize::from(region.height) * 4];
    for alpha in pixels.iter_mut().skip(3).step_by(4) {
        *alpha = 255;
    }
    let mut staging_accumulator = NativeStagingAccumulator::new(region, 960);
    let tile_stripes = sensor_tile_stripes(region, 128);
    let tile_count = tile_stripes
        .iter()
        .map(|(_, tiles)| tiles.len())
        .sum::<usize>();
    let mut completed = 0_usize;
    let mut full_well_clipped = 0_usize;
    let mut adc_clipped = 0_usize;
    let mut last_staging_update = Instant::now()
        .checked_sub(Duration::from_secs(1))
        .unwrap_or_else(Instant::now);
    for (stripe, tiles) in tile_stripes {
        if cancel.load(Ordering::Relaxed) {
            return Err(NativeCaptureError::Cancelled);
        }
        let capture_started = Instant::now();
        let captured = match &source {
            NativeCaptureSource::Static { signal, placement } => {
                capture_and_develop_device_signal_region_with_compute_backends(
                    capture.clone(),
                    sensor,
                    development,
                    stripe,
                    signal,
                    *placement,
                    &metal,
                    &metal,
                )
            }
            NativeCaptureSource::Procedural => {
                capture_and_develop_procedural_region_with_compute_backends(
                    capture.clone(),
                    sensor,
                    development,
                    stripe,
                    &metal,
                    &metal,
                )
            }
            NativeCaptureSource::Media(media) => {
                capture_and_develop_device_signal_region_sequence_with_compute_backends(
                    capture.clone(),
                    sensor,
                    development,
                    stripe,
                    media.placement,
                    |time| {
                        if let Some((_, signal)) =
                            media_cache.iter().find(|(cached, _)| *cached == time)
                        {
                            return Ok(Arc::clone(signal));
                        }
                        let (resolved_descriptor, frame) = decode_frame_at_time(
                            &media.path,
                            time,
                            media.sample_policy,
                            media.decode_interpretation,
                        )
                        .map_err(|_| ApplicationError::MediaSampleUnavailable)?;
                        if resolved_descriptor != media.descriptor {
                            return Err(ApplicationError::MediaSampleUnavailable);
                        }
                        let signal = decoded_frame_to_device_signal(
                            &frame,
                            media.descriptor.alpha,
                            media.alpha_interpretation,
                            media_processor
                                .as_ref()
                                .expect("media processor exists for media source"),
                        )?;
                        let prepared = Arc::new(PreparedDeviceSignalRaster::new(signal)?);
                        media_cache.push((time, Arc::clone(&prepared)));
                        Ok(prepared)
                    },
                    &metal,
                    &metal,
                )
            }
        }
        .map_err(|error| NativeCaptureError::Failed(error.to_string()))?;
        timings.capture_and_develop += capture_started.elapsed();
        let output_started = Instant::now();
        let output = publication_backend
            .publish_acescg_rgba8(&captured.developed.acescg)
            .map_err(|error| NativeCaptureError::Failed(error.to_string()))?;
        let stripe_width = usize::from(stripe.width);
        let output_stride = usize::from(region.width) * 4;
        for tile in tiles {
            if cancel.load(Ordering::Relaxed) {
                return Err(NativeCaptureError::Cancelled);
            }
            let (tile_full_well_clipped, tile_adc_clipped) =
                clipping_in_region(&captured.raw, tile);
            full_well_clipped += tile_full_well_clipped;
            adc_clipped += tile_adc_clipped;
            let stripe_offset_x = usize::from(tile.origin_x - stripe.origin_x);
            let stripe_offset_y = usize::from(tile.origin_y - stripe.origin_y);
            let output_offset_x = usize::from(tile.origin_x - region.origin_x);
            let output_offset_y = usize::from(tile.origin_y - region.origin_y);
            for row in 0..usize::from(tile.height) {
                let source_start = ((stripe_offset_y + row) * stripe_width + stripe_offset_x) * 4;
                let source_end = source_start + usize::from(tile.width) * 4;
                let target_start = (output_offset_y + row) * output_stride + output_offset_x * 4;
                for (column, rgba) in output[source_start..source_end].chunks_exact(4).enumerate() {
                    let pixel = [rgba[0], rgba[1], rgba[2], rgba[3]];
                    pixels[target_start + column * 4..target_start + column * 4 + 4]
                        .copy_from_slice(&pixel);
                    staging_accumulator.add_pixel(
                        output_offset_x + column,
                        output_offset_y + row,
                        pixel,
                    );
                }
            }
            completed += 1;
            let staging = if completed == tile_count
                || last_staging_update.elapsed() >= Duration::from_millis(100)
            {
                last_staging_update = Instant::now();
                Some(staging_accumulator.snapshot())
            } else {
                None
            };
            progress(completed, tile_count, tile, staging);
        }
        timings.output_and_assembly += output_started.elapsed();
    }
    let pixels = Arc::<[u8]>::from(pixels);
    let pyramid_started = Instant::now();
    let display_levels = build_native_display_levels(region.width, region.height, &pixels);
    timings.display_pyramid = pyramid_started.elapsed();
    Ok(NativeCaptureOutput {
        width: region.width,
        height: region.height,
        display_levels,
        pixels,
        full_well_clipped,
        adc_clipped,
        sensor,
        region,
        transform,
        timings,
        backend,
    })
}

fn build_native_display_levels(width: u16, height: u16, pixels: &[u8]) -> [NativeDisplayLevel; 3] {
    let level_1 = downsample_rgba_2x(width, height, pixels);
    let level_2 = downsample_rgba_2x(level_1.width, level_1.height, &level_1.pixels);
    let level_3 = downsample_rgba_2x(level_2.width, level_2.height, &level_2.pixels);
    [level_1, level_2, level_3]
}

fn downsample_rgba_2x(width: u16, height: u16, pixels: &[u8]) -> NativeDisplayLevel {
    let output_width = width.div_ceil(2);
    let output_height = height.div_ceil(2);
    let mut output = Vec::with_capacity(usize::from(output_width) * usize::from(output_height) * 4);
    for output_y in 0..output_height {
        for output_x in 0..output_width {
            let mut sum = [0_u32; 4];
            let mut count = 0_u32;
            for source_y in (output_y * 2)..(output_y * 2 + 2).min(height) {
                for source_x in (output_x * 2)..(output_x * 2 + 2).min(width) {
                    let source =
                        (usize::from(source_y) * usize::from(width) + usize::from(source_x)) * 4;
                    for channel in 0..4 {
                        sum[channel] += u32::from(pixels[source + channel]);
                    }
                    count += 1;
                }
            }
            output.extend_from_slice(&[
                ((sum[0] + count / 2) / count) as u8,
                ((sum[1] + count / 2) / count) as u8,
                ((sum[2] + count / 2) / count) as u8,
                ((sum[3] + count / 2) / count) as u8,
            ]);
        }
    }
    NativeDisplayLevel {
        width: output_width,
        height: output_height,
        pixels: output,
    }
}

fn present_native_staging(window: &MainWindow, staging: NativeStagingPreview) {
    let mut buffer =
        SharedPixelBuffer::<Rgba8Pixel>::new(u32::from(staging.width), u32::from(staging.height));
    for (target, source) in buffer.make_mut_slice().iter_mut().zip(staging.pixels) {
        *target = Rgba8Pixel {
            r: source[0],
            g: source[1],
            b: source[2],
            a: source[3],
        };
    }
    window.set_native_staging_image(Image::from_rgba8(buffer));
    window.set_native_staging_ready(true);
    window.set_scale_text("STAGING TILES · NOT FINAL".into());
}

fn present_native_capture(window: &MainWindow, output: NativeCaptureOutput, started: Instant) {
    window.set_native_level_0_image(native_level_image(
        output.width,
        output.height,
        &output.pixels,
    ));
    let [level_1, level_2, level_3] = output.display_levels;
    window.set_native_level_1_image(native_level_image(
        level_1.width,
        level_1.height,
        &level_1.pixels,
    ));
    window.set_native_level_2_image(native_level_image(
        level_2.width,
        level_2.height,
        &level_2.pixels,
    ));
    window.set_native_level_3_image(native_level_image(
        level_3.width,
        level_3.height,
        &level_3.pixels,
    ));
    window.set_native_source_width(f32::from(output.width));
    window.set_native_pyramid_ready(true);
    window.set_scale_text(
        format!(
            "CAMERA SENSOR {} × {} · {}-BIT BAYER · NATIVE VIEW · WELL {} · ADC {} CLIPPED",
            output.width,
            output.height,
            output.sensor.adc_bits,
            output.full_well_clipped,
            output.adc_clipped
        )
        .into(),
    );
    window.set_render_text(
        format!(
            "Native {:.1} ms · {} · setup {:.1} · physical+develop {:.1} · ODT+assemble {:.1} · pyramid {:.1} · {}",
            started.elapsed().as_secs_f64() * 1_000.0,
            output.backend,
            output.timings.setup.as_secs_f64() * 1_000.0,
            output.timings.capture_and_develop.as_secs_f64() * 1_000.0,
            output.timings.output_and_assembly.as_secs_f64() * 1_000.0,
            output.timings.display_pyramid.as_secs_f64() * 1_000.0,
            output.transform.label(),
        )
        .into(),
    );
    window.set_inspection_text(if output.region == SensorRegion::full(output.sensor) {
        "COMPLETE DEVELOPED CAMERA FRAME · GLOBAL SHUTTER".into()
    } else {
        format!(
            "NATIVE SENSOR ROI · x{} y{} · {} × {}",
            output.region.origin_x,
            output.region.origin_y,
            output.region.width,
            output.region.height
        )
        .into()
    });
    window.set_hint_text(
        "Native sensor result · increase View zoom and drag to inspect without moving camera"
            .into(),
    );
    window.set_error_text("".into());
}

fn native_level_image(width: u16, height: u16, pixels: &[u8]) -> Image {
    let mut buffer = SharedPixelBuffer::<Rgba8Pixel>::new(u32::from(width), u32::from(height));
    for (target, source) in buffer
        .make_mut_slice()
        .iter_mut()
        .zip(pixels.chunks_exact(4))
    {
        *target = Rgba8Pixel {
            r: source[0],
            g: source[1],
            b: source[2],
            a: source[3],
        };
    }
    Image::from_rgba8(buffer)
}

fn encode_native_png(writer: impl Write, frame: &NativeExportFrame) -> Result<(), String> {
    let expected = usize::from(frame.width) * usize::from(frame.height) * 4;
    if frame.pixels.len() != expected {
        return Err("native export buffer does not match its authored raster".into());
    }
    image::codecs::png::PngEncoder::new(writer)
        .write_image(
            frame.pixels.as_ref(),
            u32::from(frame.width),
            u32::from(frame.height),
            image::ExtendedColorType::Rgba8,
        )
        .map_err(|error| error.to_string())
}

fn write_native_png(path: &Path, frame: &NativeExportFrame) -> Result<(), String> {
    let file = File::create(path).map_err(|error| error.to_string())?;
    encode_native_png(file, frame)
}

fn sensor_tiles(region: SensorRegion, edge: u16) -> Vec<SensorRegion> {
    let mut tiles = Vec::new();
    let end_x = u32::from(region.origin_x) + u32::from(region.width);
    let end_y = u32::from(region.origin_y) + u32::from(region.height);
    let mut y = u32::from(region.origin_y);
    while y < end_y {
        let mut x = u32::from(region.origin_x);
        while x < end_x {
            tiles.push(SensorRegion {
                origin_x: x as u16,
                origin_y: y as u16,
                width: (end_x - x).min(u32::from(edge)) as u16,
                height: (end_y - y).min(u32::from(edge)) as u16,
            });
            x += u32::from(edge);
        }
        y += u32::from(edge);
    }
    tiles
}

fn sensor_tile_stripes(region: SensorRegion, edge: u16) -> Vec<(SensorRegion, Vec<SensorRegion>)> {
    let mut stripes = Vec::new();
    for tile in sensor_tiles(region, edge) {
        if stripes
            .last()
            .is_none_or(|(_, tiles): &(SensorRegion, Vec<SensorRegion>)| {
                tiles[0].origin_y != tile.origin_y
            })
        {
            stripes.push((
                SensorRegion {
                    origin_x: region.origin_x,
                    origin_y: tile.origin_y,
                    width: region.width,
                    height: tile.height,
                },
                Vec::new(),
            ));
        }
        stripes
            .last_mut()
            .expect("a stripe exists for every tile")
            .1
            .push(tile);
    }
    stripes
}

fn clipping_in_region(
    raw: &screen_sensor::RawSensorRegion,
    region: SensorRegion,
) -> (usize, usize) {
    let offset_x = usize::from(region.origin_x - raw.region.origin_x);
    let offset_y = usize::from(region.origin_y - raw.region.origin_y);
    let stride = usize::from(raw.region.width);
    let mut full_well_count = 0;
    let mut adc_count = 0;
    for row in 0..usize::from(region.height) {
        let start = (offset_y + row) * stride + offset_x;
        full_well_count += raw.full_well_clipped[start..start + usize::from(region.width)]
            .iter()
            .filter(|value| **value)
            .count();
        adc_count += raw.adc_clipped[start..start + usize::from(region.width)]
            .iter()
            .filter(|value| **value)
            .count();
    }
    (full_well_count, adc_count)
}

fn block_preview(window: &MainWindow, message: &str) {
    window.set_preview_image(Image::default());
    window.set_preview_rendering(false);
    window.set_capture_rendering(false);
    window.set_render_progress_visible(false);
    window.set_render_text("Preview blocked · see error".into());
    window.set_source_interpretation(message.into());
    window.set_error_text(message.into());
}

fn load_source(window: &MainWindow, state: &mut InteractionState, path: &Path) {
    match probe_media(path) {
        Ok(descriptor) => {
            let loaded = prepare_loaded_source(path.to_owned(), descriptor);
            present_source(window, path, &loaded.descriptor);
            state.source = Some(loaded);
            window.set_procedural_source(false);
            state.inspection = None;
            window.set_idt_index(0);
            window.set_alpha_index(0);
            window.set_matrix_index(0);
            window.set_range_index(0);
            render_preview(window, state);
        }
        Err(error) => window.set_error_text(error.to_string().into()),
    }
}

fn prepare_loaded_source(path: PathBuf, descriptor: MediaDescriptor) -> LoadedSource {
    LoadedSource {
        path,
        descriptor,
        decoded_sample_key: None,
        decoded_timestamp: None,
        decoded_frame: None,
        processor_interpretation: None,
        color_processor: None,
        prepared_signal_key: None,
        device_signal: None,
    }
}

fn ensure_device_signal(
    source: &mut LoadedSource,
    color_engine: &ColorEngine,
    interpretation: SourceColorInterpretation,
    alpha_interpretation: AlphaInterpretation,
) -> Result<(), ApplicationError> {
    let key = (interpretation, alpha_interpretation);
    if source.prepared_signal_key == Some(key) {
        return Ok(());
    }
    if source.processor_interpretation != Some(interpretation) {
        source.color_processor = Some(
            color_engine
                .source_to_device_processor(interpretation, DeviceColorTarget::SrgbDisplay)
                .map_err(ApplicationError::Color)?,
        );
        source.processor_interpretation = Some(interpretation);
    }
    let processor = source
        .color_processor
        .as_ref()
        .expect("processor interpretation and processor are updated together");
    let device_signal = decoded_frame_to_device_signal(
        source
            .decoded_frame
            .as_ref()
            .expect("device signal requires a resolved decoded sample"),
        source.descriptor.alpha,
        alpha_interpretation,
        processor,
    )?;
    source.prepared_signal_key = Some(key);
    source.device_signal = Some(device_signal);
    Ok(())
}

fn refresh_loaded_source(
    source: &mut LoadedSource,
    sample_key: DecodedSampleKey,
) -> Result<(), String> {
    let (descriptor, frame) = decode_frame_at_time(
        &source.path,
        sample_key.requested_time,
        sample_key.sample_policy,
        sample_key.interpretation,
    )
    .map_err(|error| error.to_string())?;
    if descriptor != source.descriptor {
        return Err("source descriptor changed on disk; reopen the source explicitly".to_owned());
    }
    source.descriptor = descriptor;
    source.decoded_sample_key = Some(sample_key);
    source.decoded_timestamp = Some(frame.timestamp);
    source.decoded_frame = Some(frame);
    source.prepared_signal_key = None;
    source.device_signal = None;
    Ok(())
}

fn present_source(window: &MainWindow, path: &Path, descriptor: &MediaDescriptor) {
    let frame_rate = match descriptor.cadence {
        FrameCadence::Constant { frame_rate } => format!(
            "{}/{} fps",
            frame_rate.numerator(),
            frame_rate.denominator()
        ),
        FrameCadence::Variable => "variable fps".to_owned(),
    };
    let alpha = match descriptor.alpha {
        AlphaPresence::Absent => "opaque",
        AlphaPresence::Present => "alpha present",
    };
    let source_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("Selected source");
    window.set_source_title(source_name.into());
    window.set_source_details(
        format!(
            "{} · {} × {} · {} · {} · {}",
            descriptor.codec_name,
            descriptor.raster.width,
            descriptor.raster.height,
            descriptor.pixel_format_name,
            frame_rate,
            alpha
        )
        .into(),
    );
    let interpretation_status = propose_ocio_input(&descriptor.color_metadata).map_or_else(
        || {
            if descriptor.color_metadata.is_empty() {
                "No declared color metadata · choose IDT to authorize".to_owned()
            } else {
                "Declared color metadata is not decisive · choose IDT to authorize".to_owned()
            }
        },
        |proposal| {
            format!(
                "Metadata proposes {} · choose IDT to authorize",
                proposal.label()
            )
        },
    );
    window.set_source_interpretation(interpretation_status.into());
    window.set_error_text("".into());
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let window = MainWindow::new()?;
    let idt_labels: Vec<SharedString> = ["Select IDT…", "Identity (device signal)"]
        .into_iter()
        .chain(
            OcioInputTransform::ALL
                .into_iter()
                .map(|input| input.label()),
        )
        .map(Into::into)
        .collect();
    window.set_idt_model(ModelRc::new(VecModel::from(idt_labels)));
    let device_labels: Vec<SharedString> = DEVICE_PRESETS
        .iter()
        .map(|preset| preset.label.into())
        .chain(std::iter::once("Custom".into()))
        .collect();
    let device_ids: Vec<SharedString> = DEVICE_PRESETS
        .iter()
        .map(|preset| preset.id.into())
        .chain(std::iter::once("custom".into()))
        .collect();
    window.set_device_preset_model(ModelRc::new(VecModel::from(device_labels)));
    window.set_device_preset_ids(ModelRc::new(VecModel::from(device_ids)));
    let capture_labels: Vec<SharedString> = CAPTURE_DEVICE_PRESETS
        .iter()
        .map(|preset| preset.label.into())
        .chain(std::iter::once("Custom".into()))
        .collect();
    let capture_ids: Vec<SharedString> = CAPTURE_DEVICE_PRESETS
        .iter()
        .map(|preset| preset.id.into())
        .chain(std::iter::once("custom".into()))
        .collect();
    window.set_capture_preset_model(ModelRc::new(VecModel::from(capture_labels)));
    window.set_capture_preset_ids(ModelRc::new(VecModel::from(capture_ids)));
    let lens_labels: Vec<SharedString> = LENS_PRESETS
        .iter()
        .map(|preset| preset.label.into())
        .chain(std::iter::once("Custom / interpolated".into()))
        .collect();
    let lens_ids: Vec<SharedString> = LENS_PRESETS
        .iter()
        .map(|preset| preset.id.into())
        .chain(std::iter::once("custom".into()))
        .collect();
    window.set_lens_preset_model(ModelRc::new(VecModel::from(lens_labels)));
    window.set_lens_preset_ids(ModelRc::new(VecModel::from(lens_ids)));
    let cover_labels: Vec<SharedString> = COVER_GLASS_PRESETS
        .iter()
        .map(|preset| preset.label.into())
        .chain(std::iter::once("Custom".into()))
        .collect();
    let cover_ids: Vec<SharedString> = COVER_GLASS_PRESETS
        .iter()
        .map(|preset| preset.id.into())
        .chain(std::iter::once("custom".into()))
        .collect();
    window.set_cover_preset_model(ModelRc::new(VecModel::from(cover_labels)));
    window.set_cover_preset_ids(ModelRc::new(VecModel::from(cover_ids)));
    let environment_labels: Vec<SharedString> = ENVIRONMENT_PRESETS
        .iter()
        .map(|preset| preset.label.into())
        .chain(std::iter::once("Custom".into()))
        .collect();
    let environment_ids: Vec<SharedString> = ENVIRONMENT_PRESETS
        .iter()
        .map(|preset| preset.id.into())
        .chain(std::iter::once("custom".into()))
        .collect();
    window.set_environment_preset_model(ModelRc::new(VecModel::from(environment_labels)));
    window.set_environment_preset_ids(ModelRc::new(VecModel::from(environment_ids)));
    window.set_build_id(
        option_env!("SCREEN_SIM_BUILD_ID")
            .unwrap_or("development")
            .into(),
    );
    let color_engine = ColorEngine::bundled()?;
    let state = Rc::new(RefCell::new(InteractionState::new(color_engine)));
    apply_device_preset(
        &window,
        &mut state.borrow_mut(),
        "lcd-macbook-pro-retina-14",
    )?;
    apply_environment_preset(
        &window,
        &mut state.borrow_mut(),
        "environment-uniform-neutral",
    )?;
    apply_capture_preset(&window, &mut state.borrow_mut(), "arri-alexa-35-open-gate")?;

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_select_device_preset(move |id| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let mut state = state.borrow_mut();
            match apply_device_preset(&window, &mut state, id.as_str()) {
                Ok(()) => render_preview(&window, &mut state),
                Err(error) => block_preview(&window, &error),
            }
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_select_cover_preset(move |id| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let mut state = state.borrow_mut();
            match apply_cover_preset(&window, &mut state, id.as_str()) {
                Ok(()) => render_preview(&window, &mut state),
                Err(error) => block_preview(&window, &error),
            }
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_select_environment_preset(move |id| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let mut state = state.borrow_mut();
            match apply_environment_preset(&window, &mut state, id.as_str()) {
                Ok(()) => render_preview(&window, &mut state),
                Err(error) => block_preview(&window, &error),
            }
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_select_lens_preset(move |id| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let mut state = state.borrow_mut();
            if let Err(error) = apply_lens_preset(&window, &mut state, id.as_str()) {
                block_preview(&window, &error);
                return;
            }
            let time = match project_frame_rate(&window).and_then(|rate| {
                rate.time_at_frame(i64::from(window.get_frame_number()))
                    .map_err(|error| error.to_string())
            }) {
                Ok(time) => time,
                Err(error) => {
                    block_preview(&window, &error);
                    return;
                }
            };
            let lens = state.active_lens;
            state
                .camera_editor
                .preview_edit(time, camera_edit_from_window(&window, lens));
            state.inspection = None;
            update_undo_availability(&window, &state.camera_editor);
            render_preview(&window, &mut state);
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_select_capture_preset(move |id| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let mut state = state.borrow_mut();
            match apply_capture_preset(&window, &mut state, id.as_str()) {
                Ok(()) => {
                    let time = match project_frame_rate(&window).and_then(|rate| {
                        rate.time_at_frame(i64::from(window.get_frame_number()))
                            .map_err(|error| error.to_string())
                    }) {
                        Ok(time) => time,
                        Err(error) => {
                            block_preview(&window, &error);
                            return;
                        }
                    };
                    let lens = state.active_lens;
                    state
                        .camera_editor
                        .preview_edit(time, camera_edit_from_window(&window, lens));
                    state.inspection = None;
                    update_undo_availability(&window, &state.camera_editor);
                    render_preview(&window, &mut state);
                }
                Err(error) => block_preview(&window, &error),
            }
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_select_render_quality(move |quality| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            if quality >= 3 {
                window.set_view_index(4);
            }
            render_preview(&window, &mut state.borrow_mut());
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_render_capture_frame(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            if window.get_capture_rendering() {
                return;
            }
            window.set_render_text("Rendering one native sensor frame…".into());
            let mut state = state.borrow_mut();
            state.capture_render_requested = true;
            render_preview(&window, &mut state);
        });
    }

    {
        let state = Rc::clone(&state);
        window.on_cancel_capture_frame(move || {
            if let Some(cancel) = &state.borrow().capture_cancel {
                cancel.store(true, Ordering::Relaxed);
            }
        });
    }

    {
        let weak_window = window.as_weak();
        let latest_export = Arc::clone(&state.borrow().latest_native_export);
        window.on_export_native_frame(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            if window.get_capture_rendering() || window.get_native_capture_stale() {
                return;
            }
            let frame = match latest_export.lock() {
                Ok(current) => current.clone(),
                Err(_) => {
                    block_preview(&window, "native export state is unavailable");
                    return;
                }
            };
            let Some(frame) = frame else {
                block_preview(&window, "render one complete Native result before export");
                return;
            };
            let Some(path) = rfd::FileDialog::new()
                .set_title("Export exact Native camera result")
                .add_filter("PNG image", &["png"])
                .set_file_name("screen-simulation-native.png")
                .save_file()
            else {
                return;
            };
            window.set_render_text("Exporting exact Native raster…".into());
            let export_window = weak_window.clone();
            thread::spawn(move || {
                let result = write_native_png(&path, &frame);
                let _ = export_window.upgrade_in_event_loop(move |window| match result {
                    Ok(()) => {
                        window.set_render_text(
                            format!(
                                "Exported {} × {} exact Native PNG · {}",
                                frame.width,
                                frame.height,
                                frame.transform.label()
                            )
                            .into(),
                        );
                        window.set_error_text("".into());
                    }
                    Err(error) => block_preview(&window, &format!("Native export failed: {error}")),
                });
            });
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_continue_preview_render(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let mut state = state.borrow_mut();
            if state.preview_pending {
                state.preview_pending = false;
                render_preview(&window, &mut state);
            }
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_choose_source(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            if let Some(path) = rfd::FileDialog::new()
                .set_title("Choose screen source media")
                .pick_file()
            {
                load_source(&window, &mut state.borrow_mut(), &path);
            }
        });
    }

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_inspect(move |start_x, start_y, end_x, end_y| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let to_ndc = |x: f32, y: f32| Vec2 {
                x: x * 2.0 - 1.0,
                y: y * 2.0 - 1.0,
            };
            let state_ref = state.borrow();
            let request = match simulation_request(
                &window,
                state_ref.inspection,
                state_ref.camera_editor.effective(),
                &state_ref.screen,
                state_ref.active_cover,
                state_ref.active_environment,
            ) {
                Ok(request) => request,
                Err(error) => {
                    window.set_error_text(error.into());
                    return;
                }
            };
            drop(state_ref);
            match inspection_region_from_drag(
                request,
                to_ndc(start_x, start_y),
                to_ndc(end_x, end_y),
            ) {
                Ok(region) => {
                    let mut state = state.borrow_mut();
                    state.inspection = Some(region);
                    render_preview(&window, &mut state);
                }
                Err(error) => window.set_error_text(error.to_string().into()),
            }
        });
    }
    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_set_camera_keyframe(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let frame_rate = match project_frame_rate(&window) {
                Ok(value) => value,
                Err(error) => {
                    window.set_error_text(error.into());
                    return;
                }
            };
            let time = match frame_rate.time_at_frame(i64::from(window.get_frame_number())) {
                Ok(value) => value,
                Err(error) => {
                    window.set_error_text(error.to_string().into());
                    return;
                }
            };
            let mut state = state.borrow_mut();
            let lens = state.active_lens;
            state
                .camera_editor
                .preview_edit(time, camera_edit_from_window(&window, lens));
            state.camera_editor.commit_preview();
            window.set_camera_key_count(
                state.camera_editor.committed.transform.keyframes.len() as i32
            );
            update_undo_availability(&window, &state.camera_editor);
            state.inspection = None;
            render_preview(&window, &mut state);
        });
    }
    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_undo(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let time = match project_frame_rate(&window).and_then(|rate| {
                rate.time_at_frame(i64::from(window.get_frame_number()))
                    .map_err(|error| error.to_string())
            }) {
                Ok(value) => value,
                Err(error) => {
                    window.set_error_text(error.into());
                    return;
                }
            };
            let mut state = state.borrow_mut();
            if state.camera_editor.undo() {
                state.active_lens =
                    match set_camera_controls_from_committed(&window, &state.camera_editor, time) {
                        Ok(lens) => lens,
                        Err(error) => {
                            window.set_error_text(error.into());
                            return;
                        }
                    };
                window.set_camera_key_count(
                    state.camera_editor.committed.transform.keyframes.len() as i32,
                );
                state.inspection = None;
                render_preview(&window, &mut state);
            }
            update_undo_availability(&window, &state.camera_editor);
        });
    }
    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_redo(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let time = match project_frame_rate(&window).and_then(|rate| {
                rate.time_at_frame(i64::from(window.get_frame_number()))
                    .map_err(|error| error.to_string())
            }) {
                Ok(value) => value,
                Err(error) => {
                    window.set_error_text(error.into());
                    return;
                }
            };
            let mut state = state.borrow_mut();
            if state.camera_editor.redo() {
                state.active_lens =
                    match set_camera_controls_from_committed(&window, &state.camera_editor, time) {
                        Ok(lens) => lens,
                        Err(error) => {
                            window.set_error_text(error.into());
                            return;
                        }
                    };
                window.set_camera_key_count(
                    state.camera_editor.committed.transform.keyframes.len() as i32,
                );
                state.inspection = None;
                render_preview(&window, &mut state);
            }
            update_undo_availability(&window, &state.camera_editor);
        });
    }
    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_reset_inspection(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            let mut state = state.borrow_mut();
            state.inspection = None;
            render_preview(&window, &mut state);
        });
    }
    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_tick(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            if window.get_focus_mode_index() == 0
                && window.get_focus_distance_m() != window.get_distance_m()
            {
                window.set_focus_distance_m(window.get_distance_m());
            }
            update_device_summary(&window);
            let now = Instant::now();
            let mut state = state.borrow_mut();
            let elapsed = now.duration_since(state.last_tick).as_secs_f64();
            state.last_tick = now;
            let mut frame_advanced = false;
            if window.get_playing() {
                match project_frame_rate(&window) {
                    Ok(frame_rate) => {
                        state.playback_accumulator_seconds += elapsed;
                        let frame_seconds =
                            f64::from(frame_rate.denominator()) / f64::from(frame_rate.numerator());
                        while state.playback_accumulator_seconds >= frame_seconds {
                            state.playback_accumulator_seconds -= frame_seconds;
                            window.set_frame_number(
                                (window.get_frame_number() + 1) % (DURATION_FRAMES as i32 + 1),
                            );
                            frame_advanced = true;
                        }
                    }
                    Err(error) => {
                        block_preview(&window, &error);
                        return;
                    }
                }
            } else {
                state.playback_accumulator_seconds = 0.0;
            }
            let previous_controls = state.last_render_controls;
            let mut current_controls = render_controls(&window);
            let timeline_changed = frame_advanced
                || previous_controls
                    .is_some_and(|previous| timeline_selection_changed(previous, current_controls));
            if timeline_changed {
                state.camera_editor.cancel_preview();
                let time = match project_frame_rate(&window).and_then(|rate| {
                    rate.time_at_frame(i64::from(window.get_frame_number()))
                        .map_err(|error| error.to_string())
                }) {
                    Ok(value) => value,
                    Err(error) => {
                        block_preview(&window, &error);
                        return;
                    }
                };
                state.active_lens =
                    match set_camera_controls_from_committed(&window, &state.camera_editor, time) {
                        Ok(lens) => lens,
                        Err(error) => {
                            block_preview(&window, &error);
                            return;
                        }
                    };
                current_controls = render_controls(&window);
                update_undo_availability(&window, &state.camera_editor);
            } else if previous_controls.is_some_and(|previous| {
                camera_edit_from_controls(previous, state.active_lens)
                    != camera_edit_from_controls(current_controls, state.active_lens)
            }) {
                let time = match project_frame_rate(&window).and_then(|rate| {
                    rate.time_at_frame(i64::from(window.get_frame_number()))
                        .map_err(|error| error.to_string())
                }) {
                    Ok(value) => value,
                    Err(error) => {
                        block_preview(&window, &error);
                        return;
                    }
                };
                let lens = state.active_lens;
                state
                    .camera_editor
                    .preview_edit(time, camera_edit_from_controls(current_controls, lens));
                state.inspection = None;
                update_undo_availability(&window, &state.camera_editor);
            }
            let controls_changed = previous_controls != Some(current_controls);
            if frame_advanced || controls_changed {
                render_preview(&window, &mut state);
            }
        });
    }

    if let Some(path) = std::env::args_os().nth(1) {
        load_source(&window, &mut state.borrow_mut(), Path::new(&path));
    }
    render_preview(&window, &mut state.borrow_mut());
    window.run()?;
    Ok(())
}

#[cfg(test)]
mod interaction_tests {
    use super::*;

    fn editor() -> CameraEditor {
        CameraEditor::new(
            camera_rig(vec![camera_keyframes(
                "camera-key-0".to_owned(),
                RationalTime::new(0, 24).unwrap(),
                CameraEdit {
                    distance: 0.8,
                    yaw_degrees: 0.0,
                    pitch_degrees: 0.0,
                    focal_mm: 50.0,
                    focus_distance_m: 0.8,
                    f_stop: 8.0,
                    lens: LensModel::REFERENCE_PHOTOGRAPHIC,
                    interpolation: KeyframeInterpolation::Smooth,
                },
            )]),
            1,
        )
    }

    #[test]
    fn camera_preview_is_transient_and_commit_is_one_undoable_transaction() {
        let mut editor = editor();
        let original = editor.committed.clone();
        let time = RationalTime::new(1, 24).unwrap();
        let edit = CameraEdit {
            distance: 1.2,
            yaw_degrees: 18.0,
            pitch_degrees: 11.0,
            focal_mm: 65.0,
            focus_distance_m: 1.2,
            f_stop: 4.0,
            lens: LensModel::REFERENCE_PHOTOGRAPHIC,
            interpolation: KeyframeInterpolation::Linear,
        };

        editor.preview_edit(time, edit);
        assert_eq!(editor.committed, original);
        assert_ne!(editor.effective(), &original);
        assert!(editor.can_undo());
        assert!(!editor.can_redo());

        assert!(editor.undo());
        assert_eq!(editor.effective(), &original);
        assert!(!editor.can_undo());

        editor.preview_edit(time, edit);
        assert!(editor.commit_preview());
        assert_eq!(editor.committed.transform.keyframes.len(), 2);
        let committed = editor.committed.clone();
        assert!(editor.undo());
        assert_eq!(editor.committed, original);
        assert!(editor.can_redo());
        assert!(editor.redo());
        assert_eq!(editor.committed, committed);
    }

    #[test]
    fn replacing_a_camera_key_preserves_its_stable_ids() {
        let mut editor = editor();
        let transform_id = editor.committed.transform.keyframes[0].id.clone();
        let intrinsics_id = editor.committed.intrinsics.keyframes[0].id.clone();
        editor.preview_edit(
            RationalTime::new(0, 24).unwrap(),
            CameraEdit {
                distance: 0.9,
                yaw_degrees: -12.0,
                pitch_degrees: -8.0,
                focal_mm: 35.0,
                focus_distance_m: 0.9,
                f_stop: 5.6,
                lens: lens_preset("generic-prime-35mm").unwrap().lens,
                interpolation: KeyframeInterpolation::Hold,
            },
        );
        editor.commit_preview();
        assert_eq!(editor.committed.transform.keyframes[0].id, transform_id);
        assert_eq!(editor.committed.intrinsics.keyframes[0].id, intrinsics_id);
    }

    #[test]
    fn bundled_raster_test_sources_are_authored_4k_rgb_images() {
        for encoded in [
            include_bytes!("../assets/editorial-text-reference.png").as_slice(),
            include_bytes!("../assets/camera-color-reference.png").as_slice(),
            include_bytes!("../assets/frequency-moire-reference.png").as_slice(),
        ] {
            let image = image::load_from_memory_with_format(encoded, image::ImageFormat::Png)
                .expect("bundled PNG must decode");
            assert_eq!([image.width(), image.height()], [3_840, 2_160]);
            assert!(image.to_rgba8().pixels().all(|pixel| pixel[3] == 255));
        }
    }

    #[test]
    fn native_scheduler_groups_horizontal_tiles_without_changing_progress_boundaries() {
        let region = SensorRegion {
            origin_x: 7,
            origin_y: 11,
            width: 300,
            height: 260,
        };
        let stripes = sensor_tile_stripes(region, 128);
        assert_eq!(stripes.len(), 3);
        assert_eq!(
            stripes.iter().map(|(_, tiles)| tiles.len()).sum::<usize>(),
            9
        );
        assert_eq!(stripes[0].0.width, 300);
        assert_eq!(stripes[0].0.height, 128);
        assert_eq!(stripes[2].0.height, 4);
        assert_eq!(stripes[0].1, sensor_tiles(region, 128)[..3]);
    }

    #[test]
    fn native_staging_averages_high_frequency_sensor_samples() {
        let region = SensorRegion {
            origin_x: 0,
            origin_y: 0,
            width: 16,
            height: 2,
        };
        let mut staging = NativeStagingAccumulator::new(region, 2);
        for y in 0..2 {
            for x in 0..16 {
                let value = if x % 2 == 0 { 0 } else { 255 };
                staging.add_pixel(x, y, [value, value, value, 255]);
            }
        }

        let preview = staging.snapshot();
        assert_eq!((preview.width, preview.height), (2, 1));
        assert!(
            preview
                .pixels
                .iter()
                .all(|pixel| pixel[0] == 128 && pixel[1] == 128 && pixel[2] == 128)
        );
    }

    #[test]
    fn pending_native_tiles_do_not_darken_completed_staging_pixels() {
        let region = SensorRegion {
            origin_x: 0,
            origin_y: 0,
            width: 4,
            height: 1,
        };
        let mut staging = NativeStagingAccumulator::new(region, 2);
        staging.add_pixel(0, 0, [240, 180, 120, 255]);
        staging.add_pixel(1, 0, [240, 180, 120, 255]);

        let preview = staging.snapshot();
        assert_eq!(preview.pixels[0], [240, 180, 120, 255]);
        assert_ne!(preview.pixels[1], [0, 0, 0, 255]);
        assert_ne!(preview.pixels[1], preview.pixels[0]);
    }

    #[test]
    fn camera_preview_uses_capture_shutter_nd_and_development_exposure() {
        let base = CapturePipelineSettings {
            sensor: SensorProfile::REFERENCE,
            frame_rate: FrameRate::new(24, 1).unwrap(),
            shutter_duration: RationalTime::new(1, 48).unwrap(),
            temporal_samples: 8,
            readout: SensorReadout::Global,
            noise_seed: 42,
            neutral_density_stops: 0.0,
            development: CameraDevelopment {
                white_balance: LinearRgb::new(1.0, 1.0, 1.0),
                middle_gray_illuminance_seconds: 0.09,
                develop_exposure_ev: 0.0,
            },
            transform: CameraOutputTransform::SrgbSdr100,
        };
        let base_scale = camera_preview_exposure_scale(base);
        assert!((base_scale - 1.0 / 24.0).abs() < 1.0e-6);
        assert!(
            (camera_preview_exposure_scale(CapturePipelineSettings {
                neutral_density_stops: 2.0,
                development: CameraDevelopment {
                    develop_exposure_ev: 1.0,
                    ..base.development
                },
                ..base
            }) - base_scale * 0.5)
                .abs()
                < 1.0e-6
        );
    }

    #[test]
    fn native_display_pyramid_area_filters_chroma_aliases_without_mutating_source() {
        let source = [
            255, 0, 0, 255, 0, 255, 255, 255, 255, 0, 0, 255, 0, 255, 255, 255, 255, 0, 0, 255, 0,
            255, 255, 255, 255, 0, 0, 255, 0, 255, 255, 255,
        ];
        let levels = build_native_display_levels(8, 1, &source);

        assert_eq!(&source[0..4], &[255, 0, 0, 255]);
        assert_eq!((levels[0].width, levels[0].height), (4, 1));
        assert!(
            levels[0]
                .pixels
                .chunks_exact(4)
                .all(|pixel| pixel == [128, 128, 128, 255])
        );
        assert_eq!((levels[2].width, levels[2].height), (1, 1));
        assert_eq!(levels[2].pixels, [128, 128, 128, 255]);
    }

    #[test]
    fn native_display_pyramid_preserves_odd_image_edges() {
        let source = [42, 84, 126, 255].repeat(15);
        let levels = build_native_display_levels(5, 3, &source);
        assert_eq!((levels[0].width, levels[0].height), (3, 2));
        assert_eq!((levels[1].width, levels[1].height), (2, 1));
        assert_eq!((levels[2].width, levels[2].height), (1, 1));
        assert!(
            levels
                .iter()
                .flat_map(|level| level.pixels.chunks_exact(4))
                .all(|pixel| pixel == [42, 84, 126, 255])
        );
    }

    #[test]
    fn native_png_export_preserves_exact_level_zero_pixels() {
        let pixels = Arc::<[u8]>::from(vec![
            1, 2, 3, 255, 10, 20, 30, 255, 100, 110, 120, 255, 250, 240, 230, 255,
        ]);
        let frame = NativeExportFrame {
            width: 2,
            height: 2,
            pixels: Arc::clone(&pixels),
            transform: CameraOutputTransform::SrgbSdr100,
        };
        let mut encoded = Vec::new();
        encode_native_png(&mut encoded, &frame).expect("native PNG encoding");
        let decoded = image::load_from_memory_with_format(&encoded, image::ImageFormat::Png)
            .expect("native PNG decoding")
            .to_rgba8();
        assert_eq!((decoded.width(), decoded.height()), (2, 2));
        assert_eq!(decoded.as_raw(), pixels.as_ref());
    }
}
