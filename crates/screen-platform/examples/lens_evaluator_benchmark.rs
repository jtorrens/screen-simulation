#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use core::mem::size_of;
    use std::time::Instant;

    use metal::{
        MTLPixelFormat, MTLRegion, MTLStorageMode, MTLTextureType, MTLTextureUsage,
        TextureDescriptor,
    };
    use screen_application::{
        LensEvaluationModel, PhysicalIntermediate, PhysicalPipelineExecutionPlan, RasterPlacement,
    };
    use screen_panel::{DEVICE_PRESETS, FlatPanelQuality, PanelLightSpreadProfile};
    use screen_platform::MetalPhysicalPipeline;

    const WIDTH: u32 = 3_840;
    const HEIGHT: u32 = 2_160;
    let device = metal::Device::system_default().ok_or("this Mac exposes no Metal device")?;
    let values = (0..u64::from(WIDTH) * u64::from(HEIGHT))
        .map(|index| {
            let x = (index % u64::from(WIDTH)) as f32 / WIDTH as f32;
            let y = (index / u64::from(WIDTH)) as f32 / HEIGHT as f32;
            let stripe = if (index % 19) < 9 { 1.0 } else { 0.02 };
            [stripe, x * 0.8 + 0.1, y * 0.8 + 0.1, 1.0]
        })
        .collect::<Vec<_>>();
    let descriptor = TextureDescriptor::new();
    descriptor.set_texture_type(MTLTextureType::D2);
    descriptor.set_pixel_format(MTLPixelFormat::RGBA32Float);
    descriptor.set_width(u64::from(WIDTH));
    descriptor.set_height(u64::from(HEIGHT));
    descriptor.set_storage_mode(MTLStorageMode::Shared);
    descriptor.set_usage(MTLTextureUsage::ShaderRead);
    let source = device.new_texture(&descriptor);
    let signal = device.new_texture(&descriptor);
    let region = MTLRegion::new_2d(0, 0, u64::from(WIDTH), u64::from(HEIGHT));
    let row_bytes = u64::from(WIDTH) * size_of::<[f32; 4]>() as u64;
    source.replace_region(region, 0, values.as_ptr().cast(), row_bytes);
    signal.replace_region(region, 0, values.as_ptr().cast(), row_bytes);
    drop(values);

    let backend = MetalPhysicalPipeline::new(&device)?;
    let preset = DEVICE_PRESETS
        .iter()
        .find(|preset| preset.id == "lcd-asus-proart-pa329cv")
        .expect("current ASUS panel preset");
    let mut scene = screen_application::ResolvedSceneGeometryLensSnapshot::REFERENCE;
    scene.focus_distance_meters = 0.8;
    let base_plan = PhysicalPipelineExecutionPlan {
        panel: preset.profile(),
        panel_light_spread: PanelLightSpreadProfile::LCD_DESKTOP,
        placement: RasterPlacement::Stretch,
        quality: FlatPanelQuality::High,
        requested_width: WIDTH,
        requested_height: HEIGHT,
        screen_amount: 1.0,
        emission_amount: 1.0,
        subpixel_geometry_amount: 1.0,
        temporal_emission_amount: 1.0,
        temporal_emission_gain: 1.0,
        cover: screen_cover::CoverGlassProfile::NEUTRAL,
        environment: screen_cover::IncidentEnvironment::NONE,
        scene_geometry_lens: scene,
        camera_position: screen_contracts::Vec3 {
            x: 0.0,
            y: 0.0,
            z: 1.0,
        },
        camera_rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
        screen_translation: screen_contracts::Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        },
        screen_rotation: screen_geometry::Quaternion::from_yaw_degrees(25.0),
        scene_geometry_amount: 1.0,
        lens_amount: 1.0,
        lens_evaluation_model: LensEvaluationModel::ThinLens,
        frame_time: screen_contracts::RationalTime::new(0, 1).expect("valid frame time"),
        shutter_open: screen_contracts::RationalTime::new(-1, 96).expect("valid shutter open"),
        shutter_close: screen_contracts::RationalTime::new(1, 96).expect("valid shutter close"),
        shutter_motion: screen_application::ResolvedShutterMotionSnapshot {
            temporal_samples: 1,
            readout: screen_application::SensorReadout::Global,
            neutral_density_stops: 0.0,
            noise_seed: 0,
        },
        shutter_motion_amount: 0.0,
        computational_capture: screen_sensor::ComputationalCaptureProfile::SINGLE_EXPOSURE,
        computational_character_strength: 0.0,
        sensor: screen_sensor::SensorProfile::REFERENCE,
        radiometric_calibration: screen_application::CameraRadiometricCalibration::REFERENCE,
        sensor_enabled: false,
        sensor_noise_amount: 0.0,
        development: screen_camera::CameraDevelopment::NEUTRAL,
        development_enabled: false,
        frame_index: 0,
        requested_intermediate: PhysicalIntermediate::LensProjection,
    };

    println!(
        "benchmark=lens-evaluator device=\"{}\" output={}x{} target_ms=10000",
        device.name(),
        WIDTH,
        HEIGHT
    );
    for model in [
        LensEvaluationModel::ThinLens,
        LensEvaluationModel::VfxDepthBlur,
    ] {
        let mut plan = base_plan;
        plan.lens_evaluation_model = model;
        let started = Instant::now();
        let result = backend.evaluate(&source, &signal, plan, |_| {}, || false)?;
        let elapsed = started.elapsed();
        println!(
            "model={model:?} output={}x{} samples_per_pixel={} metal_submit_to_result_ms={:.3}",
            result.sampling.effective_width,
            result.sampling.effective_height,
            result.sampling.samples_per_output_pixel,
            elapsed.as_secs_f64() * 1_000.0,
        );
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("lens_evaluator_benchmark requires the authoritative macOS Metal backend");
    std::process::exit(1);
}
