#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use core::mem::size_of;
    use std::time::Instant;

    use metal::{
        MTLPixelFormat, MTLRegion, MTLStorageMode, MTLTextureType, MTLTextureUsage,
        TextureDescriptor,
    };
    use screen_application::{
        PhysicalIntermediate, PhysicalPipelineExecutionPlan, RasterPlacement,
    };
    use screen_panel::{DEVICE_PRESETS, FlatPanelQuality, PanelLightSpreadProfile};
    use screen_platform::MetalPhysicalPipeline;

    const SOURCE_WIDTH: u32 = 3_840;
    const SOURCE_HEIGHT: u32 = 2_160;
    let device = metal::Device::system_default().ok_or("this Mac exposes no Metal device")?;
    let values = (0..u64::from(SOURCE_WIDTH) * u64::from(SOURCE_HEIGHT))
        .map(|index| {
            let x = (index % u64::from(SOURCE_WIDTH)) as f32 / SOURCE_WIDTH as f32;
            let y = (index / u64::from(SOURCE_WIDTH)) as f32 / SOURCE_HEIGHT as f32;
            [x * 1.5 - 0.25, y, (x * 47.0).fract() * 2.0, 1.0]
        })
        .collect::<Vec<_>>();
    let descriptor = TextureDescriptor::new();
    descriptor.set_texture_type(MTLTextureType::D2);
    descriptor.set_pixel_format(MTLPixelFormat::RGBA32Float);
    descriptor.set_width(u64::from(SOURCE_WIDTH));
    descriptor.set_height(u64::from(SOURCE_HEIGHT));
    descriptor.set_storage_mode(MTLStorageMode::Shared);
    descriptor.set_usage(MTLTextureUsage::ShaderRead);
    let source = device.new_texture(&descriptor);
    let signal = device.new_texture(&descriptor);
    let region = MTLRegion::new_2d(0, 0, u64::from(SOURCE_WIDTH), u64::from(SOURCE_HEIGHT));
    let row_bytes = u64::from(SOURCE_WIDTH) * size_of::<[f32; 4]>() as u64;
    source.replace_region(region, 0, values.as_ptr().cast(), row_bytes);
    signal.replace_region(region, 0, values.as_ptr().cast(), row_bytes);
    drop(values);

    let setup_started = Instant::now();
    let backend = MetalPhysicalPipeline::new(&device)?;
    let setup = setup_started.elapsed();
    println!(
        "backend=Metal device=\"{}\" source={}x{} format=RGBA32Float setup_ms={:.3}",
        device.name(),
        SOURCE_WIDTH,
        SOURCE_HEIGHT,
        milliseconds(setup)
    );
    println!(
        "memory is exact allocated texture storage; timings are measurements from this run, not extrapolations"
    );

    for preset_id in [
        "lcd-phone-4_7-retina",
        "lcd-macbook-pro-retina-14",
        "lcd-asus-proart-pa329cv",
    ] {
        let preset = DEVICE_PRESETS
            .iter()
            .find(|preset| preset.id == preset_id)
            .expect("benchmark preset is current");
        for (quality, requested_width) in [
            (FlatPanelQuality::Draft, 360),
            (FlatPanelQuality::Medium, 960),
            (FlatPanelQuality::High, 1_920),
            (FlatPanelQuality::Native, 1),
        ] {
            let requested_height = if quality == FlatPanelQuality::Native {
                1
            } else {
                ((requested_width as f64 * preset.native_height as f64 / preset.native_width as f64)
                    .round() as u32)
                    .max(1)
            };
            let plan = PhysicalPipelineExecutionPlan {
                panel: preset.profile(),
                panel_light_spread: PanelLightSpreadProfile::LCD_DESKTOP,
                placement: RasterPlacement::Stretch,
                quality,
                requested_width,
                requested_height,
                screen_amount: 1.0,
                emission_amount: 1.0,
                subpixel_geometry_amount: 1.0,
                temporal_emission_amount: 1.0,
                temporal_emission_gain: 1.0,
                cover: screen_cover::CoverGlassProfile::NEUTRAL,
                environment: screen_cover::ProceduralEnvironment::NONE,
                scene_geometry_lens:
                    screen_application::ResolvedSceneGeometryLensSnapshot::REFERENCE,
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
                screen_rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
                scene_geometry_amount: 0.0,
                lens_amount: 0.0,
                frame_time: screen_contracts::RationalTime::new(0, 1)
                    .expect("valid benchmark time"),
                shutter_open: screen_contracts::RationalTime::new(-1, 96)
                    .expect("valid benchmark open"),
                shutter_close: screen_contracts::RationalTime::new(1, 96)
                    .expect("valid benchmark close"),
                shutter_motion: screen_application::ResolvedShutterMotionSnapshot {
                    temporal_samples: 1,
                    readout: screen_application::SensorReadout::Global,
                    neutral_density_stops: 0.0,
                    noise_seed: 0,
                },
                shutter_motion_amount: 0.0,
                sensor: screen_sensor::SensorProfile::REFERENCE,
                sensor_enabled: false,
                sensor_noise_amount: 0.0,
                development: screen_camera::CameraDevelopment::NEUTRAL,
                development_enabled: false,
                frame_index: 0,
                requested_intermediate: PhysicalIntermediate::DevelopedAcesCg,
            };
            let mut first_tile = None;
            let started = Instant::now();
            let result = backend.evaluate(
                &source,
                &signal,
                plan,
                |_| {
                    if first_tile.is_none() {
                        first_tile = Some(started.elapsed());
                    }
                },
                || false,
            )?;
            let total = started.elapsed();
            let input_bytes = u64::from(SOURCE_WIDTH)
                * u64::from(SOURCE_HEIGHT)
                * size_of::<[f32; 4]>() as u64
                * 2;
            let output_bytes = u64::from(result.sampling.effective_width)
                * u64::from(result.sampling.effective_height)
                * size_of::<[f32; 4]>() as u64;
            println!(
                "preset={} quality={:?} output={}x{} samples_per_pixel={} resolved={} first_tile_ms={:.3} total_ms={:.3} input_texture_bytes={} output_texture_bytes={} peak_texture_bytes={}",
                preset.id,
                quality,
                result.sampling.effective_width,
                result.sampling.effective_height,
                result.sampling.samples_per_output_pixel,
                result.sampling.subpixel_geometry_resolved,
                milliseconds(first_tile.expect("one tile completed")),
                milliseconds(total),
                input_bytes,
                output_bytes,
                input_bytes + output_bytes,
            );
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn milliseconds(duration: std::time::Duration) -> f64 {
    duration.as_secs_f64() * 1_000.0
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("physical_pipeline_benchmark requires the authoritative macOS Metal backend");
    std::process::exit(1);
}
