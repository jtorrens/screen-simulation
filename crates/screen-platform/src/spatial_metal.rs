use core::mem::size_of;

use metal::{MTLCommandBufferStatus, MTLResourceOptions, MTLSize};
use screen_application::{
    LinearOpticalPixel, SpatialOpticalBackend, SpatialOpticalPlan, SpatialSignalPlan,
};
use screen_contracts::LinearRgb;
use screen_cover::EnvironmentPattern;
use screen_geometry::{CameraSample, ScreenSample};
use screen_panel::StripeLayout;

use crate::{MetalNativeError, MetalRawDevelopment};

#[repr(C)]
#[derive(Clone, Copy)]
struct SpatialParams {
    raster: [u32; 4],
    window: [u32; 4],
    signal_meta: [u32; 4],
    panel_meta: [u32; 4],
    camera_position_focal: [f32; 4],
    camera_right_sensor_width: [f32; 4],
    camera_up_sensor_height: [f32; 4],
    camera_forward_focus: [f32; 4],
    camera_limits: [f32; 4],
    lens_shift_radial01: [f32; 4],
    lens_radial2_tangential: [f32; 4],
    lens_longitudinal: [f32; 4],
    lens_lateral: [f32; 4],
    lens_transmission_vignette: [f32; 4],
    lens_softness: [f32; 4],
    screen_translation: [f32; 4],
    screen_quaternion: [f32; 4],
    panel_geometry: [f32; 4],
    panel_levels_angular_r: [f32; 4],
    panel_angular_b: [f32; 4],
    panel_matrix_0: [f32; 4],
    panel_matrix_1: [f32; 4],
    panel_matrix_2: [f32; 4],
    cover_geometry: [f32; 4],
    cover_absorption_roughness: [f32; 4],
    cover_haze: [f32; 4],
    environment_ambient_strength: [f32; 4],
    environment_key_radius: [f32; 4],
    environment_direction: [f32; 4],
    procedural_time: [f32; 4],
}

impl SpatialParams {
    fn new(plan: &SpatialOpticalPlan) -> Self {
        let CameraSample {
            position,
            focal_length,
            sensor_width,
            sensor_height,
            lens_shift,
            focus_distance,
            f_stop,
            near_clip,
            far_clip,
            lens,
            world_to_view,
            ..
        } = plan.frame.camera;
        let ScreenSample {
            translation,
            rotation,
        } = plan.frame.screen;
        let (signal_kind, signal_width, signal_height, placement, pattern, time_seconds) =
            match &plan.signal {
                SpatialSignalPlan::Procedural {
                    pattern,
                    time_seconds,
                } => (
                    0,
                    1,
                    1,
                    0,
                    match pattern {
                        screen_application::ProceduralTestPattern::AnimatedCheckerboard => 0,
                        screen_application::ProceduralTestPattern::EyeChart => 1,
                        screen_application::ProceduralTestPattern::PhotometricDeviceScale => 2,
                    },
                    *time_seconds,
                ),
                SpatialSignalPlan::Raster {
                    width,
                    height,
                    placement,
                    ..
                } => (
                    1,
                    *width,
                    *height,
                    match placement {
                        screen_application::RasterPlacement::Fit => 0,
                        screen_application::RasterPlacement::FillCrop => 1,
                        screen_application::RasterPlacement::Stretch => 2,
                        screen_application::RasterPlacement::OneToOne => 3,
                    },
                    0,
                    0.0,
                ),
            };
        let pad = |value: [f32; 3], fourth| [value[0], value[1], value[2], fourth];
        Self {
            raster: [
                u32::from(plan.raster.full_width),
                u32::from(plan.raster.full_height),
                u32::from(plan.raster.origin_x),
                u32::from(plan.raster.origin_y),
            ],
            window: [
                u32::from(plan.raster.width),
                u32::from(plan.raster.height),
                u32::from(plan.aperture_sample_count),
                signal_kind,
            ],
            signal_meta: [signal_width, signal_height, placement, pattern],
            panel_meta: [
                plan.panel.native_width,
                plan.panel.native_height,
                match plan.panel.stripe_layout {
                    StripeLayout::Rgb => 0,
                    StripeLayout::Bgr => 1,
                },
                match plan.environment.pattern {
                    EnvironmentPattern::UniformKey => 0,
                    EnvironmentPattern::ReflectionChart => 1,
                },
            ],
            camera_position_focal: [position.x, position.y, position.z, focal_length.0],
            camera_right_sensor_width: [
                world_to_view[0],
                world_to_view[1],
                world_to_view[2],
                sensor_width.0,
            ],
            camera_up_sensor_height: [
                world_to_view[4],
                world_to_view[5],
                world_to_view[6],
                sensor_height.0,
            ],
            camera_forward_focus: [
                world_to_view[8],
                world_to_view[9],
                world_to_view[10],
                focus_distance.0,
            ],
            camera_limits: [f_stop, near_clip.0, far_clip.0, 0.0],
            lens_shift_radial01: [
                lens_shift.x,
                lens_shift.y,
                lens.radial_distortion[0],
                lens.radial_distortion[1],
            ],
            lens_radial2_tangential: [
                lens.radial_distortion[2],
                lens.tangential_distortion[0],
                lens.tangential_distortion[1],
                0.0,
            ],
            lens_longitudinal: pad(lens.longitudinal_chromatic_meters, 0.0),
            lens_lateral: pad(lens.lateral_chromatic_scale, 0.0),
            lens_transmission_vignette: pad(lens.transmission_rgb, lens.vignetting_strength),
            lens_softness: [
                lens.center_softness_micrometers,
                lens.edge_softness_micrometers,
                0.0,
                0.0,
            ],
            screen_translation: [translation.x, translation.y, translation.z, 0.0],
            screen_quaternion: [rotation.x, rotation.y, rotation.z, rotation.w],
            panel_geometry: [
                plan.panel.active_width_meters,
                plan.panel.active_height_meters,
                plan.panel.black_matrix_fraction,
                plan.panel.eotf_gamma,
            ],
            panel_levels_angular_r: [
                plan.panel.black_level_nits,
                plan.panel.white_level_nits,
                plan.panel.angular_emission_power.r,
                plan.panel.angular_emission_power.g,
            ],
            panel_angular_b: [plan.panel.angular_emission_power.b, 0.0, 0.0, 0.0],
            panel_matrix_0: pad(plan.panel_native_to_acescg[0], 0.0),
            panel_matrix_1: pad(plan.panel_native_to_acescg[1], 0.0),
            panel_matrix_2: pad(plan.panel_native_to_acescg[2], 0.0),
            cover_geometry: [
                plan.cover.character_strength,
                plan.cover.thickness_millimeters,
                plan.cover.refractive_index,
                plan.cover.anti_reflective_efficiency,
            ],
            cover_absorption_roughness: [
                plan.cover.absorption_per_millimeter.r,
                plan.cover.absorption_per_millimeter.g,
                plan.cover.absorption_per_millimeter.b,
                plan.cover.roughness,
            ],
            cover_haze: [plan.cover.haze, 0.0, 0.0, 0.0],
            environment_ambient_strength: [
                plan.environment.ambient_radiance.0.r,
                plan.environment.ambient_radiance.0.g,
                plan.environment.ambient_radiance.0.b,
                plan.environment.character_strength,
            ],
            environment_key_radius: [
                plan.environment.key_radiance.0.r,
                plan.environment.key_radiance.0.g,
                plan.environment.key_radiance.0.b,
                plan.environment.key_angular_radius_degrees.to_radians(),
            ],
            environment_direction: pad(plan.environment.key_direction_local, 0.0),
            procedural_time: [time_seconds, 0.0, 0.0, 0.0],
        }
    }
}

fn prefix_integral(values: &[[f32; 4]], width: u32, height: u32) -> Vec<[f32; 4]> {
    let stride = width as usize + 1;
    let mut result = vec![[0.0; 4]; stride * (height as usize + 1)];
    for y in 0..height as usize {
        for x in 0..width as usize {
            let pixel = values[y * width as usize + x];
            for channel in 0..3 {
                result[(y + 1) * stride + x + 1][channel] = pixel[channel]
                    + result[(y + 1) * stride + x][channel]
                    + result[y * stride + x + 1][channel]
                    - result[y * stride + x][channel];
            }
        }
    }
    result
}

impl SpatialOpticalBackend for MetalRawDevelopment {
    type Error = MetalNativeError;

    fn evaluate_spatial(
        &self,
        plan: &SpatialOpticalPlan,
    ) -> Result<Vec<LinearOpticalPixel>, Self::Error> {
        let placeholder = vec![[0.0_f32; 4]];
        let (signal, code_integral, emission_integral) = match &plan.signal {
            SpatialSignalPlan::Procedural { .. } => {
                (placeholder.clone(), placeholder.clone(), placeholder)
            }
            SpatialSignalPlan::Raster {
                width,
                height,
                device_signal,
                linear_native_emission,
                ..
            } => {
                let signal = device_signal
                    .iter()
                    .map(|value| [value.r, value.g, value.b, 0.0])
                    .collect::<Vec<_>>();
                let emission = linear_native_emission
                    .iter()
                    .map(|value| [value.r, value.g, value.b, 0.0])
                    .collect::<Vec<_>>();
                (
                    signal.clone(),
                    prefix_integral(&signal, *width, *height),
                    prefix_integral(&emission, *width, *height),
                )
            }
        };
        let params = SpatialParams::new(plan);
        let buffer = |values: &[[f32; 4]]| {
            self.device.new_buffer_with_data(
                values.as_ptr().cast(),
                size_of_val(values) as u64,
                MTLResourceOptions::StorageModeShared,
            )
        };
        let signal = buffer(&signal);
        let code_integral = buffer(&code_integral);
        let emission_integral = buffer(&emission_integral);
        let params = self.device.new_buffer_with_data(
            core::ptr::from_ref(&params).cast(),
            size_of::<SpatialParams>() as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let count = usize::from(plan.raster.width) * usize::from(plan.raster.height);
        let output = self.device.new_buffer(
            (count * size_of::<[f32; 4]>()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.spatial_pipeline);
        encoder.set_buffer(0, Some(&signal), 0);
        encoder.set_buffer(1, Some(&code_integral), 0);
        encoder.set_buffer(2, Some(&emission_integral), 0);
        encoder.set_buffer(3, Some(&output), 0);
        encoder.set_buffer(4, Some(&params), 0);
        let width = self
            .spatial_pipeline
            .thread_execution_width()
            .min(count as u64)
            .max(1);
        encoder.dispatch_threads(MTLSize::new(count as u64, 1, 1), MTLSize::new(width, 1, 1));
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalNativeError(format!(
                "spatial Metal command ended with status {:?}",
                command.status()
            )));
        }
        // SAFETY: the shared buffer has exactly `count` float4 values, the command has completed,
        // and every value is copied into an owned result before the Metal allocation is released.
        let gpu =
            unsafe { core::slice::from_raw_parts(output.contents().cast::<[f32; 4]>(), count) };
        if gpu
            .iter()
            .any(|pixel| pixel[..3].iter().any(|value| !value.is_finite()))
        {
            return Err(MetalNativeError(
                "spatial Metal result contains a non-finite value".to_owned(),
            ));
        }
        Ok(gpu
            .iter()
            .map(|pixel| LinearOpticalPixel {
                acescg_irradiance: LinearRgb::new(pixel[0], pixel[1], pixel[2]),
                on_panel: pixel[3] != 0.0,
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_application::{
        DeviceSignalRaster, OpticalRequest, PreparedDeviceSignalRaster, ProceduralTestPattern,
        RasterPlacement, evaluate_device_signal_spatial_cpu_oracle,
        evaluate_procedural_spatial_cpu_oracle, prepare_device_signal_spatial_plan,
        prepare_procedural_spatial_plan,
    };
    use screen_contracts::{DeviceRgb, Meters, Millimeters, RationalTime, Vec2, Vec3};
    use screen_cover::{CoverGlassProfile, ProceduralEnvironment};
    use screen_geometry::{
        CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation,
        LensModel, Quaternion, TransformKeyframe, TransformTrack,
    };
    use screen_panel::{LcdProfile, PanelColorimetry, PanelTemporalEmission, StripeLayout};
    use screen_sensor::{SensorProfile, SensorRegion};
    use std::collections::BTreeMap;

    fn request() -> OpticalRequest {
        let time = RationalTime::new(17, 24).expect("valid time");
        OpticalRequest {
            time,
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
                transform: TransformTrack {
                    keyframes: vec![TransformKeyframe {
                        id: "camera".to_owned(),
                        time,
                        translation: Vec3 {
                            x: 0.0,
                            y: 0.0,
                            z: 0.8,
                        },
                        rotation: Quaternion::from_yaw_degrees(0.0),
                        interpolation: KeyframeInterpolation::Hold,
                    }],
                },
                intrinsics: CameraIntrinsicsTrack {
                    keyframes: vec![CameraIntrinsicsKeyframe {
                        id: "lens".to_owned(),
                        time,
                        focal_length: Millimeters(50.0),
                        sensor_width: Millimeters(36.0),
                        sensor_height: Millimeters(20.25),
                        lens_shift: Vec2 { x: 0.0, y: 0.0 },
                        focus_distance: Meters(0.8),
                        f_stop: 8.0,
                        near_clip: Meters(0.01),
                        far_clip: Meters(100.0),
                        lens: LensModel::REFERENCE_PHOTOGRAPHIC,
                        interpolation: KeyframeInterpolation::Hold,
                    }],
                },
            },
            screen: TransformTrack {
                keyframes: vec![TransformKeyframe {
                    id: "screen".to_owned(),
                    time,
                    translation: Vec3 {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                    },
                    rotation: Quaternion::from_yaw_degrees(0.0),
                    interpolation: KeyframeInterpolation::Hold,
                }],
            },
            inspection: None,
            procedural_pattern: ProceduralTestPattern::AnimatedCheckerboard,
        }
    }

    fn sensor_and_region() -> (SensorProfile, SensorRegion) {
        let sensor = SensorProfile {
            native_width: 32,
            native_height: 18,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 7,
            origin_y: 4,
            width: 9,
            height: 7,
        };
        (sensor, region)
    }

    fn assert_spatial_parity(cpu: &[LinearOpticalPixel], gpu: &[LinearOpticalPixel]) {
        assert_eq!(gpu.len(), cpu.len());
        let mut maximum_absolute = 0.0_f32;
        let mut maximum_relative = 0.0_f32;
        for (cpu, gpu) in cpu.iter().zip(gpu) {
            assert_eq!(gpu.on_panel, cpu.on_panel);
            for (expected, actual) in [
                (cpu.acescg_irradiance.r, gpu.acescg_irradiance.r),
                (cpu.acescg_irradiance.g, gpu.acescg_irradiance.g),
                (cpu.acescg_irradiance.b, gpu.acescg_irradiance.b),
            ] {
                let absolute = (expected - actual).abs();
                maximum_absolute = maximum_absolute.max(absolute);
                maximum_relative = maximum_relative.max(absolute / expected.abs().max(1.0e-4));
            }
        }
        assert!(
            maximum_absolute <= 2.0e-3 || maximum_relative <= 2.0e-4,
            "spatial parity exceeded tolerance: max abs {maximum_absolute}, max rel {maximum_relative}"
        );
    }

    #[test]
    fn metal_matches_cpu_spatial_oracle_for_procedural_optics() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let (sensor, region) = sensor_and_region();
        let request = request();
        let cpu = evaluate_procedural_spatial_cpu_oracle(request.clone(), sensor, region)
            .expect("CPU oracle");
        let plan = prepare_procedural_spatial_plan(request, sensor, region).expect("spatial plan");
        let gpu = metal.evaluate_spatial(&plan).expect("Metal spatial result");
        assert_spatial_parity(&cpu, &gpu);
    }

    #[test]
    fn metal_matches_cpu_spatial_oracle_for_raster_extremes() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let (sensor, region) = sensor_and_region();
        let mut request = request();
        request.panel.stripe_layout = StripeLayout::Bgr;
        request.panel.black_matrix_fraction = 0.28;
        request.camera.intrinsics.keyframes[0]
            .lens
            .radial_distortion = [-0.12, 0.035, -0.004];
        request.camera.intrinsics.keyframes[0]
            .lens
            .tangential_distortion = [0.000_7, -0.000_5];
        request.cover.character_strength = 0.85;
        let source = PreparedDeviceSignalRaster::new(DeviceSignalRaster {
            width: 5,
            height: 3,
            pixels: (0..15)
                .map(|index| {
                    DeviceRgb::new(
                        (index % 5) as f32 / 4.0,
                        (index / 5) as f32 / 2.0,
                        if index % 2 == 0 { 1.0 } else { 0.0 },
                    )
                })
                .collect(),
        })
        .expect("prepared raster");
        let cpu = evaluate_device_signal_spatial_cpu_oracle(
            request.clone(),
            sensor,
            region,
            &source,
            RasterPlacement::FillCrop,
        )
        .expect("CPU oracle");
        let plan = prepare_device_signal_spatial_plan(
            request,
            sensor,
            region,
            &source,
            RasterPlacement::FillCrop,
        )
        .expect("spatial plan");
        let gpu = metal.evaluate_spatial(&plan).expect("Metal spatial result");
        assert_spatial_parity(&cpu, &gpu);
    }

    #[test]
    fn metal_matches_every_aperture_quality_level_without_sample_reduction() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let mut plans = BTreeMap::new();
        for width in [32_u16, 128, 512] {
            let sensor = SensorProfile {
                native_width: width,
                native_height: width * 9 / 16,
                ..SensorProfile::REFERENCE
            };
            let region = SensorRegion {
                origin_x: 0,
                origin_y: 0,
                width: 3,
                height: 3,
            };
            for focus_distance in [0.8_f32, 0.7, 0.5, 0.3] {
                for f_stop in [1.4_f32, 2.8, 5.6, 16.0] {
                    let mut request = request();
                    request.camera.intrinsics.keyframes[0].focus_distance = Meters(focus_distance);
                    request.camera.intrinsics.keyframes[0].f_stop = f_stop;
                    let plan = prepare_procedural_spatial_plan(request.clone(), sensor, region)
                        .expect("spatial plan");
                    plans
                        .entry(plan.aperture_sample_count)
                        .or_insert((request, sensor, region, plan));
                }
            }
        }
        assert_eq!(
            plans.keys().copied().collect::<Vec<_>>(),
            vec![16, 32, 64, 128]
        );
        for (sample_count, (request, sensor, region, plan)) in plans {
            assert_eq!(plan.aperture_sample_count, sample_count);
            let cpu = evaluate_procedural_spatial_cpu_oracle(request, sensor, region)
                .expect("CPU oracle");
            let gpu = metal.evaluate_spatial(&plan).expect("Metal spatial result");
            assert_spatial_parity(&cpu, &gpu);
        }
    }
}
