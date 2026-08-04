//! UI-independent immutable request preparation and current-pipeline orchestration.

#![forbid(unsafe_code)]

use core::fmt;
use screen_color::{DiagnosticDisplayTransform, PreviewRgb};
use screen_contracts::{DeviceRgb, LinearRgb, RationalTime, Vec2, Vec3};
use screen_geometry::{
    CameraRig, CameraSample, GeometryError, PanelRegion, ProjectedScreen, panel_uv_at_viewport,
    project_scene_point, project_screen,
};
use screen_panel::{LcdProfile, PanelError};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RasterPlacement {
    Fit,
    FillCrop,
    Stretch,
    OneToOne,
}

/// Maps a device-native sample position to source UV. `None` is authored empty area,
/// not a substitute sample or decoder fallback.
pub fn source_uv_for_device_uv(
    source_raster: [u32; 2],
    device_raster: [u32; 2],
    placement: RasterPlacement,
    device_uv: Vec2,
) -> Option<Vec2> {
    if source_raster.contains(&0) || device_raster.contains(&0) {
        return None;
    }
    let source_aspect = source_raster[0] as f32 / source_raster[1] as f32;
    let device_aspect = device_raster[0] as f32 / device_raster[1] as f32;
    let centered = |scale_x: f32, scale_y: f32| Vec2 {
        x: (device_uv.x - 0.5) * scale_x + 0.5,
        y: (device_uv.y - 0.5) * scale_y + 0.5,
    };
    let source_uv = match placement {
        RasterPlacement::Stretch => device_uv,
        RasterPlacement::Fit if source_aspect > device_aspect => {
            centered(1.0, source_aspect / device_aspect)
        }
        RasterPlacement::Fit => centered(device_aspect / source_aspect, 1.0),
        RasterPlacement::FillCrop if source_aspect > device_aspect => {
            centered(device_aspect / source_aspect, 1.0)
        }
        RasterPlacement::FillCrop => centered(1.0, source_aspect / device_aspect),
        RasterPlacement::OneToOne => centered(
            device_raster[0] as f32 / source_raster[0] as f32,
            device_raster[1] as f32 / source_raster[1] as f32,
        ),
    };
    ((0.0..=1.0).contains(&source_uv.x) && (0.0..=1.0).contains(&source_uv.y)).then_some(source_uv)
}

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
    pub inspection: Option<PanelRegion>,
    pub view: DiagnosticView,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedFrame {
    pub time: RationalTime,
    pub view: DiagnosticView,
    pub viewport_aspect: f32,
    pub camera: CameraSample,
    pub inspection: Option<PanelRegion>,
    pub projected_screen: Option<ProjectedScreen>,
    pub native_raster: [u32; 2],
    pub active_size_meters: [f32; 2],
    pub pixel_pitch_meters: f32,
    pub pixels_per_inch: f32,
    pub representative_signal: DeviceRgb,
    pub representative_emission: LinearRgb,
    pub camera_yaw_degrees: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreviewPixel {
    pub rgb: PreviewRgb,
    pub on_panel: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PreparedRaster {
    pub frame: PreparedFrame,
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<PreviewPixel>,
    pub preview_scale_percent: f32,
    pub inspection_field_meters: Option<[f32; 2]>,
    pub subpixels_resolved_at_center: bool,
}

pub fn prepare_frame(request: SimulationRequest) -> Result<PreparedFrame, ApplicationError> {
    if request.viewport_aspect <= 0.0 {
        return Err(ApplicationError::InvalidViewportAspect);
    }
    let panel = request.panel.validate().map_err(ApplicationError::Panel)?;
    let camera_rig = request
        .camera
        .validate()
        .map_err(ApplicationError::Geometry)?;
    let camera = if let Some(region) = request.inspection {
        camera_rig
            .fit_panel_region(
                request.time,
                region,
                panel.active_width,
                panel.active_height,
                request.viewport_aspect,
            )
            .map_err(ApplicationError::Geometry)?
    } else {
        camera_rig.sample(request.time)
    };
    let projected_screen = project_screen(
        camera,
        panel.active_width,
        panel.active_height,
        request.viewport_aspect,
    );
    let signal = diagnostic_signal(Vec2 { x: 0.5, y: 0.5 }, request.time);
    Ok(PreparedFrame {
        time: request.time,
        view: request.view,
        viewport_aspect: request.viewport_aspect,
        camera,
        inspection: request.inspection,
        projected_screen,
        native_raster: [panel.native_width, panel.native_height],
        active_size_meters: [panel.active_width.0, panel.active_height.0],
        pixel_pitch_meters: panel.pixel_pitch_meters(),
        pixels_per_inch: panel.pixels_per_inch(),
        representative_signal: signal,
        representative_emission: panel.emitted_radiance(signal),
        camera_yaw_degrees: camera.yaw_degrees,
    })
}

pub fn prepare_raster(
    request: SimulationRequest,
    width: u16,
    height: u16,
) -> Result<PreparedRaster, ApplicationError> {
    if width == 0 || height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let frame = prepare_frame(request)?;
    let display = DiagnosticDisplayTransform {
        reference_white_nits: 100.0,
    };
    let preview_scale_percent = projected_device_pixel_width(&frame, request.panel, width)
        .ok_or(ApplicationError::ViewRayMissesPanel)?
        * 100.0;
    let subpixels_resolved_at_center = preview_scale_percent >= 300.0;
    let mut pixels = Vec::with_capacity(usize::from(width) * usize::from(height));
    for row in 0..height {
        for column in 0..width {
            let viewport_ndc = Vec2 {
                x: (f32::from(column) + 0.5) / f32::from(width) * 2.0 - 1.0,
                y: (f32::from(row) + 0.5) / f32::from(height) * 2.0 - 1.0,
            };
            let Some(uv) = panel_uv_at_viewport(
                frame.camera,
                request.panel.active_width,
                request.panel.active_height,
                request.viewport_aspect,
                viewport_ndc,
            ) else {
                pixels.push(outside_panel());
                continue;
            };
            if !(0.0..=1.0).contains(&uv.x) || !(0.0..=1.0).contains(&uv.y) {
                pixels.push(outside_panel());
                continue;
            }
            let signal = diagnostic_signal(uv, request.time);
            let preview = match request.view {
                DiagnosticView::DeviceSignal => PreviewRgb {
                    r: signal.r,
                    g: signal.g,
                    b: signal.b,
                },
                DiagnosticView::Composite | DiagnosticView::EmittedRadiance => {
                    display.scene_linear_to_srgb(request.panel.emitted_radiance(signal))
                }
                DiagnosticView::Subpixels if subpixels_resolved_at_center => {
                    let pixel_uv = Vec2 {
                        x: (uv.x * request.panel.native_width as f32).fract(),
                        y: (uv.y * request.panel.native_height as f32).fract(),
                    };
                    display.scene_linear_to_srgb(request.panel.emission_at_pixel(signal, pixel_uv))
                }
                DiagnosticView::Subpixels => {
                    display.scene_linear_to_srgb(request.panel.emitted_radiance(signal))
                }
            };
            pixels.push(PreviewPixel {
                rgb: preview,
                on_panel: true,
            });
        }
    }
    let inspection_field_meters = request.inspection.map(|region| {
        [
            (region.max.x - region.min.x) * request.panel.active_width.0,
            (region.max.y - region.min.y) * request.panel.active_height.0,
        ]
    });
    Ok(PreparedRaster {
        frame,
        width,
        height,
        pixels,
        preview_scale_percent,
        inspection_field_meters,
        subpixels_resolved_at_center,
    })
}

pub fn inspection_region_from_drag(
    request: SimulationRequest,
    start_ndc: Vec2,
    end_ndc: Vec2,
) -> Result<PanelRegion, ApplicationError> {
    let frame = prepare_frame(request)?;
    let intersect = |point| {
        panel_uv_at_viewport(
            frame.camera,
            request.panel.active_width,
            request.panel.active_height,
            request.viewport_aspect,
            point,
        )
        .ok_or(ApplicationError::ViewRayMissesPanel)
    };
    let start = intersect(start_ndc)?;
    if !(0.0..=1.0).contains(&start.x) || !(0.0..=1.0).contains(&start.y) {
        return Err(ApplicationError::InspectionMustStartOnPanel);
    }
    let end = intersect(end_ndc)?;
    let region = PanelRegion {
        min: Vec2 {
            x: start.x.min(end.x),
            y: start.y.min(end.y),
        },
        max: Vec2 {
            x: start.x.max(end.x),
            y: start.y.max(end.y),
        },
    };
    region.validate().map_err(ApplicationError::Geometry)
}

fn projected_device_pixel_width(
    frame: &PreparedFrame,
    panel: LcdProfile,
    preview_width: u16,
) -> Option<f32> {
    let center_uv = frame
        .inspection
        .map_or(Vec2 { x: 0.5, y: 0.5 }, |region| Vec2 {
            x: (region.min.x + region.max.x) * 0.5,
            y: (region.min.y + region.max.y) * 0.5,
        });
    let point = |uv: Vec2| Vec3 {
        x: (uv.x - 0.5) * panel.active_width.0,
        y: (0.5 - uv.y) * panel.active_height.0,
        z: 0.0,
    };
    let first = project_scene_point(frame.camera, point(center_uv), frame.viewport_aspect)?;
    let second = project_scene_point(
        frame.camera,
        point(Vec2 {
            x: center_uv.x + 1.0 / panel.native_width as f32,
            y: center_uv.y,
        }),
        frame.viewport_aspect,
    )?;
    Some((second.x - first.x).hypot(second.y - first.y) * f32::from(preview_width) * 0.5)
}

fn outside_panel() -> PreviewPixel {
    PreviewPixel {
        rgb: PreviewRgb {
            r: 0.0,
            g: 0.0,
            b: 0.0,
        },
        on_panel: false,
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
    EmptyPreviewRaster,
    InspectionMustStartOnPanel,
    ViewRayMissesPanel,
    Panel(PanelError),
    Geometry(GeometryError),
}

impl fmt::Display for ApplicationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidViewportAspect => formatter.write_str("viewport aspect must be positive"),
            Self::EmptyPreviewRaster => formatter.write_str("preview raster must be non-empty"),
            Self::InspectionMustStartOnPanel => {
                formatter.write_str("inspection selection must start on the panel")
            }
            Self::ViewRayMissesPanel => {
                formatter.write_str("camera ray does not reach the panel plane")
            }
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
            inspection: None,
            view: DiagnosticView::Composite,
        }
    }

    #[test]
    fn prepares_one_immutable_cross_domain_result() {
        let frame = prepare_frame(request()).expect("valid request");
        assert_eq!(frame.native_raster, [1920, 1080]);
        assert!(frame.pixels_per_inch > 90.0);
        assert!(
            frame
                .projected_screen
                .is_some_and(|screen| screen.facing_ratio > 0.9)
        );
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
    fn fit_subpixel_view_integrates_unresolved_device_pixels() {
        let mut request = request();
        request.view = DiagnosticView::Subpixels;
        let raster = prepare_raster(request, 320, 180).expect("valid raster");
        assert!(!raster.subpixels_resolved_at_center);
        assert!(raster.pixels.iter().any(|pixel| pixel.on_panel));
    }

    #[test]
    fn raster_placement_is_explicit_and_deterministic() {
        let center = Vec2 { x: 0.5, y: 0.5 };
        assert_eq!(
            source_uv_for_device_uv(
                [1920, 1080],
                [3840, 2160],
                RasterPlacement::OneToOne,
                center
            ),
            Some(center)
        );
        assert_eq!(
            source_uv_for_device_uv(
                [1920, 1080],
                [3840, 2160],
                RasterPlacement::OneToOne,
                Vec2 { x: 0.1, y: 0.5 }
            ),
            None
        );
        assert!(
            source_uv_for_device_uv(
                [1080, 1080],
                [1920, 1080],
                RasterPlacement::Fit,
                Vec2 { x: 0.05, y: 0.5 }
            )
            .is_none()
        );
        assert!(
            source_uv_for_device_uv(
                [1080, 1080],
                [1920, 1080],
                RasterPlacement::FillCrop,
                Vec2 { x: 0.05, y: 0.5 }
            )
            .is_some()
        );
    }

    #[test]
    fn inspection_camera_resolves_physical_subpixels() {
        let mut request = request();
        request.view = DiagnosticView::Subpixels;
        request.inspection = Some(PanelRegion {
            min: Vec2 { x: 0.499, y: 0.499 },
            max: Vec2 { x: 0.501, y: 0.501 },
        });
        let raster = prepare_raster(request, 320, 180).expect("valid inspection raster");
        assert!(raster.subpixels_resolved_at_center);
        assert!(raster.inspection_field_meters.is_some());
    }

    #[test]
    fn deep_oblique_inspection_does_not_require_the_full_panel_outline() {
        let mut request = request();
        request.time = RationalTime::new(48, 24).expect("valid time");
        request.inspection = Some(PanelRegion {
            min: Vec2 { x: 0.499, y: 0.499 },
            max: Vec2 { x: 0.501, y: 0.501 },
        });
        let raster = prepare_raster(request, 320, 180).expect("valid deep inspection raster");
        assert!(raster.frame.projected_screen.is_none());
        assert!(raster.pixels.iter().any(|pixel| pixel.on_panel));
    }

    #[test]
    fn inspection_drag_maps_back_to_panel_coordinates() {
        let region = inspection_region_from_drag(
            request(),
            Vec2 { x: -0.1, y: -0.1 },
            Vec2 { x: 0.1, y: 0.1 },
        )
        .expect("selection starts on panel");
        assert!(region.min.x < 0.5);
        assert!(region.max.x > 0.5);
    }
}
