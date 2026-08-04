//! Screen Simulation desktop composition root.

#![deny(unsafe_code)]

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;
use std::time::Instant;

use screen_application::{
    DiagnosticView, SimulationRequest, inspection_region_from_drag, prepare_raster,
};
use screen_contracts::{LinearRgb, Meters, Millimeters, RationalTime, Vec2};
use screen_geometry::{CameraRig, PanelRegion};
use screen_media::{AlphaPresence, FrameCadence, MediaDescriptor};
use screen_panel::{LcdProfile, StripeLayout};
use screen_platform::probe_media;
use slint::{Image, Rgba8Pixel, SharedPixelBuffer};

const FRAME_RATE: u32 = 24;
const DURATION_FRAMES: u32 = 96;
const PREVIEW_WIDTH: u16 = 960;
const PREVIEW_HEIGHT: u16 = 540;

slint::include_modules!();

#[derive(Default)]
struct InteractionState {
    inspection: Option<PanelRegion>,
}

fn simulation_request(window: &MainWindow, inspection: Option<PanelRegion>) -> SimulationRequest {
    let view = match window.get_view_index() {
        1 => DiagnosticView::DeviceSignal,
        2 => DiagnosticView::Subpixels,
        3 => DiagnosticView::EmittedRadiance,
        _ => DiagnosticView::Composite,
    };
    SimulationRequest {
        time: RationalTime::new(i64::from(window.get_frame_number()), FRAME_RATE)
            .expect("the fixed frame rate is non-zero"),
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
            orbit_duration: RationalTime::new(i64::from(DURATION_FRAMES), FRAME_RATE)
                .expect("the fixed animation duration is non-zero"),
        },
        inspection,
        view,
    }
}

fn render_preview(window: &MainWindow, state: &InteractionState) {
    let started = Instant::now();
    match prepare_raster(
        simulation_request(window, state.inspection),
        PREVIEW_WIDTH,
        PREVIEW_HEIGHT,
    ) {
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
        }
        Err(error) => window.set_error_text(error.to_string().into()),
    }
}

fn load_source(window: &MainWindow, path: &Path) {
    match probe_media(path) {
        Ok(descriptor) => present_source(window, path, &descriptor),
        Err(error) => window.set_error_text(error.to_string().into()),
    }
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
    window.set_source_interpretation("IDT selection required · preview remains diagnostic".into());
    window.set_error_text("".into());
}

fn main() -> Result<(), slint::PlatformError> {
    let window = MainWindow::new()?;
    let state = Rc::new(RefCell::new(InteractionState::default()));

    {
        let weak_window = window.as_weak();
        window.on_choose_source(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            if let Some(path) = rfd::FileDialog::new()
                .set_title("Choose screen source media")
                .pick_file()
            {
                load_source(&window, &path);
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
            let request = simulation_request(&window, current_inspection);
            match inspection_region_from_drag(
                request,
                to_ndc(start_x, start_y),
                to_ndc(end_x, end_y),
            ) {
                Ok(region) => {
                    state.borrow_mut().inspection = Some(region);
                    render_preview(&window, &state.borrow());
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
            state.borrow_mut().inspection = None;
            render_preview(&window, &state.borrow());
        });
    }
    {
        let weak_window = window.as_weak();
        let state = Rc::clone(&state);
        window.on_tick(move || {
            let Some(window) = weak_window.upgrade() else {
                return;
            };
            if window.get_playing() {
                window.set_frame_number(
                    (window.get_frame_number() + 1) % (DURATION_FRAMES as i32 + 1),
                );
            }
            render_preview(&window, &state.borrow());
        });
    }

    if let Some(path) = std::env::args_os().nth(1) {
        load_source(&window, Path::new(&path));
    }
    render_preview(&window, &state.borrow());
    window.run()
}
