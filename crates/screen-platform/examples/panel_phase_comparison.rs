use std::error::Error;
use std::fs;
use std::mem::size_of;
use std::path::{Path, PathBuf};

use half::f16;
use image::{ColorType, ImageFormat};
use metal::{
    MTLPixelFormat, MTLRegion, MTLStorageMode, MTLTextureType, MTLTextureUsage, Texture,
    TextureDescriptor, TextureRef,
};
use screen_application::{
    CameraRadiometricCalibration, DeviceSignalRaster, PhysicalIntermediate,
    PhysicalPipelineExecutionPlan, PhysicalPipelineInput, PhysicalPipelineRequest, RasterPlacement,
    ResolvedSceneGeometryLensSnapshot, ResolvedShutterMotionSnapshot, SensorReadout,
    capture_device_preset, evaluate_physical_pipeline_cpu_oracle, expose_physical_pipeline_raw,
};
use screen_camera::{CameraDevelopment, develop_raw_to_acescg};
use screen_color::CameraOutputTransform;
use screen_contracts::{DeviceRgb, LinearRgb, RationalTime, Vec2, Vec3};
use screen_cover::{CoverGlassProfile, ProceduralEnvironment, cover_glass_preset};
use screen_geometry::{Quaternion, lens_preset};
use screen_panel::{DEVICE_PRESETS, FlatPanelQuality, PanelLightSpreadProfile};
use screen_platform::{
    DisplayPublicationBackend, ExactCpuDisplayPublication, MetalPhysicalPipeline,
};
use screen_sensor::SensorProfile;

struct Arguments {
    input: PathBuf,
    input_width: u32,
    input_height: u32,
    device_id: String,
    white_nits: f32,
    placement: RasterPlacement,
    quality: FlatPanelQuality,
    intermediate: PhysicalIntermediate,
    output_stem: String,
    output_directory: PathBuf,
}

fn main() -> Result<(), Box<dyn Error>> {
    let arguments = arguments()?;
    let storage = read_rgba16f(
        &arguments.input,
        arguments.input_width,
        arguments.input_height,
    )?;
    let pixels = storage
        .chunks_exact(4)
        .map(|pixel| {
            DeviceRgb::new(
                f16::from_bits(pixel[0]).to_f32(),
                f16::from_bits(pixel[1]).to_f32(),
                f16::from_bits(pixel[2]).to_f32(),
            )
        })
        .collect::<Vec<_>>();
    let device = DEVICE_PRESETS
        .iter()
        .find(|candidate| candidate.id == arguments.device_id)
        .ok_or_else(|| format!("unknown Device preset: {}", arguments.device_id))?;
    if !arguments.white_nits.is_finite()
        || arguments.white_nits < device.minimum_white_nits
        || arguments.white_nits > device.maximum_white_nits
    {
        return Err(format!(
            "White Luminance {} is outside {}..={} for {}",
            arguments.white_nits, device.minimum_white_nits, device.maximum_white_nits, device.id
        )
        .into());
    }
    let mut panel = device.profile();
    panel.white_level_nits = arguments.white_nits;
    let cover = cover_glass_preset(device.default_cover_glass_preset_id).ok_or_else(|| {
        format!(
            "Device {} references unknown Cover Glass preset {}",
            device.id, device.default_cover_glass_preset_id
        )
    })?;
    let camera = capture_device_preset("iphone-16e-main-48mp")
        .ok_or("required iPhone capture preset is unavailable")?;
    let lens = lens_preset(camera.default_lens_preset_id)
        .ok_or("iPhone capture preset references an unknown Lens preset")?;
    let camera_yaw_degrees = -5.0_f32;
    let camera_distance_meters = 0.15_f32;
    let shutter_half_nanoseconds = ((camera.default_shutter_angle_degrees as f64 / 360.0)
        * (1.0 / 24.0)
        * 0.5
        * 1_000_000_000.0)
        .round() as i64;
    let shutter_open = RationalTime::new(-shutter_half_nanoseconds, 1_000_000_000)?;
    let shutter_close = RationalTime::new(shutter_half_nanoseconds, 1_000_000_000)?;
    let camera_x_meters = camera_distance_meters * camera_yaw_degrees.to_radians().sin();
    let camera_z_meters = camera_distance_meters * camera_yaw_degrees.to_radians().cos();
    let scene_geometry_lens = ResolvedSceneGeometryLensSnapshot {
        focal_length_millimeters: lens.nominal_focal_length.0,
        sensor_width_millimeters: camera.gate_width.0,
        sensor_height_millimeters: camera.gate_height.0,
        lens_shift: Vec2 { x: 0.0, y: 0.0 },
        focus_distance_meters: camera_distance_meters,
        f_stop: camera.f_stop,
        near_clip_meters: 0.01,
        far_clip_meters: 100.0,
        lens: lens.lens,
    };
    let environment = ProceduralEnvironment::NONE;
    let camera_position = Vec3 {
        x: camera_x_meters,
        y: 0.0,
        z: camera_z_meters,
    };
    let camera_rotation = Quaternion::from_yaw_degrees(camera_yaw_degrees);
    let anterior_plan = plan(
        panel,
        device.light_spread,
        cover.profile,
        environment,
        scene_geometry_lens,
        camera.sensor,
        camera.radiometric_calibration,
        shutter_open,
        shutter_close,
        camera_position,
        camera_rotation,
        arguments.placement,
        arguments.quality,
        device.native_width,
        device.native_height,
        arguments.intermediate,
    );
    let nuevo_plan = plan(
        panel,
        device.light_spread,
        cover.profile,
        environment,
        scene_geometry_lens,
        camera.sensor,
        camera.radiometric_calibration,
        shutter_open,
        shutter_close,
        camera_position,
        camera_rotation,
        arguments.placement,
        arguments.quality,
        device.native_width,
        device.native_height,
        arguments.intermediate,
    );
    let source = vec![[0.0, 0.0, 0.0, 1.0]; pixels.len()];
    let input = PhysicalPipelineInput {
        width: arguments.input_width,
        height: arguments.input_height,
        acescg: source.clone(),
        device_signal: DeviceSignalRaster {
            width: arguments.input_width,
            height: arguments.input_height,
            pixels,
        },
        environment_acescg: None,
    };

    let metal_device = metal::Device::system_default().ok_or("Metal Device unavailable")?;
    let source_texture = rgba32_texture(
        &metal_device,
        arguments.input_width,
        arguments.input_height,
        &source,
    );
    let signal_texture = rgba16_texture(
        &metal_device,
        arguments.input_width,
        arguments.input_height,
        &storage,
    );
    let backend = MetalPhysicalPipeline::new(&metal_device)?;
    let capture_intermediate = matches!(
        arguments.intermediate,
        PhysicalIntermediate::SensorNoise
            | PhysicalIntermediate::RawMosaic
            | PhysicalIntermediate::DevelopedAcesCg
    );
    let (anterior_width, anterior_height, cpu_pixels) = if capture_intermediate {
        // Every accepted phase is the sole input to its successor. Capture
        // comparisons therefore feed both camera routes from the same accepted
        // Metal shutter checkpoint instead of accumulating an already accepted
        // optical tolerance into integer RAW.
        let stopped = anterior_plan.stopped_at_requested_intermediate();
        let mut optical_plan = stopped;
        optical_plan.sensor_enabled = false;
        optical_plan.requested_intermediate = PhysicalIntermediate::ShutterMotion;
        let optical = backend.evaluate(
            &source_texture,
            &signal_texture,
            optical_plan,
            |_| {},
            || false,
        )?;
        let optical_values = read_texture(&optical.texture)?;
        let raw = expose_physical_pipeline_raw(
            &optical_values,
            optical.texture.width() as u32,
            optical.texture.height() as u32,
            stopped,
        )?;
        let pixels = if arguments.intermediate == PhysicalIntermediate::DevelopedAcesCg {
            develop_raw_to_acescg(&raw, anterior_plan.sensor, anterior_plan.development)?.acescg
        } else {
            let maximum_code = ((1_u32 << raw.adc_bits) - 1) as f32;
            raw.codes
                .iter()
                .zip(&raw.full_well_clipped)
                .zip(&raw.adc_clipped)
                .map(|((&code, &well), &adc)| {
                    LinearRgb::new(code as f32 / maximum_code, f32::from(well), f32::from(adc))
                })
                .collect()
        };
        (raw.width, raw.height, pixels)
    } else {
        let cpu = evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest {
            input: input.clone(),
            plan: anterior_plan,
        })?;
        let pixels = cpu
            .acescg
            .iter()
            .map(|pixel| LinearRgb::new(pixel[0], pixel[1], pixel[2]))
            .collect::<Vec<_>>();
        (cpu.width, cpu.height, pixels)
    };
    let metal = backend.evaluate(
        &source_texture,
        &signal_texture,
        nuevo_plan,
        |_| {},
        || false,
    )?;
    let metal_values = read_texture(&metal.texture)?;
    let metal_pixels = metal_values
        .iter()
        .map(|pixel| LinearRgb::new(pixel[0], pixel[1], pixel[2]))
        .collect::<Vec<_>>();

    fs::create_dir_all(&arguments.output_directory)?;
    let publisher = ExactCpuDisplayPublication::new(CameraOutputTransform::SrgbSdr100)?;
    write_png(
        &arguments
            .output_directory
            .join(format!("anterior-{}.png", arguments.output_stem)),
        anterior_width,
        anterior_height,
        &publisher.publish_acescg_rgba8(&cpu_pixels)?,
    )?;
    write_png(
        &arguments
            .output_directory
            .join(format!("nuevo-{}.png", arguments.output_stem)),
        metal.texture.width() as u32,
        metal.texture.height() as u32,
        &publisher.publish_acescg_rgba8(&metal_pixels)?,
    )?;
    Ok(())
}

fn arguments() -> Result<Arguments, Box<dyn Error>> {
    let values = std::env::args().skip(1).collect::<Vec<_>>();
    if values.len() != 10 {
        return Err("usage: panel_phase_comparison <rgba16f.bin> <input-width> <input-height> <device-id> <white-nits> <fit|fill-crop|stretch|one-to-one> <draft|medium|high|native> <subpixel-radiance|panel-light-spread|relative-geometry|cover-environment|lens-projection|shutter-motion|sensor-noise|raw-mosaic|developed-acescg> <output-stem> <output-directory>".into());
    }
    let placement = match values[5].as_str() {
        "fit" => RasterPlacement::Fit,
        "fill-crop" => RasterPlacement::FillCrop,
        "stretch" => RasterPlacement::Stretch,
        "one-to-one" => RasterPlacement::OneToOne,
        _ => return Err(format!("unknown placement: {}", values[5]).into()),
    };
    let quality = match values[6].as_str() {
        "draft" => FlatPanelQuality::Draft,
        "medium" => FlatPanelQuality::Medium,
        "high" => FlatPanelQuality::High,
        "native" => FlatPanelQuality::Native,
        _ => return Err(format!("unknown quality: {}", values[6]).into()),
    };
    let intermediate = match values[7].as_str() {
        "subpixel-radiance" => PhysicalIntermediate::SubpixelRadiance,
        "panel-light-spread" => PhysicalIntermediate::PanelLightSpread,
        "relative-geometry" => PhysicalIntermediate::RelativeGeometry,
        "cover-environment" => PhysicalIntermediate::CoverEnvironment,
        "lens-projection" => PhysicalIntermediate::LensProjection,
        "shutter-motion" => PhysicalIntermediate::ShutterMotion,
        "sensor-noise" => PhysicalIntermediate::SensorNoise,
        "raw-mosaic" => PhysicalIntermediate::RawMosaic,
        "developed-acescg" => PhysicalIntermediate::DevelopedAcesCg,
        _ => return Err(format!("unknown intermediate: {}", values[7]).into()),
    };
    if values[8].is_empty()
        || !values[8]
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '-')
    {
        return Err("output stem must contain only ASCII letters, digits, or hyphens".into());
    }
    Ok(Arguments {
        input: PathBuf::from(&values[0]),
        input_width: values[1].parse()?,
        input_height: values[2].parse()?,
        device_id: values[3].clone(),
        white_nits: values[4].parse()?,
        placement,
        quality,
        intermediate,
        output_stem: values[8].clone(),
        output_directory: PathBuf::from(&values[9]),
    })
}

fn plan(
    panel: screen_panel::LcdProfile,
    panel_light_spread: PanelLightSpreadProfile,
    cover: CoverGlassProfile,
    environment: ProceduralEnvironment,
    scene_geometry_lens: ResolvedSceneGeometryLensSnapshot,
    sensor: SensorProfile,
    radiometric_calibration: CameraRadiometricCalibration,
    shutter_open: RationalTime,
    shutter_close: RationalTime,
    camera_position: Vec3,
    camera_rotation: Quaternion,
    placement: RasterPlacement,
    quality: FlatPanelQuality,
    width: u32,
    height: u32,
    intermediate: PhysicalIntermediate,
) -> PhysicalPipelineExecutionPlan {
    PhysicalPipelineExecutionPlan {
        panel,
        panel_light_spread,
        placement,
        quality,
        requested_width: width,
        requested_height: height,
        screen_amount: 1.0,
        emission_amount: 1.0,
        subpixel_geometry_amount: 1.0,
        temporal_emission_amount: 0.0,
        temporal_emission_gain: 1.0,
        cover,
        environment: screen_cover::IncidentEnvironment::Procedural(environment),
        scene_geometry_lens,
        camera_position,
        camera_rotation,
        screen_translation: Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        },
        screen_rotation: Quaternion::from_yaw_degrees(0.0),
        scene_geometry_amount: 1.0,
        lens_amount: 1.0,
        lens_evaluation_model: screen_application::LensEvaluationModel::ThinLens,
        frame_time: RationalTime::new(0, 1).expect("constant valid time"),
        shutter_open,
        shutter_close,
        shutter_motion: ResolvedShutterMotionSnapshot {
            temporal_samples: 1,
            readout: SensorReadout::Global,
            neutral_density_stops: 0.0,
            noise_seed: 7,
        },
        shutter_motion_amount: 1.0,
        computational_capture: screen_sensor::ComputationalCaptureProfile::SINGLE_EXPOSURE,
        computational_character_strength: 0.0,
        sensor,
        radiometric_calibration,
        sensor_enabled: true,
        sensor_noise_amount: 1.0,
        development: CameraDevelopment::NEUTRAL,
        development_enabled: true,
        frame_index: 0,
        requested_intermediate: intermediate,
    }
}

fn read_rgba16f(path: &Path, width: u32, height: u32) -> Result<Vec<u16>, Box<dyn Error>> {
    let bytes = fs::read(path)?;
    let expected = width as usize * height as usize * 4 * size_of::<u16>();
    if bytes.len() != expected {
        return Err(format!(
            "RGBA16F byte count is {}, expected {}",
            bytes.len(),
            expected
        )
        .into());
    }
    Ok(bytes
        .chunks_exact(2)
        .map(|value| u16::from_le_bytes([value[0], value[1]]))
        .collect())
}

fn rgba32_texture(
    device: &metal::DeviceRef,
    width: u32,
    height: u32,
    values: &[[f32; 4]],
) -> Texture {
    let descriptor = descriptor(MTLPixelFormat::RGBA32Float, width, height);
    let texture = device.new_texture(&descriptor);
    texture.replace_region(
        MTLRegion::new_2d(0, 0, u64::from(width), u64::from(height)),
        0,
        values.as_ptr().cast(),
        u64::from(width) * size_of::<[f32; 4]>() as u64,
    );
    texture
}

fn rgba16_texture(device: &metal::DeviceRef, width: u32, height: u32, values: &[u16]) -> Texture {
    let descriptor = descriptor(MTLPixelFormat::RGBA16Float, width, height);
    let texture = device.new_texture(&descriptor);
    texture.replace_region(
        MTLRegion::new_2d(0, 0, u64::from(width), u64::from(height)),
        0,
        values.as_ptr().cast(),
        u64::from(width) * size_of::<[u16; 4]>() as u64,
    );
    texture
}

fn descriptor(format: MTLPixelFormat, width: u32, height: u32) -> TextureDescriptor {
    let descriptor = TextureDescriptor::new();
    descriptor.set_texture_type(MTLTextureType::D2);
    descriptor.set_pixel_format(format);
    descriptor.set_width(u64::from(width));
    descriptor.set_height(u64::from(height));
    descriptor.set_storage_mode(MTLStorageMode::Shared);
    descriptor.set_usage(MTLTextureUsage::ShaderRead);
    descriptor
}

fn read_texture(texture: &TextureRef) -> Result<Vec<[f32; 4]>, Box<dyn Error>> {
    let count = (texture.width() * texture.height()) as usize;
    let region = MTLRegion::new_2d(0, 0, texture.width(), texture.height());
    match texture.pixel_format() {
        MTLPixelFormat::RGBA32Float => {
            let mut values = vec![[0.0_f32; 4]; count];
            texture.get_bytes(
                values.as_mut_ptr().cast(),
                texture.width() * size_of::<[f32; 4]>() as u64,
                region,
                0,
            );
            Ok(values)
        }
        MTLPixelFormat::RGBA16Float => {
            let mut storage = vec![[0_u16; 4]; count];
            texture.get_bytes(
                storage.as_mut_ptr().cast(),
                texture.width() * size_of::<[u16; 4]>() as u64,
                region,
                0,
            );
            Ok(storage
                .into_iter()
                .map(|pixel| pixel.map(|value| f16::from_bits(value).to_f32()))
                .collect())
        }
        other => Err(format!("unsupported Metal result format: {other:?}").into()),
    }
}

fn write_png(path: &Path, width: u32, height: u32, rgba: &[u8]) -> Result<(), Box<dyn Error>> {
    image::save_buffer_with_format(
        path,
        rgba,
        width,
        height,
        ColorType::Rgba8,
        ImageFormat::Png,
    )?;
    Ok(())
}
