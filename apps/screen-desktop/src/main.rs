//! Screen Simulation desktop composition root.

#![forbid(unsafe_code)]

use eframe::egui::{
    self, Align, Color32, CornerRadius, FontFamily, FontId, Layout, Pos2, Rect, RichText, Shape,
    Stroke, TextureHandle, TextureOptions, Vec2,
};
use screen_application::{DiagnosticView, PreparedRaster, SimulationRequest, prepare_raster};
use screen_contracts::{LinearRgb, Meters, Millimeters, RationalTime};
use screen_geometry::CameraRig;
use screen_panel::{LcdProfile, StripeLayout};

const FRAME_RATE: u32 = 24;
const DURATION_FRAMES: u32 = 96;

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Screen Simulation")
            .with_inner_size([1440.0, 900.0])
            .with_min_inner_size([1080.0, 680.0]),
        ..Default::default()
    };
    eframe::run_native(
        "Screen Simulation",
        options,
        Box::new(|creation_context| {
            configure_style(&creation_context.egui_ctx);
            Ok(Box::new(ScreenSimulationApp::new()))
        }),
    )
}

struct ScreenSimulationApp {
    frame: u32,
    playback_accumulator: f32,
    playing: bool,
    view: DiagnosticView,
    panel: PanelControls,
    camera: CameraControls,
    preview_texture: Option<TextureHandle>,
}

struct PanelControls {
    native_width: u32,
    native_height: u32,
    active_width_mm: f32,
    active_height_mm: f32,
    stripe_layout: StripeLayout,
    black_matrix: f32,
    gamma: f32,
    black_nits: f32,
    white_nits: f32,
}

struct CameraControls {
    distance_m: f32,
    focal_length_mm: f32,
    orbit_degrees: f32,
}

impl ScreenSimulationApp {
    fn new() -> Self {
        Self {
            frame: 0,
            playback_accumulator: 0.0,
            playing: true,
            view: DiagnosticView::Composite,
            panel: PanelControls {
                native_width: 3840,
                native_height: 2160,
                active_width_mm: 596.736,
                active_height_mm: 335.664,
                stripe_layout: StripeLayout::Rgb,
                black_matrix: 0.12,
                gamma: 2.2,
                black_nits: 0.08,
                white_nits: 600.0,
            },
            camera: CameraControls {
                distance_m: 0.82,
                focal_length_mm: 50.0,
                orbit_degrees: 18.0,
            },
            preview_texture: None,
        }
    }

    fn request(&self, viewport_aspect: f32) -> SimulationRequest {
        SimulationRequest {
            time: RationalTime::new(i64::from(self.frame), FRAME_RATE)
                .expect("constant frame rate is non-zero"),
            viewport_aspect,
            panel: LcdProfile {
                native_width: self.panel.native_width,
                native_height: self.panel.native_height,
                active_width: Meters(self.panel.active_width_mm / 1_000.0),
                active_height: Meters(self.panel.active_height_mm / 1_000.0),
                stripe_layout: self.panel.stripe_layout,
                black_matrix_fraction: self.panel.black_matrix,
                eotf_gamma: self.panel.gamma,
                black_level_nits: self.panel.black_nits,
                white_level_nits: self.panel.white_nits,
                channel_efficiency: LinearRgb::new(1.0, 0.96, 0.9),
            },
            camera: CameraRig {
                distance: Meters(self.camera.distance_m),
                focal_length: Millimeters(self.camera.focal_length_mm),
                sensor_width: Millimeters(36.0),
                orbit_amplitude_degrees: self.camera.orbit_degrees,
                orbit_duration: RationalTime::new(i64::from(DURATION_FRAMES), FRAME_RATE)
                    .expect("constant frame rate is non-zero"),
            },
            inspection: None,
            view: self.view,
        }
    }

    fn update_playback(&mut self, context: &egui::Context) {
        if !self.playing {
            return;
        }
        let delta = context.input(|input| input.stable_dt).min(0.1);
        self.playback_accumulator += delta;
        let frame_duration = 1.0 / FRAME_RATE as f32;
        while self.playback_accumulator >= frame_duration {
            self.playback_accumulator -= frame_duration;
            self.frame = (self.frame + 1) % (DURATION_FRAMES + 1);
        }
        context.request_repaint();
    }
}

impl eframe::App for ScreenSimulationApp {
    fn update(&mut self, context: &egui::Context, _frame: &mut eframe::Frame) {
        self.update_playback(context);
        self.top_bar(context);
        self.inspector(context);
        self.timeline(context);
        self.viewport(context);
    }
}

impl ScreenSimulationApp {
    fn top_bar(&mut self, context: &egui::Context) {
        egui::TopBottomPanel::top("top_bar")
            .exact_height(54.0)
            .frame(
                egui::Frame::new()
                    .fill(Color32::from_rgb(18, 21, 27))
                    .inner_margin(egui::Margin::symmetric(18, 10))
                    .stroke(Stroke::new(1.0_f32, Color32::from_rgb(42, 47, 57))),
            )
            .show(context, |ui| {
                ui.horizontal_centered(|ui| {
                    ui.label(
                        RichText::new("SCREEN SIMULATION")
                            .font(FontId::new(16.0, FontFamily::Proportional))
                            .strong()
                            .color(Color32::from_rgb(226, 232, 242)),
                    );
                    ui.add_space(14.0);
                    tag(ui, "PHYSICAL LCD");
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        tag(ui, "LINEAR FLOAT");
                        ui.label(
                            RichText::new("Diagnostic scene · current contract")
                                .size(12.0)
                                .color(Color32::from_rgb(142, 151, 168)),
                        );
                    });
                });
            });
    }

    fn inspector(&mut self, context: &egui::Context) {
        egui::SidePanel::right("inspector")
            .exact_width(292.0)
            .frame(
                egui::Frame::new()
                    .fill(Color32::from_rgb(20, 23, 29))
                    .inner_margin(egui::Margin::same(16))
                    .stroke(Stroke::new(1.0_f32, Color32::from_rgb(42, 47, 57))),
            )
            .show(context, |ui| {
                ui.heading(RichText::new("SCENE INSPECTOR").size(12.0).strong());
                ui.add_space(14.0);
                section(ui, "SOURCE", |ui| {
                    property(ui, "Content", "Procedural diagnostic");
                    property(ui, "Raster", "Device-native 3840 × 2160");
                    property(ui, "Interpretation", "Explicit device signal");
                });
                ui.add_space(12.0);
                section(ui, "LCD PANEL", |ui| {
                    slider(
                        ui,
                        "White",
                        &mut self.panel.white_nits,
                        100.0..=1_500.0,
                        "nit",
                    );
                    slider(ui, "EOTF γ", &mut self.panel.gamma, 1.6..=2.8, "");
                    slider(
                        ui,
                        "Black matrix",
                        &mut self.panel.black_matrix,
                        0.02..=0.3,
                        "",
                    );
                    ui.horizontal(|ui| {
                        ui.label(label_text("Stripe order"));
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            ui.selectable_value(
                                &mut self.panel.stripe_layout,
                                StripeLayout::Bgr,
                                "BGR",
                            );
                            ui.selectable_value(
                                &mut self.panel.stripe_layout,
                                StripeLayout::Rgb,
                                "RGB",
                            );
                        });
                    });
                });
                ui.add_space(12.0);
                section(ui, "CAMERA", |ui| {
                    slider(ui, "Distance", &mut self.camera.distance_m, 0.5..=1.5, "m");
                    slider(
                        ui,
                        "Focal",
                        &mut self.camera.focal_length_mm,
                        24.0..=85.0,
                        "mm",
                    );
                    slider(ui, "Orbit", &mut self.camera.orbit_degrees, 0.0..=35.0, "°");
                    property(ui, "Sensor", "36.0 mm");
                });
                ui.add_space(12.0);
                section(ui, "DIAGNOSTIC VIEW", |ui| {
                    view_button(ui, &mut self.view, DiagnosticView::Composite, "Composite");
                    view_button(
                        ui,
                        &mut self.view,
                        DiagnosticView::DeviceSignal,
                        "Device signal",
                    );
                    view_button(
                        ui,
                        &mut self.view,
                        DiagnosticView::Subpixels,
                        "RGB subpixels",
                    );
                    view_button(
                        ui,
                        &mut self.view,
                        DiagnosticView::EmittedRadiance,
                        "Emitted radiance",
                    );
                });
            });
    }

    fn timeline(&mut self, context: &egui::Context) {
        egui::TopBottomPanel::bottom("timeline")
            .exact_height(92.0)
            .frame(
                egui::Frame::new()
                    .fill(Color32::from_rgb(18, 21, 27))
                    .inner_margin(egui::Margin::symmetric(18, 12))
                    .stroke(Stroke::new(1.0_f32, Color32::from_rgb(42, 47, 57))),
            )
            .show(context, |ui| {
                ui.horizontal(|ui| {
                    if ui
                        .button(if self.playing { "Pause" } else { "Play" })
                        .clicked()
                    {
                        self.playing = !self.playing;
                    }
                    ui.add_space(8.0);
                    ui.label(
                        RichText::new(format!(
                            "{:02}:{:02}",
                            self.frame / FRAME_RATE,
                            self.frame % FRAME_RATE
                        ))
                        .monospace()
                        .color(Color32::from_rgb(229, 234, 244)),
                    );
                    ui.label(
                        RichText::new("24 fps exact")
                            .size(11.0)
                            .color(Color32::from_rgb(126, 136, 153)),
                    );
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        ui.label(
                            RichText::new(format!("frame {} / {}", self.frame, DURATION_FRAMES))
                                .monospace()
                                .size(11.0),
                        );
                    });
                });
                ui.add_space(8.0);
                ui.add(
                    egui::Slider::new(&mut self.frame, 0..=DURATION_FRAMES)
                        .show_value(false)
                        .trailing_fill(true),
                );
            });
    }

    fn viewport(&mut self, context: &egui::Context) {
        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(Color32::from_rgb(11, 13, 17)))
            .show(context, |ui| {
                let available = ui.available_rect_before_wrap();
                let aspect = (available.width() / available.height()).max(0.1);
                let request = self.request(aspect);
                let width = available.width().round().clamp(1.0, f32::from(u16::MAX)) as u16;
                let height = available.height().round().clamp(1.0, f32::from(u16::MAX)) as u16;
                match prepare_raster(request, width, height) {
                    Ok(raster) => {
                        let image = raster_image(&raster);
                        let texture = self.preview_texture.get_or_insert_with(|| {
                            context.load_texture(
                                "physical-preview",
                                image.clone(),
                                TextureOptions::NEAREST,
                            )
                        });
                        texture.set(image, TextureOptions::NEAREST);
                        draw_viewport(ui, available, &raster, texture);
                    }
                    Err(error) => {
                        ui.centered_and_justified(|ui| {
                            ui.colored_label(Color32::from_rgb(242, 107, 107), error.to_string());
                        });
                    }
                }
            });
    }
}

fn draw_viewport(ui: &mut egui::Ui, rect: Rect, raster: &PreparedRaster, texture: &TextureHandle) {
    let painter = ui.painter_at(rect);
    painter.rect_filled(rect, 0.0, Color32::from_rgb(10, 12, 16));
    draw_grid(&painter, rect);
    painter.image(
        texture.id(),
        rect,
        Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
        Color32::WHITE,
    );

    let outline = screen_points(rect, &raster.frame.projected_screen.corners);
    painter.add(Shape::closed_line(
        outline,
        Stroke::new(1.5_f32, Color32::from_rgb(111, 129, 158)),
    ));

    let title_pos = rect.left_top() + Vec2::new(22.0, 20.0);
    painter.text(
        title_pos,
        egui::Align2::LEFT_TOP,
        view_name(raster.frame.view),
        FontId::new(12.0, FontFamily::Proportional),
        Color32::from_rgb(182, 193, 211),
    );
    painter.text(
        title_pos + Vec2::new(0.0, 20.0),
        egui::Align2::LEFT_TOP,
        format!(
            "{} × {}  ·  {:.1} ppi  ·  pitch {:.1} µm",
            raster.frame.native_raster[0],
            raster.frame.native_raster[1],
            raster.frame.pixels_per_inch,
            raster.frame.pixel_pitch_meters * 1_000_000.0
        ),
        FontId::monospace(11.0),
        Color32::from_rgb(112, 124, 143),
    );
    painter.text(
        rect.right_bottom() - Vec2::new(22.0, 20.0),
        egui::Align2::RIGHT_BOTTOM,
        format!(
            "camera yaw {:+.2}°  ·  facing {:.3}",
            raster.frame.camera_yaw_degrees, raster.frame.projected_screen.facing_ratio
        ),
        FontId::monospace(11.0),
        Color32::from_rgb(112, 124, 143),
    );
}

fn screen_points(rect: Rect, points: &[screen_contracts::Vec2; 4]) -> Vec<Pos2> {
    points
        .iter()
        .map(|point| {
            Pos2::new(
                rect.center().x + point.x * rect.width() * 0.5,
                rect.center().y + point.y * rect.height() * 0.5,
            )
        })
        .collect()
}

fn draw_grid(painter: &egui::Painter, rect: Rect) {
    let stroke = Stroke::new(1.0_f32, Color32::from_rgb(20, 24, 31));
    let spacing = 48.0;
    let mut x = rect.left();
    while x <= rect.right() {
        painter.line_segment(
            [Pos2::new(x, rect.top()), Pos2::new(x, rect.bottom())],
            stroke,
        );
        x += spacing;
    }
    let mut y = rect.top();
    while y <= rect.bottom() {
        painter.line_segment(
            [Pos2::new(rect.left(), y), Pos2::new(rect.right(), y)],
            stroke,
        );
        y += spacing;
    }
}

fn preview_color(color: screen_color::PreviewRgb) -> Color32 {
    let channel = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
    Color32::from_rgb(channel(color.r), channel(color.g), channel(color.b))
}

fn raster_image(raster: &PreparedRaster) -> egui::ColorImage {
    let pixels = raster
        .pixels
        .iter()
        .map(|pixel| {
            if pixel.on_panel {
                preview_color(pixel.rgb)
            } else {
                Color32::TRANSPARENT
            }
        })
        .collect();
    egui::ColorImage::new(
        [usize::from(raster.width), usize::from(raster.height)],
        pixels,
    )
}

fn view_name(view: DiagnosticView) -> &'static str {
    match view {
        DiagnosticView::Composite => "COMPOSITE · IDEAL CAMERA SAMPLE",
        DiagnosticView::DeviceSignal => "DEVICE SIGNAL · EXPLICIT RGB",
        DiagnosticView::Subpixels => "PANEL EMISSION · PHYSICAL SUBPIXELS",
        DiagnosticView::EmittedRadiance => "EMITTED RADIANCE · DISPLAY PREVIEW",
    }
}

fn configure_style(context: &egui::Context) {
    let mut style = (*context.style()).clone();
    style.visuals = egui::Visuals::dark();
    style.visuals.panel_fill = Color32::from_rgb(18, 21, 27);
    style.visuals.window_fill = Color32::from_rgb(20, 23, 29);
    style.visuals.selection.bg_fill = Color32::from_rgb(54, 111, 217);
    style.visuals.widgets.inactive.bg_fill = Color32::from_rgb(29, 33, 41);
    style.visuals.widgets.hovered.bg_fill = Color32::from_rgb(39, 45, 56);
    style.visuals.widgets.active.bg_fill = Color32::from_rgb(50, 93, 174);
    style.spacing.item_spacing = Vec2::new(8.0, 7.0);
    style.spacing.button_padding = Vec2::new(10.0, 6.0);
    context.set_style(style);
}

fn tag(ui: &mut egui::Ui, text: &str) {
    egui::Frame::new()
        .fill(Color32::from_rgb(32, 39, 50))
        .corner_radius(CornerRadius::same(4))
        .inner_margin(egui::Margin::symmetric(7, 3))
        .show(ui, |ui| {
            ui.label(
                RichText::new(text)
                    .size(10.0)
                    .strong()
                    .color(Color32::from_rgb(132, 175, 242)),
            );
        });
}

fn section(ui: &mut egui::Ui, title: &str, content: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::new()
        .fill(Color32::from_rgb(24, 28, 35))
        .corner_radius(CornerRadius::same(6))
        .stroke(Stroke::new(1.0_f32, Color32::from_rgb(42, 47, 57)))
        .inner_margin(egui::Margin::same(12))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(
                RichText::new(title)
                    .size(10.0)
                    .strong()
                    .color(Color32::from_rgb(126, 139, 159)),
            );
            ui.add_space(6.0);
            content(ui);
        });
}

fn property(ui: &mut egui::Ui, name: &str, value: &str) {
    ui.horizontal(|ui| {
        ui.label(label_text(name));
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.label(
                RichText::new(value)
                    .size(11.0)
                    .color(Color32::from_rgb(205, 212, 224)),
            );
        });
    });
}

fn slider(
    ui: &mut egui::Ui,
    name: &str,
    value: &mut f32,
    range: core::ops::RangeInclusive<f32>,
    suffix: &str,
) {
    ui.horizontal(|ui| {
        ui.label(label_text(name));
        ui.add_space(2.0);
        ui.add(
            egui::Slider::new(value, range)
                .suffix(suffix)
                .max_decimals(2),
        );
    });
}

fn label_text(text: &str) -> RichText {
    RichText::new(text)
        .size(11.0)
        .color(Color32::from_rgb(151, 160, 176))
}

fn view_button(
    ui: &mut egui::Ui,
    current: &mut DiagnosticView,
    value: DiagnosticView,
    label: &str,
) {
    let selected = *current == value;
    if ui
        .add_sized(
            [ui.available_width(), 26.0],
            egui::Button::new(RichText::new(label).size(11.0)).selected(selected),
        )
        .clicked()
    {
        *current = value;
    }
}
