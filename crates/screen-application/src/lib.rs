//! UI-independent immutable request preparation and current-pipeline orchestration.

#![forbid(unsafe_code)]

use core::fmt;
use rayon::prelude::*;
use screen_camera::{
    CameraDevelopment, CameraDevelopmentError, CpuRawDevelopment, DevelopedCameraRaster,
    DevelopedCameraRegion, RawDevelopmentBackend, develop_raw_to_acescg,
};
use screen_color::{ColorError, DiagnosticDisplayTransform, PreviewRgb, SourceToDeviceProcessor};
use screen_contracts::{
    ContractError, DeviceRgb, FrameRate, LinearRgb, Millimeters, RationalTime, Vec2, Vec3,
};
use screen_cover::{
    CoverError, CoverGlassProfile, CoverSurfaceSample, ProceduralEnvironment,
    ValidatedCoverEvaluator,
};
#[cfg(test)]
use screen_geometry::APERTURE_SAMPLE_COUNT;
use screen_geometry::{
    CameraRig, CameraSample, GeometryError, OpticalSample, PanelRegion, ProjectedScreen,
    ScreenSample, ScreenTrack, panel_uv_aperture_samples, panel_uv_aperture_samples_with_count,
    panel_uv_at_viewport, project_scene_point, project_screen,
};
use screen_media::{AlphaInterpretation, AlphaPresence, DecodedFrame};
use screen_panel::{LcdProfile, PanelError, ValidatedPanelEvaluator};
use screen_sensor::{
    BayerPattern, CaptureIdentity, IntegratedOpticalExposure, RawSensorRaster, RawSensorRegion,
    SensorError, SensorProfile, SensorRegion, expose_raw, expose_raw_region,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptureOpticsAuthority {
    InterchangeableReferenceLens,
    IntegratedFixedLens,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptureDevicePreset {
    pub id: &'static str,
    pub label: &'static str,
    pub calibration: &'static str,
    pub sensor: SensorProfile,
    pub gate_width: Millimeters,
    pub gate_height: Millimeters,
    pub focal_length: Millimeters,
    pub default_lens_preset_id: &'static str,
    pub f_stop: f32,
    pub reference_exposure_index: f32,
    pub middle_gray_illuminance_seconds_at_reference_ei: f32,
    pub default_shutter_angle_degrees: f32,
    pub default_temporal_samples: u16,
    pub default_readout_duration_milliseconds: f32,
    pub optics_authority: CaptureOpticsAuthority,
}

pub const CAPTURE_DEVICE_PRESETS: &[CaptureDevicePreset] = &[
    CaptureDevicePreset {
        id: "arri-alexa-35-open-gate",
        label: "ARRI ALEXA 35 · 4.6K Open Gate",
        calibration: "Published ALEV 4 geometry · reference 50 mm lens",
        sensor: SensorProfile {
            native_width: 4_608,
            native_height: 3_164,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: SensorProfile::REFERENCE.acescg_to_sensor,
            saturation_illuminance_seconds: LinearRgb::new(2.4, 2.4, 2.4),
            full_well_electrons: 65_000.0,
            dark_current_electrons_per_second: 0.1,
            read_noise_electrons_rms: 2.0,
            analog_gain: 1.0,
            adc_bits: 14,
        },
        gate_width: Millimeters(27.99),
        gate_height: Millimeters(19.22),
        focal_length: Millimeters(50.0),
        default_lens_preset_id: "generic-prime-50mm",
        f_stop: 4.0,
        reference_exposure_index: 800.0,
        middle_gray_illuminance_seconds_at_reference_ei: 0.0125,
        default_shutter_angle_degrees: 180.0,
        default_temporal_samples: 1,
        default_readout_duration_milliseconds: 7.8,
        optics_authority: CaptureOpticsAuthority::InterchangeableReferenceLens,
    },
    CaptureDevicePreset {
        id: "iphone-16e-main-48mp",
        label: "iPhone 16e Main · 48 MP",
        calibration: "Calibrated approximation · 4.2 mm EXIF / 26 mm equivalent",
        sensor: SensorProfile {
            native_width: 8_064,
            native_height: 6_048,
            bayer_pattern: BayerPattern::Rggb,
            acescg_to_sensor: SensorProfile::REFERENCE.acescg_to_sensor,
            saturation_illuminance_seconds: LinearRgb::new(0.8, 0.8, 0.8),
            full_well_electrons: 10_000.0,
            dark_current_electrons_per_second: 0.05,
            read_noise_electrons_rms: 1.5,
            analog_gain: 1.0,
            adc_bits: 12,
        },
        gate_width: Millimeters(5.815_385),
        gate_height: Millimeters(4.361_539),
        focal_length: Millimeters(4.2),
        default_lens_preset_id: "iphone-16e-main-integrated",
        f_stop: 1.64,
        reference_exposure_index: 100.0,
        middle_gray_illuminance_seconds_at_reference_ei: 0.1,
        default_shutter_angle_degrees: 30.0,
        default_temporal_samples: 1,
        default_readout_duration_milliseconds: 12.0,
        optics_authority: CaptureOpticsAuthority::IntegratedFixedLens,
    },
];

pub fn capture_device_preset(id: &str) -> Option<CaptureDevicePreset> {
    CAPTURE_DEVICE_PRESETS
        .iter()
        .copied()
        .find(|preset| preset.id == id)
}
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
        Self::new_mapped(source, |pixel| pixel)
    }

    fn new_mapped(source: &DeviceSignalRaster, map: impl Fn(DeviceRgb) -> DeviceRgb) -> Self {
        let stride = source.width as usize + 1;
        let mut prefix = vec![IntegralRgb::default(); stride * (source.height as usize + 1)];
        for row in 0..source.height as usize {
            let mut row_sum = IntegralRgb::default();
            for column in 0..source.width as usize {
                let pixel = map(source.pixels[row * source.width as usize + column]);
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

#[derive(Clone, Copy, Debug)]
struct AreaSignalSample {
    device_code: DeviceRgb,
    linear_native_emission: LinearRgb,
}

fn linear_emission_integral(
    source: &DeviceSignalRaster,
    evaluator: ValidatedPanelEvaluator,
) -> DeviceSignalIntegral {
    DeviceSignalIntegral::new_mapped(source, |pixel| {
        DeviceRgb::new(
            evaluator.native_channel(pixel, 0),
            evaluator.native_channel(pixel, 1),
            evaluator.native_channel(pixel, 2),
        )
    })
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
    source_code: &DeviceSignalIntegral,
    source_emission: &DeviceSignalIntegral,
    source_raster: [u32; 2],
    device_raster: [u32; 2],
    placement: RasterPlacement,
    minimum: Vec2,
    maximum: Vec2,
) -> AreaSignalSample {
    let Some(first) = source_uv_unbounded(source_raster, device_raster, placement, minimum) else {
        return AreaSignalSample {
            device_code: DeviceRgb::BLACK,
            linear_native_emission: LinearRgb::new(0.0, 0.0, 0.0),
        };
    };
    let Some(second) = source_uv_unbounded(source_raster, device_raster, placement, maximum) else {
        return AreaSignalSample {
            device_code: DeviceRgb::BLACK,
            linear_native_emission: LinearRgb::new(0.0, 0.0, 0.0),
        };
    };
    let device_code = source_code.sample_area_box(first, second);
    let emission = source_emission.sample_area_box(first, second);
    AreaSignalSample {
        device_code,
        linear_native_emission: LinearRgb::new(emission.r, emission.g, emission.b),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnosticView {
    Composite,
    DeviceSignal,
    Subpixels,
    EmittedRadiance,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProceduralTestPattern {
    AnimatedCheckerboard,
    EyeChart,
    PhotometricDeviceScale,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PanelTemporalEvaluation {
    /// Technical preview at one exact project time.
    Instantaneous,
    /// Shutter-integrated panel-emission gain. Optics still evaluate through the same path.
    ExposureAverage(f32),
}

pub const PHOTOMETRIC_DEVICE_CODES: [f32; 9] = [0.0, 0.05, 0.10, 0.18, 0.25, 0.50, 0.75, 0.90, 1.0];

#[derive(Clone, Debug, PartialEq)]
pub struct OpticalRequest {
    pub time: RationalTime,
    pub panel_temporal_evaluation: PanelTemporalEvaluation,
    pub viewport_aspect: f32,
    pub panel: LcdProfile,
    pub cover: CoverGlassProfile,
    pub environment: ProceduralEnvironment,
    pub camera: CameraRig,
    pub screen: ScreenTrack,
    pub inspection: Option<PanelRegion>,
    pub procedural_pattern: ProceduralTestPattern,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShutterRequest {
    pub optics: OpticalRequest,
    pub duration: RationalTime,
    pub temporal_samples: u16,
    pub readout: SensorReadout,
    /// Optical neutral-density attenuation applied before sensor charge collection.
    pub neutral_density_stops: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FrameCaptureRequest {
    pub optics: OpticalRequest,
    pub frame_rate: FrameRate,
    pub frame_index: i64,
    pub duration: RationalTime,
    pub temporal_samples: u16,
    pub readout: SensorReadout,
    pub neutral_density_stops: f32,
    pub noise_seed: u64,
}

impl FrameCaptureRequest {
    fn resolve(self) -> Result<(ShutterRequest, CaptureIdentity), ApplicationError> {
        if !self.neutral_density_stops.is_finite()
            || !(0.0..=16.0).contains(&self.neutral_density_stops)
        {
            return Err(ApplicationError::InvalidOpticalAttenuation);
        }
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
                neutral_density_stops: self.neutral_density_stops,
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RasterWindow {
    full_width: u16,
    full_height: u16,
    origin_x: u16,
    origin_y: u16,
    width: u16,
    height: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpatialRasterWindow {
    pub full_width: u16,
    pub full_height: u16,
    pub origin_x: u16,
    pub origin_y: u16,
    pub width: u16,
    pub height: u16,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SpatialSignalPlan {
    Procedural {
        pattern: ProceduralTestPattern,
        time_seconds: f32,
    },
    Raster {
        width: u32,
        height: u32,
        device_signal: Arc<[DeviceRgb]>,
        linear_native_emission: Arc<[LinearRgb]>,
        placement: RasterPlacement,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpatialPanelPlan {
    pub native_width: u32,
    pub native_height: u32,
    pub active_width_meters: f32,
    pub active_height_meters: f32,
    pub stripe_layout: screen_panel::StripeLayout,
    pub black_matrix_fraction: f32,
    pub eotf_gamma: f32,
    pub black_level_nits: f32,
    pub white_level_nits: f32,
    pub angular_emission_power: LinearRgb,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpatialOpticalPlan {
    pub frame: PreparedFrame,
    pub raster: SpatialRasterWindow,
    pub panel: SpatialPanelPlan,
    pub panel_native_to_acescg: [[f32; 3]; 3],
    pub cover: CoverGlassProfile,
    pub environment: ProceduralEnvironment,
    pub aperture_sample_count: u16,
    pub signal: SpatialSignalPlan,
}

impl SpatialOpticalPlan {
    fn has_identical_spatial_evaluation(&self, other: &Self) -> bool {
        self.raster == other.raster
            && self.frame.camera == other.frame.camera
            && self.frame.screen == other.frame.screen
            && self.panel == other.panel
            && self.panel_native_to_acescg == other.panel_native_to_acescg
            && self.cover == other.cover
            && self.environment == other.environment
            && self.aperture_sample_count == other.aperture_sample_count
            && self.signal.has_identical_spatial_evaluation(&other.signal)
    }
}

impl SpatialSignalPlan {
    fn has_identical_spatial_evaluation(&self, other: &Self) -> bool {
        match (self, other) {
            (
                Self::Procedural {
                    pattern: first_pattern,
                    time_seconds: first_time,
                },
                Self::Procedural {
                    pattern,
                    time_seconds,
                },
            ) => {
                first_pattern == pattern
                    && (*first_pattern != ProceduralTestPattern::AnimatedCheckerboard
                        || first_time == time_seconds)
            }
            (
                Self::Raster {
                    width: first_width,
                    height: first_height,
                    device_signal: first_device,
                    linear_native_emission: first_emission,
                    placement: first_placement,
                },
                Self::Raster {
                    width,
                    height,
                    device_signal,
                    linear_native_emission,
                    placement,
                },
            ) => {
                first_width == width
                    && first_height == height
                    && first_placement == placement
                    && Arc::ptr_eq(first_device, device_signal)
                    && Arc::ptr_eq(first_emission, linear_native_emission)
            }
            _ => false,
        }
    }
}

pub trait SpatialOpticalBackend {
    type Error: fmt::Display;

    fn evaluate_spatial(
        &self,
        plan: &SpatialOpticalPlan,
    ) -> Result<Vec<LinearOpticalPixel>, Self::Error>;

    fn evaluate_spatial_batch(
        &self,
        plans: &[SpatialOpticalPlan],
    ) -> Result<Vec<Vec<LinearOpticalPixel>>, Self::Error> {
        plans
            .iter()
            .map(|plan| self.evaluate_spatial(plan))
            .collect()
    }
}

impl RasterWindow {
    fn full(width: u16, height: u16) -> Self {
        Self {
            full_width: width,
            full_height: height,
            origin_x: 0,
            origin_y: 0,
            width,
            height,
        }
    }

    fn from_sensor_region(sensor: SensorProfile, region: SensorRegion) -> Self {
        Self {
            full_width: sensor.native_width,
            full_height: sensor.native_height,
            origin_x: region.origin_x,
            origin_y: region.origin_y,
            width: region.width,
            height: region.height,
        }
    }
}

impl From<RasterWindow> for SpatialRasterWindow {
    fn from(value: RasterWindow) -> Self {
        Self {
            full_width: value.full_width,
            full_height: value.full_height,
            origin_x: value.origin_x,
            origin_y: value.origin_y,
            width: value.width,
            height: value.height,
        }
    }
}

pub fn prepare_procedural_spatial_plan(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<SpatialOpticalPlan, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let region = region.validate(sensor).map_err(ApplicationError::Sensor)?;
    let pattern = request.procedural_pattern;
    let time_seconds = request.time.as_seconds() as f32;
    prepare_spatial_plan(
        request,
        RasterWindow::from_sensor_region(sensor, region),
        SpatialSignalPlan::Procedural {
            pattern,
            time_seconds,
        },
    )
}

pub fn prepare_device_signal_spatial_plan(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<SpatialOpticalPlan, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let region = region.validate(sensor).map_err(ApplicationError::Sensor)?;
    let signal = prepare_device_signal_spatial_signal(request.panel, source, placement)?;
    prepare_spatial_plan(
        request,
        RasterWindow::from_sensor_region(sensor, region),
        signal,
    )
}

fn prepare_device_signal_spatial_signal(
    panel: LcdProfile,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<SpatialSignalPlan, ApplicationError> {
    let panel_evaluator = panel.evaluator().map_err(ApplicationError::Panel)?;
    let linear_native_emission = source
        .source
        .pixels
        .iter()
        .map(|pixel| {
            LinearRgb::new(
                panel_evaluator.native_channel(*pixel, 0),
                panel_evaluator.native_channel(*pixel, 1),
                panel_evaluator.native_channel(*pixel, 2),
            )
        })
        .collect::<Vec<_>>();
    Ok(SpatialSignalPlan::Raster {
        width: source.source.width,
        height: source.source.height,
        device_signal: Arc::from(source.source.pixels.clone()),
        linear_native_emission: Arc::from(linear_native_emission),
        placement,
    })
}

fn prepare_spatial_plan(
    request: OpticalRequest,
    raster: RasterWindow,
    signal: SpatialSignalPlan,
) -> Result<SpatialOpticalPlan, ApplicationError> {
    if raster.width == 0 || raster.height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let frame = prepare_frame(request.clone())?;
    if !raster_represents_viewport(raster.full_width, raster.full_height, frame.viewport_aspect) {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect: f32::from(raster.full_width) / f32::from(raster.full_height),
            viewport_aspect: frame.viewport_aspect,
        });
    }
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let basis = [
        panel_evaluator.native_to_acescg(LinearRgb::new(1.0, 0.0, 0.0)),
        panel_evaluator.native_to_acescg(LinearRgb::new(0.0, 1.0, 0.0)),
        panel_evaluator.native_to_acescg(LinearRgb::new(0.0, 0.0, 1.0)),
    ];
    Ok(SpatialOpticalPlan {
        frame,
        raster: raster.into(),
        panel: SpatialPanelPlan {
            native_width: request.panel.native_width,
            native_height: request.panel.native_height,
            active_width_meters: request.panel.active_width.0,
            active_height_meters: request.panel.active_height.0,
            stripe_layout: request.panel.stripe_layout,
            black_matrix_fraction: request.panel.black_matrix_fraction,
            eotf_gamma: request.panel.eotf_gamma,
            black_level_nits: request.panel.black_level_nits,
            white_level_nits: request.panel.white_level_nits,
            angular_emission_power: request.panel.angular_emission_power,
        },
        panel_native_to_acescg: [
            [basis[0].r, basis[1].r, basis[2].r],
            [basis[0].g, basis[1].g, basis[2].g],
            [basis[0].b, basis[1].b, basis[2].b],
        ],
        cover: request.cover,
        environment: request.environment,
        aperture_sample_count: aperture_sample_count(
            frame.camera,
            frame.screen,
            request.panel,
            raster.full_width,
        ) as u16,
        signal,
    })
}

pub fn prepare_frame(request: OpticalRequest) -> Result<PreparedFrame, ApplicationError> {
    if !request.viewport_aspect.is_finite() || request.viewport_aspect <= 0.0 {
        return Err(ApplicationError::InvalidViewportAspect);
    }
    let panel = request.panel.validate().map_err(ApplicationError::Panel)?;
    request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
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
    let signal = diagnostic_signal(
        request.procedural_pattern,
        Vec2 { x: 0.5, y: 0.5 },
        request.time,
    );
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
    let panel_evaluator = request
        .optics
        .panel
        .evaluator()
        .map_err(ApplicationError::Panel)?;
    prepare_raster_with_signal(
        request.clone(),
        width,
        height,
        &|uv| diagnostic_signal(request.optics.procedural_pattern, uv, request.optics.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.optics.procedural_pattern,
                minimum,
                maximum,
                request.optics.time,
                panel_evaluator,
            )
        },
    )
}

pub fn evaluate_linear_optics(
    request: OpticalRequest,
    width: u16,
    height: u16,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    evaluate_optical_raster_with_signal(
        request.clone(),
        width,
        height,
        DiagnosticView::Composite,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
    )
}

fn evaluate_linear_optics_region(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    evaluate_optical_window_with_signal(
        request.clone(),
        RasterWindow::from_sensor_region(sensor, region),
        DiagnosticView::Composite,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
    )
}

/// Evaluates the modulation-free procedural spatial pass with the scalar CPU implementation.
///
/// This is an oracle for backend conformance tests. Product composition should select a
/// [`SpatialOpticalBackend`] at its platform boundary instead of calling this function.
pub fn evaluate_procedural_spatial_cpu_oracle(
    mut request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    request.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(1.0);
    evaluate_linear_optics_region(request, sensor, region).map(|raster| raster.pixels)
}

fn evaluate_procedural_optical_sensor_row(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    global_row: u16,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let raster = evaluate_optical_window_with_signal(
        request.clone(),
        RasterWindow {
            full_width: sensor.native_width,
            full_height: sensor.native_height,
            origin_x: region.origin_x,
            origin_y: global_row,
            width: region.width,
            height: 1,
        },
        DiagnosticView::Composite,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
    )?;
    Ok(raster.pixels)
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

#[derive(Clone, Debug, PartialEq)]
pub struct CapturedCameraRegion {
    pub raw: RawSensorRegion,
    pub developed: DevelopedCameraRegion,
}

pub fn capture_and_develop_procedural_region(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
) -> Result<CapturedCameraRegion, ApplicationError> {
    capture_and_develop_procedural_region_with_backend(
        request,
        sensor,
        development,
        requested_region,
        &CpuRawDevelopment,
    )
}

pub fn capture_and_develop_procedural_region_with_backend<B: RawDevelopmentBackend>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    backend: &B,
) -> Result<CapturedCameraRegion, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_procedural_region(shutter, sensor, evaluation_region)?;
    let raw = expose_raw_region(sensor, &exposure, identity, evaluation_region)
        .map_err(ApplicationError::Sensor)?;
    let developed = backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

/// Product compute composition with independent spatial-optics and RAW-development ports.
pub fn capture_and_develop_procedural_region_with_compute_backends<S, R>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    spatial_backend: &S,
    raw_backend: &R,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    S: SpatialOpticalBackend,
    R: RawDevelopmentBackend,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let source_is_static =
        request.optics.procedural_pattern != ProceduralTestPattern::AnimatedCheckerboard;
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_spatial_region_with_backend(
        shutter,
        sensor,
        evaluation_region,
        source_is_static,
        spatial_backend,
        |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
    )?;
    let raw = expose_raw_region(sensor, &exposure, identity, evaluation_region)
        .map_err(ApplicationError::Sensor)?;
    let developed = raw_backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

pub fn capture_and_develop_device_signal_region(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<CapturedCameraRegion, ApplicationError> {
    capture_and_develop_device_signal_region_with_backend(
        request,
        sensor,
        development,
        requested_region,
        signal,
        placement,
        &CpuRawDevelopment,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_with_backend<B: RawDevelopmentBackend>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
    backend: &B,
) -> Result<CapturedCameraRegion, ApplicationError> {
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure =
        integrate_device_signal_region(shutter, sensor, evaluation_region, signal, placement)?;
    let raw = expose_raw_region(sensor, &exposure, identity, evaluation_region)
        .map_err(ApplicationError::Sensor)?;
    let developed = backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_with_compute_backends<S, R>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
    spatial_backend: &S,
    raw_backend: &R,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    S: SpatialOpticalBackend,
    R: RawDevelopmentBackend,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let spatial_signal =
        prepare_device_signal_spatial_signal(request.optics.panel, signal, placement)?;
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_spatial_region_with_backend(
        shutter,
        sensor,
        evaluation_region,
        true,
        spatial_backend,
        |optics, region| {
            prepare_spatial_plan(
                optics,
                RasterWindow::from_sensor_region(sensor, region),
                spatial_signal.clone(),
            )
        },
    )?;
    let raw = expose_raw_region(sensor, &exposure, identity, evaluation_region)
        .map_err(ApplicationError::Sensor)?;
    let developed = raw_backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

/// Region-authoritative capture for animated device content. Every temporal and rolling-shutter
/// sample resolves the source at its exact rational time; tiled capture therefore cannot freeze
/// the source at the nominal frame time.
pub fn capture_and_develop_device_signal_region_sequence<F>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    placement: RasterPlacement,
    signal_at_time: F,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
{
    capture_and_develop_device_signal_region_sequence_with_backend(
        request,
        sensor,
        development,
        requested_region,
        placement,
        signal_at_time,
        &CpuRawDevelopment,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_sequence_with_backend<F, B>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    placement: RasterPlacement,
    mut signal_at_time: F,
    backend: &B,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
    B: RawDevelopmentBackend,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure = match shutter.readout {
        SensorReadout::Global => integrate_global_region(shutter, evaluation_region, |optics| {
            let signal = signal_at_time(optics.time)?;
            evaluate_linear_optics_region_from_prepared_device_signal(
                optics,
                sensor,
                evaluation_region,
                &signal,
                placement,
            )
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_region(
            shutter,
            sensor,
            evaluation_region,
            duration,
            direction,
            |optics, row| {
                let signal = signal_at_time(optics.time)?;
                evaluate_device_signal_optical_sensor_row(
                    optics,
                    sensor,
                    evaluation_region,
                    row,
                    &signal,
                    placement,
                )
            },
        ),
    }?;
    let raw = expose_raw_region(sensor, &exposure, identity, evaluation_region)
        .map_err(ApplicationError::Sensor)?;
    let developed = backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
}

#[allow(clippy::too_many_arguments)]
pub fn capture_and_develop_device_signal_region_sequence_with_compute_backends<F, S, R>(
    request: FrameCaptureRequest,
    sensor: SensorProfile,
    development: CameraDevelopment,
    requested_region: SensorRegion,
    placement: RasterPlacement,
    mut signal_at_time: F,
    spatial_backend: &S,
    raw_backend: &R,
) -> Result<CapturedCameraRegion, ApplicationError>
where
    F: FnMut(RationalTime) -> Result<Arc<PreparedDeviceSignalRaster>, ApplicationError>,
    S: SpatialOpticalBackend,
    R: RawDevelopmentBackend,
{
    let sensor = sensor.validate().map_err(ApplicationError::Sensor)?;
    let requested_region = requested_region
        .validate(sensor)
        .map_err(ApplicationError::Sensor)?;
    let evaluation_region = requested_region.expanded_for_demosaic(sensor);
    let (shutter, identity) = request.resolve()?;
    let exposure = integrate_spatial_region_with_backend(
        shutter,
        sensor,
        evaluation_region,
        false,
        spatial_backend,
        |optics, region| {
            let signal = signal_at_time(optics.time)?;
            prepare_device_signal_spatial_plan(optics, sensor, region, &signal, placement)
        },
    )?;
    let raw = expose_raw_region(sensor, &exposure, identity, evaluation_region)
        .map_err(ApplicationError::Sensor)?;
    let developed = raw_backend
        .develop_region(&raw, sensor, development)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    Ok(CapturedCameraRegion {
        raw,
        developed: crop_developed_region(developed, requested_region),
    })
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
    )?;
    if width == 0 || height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let pixel_count = usize::from(width) * usize::from(height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for sample in samples {
        let mut optics = request.optics.clone();
        optics.time = sample.time;
        optics.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(
            optics
                .panel
                .temporal_emission
                .average_gain(sample.start, sample.end)
                .map_err(ApplicationError::Panel)?,
        );
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
    finish_integrated_exposure(
        width,
        height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

fn integrate_procedural_region(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    match request.readout {
        SensorReadout::Global => integrate_global_region(request, region, |optics| {
            evaluate_linear_optics_region(optics, sensor, region)
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_region(
            request,
            sensor,
            region,
            duration,
            direction,
            |optics, row| evaluate_procedural_optical_sensor_row(optics, sensor, region, row),
        ),
    }
}

fn integrate_device_signal_region(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    signal: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    match request.readout {
        SensorReadout::Global => integrate_global_region(request, region, |optics| {
            evaluate_linear_optics_region_from_prepared_device_signal(
                optics, sensor, region, signal, placement,
            )
        }),
        SensorReadout::Rolling {
            duration,
            direction,
        } => integrate_rolling_region(
            request,
            sensor,
            region,
            duration,
            direction,
            |optics, row| {
                evaluate_device_signal_optical_sensor_row(
                    optics, sensor, region, row, signal, placement,
                )
            },
        ),
    }
}

fn integrate_spatial_region_with_backend<B, F>(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source_is_static: bool,
    backend: &B,
    mut plan_at: F,
) -> Result<IntegratedOpticalExposure, ApplicationError>
where
    B: SpatialOpticalBackend,
    F: FnMut(OpticalRequest, SensorRegion) -> Result<SpatialOpticalPlan, ApplicationError>,
{
    struct BatchSample {
        plan_index: usize,
        destination_offset: usize,
        expected_pixels: usize,
        weight_seconds: f64,
        temporal_gain: f32,
    }

    let can_reuse_spatial_samples = source_is_static
        && request.optics.camera.transform.keyframes.len() == 1
        && request.optics.camera.intrinsics.keyframes.len() == 1
        && request.optics.screen.keyframes.len() == 1;
    let mut plans = Vec::new();
    let mut batch_samples = Vec::new();
    let intern_plan =
        |plans: &mut Vec<SpatialOpticalPlan>, search_start: usize, plan: SpatialOpticalPlan| {
            if let Some(index) = plans[search_start..]
                .iter()
                .position(|candidate| candidate.has_identical_spatial_evaluation(&plan))
            {
                search_start + index
            } else {
                plans.push(plan);
                plans.len() - 1
            }
        };
    match request.readout {
        SensorReadout::Global => {
            let mut reused_plan_index = None;
            for sample in shutter_quadrature(
                request.optics.time,
                request.duration,
                request.temporal_samples,
            )? {
                let temporal_gain = request
                    .optics
                    .panel
                    .temporal_emission
                    .average_gain(sample.start, sample.end)
                    .map_err(ApplicationError::Panel)?;
                let mut optics = request.optics.clone();
                optics.time = sample.time;
                optics.panel_temporal_evaluation =
                    PanelTemporalEvaluation::ExposureAverage(temporal_gain);
                let plan_index = if can_reuse_spatial_samples {
                    if let Some(index) = reused_plan_index {
                        index
                    } else {
                        let index = intern_plan(&mut plans, 0, plan_at(optics, region)?);
                        reused_plan_index = Some(index);
                        index
                    }
                } else {
                    intern_plan(&mut plans, 0, plan_at(optics, region)?)
                };
                batch_samples.push(BatchSample {
                    plan_index,
                    destination_offset: 0,
                    expected_pixels: usize::from(region.width) * usize::from(region.height),
                    weight_seconds: sample.weight_seconds,
                    temporal_gain,
                });
            }
        }
        SensorReadout::Rolling {
            duration,
            direction,
        } => {
            if duration.numerator() <= 0 {
                return Err(ApplicationError::InvalidSensorReadout);
            }
            for local_row in 0..usize::from(region.height) {
                let row_plan_start = plans.len();
                let mut reused_plan_index = None;
                let global_row = usize::from(region.origin_y) + local_row;
                let row_center = rolling_row_center_time(
                    request.optics.time,
                    duration,
                    global_row,
                    usize::from(sensor.native_height),
                    direction,
                )?;
                for sample in
                    shutter_quadrature(row_center, request.duration, request.temporal_samples)?
                {
                    let temporal_gain = request
                        .optics
                        .panel
                        .temporal_emission
                        .average_gain(sample.start, sample.end)
                        .map_err(ApplicationError::Panel)?;
                    let mut optics = request.optics.clone();
                    optics.time = sample.time;
                    optics.panel_temporal_evaluation =
                        PanelTemporalEvaluation::ExposureAverage(temporal_gain);
                    let row_region = SensorRegion {
                        origin_x: region.origin_x,
                        origin_y: global_row as u16,
                        width: region.width,
                        height: 1,
                    };
                    let plan_index = if can_reuse_spatial_samples {
                        if let Some(index) = reused_plan_index {
                            index
                        } else {
                            let index = intern_plan(
                                &mut plans,
                                row_plan_start,
                                plan_at(optics, row_region)?,
                            );
                            reused_plan_index = Some(index);
                            index
                        }
                    } else {
                        intern_plan(&mut plans, row_plan_start, plan_at(optics, row_region)?)
                    };
                    batch_samples.push(BatchSample {
                        plan_index,
                        destination_offset: local_row * usize::from(region.width),
                        expected_pixels: usize::from(region.width),
                        weight_seconds: sample.weight_seconds,
                        temporal_gain,
                    });
                }
            }
        }
    }
    let batches = backend
        .evaluate_spatial_batch(&plans)
        .map_err(|error| ApplicationError::NativeBackend(error.to_string()))?;
    if batches.len() != plans.len() {
        return Err(ApplicationError::OpticalSampleRasterMismatch);
    }
    let mut accumulated =
        vec![[0.0_f64; 3]; usize::from(region.width) * usize::from(region.height)];
    for sample in batch_samples {
        let pixels = &batches[sample.plan_index];
        if pixels.len() != sample.expected_pixels {
            return Err(ApplicationError::OpticalSampleRasterMismatch);
        }
        for (index, pixel) in pixels.iter().enumerate() {
            let sum = &mut accumulated[sample.destination_offset + index];
            let scale = f64::from(sample.temporal_gain) * sample.weight_seconds;
            sum[0] += f64::from(pixel.acescg_irradiance.r) * scale;
            sum[1] += f64::from(pixel.acescg_irradiance.g) * scale;
            sum[2] += f64::from(pixel.acescg_irradiance.b) * scale;
        }
    }
    finish_integrated_exposure(
        region.width,
        region.height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

fn integrate_global_region(
    request: ShutterRequest,
    region: SensorRegion,
    mut optical_at_time: impl FnMut(OpticalRequest) -> Result<LinearOpticalRaster, ApplicationError>,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    let samples = shutter_quadrature(
        request.optics.time,
        request.duration,
        request.temporal_samples,
    )?;
    let pixel_count = usize::from(region.width) * usize::from(region.height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for sample in samples {
        let mut optics = request.optics.clone();
        optics.time = sample.time;
        optics.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(
            optics
                .panel
                .temporal_emission
                .average_gain(sample.start, sample.end)
                .map_err(ApplicationError::Panel)?,
        );
        let raster = optical_at_time(optics)?;
        for (sum, pixel) in accumulated.iter_mut().zip(raster.pixels) {
            sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
            sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
            sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
        }
    }
    finish_integrated_exposure(
        region.width,
        region.height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

#[allow(clippy::too_many_arguments)]
fn integrate_rolling_region(
    request: ShutterRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    readout_duration: RationalTime,
    direction: RollingDirection,
    mut optical_row_at_time: impl FnMut(
        OpticalRequest,
        u16,
    ) -> Result<Vec<LinearOpticalPixel>, ApplicationError>,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    if readout_duration.numerator() <= 0 {
        return Err(ApplicationError::InvalidSensorReadout);
    }
    let mut accumulated =
        vec![[0.0_f64; 3]; usize::from(region.width) * usize::from(region.height)];
    for local_row in 0..usize::from(region.height) {
        let global_row = usize::from(region.origin_y) + local_row;
        let row_center = rolling_row_center_time(
            request.optics.time,
            readout_duration,
            global_row,
            usize::from(sensor.native_height),
            direction,
        )?;
        let samples = shutter_quadrature(row_center, request.duration, request.temporal_samples)?;
        for sample in samples {
            let mut optics = request.optics.clone();
            optics.time = sample.time;
            optics.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(
                optics
                    .panel
                    .temporal_emission
                    .average_gain(sample.start, sample.end)
                    .map_err(ApplicationError::Panel)?,
            );
            let row = optical_row_at_time(optics, global_row as u16)?;
            if row.len() != usize::from(region.width) {
                return Err(ApplicationError::OpticalSampleRasterMismatch);
            }
            for (column, pixel) in row.into_iter().enumerate() {
                let sum = &mut accumulated[local_row * usize::from(region.width) + column];
                sum[0] += f64::from(pixel.acescg_irradiance.r) * sample.weight_seconds;
                sum[1] += f64::from(pixel.acescg_irradiance.g) * sample.weight_seconds;
                sum[2] += f64::from(pixel.acescg_irradiance.b) * sample.weight_seconds;
            }
        }
    }
    finish_integrated_exposure(
        region.width,
        region.height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
}

fn crop_developed_region(
    developed: DevelopedCameraRegion,
    requested: SensorRegion,
) -> DevelopedCameraRegion {
    if developed.region == requested {
        return developed;
    }
    let offset_x = usize::from(requested.origin_x - developed.region.origin_x);
    let offset_y = usize::from(requested.origin_y - developed.region.origin_y);
    let source_width = usize::from(developed.region.width);
    let requested_width = usize::from(requested.width);
    let mut acescg = Vec::with_capacity(requested_width * usize::from(requested.height));
    for row in 0..usize::from(requested.height) {
        let start = (offset_y + row) * source_width + offset_x;
        acescg.extend_from_slice(&developed.acescg[start..start + requested_width]);
    }
    DevelopedCameraRegion {
        sensor_width: developed.sensor_width,
        sensor_height: developed.sensor_height,
        region: requested,
        acescg,
    }
}

fn finish_integrated_exposure(
    width: u16,
    height: u16,
    duration: RationalTime,
    neutral_density_stops: f32,
    accumulated: Vec<[f64; 3]>,
) -> Result<IntegratedOpticalExposure, ApplicationError> {
    let duration_seconds = duration.as_seconds();
    let photometric_scale = 2.0_f64.powf(-f64::from(neutral_density_stops));
    let acescg_illuminance_seconds = accumulated
        .into_iter()
        .map(|sum| {
            LinearRgb::new(
                (sum[0] * photometric_scale) as f32,
                (sum[1] * photometric_scale) as f32,
                (sum[2] * photometric_scale) as f32,
            )
        })
        .collect();
    let exposure = IntegratedOpticalExposure {
        width: u32::from(width),
        height: u32::from(height),
        duration_seconds: duration_seconds as f32,
        acescg_illuminance_seconds,
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
                shutter_quadrature(row_center, request.duration, request.temporal_samples)?,
            ))
        })
        .collect::<Result<Vec<_>, ApplicationError>>()?;
    let pixel_count = usize::from(width) * usize::from(height);
    let mut accumulated = vec![[0.0_f64; 3]; pixel_count];
    for (row, samples) in row_schedules {
        for sample in samples {
            let mut optics = request.optics.clone();
            optics.time = sample.time;
            optics.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(
                optics
                    .panel
                    .temporal_emission
                    .average_gain(sample.start, sample.end)
                    .map_err(ApplicationError::Panel)?,
            );
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
    finish_integrated_exposure(
        width,
        height,
        request.duration,
        request.neutral_density_stops,
        accumulated,
    )
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
    start: RationalTime,
    time: RationalTime,
    end: RationalTime,
    weight_seconds: f64,
}

fn shutter_quadrature(
    center: RationalTime,
    duration: RationalTime,
    temporal_samples: u16,
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
    let mut boundaries = Vec::with_capacity(usize::from(temporal_samples) + 1);
    for index in 0..=temporal_samples {
        let offset = duration
            .checked_mul_ratio(i64::from(index), u32::from(temporal_samples))
            .map_err(ApplicationError::Time)?;
        boundaries.push(open.checked_add(offset).map_err(ApplicationError::Time)?);
    }
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
                start: interval[0],
                time: midpoint,
                end: interval[1],
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
    let panel_evaluator = request
        .optics
        .panel
        .evaluator()
        .map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(source, panel_evaluator);
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
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

pub fn prepare_raster_from_prepared_device_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<PreparedRaster, ApplicationError> {
    let source_raster = source.raster_size();
    let panel_evaluator = request
        .optics
        .panel
        .evaluator()
        .map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
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
                    source.source.sample_native_pixel(source_uv)
                })
        },
        &|minimum, maximum| {
            sample_placed_area(
                &source.integral,
                &emission_integral,
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
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(source, panel_evaluator);
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
                &emission_integral,
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
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
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
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

fn evaluate_linear_optics_region_from_prepared_device_signal(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<LinearOpticalRaster, ApplicationError> {
    let source_raster = source.raster_size();
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
    let device_raster = [request.panel.native_width, request.panel.native_height];
    evaluate_optical_window_with_signal(
        request,
        RasterWindow::from_sensor_region(sensor, region),
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
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )
}

/// Evaluates the modulation-free raster spatial pass with the scalar CPU implementation.
///
/// This is retained only as an oracle for backend conformance tests.
pub fn evaluate_device_signal_spatial_cpu_oracle(
    mut request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    request.panel_temporal_evaluation = PanelTemporalEvaluation::ExposureAverage(1.0);
    evaluate_linear_optics_region_from_prepared_device_signal(
        request, sensor, region, source, placement,
    )
    .map(|raster| raster.pixels)
}

fn evaluate_device_signal_optical_sensor_row(
    request: OpticalRequest,
    sensor: SensorProfile,
    region: SensorRegion,
    global_row: u16,
    source: &PreparedDeviceSignalRaster,
    placement: RasterPlacement,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let source_raster = source.raster_size();
    let device_raster = [request.panel.native_width, request.panel.native_height];
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
    let raster = evaluate_optical_window_with_signal(
        request,
        RasterWindow {
            full_width: sensor.native_width,
            full_height: sensor.native_height,
            origin_x: region.origin_x,
            origin_y: global_row,
            width: region.width,
            height: 1,
        },
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
                &emission_integral,
                source_raster,
                device_raster,
                placement,
                minimum,
                maximum,
            )
        },
    )?;
    Ok(raster.pixels)
}

fn evaluate_procedural_optical_row(
    request: OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    evaluate_optical_row_with_signal(
        request.clone(),
        width,
        height,
        row,
        &|uv| diagnostic_signal(request.procedural_pattern, uv, request.time),
        &|minimum, maximum| {
            diagnostic_area_signal(
                request.procedural_pattern,
                minimum,
                maximum,
                request.time,
                panel_evaluator,
            )
        },
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
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let emission_integral = linear_emission_integral(&source.source, panel_evaluator);
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
                &emission_integral,
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
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> Result<Vec<LinearOpticalPixel>, ApplicationError> {
    if width == 0 || height == 0 || row >= usize::from(height) {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let frame = prepare_frame(request.clone())?;
    let raster_aspect = f32::from(width) / f32::from(height);
    if !raster_represents_viewport(width, height, frame.viewport_aspect) {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect,
            viewport_aspect: frame.viewport_aspect,
        });
    }
    let evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let cover_evaluator = request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let temporal_gain = panel_temporal_gain(&request, evaluator)?;
    macro_rules! evaluate_row {
        ($sample_count:literal) => {
            (0..usize::from(width))
                .map(|column| {
                    evaluate_optical_pixel::<$sample_count>(
                        &frame,
                        &request,
                        width,
                        height,
                        row,
                        column,
                        DiagnosticView::Composite,
                        evaluator,
                        temporal_gain,
                        cover_evaluator,
                        signal_at,
                        signal_area,
                    )
                })
                .collect()
        };
    }
    Ok(
        match aperture_sample_count(frame.camera, frame.screen, request.panel, width) {
            16 => evaluate_row!(16),
            32 => evaluate_row!(32),
            64 => evaluate_row!(64),
            128 => evaluate_row!(128),
            _ => unreachable!("aperture sample policy only emits supported quality levels"),
        },
    )
}

fn prepare_raster_with_signal(
    request: SimulationRequest,
    width: u16,
    height: u16,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
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
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> Result<LinearOpticalRaster, ApplicationError> {
    evaluate_optical_window_with_signal(
        request,
        RasterWindow::full(width, height),
        view,
        signal_at,
        signal_area,
    )
}

fn evaluate_optical_window_with_signal(
    request: OpticalRequest,
    raster: RasterWindow,
    view: DiagnosticView,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> Result<LinearOpticalRaster, ApplicationError> {
    if raster.width == 0 || raster.height == 0 {
        return Err(ApplicationError::EmptyPreviewRaster);
    }
    let mut frame = prepare_frame(request.clone())?;
    let raster_aspect = f32::from(raster.full_width) / f32::from(raster.full_height);
    if !raster_represents_viewport(raster.full_width, raster.full_height, frame.viewport_aspect) {
        return Err(ApplicationError::RasterViewportAspectMismatch {
            raster_aspect,
            viewport_aspect: frame.viewport_aspect,
        });
    }
    frame.representative_signal = signal_at(Vec2 { x: 0.5, y: 0.5 });
    let panel_evaluator = request.panel.evaluator().map_err(ApplicationError::Panel)?;
    let cover_evaluator = request
        .cover
        .evaluator(request.environment)
        .map_err(ApplicationError::Cover)?;
    let panel_temporal_gain = panel_temporal_gain(&request, panel_evaluator)?;
    let representative = request.panel.emitted_radiance(frame.representative_signal);
    frame.representative_emission = LinearRgb::new(
        representative.r * panel_temporal_gain,
        representative.g * panel_temporal_gain,
        representative.b * panel_temporal_gain,
    );
    let preview_scale_percent =
        projected_device_pixel_width(&frame, request.panel, raster.full_width)
            .ok_or(ApplicationError::ViewRayMissesPanel)?
            * 100.0;
    let subpixels_resolved_at_center = optical_footprint_device_pixels(
        &frame,
        request.panel,
        raster.full_width,
        raster.full_height,
    )
    .is_some_and(|footprint| footprint[0] <= 1.0 / 3.0 && footprint[1] <= 1.0);
    let mut pixels = vec![
        LinearOpticalPixel {
            acescg_irradiance: LinearRgb::new(0.0, 0.0, 0.0),
            on_panel: false,
        };
        usize::from(raster.width) * usize::from(raster.height)
    ];
    match aperture_sample_count(frame.camera, frame.screen, request.panel, raster.full_width) {
        16 => evaluate_optical_pixels::<16>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        32 => evaluate_optical_pixels::<32>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        64 => evaluate_optical_pixels::<64>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        128 => evaluate_optical_pixels::<128>(
            &mut pixels,
            &frame,
            &request,
            raster,
            view,
            panel_evaluator,
            panel_temporal_gain,
            cover_evaluator,
            signal_at,
            signal_area,
        ),
        _ => unreachable!("aperture sample policy only emits supported quality levels"),
    }
    let inspection_field_meters = request.inspection.map(|region| {
        [
            (region.max.x - region.min.x) * request.panel.active_width.0,
            (region.max.y - region.min.y) * request.panel.active_height.0,
        ]
    });
    Ok(LinearOpticalRaster {
        frame,
        width: raster.width,
        height: raster.height,
        pixels,
        projected_device_pixel_percent: preview_scale_percent,
        inspection_field_meters,
        subpixels_resolved_at_center,
    })
}

fn panel_temporal_gain(
    request: &OpticalRequest,
    evaluator: ValidatedPanelEvaluator,
) -> Result<f32, ApplicationError> {
    match request.panel_temporal_evaluation {
        PanelTemporalEvaluation::Instantaneous => evaluator
            .temporal_gain(request.time)
            .map_err(ApplicationError::Panel),
        PanelTemporalEvaluation::ExposureAverage(gain) if gain.is_finite() && gain >= 0.0 => {
            Ok(gain)
        }
        PanelTemporalEvaluation::ExposureAverage(_) => Err(ApplicationError::InvalidShutter),
    }
}

fn raster_represents_viewport(width: u16, height: u16, viewport_aspect: f32) -> bool {
    let expected_width = f32::from(height) * viewport_aspect;
    (f32::from(width) - expected_width).abs() <= 0.5 + f32::EPSILON
}

#[allow(clippy::too_many_arguments)]
fn evaluate_optical_pixels<const SAMPLE_COUNT: usize>(
    pixels: &mut [LinearOpticalPixel],
    frame: &PreparedFrame,
    request: &OpticalRequest,
    raster: RasterWindow,
    view: DiagnosticView,
    panel_evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    cover_evaluator: ValidatedCoverEvaluator,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) {
    pixels
        .par_chunks_mut(usize::from(raster.width))
        .enumerate()
        .for_each(|(row, output_row)| {
            for (column, output) in output_row.iter_mut().enumerate() {
                *output = evaluate_optical_pixel::<SAMPLE_COUNT>(
                    frame,
                    request,
                    raster.full_width,
                    raster.full_height,
                    row + usize::from(raster.origin_y),
                    column + usize::from(raster.origin_x),
                    view,
                    panel_evaluator,
                    panel_temporal_gain,
                    cover_evaluator,
                    signal_at,
                    signal_area,
                );
            }
        });
}

fn aperture_sample_count(
    camera: CameraSample,
    screen: ScreenSample,
    panel: LcdProfile,
    raster_width: u16,
) -> usize {
    let forward = Vec3 {
        x: camera.target.x - camera.position.x,
        y: camera.target.y - camera.position.y,
        z: camera.target.z - camera.position.z,
    };
    let focal_length_meters = camera.focal_length.0 * 0.001;
    let sensor_width_meters = camera.sensor_width.0 * 0.001;
    let aperture_radius = focal_length_meters / (2.0 * camera.f_stop);
    let half_width = panel.active_width.0 * 0.5;
    let half_height = panel.active_height.0 * 0.5;
    let blur_radius_pixels = [
        Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        },
        Vec3 {
            x: -half_width,
            y: -half_height,
            z: 0.0,
        },
        Vec3 {
            x: half_width,
            y: -half_height,
            z: 0.0,
        },
        Vec3 {
            x: -half_width,
            y: half_height,
            z: 0.0,
        },
        Vec3 {
            x: half_width,
            y: half_height,
            z: 0.0,
        },
    ]
    .into_iter()
    .map(|local| screen.local_to_world(local))
    .map(|point| Vec3 {
        x: point.x - camera.position.x,
        y: point.y - camera.position.y,
        z: point.z - camera.position.z,
    })
    .map(|offset| {
        let distance = (offset.x * forward.x + offset.y * forward.y + offset.z * forward.z)
            .abs()
            .max(0.001);
        let relative_defocus = (1.0 - distance / camera.focus_distance.0).abs();
        let projected_pixel_width =
            distance * sensor_width_meters / focal_length_meters / f32::from(raster_width);
        aperture_radius * relative_defocus / projected_pixel_width
    })
    .fold(0.0_f32, f32::max);
    if blur_radius_pixels < 0.5 {
        16
    } else if blur_radius_pixels < 1.5 {
        32
    } else if blur_radius_pixels < 4.0 {
        64
    } else {
        128
    }
}

#[allow(clippy::too_many_arguments)]
fn evaluate_optical_pixel<const SAMPLE_COUNT: usize>(
    frame: &PreparedFrame,
    request: &OpticalRequest,
    width: u16,
    height: u16,
    row: usize,
    column: usize,
    view: DiagnosticView,
    panel_evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    cover_evaluator: ValidatedCoverEvaluator,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
) -> LinearOpticalPixel {
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
        panel_uv_aperture_samples_with_count::<SAMPLE_COUNT>(
            frame.camera,
            frame.screen,
            request.panel.active_width,
            request.panel.active_height,
            viewport_ndc,
        )
    };
    let pixel_center_ndc = Vec2 {
        x: (column as f32 + 0.5) / f32::from(width) * 2.0 - 1.0,
        y: (row as f32 + 0.5) / f32::from(height) * 2.0 - 1.0,
    };
    let psf_radius = approximate_psf_radius_pixels(frame.camera, width, pixel_center_ndc);
    let minimum = 0.001 - psf_radius;
    let maximum = 0.999 + psf_radius;
    let footprint = [
        Vec2 {
            x: minimum,
            y: minimum,
        },
        Vec2 {
            x: maximum,
            y: minimum,
        },
        Vec2 {
            x: minimum,
            y: maximum,
        },
        Vec2 {
            x: maximum,
            y: maximum,
        },
    ]
    .map(trace);
    if !subpixels_resolved_for_samples(&footprint, request.panel, cover_evaluator, view) {
        let integrated = integrate_aperture_samples(
            &footprint,
            view,
            request.panel,
            panel_evaluator,
            panel_temporal_gain,
            signal_at,
            signal_area,
            cover_evaluator,
        );
        return integrated;
    }
    let aperture_samples = RESOLVED_SENSOR_BOX
        .map(|offset| expand_sensor_footprint(offset, psf_radius))
        .map(trace);
    integrate_aperture_samples(
        &aperture_samples,
        view,
        request.panel,
        panel_evaluator,
        panel_temporal_gain,
        signal_at,
        signal_area,
        cover_evaluator,
    )
}

fn expand_sensor_footprint(offset: Vec2, psf_radius_pixels: f32) -> Vec2 {
    let disk = concentric_disk_sample(offset);
    Vec2 {
        x: offset.x + disk.x * psf_radius_pixels,
        y: offset.y + disk.y * psf_radius_pixels,
    }
}

fn concentric_disk_sample(sample: Vec2) -> Vec2 {
    let x = 2.0 * sample.x - 1.0;
    let y = 2.0 * sample.y - 1.0;
    if x == 0.0 && y == 0.0 {
        return Vec2 { x: 0.0, y: 0.0 };
    }
    let (radius, angle) = if x.abs() > y.abs() {
        (x, core::f32::consts::FRAC_PI_4 * (y / x))
    } else {
        (
            y,
            core::f32::consts::FRAC_PI_2 - core::f32::consts::FRAC_PI_4 * (x / y),
        )
    };
    Vec2 {
        x: radius * angle.cos(),
        y: radius * angle.sin(),
    }
}

fn approximate_psf_radius_pixels(
    camera: CameraSample,
    raster_width: u16,
    viewport_ndc: Vec2,
) -> f32 {
    const GREEN_WAVELENGTH_MM: f32 = 0.000_550;
    let photosite_pitch_mm = camera.sensor_width.0 / f32::from(raster_width);
    let airy_radius_mm = 1.22 * GREEN_WAVELENGTH_MM * camera.f_stop;
    let field_amount =
        ((viewport_ndc.x * viewport_ndc.x + viewport_ndc.y * viewport_ndc.y) * 0.5).clamp(0.0, 1.0);
    let lens_softness_micrometers = camera.lens.center_softness_micrometers
        + (camera.lens.edge_softness_micrometers - camera.lens.center_softness_micrometers)
            * field_amount;
    let lens_softness_mm = lens_softness_micrometers * 0.001;
    (lens_softness_mm + airy_radius_mm) / photosite_pitch_mm
}

#[allow(clippy::too_many_arguments)]
fn integrate_aperture_samples<const SAMPLE_COUNT: usize>(
    spatial_samples: &[[OpticalSample; SAMPLE_COUNT]],
    view: DiagnosticView,
    panel: LcdProfile,
    evaluator: ValidatedPanelEvaluator,
    panel_temporal_gain: f32,
    signal_at: &(dyn Fn(Vec2) -> DeviceRgb + Sync),
    signal_area: &(dyn Fn(Vec2, Vec2) -> AreaSignalSample + Sync),
    cover: ValidatedCoverEvaluator,
) -> LinearOpticalPixel {
    let subpixels_resolved = subpixels_resolved_for_samples(spatial_samples, panel, cover, view);
    let mut sum = LinearRgb::new(0.0, 0.0, 0.0);
    let mut on_panel = false;
    let reflected = reflected_environment_average(spatial_samples, view, cover);
    if !subpixels_resolved {
        for aperture in 0..SAMPLE_COUNT {
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
                    let Some(uv) = transmitted_panel_uv(cover, optical, panel, view, channel)
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
                    ) * cover_transmission_channel(cover, optical, view, channel);
                    count += 1;
                }
                if count == 0 {
                    continue;
                }
                on_panel = true;
                let signal = signal_area(minimum, maximum);
                let value = if view == DiagnosticView::DeviceSignal {
                    [
                        signal.device_code.r,
                        signal.device_code.g,
                        signal.device_code.b,
                    ][channel]
                } else {
                    evaluator.linear_native_channel_over_device_rect(
                        [
                            signal.linear_native_emission.r,
                            signal.linear_native_emission.g,
                            signal.linear_native_emission.b,
                        ][channel],
                        Vec2 {
                            x: minimum.x * panel.native_width as f32,
                            y: minimum.y * panel.native_height as f32,
                        },
                        Vec2 {
                            x: maximum.x * panel.native_width as f32,
                            y: maximum.y * panel.native_height as f32,
                        },
                        channel,
                    )
                };
                let contribution = value * weight_sum / spatial_samples.len() as f32;
                match channel {
                    0 => sum.r += contribution,
                    1 => sum.g += contribution,
                    _ => sum.b += contribution,
                }
            }
        }
        let scale = 1.0 / SAMPLE_COUNT as f32;
        let native_average = LinearRgb::new(sum.r * scale, sum.g * scale, sum.b * scale);
        return LinearOpticalPixel {
            acescg_irradiance: if view == DiagnosticView::DeviceSignal {
                native_average
            } else {
                let emitted = evaluator.native_to_acescg(native_average);
                LinearRgb::new(
                    emitted.r + reflected.r,
                    emitted.g + reflected.g,
                    emitted.b + reflected.b,
                )
            },
            on_panel,
        };
    }
    for optical_sample in spatial_samples.iter().flatten() {
        for channel in 0..3 {
            let Some(uv) = transmitted_panel_uv(cover, *optical_sample, panel, view, channel)
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
            let weighted =
                weighted * cover_transmission_channel(cover, *optical_sample, view, channel);
            match channel {
                0 => sum.r += weighted,
                1 => sum.g += weighted,
                _ => sum.b += weighted,
            }
        }
    }
    let scale = 1.0 / (SAMPLE_COUNT * spatial_samples.len()) as f32;
    let native_average = LinearRgb::new(sum.r * scale, sum.g * scale, sum.b * scale);
    let average = if view == DiagnosticView::DeviceSignal {
        native_average
    } else {
        let emitted = evaluator.native_to_acescg(native_average);
        LinearRgb::new(
            emitted.r + reflected.r,
            emitted.g + reflected.g,
            emitted.b + reflected.b,
        )
    };
    LinearOpticalPixel {
        acescg_irradiance: average,
        on_panel,
    }
}

fn cover_transmission_channel(
    cover: ValidatedCoverEvaluator,
    optical: OpticalSample,
    view: DiagnosticView,
    channel: usize,
) -> f32 {
    if view != DiagnosticView::Composite {
        return 1.0;
    }
    let transmission = cover.transmission(optical.emission_cosine[channel]);
    [transmission.r, transmission.g, transmission.b][channel]
}

fn transmitted_panel_uv(
    cover: ValidatedCoverEvaluator,
    optical: OpticalSample,
    panel: LcdProfile,
    view: DiagnosticView,
    channel: usize,
) -> Option<Vec2> {
    let uv = optical.panel_uv[channel]?;
    if view != DiagnosticView::Composite {
        return Some(uv);
    }
    let direction = optical.reflection_direction_local[channel]?;
    let offset = cover.transmitted_lateral_offset_meters([direction.x, direction.y, direction.z]);
    Some(Vec2 {
        x: uv.x + offset[0] / panel.active_width.0,
        y: uv.y - offset[1] / panel.active_height.0,
    })
}

fn reflected_environment_average<const SAMPLE_COUNT: usize>(
    spatial_samples: &[[OpticalSample; SAMPLE_COUNT]],
    view: DiagnosticView,
    cover: ValidatedCoverEvaluator,
) -> LinearRgb {
    if view != DiagnosticView::Composite {
        return LinearRgb::new(0.0, 0.0, 0.0);
    }
    let mut sum = [0.0_f32; 3];
    for optical in spatial_samples.iter().flatten() {
        for channel in 0..3 {
            let Some(_uv) = optical.panel_uv[channel]
                .filter(|uv| (0.0..=1.0).contains(&uv.x) && (0.0..=1.0).contains(&uv.y))
            else {
                continue;
            };
            let Some(direction) = optical.reflection_direction_local[channel] else {
                continue;
            };
            let reflected = cover.reflected_illuminance(CoverSurfaceSample {
                view_cosine: optical.emission_cosine[channel],
                reflection_direction_local: [direction.x, direction.y, direction.z],
                lens_irradiance_weight: LinearRgb::new(
                    optical.irradiance_weight[0],
                    optical.irradiance_weight[1],
                    optical.irradiance_weight[2],
                ),
            });
            sum[channel] += [reflected.r, reflected.g, reflected.b][channel];
        }
    }
    let scale = 1.0 / (SAMPLE_COUNT * spatial_samples.len()) as f32;
    LinearRgb::new(sum[0] * scale, sum[1] * scale, sum[2] * scale)
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

fn subpixels_resolved_for_samples<const SAMPLE_COUNT: usize>(
    spatial_samples: &[[OpticalSample; SAMPLE_COUNT]],
    panel: LcdProfile,
    cover: ValidatedCoverEvaluator,
    view: DiagnosticView,
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
            .filter_map(|sample| transmitted_panel_uv(cover, *sample, panel, view, channel))
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
pub fn diagnostic_signal(
    pattern: ProceduralTestPattern,
    uv: Vec2,
    time: RationalTime,
) -> DeviceRgb {
    match pattern {
        ProceduralTestPattern::AnimatedCheckerboard => checkerboard_signal(uv, time),
        ProceduralTestPattern::EyeChart => eye_chart_signal(uv),
        ProceduralTestPattern::PhotometricDeviceScale => photometric_device_scale_signal(uv),
    }
}

fn photometric_device_scale_signal(uv: Vec2) -> DeviceRgb {
    let patch = ((uv.x.clamp(0.0, 1.0 - f32::EPSILON) * PHOTOMETRIC_DEVICE_CODES.len() as f32)
        .floor() as usize)
        .min(PHOTOMETRIC_DEVICE_CODES.len() - 1);
    let code = PHOTOMETRIC_DEVICE_CODES[patch];
    DeviceRgb::new(code, code, code)
}

fn checkerboard_signal(uv: Vec2, time: RationalTime) -> DeviceRgb {
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

fn eye_chart_signal(uv: Vec2) -> DeviceRgb {
    const ROWS: [(f32, f32, u8); 7] = [
        (0.14, 0.18, 1),
        (0.31, 0.13, 2),
        (0.45, 0.095, 3),
        (0.57, 0.072, 4),
        (0.67, 0.055, 5),
        (0.76, 0.043, 6),
        (0.84, 0.034, 7),
    ];
    for (row, (center_y, size, count)) in ROWS.into_iter().enumerate() {
        let spacing = size * 1.45;
        let first_x = 0.5 - spacing * (f32::from(count) - 1.0) * 0.5;
        for column in 0..count {
            let center_x = first_x + spacing * f32::from(column);
            let mut local_x = (uv.x - center_x) / size;
            let mut local_y = (uv.y - center_y) / size;
            match (row + usize::from(column)) % 4 {
                1 => (local_x, local_y) = (-local_y, local_x),
                2 => (local_x, local_y) = (-local_x, -local_y),
                3 => (local_x, local_y) = (local_y, -local_x),
                _ => {}
            }
            let vertical = (-0.5..=-0.28).contains(&local_x) && (-0.5..=0.5).contains(&local_y);
            let horizontal = (-0.5..=0.5).contains(&local_x)
                && ((-0.5..=-0.30).contains(&local_y)
                    || (-0.10..=0.10).contains(&local_y)
                    || (0.30..=0.5).contains(&local_y));
            if vertical || horizontal {
                return DeviceRgb::BLACK;
            }
        }
    }
    DeviceRgb::WHITE
}

fn diagnostic_area_signal(
    pattern: ProceduralTestPattern,
    minimum: Vec2,
    maximum: Vec2,
    time: RationalTime,
    evaluator: ValidatedPanelEvaluator,
) -> AreaSignalSample {
    const OFFSETS: [f32; 4] = [0.125, 0.375, 0.625, 0.875];
    let mut sum = DeviceRgb::BLACK;
    let mut linear_sum = LinearRgb::new(0.0, 0.0, 0.0);
    for y in OFFSETS {
        for x in OFFSETS {
            let uv = Vec2 {
                x: minimum.x + (maximum.x - minimum.x) * x,
                y: minimum.y + (maximum.y - minimum.y) * y,
            };
            let value = diagnostic_signal(pattern, uv, time);
            sum.r += value.r;
            sum.g += value.g;
            sum.b += value.b;
            linear_sum.r += evaluator.native_channel(value, 0);
            linear_sum.g += evaluator.native_channel(value, 1);
            linear_sum.b += evaluator.native_channel(value, 2);
        }
    }
    AreaSignalSample {
        device_code: DeviceRgb::new(sum.r / 16.0, sum.g / 16.0, sum.b / 16.0),
        linear_native_emission: LinearRgb::new(
            linear_sum.r / 16.0,
            linear_sum.g / 16.0,
            linear_sum.b / 16.0,
        ),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ApplicationError {
    InvalidViewportAspect,
    InvalidPreviewExposure,
    InvalidShutter,
    InvalidSensorReadout,
    InvalidOpticalAttenuation,
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
    MediaSampleUnavailable,
    AlphaAssociationUnresolved,
    Color(ColorError),
    Panel(PanelError),
    Cover(CoverError),
    Geometry(GeometryError),
    Sensor(SensorError),
    CameraDevelopment(CameraDevelopmentError),
    NativeBackend(String),
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
                "shutter duration must be positive and motion samples must be in [1, 64]",
            ),
            Self::InvalidSensorReadout => formatter.write_str(
                "sensor readout duration and row coordinates must define a valid shutter interval",
            ),
            Self::InvalidOpticalAttenuation => formatter
                .write_str("neutral-density attenuation must be finite and in [0, 16] stops"),
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
            Self::MediaSampleUnavailable => {
                formatter.write_str("media sample is unavailable at the requested exact time")
            }
            Self::AlphaAssociationUnresolved => formatter.write_str(
                "alpha metadata does not identify Straight or Premultiplied association",
            ),
            Self::Color(error) => write!(formatter, "invalid color transform: {error}"),
            Self::Panel(error) => write!(formatter, "invalid panel: {error}"),
            Self::Cover(error) => write!(formatter, "invalid optical cover: {error}"),
            Self::Geometry(error) => write!(formatter, "invalid camera: {error}"),
            Self::Sensor(error) => write!(formatter, "invalid sensor capture: {error}"),
            Self::CameraDevelopment(error) => write!(formatter, "camera development: {error}"),
            Self::NativeBackend(error) => write!(formatter, "native compute backend: {error}"),
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
    use screen_cover::{COVER_GLASS_PRESETS, ENVIRONMENT_PRESETS, cover_glass_preset};
    use screen_geometry::lens_preset;
    use screen_panel::{AnalyticBanding, PanelTemporalEmission};
    use screen_panel::{DEVICE_PRESETS, PanelColorimetry, StripeLayout};
    use std::collections::HashSet;
    use std::convert::Infallible;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct UnitSpatialBackend {
        last_batch_size: AtomicUsize,
    }

    impl SpatialOpticalBackend for UnitSpatialBackend {
        type Error = Infallible;

        fn evaluate_spatial(
            &self,
            plan: &SpatialOpticalPlan,
        ) -> Result<Vec<LinearOpticalPixel>, Self::Error> {
            Ok(vec![
                LinearOpticalPixel {
                    acescg_irradiance: LinearRgb::new(1.0, 1.0, 1.0),
                    on_panel: true,
                };
                usize::from(plan.raster.width)
                    * usize::from(plan.raster.height)
            ])
        }

        fn evaluate_spatial_batch(
            &self,
            plans: &[SpatialOpticalPlan],
        ) -> Result<Vec<Vec<LinearOpticalPixel>>, Self::Error> {
            self.last_batch_size.store(plans.len(), Ordering::Relaxed);
            plans
                .iter()
                .map(|plan| self.evaluate_spatial(plan))
                .collect()
        }
    }

    fn request() -> SimulationRequest {
        SimulationRequest {
            optics: OpticalRequest {
                time: RationalTime::new(24, 24).expect("valid time"),
                panel_temporal_evaluation: PanelTemporalEvaluation::Instantaneous,
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
                cover: CoverGlassProfile::NEUTRAL,
                environment: ProceduralEnvironment::DARK,
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
                procedural_pattern: ProceduralTestPattern::AnimatedCheckerboard,
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
    fn spatial_plan_is_complete_and_excludes_display_modulation() {
        let mut optics = request().optics;
        optics.viewport_aspect = 1.0;
        optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        optics.panel.temporal_emission = PanelTemporalEmission::clean_lcd();
        optics.panel.temporal_emission.analytic_banding.amount = 1.0;
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let plan = prepare_procedural_spatial_plan(optics, sensor, SensorRegion::full(sensor))
            .expect("valid spatial plan");
        assert_eq!(plan.raster.width, 8);
        assert_eq!(plan.raster.height, 8);
        assert!(matches!(plan.aperture_sample_count, 16 | 32 | 64 | 128));
        assert!(matches!(
            plan.signal,
            SpatialSignalPlan::Procedural {
                pattern: ProceduralTestPattern::AnimatedCheckerboard,
                ..
            }
        ));
        assert!(
            plan.panel_native_to_acescg
                .into_iter()
                .flatten()
                .all(f32::is_finite)
        );
    }

    #[test]
    fn spatial_batch_applies_analytic_temporal_gain_exactly_once() {
        let mut optics = request().optics;
        optics.panel.temporal_emission = PanelTemporalEmission::continuous();
        optics.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 120).unwrap(),
            on_duration: RationalTime::new(1, 240).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
            amount: 0.6,
        };
        let duration = RationalTime::new(1, 48).unwrap();
        let half = RationalTime::new(1, 96).unwrap();
        let open = optics.time.checked_sub(half).unwrap();
        let close = optics.time.checked_add(half).unwrap();
        let expected_gain = optics
            .panel
            .temporal_emission
            .average_gain(open, close)
            .unwrap();
        let shutter = ShutterRequest {
            optics,
            duration,
            temporal_samples: 8,
            readout: SensorReadout::Global,
            neutral_density_stops: 0.0,
        };
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let exposure = integrate_spatial_region_with_backend(
            shutter,
            sensor,
            region,
            false,
            &backend,
            |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
        )
        .unwrap();
        assert_eq!(backend.last_batch_size.load(Ordering::Relaxed), 8);
        let expected = duration.as_seconds() as f32 * expected_gain;
        for pixel in exposure.acescg_illuminance_seconds {
            assert!((pixel.r - expected).abs() <= 2.0e-7);
            assert!((pixel.g - expected).abs() <= 2.0e-7);
            assert!((pixel.b - expected).abs() <= 2.0e-7);
        }
    }

    #[test]
    fn analytic_banding_amount_zero_is_exact_spatial_identity() {
        let mut clean = request().optics;
        clean.panel.temporal_emission = PanelTemporalEmission::continuous();
        let mut zero_amount = clean.clone();
        zero_amount.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 37).unwrap(),
            on_duration: RationalTime::new(1, 777).unwrap(),
            phase: RationalTime::new(13, 997).unwrap(),
            amount: 0.0,
        };
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 1,
            origin_y: 1,
            width: 2,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let integrate = |optics| {
            integrate_spatial_region_with_backend(
                ShutterRequest {
                    optics,
                    duration: RationalTime::new(1, 96).unwrap(),
                    temporal_samples: 8,
                    readout: SensorReadout::Global,
                    neutral_density_stops: 0.0,
                },
                sensor,
                region,
                false,
                &backend,
                |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
            )
            .unwrap()
        };
        assert_eq!(integrate(zero_amount), integrate(clean));
    }

    #[test]
    fn static_rolling_reuses_one_plan_per_row_but_integrates_all_eight_gains() {
        let mut optics = request().optics;
        optics.procedural_pattern = ProceduralTestPattern::EyeChart;
        optics.panel.temporal_emission = PanelTemporalEmission::continuous();
        optics.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 100).unwrap(),
            on_duration: RationalTime::new(1, 250).unwrap(),
            phase: RationalTime::new(1, 1_000).unwrap(),
            amount: 0.8,
        };
        let duration = RationalTime::new(1, 800).unwrap();
        let readout_duration = RationalTime::new(1, 100).unwrap();
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        let exposure = integrate_spatial_region_with_backend(
            ShutterRequest {
                optics: optics.clone(),
                duration,
                temporal_samples: 8,
                readout: SensorReadout::Rolling {
                    duration: readout_duration,
                    direction: RollingDirection::TopToBottom,
                },
                neutral_density_stops: 0.0,
            },
            sensor,
            region,
            true,
            &backend,
            |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
        )
        .unwrap();
        assert_eq!(backend.last_batch_size.load(Ordering::Relaxed), 2);
        for local_row in 0..usize::from(region.height) {
            let global_row = usize::from(region.origin_y) + local_row;
            let center = rolling_row_center_time(
                optics.time,
                readout_duration,
                global_row,
                usize::from(sensor.native_height),
                RollingDirection::TopToBottom,
            )
            .unwrap();
            let expected = shutter_quadrature(center, duration, 8)
                .unwrap()
                .into_iter()
                .map(|sample| {
                    f64::from(
                        optics
                            .panel
                            .temporal_emission
                            .average_gain(sample.start, sample.end)
                            .unwrap(),
                    ) * sample.weight_seconds
                })
                .sum::<f64>() as f32;
            for column in 0..usize::from(region.width) {
                let pixel = exposure.acescg_illuminance_seconds
                    [local_row * usize::from(region.width) + column];
                assert!((pixel.r - expected).abs() <= 2.0e-7);
                assert!((pixel.g - expected).abs() <= 2.0e-7);
                assert!((pixel.b - expected).abs() <= 2.0e-7);
            }
        }
    }

    #[test]
    fn authored_camera_motion_forces_the_complete_eight_plan_batch() {
        let mut optics = request().optics;
        optics.procedural_pattern = ProceduralTestPattern::EyeChart;
        let mut moving_key = optics.camera.transform.keyframes[0].clone();
        moving_key.id = "camera-transform-moving".to_owned();
        moving_key.time = RationalTime::new(2, 1).unwrap();
        moving_key.translation.x = 0.1;
        optics.camera.transform.keyframes.push(moving_key);
        let sensor = SensorProfile {
            native_width: 16,
            native_height: 9,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 2,
            width: 3,
            height: 2,
        };
        let backend = UnitSpatialBackend {
            last_batch_size: AtomicUsize::new(0),
        };
        integrate_spatial_region_with_backend(
            ShutterRequest {
                optics,
                duration: RationalTime::new(1, 48).unwrap(),
                temporal_samples: 8,
                readout: SensorReadout::Global,
                neutral_density_stops: 0.0,
            },
            sensor,
            region,
            true,
            &backend,
            |optics, region| prepare_procedural_spatial_plan(optics, sensor, region),
        )
        .unwrap();
        assert_eq!(backend.last_batch_size.load(Ordering::Relaxed), 8);
    }

    #[test]
    fn every_device_default_resolves_to_one_current_cover_preset() {
        for device in DEVICE_PRESETS {
            assert!(
                cover_glass_preset(device.default_cover_glass_preset_id).is_some(),
                "{} references an unknown cover preset",
                device.id
            );
        }
    }

    #[test]
    fn cover_is_neutral_at_zero_and_isolated_from_emission_diagnostics() {
        let baseline = request();
        let baseline_composite =
            evaluate_linear_optics(baseline.optical_request(), 32, 18).expect("baseline composite");

        let mut neutralized = baseline.clone();
        neutralized.optics.cover = COVER_GLASS_PRESETS[1].profile;
        neutralized.optics.cover.character_strength = 0.0;
        neutralized.optics.environment = ENVIRONMENT_PRESETS[1].environment;
        neutralized.optics.environment.character_strength = 0.0;
        let neutral_composite = evaluate_linear_optics(neutralized.optical_request(), 32, 18)
            .expect("neutral composite");
        assert_eq!(baseline_composite.pixels, neutral_composite.pixels);

        let mut physical = baseline.clone();
        physical.optics.cover = COVER_GLASS_PRESETS[1].profile;
        physical.optics.environment = ENVIRONMENT_PRESETS[1].environment;
        let physical_composite =
            evaluate_linear_optics(physical.optical_request(), 32, 18).expect("physical composite");
        assert_ne!(baseline_composite.pixels, physical_composite.pixels);

        let mut baseline_emission = baseline;
        baseline_emission.view = DiagnosticView::EmittedRadiance;
        let mut physical_emission = physical;
        physical_emission.view = DiagnosticView::EmittedRadiance;
        let baseline_diagnostic =
            prepare_raster(baseline_emission, 32, 18).expect("baseline emission diagnostic");
        let physical_diagnostic =
            prepare_raster(physical_emission, 32, 18).expect("physical emission diagnostic");
        assert_eq!(baseline_diagnostic.pixels, physical_diagnostic.pixels);
    }

    #[test]
    fn bundled_capture_presets_are_complete_unique_authoring_templates() {
        let mut ids = HashSet::new();
        for preset in CAPTURE_DEVICE_PRESETS {
            assert!(ids.insert(preset.id));
            preset.sensor.validate().expect("valid sensor profile");
            assert!(preset.gate_width.0 > 0.0 && preset.gate_height.0 > 0.0);
            let lens = lens_preset(preset.default_lens_preset_id)
                .expect("capture template lens must resolve");
            assert_eq!(lens.nominal_focal_length, preset.focal_length);
            assert!((25.0..=12_800.0).contains(&preset.reference_exposure_index));
            assert!(preset.middle_gray_illuminance_seconds_at_reference_ei > 0.0);
            assert!((1.0..=360.0).contains(&preset.default_shutter_angle_degrees));
            let raster_aspect =
                f32::from(preset.sensor.native_width) / f32::from(preset.sensor.native_height);
            let gate_aspect = preset.gate_width.0 / preset.gate_height.0;
            assert!((raster_aspect - gate_aspect).abs() < 0.001);
            assert_eq!(capture_device_preset(preset.id), Some(*preset));
        }
        assert_eq!(capture_device_preset("unknown-or-retired"), None);
    }

    #[test]
    fn optical_sensor_region_is_an_exact_crop_of_the_complete_raster() {
        let mut request = request().optical_request();
        request.viewport_aspect = 1.0;
        request.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        let full = evaluate_linear_optics(request.clone(), 8, 8).expect("complete raster");
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 3,
            width: 3,
            height: 2,
        };
        let cropped =
            evaluate_linear_optics_region(request, sensor, region).expect("native sensor region");
        for local_y in 0..usize::from(region.height) {
            for local_x in 0..usize::from(region.width) {
                let full_index = (usize::from(region.origin_y) + local_y) * 8
                    + usize::from(region.origin_x)
                    + local_x;
                let region_index = local_y * usize::from(region.width) + local_x;
                assert_eq!(cropped.pixels[region_index], full.pixels[full_index]);
            }
        }
    }

    #[test]
    fn rolling_sensor_region_is_an_exact_crop_of_the_complete_exposure() {
        let mut optics = request().optical_request();
        optics.viewport_aspect = 1.0;
        optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        let shutter = ShutterRequest {
            optics,
            duration: RationalTime::new(1, 48).unwrap(),
            temporal_samples: 3,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 120).unwrap(),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
        };
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 2,
            origin_y: 3,
            width: 3,
            height: 2,
        };
        let full = integrate_procedural_shutter(shutter.clone(), 8, 8).expect("full exposure");
        let cropped =
            integrate_procedural_region(shutter, sensor, region).expect("region exposure");
        for local_y in 0..usize::from(region.height) {
            for local_x in 0..usize::from(region.width) {
                let full_index = (usize::from(region.origin_y) + local_y) * 8
                    + usize::from(region.origin_x)
                    + local_x;
                let region_index = local_y * usize::from(region.width) + local_x;
                assert_eq!(
                    cropped.acescg_illuminance_seconds[region_index],
                    full.acescg_illuminance_seconds[full_index]
                );
            }
        }
    }

    #[test]
    fn animated_region_capture_resolves_source_at_each_rolling_sample_time() {
        let mut optics = request().optics;
        optics.viewport_aspect = 1.0;
        optics.camera.intrinsics.keyframes[0].sensor_height = Millimeters(36.0);
        let capture = FrameCaptureRequest {
            optics,
            frame_rate: FrameRate::new(24, 1).unwrap(),
            frame_index: 0,
            duration: RationalTime::new(1, 48).unwrap(),
            temporal_samples: 2,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 120).unwrap(),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
            noise_seed: 4,
        };
        let sensor = SensorProfile {
            native_width: 8,
            native_height: 8,
            ..SensorProfile::REFERENCE
        };
        let mut sampled = Vec::new();
        capture_and_develop_device_signal_region_sequence(
            capture,
            sensor,
            CameraDevelopment::NEUTRAL,
            SensorRegion {
                origin_x: 3,
                origin_y: 3,
                width: 2,
                height: 2,
            },
            RasterPlacement::Stretch,
            |time| {
                sampled.push(time);
                Ok(Arc::new(PreparedDeviceSignalRaster::new(
                    DeviceSignalRaster {
                        width: 1,
                        height: 1,
                        pixels: vec![DeviceRgb::new(0.25, 0.5, 0.75)],
                    },
                )?))
            },
        )
        .expect("animated rolling region");
        sampled.sort();
        sampled.dedup();
        assert!(
            sampled.len() > 2,
            "rolling rows must not freeze one frame sample"
        );
    }

    #[test]
    fn aperture_quality_tracks_global_defocus_without_per_pixel_seams() {
        let mut camera = prepare_frame(request().optical_request())
            .expect("valid request")
            .camera;
        assert_eq!(
            aperture_sample_count(camera, ScreenSample::IDENTITY, request().optics.panel, 960),
            16
        );

        camera.position.z = 0.5;
        camera.focus_distance = Meters(0.55);
        camera.focal_length = Millimeters(63.5);
        camera.f_stop = 1.2;
        assert_eq!(
            aperture_sample_count(camera, ScreenSample::IDENTITY, request().optics.panel, 960),
            128
        );
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
    fn discrete_preview_raster_may_round_the_authored_viewport_by_half_a_pixel() {
        let authored_aspect = 27.99 / 19.22;
        assert!(raster_represents_viewport(960, 659, authored_aspect));
        assert!(!raster_represents_viewport(960, 658, authored_aspect));
        assert!(raster_represents_viewport(1_919, 1_318, authored_aspect));
        assert!(!raster_represents_viewport(1_920, 1_318, authored_aspect));
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
        let samples = shutter_quadrature(center, duration, 4).expect("valid samples");
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
            shutter_quadrature(center, duration, 0),
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
            neutral_density_stops: 0.0,
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
            neutral_density_stops: 0.0,
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
                middle_gray_illuminance_seconds: 0.18,
                develop_exposure_ev: 0.0,
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
    fn native_development_matches_the_ideal_camera_preview_photometry() {
        let simulation = request();
        let signal = PreparedDeviceSignalRaster::new(DeviceSignalRaster {
            width: 1,
            height: 1,
            pixels: vec![DeviceRgb::WHITE],
        })
        .expect("uniform device signal");
        let sensor = SensorProfile {
            native_width: 32,
            native_height: 18,
            saturation_illuminance_seconds: LinearRgb::new(2.4, 2.4, 2.4),
            full_well_electrons: 10_000_000.0,
            dark_current_electrons_per_second: 0.0,
            read_noise_electrons_rms: 0.0,
            adc_bits: 16,
            ..SensorProfile::REFERENCE
        };
        let shutter = RationalTime::new(1, 48).expect("valid shutter");
        let development = CameraDevelopment {
            white_balance: LinearRgb::new(1.0, 1.0, 1.0),
            middle_gray_illuminance_seconds: 0.1,
            develop_exposure_ev: 0.0,
        };
        let ideal = evaluate_linear_optics_from_prepared_device_signal(
            simulation.optics.clone(),
            sensor.native_width,
            sensor.native_height,
            &signal,
            RasterPlacement::Stretch,
        )
        .expect("ideal optical raster");
        let native = capture_and_develop_device_signal_region(
            FrameCaptureRequest {
                optics: simulation.optics,
                frame_rate: FrameRate::new(24, 1).expect("valid frame rate"),
                frame_index: 0,
                duration: shutter,
                temporal_samples: 1,
                readout: SensorReadout::Global,
                neutral_density_stops: 0.0,
                noise_seed: 1,
            },
            sensor,
            development,
            SensorRegion {
                origin_x: 0,
                origin_y: 0,
                width: sensor.native_width,
                height: sensor.native_height,
            },
            &signal,
            RasterPlacement::Stretch,
        )
        .expect("native camera result");
        let center = 9 * 32 + 16;
        let expected =
            ideal.pixels[center].acescg_irradiance.g * shutter.as_seconds() as f32 * 0.18
                / development.middle_gray_illuminance_seconds;
        let measured = native.developed.acescg[center].g;
        assert!(
            (measured / expected - 1.0).abs() < 0.015,
            "native {measured} differs from ideal preview {expected}"
        );
    }

    #[test]
    fn global_shutter_integrates_analytic_banding_without_changing_average_luminance() {
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
                neutral_density_stops: 0.0,
            },
            32,
            18,
            RasterPlacement::Stretch,
            signal,
        )
        .expect("continuous exposure");
        let mut pulsed_optics = base_optics;
        let mut temporal = PanelTemporalEmission::continuous();
        temporal.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 1_000).unwrap(),
            on_duration: RationalTime::new(1, 2_000).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
            amount: 1.0,
        };
        pulsed_optics.panel.temporal_emission = temporal;
        let pulsed = integrate_shutter_from_device_signal_sequence(
            ShutterRequest {
                optics: pulsed_optics,
                duration: RationalTime::new(1, 100).unwrap(),
                temporal_samples: 1,
                readout: SensorReadout::Global,
                neutral_density_stops: 0.0,
            },
            32,
            18,
            RasterPlacement::Stretch,
            signal,
        )
        .expect("pulsed exposure");
        let index = 9 * 32 + 16;
        let continuous_value = continuous.acescg_illuminance_seconds[index].g;
        let pulsed_value = pulsed.acescg_illuminance_seconds[index].g;
        assert!((pulsed_value / continuous_value - 1.0).abs() < 1.0e-5);
    }

    #[test]
    fn photometric_boundary_converts_panel_luminance_to_lux_seconds_and_nd_is_exact() {
        let shutter = RationalTime::new(1, 48).unwrap();
        let illuminance_integral = 500.0_f64 * core::f64::consts::FRAC_PI_4 / 16.0 / 48.0;
        let open = finish_integrated_exposure(1, 1, shutter, 0.0, vec![[illuminance_integral; 3]])
            .expect("calibrated exposure");
        let nd_three =
            finish_integrated_exposure(1, 1, shutter, 3.0, vec![[illuminance_integral; 3]])
                .expect("attenuated exposure");
        let expected = 500.0_f32 * core::f32::consts::FRAC_PI_4 / 16.0 / 48.0;
        let measured = open.acescg_illuminance_seconds[0].g;
        assert!((measured - expected).abs() < 1.0e-6);
        assert!((nd_three.acescg_illuminance_seconds[0].g / measured - 0.125).abs() < 1.0e-6);
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
    fn optional_analytic_banding_uses_rolling_row_phase_without_extra_optical_samples() {
        let mut optics = request().optics;
        optics.time = RationalTime::new(0, 1).unwrap();
        let mut temporal = PanelTemporalEmission::continuous();
        temporal.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 100).unwrap(),
            on_duration: RationalTime::new(1, 200).unwrap(),
            phase: RationalTime::new(0, 1).unwrap(),
            amount: 1.0,
        };
        optics.panel.temporal_emission = temporal;
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
                neutral_density_stops: 0.0,
            },
            32,
            18,
            RasterPlacement::Stretch,
            |_| Ok(Arc::clone(&prepared)),
        )
        .expect("rolling exposure");
        let top = exposure.acescg_illuminance_seconds[2 * 32 + 16].g;
        let bottom = exposure.acescg_illuminance_seconds[15 * 32 + 16].g;
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
    fn approximate_optical_psf_scales_with_f_number_and_sensor_sampling_density() {
        let frame = prepare_frame(request().optical_request()).expect("valid frame");
        let center = Vec2 { x: 0.0, y: 0.0 };
        let edge = Vec2 { x: 1.0, y: 1.0 };
        let at_960 = approximate_psf_radius_pixels(frame.camera, 960, center);
        let at_3840 = approximate_psf_radius_pixels(frame.camera, 3_840, center);
        let at_edge = approximate_psf_radius_pixels(frame.camera, 3_840, edge);
        let mut stopped_down = frame.camera;
        stopped_down.f_stop *= 2.0;
        let at_f16 = approximate_psf_radius_pixels(stopped_down, 3_840, center);
        assert!(at_3840 > at_960);
        assert!(at_edge > at_3840);
        assert!(at_f16 > at_3840);
        let very_dense = approximate_psf_radius_pixels(stopped_down, 65_535, center);
        assert!(
            very_dense > 2.5,
            "the physical PSF must not be silently capped"
        );
    }

    #[test]
    fn resolved_sensor_sampling_applies_the_authored_optical_psf_extent() {
        let base = expand_sensor_footprint(Vec2 { x: 0.125, y: 0.875 }, 0.0);
        assert_eq!(base, Vec2 { x: 0.125, y: 0.875 });

        let expanded = expand_sensor_footprint(Vec2 { x: 0.125, y: 0.875 }, 0.5);
        let displacement = Vec2 {
            x: expanded.x - 0.125,
            y: expanded.y - 0.875,
        };
        assert!(displacement.x.hypot(displacement.y) <= 0.5 + f32::EPSILON);
        assert!(displacement.x < 0.0 && displacement.y > 0.0);
        let opposite = expand_sensor_footprint(Vec2 { x: 0.875, y: 0.125 }, 0.5);
        assert!((expanded.x + opposite.x - 1.0).abs() < f32::EPSILON);
        assert!((expanded.y + opposite.y - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn composite_uses_physical_black_matrix_when_resolved() {
        let request = request();
        let optical = OpticalSample {
            panel_uv: [Some(Vec2 { x: 0.5, y: 0.5 }); 3],
            emission_cosine: [1.0; 3],
            reflection_direction_local: [Some(Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            }); 3],
            irradiance_weight: [1.0; 3],
        };
        let neutral_cover = CoverGlassProfile::NEUTRAL
            .evaluator(ProceduralEnvironment::DARK)
            .expect("valid neutral cover");
        let resolved_spatial = [[optical; APERTURE_SAMPLE_COUNT]];
        let white_area = AreaSignalSample {
            device_code: DeviceRgb::WHITE,
            linear_native_emission: LinearRgb::new(500.0, 500.0, 500.0),
        };
        let resolved = integrate_aperture_samples(
            &resolved_spatial,
            DiagnosticView::Composite,
            request.optics.panel,
            request.optics.panel.evaluator().expect("valid panel"),
            1.0,
            &|_| DeviceRgb::WHITE,
            &|_, _| white_area,
            neutral_cover,
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
            &|_, _| white_area,
            neutral_cover,
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
    fn unresolved_filter_averages_emission_after_eotf() {
        let panel = request().optics.panel;
        let evaluator = panel.evaluator().expect("valid panel");
        let raster = DeviceSignalRaster {
            width: 2,
            height: 1,
            pixels: vec![DeviceRgb::BLACK, DeviceRgb::WHITE],
        };
        let emission = linear_emission_integral(&raster, evaluator)
            .sample_area_box(Vec2 { x: 0.0, y: 0.0 }, Vec2 { x: 1.0, y: 1.0 });
        let expected = (evaluator.native_channel(DeviceRgb::BLACK, 0)
            + evaluator.native_channel(DeviceRgb::WHITE, 0))
            * 0.5;
        assert!((emission.r - expected).abs() < 1.0e-5);
        assert!(
            (emission.r - evaluator.native_channel(DeviceRgb::new(0.5, 0.5, 0.5), 0)).abs() > 1.0
        );
    }

    #[test]
    fn prepared_device_signal_preview_is_identical_to_direct_device_signal_preview() {
        let source = DeviceSignalRaster {
            width: 2,
            height: 2,
            pixels: vec![
                DeviceRgb::new(0.1, 0.2, 0.3),
                DeviceRgb::new(0.7, 0.3, 0.1),
                DeviceRgb::new(0.2, 0.8, 0.4),
                DeviceRgb::new(0.9, 0.9, 0.9),
            ],
        };
        let prepared = PreparedDeviceSignalRaster::new(source.clone()).expect("valid signal");
        let direct =
            prepare_raster_from_device_signal(request(), 64, 36, &source, RasterPlacement::Stretch)
                .expect("direct preview");
        let reused = prepare_raster_from_prepared_device_signal(
            request(),
            64,
            36,
            &prepared,
            RasterPlacement::Stretch,
        )
        .expect("prepared preview");
        assert_eq!(direct, reused);
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

    #[test]
    fn eye_chart_is_an_explicit_bounded_black_on_white_device_signal() {
        let time = RationalTime::new(0, 24).expect("valid time");
        assert_eq!(
            diagnostic_signal(
                ProceduralTestPattern::EyeChart,
                Vec2 { x: 0.5, y: 0.14 },
                time,
            ),
            DeviceRgb::BLACK
        );
        assert_eq!(
            diagnostic_signal(
                ProceduralTestPattern::EyeChart,
                Vec2 { x: 0.05, y: 0.05 },
                time,
            ),
            DeviceRgb::WHITE
        );
        for y in 0..=100 {
            for x in 0..=100 {
                let value = diagnostic_signal(
                    ProceduralTestPattern::EyeChart,
                    Vec2 {
                        x: x as f32 / 100.0,
                        y: y as f32 / 100.0,
                    },
                    time,
                );
                assert!(
                    [value.r, value.g, value.b]
                        .into_iter()
                        .all(|channel| (0.0..=1.0).contains(&channel))
                );
            }
        }
    }

    #[test]
    fn photometric_scale_publishes_exact_achromatic_device_codes() {
        let time = RationalTime::new(0, 24).expect("valid time");
        for (index, expected) in PHOTOMETRIC_DEVICE_CODES.into_iter().enumerate() {
            let value = diagnostic_signal(
                ProceduralTestPattern::PhotometricDeviceScale,
                Vec2 {
                    x: (index as f32 + 0.5) / PHOTOMETRIC_DEVICE_CODES.len() as f32,
                    y: 0.5,
                },
                time,
            );
            assert_eq!(value, DeviceRgb::new(expected, expected, expected));
        }
    }

    #[test]
    fn known_device_code_follows_authored_panel_eotf_through_optics() {
        let mut optics = request().optical_request();
        optics.panel.black_level_nits = 0.0;
        let uniform = |code| DeviceSignalRaster {
            width: 1,
            height: 1,
            pixels: vec![DeviceRgb::new(code, code, code)],
        };
        let white = evaluate_linear_optics_from_device_signal(
            optics.clone(),
            16,
            9,
            &uniform(1.0),
            RasterPlacement::Stretch,
        )
        .expect("white optical reference");
        let half = evaluate_linear_optics_from_device_signal(
            optics.clone(),
            16,
            9,
            &uniform(0.5),
            RasterPlacement::Stretch,
        )
        .expect("half-code optical reference");
        let center = 4 * 16 + 8;
        let measured =
            half.pixels[center].acescg_irradiance.g / white.pixels[center].acescg_irradiance.g;
        let expected = 0.5_f32.powf(optics.panel.eotf_gamma);
        assert!((measured - expected).abs() < 1.0e-5);
    }
}
