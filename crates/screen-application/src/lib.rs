//! UI-independent immutable request preparation and current-pipeline orchestration.

#![forbid(unsafe_code)]

use core::fmt;
use rayon::prelude::*;
use screen_camera::{
    CameraDevelopment, CameraDevelopmentError, DevelopedCameraRaster, develop_raw_to_acescg,
};
use screen_color::{ColorError, DiagnosticDisplayTransform, PreviewRgb, SourceToDeviceProcessor};
use screen_contracts::{ContractError, DeviceRgb, FrameRate, LinearRgb, RationalTime, Vec2, Vec3};
use screen_geometry::{
    APERTURE_SAMPLE_COUNT, CameraRig, CameraSample, GeometryError, OpticalSample, PanelRegion,
    ProjectedScreen, ScreenSample, ScreenTrack, panel_uv_aperture_samples, panel_uv_at_viewport,
    project_scene_point, project_screen,
};
use screen_media::{AlphaInterpretation, AlphaPresence, DecodedFrame};
use screen_panel::{LcdProfile, PanelError, PanelTemporalEmission, ValidatedPanelEvaluator};
use screen_sensor::{
    CaptureIdentity, IntegratedOpticalExposure, RawSensorRaster, SensorError, SensorProfile,
    expose_raw,
};
use std::sync::Arc;

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

#[derive(Clone, Debug)]
pub struct PreparedDeviceSignalRaster {
    source: DeviceSignalRaster,
    integral: DeviceSignalIntegral,
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
        if self
            .pixels
            .iter()
            .any(|pixel| !pixel.r.is_finite() || !pixel.g.is_finite() || !pixel.b.is_finite())
        {
            return Err(ApplicationError::NonFiniteDeviceSignal);
        }
        Ok(())
    }

    fn sample_native_pixel(&self, uv: Vec2) -> DeviceRgb {
        let x = (uv.x * self.width as f32)
            .floor()
            .clamp(0.0, self.width.saturating_sub(1) as f32) as u32;
        let y = (uv.y * self.height as f32)
            .floor()
            .clamp(0.0, self.height.saturating_sub(1) as f32) as u32;
        self.pixels[(u64::from(y) * u64::from(self.width) + u64::from(x)) as usize]
    }
}

impl PreparedDeviceSignalRaster {
    pub fn new(source: DeviceSignalRaster) -> Result<Self, ApplicationError> {
        source.validate()?;
        let integral = DeviceSignalIntegral::new(&source);
        Ok(Self { source, integral })
    }

    pub fn raster_size(&self) -> [u32; 2] {
        [self.source.width, self.source.height]
    }
}

#[derive(Clone, Debug)]
struct DeviceSignalIntegral {
    width: u32,
    height: u32,
    prefix: Vec<IntegralRgb>,
}

#[derive(Clone, Copy, Debug, Default)]
struct IntegralRgb {
    r: f64,
    g: f64,
    b: f64,
}

impl DeviceSignalIntegral {
    fn new(source: &DeviceSignalRaster) -> Self {
        let stride = source.width as usize + 1;
        let mut prefix = vec![IntegralRgb::default(); stride * (source.height as usize + 1)];
        for row in 0..source.height as usize {
            let mut row_sum = IntegralRgb::default();
            for column in 0..source.width as usize {
                let pixel = source.pixels[row * source.width as usize + column];
                row_sum.r += f64::from(pixel.r);
                row_sum.g += f64::from(pixel.g);
                row_sum.b += f64::from(pixel.b);
                let above = prefix[row * stride + column + 1];
                prefix[(row + 1) * stride + column + 1] = IntegralRgb {
                    r: above.r + row_sum.r,
                    g: above.g + row_sum.g,
                    b: above.b + row_sum.b,
                };
            }
        }
        Self {
            width: source.width,
            height: source.height,
            prefix,
        }
    }

    fn prefix_at(&self, column: usize, row: usize) -> IntegralRgb {
        self.prefix[row * (self.width as usize + 1) + column]
    }

    fn integer_sum(&self, x0: usize, y0: usize, x1: usize, y1: usize) -> IntegralRgb {
        let a = self.prefix_at(x0, y0);
        let b = self.prefix_at(x1, y0);
        let c = self.prefix_at(x0, y1);
        let d = self.prefix_at(x1, y1);
        IntegralRgb {
            r: d.r - b.r - c.r + a.r,
            g: d.g - b.g - c.g + a.g,
            b: d.b - b.b - c.b + a.b,
        }
    }

    fn integral_to(&self, x: f32, y: f32) -> IntegralRgb {
        let x = x.clamp(0.0, self.width as f32);
        let y = y.clamp(0.0, self.height as f32);
        let integer_x = x.floor() as usize;
        let integer_y = y.floor() as usize;
        let fraction_x = if integer_x < self.width as usize {
            x - integer_x as f32
        } else {
            0.0
        };
        let fraction_y = if integer_y < self.height as usize {
            y - integer_y as f32
        } else {
            0.0
        };
        let mut sum = self.prefix_at(integer_x, integer_y);
        if fraction_x > 0.0 {
            let column = self.integer_sum(integer_x, 0, integer_x + 1, integer_y);
            sum.r += column.r * f64::from(fraction_x);
            sum.g += column.g * f64::from(fraction_x);
            sum.b += column.b * f64::from(fraction_x);
        }
        if fraction_y > 0.0 {
            let row = self.integer_sum(0, integer_y, integer_x, integer_y + 1);
            sum.r += row.r * f64::from(fraction_y);
            sum.g += row.g * f64::from(fraction_y);
            sum.b += row.b * f64::from(fraction_y);
        }
        if fraction_x > 0.0 && fraction_y > 0.0 {
            let pixel = self.integer_sum(integer_x, integer_y, integer_x + 1, integer_y + 1);
            let weight = f64::from(fraction_x) * f64::from(fraction_y);
            sum.r += pixel.r * weight;
            sum.g += pixel.g * weight;
            sum.b += pixel.b * weight;
        }
        sum
    }

    fn sample_area_box(&self, minimum: Vec2, maximum: Vec2) -> DeviceRgb {
        let x0 = minimum.x.min(maximum.x) * self.width as f32;
        let x1 = minimum.x.max(maximum.x) * self.width as f32;
        let y0 = minimum.y.min(maximum.y) * self.height as f32;
        let y1 = minimum.y.max(maximum.y) * self.height as f32;
        let full_area = (x1 - x0).max(1.0e-8) * (y1 - y0).max(1.0e-8);
        let lower = self.integral_to(x0, y0);
        let upper_x = self.integral_to(x1, y0);
        let upper_y = self.integral_to(x0, y1);
        let upper = self.integral_to(x1, y1);
        let sum = IntegralRgb {
            r: upper.r - upper_x.r - upper_y.r + lower.r,
            g: upper.g - upper_x.g - upper_y.g + lower.g,
            b: upper.b - upper_x.b - upper_y.b + lower.b,
        };
        let full_area = f64::from(full_area);
        DeviceRgb::new(
            (sum.r / full_area) as f32,
            (sum.g / full_area) as f32,
            (sum.b / full_area) as f32,
        )
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
    let source_uv = source_uv_unbounded(source_raster, device_raster, placement, device_uv)?;
    ((0.0..=1.0).contains(&source_uv.x) && (0.0..=1.0).contains(&source_uv.y)).then_some(source_uv)
}

fn source_uv_unbounded(
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
    Some(match placement {
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
    })
}

fn sample_placed_area(
    source: &DeviceSignalIntegral,
    source_raster: [u32; 2],
    device_raster: [u32; 2],
    placement: RasterPlacement,
    minimum: Vec2,
    maximum: Vec2,
) -> DeviceRgb {
    let Some(first) = source_uv_unbounded(source_raster, device_raster, placement, minimum) else {
        return DeviceRgb::BLACK;
    };
    let Some(second) = source_uv_unbounded(source_raster, device_raster, placement, maximum) else {
        return DeviceRgb::BLACK;
    };
    source.sample_area_box(first, second)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnosticView {
    Composite,
    DeviceSignal,
    Subpixels,
    EmittedRadiance,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OpticalRequest {
    pub time: RationalTime,
    pub viewport_aspect: f32,
    pub panel: LcdProfile,
    pub camera: CameraRig,
    pub screen: ScreenTrack,
    pub inspection: Option<PanelRegion>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShutterRequest {
    pub optics: OpticalRequest,
    pub duration: RationalTime,
    pub temporal_samples: u16,
    pub readout: SensorReadout,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FrameCaptureRequest {
    pub optics: OpticalRequest,
    pub frame_rate: FrameRate,
    pub frame_index: i64,
    pub duration: RationalTime,
    pub temporal_samples: u16,
    pub readout: SensorReadout,
    pub noise_seed: u64,
}

impl FrameCaptureRequest {
    fn resolve(self) -> Result<(ShutterRequest, CaptureIdentity), ApplicationError> {
        let mut optics = self.optics;
        optics.time = self
            .frame_rate
            .time_at_frame(self.frame_index)
            .map_err(ApplicationError::Time)?;
        Ok((
            ShutterRequest {
                optics,
                duration: self.duration,
                temporal_samples: self.temporal_samples,
                readout: self.readout,
            },
            CaptureIdentity {
                noise_seed: self.noise_seed,
                frame_index: self.frame_index,
            },
        ))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SensorReadout {
    Global,
    Rolling {
        duration: RationalTime,
        direction: RollingDirection,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RollingDirection {
    TopToBottom,
    BottomToTop,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SimulationRequest {
    pub optics: OpticalRequest,
    pub view: DiagnosticView,
    pub preview_exposure_ev: f32,
}

impl SimulationRequest {
    pub fn optical_request(&self) -> OpticalRequest {
        self.optics.clone()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedFrame {
    pub time: RationalTime,
    pub viewport_aspect: f32,
    pub camera: CameraSample,
    pub screen: ScreenSample,
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

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LinearOpticalPixel {
    pub acescg_irradiance: LinearRgb,
    pub on_panel: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LinearOpticalRaster {
    pub frame: PreparedFrame,
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<LinearOpticalPixel>,
    pub projected_device_pixel_percent: f32,
    pub inspection_field_meters: Option<[f32; 2]>,
    pub subpixels_resolved_at_center: bool,
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

pub fn prepare_frame(request: OpticalRequest) -> Result<PreparedFrame, ApplicationError> {
    if !request.viewport_aspect.is_finite() || request.viewport_aspect <= 0.0 {
        return Err(ApplicationError::InvalidViewportAspect);
    }
    let panel = request.panel.validate().map_err(ApplicationError::Panel)?;
    request
        .camera
        .validate()
        .map_err(ApplicationError::Geometry)?;
    request
        .screen
        .validate()
        .map_err(ApplicationError::Geometry)?;
    let screen = request
        .screen
        .sample(request.time)
        .map_err(ApplicationError::Geometry)?;
    let camera = if let Some(region) = request.inspection {
        request
            .camera
            .fit_panel_region(
                request.time,
                region,
                panel.active_width,
                panel.active_height,
                screen,
                request.viewport_aspect,
            )
            .map_err(ApplicationError::Geometry)?
    } else {
        request
            .camera
            .sample(request.time)
            .map_err(ApplicationError::Geometry)?
    };
    let sensor_aspect = camera.sensor_width.0 / camera.sensor_height.0;
    if (sensor_aspect - request.viewport_aspect).abs() > 1.0e-4 {
        return Err(ApplicationError::SensorViewportAspectMismatch {
            sensor_aspect,
            viewport_aspect: request.viewport_aspect,
        });
    }
    let projected_screen = project_screen(
        camera,
        screen,
        panel.active_width,
        panel.active_height,
        request.viewport_aspect,
    );
    let signal = diagnostic_signal(Vec2 { x: 0.5, y: 0.5 }, request.time);
    Ok(PreparedFrame {
        time: request.time,
        viewport_aspect: request.viewport_aspect,
        camera,
        screen,
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
    prepare_raster_with_signal(
        request.clone(),
        width,
        height,
        &|uv| diagnostic_signal(uv, request.optics.time),
        &|minimum, maximum| diagnostic_area_signal(minimum, maximum, request.optics.time),
    )
}

pub fn evaluate_linear_optics(
    request: OpticalRequest,
    width: u16,
    height: u16,
) -> Result<LinearOpticalRaster, ApplicationError> {
    evaluate_optical_raster_with_signal(
        request.clone(),
        width,
        height,
        DiagnosticView::Composite,
        &|uv| diagnostic_signal(uv, request.time),
        &|minimum, maximum| diagnostic_area_signal(minimum, maximum, request.time),
    )
}

pub fn integrate_procedural_shutter(
    request: ShutterRequest,
    width: u16,
    height: u16,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    match request.readout {
        SensorReadout::Global => integrate_global_shutter(request, width, height, |optics| {
            evaluate_linear_optics(optics, width, height)
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_shutter(
            request,
            width,
            height,
            duration,
            direction,
            |optics, row| evaluate_procedural_optical_row(optics, width, height, row),
        ),
    }
}

pub fn capture_procedural_frame(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
) -> Result<RawSensorRaster, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let (shutter, identity) = request.resolve()?;
    let exposure =
        integrate_procedural_shutter(shutter, sensor.native_width, sensor.native_height)?;
    expose_raw(sensor, &exposure, identity).map_err(ApplicationError::Sensor)
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapturedCameraFrame {
    pub raw: RawSensorRaster,
    pub developed: DevelopedCameraRaster,
}

pub fn capture_and_develop_procedural_frame(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
) -> Result<CapturedCameraFrame, ApplicationError> {
    let raw = capture_procedural_frame(request, sensor)?;
    let developed = develop_raw_to_acescg(&raw, sensor, development)
        .map_err(ApplicationError::CameraDevelopment)?;
    Ok(CapturedCameraFrame { raw, developed })
}

pub fn integrate_shutter_from_device_signal_sequence<F>(
    request: ShutterRequest,
    width: u16,
    height: u16,
    placement: RasterPlacement,
    mut signal_at_time: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    match request.readout {
        SensorReadout::Global => integrate_global_shutter(request, width, height, |optics| {
            let signal = signal_at_time(optics.time)?;
            evaluate_linear_optics_from_prepared_device_signal(
                optics, width, height, &signal, placement,
            )
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_shutter(
            request,
            width,
            height,
            duration,
            direction,
            |optics, row| {
                let signal = signal_at_time(optics.time)?;
                evaluate_optical_row_from_prepared_device_signal(
                    optics, width, height, row, &signal, placement,
                )
            },
        ),
    }
}

pub fn capture_frame_from_device_signal_sequence<F>(
    request: FrameCaptureRequest,
    placement: RasterPlacement,
    signal_at_time: F,
    sensor: SensorProfile,
) -> Result<RawSensorRaster, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_shutter_from_device_signal_sequence(
        shutter,
        sensor.native_width,
        sensor.native_height,
        placement,
        signal_at_time,
    )?;
    expose_raw(sensor, &exposure, identity).map_err(ApplicationError::Sensor)
}

pub fn capture_and_develop_frame_from_device_signal_sequence<F>(
    request: FrameCaptureRequest,
    placement: RasterPlacement,
    signal_at_time: F,
    sensor: SensorProfile,
    development: CameraDevelopment,
) -> Result<CapturedCameraFrame, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    let raw =
        capture_frame_from_device_signal_sequence(request, placement, signal_at_time, sensor)?;
    let developed = develop_raw_to_acescg(&raw, sensor, development)
        .map_err(ApplicationError::CameraDevelopment)?;
    Ok(CapturedCameraFrame { raw, developed })
}

fn integrate_global_shutter<F>(
    request: ShutterRequest,
    width: u16,
    height: u16,
    mut optical_at_time: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    F: FnMut(OpticalRequest) -> Result<LinearOpticalRaster, ApplicationError>,
{
    if request.readout != SensorReadout::Global {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let samples = shutter_quadrature(
        request.optics.time,
        request.duration,
        request.temporal_samples,
        request.optics.panel.temporal_emission,
    )?;
    if width == 0 || height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let pixel_count = usize::from(width) * usize::from(height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for sample in samples {
        let mut optics = request.optics.clone();
        optics.time = sample.time;
        let raster = optical_at_time(optics)?;
        if raster.width != width || raster.height != height || raster.pixels.len() != pixel_count {
            return Err(ApplicationError::OpticalSampleRasterMismatch);
        }
        for (sum, pixel) in accumulated.iter_mut().zip(raster.pixels) {
            sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
            sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
            sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
        }
    }
    finish_integrated_exposure(width, height, request.duration, accumulated)
}

fn finish_integrated_exposure(
    width: u16,
    height: u16,
    duration: RationalTime,
    accumulated: Vec<[f64; 3]>,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    let duration_seconds = duration.as_seconds();
    let acescg_irradiance_seconds = accumulated
        .into_iter()
        .map(|sum| LinearRgb::new(sum[0] as f32, sum[1] as f32, sum[2] as f32))
        .collect();
    let exposure = IntegratedOpticalExposure {
        width: u32::from(width),
        height: u32::from(height),
        duration_seconds: duration_seconds as f32,
        acescg_irradiance_seconds,
    };
    exposure.validate().map_err(ApplicationError::Sensor)?;
    Ok(exposure)
}

#[allow(clippy::too_many_arguments)]
fn integrate_rolling_shutter<F>(
    request: ShutterRequest,
    width: u16,
    height: u16,
    readout_duration: RationalTime,
    direction: RollingDirection,
    mut optical_row_at_time: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    F: FnMut(OpticalRequest, usize) -> Result<Vec<LinearOpticalPixel>, ApplicationError>,
{
    if width == 0 || height == 0 || readout_duration.numerator() <= 0 {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let row_schedules = (0..usize::from(height))
        .map(|row| {
            let row_center = rolling_row_center_time(
                request.optics.time,
                readout_duration,
                row,
                usize::from(height),
                direction,
            )?;
            Ok((
                row,
                shutter_quadrature(
                    row_center,
                    request.duration,
                    request.temporal_samples,
                    request.optics.panel.temporal_emission,
                )?,
            ))
        })
        .collect::<Result<Vec<_>, ApplicationError>>()?;
    let pixel_count = usize::from(width) * usize::from(height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for (row, samples) in row_schedules {
        for sample in samples {
            let mut optics = request.optics.clone();
            optics.time = sample.time;
            let optical_row = optical_row_at_time(optics, row)?;
            if optical_row.len() != usize::from(width) {
                return Err(ApplicationError::OpticalSampleRasterMismatch);
            }
            for (column, pixel) in optical_row.into_iter().enumerate() {
                let sum = &mut accumulated[row * usize::from(width) + column];
                sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
                sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
                sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
            }
        }
    }
    finish_integrated_exposure(width, height, request.duration, accumulated)
}

fn rolling_row_center_time(
    frame_center: RationalTime,
    readout_duration: RationalTime,
    row: usize,
    height: usize,
    direction: RollingDirection,
) -> Result<RationalTime, ApplicationError> {
    if height == 0 || row >= height || readout_duration.numerator() <= 0 {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let ordered_row = match direction {
        RollingDirection::TopToBottom => row,
        RollingDirection::BottomToTop => height - 1 - row,
    };
    let numerator = i64::try_from(ordered_row * 2 + 1)
        .map_err(|_| ApplicationError::InvalidSensorReadout)?
        - i64::try_from(height).map_err(|_| ApplicationError::InvalidSensorReadout)?;
    let denominator =
        u32::try_from(height * 2).map_err(|_| ApplicationError::InvalidSensorReadout)?;
    let offset = readout_duration
        .checked_mul_ratio(numerator, denominator)
        .map_err(ApplicationError::Time)?;
    frame_center
        .checked_add(offset)
        .map_err(ApplicationError::Time)
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct TemporalSample {
    time: RationalTime,
    weight_seconds: f64,
}

fn shutter_quadrature(
    center: RationalTime,
    duration: RationalTime,
    temporal_samples: u16,
    panel_temporal: PanelTemporalEmission,
) -> Result<Vec<TemporalSample>, ApplicationError> {
    let duration_seconds = duration.as_seconds();
    if duration.numerator() <= 0
        || !duration_seconds.is_finite()
        || duration_seconds <= 0.0
        || duration_seconds > f64::from(f32::MAX)
        || !(1..=64).contains(&temporal_samples)
    {
        return Err(ApplicationError::InvalidShutter);
    }
    let half_duration = duration
        .checked_mul_ratio(1, 2)
        .map_err(ApplicationError::Time)?;
    let open = center
        .checked_sub(half_duration)
        .map_err(ApplicationError::Time)?;
    let close = center
        .checked_add(half_duration)
        .map_err(ApplicationError::Time)?;

    let mut boundaries = Vec::with_capacity(usize::from(temporal_samples) + 2);
    for index in 0..=temporal_samples {
        let offset = duration
            .checked_mul_ratio(i64::from(index), u32::from(temporal_samples))
            .map_err(ApplicationError::Time)?;
        boundaries.push(open.checked_add(offset).map_err(ApplicationError::Time)?);
    }
    boundaries.extend(
        panel_temporal
            .transitions_between(open, close)
            .map_err(ApplicationError::Panel)?,
    );
    boundaries.sort_unstable();
    boundaries.dedup();

    boundaries
        .windows(2)
        .map(|interval| {
            let width = interval[1]
                .checked_sub(interval[0])
                .map_err(ApplicationError::Time)?;
            let midpoint = interval[0]
                .checked_add(
                    width
                        .checked_mul_ratio(1, 2)
                        .map_err(ApplicationError::Time)?,
                )
                .map_err(ApplicationError::Time)?;
            Ok(TemporalSample {
                time: midpoint,
                weight_seconds: width.as_seconds(),
            })
        })
        .collect()
}

pub fn prepare_raster_from_device_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    source: &DeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<PreparedRaster, ApplicationError> {
    source.validate()?;
    let source_integral = DeviceSignalIntegral::new(source);
    let source_raster = [source.width, source.height];
    let device_raster = [
        request.optics.panel.native_width,
        request.optics.panel.native_height,
    ];
    prepare_raster_with_signal(
        request,
        width,
        height,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

pub fn evaluate_linear_optics_from_device_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    source: &DeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<LinearOpticalRaster, ApplicationError> {
    source.validate()?;
    let source_integral = DeviceSignalIntegral::new(source);
    let source_raster = [source.width, source.height];
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_raster_with_signal(
        request,
        width,
        height,
        DiagnosticView::Composite,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

pub fn evaluate_linear_optics_from_prepared_device_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let source_raster = source.raster_size();
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_raster_with_signal(
        request,
        width,
        height,
        DiagnosticView::Composite,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

fn evaluate_procedural_optical_row(
    request: OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    evaluate_optical_row_with_signal(
        request.clone(),
        width,
        height,
        row,
        &|uv| diagnostic_signal(uv, request.time),
        &|minimum, maximum| diagnostic_area_signal(minimum, maximum, request.time),
    )
}

fn evaluate_optical_row_from_prepared_device_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let source_raster = source.raster_size();
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_row_with_signal(
        request,
        width,
        height,
        row,
        &|device_uv| {
            source_uv_for_device_uv(source_raster, device_raster, placement, device_uv)
                .map_or(DeviceRgb::BLACK, |source_uv| {
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

fn evaluate_optical_row_with_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> DeviceRgb + Sync),
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    if width == 0 || height == 0 || row >= usize::from(height) {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let frame = prepare_frame(request.clone())?;
    let raster_aspect = f32::from(width) / f32::from(height);
    if (raster_aspect - frame.viewport_aspect).abs() > 1.0e-4 {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect,
            viewport_aspect: frame.viewport_aspect,
        });
    }
    let evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let temporal_gain = evaluator
        .temporal_gain(request.time)
        .map_err(ApplicationError::Panel)?;
    Ok((0..usize::from(width))
        .map(|column| {
            evaluate_optical_pixel(
                &frame,
                &request,
                width,
                height,
                row,
                column,
                DiagnosticView::Composite,
                evaluator,
                temporal_gain,
                signal_at,
                signal_area,
            )
        })
        .collect())
}

fn prepare_raster_with_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> DeviceRgb + Sync),
) -> Result<PreparedRaster, ApplicationError> {
    if !request.preview_exposure_ev.is_finite() {
        return Err(ApplicationError::InvalidPreviewExposure);
    }
    let linear = evaluate_optical_raster_with_signal(
        request.optical_request(),
        width,
        height,
        request.view,
        signal_at,
        signal_area,
    )?;
    let display = DiagnosticDisplayTransform {
        reference_white_nits: 100.0,
    };
    let preview_gain = if request.view == DiagnosticView::DeviceSignal {
        1.0
    } else {
        request.preview_exposure_ev.exp2()
    };
    let pixels = linear
        .pixels
        .iter()
        .map(|pixel| {
            let value = LinearRgb::new(
                pixel.acescg_irradiance.r * preview_gain,
                pixel.acescg_irradiance.g * preview_gain,
                pixel.acescg_irradiance.b * preview_gain,
            );
            PreviewPixel {
                rgb: if request.view == DiagnosticView::DeviceSignal {
                    PreviewRgb {
                        r: value.r,
                        g: value.g,
                        b: value.b,
                    }
                } else {
                    display.scene_linear_to_srgb(value)
                },
                on_panel: pixel.on_panel,
            }
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

fn evaluate_optical_raster_with_signal(
    request: OpticalRequest,
    width: u16,
    height: u16,
    view: DiagnosticView,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> DeviceRgb + Sync),
) -> Result<LinearOpticalRaster, ApplicationError> {
    if width == 0 || height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let mut frame = prepare_frame(request.clone())?;
    let raster_aspect = f32::from(width) / f32::from(height);
    if (raster_aspect - frame.viewport_aspect).abs() > 1.0e-4 {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect,
            viewport_aspect: frame.viewport_aspect,
        });
    }
    frame.representative_signal = signal_at(Vec2 { x: 0.5, y: 0.5 });
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let panel_temporal_gain = panel_evaluator
        .temporal_gain(request.time)
        .map_err(ApplicationError::Panel)?;
    let representative = request.panel.emitted_radiance(frame.representative_signal);
    frame.representative_emission = LinearRgb::new(
        representative.r * panel_temporal_gain,
        representative.g * panel_temporal_gain,
        representative.b * panel_temporal_gain,
    );
    let preview_scale_percent = projected_device_pixel_width(&frame, request.panel, width)
        .ok_or(ApplicationError::ViewRayMissesPanel)?
        * 100.0;
    let subpixels_resolved_at_center =
        optical_footprint_device_pixels(&frame, request.panel, width, height)
            .is_some_and(|footprint| footprint[0] <= 1.0 / 3.0 && footprint[1] <= 1.0);
    let mut pixels = vec![
        LinearOpticalPixel {
            acescg_irradiance: LinearRgb::new(0.0, 0.0, 0.0),
            on_panel: false,
        };
        usize::from(width) * usize::from(height)
    ];
    pixels
        .par_chunks_mut(usize::from(width))
        .enumerate()
        .for_each(|(row, output_row)| {
            for (column, output) in output_row.iter_mut().enumerate() {
                *output = evaluate_optical_pixel(
                    &frame,
                    &request,
                    width,
                    height,
                    row,
                    column,
                    view,
                    panel_evaluator,
                    panel_temporal_gain,
                    signal_at,
                    signal_area,
                );
            }
        });
    let inspection_field_meters = request.inspection.map(|region| {
        [
            (region.max.x - region.min.x) * request.panel.active_width.0,
            (region.max.y - region.min.y) * request.panel.active_height.0,
        ]
    });
    Ok(LinearOpticalRaster {
        frame,
        width,
        height,
        pixels,
        projected_device_pixel_percent: preview_scale_percent,
        inspection_field_meters,
        subpixels_resolved_at_center,
    })
}

#[allow(clippy::too_many_arguments)]
fn evaluate_optical_pixel(
    frame: &PreparedFrame,
    request: &OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
    column: usize,
    view: DiagnosticView,
    panel_evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> DeviceRgb + Sync),
) -> LinearOpticalPixel {
    const FOOTPRINT_CORNERS: [Vec2; 4] = [
        Vec2 { x: 0.001, y: 0.001 },
        Vec2 { x: 0.999, y: 0.001 },
        Vec2 { x: 0.001, y: 0.999 },
        Vec2 { x: 0.999, y: 0.999 },
    ];
    const RESOLVED_SENSOR_BOX: [Vec2; 16] = [
        Vec2 { x: 0.125, y: 0.125 },
        Vec2 { x: 0.375, y: 0.125 },
        Vec2 { x: 0.625, y: 0.125 },
        Vec2 { x: 0.875, y: 0.125 },
        Vec2 { x: 0.125, y: 0.375 },
        Vec2 { x: 0.375, y: 0.375 },
        Vec2 { x: 0.625, y: 0.375 },
        Vec2 { x: 0.875, y: 0.375 },
        Vec2 { x: 0.125, y: 0.625 },
        Vec2 { x: 0.375, y: 0.625 },
        Vec2 { x: 0.625, y: 0.625 },
        Vec2 { x: 0.875, y: 0.625 },
        Vec2 { x: 0.125, y: 0.875 },
        Vec2 { x: 0.375, y: 0.875 },
        Vec2 { x: 0.625, y: 0.875 },
        Vec2 { x: 0.875, y: 0.875 },
    ];
    let trace = |offset: Vec2| {
        let viewport_ndc = Vec2 {
            x: (column as f32 + offset.x) / f32::from(width) * 2.0 - 1.0,
            y: (row as f32 + offset.y) / f32::from(height) * 2.0 - 1.0,
        };
        panel_uv_aperture_samples(
            frame.camera,
            frame.screen,
            request.panel.active_width,
            request.panel.active_height,
            viewport_ndc,
        )
    };
    let footprint = FOOTPRINT_CORNERS.map(trace);
    if !subpixels_resolved_for_samples(&footprint, request.panel) {
        return integrate_aperture_samples(
            &footprint,
            view,
            request.panel,
            panel_evaluator,
            panel_temporal_gain,
            signal_at,
            signal_area,
        );
    }
    let aperture_samples = RESOLVED_SENSOR_BOX.map(trace);
    integrate_aperture_samples(
        &aperture_samples,
        view,
        request.panel,
        panel_evaluator,
        panel_temporal_gain,
        signal_at,
        signal_area,
    )
}

fn integrate_aperture_samples(
    spatial_samples: &[[OpticalSample; APERTURE_SAMPLE_COUNT]],
    view: DiagnosticView,
    panel: LcdProfile,
    evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> DeviceRgb + Sync),
) -> LinearOpticalPixel {
    let subpixels_resolved = subpixels_resolved_for_samples(spatial_samples, panel);
    let mut sum = LinearRgb::new(0.0, 0.0, 0.0);
    let mut on_panel = false;
    if !subpixels_resolved {
        for aperture in 0..APERTURE_SAMPLE_COUNT {
            for channel in 0..3 {
                let mut minimum = Vec2 {
                    x: f32::INFINITY,
                    y: f32::INFINITY,
                };
                let mut maximum = Vec2 {
                    x: f32::NEG_INFINITY,
                    y: f32::NEG_INFINITY,
                };
                let mut weight_sum = 0.0;
                let mut count = 0;
                for spatial in spatial_samples {
                    let optical = spatial[aperture];
                    let Some(uv) = optical.panel_uv[channel]
                        .filter(|uv| (0.0..=1.0).contains(&uv.x) && (0.0..=1.0).contains(&uv.y))
                    else {
                        continue;
                    };
                    minimum.x = minimum.x.min(uv.x);
                    minimum.y = minimum.y.min(uv.y);
                    maximum.x = maximum.x.max(uv.x);
                    maximum.y = maximum.y.max(uv.y);
                    weight_sum += optical_channel_weight(
                        optical,
                        evaluator,
                        panel_temporal_gain,
                        view,
                        channel,
                    );
                    count += 1;
                }
                if count == 0 {
                    continue;
                }
                on_panel = true;
                let signal = signal_area(minimum, maximum);
                let value = if view == DiagnosticView::DeviceSignal {
                    [signal.r, signal.g, signal.b][channel]
                } else {
                    evaluator.native_channel(signal, channel)
                };
                let contribution = value * weight_sum / spatial_samples.len() as f32;
                match channel {
                    0 => sum.r += contribution,
                    1 => sum.g += contribution,
                    _ => sum.b += contribution,
                }
            }
        }
        let scale = 1.0 / APERTURE_SAMPLE_COUNT as f32;
        let native_average = LinearRgb::new(sum.r * scale, sum.g * scale, sum.b * scale);
        return LinearOpticalPixel {
            acescg_irradiance: if view == DiagnosticView::DeviceSignal {
                native_average
            } else {
                evaluator.native_to_acescg(native_average)
            },
            on_panel,
        };
    }
    for optical_sample in spatial_samples.iter().flatten() {
        for channel in 0..3 {
            let Some(uv) = optical_sample.panel_uv[channel]
                .filter(|uv| (0.0..=1.0).contains(&uv.x) && (0.0..=1.0).contains(&uv.y))
            else {
                continue;
            };
            on_panel = true;
            let signal = signal_at(uv);
            let value = match view {
                DiagnosticView::DeviceSignal => [signal.r, signal.g, signal.b][channel],
                DiagnosticView::Composite
                | DiagnosticView::EmittedRadiance
                | DiagnosticView::Subpixels
                    if subpixels_resolved =>
                {
                    let pixel_uv = Vec2 {
                        x: (uv.x * panel.native_width as f32).fract(),
                        y: (uv.y * panel.native_height as f32).fract(),
                    };
                    evaluator.native_channel_at_pixel(signal, pixel_uv, channel)
                }
                DiagnosticView::Composite
                | DiagnosticView::EmittedRadiance
                | DiagnosticView::Subpixels => evaluator.native_channel(signal, channel),
            };
            let optical_weight = optical_channel_weight(
                *optical_sample,
                evaluator,
                panel_temporal_gain,
                view,
                channel,
            );
            let weighted = value * optical_weight;
            match channel {
                0 => sum.r += weighted,
                1 => sum.g += weighted,
                _ => sum.b += weighted,
            }
        }
    }
    let scale = 1.0 / (APERTURE_SAMPLE_COUNT * spatial_samples.len()) as f32;
    let native_average = LinearRgb::new(sum.r * scale, sum.g * scale, sum.b * scale);
    let average = if view == DiagnosticView::DeviceSignal {
        native_average
    } else {
        evaluator.native_to_acescg(native_average)
    };
    LinearOpticalPixel {
        acescg_irradiance: average,
        on_panel,
    }
}

fn optical_channel_weight(
    optical: OpticalSample,
    evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    view: DiagnosticView,
    channel: usize,
) -> f32 {
    if view == DiagnosticView::DeviceSignal {
        return 1.0;
    }
    optical.irradiance_weight[channel]
        * evaluator.angular_channel(optical.emission_cosine[channel], channel)
        * panel_temporal_gain
}

fn subpixels_resolved_for_samples(
    spatial_samples: &[[OpticalSample; APERTURE_SAMPLE_COUNT]],
    panel: LcdProfile,
) -> bool {
    (0..3).all(|channel| {
        let mut minimum = Vec2 {
            x: f32::INFINITY,
            y: f32::INFINITY,
        };
        let mut maximum = Vec2 {
            x: f32::NEG_INFINITY,
            y: f32::NEG_INFINITY,
        };
        let mut count = 0;
        for uv in spatial_samples
            .iter()
            .flatten()
            .filter_map(|sample| sample.panel_uv[channel])
        {
            minimum.x = minimum.x.min(uv.x);
            minimum.y = minimum.y.min(uv.y);
            maximum.x = maximum.x.max(uv.x);
            maximum.y = maximum.y.max(uv.y);
            count += 1;
        }
        count > 0
            && (maximum.x - minimum.x) * panel.native_width as f32 <= 1.0 / 3.0
            && (maximum.y - minimum.y) * panel.native_height as f32 <= 1.0
    })
}

pub fn inspection_region_from_drag(
    request: SimulationRequest,
    start_ndc: Vec2,
    end_ndc: Vec2,
) -> Result<PanelRegion, ApplicationError> {
    let frame = prepare_frame(request.optical_request())?;
    let intersect = |point| {
        panel_uv_at_viewport(
            frame.camera,
            frame.screen,
            request.optics.panel.active_width,
            request.optics.panel.active_height,
            request.optics.viewport_aspect,
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
    let point = |uv: Vec2| {
        frame.screen.local_to_world(Vec3 {
            x: (uv.x - 0.5) * panel.active_width.0,
            y: (0.5 - uv.y) * panel.active_height.0,
            z: 0.0,
        })
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

fn optical_footprint_device_pixels(
    frame: &PreparedFrame,
    panel: LcdProfile,
    preview_width: u16,
    preview_height: u16,
) -> Option<[f32; 2]> {
    let positions = [
        Vec2 { x: 0.0, y: 0.0 },
        Vec2 {
            x: 2.0 / f32::from(preview_width),
            y: 0.0,
        },
        Vec2 {
            x: 0.0,
            y: 2.0 / f32::from(preview_height),
        },
    ];
    let mut minimum = [Vec2 {
        x: f32::INFINITY,
        y: f32::INFINITY,
    }; 3];
    let mut maximum = [Vec2 {
        x: f32::NEG_INFINITY,
        y: f32::NEG_INFINITY,
    }; 3];
    let mut count = 0;
    for sample in positions.into_iter().flat_map(|position| {
        panel_uv_aperture_samples(
            frame.camera,
            frame.screen,
            panel.active_width,
            panel.active_height,
            position,
        )
    }) {
        for (channel, uv) in sample.panel_uv.into_iter().enumerate() {
            if let Some(uv) = uv {
                minimum[channel].x = minimum[channel].x.min(uv.x);
                minimum[channel].y = minimum[channel].y.min(uv.y);
                maximum[channel].x = maximum[channel].x.max(uv.x);
                maximum[channel].y = maximum[channel].y.max(uv.y);
                count += 1;
            }
        }
    }
    (count > 0).then_some([
        (0..3)
            .map(|channel| (maximum[channel].x - minimum[channel].x) * panel.native_width as f32)
            .fold(0.0, f32::max),
        (0..3)
            .map(|channel| (maximum[channel].y - minimum[channel].y) * panel.native_height as f32)
            .fold(0.0, f32::max),
    ])
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

fn diagnostic_area_signal(minimum: Vec2, maximum: Vec2, time: RationalTime) -> DeviceRgb {
    const OFFSETS: [f32; 4] = [0.125, 0.375, 0.625, 0.875];
    let mut sum = DeviceRgb::BLACK;
    for y in OFFSETS {
        for x in OFFSETS {
            let uv = Vec2 {
                x: minimum.x + (maximum.x - minimum.x) * x,
                y: minimum.y + (maximum.y - minimum.y) * y,
            };
            let value = diagnostic_signal(uv, time);
            sum.r += value.r;
            sum.g += value.g;
            sum.b += value.b;
        }
    }
    DeviceRgb::new(sum.r / 16.0, sum.g / 16.0, sum.b / 16.0)
}

#[derive(Clone, Debug, PartialEq)]
pub enum ApplicationError {
    InvalidViewportAspect,
    InvalidPreviewExposure,
    InvalidShutter,
    InvalidSensorReadout,
    OpticalSampleRasterMismatch,
    SensorViewportAspectMismatch {
        sensor_aspect: f32,
        viewport_aspect: f32,
    },
    RasterViewportAspectMismatch {
        raster_aspect: f32,
        viewport_aspect: f32,
    },
    EmptyPreviewRaster,
    InspectionMustStartOnPanel,
    ViewRayMissesPanel,
    EmptyDeviceSignalRaster,
    NonFiniteDeviceSignal,
    DeviceSignalPixelCountMismatch {
        expected: u64,
        actual: u64,
    },
    DecodedPixelCountMismatch {
        expected: u64,
        actual: u64,
    },
    DecodedPixelStorageTooLarge,
    AlphaAssociationUnresolved,
    Color(ColorError),
    Panel(PanelError),
    Geometry(GeometryError),
    Sensor(SensorError),
    CameraDevelopment(CameraDevelopmentError),
    Time(ContractError),
}

impl fmt::Display for ApplicationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidViewportAspect => formatter.write_str("viewport aspect must be positive"),
            Self::InvalidPreviewExposure => {
                formatter.write_str("preview exposure EV must be finite")
            }
            Self::InvalidShutter => formatter.write_str(
                "shutter duration must be positive and temporal samples must be in [1, 64]",
            ),
            Self::InvalidSensorReadout => formatter.write_str(
                "sensor readout duration and row coordinates must define a valid shutter interval",
            ),
            Self::OpticalSampleRasterMismatch => formatter
                .write_str("all temporal optical samples must match the authored sensor raster"),
            Self::SensorViewportAspectMismatch {
                sensor_aspect,
                viewport_aspect,
            } => write!(
                formatter,
                "sensor aspect {sensor_aspect:.6} does not match authored viewport aspect {viewport_aspect:.6}"
            ),
            Self::RasterViewportAspectMismatch {
                raster_aspect,
                viewport_aspect,
            } => write!(
                formatter,
                "raster aspect {raster_aspect:.6} does not match authored viewport aspect {viewport_aspect:.6}"
            ),
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
            Self::NonFiniteDeviceSignal => {
                formatter.write_str("device signal raster must contain only finite RGB values")
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
            Self::Sensor(error) => write!(formatter, "invalid sensor capture: {error}"),
            Self::CameraDevelopment(error) => write!(formatter, "camera development: {error}"),
            Self::Time(error) => write!(formatter, "invalid capture time: {error}"),
        }
    }
}

impl std::error::Error for ApplicationError {}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_color::{ColorEngine, DeviceColorTarget, SourceColorInterpretation};
    use screen_contracts::{Meters, Millimeters};
    use screen_panel::PanelTemporalEmission;
    use screen_panel::{PanelColorimetry, StripeLayout};

    fn request() -> SimulationRequest {
        SimulationRequest {
            optics: OpticalRequest {
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
                    colorimetry: PanelColorimetry::SRGB_D65,
                    angular_emission_power: LinearRgb::new(1.7, 1.5, 1.8),
                    temporal_emission: PanelTemporalEmission::continuous(),
                },
                camera: CameraRig {
                    transform: screen_geometry::TransformTrack {
                        keyframes: vec![screen_geometry::TransformKeyframe {
                            id: "camera-transform-0".to_owned(),
                            time: RationalTime::new(0, 24).expect("valid time"),
                            translation: Vec3 {
                                x: 0.0,
                                y: 0.0,
                                z: 0.8,
                            },
                            rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                            interpolation: screen_geometry::KeyframeInterpolation::Smooth,
                        }],
                    },
                    intrinsics: screen_geometry::CameraIntrinsicsTrack {
                        keyframes: vec![screen_geometry::CameraIntrinsicsKeyframe {
                            id: "camera-intrinsics-0".to_owned(),
                            time: RationalTime::new(0, 24).expect("valid time"),
                            focal_length: Millimeters(50.0),
                            sensor_width: Millimeters(36.0),
                            sensor_height: Millimeters(20.25),
                            lens_shift: Vec2 { x: 0.0, y: 0.0 },
                            focus_distance: Meters(0.8),
                            f_stop: 8.0,
                            near_clip: Meters(0.01),
                            far_clip: Meters(100.0),
                            lens: screen_geometry::LensModel::REFERENCE_PHOTOGRAPHIC,
                            interpolation: screen_geometry::KeyframeInterpolation::Smooth,
                        }],
                    },
                },
                screen: screen_geometry::TransformTrack {
                    keyframes: vec![screen_geometry::TransformKeyframe {
                        id: "screen-transform-0".to_owned(),
                        time: RationalTime::new(0, 24).expect("valid time"),
                        translation: Vec3 {
                            x: 0.0,
                            y: 0.0,
                            z: 0.0,
                        },
                        rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                        interpolation: screen_geometry::KeyframeInterpolation::Hold,
                    }],
                },
                inspection: None,
            },
            view: DiagnosticView::Composite,
            preview_exposure_ev: 6.0,
        }
    }

    #[test]
    fn prepares_one_immutable_cross_domain_result() {
        let frame = prepare_frame(request().optical_request()).expect("valid request");
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
        invalid.optics.panel.native_width = 0;
        assert_eq!(
            prepare_frame(invalid.optical_request()),
            Err(ApplicationError::Panel(PanelError::EmptyNativeRaster))
        );
    }

    #[test]
    fn sensor_and_output_aspects_require_an_explicit_match() {
        let mut request = request();
        request.optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(24.0);
        assert!(matches!(
            prepare_frame(request.optical_request()),
            Err(ApplicationError::SensorViewportAspectMismatch { .. })
        ));
    }

    #[test]
    fn parallel_optical_reference_is_deterministic() {
        let first = prepare_raster(request(), 96, 54).expect("first optical render");
        let second = prepare_raster(request(), 96, 54).expect("second optical render");
        assert_eq!(first, second);
    }

    #[test]
    fn linear_optical_output_is_independent_of_preview_exposure() {
        let mut preview = request();
        let first =
            evaluate_linear_optics(preview.optical_request(), 32, 18).expect("linear render");
        preview.preview_exposure_ev = -12.0;
        let second =
            evaluate_linear_optics(preview.optical_request(), 32, 18).expect("linear render");
        assert_eq!(first, second);
    }

    #[test]
    fn global_shutter_uses_exact_centered_temporal_quadrature() {
        let center = RationalTime::new(1, 1).expect("valid center");
        let duration = RationalTime::new(1, 48).expect("valid shutter");
        let samples = shutter_quadrature(center, duration, 4, PanelTemporalEmission::continuous())
            .expect("valid samples");
        assert_eq!(
            samples.iter().map(|sample| sample.time).collect::<Vec<_>>(),
            vec![
                RationalTime::new(127, 128).expect("valid time"),
                RationalTime::new(383, 384).expect("valid time"),
                RationalTime::new(385, 384).expect("valid time"),
                RationalTime::new(129, 128).expect("valid time"),
            ]
        );
        assert!(samples.iter().all(|sample| {
            (sample.weight_seconds - RationalTime::new(1, 192).unwrap().as_seconds()).abs()
                < f64::EPSILON
        }));
        assert_eq!(
            shutter_quadrature(center, duration, 0, PanelTemporalEmission::continuous(),),
            Err(ApplicationError::InvalidShutter)
        );
    }

    #[test]
    fn global_shutter_capture_is_deterministic_and_samples_the_signal_sequence() {
        let mut optics = request().optics;
        optics.time = RationalTime::new(99, 1).expect("ignored preview time");
        let capture = FrameCaptureRequest {
            optics,
            frame_rate: FrameRate::new(24, 1).expect("valid frame rate"),
            frame_index: 24,
            duration: RationalTime::new(1, 48).expect("valid shutter"),
            temporal_samples: 4,
            readout: SensorReadout::Global,
            noise_seed: 42,
        };
        let sensor = SensorProfile {
            native_width: 32,
            native_height: 18,
            ..SensorProfile::REFERENCE
        };
        let mut sampled_times = Vec::new();
        let first = capture_frame_from_device_signal_sequence(
            capture.clone(),
            RasterPlacement::Stretch,
            |time| {
                sampled_times.push(time);
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
            sensor,
        )
        .expect("first capture");
        let second = capture_frame_from_device_signal_sequence(
            capture,
            RasterPlacement::Stretch,
            |_| {
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
            sensor,
        )
        .expect("repeated capture");
        assert_eq!(sampled_times.len(), 4);
        assert!(sampled_times.iter().all(|time| {
            *time > RationalTime::new(0, 1).unwrap() && *time < RationalTime::new(2, 1).unwrap()
        }));
        assert_eq!(first, second);
        assert_eq!(first.codes.len(), 32 * 18);
    }

    #[test]
    fn application_publishes_raw_and_developed_acescg_as_distinct_immutable_results() {
        let capture = FrameCaptureRequest {
            optics: request().optics,
            frame_rate: FrameRate::new(24, 1).expect("valid frame rate"),
            frame_index: 0,
            duration: RationalTime::new(1, 48).expect("valid shutter"),
            temporal_samples: 1,
            readout: SensorReadout::Global,
            noise_seed: 7,
        };
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let frame = capture_and_develop_frame_from_device_signal_sequence(
            capture,
            RasterPlacement::Stretch,
            |_| {
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
            sensor,
            CameraDevelopment {
                white_balance: LinearRgb::new(2.0, 1.0, 1.5),
                linear_exposure_scale: 1.0,
            },
        )
        .expect("captured camera frame");
        assert_eq!(frame.raw.codes.len(), 144);
        assert_eq!(frame.developed.acescg.len(), 144);
        assert!(
            frame
                .developed
                .acescg
                .iter()
                .all(|pixel| pixel.r.is_finite() && pixel.g.is_finite() && pixel.b.is_finite())
        );
    }

    #[test]
    fn global_shutter_integrates_physical_panel_pwm_phase() {
        let base_optics = request().optics;
        let signal = |_| {
            Ok(Arc::new(PreparedDeviceSignalRaster::new(
                DeviceSignalRaster {
                    width: 1,
                    height: 1,
                    pixels: vec![DeviceRgb::WHITE],
                },
            )?))
        };
        let continuous = integrate_shutter_from_device_signal_sequence(
            ShutterRequest {
                optics: base_optics.clone(),
                duration: RationalTime::new(1, 100).unwrap(),
                temporal_samples: 1,
                readout: SensorReadout::Global,
            },
            32,
            18,
            RasterPlacement::Stretch,
            signal,
        )
        .expect("continuous exposure");
        let mut pulsed_optics = base_optics;
        pulsed_optics.panel.temporal_emission = PanelTemporalEmission {
            pwm_period: RationalTime::new(1, 1_000).unwrap(),
            pwm_on_duration: RationalTime::new(1, 2_000).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
        };
        let pulsed = integrate_shutter_from_device_signal_sequence(
            ShutterRequest {
                optics: pulsed_optics,
                duration: RationalTime::new(1, 100).unwrap(),
                temporal_samples: 1,
                readout: SensorReadout::Global,
            },
            32,
            18,
            RasterPlacement::Stretch,
            signal,
        )
        .expect("pulsed exposure");
        let index = 9 * 32 + 16;
        let continuous_value = continuous.acescg_irradiance_seconds[index].g;
        let pulsed_value = pulsed.acescg_irradiance_seconds[index].g;
        assert!((pulsed_value / continuous_value - 0.5).abs() < 1.0e-5);
    }

    #[test]
    fn rolling_shutter_offsets_each_row_in_exact_readout_order() {
        let center = RationalTime::new(0, 1).unwrap();
        let readout = RationalTime::new(1, 100).unwrap();
        assert_eq!(
            rolling_row_center_time(center, readout, 0, 4, RollingDirection::TopToBottom).unwrap(),
            RationalTime::new(-3, 800).unwrap()
        );
        assert_eq!(
            rolling_row_center_time(center, readout, 0, 4, RollingDirection::BottomToTop).unwrap(),
            RationalTime::new(3, 800).unwrap()
        );
    }

    #[test]
    fn rolling_shutter_and_panel_pwm_create_physical_row_bands() {
        let mut optics = request().optics;
        optics.time = RationalTime::new(0, 1).unwrap();
        optics.panel.temporal_emission = PanelTemporalEmission {
            pwm_period: RationalTime::new(1, 100).unwrap(),
            pwm_on_duration: RationalTime::new(1, 200).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
        };
        let prepared = Arc::new(
            PreparedDeviceSignalRaster::new(DeviceSignalRaster {
                width: 1,
                height: 1,
                pixels: vec![DeviceRgb::WHITE],
            })
            .unwrap(),
        );
        let exposure = integrate_shutter_from_device_signal_sequence(
            ShutterRequest {
                optics,
                duration: RationalTime::new(1, 100_000).unwrap(),
                temporal_samples: 1,
                readout: SensorReadout::Rolling {
                    duration: RationalTime::new(1, 100).unwrap(),
                    direction: RollingDirection::TopToBottom,
                },
            },
            32,
            18,
            RasterPlacement::Stretch,
            |_| Ok(Arc::clone(&prepared)),
        )
        .expect("rolling exposure");
        let top = exposure.acescg_irradiance_seconds[2 * 32 + 16].g;
        let bottom = exposure.acescg_irradiance_seconds[15 * 32 + 16].g;
        assert_eq!(top, 0.0);
        assert!(bottom > 0.0);
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
    fn composite_uses_physical_black_matrix_when_resolved() {
        let request = request();
        let optical = OpticalSample {
            panel_uv: [Some(Vec2 { x: 0.5, y: 0.5 }); 3],
            emission_cosine: [1.0; 3],
            irradiance_weight: [1.0; 3],
        };
        let resolved_spatial = [[optical; APERTURE_SAMPLE_COUNT]];
        let resolved = integrate_aperture_samples(
            &resolved_spatial,
            DiagnosticView::Composite,
            request.optics.panel,
            request.optics.panel.evaluator().expect("valid panel"),
            1.0,
            &|_| DeviceRgb::WHITE,
            &|_, _| DeviceRgb::WHITE,
        );
        let mut offset = optical;
        offset.panel_uv = [Some(Vec2 { x: 0.51, y: 0.51 }); 3];
        let unresolved_spatial = [
            [optical; APERTURE_SAMPLE_COUNT],
            [offset; APERTURE_SAMPLE_COUNT],
        ];
        let unresolved = integrate_aperture_samples(
            &unresolved_spatial,
            DiagnosticView::Composite,
            request.optics.panel,
            request.optics.panel.evaluator().expect("valid panel"),
            1.0,
            &|_| DeviceRgb::WHITE,
            &|_, _| DeviceRgb::WHITE,
        );
        assert_eq!(resolved.acescg_irradiance, LinearRgb::new(0.0, 0.0, 0.0));
        assert!(unresolved.acescg_irradiance.g > 0.0);
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
    fn device_signal_area_filter_integrates_piecewise_constant_native_pixels() {
        let raster = DeviceSignalRaster {
            width: 2,
            height: 2,
            pixels: vec![
                DeviceRgb::BLACK,
                DeviceRgb::WHITE,
                DeviceRgb::WHITE,
                DeviceRgb::BLACK,
            ],
        };
        let integral = DeviceSignalIntegral::new(&raster);
        let average = integral.sample_area_box(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        assert_eq!(average, DeviceRgb::new(0.5, 0.5, 0.5));
        let with_black_outside =
            integral.sample_area_box(Vec2 { x: -1.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        assert_eq!(with_black_outside, DeviceRgb::new(0.25, 0.25, 0.25));

        let high = f32::MAX / 4.0;
        let hdr = DeviceSignalRaster {
            width: 2,
            height: 2,
            pixels: vec![DeviceRgb::new(high, high, high); 4],
        };
        let hdr_average = DeviceSignalIntegral::new(&hdr)
            .sample_area_box(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        assert_eq!(hdr_average, DeviceRgb::new(high, high, high));
        assert!(hdr_average.r.is_finite());
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
        request.optics.camera.intrinsics.keyframes[0]
            .lens
            .longitudinal_chromatic_meters = [0.0; 3];
        request.optics.camera.intrinsics.keyframes[0]
            .lens
            .lateral_chromatic_scale = [1.0; 3];
        request.view = DiagnosticView::Subpixels;
        request.optics.inspection = Some(PanelRegion {
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
        request.optics.time = RationalTime::new(48, 24).expect("valid time");
        let yaw = 80.0_f32.to_radians();
        request.optics.camera.transform.keyframes[0].translation = Vec3 {
            x: 0.8 * yaw.sin(),
            y: 0.0,
            z: 0.8 * yaw.cos(),
        };
        request.optics.camera.transform.keyframes[0].rotation =
            screen_geometry::Quaternion::from_yaw_degrees(80.0);
        request.optics.inspection = Some(PanelRegion {
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
