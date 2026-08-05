use std::time::Instant;

use screen_application::{
    CAPTURE_DEVICE_PRESETS, FrameCaptureRequest, OpticalRequest, PanelTemporalEvaluation,
    ProceduralTestPattern, RollingDirection, SensorReadout, SpatialOpticalBackend,
    capture_and_develop_procedural_region_with_compute_backends,
    evaluate_procedural_spatial_cpu_oracle, prepare_procedural_spatial_plan,
};
use screen_camera::{CameraDevelopment, CpuRawDevelopment, RawDevelopmentBackend};
use screen_contracts::{FrameRate, Meters, RationalTime, Vec2, Vec3};
use screen_cover::{CoverGlassProfile, ProceduralEnvironment};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation, Quaternion,
    TransformKeyframe, TransformTrack, lens_preset,
};
use screen_panel::{
    DEVICE_PRESETS, LcdProfile, PanelColorimetry, PanelTemporalEmission, StripeLayout,
};
use screen_platform::MetalRawDevelopment;
use screen_sensor::{RawSensorRegion, SensorProfile, SensorRegion};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    const SENSOR_WIDTH: u16 = 256;
    const SENSOR_HEIGHT: u16 = 192;
    const TILE_EDGE: u16 = 128;
    const MOTION_SAMPLES: u16 = 8;
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
    let capture = FrameCaptureRequest {
        optics,
        frame_rate: FrameRate::new(24, 1)?,
        frame_index: 0,
        duration: RationalTime::new(1, 288)?,
        temporal_samples: MOTION_SAMPLES,
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
    let render_started = Instant::now();
    let result = capture_and_develop_procedural_region_with_compute_backends(
        capture,
        sensor,
        development,
        tile_region,
        &metal,
        &metal,
    )?;
    let elapsed = render_started.elapsed();
    let pixels = result.developed.acescg.len() as f64;
    let throughput = pixels / elapsed.as_secs_f64();
    let iphone_pixels =
        f64::from(iphone.sensor.native_width) * f64::from(iphone.sensor.native_height);
    println!("backend: Metal · {}", metal.device_name());
    println!("scene: iPhone 16e model · rolling shutter · 8 temporal samples");
    println!("benchmark tile: {TILE_EDGE}x{TILE_EDGE} ({pixels:.0} pixels)");
    println!("cold backend setup: {:.3} s", setup.as_secs_f64());
    println!(
        "time to first complete product tile: {:.3} s",
        elapsed.as_secs_f64()
    );
    println!(
        "rolling batch: {} exact row-sample plans ({} motion samples)",
        usize::from(tile_region.expanded_for_demosaic(sensor).height) * usize::from(MOTION_SAMPLES),
        MOTION_SAMPLES
    );
    println!("end-to-end physical throughput: {throughput:.2} sensor pixels/s");
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
        "48 MP end-to-end measured extrapolation: {:.1} min ({}x{}; rolling, 8 motion samples)",
        iphone_pixels / throughput / 60.0,
        iphone.sensor.native_width,
        iphone.sensor.native_height
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
