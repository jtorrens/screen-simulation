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
    lens_veiling_glare: [f32; 4],
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
    cover_glow: [f32; 4],
    environment_ambient_strength: [f32; 4],
    environment_key_radius: [f32; 4],
    environment_direction: [f32; 4],
    environment_rotation: [f32; 4],
    procedural_time: [f32; 4],
    pipeline_strengths: [f32; 4],
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
                    EnvironmentPattern::UniformNeutral => 0,
                    EnvironmentPattern::StudioSoftboxes => 1,
                    EnvironmentPattern::CalibrationGrid => 2,
                    EnvironmentPattern::OfficeCeiling => 3,
                    EnvironmentPattern::DaylightWindow => 4,
                    EnvironmentPattern::WarmPracticals => 5,
                    EnvironmentPattern::MixedProduction => 6,
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
            lens_veiling_glare: [
                plan.veiling_glare_gate_average.r,
                plan.veiling_glare_gate_average.g,
                plan.veiling_glare_gate_average.b,
                lens.veiling_glare_fraction,
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
            cover_glow: [
                plan.cover.glow.core_radius_millimeters * 0.001,
                plan.cover.glow.tail_radius_millimeters * 0.001,
                plan.cover.glow.scatter_fraction * plan.cover.glow.character_strength,
                plan.cover.glow.tail_fraction,
            ],
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
            environment_rotation: [
                plan.environment.rotation_x_degrees.to_radians(),
                plan.environment.rotation_y_degrees.to_radians(),
                0.0,
                0.0,
            ],
            procedural_time: [time_seconds, 0.0, 0.0, 0.0],
            pipeline_strengths: [
                plan.panel_character_strength,
                plan.lens_character_strength,
                0.0,
                0.0,
            ],
        }
    }
}

/// Horizontal row prefixes keep every accumulator bounded by the source width. A full 2D `f32`
/// summed-area table grows with the complete raster area; subtracting nearby samples late in a
/// UHD raster then loses the local signal and creates large spatial discontinuities. The shader
/// integrates the small number of source rows crossed by an unresolved sensor footprint.
fn row_prefix(values: &[[f32; 4]], width: u32, height: u32) -> Vec<[f32; 4]> {
    let stride = width as usize + 1;
    let mut result = vec![[0.0; 4]; stride * height as usize];
    for y in 0..height as usize {
        let mut sum = [0.0_f32; 4];
        for x in 0..width as usize {
            let pixel = values[y * width as usize + x];
            sum[0] += pixel[0];
            sum[1] += pixel[1];
            sum[2] += pixel[2];
            result[y * stride + x + 1] = sum;
        }
    }
    result
}

#[cfg(test)]
fn row_prefix_interval(
    prefix: &[[f32; 4]],
    width: u32,
    row: u32,
    start: u32,
    end: u32,
) -> [f32; 4] {
    let stride = width as usize + 1;
    let first = prefix[row as usize * stride + start as usize];
    let last = prefix[row as usize * stride + end as usize];
    [
        last[0] - first[0],
        last[1] - first[1],
        last[2] - first[2],
        last[3] - first[3],
    ]
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
                    row_prefix(&signal, *width, *height),
                    row_prefix(&emission, *width, *height),
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

    fn evaluate_spatial_batch(
        &self,
        plans: &[SpatialOpticalPlan],
    ) -> Result<Vec<Vec<LinearOpticalPixel>>, Self::Error> {
        struct Dispatch {
            signal: metal::Buffer,
            code_integral: metal::Buffer,
            emission_integral: metal::Buffer,
            params: metal::Buffer,
            output: metal::Buffer,
            count: usize,
        }

        if plans.is_empty() {
            return Ok(Vec::new());
        }
        let shared_count = usize::from(plans[0].raster.width) * usize::from(plans[0].raster.height);
        let shares_signal_and_shape = plans.iter().all(|plan| {
            let shared_signal_storage = match (&plans[0].signal, &plan.signal) {
                (SpatialSignalPlan::Procedural { .. }, SpatialSignalPlan::Procedural { .. }) => {
                    true
                }
                (
                    SpatialSignalPlan::Raster {
                        width: first_width,
                        height: first_height,
                        device_signal: first_device,
                        linear_native_emission: first_emission,
                        placement: first_placement,
                    },
                    SpatialSignalPlan::Raster {
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
                        && std::sync::Arc::ptr_eq(first_device, device_signal)
                        && std::sync::Arc::ptr_eq(first_emission, linear_native_emission)
                }
                _ => false,
            };
            usize::from(plan.raster.width) * usize::from(plan.raster.height) == shared_count
                && shared_signal_storage
        });
        if shares_signal_and_shape {
            let placeholder = vec![[0.0_f32; 4]];
            let (signal, code_integral, emission_integral) = match &plans[0].signal {
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
                        row_prefix(&signal, *width, *height),
                        row_prefix(&emission, *width, *height),
                    )
                }
            };
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
            let params = plans.iter().map(SpatialParams::new).collect::<Vec<_>>();
            let params = self.device.new_buffer_with_data(
                params.as_ptr().cast(),
                size_of_val(params.as_slice()) as u64,
                MTLResourceOptions::StorageModeShared,
            );
            let batch = [shared_count as u32, plans.len() as u32];
            let batch = self.device.new_buffer_with_data(
                batch.as_ptr().cast(),
                size_of_val(&batch) as u64,
                MTLResourceOptions::StorageModeShared,
            );
            let total_count = shared_count * plans.len();
            let output = self.device.new_buffer(
                (total_count * size_of::<[f32; 4]>()) as u64,
                MTLResourceOptions::StorageModeShared,
            );
            let command = self.queue.new_command_buffer();
            let encoder = command.new_compute_command_encoder();
            encoder.set_compute_pipeline_state(&self.spatial_batch_pipeline);
            encoder.set_buffer(0, Some(&signal), 0);
            encoder.set_buffer(1, Some(&code_integral), 0);
            encoder.set_buffer(2, Some(&emission_integral), 0);
            encoder.set_buffer(3, Some(&output), 0);
            encoder.set_buffer(4, Some(&params), 0);
            encoder.set_buffer(5, Some(&batch), 0);
            let width = self
                .spatial_batch_pipeline
                .thread_execution_width()
                .min(total_count as u64)
                .max(1);
            encoder.dispatch_threads(
                MTLSize::new(total_count as u64, 1, 1),
                MTLSize::new(width, 1, 1),
            );
            encoder.end_encoding();
            command.commit();
            command.wait_until_completed();
            if command.status() != MTLCommandBufferStatus::Completed {
                return Err(MetalNativeError(format!(
                    "spatial Metal shared batch ended with status {:?}",
                    command.status()
                )));
            }
            // SAFETY: the shared output contains exactly `total_count` float4 values and the
            // command is complete. Every returned pixel is copied before the buffer is released.
            let gpu = unsafe {
                core::slice::from_raw_parts(output.contents().cast::<[f32; 4]>(), total_count)
            };
            if gpu
                .iter()
                .any(|pixel| pixel[..3].iter().any(|value| !value.is_finite()))
            {
                return Err(MetalNativeError(
                    "spatial Metal shared batch contains a non-finite value".to_owned(),
                ));
            }
            return Ok(gpu
                .chunks_exact(shared_count)
                .map(|chunk| {
                    chunk
                        .iter()
                        .map(|pixel| LinearOpticalPixel {
                            acescg_irradiance: LinearRgb::new(pixel[0], pixel[1], pixel[2]),
                            on_panel: pixel[3] != 0.0,
                        })
                        .collect()
                })
                .collect());
        }
        let mut dispatches = Vec::with_capacity(plans.len());
        for plan in plans {
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
                        row_prefix(&signal, *width, *height),
                        row_prefix(&emission, *width, *height),
                    )
                }
            };
            let buffer = |values: &[[f32; 4]]| {
                self.device.new_buffer_with_data(
                    values.as_ptr().cast(),
                    size_of_val(values) as u64,
                    MTLResourceOptions::StorageModeShared,
                )
            };
            let params = SpatialParams::new(plan);
            let count = usize::from(plan.raster.width) * usize::from(plan.raster.height);
            dispatches.push(Dispatch {
                signal: buffer(&signal),
                code_integral: buffer(&code_integral),
                emission_integral: buffer(&emission_integral),
                params: self.device.new_buffer_with_data(
                    core::ptr::from_ref(&params).cast(),
                    size_of::<SpatialParams>() as u64,
                    MTLResourceOptions::StorageModeShared,
                ),
                output: self.device.new_buffer(
                    (count * size_of::<[f32; 4]>()) as u64,
                    MTLResourceOptions::StorageModeShared,
                ),
                count,
            });
        }
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.spatial_pipeline);
        for dispatch in &dispatches {
            encoder.set_buffer(0, Some(&dispatch.signal), 0);
            encoder.set_buffer(1, Some(&dispatch.code_integral), 0);
            encoder.set_buffer(2, Some(&dispatch.emission_integral), 0);
            encoder.set_buffer(3, Some(&dispatch.output), 0);
            encoder.set_buffer(4, Some(&dispatch.params), 0);
            let width = self
                .spatial_pipeline
                .thread_execution_width()
                .min(dispatch.count as u64)
                .max(1);
            encoder.dispatch_threads(
                MTLSize::new(dispatch.count as u64, 1, 1),
                MTLSize::new(width, 1, 1),
            );
        }
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalNativeError(format!(
                "spatial Metal batch ended with status {:?}",
                command.status()
            )));
        }
        dispatches
            .iter()
            .map(|dispatch| {
                // SAFETY: each shared output has `count` float4 values, the shared command has
                // completed, and values are copied before the Metal allocation is released.
                let gpu = unsafe {
                    core::slice::from_raw_parts(
                        dispatch.output.contents().cast::<[f32; 4]>(),
                        dispatch.count,
                    )
                };
                if gpu
                    .iter()
                    .any(|pixel| pixel[..3].iter().any(|value| !value.is_finite()))
                {
                    return Err(MetalNativeError(
                        "spatial Metal batch contains a non-finite value".to_owned(),
                    ));
                }
                Ok(gpu
                    .iter()
                    .map(|pixel| LinearOpticalPixel {
                        acescg_irradiance: LinearRgb::new(pixel[0], pixel[1], pixel[2]),
                        on_panel: pixel[3] != 0.0,
                    })
                    .collect())
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_application::{
        CAPTURE_DEVICE_PRESETS, DeviceSignalRaster, FrameCaptureRequest, OpticalRequest,
        PanelTemporalEvaluation, PreparedDeviceSignalRaster, ProceduralTestPattern,
        RasterPlacement, RollingDirection, SensorReadout,
        capture_and_develop_procedural_region_with_backend,
        capture_and_develop_procedural_region_with_compute_backends,
        evaluate_device_signal_spatial_cpu_oracle, evaluate_procedural_spatial_cpu_oracle,
        prepare_device_signal_spatial_plan, prepare_procedural_spatial_plan,
    };
    use screen_camera::CameraDevelopment;
    use screen_contracts::{DeviceRgb, FrameRate, Meters, Millimeters, RationalTime, Vec2, Vec3};
    use screen_cover::{
        COVER_GLASS_PRESETS, CoverGlassProfile, ENVIRONMENT_PRESETS, ProceduralEnvironment,
    };
    use screen_geometry::{
        CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation,
        LensModel, Quaternion, TransformKeyframe, TransformTrack, lens_preset,
    };
    use screen_panel::{
        AnalyticBanding, LcdProfile, PanelColorimetry, PanelTemporalEmission, StripeLayout,
        device_preset,
    };
    use screen_sensor::{SensorProfile, SensorRegion};
    use std::collections::BTreeMap;

    #[test]
    fn row_prefix_preserves_local_energy_late_in_a_large_bright_raster() {
        let width = 3_840;
        let height = 2_160;
        let value = [350.0_f32, 175.0, 87.5, 0.0];
        let source = vec![value; width as usize * height as usize];
        let prefix = row_prefix(&source, width, height);
        for row in [0, height / 2, height - 1] {
            let interval = row_prefix_interval(&prefix, width, row, width - 1, width);
            for channel in 0..3 {
                assert!(
                    (interval[channel] - value[channel]).abs() <= value[channel] * 5.0e-4,
                    "row {row} channel {channel} lost local energy: expected {}, got {}",
                    value[channel],
                    interval[channel]
                );
            }
        }
    }

    fn request() -> OpticalRequest {
        let time = RationalTime::new(17, 24).expect("valid time");
        OpticalRequest {
            time,
            panel_temporal_evaluation: PanelTemporalEvaluation::Instantaneous,
            panel_character_strength: 1.0,
            lens_character_strength: 1.0,
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
            environment: ProceduralEnvironment::NONE,
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
        let (
            maximum_absolute,
            maximum_relative,
            rms,
            components_over_tolerance,
            component_count,
            maximum_pair,
        ) = spatial_parity_metrics(cpu, gpu);
        assert!(
            maximum_absolute <= 2.0e-3 || maximum_relative <= 2.0e-4,
            "spatial parity exceeded tolerance: max abs {maximum_absolute}, max rel {maximum_relative}, rms {rms}, components over tolerance {components_over_tolerance}/{component_count}, max pair {maximum_pair:?}"
        );
    }

    fn assert_resolved_panel_spatial_parity(
        cpu: &[LinearOpticalPixel],
        gpu: &[LinearOpticalPixel],
    ) {
        let (
            maximum_absolute,
            maximum_relative,
            rms,
            components_over_tolerance,
            component_count,
            maximum_pair,
        ) = spatial_parity_metrics(cpu, gpu);
        // At native sensor phase, infinitesimal CPU/Metal coordinate differences can cross a
        // procedural subpixel boundary. Bound both the sparse outliers and aggregate energy;
        // smooth/raster cases continue to use the strict component-wise assertion above.
        assert!(
            maximum_absolute <= 0.2
                && maximum_relative <= 0.01
                && rms <= 0.01
                && components_over_tolerance * 50 <= component_count,
            "resolved-panel spatial parity exceeded tolerance: max abs {maximum_absolute}, max rel {maximum_relative}, rms {rms}, components over strict tolerance {components_over_tolerance}/{component_count}, max pair {maximum_pair:?}"
        );
    }

    fn spatial_parity_metrics(
        cpu: &[LinearOpticalPixel],
        gpu: &[LinearOpticalPixel],
    ) -> (f32, f32, f64, u64, u64, (f32, f32)) {
        assert_eq!(gpu.len(), cpu.len());
        let mut maximum_absolute = 0.0_f32;
        let mut maximum_relative = 0.0_f32;
        let mut maximum_pair = (0.0_f32, 0.0_f32);
        let mut squared_error = 0.0_f64;
        let mut component_count = 0_u64;
        let mut components_over_tolerance = 0_u64;
        for (cpu, gpu) in cpu.iter().zip(gpu) {
            assert_eq!(gpu.on_panel, cpu.on_panel);
            for (expected, actual) in [
                (cpu.acescg_irradiance.r, gpu.acescg_irradiance.r),
                (cpu.acescg_irradiance.g, gpu.acescg_irradiance.g),
                (cpu.acescg_irradiance.b, gpu.acescg_irradiance.b),
            ] {
                let absolute = (expected - actual).abs();
                if absolute > maximum_absolute {
                    maximum_absolute = absolute;
                    maximum_pair = (expected, actual);
                }
                let relative = absolute / expected.abs().max(1.0e-4);
                maximum_relative = maximum_relative.max(relative);
                squared_error += f64::from(absolute) * f64::from(absolute);
                component_count += 1;
                if absolute > 2.0e-3 && relative > 2.0e-4 {
                    components_over_tolerance += 1;
                }
            }
        }
        let rms = (squared_error / component_count as f64).sqrt();
        (
            maximum_absolute,
            maximum_relative,
            rms,
            components_over_tolerance,
            component_count,
            maximum_pair,
        )
    }

    #[test]
    fn metal_matches_cpu_spatial_oracle_for_procedural_optics() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let (sensor, region) = sensor_and_region();
        for pattern in [
            ProceduralTestPattern::AnimatedCheckerboard,
            ProceduralTestPattern::EyeChart,
            ProceduralTestPattern::PhotometricDeviceScale,
        ] {
            for strength in [0.0, 1.0, 2.0] {
                let mut request = request();
                request.procedural_pattern = pattern;
                request.panel_character_strength = strength;
                request.lens_character_strength = strength;
                let cpu = evaluate_procedural_spatial_cpu_oracle(request.clone(), sensor, region)
                    .expect("CPU oracle");
                let plan =
                    prepare_procedural_spatial_plan(request, sensor, region).expect("spatial plan");
                let gpu = metal.evaluate_spatial(&plan).expect("Metal spatial result");
                assert_spatial_parity(&cpu, &gpu);
            }
        }
    }

    #[test]
    fn metal_matches_all_synthetic_hdr_environments_and_rotation() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let (sensor, region) = sensor_and_region();
        for preset in ENVIRONMENT_PRESETS {
            let mut request = request();
            request.cover = COVER_GLASS_PRESETS[1].profile;
            request.environment = preset.environment;
            request.environment.rotation_y_degrees = 37.0;
            let cpu = evaluate_procedural_spatial_cpu_oracle(request.clone(), sensor, region)
                .expect("CPU synthetic HDR oracle");
            let plan =
                prepare_procedural_spatial_plan(request, sensor, region).expect("spatial plan");
            let gpu = metal.evaluate_spatial(&plan).expect("Metal spatial result");
            assert_spatial_parity(&cpu, &gpu);
        }
    }

    #[test]
    fn metal_matches_cpu_at_full_iphone_sensor_phase_with_resolved_uhd_panel() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let iphone = CAPTURE_DEVICE_PRESETS
            .iter()
            .find(|preset| preset.id == "iphone-16e-main-48mp")
            .expect("current iPhone capture preset");
        let device = device_preset("lcd-asus-proart-pa329cv").expect("current ASUS panel preset");
        let time = RationalTime::new(0, 24).expect("valid time");
        let distance = 0.15_f32;
        let yaw_degrees = -5.0_f32;
        let yaw = yaw_degrees.to_radians();
        let mut request = request();
        request.time = time;
        request.viewport_aspect =
            f32::from(iphone.sensor.native_width) / f32::from(iphone.sensor.native_height);
        request.panel.native_width = device.native_width;
        request.panel.native_height = device.native_height;
        request.panel.active_width = device.active_width;
        request.panel.active_height = device.active_height;
        request.panel.white_level_nits = device.reference_white_nits;
        request.cover = CoverGlassProfile::NEUTRAL;
        request.environment = ProceduralEnvironment::NONE;
        request.camera = CameraRig {
            transform: TransformTrack {
                keyframes: vec![TransformKeyframe {
                    id: "full-sensor-camera".to_owned(),
                    time,
                    translation: Vec3 {
                        x: distance * yaw.sin(),
                        y: 0.0,
                        z: distance * yaw.cos(),
                    },
                    rotation: Quaternion::from_orbit_yaw_pitch_degrees(yaw_degrees, 0.0),
                    interpolation: KeyframeInterpolation::Hold,
                }],
            },
            intrinsics: CameraIntrinsicsTrack {
                keyframes: vec![CameraIntrinsicsKeyframe {
                    id: "full-sensor-lens".to_owned(),
                    time,
                    focal_length: lens_preset(iphone.default_lens_preset_id)
                        .expect("current iPhone integrated lens")
                        .nominal_focal_length,
                    sensor_width: iphone.gate_width,
                    sensor_height: iphone.gate_height,
                    lens_shift: Vec2 { x: 0.0, y: 0.0 },
                    focus_distance: Meters(distance),
                    f_stop: 1.6,
                    near_clip: Meters(0.01),
                    far_clip: Meters(100.0),
                    lens: lens_preset(iphone.default_lens_preset_id)
                        .expect("current iPhone integrated lens")
                        .lens,
                    interpolation: KeyframeInterpolation::Hold,
                }],
            },
        };
        request.screen = TransformTrack {
            keyframes: vec![TransformKeyframe {
                id: "full-sensor-screen".to_owned(),
                time,
                translation: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
                rotation: Quaternion::from_yaw_degrees(0.0),
                interpolation: KeyframeInterpolation::Hold,
            }],
        };
        request.procedural_pattern = ProceduralTestPattern::EyeChart;
        let region = SensorRegion {
            origin_x: 5_600,
            origin_y: 3_700,
            width: 24,
            height: 24,
        };
        let cpu = evaluate_procedural_spatial_cpu_oracle(request.clone(), iphone.sensor, region)
            .expect("CPU full-sensor-phase oracle");
        let plan = prepare_procedural_spatial_plan(request, iphone.sensor, region)
            .expect("full-sensor-phase spatial plan");
        assert_eq!(plan.aperture_sample_count, 256);
        let gpu = metal
            .evaluate_spatial(&plan)
            .expect("Metal full-sensor-phase result");
        assert_resolved_panel_spatial_parity(&cpu, &gpu);
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
            alpha: vec![1.0; 15],
        })
        .expect("prepared raster");
        for placement in [
            RasterPlacement::Fit,
            RasterPlacement::FillCrop,
            RasterPlacement::Stretch,
            RasterPlacement::OneToOne,
        ] {
            let cpu = evaluate_device_signal_spatial_cpu_oracle(
                request.clone(),
                sensor,
                region,
                &source,
                placement,
            )
            .expect("CPU oracle");
            let plan = prepare_device_signal_spatial_plan(
                request.clone(),
                sensor,
                region,
                &source,
                placement,
            )
            .expect("spatial plan");
            let gpu = metal.evaluate_spatial(&plan).expect("Metal spatial result");
            assert_spatial_parity(&cpu, &gpu);
        }
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
            vec![16, 32, 64, 128, 256, 512]
        );
        for (sample_count, (request, sensor, region, plan)) in plans {
            assert_eq!(plan.aperture_sample_count, sample_count);
            let cpu = evaluate_procedural_spatial_cpu_oracle(request, sensor, region)
                .expect("CPU oracle");
            let gpu = metal.evaluate_spatial(&plan).expect("Metal spatial result");
            assert_spatial_parity(&cpu, &gpu);
        }
    }

    #[test]
    fn spatial_metal_is_bit_deterministic_for_one_prepared_plan() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let (sensor, region) = sensor_and_region();
        let plan =
            prepare_procedural_spatial_plan(request(), sensor, region).expect("spatial plan");
        let first = metal.evaluate_spatial(&plan).expect("first Metal result");
        let second = metal.evaluate_spatial(&plan).expect("second Metal result");
        assert_eq!(second, first);
    }

    #[test]
    fn complete_rolling_capture_preserves_cpu_oracle_codes_with_eight_motion_samples() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let (sensor, region) = sensor_and_region();
        let capture = FrameCaptureRequest {
            optics: request(),
            frame_rate: FrameRate::new(24, 1).expect("frame rate"),
            frame_index: 17,
            duration: RationalTime::new(1, 192).expect("shutter"),
            temporal_samples: 8,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 80).expect("readout"),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
            noise_seed: 0x5EED,
        };
        let development = CameraDevelopment {
            white_balance: LinearRgb::new(1.7, 1.0, 0.65),
            middle_gray_illuminance_seconds: 0.05,
            develop_exposure_ev: 0.75,
        };
        let cpu = capture_and_develop_procedural_region_with_backend(
            capture.clone(),
            sensor,
            development,
            region,
            &metal,
        )
        .expect("CPU spatial oracle capture");
        let gpu = capture_and_develop_procedural_region_with_compute_backends(
            capture,
            sensor,
            development,
            region,
            &metal,
            &metal,
        )
        .expect("complete Metal capture");
        assert_eq!(gpu.raw.codes, cpu.raw.codes);
        assert_eq!(gpu.raw.full_well_clipped, cpu.raw.full_well_clipped);
        assert_eq!(gpu.raw.adc_clipped, cpu.raw.adc_clipped);
        for (expected, actual) in cpu.developed.acescg.iter().zip(&gpu.developed.acescg) {
            for difference in [
                (expected.r - actual.r).abs(),
                (expected.g - actual.g).abs(),
                (expected.b - actual.b).abs(),
            ] {
                assert!(difference <= 2.0e-5, "developed difference {difference}");
            }
        }
    }

    #[test]
    fn static_reuse_matches_cpu_for_rolling_analytic_banding_and_eight_samples() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let (sensor, region) = sensor_and_region();
        let mut optics = request();
        optics.procedural_pattern = ProceduralTestPattern::EyeChart;
        optics.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 100).expect("period"),
            on_duration: RationalTime::new(1, 250).expect("duty"),
            phase: RationalTime::new(1, 1_000).expect("phase"),
            amount: 0.8,
        };
        let capture = FrameCaptureRequest {
            optics,
            frame_rate: FrameRate::new(24, 1).expect("frame rate"),
            frame_index: 17,
            duration: RationalTime::new(1, 800).expect("shutter"),
            temporal_samples: 8,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 100).expect("readout"),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
            noise_seed: 0x0B4A_D1A6,
        };
        let development = CameraDevelopment {
            white_balance: LinearRgb::new(1.7, 1.0, 0.65),
            middle_gray_illuminance_seconds: 0.05,
            develop_exposure_ev: 0.75,
        };
        let cpu = capture_and_develop_procedural_region_with_backend(
            capture.clone(),
            sensor,
            development,
            region,
            &metal,
        )
        .expect("CPU spatial oracle capture");
        let gpu = capture_and_develop_procedural_region_with_compute_backends(
            capture,
            sensor,
            development,
            region,
            &metal,
            &metal,
        )
        .expect("reused Metal capture");
        assert_eq!(gpu.raw.codes, cpu.raw.codes);
        assert_eq!(gpu.raw.full_well_clipped, cpu.raw.full_well_clipped);
        assert_eq!(gpu.raw.adc_clipped, cpu.raw.adc_clipped);
        for (expected, actual) in cpu.developed.acescg.iter().zip(&gpu.developed.acescg) {
            for difference in [
                (expected.r - actual.r).abs(),
                (expected.g - actual.g).abs(),
                (expected.b - actual.b).abs(),
            ] {
                assert!(difference <= 2.0e-5, "developed difference {difference}");
            }
        }
    }

    #[test]
    fn horizontal_supertile_is_exactly_equivalent_to_logical_tiles() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        let sensor = SensorProfile {
            native_width: 32,
            native_height: 18,
            ..SensorProfile::REFERENCE
        };
        let stripe = SensorRegion {
            origin_x: 4,
            origin_y: 4,
            width: 18,
            height: 7,
        };
        let tiles = [
            SensorRegion { width: 9, ..stripe },
            SensorRegion {
                origin_x: 13,
                width: 9,
                ..stripe
            },
        ];
        let mut optics = request();
        optics.procedural_pattern = ProceduralTestPattern::EyeChart;
        optics.panel.temporal_emission.analytic_banding = AnalyticBanding {
            period: RationalTime::new(1, 100).expect("period"),
            on_duration: RationalTime::new(1, 250).expect("duty"),
            phase: RationalTime::new(1, 1_000).expect("phase"),
            amount: 0.8,
        };
        let capture = FrameCaptureRequest {
            optics,
            frame_rate: FrameRate::new(24, 1).expect("frame rate"),
            frame_index: 17,
            duration: RationalTime::new(1, 800).expect("shutter"),
            temporal_samples: 8,
            readout: SensorReadout::Rolling {
                duration: RationalTime::new(1, 100).expect("readout"),
                direction: RollingDirection::TopToBottom,
            },
            neutral_density_stops: 0.0,
            noise_seed: 0x051A_17E5,
        };
        let development = CameraDevelopment {
            white_balance: LinearRgb::new(1.7, 1.0, 0.65),
            middle_gray_illuminance_seconds: 0.05,
            develop_exposure_ev: 0.75,
        };
        let combined = capture_and_develop_procedural_region_with_compute_backends(
            capture.clone(),
            sensor,
            development,
            stripe,
            &metal,
            &metal,
        )
        .expect("stripe capture");
        for tile in tiles {
            let separate = capture_and_develop_procedural_region_with_compute_backends(
                capture.clone(),
                sensor,
                development,
                tile,
                &metal,
                &metal,
            )
            .expect("logical tile capture");
            for row in 0..usize::from(tile.height) {
                let combined_start =
                    row * usize::from(stripe.width) + usize::from(tile.origin_x - stripe.origin_x);
                let separate_start = row * usize::from(tile.width);
                assert_eq!(
                    &combined.developed.acescg
                        [combined_start..combined_start + usize::from(tile.width)],
                    &separate.developed.acescg
                        [separate_start..separate_start + usize::from(tile.width)]
                );
            }
        }
    }
}
