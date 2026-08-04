//! Screen Simulation desktop composition root.

#![deny(unsafe_code)]

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Instant;

use screen_application::{
    ApplicationError, DeviceSignalRaster, DiagnosticView, RasterPlacement, SimulationRequest,
    decoded_frame_to_device_signal, inspection_region_from_drag, prepare_raster,
    prepare_raster_from_device_signal,
};
use screen_color::SourceColorInterpretation;
use screen_contracts::{FrameRate, LinearRgb, Meters, Millimeters, RationalTime, Vec2};
use screen_geometry::{CameraRig, PanelRegion};
use screen_media::{
    AlphaInterpretation, AlphaPresence, DecodedFrame, FrameCadence, FrameSelectionPolicy,
    MediaDescriptor,
};
use screen_panel::{LcdProfile, StripeLayout};
use screen_platform::decode_frame_at_time;
use slint::{Image, Rgba8Pixel, SharedPixelBuffer};

const DURATION_FRAMES: u32 = 96;
const PREVIEW_WIDTH: u16 = 960;
const PREVIEW_HEIGHT: u16 = 540;

slint::include_modules!();

struct InteractionState {
    inspection: Option<PanelRegion>,
    source: Option<LoadedSource>,
    last_tick: Instant,
    playback_accumulator_seconds: f64,
}

struct LoadedSource {
    path: PathBuf,
    descriptor: MediaDescriptor,
    requested_time: RationalTime,
    sample_policy: FrameSelectionPolicy,
    decoded_timestamp: RationalTime,
    straight_over_black: DeviceSignalRaster,
    premultiplied_over_black: DeviceSignalRaster,
}

impl InteractionState {
    fn new() -> Self {
        Self {
            inspection: None,
            source: None,
            last_tick: Instant::now(),
            playback_accumulator_seconds: 0.0,
        }
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

fn simulation_request(
    window: &MainWindow,
    inspection: Option<PanelRegion>,
) -> Result<SimulationRequest, String> {
    let frame_rate = project_frame_rate(window)?;
    let view = match window.get_view_index() {
        1 => DiagnosticView::DeviceSignal,
        2 => DiagnosticView::Subpixels,
        3 => DiagnosticView::EmittedRadiance,
        _ => DiagnosticView::Composite,
    };
    Ok(SimulationRequest {
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
        },
        camera: CameraRig {
            distance: Meters(window.get_distance_m()),
            focal_length: Millimeters(window.get_focal_mm()),
            sensor_width: Millimeters(36.0),
            orbit_amplitude_degrees: window.get_orbit_degrees(),
            orbit_duration: frame_rate
                .time_at_frame(i64::from(DURATION_FRAMES))
                .map_err(|error| error.to_string())?,
        },
        inspection,
        view,
    })
}

fn render_preview(window: &MainWindow, state: &mut InteractionState) {
    let started = Instant::now();
    let request = match simulation_request(window, state.inspection) {
        Ok(request) => request,
        Err(error) => {
            block_preview(window, &error);
            return;
        }
    };
    let prepared = match &mut state.source {
        None => prepare_raster(request, PREVIEW_WIDTH, PREVIEW_HEIGHT),
        Some(source) => {
            if window.get_idt_index() == 0 {
                block_preview(window, "Select an authoritative source IDT");
                return;
            }
            if source.descriptor.alpha == AlphaPresence::Present
                && !matches!(window.get_alpha_index(), 1 | 2)
            {
                block_preview(
                    window,
                    "Alpha metadata cannot resolve association; choose Straight or Premultiplied",
                );
                return;
            }
            let sample_policy = frame_selection_policy(window);
            if (source.requested_time != request.time || source.sample_policy != sample_policy)
                && let Err(error) = refresh_loaded_source(source, request.time, sample_policy)
            {
                block_preview(window, &error);
                return;
            }
            let signal = match (source.descriptor.alpha, window.get_alpha_index()) {
                (AlphaPresence::Absent, _) => &source.straight_over_black,
                (AlphaPresence::Present, 1) => &source.straight_over_black,
                (AlphaPresence::Present, 2) => &source.premultiplied_over_black,
                _ => unreachable!("alpha association was validated before sample refresh"),
            };
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
                if raster.frame.view == DiagnosticView::Subpixels
                    && !raster.subpixels_resolved_at_center
                {
                    "Hold Z and drag on the panel to resolve physical subpixels".into()
                } else if raster.frame.inspection.is_some() {
                    "Esc or Shift+Z · return to main camera".into()
                } else {
                    "Hold Z and drag · physical inspection camera".into()
                },
            );
            window.set_error_text("".into());
            if let Some(source) = &state.source {
                let alpha = match source.descriptor.alpha {
                    AlphaPresence::Absent => "opaque",
                    AlphaPresence::Present if window.get_alpha_index() == 1 => {
                        "straight → opaque black"
                    }
                    AlphaPresence::Present => "premultiplied → opaque black",
                };
                window.set_source_interpretation(
                    format!(
                        "Identity device signal · {alpha} · sample {}/{} s · {:?}",
                        source.decoded_timestamp.numerator(),
                        source.decoded_timestamp.denominator(),
                        source.sample_policy
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
    let requested_time = match simulation_request(window, state.inspection) {
        Ok(request) => request.time,
        Err(error) => {
            window.set_error_text(error.into());
            return;
        }
    };
    let sample_policy = frame_selection_policy(window);
    match decode_frame_at_time(path, requested_time, sample_policy) {
        Ok((descriptor, frame)) => {
            let loaded = match prepare_loaded_source(
                path.to_owned(),
                descriptor,
                frame,
                requested_time,
                sample_policy,
            ) {
                Ok(loaded) => loaded,
                Err(error) => {
                    window.set_error_text(error.to_string().into());
                    return;
                }
            };
            present_source(window, path, &loaded.descriptor);
            state.source = Some(loaded);
            state.inspection = None;
            window.set_idt_index(0);
            window.set_alpha_index(0);
            render_preview(window, state);
        }
        Err(error) => window.set_error_text(error.to_string().into()),
    }
}

fn prepare_loaded_source(
    path: PathBuf,
    descriptor: MediaDescriptor,
    frame: DecodedFrame,
    requested_time: RationalTime,
    sample_policy: FrameSelectionPolicy,
) -> Result<LoadedSource, ApplicationError> {
    let straight_over_black = decoded_frame_to_device_signal(
        &frame,
        descriptor.alpha,
        AlphaInterpretation::Straight,
        SourceColorInterpretation::IdentityDeviceSignal,
    )?;
    let premultiplied_over_black = decoded_frame_to_device_signal(
        &frame,
        descriptor.alpha,
        AlphaInterpretation::Premultiplied,
        SourceColorInterpretation::IdentityDeviceSignal,
    )?;
    Ok(LoadedSource {
        path,
        descriptor,
        requested_time,
        sample_policy,
        decoded_timestamp: frame.timestamp,
        straight_over_black,
        premultiplied_over_black,
    })
}

fn refresh_loaded_source(
    source: &mut LoadedSource,
    requested_time: RationalTime,
    sample_policy: FrameSelectionPolicy,
) -> Result<(), String> {
    let (descriptor, frame) = decode_frame_at_time(&source.path, requested_time, sample_policy)
        .map_err(|error| error.to_string())?;
    if descriptor != source.descriptor {
        return Err("source descriptor changed on disk; reopen the source explicitly".to_owned());
    }
    let refreshed = prepare_loaded_source(
        source.path.clone(),
        descriptor,
        frame,
        requested_time,
        sample_policy,
    )
    .map_err(|error| error.to_string())?;
    *source = refreshed;
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
    window.set_source_interpretation("IDT selection required · evaluation blocked".into());
    window.set_error_text("".into());
}

fn main() -> Result<(), slint::PlatformError> {
    let window = MainWindow::new()?;
    let state = Rc::new(RefCell::new(InteractionState::new()));

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
            let request = match simulation_request(&window, current_inspection) {
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
    window.run()
}
