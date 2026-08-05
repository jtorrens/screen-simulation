//! Screen Simulation desktop composition root.

#![deny(unsafe_code)]

pub mod project_mapping;

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Instant;

use screen_application::{
    ApplicationError, DeviceSignalRaster, DiagnosticView, FrameCaptureRequest, OpticalRequest,
    PreparedDeviceSignalRaster, ProceduralTestPattern, RasterPlacement, SensorReadout,
    SimulationRequest, capture_and_develop_frame_from_device_signal_sequence,
    capture_and_develop_procedural_frame, decoded_frame_to_device_signal,
    inspection_region_from_drag, prepare_raster, prepare_raster_from_device_signal,
};
use screen_camera::CameraDevelopment;
use screen_color::{
    CameraOutputTransform, ColorEngine, DeviceColorTarget, OcioInputTransform,
    SourceColorInterpretation, SourceToDeviceProcessor, propose_ocio_input,
};
use screen_contracts::{FrameRate, LinearRgb, Meters, Millimeters, RationalTime, Vec2, Vec3};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation, LensModel,
    PanelRegion, Quaternion, ScreenTrack, TransformKeyframe, TransformTrack,
};
use screen_media::{
    AlphaInterpretation, AlphaPresence, DecodedFrame, FrameCadence, FrameSelectionPolicy,
    MediaDescriptor, ResolvedSignalRange, ResolvedSourceDecode, ResolvedYuvMatrix,
    SignalRangeSelection, SourceDecodeInterpretation, YuvMatrixSelection,
};
use screen_panel::{
    DEVICE_GEOMETRY_PRESETS, LcdProfile, PanelColorimetry, PanelTemporalEmission, StripeLayout,
    device_geometry_preset,
};
use screen_platform::{decode_frame_at_time, probe_media};
use screen_sensor::SensorProfile;
use slint::{Image, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};

const DURATION_FRAMES: u32 = 96;
const PREVIEW_WIDTH: u16 = 960;
const PREVIEW_HEIGHT: u16 = 540;

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
    output_transform_index: i32,
    sensor_raster_index: i32,
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
        output_transform_index: window.get_output_transform_index(),
        sensor_raster_index: window.get_sensor_raster_index(),
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

fn camera_edit_from_controls(controls: RenderControls) -> CameraEdit {
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
    interpolation: KeyframeInterpolation,
}

fn camera_edit_from_window(window: &MainWindow) -> CameraEdit {
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
            lens: LensModel::REFERENCE_PHOTOGRAPHIC,
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
) -> Result<(), String> {
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
    Ok(())
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
) -> Result<SimulationRequest, String> {
    let frame_rate = project_frame_rate(window)?;
    let (native_width, native_height, active_width, active_height) = device_geometry(window)?;
    let view = match window.get_view_index() {
        1 => DiagnosticView::DeviceSignal,
        2 => DiagnosticView::Subpixels,
        3 => DiagnosticView::EmittedRadiance,
        _ => DiagnosticView::Composite,
    };
    Ok(SimulationRequest {
        optics: OpticalRequest {
            time: frame_rate
                .time_at_frame(i64::from(window.get_frame_number()))
                .map_err(|error| error.to_string())?,
            viewport_aspect: f32::from(PREVIEW_WIDTH) / f32::from(PREVIEW_HEIGHT),
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
                temporal_emission: PanelTemporalEmission::continuous(),
            },
            camera: camera.clone(),
            screen: screen.clone(),
            inspection,
            procedural_pattern: if window.get_procedural_pattern_index() == 1 {
                ProceduralTestPattern::EyeChart
            } else {
                ProceduralTestPattern::AnimatedCheckerboard
            },
        },
        view,
        preview_exposure_ev: window.get_preview_exposure_ev(),
    })
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

fn apply_device_preset(window: &MainWindow, id: &str) -> Result<(), String> {
    if id == "custom" {
        update_device_summary(window);
        return Ok(());
    }
    let preset = device_geometry_preset(id)
        .ok_or_else(|| format!("unknown current device preset id {id}"))?;
    window.set_device_native_width(preset.native_width as f32);
    window.set_device_native_height(preset.native_height as f32);
    window.set_device_active_width_mm(preset.active_width.0 * 1_000.0);
    window.set_device_active_height_mm(preset.active_height.0 * 1_000.0);
    update_device_summary(window);
    Ok(())
}

fn render_preview(window: &MainWindow, state: &mut InteractionState) {
    state.last_render_controls = Some(render_controls(window));
    if state.source.is_none() {
        present_procedural_source(window);
    }
    let started = Instant::now();
    let request = match simulation_request(
        window,
        state.inspection,
        state.camera_editor.effective(),
        &state.screen,
    ) {
        Ok(request) => request,
        Err(error) => {
            block_preview(window, &error);
            return;
        }
    };
    let color_engine = &state.color_engine;
    if window.get_view_index() == 4 && state.source.is_none() {
        render_camera_result(window, request, color_engine, None, started);
        return;
    }
    let prepared = match &mut state.source {
        None => prepare_raster(request, PREVIEW_WIDTH, PREVIEW_HEIGHT),
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
            if window.get_view_index() == 4 {
                let prepared_signal = match PreparedDeviceSignalRaster::new(signal.clone()) {
                    Ok(signal) => Arc::new(signal),
                    Err(error) => {
                        block_preview(window, &error.to_string());
                        return;
                    }
                };
                render_camera_result(
                    window,
                    request,
                    color_engine,
                    Some((prepared_signal, placement)),
                    started,
                );
                return;
            }
            prepare_raster_from_device_signal(
                request,
                PREVIEW_WIDTH,
                PREVIEW_HEIGHT,
                signal,
                placement,
            )
        }
    };
    match prepared {
        Ok(raster) => {
            let mut buffer = SharedPixelBuffer::<Rgba8Pixel>::new(
                u32::from(PREVIEW_WIDTH),
                u32::from(PREVIEW_HEIGHT),
            );
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
            window.set_scale_text(
                format!(
                    "DEVICE PIXEL {device_pixel_width:.2} px · RGB STRIPE {subpixel_width:.2} px · {resolution}"
                )
                .into(),
            );
            window.set_render_text(
                format!(
                    "{} × {} · {:.1} ms",
                    PREVIEW_WIDTH,
                    PREVIEW_HEIGHT,
                    started.elapsed().as_secs_f64() * 1_000.0
                )
                .into(),
            );
            window.set_inspection_text(match raster.inspection_field_meters {
                Some([width, height]) => format!(
                    "INSPECTION · FIELD {:.2} × {:.2} mm",
                    width * 1_000.0,
                    height * 1_000.0
                )
                .into(),
                None => "FIT · MAIN CAMERA".into(),
            });
            window.set_hint_text(
                if window.get_view_index() == 2 && !raster.subpixels_resolved_at_center {
                    "Hold Z and drag on the panel to resolve physical subpixels".into()
                } else if raster.frame.inspection.is_some() {
                    "Esc or Shift+Z · return to main camera".into()
                } else {
                    "Hold Z and drag · physical inspection camera".into()
                },
            );
            window.set_error_text("".into());
            if let Some(source) = &state.source {
                let (interpretation, interpretation_label) = source_color_interpretation(window)
                    .expect("rendered media has an explicit interpretation");
                let interpretation_description = match interpretation {
                    SourceColorInterpretation::IdentityDeviceSignal => {
                        interpretation_label.to_owned()
                    }
                    SourceColorInterpretation::Ocio(_) => {
                        format!("{interpretation_label} → sRGB device")
                    }
                };
                let alpha = match source.descriptor.alpha {
                    AlphaPresence::Absent => "opaque",
                    AlphaPresence::Present if window.get_alpha_index() == 1 => {
                        "straight → opaque black"
                    }
                    AlphaPresence::Present => "premultiplied → opaque black",
                };
                let sample_key = source
                    .decoded_sample_key
                    .expect("rendered media has a resolved decoded sample");
                let decoded_timestamp = source
                    .decoded_timestamp
                    .expect("rendered media has an exact decoded timestamp");
                window.set_source_interpretation(
                    format!(
                        "{} · {interpretation_description} · {alpha} · sample {}/{} s · {:?}",
                        decode_interpretation_description(sample_key.interpretation),
                        decoded_timestamp.numerator(),
                        decoded_timestamp.denominator(),
                        sample_key.sample_policy
                    )
                    .into(),
                );
            }
        }
        Err(error) => window.set_error_text(error.to_string().into()),
    }
}

fn present_procedural_source(window: &MainWindow) {
    if window.get_procedural_pattern_index() == 1 {
        window.set_source_title("Eye chart".into());
        window.set_source_details("3840 × 2160 · black optotypes on white".into());
        window.set_source_interpretation("Explicit sRGB device signal · bounded 0–1".into());
    } else {
        window.set_source_title("Procedural diagnostic".into());
        window.set_source_details("3840 × 2160 · animated checkerboard".into());
        window.set_source_interpretation("Explicit device signal".into());
    }
}

fn render_camera_result(
    window: &MainWindow,
    request: SimulationRequest,
    color_engine: &ColorEngine,
    source: Option<(Arc<PreparedDeviceSignalRaster>, RasterPlacement)>,
    started: Instant,
) {
    let frame_rate = match project_frame_rate(window) {
        Ok(value) => value,
        Err(error) => {
            block_preview(window, &error);
            return;
        }
    };
    let shutter_denominator = match frame_rate.numerator().checked_mul(2) {
        Some(value) => value,
        None => {
            block_preview(
                window,
                "project frame rate is too large for a 180-degree shutter",
            );
            return;
        }
    };
    let shutter_duration =
        match RationalTime::new(i64::from(frame_rate.denominator()), shutter_denominator) {
            Ok(value) => value,
            Err(error) => {
                block_preview(window, &error.to_string());
                return;
            }
        };
    let capture = FrameCaptureRequest {
        optics: request.optics,
        frame_rate,
        frame_index: i64::from(window.get_frame_number()),
        duration: shutter_duration,
        temporal_samples: 1,
        readout: SensorReadout::Global,
        noise_seed: 42,
    };
    let (sensor_width, sensor_height) = match sensor_raster(window.get_sensor_raster_index()) {
        Ok(value) => value,
        Err(error) => {
            block_preview(window, error);
            return;
        }
    };
    let sensor = SensorProfile {
        native_width: sensor_width,
        native_height: sensor_height,
        ..SensorProfile::REFERENCE
    };
    let development = CameraDevelopment {
        white_balance: LinearRgb::new(
            window.get_white_balance_r(),
            window.get_white_balance_g(),
            window.get_white_balance_b(),
        ),
        linear_exposure_scale: sensor.saturation_exposure.g.recip()
            * window.get_camera_exposure_ev().exp2(),
    };
    let captured = match source {
        Some((prepared, placement)) => capture_and_develop_frame_from_device_signal_sequence(
            capture,
            placement,
            |_| Ok(Arc::clone(&prepared)),
            sensor,
            development,
        ),
        None => capture_and_develop_procedural_frame(capture, sensor, development),
    };
    let captured = match captured {
        Ok(value) => value,
        Err(error) => {
            block_preview(window, &error.to_string());
            return;
        }
    };
    let transform = match window.get_output_transform_index() {
        0 => CameraOutputTransform::SrgbSdr100,
        1 => CameraOutputTransform::Rec709Sdr100,
        2 => CameraOutputTransform::Rec2100Pq1000,
        _ => {
            block_preview(window, "select an explicit camera output transform");
            return;
        }
    };
    let processor = match color_engine.camera_output_processor(transform) {
        Ok(value) => value,
        Err(error) => {
            block_preview(window, &error.to_string());
            return;
        }
    };
    let mut output = Vec::with_capacity(captured.developed.acescg.len() * 4);
    for pixel in &captured.developed.acescg {
        output.extend_from_slice(&[pixel.r, pixel.g, pixel.b, 1.0]);
    }
    if let Err(error) = processor.apply_acescg_rgba_buffer(&mut output) {
        block_preview(window, &error.to_string());
        return;
    }
    let mut buffer =
        SharedPixelBuffer::<Rgba8Pixel>::new(u32::from(sensor_width), u32::from(sensor_height));
    for (target, rgba) in buffer
        .make_mut_slice()
        .iter_mut()
        .zip(output.chunks_exact(4))
    {
        let channel = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
        *target = Rgba8Pixel {
            r: channel(rgba[0]),
            g: channel(rgba[1]),
            b: channel(rgba[2]),
            a: 255,
        };
    }
    let clipped = captured.raw.clipped.iter().filter(|value| **value).count();
    window.set_preview_image(Image::from_rgba8(buffer));
    window.set_scale_text(
        format!(
            "CAMERA SENSOR {} × {} · {}-BIT BAYER · NATIVE VIEW · {} CLIPPED",
            sensor_width, sensor_height, sensor.adc_bits, clipped
        )
        .into(),
    );
    window.set_render_text(
        format!(
            "RAW → demosaic → WB → ACEScg → {} · {:.1} ms",
            transform.label(),
            started.elapsed().as_secs_f64() * 1_000.0
        )
        .into(),
    );
    window.set_inspection_text("DEVELOPED CAMERA FRAME · 180° GLOBAL SHUTTER".into());
    window.set_hint_text(
        "Native sensor result · increase View zoom and drag to inspect without moving camera"
            .into(),
    );
    window.set_error_text("".into());
}

fn sensor_raster(index: i32) -> Result<(u16, u16), &'static str> {
    match index {
        0 => Ok((960, 540)),
        1 => Ok((1_920, 1_080)),
        2 => Ok((3_840, 2_160)),
        _ => Err("select an explicit sensor raster"),
    }
}

fn block_preview(window: &MainWindow, message: &str) {
    window.set_preview_image(Image::default());
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
    let device_labels: Vec<SharedString> = DEVICE_GEOMETRY_PRESETS
        .iter()
        .map(|preset| preset.label.into())
        .chain(std::iter::once("Custom".into()))
        .collect();
    let device_ids: Vec<SharedString> = DEVICE_GEOMETRY_PRESETS
        .iter()
        .map(|preset| preset.id.into())
        .chain(std::iter::once("custom".into()))
        .collect();
    window.set_device_preset_model(ModelRc::new(VecModel::from(device_labels)));
    window.set_device_preset_ids(ModelRc::new(VecModel::from(device_ids)));
    window.set_build_id(
        option_env!("SCREEN_SIM_BUILD_ID")
            .unwrap_or("development")
            .into(),
    );
    apply_device_preset(&window, "lcd-macbook-pro-retina-14")?;
    let color_engine = ColorEngine::bundled()?;
    let state = Rc::new(RefCell::new(InteractionState::new(color_engine)));

    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_select_device_preset(move |id| {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            match apply_device_preset(&window, id.as_str()) {
                Ok(()) => render_preview(&window, &mut state.borrow_mut()),
                Err(error) => block_preview(&window, &error),
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
            state
                .camera_editor
                .preview_edit(time, camera_edit_from_window(&window));
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
                if let Err(error) =
                    set_camera_controls_from_committed(&window, &state.camera_editor, time)
                {
                    window.set_error_text(error.into());
                    return;
                }
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
                if let Err(error) =
                    set_camera_controls_from_committed(&window, &state.camera_editor, time)
                {
                    window.set_error_text(error.into());
                    return;
                }
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
                if let Err(error) =
                    set_camera_controls_from_committed(&window, &state.camera_editor, time)
                {
                    block_preview(&window, &error);
                    return;
                }
                current_controls = render_controls(&window);
                update_undo_availability(&window, &state.camera_editor);
            } else if previous_controls.is_some_and(|previous| {
                camera_edit_from_controls(previous) != camera_edit_from_controls(current_controls)
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
                state
                    .camera_editor
                    .preview_edit(time, camera_edit_from_controls(current_controls));
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
                interpolation: KeyframeInterpolation::Hold,
            },
        );
        editor.commit_preview();
        assert_eq!(editor.committed.transform.keyframes[0].id, transform_id);
        assert_eq!(editor.committed.intrinsics.keyframes[0].id, intrinsics_id);
    }
}
