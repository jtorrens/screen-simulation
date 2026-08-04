//! UI-independent immutable request preparation and current-pipeline orchestration.

#![forbid(unsafe_code)]

use core::fmt;
use screen_color::{ColorError, DiagnosticDisplayTransform, PreviewRgb, SourceToDeviceProcessor};
use screen_contracts::{DeviceRgb, LinearRgb, RationalTime, Vec2, Vec3};
use screen_geometry::{
    CameraSample, CameraTrack, GeometryError, PanelRegion, ProjectedScreen, panel_uv_at_viewport,
    project_scene_point, project_screen,
};
use screen_media::{AlphaInterpretation, AlphaPresence, DecodedFrame};
use screen_panel::{LcdProfile, PanelError};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RasterPlacement {
    Fit,
    FillCrop,
    Stretch,
    OneToOne,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceSignalRaster {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<DeviceRgb>,
}

impl DeviceSignalRaster {
    pub fn validate(&self) -> Result<(), ApplicationError> {
        if self.width == 0 || self.height == 0 {
            return Err(ApplicationError::EmptyDeviceSignalRaster);
        }
        let expected = u64::from(self.width) * u64::from(self.height);
        if self.pixels.len() as u64 != expected {
            return Err(ApplicationError::DeviceSignalPixelCountMismatch {
                expected,
                actual: self.pixels.len() as u64,
            });
        }
        Ok(())
    }

    fn sample_nearest(&self, uv: Vec2) -> DeviceRgb {
        let x = (uv.x * self.width as f32)
            .floor()
            .clamp(0.0, self.width.saturating_sub(1) as f32) as u32;
        let y = (uv.y * self.height as f32)
            .floor()
            .clamp(0.0, self.height.saturating_sub(1) as f32) as u32;
        self.pixels[(u64::from(y) * u64::from(self.width) + u64::from(x)) as usize]
    }
}

pub fn decoded_frame_to_device_signal(
    frame: &DecodedFrame,
    alpha_presence: AlphaPresence,
    alpha_interpretation: AlphaInterpretation,
    color_processor: &SourceToDeviceProcessor,
) -> Result<DeviceSignalRaster, ApplicationError> {
    let expected = frame.raster.pixel_count();
    if frame.pixels.len() as u64 != expected {
        return Err(ApplicationError::DecodedPixelCountMismatch {
            expected,
            actual: frame.pixels.len() as u64,
        });
    }
    if alpha_presence == AlphaPresence::Present && alpha_interpretation == AlphaInterpretation::Auto
    {
        return Err(ApplicationError::AlphaAssociationUnresolved);
    }
    let capacity = usize::try_from(expected)
        .map_err(|_| ApplicationError::DecodedPixelStorageTooLarge)?
        .checked_mul(4)
        .ok_or(ApplicationError::DecodedPixelStorageTooLarge)?;
    let mut transformed = Vec::with_capacity(capacity);
    for pixel in &frame.pixels {
        let [r, g, b, alpha] = match (alpha_presence, alpha_interpretation) {
            (AlphaPresence::Absent, _)
            | (AlphaPresence::Present, AlphaInterpretation::Straight) => {
                [pixel.r, pixel.g, pixel.b, pixel.a]
            }
            (AlphaPresence::Present, AlphaInterpretation::Premultiplied) if pixel.a == 0.0 => {
                [0.0, 0.0, 0.0, 0.0]
            }
            (AlphaPresence::Present, AlphaInterpretation::Premultiplied) => [
                pixel.r / pixel.a,
                pixel.g / pixel.a,
                pixel.b / pixel.a,
                pixel.a,
            ],
            (AlphaPresence::Present, AlphaInterpretation::Auto) => {
                unreachable!("unresolved alpha was rejected before color processing")
            }
        };
        transformed.extend_from_slice(&[r, g, b, alpha]);
    }
    color_processor
        .apply_rgba_buffer(&mut transformed)
        .map_err(ApplicationError::Color)?;
    let pixels = transformed
        .chunks_exact(4)
        .map(|pixel| {
            let association = if alpha_presence == AlphaPresence::Present {
                pixel[3]
            } else {
                1.0
            };
            DeviceRgb::new(
                pixel[0] * association,
                pixel[1] * association,
                pixel[2] * association,
            )
        })
        .collect();
    Ok(DeviceSignalRaster {
        width: frame.raster.width,
        height: frame.raster.height,
        pixels,
    })
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

#[derive(Clone, Debug, PartialEq)]
pub struct SimulationRequest {
    pub time: RationalTime,
    pub viewport_aspect: f32,
    pub panel: LcdProfile,
    pub camera: CameraTrack,
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
    request
        .camera
        .validate()
        .map_err(ApplicationError::Geometry)?;
    let camera = if let Some(region) = request.inspection {
        request
            .camera
            .fit_panel_region(
                request.time,
                region,
                panel.active_width,
                panel.active_height,
                request.viewport_aspect,
            )
            .map_err(ApplicationError::Geometry)?
    } else {
        request
            .camera
            .sample(request.time)
            .map_err(ApplicationError::Geometry)?
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
    prepare_raster_with_signal(request.clone(), width, height, &|uv| {
        diagnostic_signal(uv, request.time)
    })
}

pub fn prepare_raster_from_device_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    source: &DeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<PreparedRaster, ApplicationError> {
    source.validate()?;
    let source_raster = [source.width, source.height];
    let device_raster = [request.panel.native_width, request.panel.native_height];
    prepare_raster_with_signal(request, width, height, &|device_uv| {
        source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
            .map_or(DeviceRgb::BLACK, |source_uv| {
                source.sample_nearest(source_uv)
            })
    })
}

fn prepare_raster_with_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    signal_at: &dyn Fn(Vec2) -> DeviceRgb,
) -> Result<PreparedRaster, ApplicationError> {
    if width == 0 || height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let mut frame = prepare_frame(request.clone())?;
    frame.representative_signal = signal_at(Vec2 { x: 0.5, y: 0.5 });
    frame.representative_emission = request.panel.emitted_radiance(frame.representative_signal);
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
            let signal = signal_at(uv);
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
    let frame = prepare_frame(request.clone())?;
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplicationError {
    InvalidViewportAspect,
    EmptyPreviewRaster,
    InspectionMustStartOnPanel,
    ViewRayMissesPanel,
    EmptyDeviceSignalRaster,
    DeviceSignalPixelCountMismatch { expected: u64, actual: u64 },
    DecodedPixelCountMismatch { expected: u64, actual: u64 },
    DecodedPixelStorageTooLarge,
    AlphaAssociationUnresolved,
    Color(ColorError),
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
            Self::EmptyDeviceSignalRaster => {
                formatter.write_str("device signal raster must be non-empty")
            }
            Self::DeviceSignalPixelCountMismatch { expected, actual } => write!(
                formatter,
                "device signal raster has {actual} pixels but requires {expected}"
            ),
            Self::DecodedPixelCountMismatch { expected, actual } => write!(
                formatter,
                "decoded source has {actual} pixels but requires {expected}"
            ),
            Self::DecodedPixelStorageTooLarge => {
                formatter.write_str("decoded source is too large for RGBA color processing")
            }
            Self::AlphaAssociationUnresolved => formatter.write_str(
                "alpha metadata does not identify Straight or Premultiplied association",
            ),
            Self::Color(error) => write!(formatter, "invalid color transform: {error}"),
            Self::Panel(error) => write!(formatter, "invalid panel: {error}"),
            Self::Geometry(error) => write!(formatter, "invalid camera: {error}"),
        }
    }
}

impl std::error::Error for ApplicationError {}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_color::{ColorEngine, DeviceColorTarget, SourceColorInterpretation};
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
            camera: CameraTrack {
                keyframes: vec![screen_geometry::CameraKeyframe {
                    id: "camera-key-0".to_owned(),
                    time: RationalTime::new(0, 24).expect("valid time"),
                    position: Vec3 {
                        x: 0.0,
                        y: 0.0,
                        z: 0.8,
                    },
                    rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                    focal_length: Millimeters(50.0),
                    sensor_width: Millimeters(36.0),
                    interpolation: screen_geometry::KeyframeInterpolation::Smooth,
                }],
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
    fn alpha_association_is_resolved_before_panel_evaluation() {
        use screen_media::{DecodedRgba, RasterSize};

        let frame = DecodedFrame {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            timestamp: RationalTime::new(0, 24).expect("valid time"),
            pixels: vec![DecodedRgba {
                r: 0.8,
                g: 0.4,
                b: 0.2,
                a: 0.5,
            }],
        };
        let processor = ColorEngine::bundled()
            .expect("bundled color engine")
            .source_to_device_processor(
                SourceColorInterpretation::IdentityDeviceSignal,
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("identity processor");
        assert_eq!(
            decoded_frame_to_device_signal(
                &frame,
                AlphaPresence::Present,
                AlphaInterpretation::Auto,
                &processor,
            ),
            Err(ApplicationError::AlphaAssociationUnresolved)
        );
        let straight = decoded_frame_to_device_signal(
            &frame,
            AlphaPresence::Present,
            AlphaInterpretation::Straight,
            &processor,
        )
        .expect("explicit straight alpha");
        let premultiplied = decoded_frame_to_device_signal(
            &frame,
            AlphaPresence::Present,
            AlphaInterpretation::Premultiplied,
            &processor,
        )
        .expect("explicit premultiplied alpha");
        assert_eq!(straight.pixels[0], DeviceRgb::new(0.4, 0.2, 0.1));
        assert_eq!(premultiplied.pixels[0], DeviceRgb::new(0.8, 0.4, 0.2));
    }

    #[test]
    fn equivalent_straight_and_premultiplied_sources_match_after_ocio() {
        use screen_color::OcioInputTransform;
        use screen_media::{DecodedRgba, RasterSize};

        let make_frame = |rgb: [f32; 3]| DecodedFrame {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            timestamp: RationalTime::new(0, 24).expect("valid time"),
            pixels: vec![DecodedRgba {
                r: rgb[0],
                g: rgb[1],
                b: rgb[2],
                a: 0.5,
            }],
        };
        let processor = ColorEngine::bundled()
            .expect("bundled color engine")
            .source_to_device_processor(
                SourceColorInterpretation::Ocio(OcioInputTransform::ArriLogC4),
                DeviceColorTarget::SrgbDisplay,
            )
            .expect("LogC4 processor");
        let straight = decoded_frame_to_device_signal(
            &make_frame([0.4, 0.2, 0.1]),
            AlphaPresence::Present,
            AlphaInterpretation::Straight,
            &processor,
        )
        .expect("straight signal");
        let premultiplied = decoded_frame_to_device_signal(
            &make_frame([0.2, 0.1, 0.05]),
            AlphaPresence::Present,
            AlphaInterpretation::Premultiplied,
            &processor,
        )
        .expect("premultiplied signal");
        assert_eq!(straight, premultiplied);
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
        let yaw = 80.0_f32.to_radians();
        request.camera.keyframes[0].position = Vec3 {
            x: 0.8 * yaw.sin(),
            y: 0.0,
            z: 0.8 * yaw.cos(),
        };
        request.camera.keyframes[0].rotation = screen_geometry::Quaternion::from_yaw_degrees(80.0);
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
