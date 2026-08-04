//! Screen Simulation desktop composition root.

#![deny(unsafe_code)]

pub mod project_mapping;

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Instant;

use screen_application::{
    ApplicationError, DeviceSignalRaster, DiagnosticView, OpticalRequest, RasterPlacement,
    SimulationRequest, decoded_frame_to_device_signal, inspection_region_from_drag, prepare_raster,
    prepare_raster_from_device_signal,
};
use screen_color::{
    ColorEngine, DeviceColorTarget, OcioInputTransform, SourceColorInterpretation,
    SourceToDeviceProcessor, propose_ocio_input,
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
use screen_panel::{LcdProfile, PanelColorimetry, StripeLayout};
use screen_platform::{decode_frame_at_time, probe_media};
use slint::{Image, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};

const DURATION_FRAMES: u32 = 96;
const PREVIEW_WIDTH: u16 = 960;
const PREVIEW_HEIGHT: u16 = 540;

slint::include_modules!();

struct InteractionState {
    inspection: Option<PanelRegion>,
    source: Option<LoadedSource>,
    color_engine: ColorEngine,
    last_tick: Instant,
    playback_accumulator_seconds: f64,
    camera: CameraRig,
    screen: ScreenTrack,
    next_camera_key_id: u64,
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
            camera: camera_rig(vec![camera_keyframes(
                "camera-key-0".to_owned(),
                RationalTime::new(0, 1).expect("initial camera time is valid"),
                CameraEdit {
                    distance: 0.82,
                    yaw_degrees: 0.0,
                    focal_mm: 50.0,
                    focus_distance_m: 0.82,
                    f_stop: 8.0,
                    interpolation: KeyframeInterpolation::Smooth,
                },
            )]),
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
            next_camera_key_id: 1,
        }
    }
}

#[derive(Clone, Copy)]
struct CameraEdit {
    distance: f32,
    yaw_degrees: f32,
    focal_mm: f32,
    focus_distance_m: f32,
    f_stop: f32,
    interpolation: KeyframeInterpolation,
}

fn camera_keyframes(
    id: String,
    time: RationalTime,
    edit: CameraEdit,
) -> (TransformKeyframe, CameraIntrinsicsKeyframe) {
    let yaw = edit.yaw_degrees.to_radians();
    (
        TransformKeyframe {
            id: format!("{id}-transform"),
            time,
            translation: Vec3 {
                x: edit.distance * yaw.sin(),
                y: 0.0,
                z: edit.distance * yaw.cos(),
            },
            rotation: Quaternion::from_yaw_degrees(edit.yaw_degrees),
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
                native_width: 3840,
                native_height: 2160,
                active_width: Meters(0.596_736),
                active_height: Meters(0.335_664),
                stripe_layout: if window.get_stripe_index() == 1 {
                    StripeLayout::Bgr
                } else {
                    StripeLayout::Rgb
                },
                black_matrix_fraction: window.get_black_matrix(),
                eotf_gamma: window.get_gamma(),
                black_level_nits: 0.08,
                white_level_nits: window.get_white_nits(),
                channel_efficiency: LinearRgb::new(1.0, 0.96, 0.9),
                colorimetry: PanelColorimetry::SRGB_D65,
                angular_emission_power: LinearRgb::new(1.7, 1.5, 1.8),
            },
            camera: camera.clone(),
            screen: screen.clone(),
            inspection,
        },
        view,
        preview_exposure_ev: window.get_preview_exposure_ev(),
    })
}

fn render_preview(window: &MainWindow, state: &mut InteractionState) {
    let started = Instant::now();
    let request = match simulation_request(window, state.inspection, &state.camera, &state.screen) {
        Ok(request) => request,
        Err(error) => {
            block_preview(window, &error);
            return;
        }
    };
    let color_engine = &state.color_engine;
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
    let color_engine = ColorEngine::bundled()?;
    let state = Rc::new(RefCell::new(InteractionState::new(color_engine)));

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
            let current_inspection = state.borrow().inspection;
            let request = match simulation_request(
                &window,
                current_inspection,
                &state.borrow().camera,
                &state.borrow().screen,
            ) {
                Ok(request) => request,
                Err(error) => {
                    window.set_error_text(error.into());
                    return;
                }
            };
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
            let interpolation = match window.get_camera_interpolation_index() {
                0 => KeyframeInterpolation::Hold,
                1 => KeyframeInterpolation::Linear,
                _ => KeyframeInterpolation::Smooth,
            };
            let mut state = state.borrow_mut();
            match state
                .camera
                .transform
                .keyframes
                .binary_search_by_key(&time, |item| item.time)
            {
                Ok(index) => {
                    let id = format!("camera-key-{}", index);
                    let (transform, intrinsics) = camera_keyframes(
                        id,
                        time,
                        CameraEdit {
                            distance: window.get_distance_m(),
                            yaw_degrees: window.get_yaw_degrees(),
                            focal_mm: window.get_focal_mm(),
                            focus_distance_m: window.get_focus_distance_m(),
                            f_stop: window.get_f_stop(),
                            interpolation,
                        },
                    );
                    state.camera.transform.keyframes[index] = transform;
                    state.camera.intrinsics.keyframes[index] = intrinsics;
                }
                Err(index) => {
                    let id = format!("camera-key-{}", state.next_camera_key_id);
                    state.next_camera_key_id += 1;
                    let (transform, intrinsics) = camera_keyframes(
                        id,
                        time,
                        CameraEdit {
                            distance: window.get_distance_m(),
                            yaw_degrees: window.get_yaw_degrees(),
                            focal_mm: window.get_focal_mm(),
                            focus_distance_m: window.get_focus_distance_m(),
                            f_stop: window.get_f_stop(),
                            interpolation,
                        },
                    );
                    state.camera.transform.keyframes.insert(index, transform);
                    state.camera.intrinsics.keyframes.insert(index, intrinsics);
                }
            }
            window.set_camera_key_count(state.camera.transform.keyframes.len() as i32);
            state.inspection = None;
            render_preview(&window, &mut state);
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
            let now = Instant::now();
            let mut state = state.borrow_mut();
            let elapsed = now.duration_since(state.last_tick).as_secs_f64();
            state.last_tick = now;
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
                        }
                    }
                    Err(error) => block_preview(&window, &error),
                }
            } else {
                state.playback_accumulator_seconds = 0.0;
            }
            render_preview(&window, &mut state);
        });
    }

    if let Some(path) = std::env::args_os().nth(1) {
        load_source(&window, &mut state.borrow_mut(), Path::new(&path));
    }
    render_preview(&window, &mut state.borrow_mut());
    window.run()?;
    Ok(())
}
