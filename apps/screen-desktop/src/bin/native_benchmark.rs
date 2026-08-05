use std::time::{Duration, Instant};

use screen_application::{
    CAPTURE_DEVICE_PRESETS, FrameCaptureRequest, OpticalRequest, PanelTemporalEvaluation,
    ProceduralTestPattern, RollingDirection, SensorReadout, SpatialOpticalBackend,
    capture_and_develop_procedural_region_with_compute_backends,
    capture_and_develop_procedural_region_with_compute_backends_timed,
    evaluate_procedural_spatial_cpu_oracle, prepare_procedural_spatial_plan,
};
use screen_camera::{CameraDevelopment, CpuRawDevelopment, RawDevelopmentBackend};
use screen_color::{CameraOutputTransform, ColorEngine};
use screen_contracts::{FrameRate, Meters, RationalTime, Vec2, Vec3};
use screen_cover::{CoverGlassProfile, ProceduralEnvironment};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation, Quaternion,
    TransformKeyframe, TransformTrack, lens_preset,
};
use screen_panel::{
    DEVICE_PRESETS, LcdProfile, PanelColorimetry, PanelTemporalEmission, StripeLayout,
};
use screen_platform::{DisplayPublicationBackend, ExactCpuDisplayPublication, MetalRawDevelopment};
use screen_sensor::{RawSensorRegion, SensorProfile, SensorRegion};

struct BenchmarkStaging {
    width: usize,
    height: usize,
    source_width: usize,
    source_height: usize,
    sums: Vec<[u64; 3]>,
    samples: Vec<u32>,
}

impl BenchmarkStaging {
    fn new(source_width: u16, source_height: u16) -> Self {
        let width = usize::from(source_width.min(960));
        let height = (usize::from(source_height) * width / usize::from(source_width)).max(1);
        Self {
            width,
            height,
            source_width: usize::from(source_width),
            source_height: usize::from(source_height),
            sums: vec![[0; 3]; width * height],
            samples: vec![0; width * height],
        }
    }

    fn add(&mut self, source_x: usize, source_y: usize, pixel: &[u8]) {
        let target_x = source_x * self.width / self.source_width;
        let target_y = source_y * self.height / self.source_height;
        let target = target_y * self.width + target_x;
        for (sum, value) in self.sums[target].iter_mut().zip(pixel.iter().take(3)) {
            *sum += u64::from(*value);
        }
        self.samples[target] += 1;
    }

    fn snapshot(&self) -> Vec<[u8; 4]> {
        self.sums
            .iter()
            .zip(&self.samples)
            .map(|(sum, samples)| {
                if *samples == 0 {
                    [17, 17, 17, 255]
                } else {
                    let count = u64::from(*samples);
                    [
                        ((sum[0] + count / 2) / count) as u8,
                        ((sum[1] + count / 2) / count) as u8,
                        ((sum[2] + count / 2) / count) as u8,
                        255,
                    ]
                }
            })
            .collect()
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    const SENSOR_WIDTH: u16 = 256;
    const SENSOR_HEIGHT: u16 = 192;
    const TILE_EDGE: u16 = 128;
    const MOTION_SAMPLES: u16 = 8;
    let product_stripe_height = std::env::var("SCREEN_BENCH_STRIPE_HEIGHT")
        .map_or(Ok(TILE_EDGE), |value| value.parse::<u16>())?;
    if product_stripe_height == 0 {
        return Err("SCREEN_BENCH_STRIPE_HEIGHT must be positive".into());
    }
    let iphone = CAPTURE_DEVICE_PRESETS
        .iter()
        .find(|preset| preset.id == "iphone-16e-main-48mp")
        .expect("current iPhone capture template");
    let sensor = SensorProfile {
        native_width: SENSOR_WIDTH,
        native_height: SENSOR_HEIGHT,
        ..iphone.sensor
    };
    let at_zero = RationalTime::new(0, 24)?;
    let camera = CameraRig {
        transform: TransformTrack {
            keyframes: vec![TransformKeyframe {
                id: "benchmark-camera".to_owned(),
                time: at_zero,
                translation: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.22,
                },
                rotation: Quaternion::from_yaw_degrees(0.0),
                interpolation: KeyframeInterpolation::Hold,
            }],
        },
        intrinsics: CameraIntrinsicsTrack {
            keyframes: vec![CameraIntrinsicsKeyframe {
                id: "benchmark-intrinsics".to_owned(),
                time: at_zero,
                focal_length: iphone.focal_length,
                sensor_width: iphone.gate_width,
                sensor_height: iphone.gate_height,
                lens_shift: Vec2 { x: 0.0, y: 0.0 },
                focus_distance: Meters(0.22),
                f_stop: iphone.f_stop,
                near_clip: Meters(0.01),
                far_clip: Meters(100.0),
                lens: lens_preset(iphone.default_lens_preset_id)
                    .expect("current integrated lens")
                    .lens,
                interpolation: KeyframeInterpolation::Hold,
            }],
        },
    };
    let screen = TransformTrack {
        keyframes: vec![TransformKeyframe {
            id: "benchmark-screen".to_owned(),
            time: at_zero,
            translation: Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            rotation: Quaternion::from_yaw_degrees(0.0),
            interpolation: KeyframeInterpolation::Hold,
        }],
    };
    let optics = OpticalRequest {
        time: at_zero,
        panel_temporal_evaluation: PanelTemporalEvaluation::Instantaneous,
        viewport_aspect: f32::from(SENSOR_WIDTH) / f32::from(SENSOR_HEIGHT),
        panel: LcdProfile {
            native_width: DEVICE_PRESETS[0].native_width,
            native_height: DEVICE_PRESETS[0].native_height,
            active_width: DEVICE_PRESETS[0].active_width,
            active_height: DEVICE_PRESETS[0].active_height,
            stripe_layout: StripeLayout::Rgb,
            black_matrix_fraction: 0.1,
            eotf_gamma: 2.2,
            black_level_nits: 0.05,
            white_level_nits: DEVICE_PRESETS[0].reference_white_nits,
            colorimetry: PanelColorimetry::SRGB_D65,
            angular_emission_power: screen_contracts::LinearRgb::new(1.7, 1.5, 1.8),
            temporal_emission: PanelTemporalEmission::clean_lcd(),
        },
        cover: CoverGlassProfile::NEUTRAL,
        environment: ProceduralEnvironment::DARK,
        camera,
        screen,
        inspection: None,
        procedural_pattern: ProceduralTestPattern::AnimatedCheckerboard,
    };
    let tile_region = SensorRegion {
        origin_x: 0,
        origin_y: 0,
        width: TILE_EDGE,
        height: TILE_EDGE,
    };
    let spatial_plan = prepare_procedural_spatial_plan(optics.clone(), sensor, tile_region)?;
    let cpu_spatial_started = Instant::now();
    evaluate_procedural_spatial_cpu_oracle(optics.clone(), sensor, tile_region)?;
    let cpu_spatial_elapsed = cpu_spatial_started.elapsed();
    let default_capture = FrameCaptureRequest {
        optics,
        frame_rate: FrameRate::new(24, 1)?,
        frame_index: 0,
        duration: RationalTime::new(1, 288)?,
        temporal_samples: 1,
        readout: SensorReadout::Rolling {
            duration: RationalTime::new(3, 250)?,
            direction: RollingDirection::TopToBottom,
        },
        neutral_density_stops: 0.0,
        noise_seed: 0x5EED,
    };
    let development = CameraDevelopment {
        white_balance: screen_contracts::LinearRgb::new(1.0, 1.0, 1.0),
        middle_gray_illuminance_seconds: iphone.middle_gray_illuminance_seconds_at_reference_ei,
        develop_exposure_ev: 0.0,
    };
    let setup_started = Instant::now();
    let metal = MetalRawDevelopment::new()?;
    let setup = setup_started.elapsed();
    let first_spatial_started = Instant::now();
    let first_spatial = metal.evaluate_spatial(&spatial_plan)?;
    let first_spatial_elapsed = first_spatial_started.elapsed();
    let spatial_pixels = first_spatial.len() as f64;
    const SPATIAL_THROUGHPUT_ITERATIONS: usize = 8;
    let throughput_started = Instant::now();
    for _ in 0..SPATIAL_THROUGHPUT_ITERATIONS {
        metal.evaluate_spatial(&spatial_plan)?;
    }
    let throughput_elapsed = throughput_started.elapsed();
    let metal_spatial_throughput =
        spatial_pixels * SPATIAL_THROUGHPUT_ITERATIONS as f64 / throughput_elapsed.as_secs_f64();
    let run_capture =
        |capture: FrameCaptureRequest| -> Result<(Duration, f64), Box<dyn std::error::Error>> {
            let started = Instant::now();
            let result = capture_and_develop_procedural_region_with_compute_backends(
                capture,
                sensor,
                development,
                tile_region,
                &metal,
                &metal,
            )?;
            Ok((started.elapsed(), result.developed.acescg.len() as f64))
        };
    let (default_elapsed, pixels) = run_capture(default_capture.clone())?;
    let mut static_eight_capture = default_capture.clone();
    static_eight_capture.temporal_samples = MOTION_SAMPLES;
    static_eight_capture.optics.procedural_pattern = ProceduralTestPattern::EyeChart;
    let (static_eight_elapsed, static_pixels) = run_capture(static_eight_capture)?;
    let default_throughput = pixels / default_elapsed.as_secs_f64();
    let static_eight_throughput = static_pixels / static_eight_elapsed.as_secs_f64();
    let iphone_pixels =
        f64::from(iphone.sensor.native_width) * f64::from(iphone.sensor.native_height);
    println!("backend: Metal · {}", metal.device_name());
    println!("scene: iPhone 16e model · rolling shutter · clean LCD timing");
    println!("benchmark tile: {TILE_EDGE}x{TILE_EDGE} ({pixels:.0} pixels)");
    println!("cold backend setup: {:.3} s", setup.as_secs_f64());
    println!(
        "time to first complete product tile: {:.3} s",
        default_elapsed.as_secs_f64()
    );
    println!(
        "default 1 motion sample: {:.3} s · {:.0} pixels/s",
        default_elapsed.as_secs_f64(),
        default_throughput
    );
    let rolling_rows = usize::from(tile_region.expanded_for_demosaic(sensor).height);
    println!(
        "static 8 motion samples: {:.3} s · {:.0} pixels/s · {} authored row-samples reused as {} spatial plans",
        static_eight_elapsed.as_secs_f64(),
        static_eight_throughput,
        rolling_rows * usize::from(MOTION_SAMPLES),
        rolling_rows
    );
    println!(
        "CPU spatial oracle: {:.3} s · {:.0} pixels/s",
        cpu_spatial_elapsed.as_secs_f64(),
        spatial_pixels / cpu_spatial_elapsed.as_secs_f64()
    );
    println!(
        "Metal time to first spatial tile: {:.3} s",
        first_spatial_elapsed.as_secs_f64()
    );
    println!(
        "Metal spatial throughput ({} iterations): {:.0} pixels/s",
        SPATIAL_THROUGHPUT_ITERATIONS, metal_spatial_throughput
    );
    println!(
        "48 MP one-sample Metal spatial extrapolation: {:.1} s",
        iphone_pixels / metal_spatial_throughput
    );
    println!(
        "48 MP default end-to-end extrapolation: {:.1} min ({}x{}; rolling, 1 motion sample)",
        iphone_pixels / default_throughput / 60.0,
        iphone.sensor.native_width,
        iphone.sensor.native_height
    );
    println!(
        "48 MP static/8 end-to-end extrapolation: {:.1} min (same exact 8-sample integration)",
        iphone_pixels / static_eight_throughput / 60.0
    );

    const LARGE_WIDTH: u16 = 1_536;
    const LARGE_HEIGHT: u16 = 1_152;
    let large_sensor = SensorProfile {
        native_width: LARGE_WIDTH,
        native_height: LARGE_HEIGHT,
        ..iphone.sensor
    };
    let large_region = SensorRegion::full(large_sensor);
    let large_default = default_capture.clone();
    let mut large_static_eight = large_default.clone();
    large_static_eight.temporal_samples = MOTION_SAMPLES;
    large_static_eight.optics.procedural_pattern = ProceduralTestPattern::EyeChart;
    let run_large = |label: &str,
                     capture: FrameCaptureRequest|
     -> Result<(Duration, f64), Box<dyn std::error::Error>> {
        let started = Instant::now();
        let (result, stages) = capture_and_develop_procedural_region_with_compute_backends_timed(
            capture,
            large_sensor,
            development,
            large_region,
            &metal,
            &metal,
        )?;
        let total = started.elapsed();
        let measured = stages.preparation_cpu
            + stages.spatial_backend
            + stages.integration_and_sensor_cpu
            + stages.raw_development_backend
            + stages.output_assembly_cpu;
        println!(
            "large ROI {label}: {LARGE_WIDTH}x{LARGE_HEIGHT} · {:.3} s",
            total.as_secs_f64()
        );
        println!(
            "  preparation CPU {:.3} s · spatial Metal + shared materialization {:.3} s",
            stages.preparation_cpu.as_secs_f64(),
            stages.spatial_backend.as_secs_f64()
        );
        println!(
            "  temporal integration + sensor CPU {:.3} s · RAW develop Metal {:.3} s · output assembly {:.3} s",
            stages.integration_and_sensor_cpu.as_secs_f64(),
            stages.raw_development_backend.as_secs_f64(),
            stages.output_assembly_cpu.as_secs_f64()
        );
        println!(
            "  explicit device/host transfer 0.000 s (unified StorageModeShared; result materialization is included above) · unaccounted {:.3} s",
            total.saturating_sub(measured).as_secs_f64()
        );
        Ok((total, result.developed.acescg.len() as f64))
    };
    let (large_default_elapsed, large_pixels) = run_large("default1", large_default)?;
    let (large_static_elapsed, _) = run_large("static8", large_static_eight)?;
    println!(
        "48 MP large-ROI extrapolation: default1 {:.1} s · static8 {:.1} s",
        iphone_pixels / (large_pixels / large_default_elapsed.as_secs_f64()),
        iphone_pixels / (large_pixels / large_static_elapsed.as_secs_f64())
    );
    let expanded = large_region.expanded_for_demosaic(large_sensor);
    let expanded_pixels = usize::from(expanded.width) * usize::from(expanded.height);
    println!(
        "large-ROI principal staging: {:.1} MiB spatial float4 + {:.1} MiB accumulated f64x3 + {:.1} MiB developed float3",
        expanded_pixels as f64 * 16.0 / 1_048_576.0,
        expanded_pixels as f64 * 24.0 / 1_048_576.0,
        expanded_pixels as f64 * 12.0 / 1_048_576.0
    );

    let product_stripe = SensorRegion {
        origin_x: 0,
        origin_y: 0,
        width: iphone.sensor.native_width,
        height: product_stripe_height.min(iphone.sensor.native_height),
    };
    let output_processor =
        ColorEngine::bundled()?.camera_output_processor(CameraOutputTransform::SrgbSdr100)?;
    let publication_setup_started = Instant::now();
    let publication_backend = ExactCpuDisplayPublication::new(CameraOutputTransform::SrgbSdr100)?;
    println!(
        "exact publication backend setup: {:.3} s",
        publication_setup_started.elapsed().as_secs_f64()
    );
    let stripe_count =
        usize::from(iphone.sensor.native_height).div_ceil(usize::from(product_stripe.height));
    let run_product_stripe = |label: &str,
                              capture: FrameCaptureRequest|
     -> Result<Duration, Box<dyn std::error::Error>> {
        let started = Instant::now();
        let (result, stages) = capture_and_develop_procedural_region_with_compute_backends_timed(
            capture,
            iphone.sensor,
            development,
            product_stripe,
            &metal,
            &metal,
        )?;
        let capture_elapsed = started.elapsed();
        let developed = result.developed.acescg;
        let materialize_started = Instant::now();
        let mut display = Vec::with_capacity(developed.len() * 4);
        for pixel in &developed {
            display.extend_from_slice(&[pixel.r, pixel.g, pixel.b, 1.0]);
        }
        let materialize_elapsed = materialize_started.elapsed();
        let ocio_started = Instant::now();
        output_processor.apply_acescg_rgba_buffer(&mut display)?;
        let ocio_elapsed = ocio_started.elapsed();
        let quantize_started = Instant::now();
        let display_bytes = display
            .chunks_exact(4)
            .flat_map(|rgba| {
                let channel = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
                [channel(rgba[0]), channel(rgba[1]), channel(rgba[2]), 255]
            })
            .collect::<Vec<_>>();
        let quantize_elapsed = quantize_started.elapsed();
        let exact_started = Instant::now();
        let exact_bytes = publication_backend.publish_acescg_rgba8(&developed)?;
        let exact_elapsed = exact_started.elapsed();
        assert_eq!(exact_bytes, display_bytes);
        let copy_started = Instant::now();
        let mut publication = vec![0_u8; exact_bytes.len()];
        publication.copy_from_slice(&exact_bytes);
        let copy_elapsed = copy_started.elapsed();
        let staging_started = Instant::now();
        let mut staging =
            BenchmarkStaging::new(iphone.sensor.native_width, iphone.sensor.native_height);
        for (index, pixel) in publication.chunks_exact(4).enumerate() {
            staging.add(
                index % usize::from(product_stripe.width),
                index / usize::from(product_stripe.width),
                pixel,
            );
        }
        std::hint::black_box(staging.snapshot());
        let staging_elapsed = staging_started.elapsed();
        let product_elapsed = capture_elapsed + exact_elapsed + copy_elapsed + staging_elapsed;
        println!(
            "product stripe {label}: {}x{} · {:.3} s exact product path · {} logical tiles ready · prep {:.3} s · spatial {:.3} s · integration/sensor {:.3} s · RAW {:.3} s · exact parallel publication {:.3} s · output copy {:.3} s · staging {:.3} s",
            product_stripe.width,
            product_stripe.height,
            product_elapsed.as_secs_f64(),
            usize::from(product_stripe.width).div_ceil(usize::from(TILE_EDGE)),
            stages.preparation_cpu.as_secs_f64(),
            stages.spatial_backend.as_secs_f64(),
            stages.integration_and_sensor_cpu.as_secs_f64(),
            stages.raw_development_backend.as_secs_f64(),
            exact_elapsed.as_secs_f64(),
            copy_elapsed.as_secs_f64(),
            staging_elapsed.as_secs_f64(),
        );
        println!(
            "  serial exact oracle split: float RGBA {:.3} s · OCIO {:.3} s · quantize/assembly {:.3} s",
            materialize_elapsed.as_secs_f64(),
            ocio_elapsed.as_secs_f64(),
            quantize_elapsed.as_secs_f64(),
        );
        Ok(product_elapsed)
    };
    let stripe_default = run_product_stripe("default1", default_capture.clone())?;
    let mut stripe_static_capture = default_capture.clone();
    stripe_static_capture.temporal_samples = MOTION_SAMPLES;
    stripe_static_capture.optics.procedural_pattern = ProceduralTestPattern::EyeChart;
    let stripe_static = run_product_stripe("static8", stripe_static_capture)?;
    println!(
        "48 MP stripe-scheduled estimate ({} stripes): default1 {:.1} s · static8 {:.1} s",
        stripe_count,
        stripe_default.as_secs_f64() * stripe_count as f64,
        stripe_static.as_secs_f64() * stripe_count as f64,
    );

    let backend_sensor = SensorProfile {
        native_width: 1_024,
        native_height: 768,
        ..iphone.sensor
    };
    let backend_region = SensorRegion::full(backend_sensor);
    let backend_count = usize::from(backend_region.width) * usize::from(backend_region.height);
    let raw = RawSensorRegion {
        sensor_width: backend_sensor.native_width,
        sensor_height: backend_sensor.native_height,
        region: backend_region,
        bayer_pattern: backend_sensor.bayer_pattern,
        adc_bits: backend_sensor.adc_bits,
        sensor_profile: backend_sensor,
        codes: (0..backend_count)
            .map(|index| ((index as u32 * 997 + 31) % 4_095) as u16)
            .collect(),
        full_well_clipped: vec![false; backend_count],
        adc_clipped: vec![false; backend_count],
    };
    let cpu_started = Instant::now();
    CpuRawDevelopment.develop_region(&raw, backend_sensor, development)?;
    let cpu_elapsed = cpu_started.elapsed();
    let metal_started = Instant::now();
    metal.develop_region(&raw, backend_sensor, development)?;
    let metal_elapsed = metal_started.elapsed();
    println!(
        "RAW develop 1024x768: CPU {:.3} s · Metal {:.3} s · {:.2}x",
        cpu_elapsed.as_secs_f64(),
        metal_elapsed.as_secs_f64(),
        cpu_elapsed.as_secs_f64() / metal_elapsed.as_secs_f64()
    );
    Ok(())
}
