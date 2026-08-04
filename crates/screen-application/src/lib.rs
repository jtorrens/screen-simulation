//! UI-independent immutable request preparation and current-pipeline orchestration.

#![forbid(unsafe_code)]

use core::fmt;
use screen_color::{DiagnosticDisplayTransform, PreviewRgb};
use screen_contracts::{DeviceRgb, LinearRgb, RationalTime, Vec2};
use screen_geometry::{CameraRig, GeometryError, ProjectedScreen, project_screen};
use screen_panel::{LcdProfile, PanelError};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnosticView {
    Composite,
    DeviceSignal,
    Subpixels,
    EmittedRadiance,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SimulationRequest {
    pub time: RationalTime,
    pub viewport_aspect: f32,
    pub panel: LcdProfile,
    pub camera: CameraRig,
    pub view: DiagnosticView,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedFrame {
    pub time: RationalTime,
    pub view: DiagnosticView,
    pub projected_screen: ProjectedScreen,
    pub native_raster: [u32; 2],
    pub active_size_meters: [f32; 2],
    pub pixel_pitch_meters: f32,
    pub pixels_per_inch: f32,
    pub representative_signal: DeviceRgb,
    pub representative_emission: LinearRgb,
    pub camera_yaw_degrees: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedVisualCell {
    pub corners: [Vec2; 4],
    pub preview: PreviewRgb,
    pub subpixels: [PreparedSubpixel; 3],
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedSubpixel {
    pub corners: [Vec2; 4],
    pub preview: PreviewRgb,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PreparedVisual {
    pub frame: PreparedFrame,
    pub columns: u16,
    pub rows: u16,
    pub cells: Vec<PreparedVisualCell>,
}

pub fn prepare_frame(request: SimulationRequest) -> Result<PreparedFrame, ApplicationError> {
    if request.viewport_aspect <= 0.0 {
        return Err(ApplicationError::InvalidViewportAspect);
    }
    let panel = request.panel.validate().map_err(ApplicationError::Panel)?;
    let camera = request
        .camera
        .validate()
        .map_err(ApplicationError::Geometry)?;
    let camera_sample = camera.sample(request.time);
    let projected_screen = project_screen(
        camera_sample,
        panel.active_width,
        panel.active_height,
        request.viewport_aspect,
    );
    let signal = diagnostic_signal(Vec2 { x: 0.5, y: 0.5 }, request.time);
    Ok(PreparedFrame {
        time: request.time,
        view: request.view,
        projected_screen,
        native_raster: [panel.native_width, panel.native_height],
        active_size_meters: [panel.active_width.0, panel.active_height.0],
        pixel_pitch_meters: panel.pixel_pitch_meters(),
        pixels_per_inch: panel.pixels_per_inch(),
        representative_signal: signal,
        representative_emission: panel.emitted_radiance(signal),
        camera_yaw_degrees: camera_sample.yaw_degrees,
    })
}

pub fn prepare_visual(
    request: SimulationRequest,
    columns: u16,
    rows: u16,
) -> Result<PreparedVisual, ApplicationError> {
    if columns == 0 || rows == 0 {
        return Err(ApplicationError::EmptyVisualGrid);
    }
    let frame = prepare_frame(request)?;
    let display = DiagnosticDisplayTransform {
        reference_white_nits: 100.0,
    };
    let mut cells = Vec::with_capacity(usize::from(columns) * usize::from(rows));
    for row in 0..rows {
        for column in 0..columns {
            let uv_min = Vec2 {
                x: f32::from(column) / f32::from(columns),
                y: f32::from(row) / f32::from(rows),
            };
            let uv_max = Vec2 {
                x: f32::from(column + 1) / f32::from(columns),
                y: f32::from(row + 1) / f32::from(rows),
            };
            let center = Vec2 {
                x: (uv_min.x + uv_max.x) * 0.5,
                y: (uv_min.y + uv_max.y) * 0.5,
            };
            let signal = diagnostic_signal(center, request.time);
            let emission = request.panel.emitted_radiance(signal);
            let preview = match request.view {
                DiagnosticView::DeviceSignal => PreviewRgb {
                    r: signal.r,
                    g: signal.g,
                    b: signal.b,
                },
                DiagnosticView::Composite
                | DiagnosticView::Subpixels
                | DiagnosticView::EmittedRadiance => display.scene_linear_to_srgb(emission),
            };
            let stripes = request.panel.subpixel_emission(signal).stripes;
            let corners = [
                interpolate_screen(frame.projected_screen, uv_min),
                interpolate_screen(
                    frame.projected_screen,
                    Vec2 {
                        x: uv_max.x,
                        y: uv_min.y,
                    },
                ),
                interpolate_screen(frame.projected_screen, uv_max),
                interpolate_screen(
                    frame.projected_screen,
                    Vec2 {
                        x: uv_min.x,
                        y: uv_max.y,
                    },
                ),
            ];
            let margin = request.panel.black_matrix_fraction * 0.5;
            let visible_width = 1.0 - request.panel.black_matrix_fraction;
            let stripe_width = visible_width / 3.0;
            let subpixels = core::array::from_fn(|index| {
                let x_min = margin + stripe_width * index as f32;
                let x_max = margin + stripe_width * (index + 1) as f32;
                PreparedSubpixel {
                    corners: sub_quad(corners, x_min, x_max, margin, 1.0 - margin),
                    preview: display.scene_linear_to_srgb(stripes[index]),
                }
            });
            cells.push(PreparedVisualCell {
                corners,
                preview,
                subpixels,
            });
        }
    }
    Ok(PreparedVisual {
        frame,
        columns,
        rows,
        cells,
    })
}

fn sub_quad(corners: [Vec2; 4], x_min: f32, x_max: f32, y_min: f32, y_max: f32) -> [Vec2; 4] {
    [
        interpolate_quad(corners, Vec2 { x: x_min, y: y_min }),
        interpolate_quad(corners, Vec2 { x: x_max, y: y_min }),
        interpolate_quad(corners, Vec2 { x: x_max, y: y_max }),
        interpolate_quad(corners, Vec2 { x: x_min, y: y_max }),
    ]
}

fn interpolate_quad(corners: [Vec2; 4], uv: Vec2) -> Vec2 {
    let top = Vec2 {
        x: corners[0].x + (corners[1].x - corners[0].x) * uv.x,
        y: corners[0].y + (corners[1].y - corners[0].y) * uv.x,
    };
    let bottom = Vec2 {
        x: corners[3].x + (corners[2].x - corners[3].x) * uv.x,
        y: corners[3].y + (corners[2].y - corners[3].y) * uv.x,
    };
    Vec2 {
        x: top.x + (bottom.x - top.x) * uv.y,
        y: top.y + (bottom.y - top.y) * uv.y,
    }
}

fn interpolate_screen(screen: ProjectedScreen, uv: Vec2) -> Vec2 {
    let top = Vec2 {
        x: screen.corners[0].x + (screen.corners[1].x - screen.corners[0].x) * uv.x,
        y: screen.corners[0].y + (screen.corners[1].y - screen.corners[0].y) * uv.x,
    };
    let bottom = Vec2 {
        x: screen.corners[3].x + (screen.corners[2].x - screen.corners[3].x) * uv.x,
        y: screen.corners[3].y + (screen.corners[2].y - screen.corners[3].y) * uv.x,
    };
    Vec2 {
        x: top.x + (bottom.x - top.x) * uv.y,
        y: top.y + (bottom.y - top.y) * uv.y,
    }
}

/// Current vertical-slice device signal. This is explicit authored diagnostic content,
/// not a media fallback and not reachable from media decoding.
pub fn diagnostic_signal(uv: Vec2, time: RationalTime) -> DeviceRgb {
    let pulse = (time.as_seconds() as f32 * 0.8).sin() * 0.5 + 0.5;
    let grid_x = (uv.x * 12.0).floor() as i32;
    let grid_y = (uv.y * 8.0).floor() as i32;
    let checker = if (grid_x + grid_y) % 2 == 0 {
        0.18
    } else {
        0.06
    };
    let glow = (1.0 - ((uv.x - 0.5).hypot(uv.y - 0.5) * 1.8)).max(0.0);
    DeviceRgb::new(
        checker + glow * (0.45 + pulse * 0.25),
        checker + glow * (0.18 + (1.0 - pulse) * 0.18),
        checker + glow * 0.75,
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApplicationError {
    InvalidViewportAspect,
    EmptyVisualGrid,
    Panel(PanelError),
    Geometry(GeometryError),
}

impl fmt::Display for ApplicationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidViewportAspect => formatter.write_str("viewport aspect must be positive"),
            Self::EmptyVisualGrid => formatter.write_str("visual grid must be non-empty"),
            Self::Panel(error) => write!(formatter, "invalid panel: {error}"),
            Self::Geometry(error) => write!(formatter, "invalid camera: {error}"),
        }
    }
}

impl std::error::Error for ApplicationError {}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_contracts::{Meters, Millimeters};
    use screen_panel::StripeLayout;

    fn request() -> SimulationRequest {
        SimulationRequest {
            time: RationalTime::new(24, 24).expect("valid time"),
            viewport_aspect: 16.0 / 9.0,
            panel: LcdProfile {
                native_width: 1920,
                native_height: 1080,
                active_width: Meters(0.531),
                active_height: Meters(0.299),
                stripe_layout: StripeLayout::Rgb,
                black_matrix_fraction: 0.1,
                eotf_gamma: 2.2,
                black_level_nits: 0.05,
                white_level_nits: 500.0,
                channel_efficiency: LinearRgb::new(1.0, 0.95, 0.9),
            },
            camera: CameraRig {
                distance: Meters(0.8),
                focal_length: Millimeters(50.0),
                sensor_width: Millimeters(36.0),
                orbit_amplitude_degrees: 15.0,
                orbit_duration: RationalTime::new(96, 24).expect("valid duration"),
            },
            view: DiagnosticView::Composite,
        }
    }

    #[test]
    fn prepares_one_immutable_cross_domain_result() {
        let frame = prepare_frame(request()).expect("valid request");
        assert_eq!(frame.native_raster, [1920, 1080]);
        assert!(frame.pixels_per_inch > 90.0);
        assert!(frame.projected_screen.facing_ratio > 0.9);
        assert!(frame.representative_emission.b > frame.representative_emission.g);
    }

    #[test]
    fn invalid_panel_fails_at_request_boundary() {
        let mut invalid = request();
        invalid.panel.native_width = 0;
        assert_eq!(
            prepare_frame(invalid),
            Err(ApplicationError::Panel(PanelError::EmptyNativeRaster))
        );
    }

    #[test]
    fn prepared_visual_contains_only_resolved_cells() {
        let visual = prepare_visual(request(), 12, 8).expect("valid visual request");
        assert_eq!(visual.cells.len(), 96);
        assert!(visual.cells.iter().all(|cell| cell.preview.r.is_finite()));
    }
}
