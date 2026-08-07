use core::fmt;
use core::mem::size_of;
use std::time::Instant;

use metal::{
    ComputePipelineState, DeviceRef, MTLCommandBufferStatus, MTLResourceOptions, MTLSize,
    MTLStorageMode, MTLTextureType, MTLTextureUsage, Texture, TextureDescriptor, TextureRef,
};
use screen_application::{
    PhysicalIntermediate, PhysicalPipelineExecutionPlan, RasterPlacement,
    physical_row_temporal_gain,
};
use screen_cover::EnvironmentPattern;
use screen_panel::{FlatPanelGeometry, FlatPanelSampling, StripeLayout};

const SHADER_LIBRARY: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/native_camera.metallib"));
const TILE_ROWS: u32 = 64;

fn inverse3(matrix: [[f32; 3]; 3]) -> Option<[[f32; 3]; 3]> {
    let determinant = matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1])
        - matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0])
        + matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if !determinant.is_finite() || determinant.abs() < 1.0e-8 {
        return None;
    }
    let reciprocal = determinant.recip();
    Some([
        [
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * reciprocal,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * reciprocal,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * reciprocal,
        ],
        [
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * reciprocal,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * reciprocal,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * reciprocal,
        ],
        [
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * reciprocal,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * reciprocal,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * reciprocal,
        ],
    ])
}

#[repr(C)]
#[derive(Clone, Copy)]
struct PhysicalPipelineParams {
    source_panel: [u32; 4],
    output_tile: [u32; 4],
    semantics: [u32; 4],
    levels: [f32; 4],
    geometry: [f32; 4],
    strengths: [f32; 4],
    matrix0: [f32; 4],
    matrix1: [f32; 4],
    matrix2: [f32; 4],
    panel_size_meters: [f32; 4],
    spread_core_radius: [f32; 4],
    spread_core_weight: [f32; 4],
    spread_tail_radius: [f32; 4],
    spread_tail_weight: [f32; 4],
    cover_geometry: [f32; 4],
    cover_absorption_roughness: [f32; 4],
    cover_haze: [f32; 4],
    environment_ambient_strength: [f32; 4],
    environment_key_radius: [f32; 4],
    environment_direction_rotation: [f32; 4],
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
    panel_angular_scene: [f32; 4],
    shutter: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct SensorExposureParams {
    input_width: u32,
    input_height: u32,
    width: u32,
    height: u32,
    pattern: u32,
    maximum_code: u32,
    frame_index: i64,
    noise_seed: u64,
    duration_seconds: f32,
    full_well_electrons: f32,
    dark_current_electrons_per_second: f32,
    read_noise_electrons_rms: f32,
    analog_gain: f32,
    noise_amount: f32,
    input_luminance_scale: [f32; 4],
    acescg_to_sensor_0: [f32; 4],
    acescg_to_sensor_1: [f32; 4],
    acescg_to_sensor_2: [f32; 4],
    saturation: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CameraDevelopmentParams {
    width: u32,
    height: u32,
    origin_x: u32,
    origin_y: u32,
    pattern: u32,
    maximum_code: u32,
    analog_gain: f32,
    linear_scale: f32,
    saturation: [f32; 4],
    white_balance: [f32; 4],
    sensor_to_acescg_0: [f32; 4],
    sensor_to_acescg_1: [f32; 4],
    sensor_to_acescg_2: [f32; 4],
}

pub struct MetalPhysicalPipeline {
    queue: metal::CommandQueue,
    pipeline: ComputePipelineState,
    accumulator: ComputePipelineState,
    sensor_pipeline: ComputePipelineState,
    publish_raw_pipeline: ComputePipelineState,
    reconstruct_green_pipeline: ComputePipelineState,
    develop_pipeline: ComputePipelineState,
    publish_developed_pipeline: ComputePipelineState,
}

pub struct MetalPhysicalPipelineResult {
    pub texture: Texture,
    pub geometry: FlatPanelGeometry,
    pub sampling: FlatPanelSampling,
    pub stage_elapsed_nanoseconds: [u64; 12],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MetalPhysicalPipelineError {
    InvalidPlan(String),
    TextureMismatch,
    UnsupportedTexture,
    Cancelled,
    Backend(String),
}

impl fmt::Display for MetalPhysicalPipelineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPlan(message) => write!(formatter, "invalid physical pipeline plan: {message}"),
            Self::TextureMismatch => formatter.write_str(
                "source ACEScg and resolved device-signal textures must have the same non-zero raster",
            ),
            Self::UnsupportedTexture => formatter.write_str(
                "physical pipeline textures must be two-dimensional RGBA16Float or RGBA32Float",
            ),
            Self::Cancelled => formatter.write_str("physical pipeline evaluation was cancelled"),
            Self::Backend(message) => write!(formatter, "Metal physical pipeline backend failed: {message}"),
        }
    }
}

impl std::error::Error for MetalPhysicalPipelineError {}

impl MetalPhysicalPipeline {
    pub fn new(device: &DeviceRef) -> Result<Self, MetalPhysicalPipelineError> {
        let library = device
            .new_library_with_data(SHADER_LIBRARY)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let function = library
            .get_function("evaluate_physical_pipeline", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let pipeline = device
            .new_compute_pipeline_state_with_function(&function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let accumulator_function = library
            .get_function("accumulate_physical_pipeline", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let accumulator = device
            .new_compute_pipeline_state_with_function(&accumulator_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let sensor_function = library
            .get_function("expose_sensor_raw", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let sensor_pipeline = device
            .new_compute_pipeline_state_with_function(&sensor_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let publish_raw_function = library
            .get_function("publish_sensor_raw", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let publish_raw_pipeline = device
            .new_compute_pipeline_state_with_function(&publish_raw_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let reconstruct_green_function = library
            .get_function("reconstruct_green", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let reconstruct_green_pipeline = device
            .new_compute_pipeline_state_with_function(&reconstruct_green_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let develop_function = library
            .get_function("develop_acescg", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let develop_pipeline = device
            .new_compute_pipeline_state_with_function(&develop_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let publish_developed_function = library
            .get_function("publish_developed_acescg", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let publish_developed_pipeline = device
            .new_compute_pipeline_state_with_function(&publish_developed_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        Ok(Self {
            queue: device.new_command_queue(),
            pipeline,
            accumulator,
            sensor_pipeline,
            publish_raw_pipeline,
            reconstruct_green_pipeline,
            develop_pipeline,
            publish_developed_pipeline,
        })
    }

    fn evaluate_sensor_raw(
        &self,
        physical: MetalPhysicalPipelineResult,
        plan: PhysicalPipelineExecutionPlan,
        mut report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        if !plan.sensor_enabled {
            report_progress(1.0);
            return Ok(physical);
        }
        if is_cancelled() {
            return Err(MetalPhysicalPipelineError::Cancelled);
        }
        let capture_started = Instant::now();
        let sensor = plan
            .sensor
            .validate()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        let panel_white_nits = plan
            .panel
            .evaluator()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?
            .device_stage_parameters()
            .white_level_nits;
        let duration_seconds = plan
            .shutter_close
            .checked_sub(plan.shutter_open)
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?
            .as_seconds() as f32;
        let pad = |row: [f32; 3]| [row[0], row[1], row[2], 0.0];
        let parameters = SensorExposureParams {
            input_width: physical.texture.width() as u32,
            input_height: physical.texture.height() as u32,
            width: u32::from(sensor.native_width),
            height: u32::from(sensor.native_height),
            pattern: match sensor.bayer_pattern {
                screen_sensor::BayerPattern::Rggb => 0,
                screen_sensor::BayerPattern::Bggr => 1,
                screen_sensor::BayerPattern::Grbg => 2,
                screen_sensor::BayerPattern::Gbrg => 3,
            },
            maximum_code: (1_u32 << sensor.adc_bits) - 1,
            frame_index: plan.frame_index,
            noise_seed: plan.shutter_motion.noise_seed,
            duration_seconds,
            full_well_electrons: sensor.full_well_electrons,
            dark_current_electrons_per_second: sensor.dark_current_electrons_per_second,
            read_noise_electrons_rms: sensor.read_noise_electrons_rms,
            analog_gain: sensor.analog_gain,
            noise_amount: plan.sensor_noise_amount,
            input_luminance_scale: [panel_white_nits, 0.0, 0.0, 0.0],
            acescg_to_sensor_0: pad(sensor.acescg_to_sensor[0]),
            acescg_to_sensor_1: pad(sensor.acescg_to_sensor[1]),
            acescg_to_sensor_2: pad(sensor.acescg_to_sensor[2]),
            saturation: [
                sensor.saturation_illuminance_seconds.r,
                sensor.saturation_illuminance_seconds.g,
                sensor.saturation_illuminance_seconds.b,
                0.0,
            ],
        };
        let count = usize::from(sensor.native_width) * usize::from(sensor.native_height);
        let device = physical.texture.device();
        let codes = device.new_buffer(
            (count * size_of::<u16>()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let clipping = device.new_buffer(
            (count * size_of::<[u8; 2]>()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let development_parameters = if plan.development_enabled
            && plan.requested_intermediate == PhysicalIntermediate::DevelopedAcesCg
        {
            let development = plan
                .development
                .validate()
                .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
            let inverse = inverse3(sensor.acescg_to_sensor).ok_or_else(|| {
                MetalPhysicalPipelineError::InvalidPlan(
                    "sensor color matrix cannot be inverted for development".to_owned(),
                )
            })?;
            Some(CameraDevelopmentParams {
                width: u32::from(sensor.native_width),
                height: u32::from(sensor.native_height),
                origin_x: 0,
                origin_y: 0,
                pattern: parameters.pattern,
                maximum_code: parameters.maximum_code,
                analog_gain: sensor.analog_gain,
                linear_scale: 0.18 / development.middle_gray_illuminance_seconds
                    * development.develop_exposure_ev.exp2(),
                saturation: parameters.saturation,
                white_balance: [
                    development.white_balance.r,
                    development.white_balance.g,
                    development.white_balance.b,
                    0.0,
                ],
                sensor_to_acescg_0: pad(inverse[0]),
                sensor_to_acescg_1: pad(inverse[1]),
                sensor_to_acescg_2: pad(inverse[2]),
            })
        } else {
            None
        };
        if plan.requested_intermediate == PhysicalIntermediate::DevelopedAcesCg
            && development_parameters.is_none()
        {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "developed output requires the explicit development stage".to_owned(),
            ));
        }
        let green = development_parameters.as_ref().map(|_| {
            device.new_buffer(
                (count * size_of::<f32>()) as u64,
                MTLResourceOptions::StorageModeShared,
            )
        });
        let developed = development_parameters.as_ref().map(|_| {
            device.new_buffer(
                (count * size_of::<[f32; 4]>()) as u64,
                MTLResourceOptions::StorageModeShared,
            )
        });
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_pixel_format(metal::MTLPixelFormat::RGBA32Float);
        descriptor.set_width(u64::from(sensor.native_width));
        descriptor.set_height(u64::from(sensor.native_height));
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
        let output = device.new_texture(&descriptor);
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.sensor_pipeline);
        encoder.set_texture(0, Some(&physical.texture));
        encoder.set_buffer(0, Some(&codes), 0);
        encoder.set_buffer(1, Some(&clipping), 0);
        encoder.set_bytes(
            2,
            size_of::<SensorExposureParams>() as u64,
            (&raw const parameters).cast(),
        );
        let thread_width = self.sensor_pipeline.thread_execution_width();
        let thread_height =
            (self.sensor_pipeline.max_total_threads_per_threadgroup() / thread_width).max(1);
        encoder.dispatch_threads(
            MTLSize::new(
                u64::from(sensor.native_width),
                u64::from(sensor.native_height),
                1,
            ),
            MTLSize::new(thread_width, thread_height, 1),
        );
        encoder.memory_barrier_with_resources(&[&codes, &clipping]);
        if let (Some(development), Some(green), Some(developed)) =
            (development_parameters, green.as_ref(), developed.as_ref())
        {
            encoder.set_compute_pipeline_state(&self.reconstruct_green_pipeline);
            encoder.set_buffer(0, Some(&codes), 0);
            encoder.set_buffer(1, Some(green), 0);
            encoder.set_bytes(
                2,
                size_of::<CameraDevelopmentParams>() as u64,
                (&raw const development).cast(),
            );
            let one_dimensional_width = self
                .reconstruct_green_pipeline
                .thread_execution_width()
                .min(count as u64)
                .max(1);
            encoder.dispatch_threads(
                MTLSize::new(count as u64, 1, 1),
                MTLSize::new(one_dimensional_width, 1, 1),
            );
            encoder.memory_barrier_with_resources(&[green]);
            encoder.set_compute_pipeline_state(&self.develop_pipeline);
            encoder.set_buffer(0, Some(&codes), 0);
            encoder.set_buffer(1, Some(green), 0);
            encoder.set_buffer(2, Some(developed), 0);
            encoder.set_bytes(
                3,
                size_of::<CameraDevelopmentParams>() as u64,
                (&raw const development).cast(),
            );
            encoder.dispatch_threads(
                MTLSize::new(count as u64, 1, 1),
                MTLSize::new(one_dimensional_width, 1, 1),
            );
            encoder.memory_barrier_with_resources(&[developed]);
            encoder.set_compute_pipeline_state(&self.publish_developed_pipeline);
            encoder.set_buffer(0, Some(developed), 0);
            encoder.set_texture(0, Some(&output));
            encoder.set_bytes(
                1,
                size_of::<CameraDevelopmentParams>() as u64,
                (&raw const development).cast(),
            );
        } else {
            encoder.set_compute_pipeline_state(&self.publish_raw_pipeline);
            encoder.set_buffer(0, Some(&codes), 0);
            encoder.set_buffer(1, Some(&clipping), 0);
            encoder.set_texture(0, Some(&output));
            encoder.set_bytes(
                2,
                size_of::<SensorExposureParams>() as u64,
                (&raw const parameters).cast(),
            );
        }
        encoder.dispatch_threads(
            MTLSize::new(
                u64::from(sensor.native_width),
                u64::from(sensor.native_height),
                1,
            ),
            MTLSize::new(thread_width, thread_height, 1),
        );
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalPhysicalPipelineError::Backend(
                "sensor exposure command did not complete".to_owned(),
            ));
        }
        report_progress(1.0);
        let mut stage_elapsed_nanoseconds = physical.stage_elapsed_nanoseconds;
        let capture_elapsed = capture_started
            .elapsed()
            .as_nanos()
            .min(u128::from(u64::MAX)) as u64;
        stage_elapsed_nanoseconds[9] = capture_elapsed;
        stage_elapsed_nanoseconds[10] = capture_elapsed;
        if plan.development_enabled {
            stage_elapsed_nanoseconds[11] = capture_elapsed;
        }
        Ok(MetalPhysicalPipelineResult {
            texture: output,
            geometry: physical.geometry,
            sampling: physical.sampling,
            stage_elapsed_nanoseconds,
        })
    }

    /// Evaluates a Rust-scheduled global or row-addressed rolling sequence on
    /// Metal and accumulates normalized quadrature weights per output row.
    pub fn evaluate_temporal(
        &self,
        samples: &[(
            &TextureRef,
            &TextureRef,
            PhysicalPipelineExecutionPlan,
            f32,
            Option<u32>,
        )],
        mut report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        if samples.is_empty() {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "temporal schedule is empty".to_owned(),
            ));
        }
        let weight_sum = samples.iter().map(|sample| sample.3).sum::<f32>();
        if !weight_sum.is_finite() || weight_sum <= 0.0 {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "temporal weights must have a positive finite sum".to_owned(),
            ));
        }
        let mut accumulated: Option<Texture> = None;
        let mut final_geometry = None;
        let mut final_sampling = None;
        let mut stage_elapsed_nanoseconds = [0_u64; 12];
        for (index, (source, signal, plan, weight, row)) in samples.iter().enumerate() {
            if is_cancelled() {
                return Err(MetalPhysicalPipelineError::Cancelled);
            }
            let base = index as f32 / samples.len() as f32;
            let span = 0.85 / samples.len() as f32;
            let row_range = row.map(|row| (row, 1));
            let mut physical_plan = *plan;
            if physical_plan.sensor_enabled {
                physical_plan.sensor_enabled = false;
                physical_plan.requested_intermediate = PhysicalIntermediate::ShutterMotion;
            }
            let evaluated = self.evaluate_rows(
                source,
                signal,
                physical_plan,
                row_range,
                |progress| report_progress(base + progress * span),
                &is_cancelled,
            )?;
            let output = accumulated.get_or_insert_with(|| {
                let descriptor = TextureDescriptor::new();
                descriptor.set_texture_type(MTLTextureType::D2);
                descriptor.set_pixel_format(metal::MTLPixelFormat::RGBA32Float);
                descriptor.set_width(evaluated.texture.width());
                descriptor.set_height(evaluated.texture.height());
                descriptor.set_storage_mode(MTLStorageMode::Shared);
                descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
                evaluated.texture.device().new_texture(&descriptor)
            });
            if output.width() != evaluated.texture.width()
                || output.height() != evaluated.texture.height()
            {
                return Err(MetalPhysicalPipelineError::InvalidPlan(
                    "temporal samples changed output geometry".to_owned(),
                ));
            }
            let local_weight_sum = if let Some(row) = row {
                samples
                    .iter()
                    .filter(|sample| sample.4 == Some(*row))
                    .map(|sample| sample.3)
                    .sum::<f32>()
            } else {
                weight_sum
            };
            let reset = !samples[..index].iter().any(|sample| sample.4 == *row);
            let (row_origin, row_count) = row_range.unwrap_or((0, output.height() as u32));
            let weight_reset = [
                *weight / local_weight_sum,
                if reset { 1.0 } else { 0.0 },
                row_origin as f32,
                row_count as f32,
            ];
            let command = self.queue.new_command_buffer();
            let encoder = command.new_compute_command_encoder();
            encoder.set_compute_pipeline_state(&self.accumulator);
            encoder.set_texture(0, Some(&evaluated.texture));
            encoder.set_texture(1, Some(output));
            encoder.set_bytes(
                0,
                size_of::<[f32; 4]>() as u64,
                weight_reset.as_ptr().cast(),
            );
            let thread_width = self.accumulator.thread_execution_width();
            let thread_height =
                (self.accumulator.max_total_threads_per_threadgroup() / thread_width).max(1);
            encoder.dispatch_threads(
                MTLSize::new(output.width(), u64::from(row_count), 1),
                MTLSize::new(thread_width, thread_height, 1),
            );
            encoder.end_encoding();
            command.commit();
            command.wait_until_completed();
            if command.status() != MTLCommandBufferStatus::Completed {
                return Err(MetalPhysicalPipelineError::Backend(
                    "temporal accumulation did not complete".to_owned(),
                ));
            }
            final_geometry = Some(evaluated.geometry);
            final_sampling = Some(evaluated.sampling);
            for (total, elapsed) in stage_elapsed_nanoseconds
                .iter_mut()
                .zip(evaluated.stage_elapsed_nanoseconds)
            {
                *total = total.saturating_add(elapsed);
            }
        }
        let physical = MetalPhysicalPipelineResult {
            texture: accumulated.expect("non-empty schedule allocates output"),
            geometry: final_geometry.expect("non-empty schedule resolves geometry"),
            sampling: final_sampling.expect("non-empty schedule resolves sampling"),
            stage_elapsed_nanoseconds,
        };
        self.evaluate_sensor_raw(
            physical,
            samples[0].2,
            |progress| report_progress(0.9 + progress * 0.1),
            is_cancelled,
        )
    }

    pub fn evaluate(
        &self,
        source_acescg: &TextureRef,
        device_signal: &TextureRef,
        plan: PhysicalPipelineExecutionPlan,
        mut report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        let mut physical_plan = plan;
        if physical_plan.sensor_enabled {
            physical_plan.sensor_enabled = false;
            physical_plan.requested_intermediate = PhysicalIntermediate::ShutterMotion;
        }
        let physical = self.evaluate_rows(
            source_acescg,
            device_signal,
            physical_plan,
            None,
            |progress| {
                report_progress(if plan.sensor_enabled {
                    progress * 0.9
                } else {
                    progress
                })
            },
            &is_cancelled,
        )?;
        self.evaluate_sensor_raw(
            physical,
            plan,
            |progress| report_progress(0.9 + progress * 0.1),
            is_cancelled,
        )
    }

    fn evaluate_rows(
        &self,
        source_acescg: &TextureRef,
        device_signal: &TextureRef,
        plan: PhysicalPipelineExecutionPlan,
        row_range: Option<(u32, u32)>,
        mut report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        let physical_started = Instant::now();
        if source_acescg.width() == 0
            || source_acescg.height() == 0
            || source_acescg.width() != device_signal.width()
            || source_acescg.height() != device_signal.height()
        {
            return Err(MetalPhysicalPipelineError::TextureMismatch);
        }
        let supported = |texture: &TextureRef| {
            texture.texture_type() == MTLTextureType::D2
                && matches!(
                    texture.pixel_format(),
                    metal::MTLPixelFormat::RGBA16Float | metal::MTLPixelFormat::RGBA32Float
                )
        };
        if !supported(source_acescg) || !supported(device_signal) {
            return Err(MetalPhysicalPipelineError::UnsupportedTexture);
        }
        let geometry = plan
            .panel
            .flat_panel_geometry()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        let sampling = plan
            .panel
            .flat_panel_sampling(plan.quality, plan.requested_width, plan.requested_height)
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        if [
            plan.screen_amount,
            plan.emission_amount,
            plan.subpixel_geometry_amount,
            plan.temporal_emission_amount,
            plan.scene_geometry_amount,
            plan.lens_amount,
        ]
        .into_iter()
        .any(|amount| !amount.is_finite() || !(0.0..=4.0).contains(&amount))
        {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "amount must be finite and inside 0..=4".to_owned(),
            ));
        }
        plan.panel_light_spread
            .validate()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        let (camera, screen) = plan
            .scene_geometry_lens
            .resolve(
                plan.camera_position,
                plan.camera_rotation,
                plan.screen_translation,
                plan.screen_rotation,
                plan.lens_amount,
            )
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        if is_cancelled() {
            return Err(MetalPhysicalPipelineError::Cancelled);
        }
        if !matches!(
            plan.requested_intermediate,
            PhysicalIntermediate::SourceAcesCg
                | PhysicalIntermediate::DeviceSignal
                | PhysicalIntermediate::PanelEmission
                | PhysicalIntermediate::SubpixelRadiance
                | PhysicalIntermediate::PanelLightSpread
                | PhysicalIntermediate::CoverEnvironment
                | PhysicalIntermediate::SceneGeometryLens
                | PhysicalIntermediate::ShutterMotion
                | PhysicalIntermediate::DevelopedAcesCg
        ) {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "requested intermediate belongs to an unsupported stage".to_owned(),
            ));
        }
        if plan.screen_amount == 0.0
            && matches!(
                plan.requested_intermediate,
                PhysicalIntermediate::SourceAcesCg | PhysicalIntermediate::DevelopedAcesCg
            )
        {
            report_progress(1.0);
            return Ok(MetalPhysicalPipelineResult {
                texture: source_acescg.to_owned(),
                geometry,
                sampling,
                stage_elapsed_nanoseconds: [0; 12],
            });
        }

        let device = source_acescg.device();
        if !core::ptr::eq(device, device_signal.device()) {
            return Err(MetalPhysicalPipelineError::TextureMismatch);
        }
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        // Active physical evaluation publishes float32 ACEScg so half-float input
        // quantization is not compounded at the authoritative output boundary.
        descriptor.set_pixel_format(metal::MTLPixelFormat::RGBA32Float);
        descriptor.set_width(u64::from(sampling.effective_width));
        descriptor.set_height(u64::from(sampling.effective_height));
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
        let output = device.new_texture(&descriptor);
        let values = plan
            .panel
            .evaluator()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?
            .device_stage_parameters();
        let side = match sampling.samples_per_output_pixel {
            1 => 1,
            4 => 2,
            16 => 4,
            count => {
                return Err(MetalPhysicalPipelineError::InvalidPlan(format!(
                    "unsupported sample count {count}"
                )));
            }
        };
        let pad = |row: [f32; 3]| [row[0], row[1], row[2], 0.0];
        let mut params = PhysicalPipelineParams {
            source_panel: [
                source_acescg.width() as u32,
                source_acescg.height() as u32,
                plan.panel.native_width,
                plan.panel.native_height,
            ],
            output_tile: [sampling.effective_width, sampling.effective_height, 0, side],
            semantics: [
                match plan.placement {
                    RasterPlacement::Fit => 0,
                    RasterPlacement::FillCrop => 1,
                    RasterPlacement::Stretch => 2,
                    RasterPlacement::OneToOne => 3,
                },
                match plan.panel.stripe_layout {
                    StripeLayout::Rgb => 0,
                    StripeLayout::Bgr => 1,
                },
                plan.requested_intermediate as u32,
                match plan.environment.pattern {
                    EnvironmentPattern::UniformNeutral => 0,
                    EnvironmentPattern::StudioSoftboxes => 1,
                    EnvironmentPattern::CalibrationGrid => 2,
                },
            ],
            levels: [
                plan.panel.eotf_gamma,
                plan.panel.black_level_nits,
                plan.panel.white_level_nits,
                0.0,
            ],
            geometry: [plan.panel.black_matrix_fraction, 0.0, 0.0, 0.0],
            strengths: [
                plan.screen_amount,
                plan.emission_amount,
                plan.subpixel_geometry_amount,
                plan.temporal_emission_amount,
            ],
            matrix0: pad(values.native_to_acescg[0]),
            matrix1: pad(values.native_to_acescg[1]),
            matrix2: pad(values.native_to_acescg[2]),
            panel_size_meters: [
                plan.panel.active_width.0,
                plan.panel.active_height.0,
                0.0,
                0.0,
            ],
            spread_core_radius: [
                plan.panel_light_spread.core_radius_micrometers.r,
                plan.panel_light_spread.core_radius_micrometers.g,
                plan.panel_light_spread.core_radius_micrometers.b,
                plan.panel_light_spread.character_strength,
            ],
            spread_core_weight: [
                plan.panel_light_spread.core_weight.r,
                plan.panel_light_spread.core_weight.g,
                plan.panel_light_spread.core_weight.b,
                0.0,
            ],
            spread_tail_radius: [
                plan.panel_light_spread.tail_radius_micrometers.r,
                plan.panel_light_spread.tail_radius_micrometers.g,
                plan.panel_light_spread.tail_radius_micrometers.b,
                0.0,
            ],
            spread_tail_weight: [
                plan.panel_light_spread.tail_weight.r,
                plan.panel_light_spread.tail_weight.g,
                plan.panel_light_spread.tail_weight.b,
                0.0,
            ],
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
            environment_direction_rotation: [
                plan.environment.key_direction_local[0],
                plan.environment.key_direction_local[1],
                plan.environment.key_direction_local[2],
                plan.environment.rotation_degrees.to_radians(),
            ],
            camera_position_focal: [
                camera.position.x,
                camera.position.y,
                camera.position.z,
                camera.focal_length.0,
            ],
            camera_right_sensor_width: [
                camera.world_to_view[0],
                camera.world_to_view[1],
                camera.world_to_view[2],
                camera.sensor_width.0,
            ],
            camera_up_sensor_height: [
                camera.world_to_view[4],
                camera.world_to_view[5],
                camera.world_to_view[6],
                camera.sensor_height.0,
            ],
            camera_forward_focus: [
                camera.world_to_view[8],
                camera.world_to_view[9],
                camera.world_to_view[10],
                camera.focus_distance.0,
            ],
            camera_limits: [camera.f_stop, camera.near_clip.0, camera.far_clip.0, 0.0],
            lens_shift_radial01: [
                camera.lens_shift.x,
                camera.lens_shift.y,
                camera.lens.radial_distortion[0],
                camera.lens.radial_distortion[1],
            ],
            lens_radial2_tangential: [
                camera.lens.radial_distortion[2],
                camera.lens.tangential_distortion[0],
                camera.lens.tangential_distortion[1],
                0.0,
            ],
            lens_longitudinal: [
                camera.lens.longitudinal_chromatic_meters[0],
                camera.lens.longitudinal_chromatic_meters[1],
                camera.lens.longitudinal_chromatic_meters[2],
                0.0,
            ],
            lens_lateral: [
                camera.lens.lateral_chromatic_scale[0],
                camera.lens.lateral_chromatic_scale[1],
                camera.lens.lateral_chromatic_scale[2],
                0.0,
            ],
            lens_transmission_vignette: [
                camera.lens.transmission_rgb[0],
                camera.lens.transmission_rgb[1],
                camera.lens.transmission_rgb[2],
                camera.lens.vignetting_strength,
            ],
            lens_softness: [
                camera.lens.center_softness_micrometers,
                camera.lens.edge_softness_micrometers,
                plan.lens_amount,
                0.0,
            ],
            screen_translation: [
                screen.translation.x,
                screen.translation.y,
                screen.translation.z,
                0.0,
            ],
            screen_quaternion: [
                screen.rotation.x,
                screen.rotation.y,
                screen.rotation.z,
                screen.rotation.w,
            ],
            panel_angular_scene: [
                plan.panel.angular_emission_power.r,
                plan.panel.angular_emission_power.g,
                plan.panel.angular_emission_power.b,
                plan.scene_geometry_amount,
            ],
            shutter: [
                plan.shutter_motion_amount,
                plan.shutter_close
                    .checked_sub(plan.shutter_open)
                    .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?
                    .as_seconds() as f32,
                plan.shutter_motion.neutral_density_stops,
                0.0,
            ],
        };
        params.levels[3] = plan.temporal_emission_gain;
        let row_temporal_gains = (0..sampling.effective_height)
            .map(|row| {
                physical_row_temporal_gain(plan, row as usize, sampling.effective_height as usize)
                    .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let row_temporal_buffer = device.new_buffer_with_data(
            row_temporal_gains.as_ptr().cast(),
            (row_temporal_gains.len() * size_of::<f32>()) as u64,
            MTLResourceOptions::StorageModeShared,
        );

        let (work_origin, work_height) = row_range.unwrap_or((0, sampling.effective_height));
        if work_height == 0 || work_origin.saturating_add(work_height) > sampling.effective_height {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "physical work rows exceed the output domain".to_owned(),
            ));
        }
        let tile_count = work_height.div_ceil(TILE_ROWS);
        for tile in 0..tile_count {
            if is_cancelled() {
                return Err(MetalPhysicalPipelineError::Cancelled);
            }
            let origin_y = work_origin + tile * TILE_ROWS;
            let height = TILE_ROWS.min(work_origin + work_height - origin_y);
            params.output_tile[2] = origin_y;
            let command = self.queue.new_command_buffer();
            let encoder = command.new_compute_command_encoder();
            encoder.set_compute_pipeline_state(&self.pipeline);
            encoder.set_texture(0, Some(source_acescg));
            encoder.set_texture(1, Some(device_signal));
            encoder.set_texture(2, Some(&output));
            encoder.set_bytes(
                0,
                size_of::<PhysicalPipelineParams>() as u64,
                (&raw const params).cast(),
            );
            encoder.set_buffer(1, Some(&row_temporal_buffer), 0);
            let thread_width = self.pipeline.thread_execution_width();
            let thread_height =
                (self.pipeline.max_total_threads_per_threadgroup() / thread_width).max(1);
            encoder.dispatch_threads(
                MTLSize::new(u64::from(sampling.effective_width), u64::from(height), 1),
                MTLSize::new(thread_width, thread_height, 1),
            );
            encoder.end_encoding();
            command.commit();
            command.wait_until_completed();
            if command.status() != MTLCommandBufferStatus::Completed {
                return Err(MetalPhysicalPipelineError::Backend(
                    "compute command did not complete".to_owned(),
                ));
            }
            report_progress((tile + 1) as f32 / tile_count as f32);
        }
        let elapsed = physical_started
            .elapsed()
            .as_nanos()
            .min(u128::from(u64::MAX)) as u64;
        let mut stage_elapsed_nanoseconds = [0_u64; 12];
        stage_elapsed_nanoseconds[..9].fill(elapsed);
        Ok(MetalPhysicalPipelineResult {
            texture: output,
            geometry,
            sampling,
            stage_elapsed_nanoseconds,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use metal::{MTLPixelFormat, MTLRegion};
    use screen_application::{
        DeviceSignalRaster, PhysicalPipelineInput, PhysicalPipelineRequest,
        evaluate_physical_pipeline_cpu_oracle,
    };
    use screen_contracts::{DeviceRgb, Meters};
    use screen_panel::{DEVICE_PRESETS, FlatPanelQuality, PanelLightSpreadProfile};

    fn texture(device: &DeviceRef, width: u32, height: u32, values: &[[f32; 4]]) -> Texture {
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_pixel_format(MTLPixelFormat::RGBA32Float);
        descriptor.set_width(u64::from(width));
        descriptor.set_height(u64::from(height));
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        descriptor.set_usage(MTLTextureUsage::ShaderRead);
        let texture = device.new_texture(&descriptor);
        texture.replace_region(
            MTLRegion::new_2d(0, 0, u64::from(width), u64::from(height)),
            0,
            values.as_ptr().cast(),
            u64::from(width) * size_of::<[f32; 4]>() as u64,
        );
        texture
    }

    fn half_texture(device: &DeviceRef, width: u32, height: u32, values: &[[f32; 4]]) -> Texture {
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_pixel_format(MTLPixelFormat::RGBA16Float);
        descriptor.set_width(u64::from(width));
        descriptor.set_height(u64::from(height));
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        descriptor.set_usage(MTLTextureUsage::ShaderRead);
        let texture = device.new_texture(&descriptor);
        let storage = values
            .iter()
            .flat_map(|pixel| pixel.map(|value| half::f16::from_f32(value).to_bits()))
            .collect::<Vec<_>>();
        texture.replace_region(
            MTLRegion::new_2d(0, 0, u64::from(width), u64::from(height)),
            0,
            storage.as_ptr().cast(),
            u64::from(width) * size_of::<[u16; 4]>() as u64,
        );
        texture
    }

    fn read(texture: &TextureRef) -> Vec<[f32; 4]> {
        let mut values = vec![[0.0_f32; 4]; (texture.width() * texture.height()) as usize];
        texture.get_bytes(
            values.as_mut_ptr().cast(),
            texture.width() * size_of::<[f32; 4]>() as u64,
            MTLRegion::new_2d(0, 0, texture.width(), texture.height()),
            0,
        );
        values
    }

    fn fixture(
        placement: RasterPlacement,
        quality: FlatPanelQuality,
        layout: StripeLayout,
        matrix: f32,
        amount: f32,
    ) -> (PhysicalPipelineInput, PhysicalPipelineExecutionPlan) {
        let acescg = vec![
            [-0.25, 0.0, 0.5, 0.2],
            [0.1, 0.5, 1.5, 0.4],
            [2.0, 0.25, 0.0, 0.6],
            [0.5, 1.25, -0.1, 0.8],
            [0.0, 0.0, 0.0, 1.0],
            [1.0, 1.0, 1.0, 0.3],
        ];
        let device_signal = acescg
            .iter()
            .map(|value| DeviceRgb::new(value[0], value[1], value[2]))
            .collect();
        let mut panel = DEVICE_PRESETS[0].profile();
        panel.native_width = 4;
        panel.native_height = 3;
        panel.active_width = Meters(0.004);
        panel.active_height = Meters(0.003);
        panel.stripe_layout = layout;
        panel.black_matrix_fraction = matrix;
        (
            PhysicalPipelineInput {
                width: 3,
                height: 2,
                acescg,
                device_signal: DeviceSignalRaster {
                    width: 3,
                    height: 2,
                    pixels: device_signal,
                },
            },
            PhysicalPipelineExecutionPlan {
                panel,
                panel_light_spread: PanelLightSpreadProfile::LCD_DESKTOP,
                placement,
                quality,
                requested_width: 12,
                requested_height: 8,
                screen_amount: amount,
                emission_amount: 1.0,
                subpixel_geometry_amount: 1.0,
                temporal_emission_amount: 0.0,
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
                frame_time: screen_contracts::RationalTime::new(0, 1).expect("valid fixture time"),
                shutter_open: screen_contracts::RationalTime::new(-1, 96).expect("valid open"),
                shutter_close: screen_contracts::RationalTime::new(1, 96).expect("valid close"),
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
            },
        )
    }

    #[test]
    fn metal_matches_cpu_for_placements_layouts_matrix_extremes_and_qualities() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let mut suite_maximum = 0.0_f32;
        for placement in [
            RasterPlacement::Fit,
            RasterPlacement::FillCrop,
            RasterPlacement::Stretch,
            RasterPlacement::OneToOne,
        ] {
            for quality in [
                FlatPanelQuality::Draft,
                FlatPanelQuality::Medium,
                FlatPanelQuality::High,
                FlatPanelQuality::Native,
            ] {
                for layout in [StripeLayout::Rgb, StripeLayout::Bgr] {
                    for matrix in [0.0, 0.45] {
                        for spread_amount in [0.0, 1.0, 2.5] {
                            let (input, mut plan) =
                                fixture(placement, quality, layout, matrix, 1.5);
                            plan.panel_light_spread.character_strength = spread_amount;
                            let source = texture(&device, input.width, input.height, &input.acescg);
                            let signal_values = input
                                .device_signal
                                .pixels
                                .iter()
                                .map(|value| [value.r, value.g, value.b, 1.0])
                                .collect::<Vec<_>>();
                            let signal =
                                texture(&device, input.width, input.height, &signal_values);
                            let cpu =
                                evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest {
                                    input,
                                    plan,
                                })
                                .expect("CPU oracle");
                            let mut progress = Vec::new();
                            let gpu = backend
                                .evaluate(
                                    &source,
                                    &signal,
                                    plan,
                                    |value| progress.push(value),
                                    || false,
                                )
                                .expect("Metal result");
                            assert_eq!(
                                (gpu.texture.width(), gpu.texture.height()),
                                (u64::from(cpu.width), u64::from(cpu.height))
                            );
                            assert_eq!(progress.last().copied(), Some(1.0));
                            let actual = read(&gpu.texture);
                            let maximum = actual
                                .iter()
                                .zip(&cpu.acescg)
                                .flat_map(|(gpu, cpu)| {
                                    gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs())
                                })
                                .fold(0.0_f32, f32::max);
                            suite_maximum = suite_maximum.max(maximum);
                            assert!(maximum <= 2.0e-3, "maximum CPU/Metal deviation {maximum}");
                        }
                    }
                }
            }
        }
        eprintln!("physical pipeline CPU/Metal suite maximum absolute deviation: {suite_maximum}");
    }

    #[test]
    fn metal_zero_reuses_exact_source_and_cancellation_is_explicit() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let (input, plan) = fixture(
            RasterPlacement::Stretch,
            FlatPanelQuality::Native,
            StripeLayout::Rgb,
            0.12,
            0.0,
        );
        let source = texture(&device, input.width, input.height, &input.acescg);
        let signal = texture(&device, input.width, input.height, &input.acescg);
        let result = backend
            .evaluate(&source, &signal, plan, |_| {}, || false)
            .expect("identity result");
        assert!(core::ptr::eq(&*source, &*result.texture));
        let mut active = plan;
        active.screen_amount = 1.0;
        assert!(matches!(
            backend.evaluate(&source, &signal, active, |_| {}, || true),
            Err(MetalPhysicalPipelineError::Cancelled)
        ));
    }

    #[test]
    fn temporal_emission_matches_cpu_for_identity_calibrated_and_artistic_amounts() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for amount in [0.0, 1.0, 2.5] {
            let (input, mut plan) = fixture(
                RasterPlacement::Stretch,
                FlatPanelQuality::High,
                StripeLayout::Rgb,
                0.12,
                1.0,
            );
            plan.temporal_emission_amount = amount;
            plan.temporal_emission_gain = 0.91;
            let source = texture(&device, input.width, input.height, &input.acescg);
            let signal_values = input
                .device_signal
                .pixels
                .iter()
                .map(|value| [value.r, value.g, value.b, 1.0])
                .collect::<Vec<_>>();
            let signal = texture(&device, input.width, input.height, &signal_values);
            let cpu =
                evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest { input, plan })
                    .expect("CPU oracle");
            let gpu = backend
                .evaluate(&source, &signal, plan, |_| {}, || false)
                .expect("Metal temporal result");
            let maximum = read(&gpu.texture)
                .iter()
                .zip(&cpu.acescg)
                .flat_map(|(gpu, cpu)| gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs()))
                .fold(0.0_f32, f32::max);
            assert!(maximum <= 2.0e-3, "temporal CPU/Metal deviation {maximum}");
        }
    }

    #[test]
    fn cover_and_hdr_environment_match_the_existing_cpu_authority() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for cover in [
            screen_cover::CoverGlassProfile::NEUTRAL,
            screen_cover::COVER_GLASS_PRESETS[1].profile,
            screen_cover::COVER_GLASS_PRESETS[4].profile,
        ] {
            for environment in [
                screen_cover::ProceduralEnvironment::NONE,
                screen_cover::ENVIRONMENT_PRESETS[0].environment,
                screen_cover::ENVIRONMENT_PRESETS[1].environment,
                screen_cover::ENVIRONMENT_PRESETS[2].environment,
            ] {
                let (input, mut plan) = fixture(
                    RasterPlacement::Stretch,
                    FlatPanelQuality::High,
                    StripeLayout::Bgr,
                    0.2,
                    1.0,
                );
                plan.cover = cover;
                plan.environment = environment;
                plan.requested_intermediate = PhysicalIntermediate::CoverEnvironment;
                let source = texture(&device, input.width, input.height, &input.acescg);
                let signal_values = input
                    .device_signal
                    .pixels
                    .iter()
                    .map(|value| [value.r, value.g, value.b, 1.0])
                    .collect::<Vec<_>>();
                let signal = texture(&device, input.width, input.height, &signal_values);
                let cpu =
                    evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest { input, plan })
                        .expect("CPU cover oracle");
                let gpu = backend
                    .evaluate(&source, &signal, plan, |_| {}, || false)
                    .expect("Metal cover result");
                let maximum = read(&gpu.texture)
                    .iter()
                    .zip(&cpu.acescg)
                    .flat_map(|(gpu, cpu)| gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs()))
                    .fold(0.0_f32, f32::max);
                assert!(maximum <= 2.0e-3, "cover CPU/Metal deviation {maximum}");
            }
        }
    }

    #[test]
    fn scene_geometry_and_generalized_lens_match_cpu_for_zero_one_and_artistic_amounts() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for lens_amount in [0.0, 1.0, 2.0] {
            let (input, mut plan) = fixture(
                RasterPlacement::Stretch,
                FlatPanelQuality::High,
                StripeLayout::Rgb,
                0.12,
                1.0,
            );
            plan.scene_geometry_amount = 1.0;
            plan.lens_amount = lens_amount;
            plan.camera_position = screen_contracts::Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.01,
            };
            plan.scene_geometry_lens.focus_distance_meters = 0.01;
            plan.scene_geometry_lens.focal_length_millimeters = 10.0;
            plan.scene_geometry_lens.sensor_width_millimeters = 4.0;
            plan.scene_geometry_lens.sensor_height_millimeters = 2.0;
            plan.requested_intermediate = PhysicalIntermediate::SceneGeometryLens;
            let source = texture(&device, input.width, input.height, &input.acescg);
            let signal_values = input
                .device_signal
                .pixels
                .iter()
                .map(|value| [value.r, value.g, value.b, 1.0])
                .collect::<Vec<_>>();
            let signal = texture(&device, input.width, input.height, &signal_values);
            let cpu =
                evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest { input, plan })
                    .expect("CPU scene oracle");
            let gpu = backend
                .evaluate(&source, &signal, plan, |_| {}, || false)
                .expect("Metal scene result");
            let maximum = read(&gpu.texture)
                .iter()
                .zip(&cpu.acescg)
                .flat_map(|(gpu, cpu)| gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs()))
                .fold(0.0_f32, f32::max);
            assert!(
                maximum <= 3.0e-3,
                "scene/lens CPU/Metal deviation {maximum}"
            );
        }
    }

    #[test]
    fn half_float_contract_input_matches_oracle_without_output_requantization() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let (mut input, plan) = fixture(
            RasterPlacement::Fit,
            FlatPanelQuality::High,
            StripeLayout::Bgr,
            0.45,
            1.0,
        );
        for pixel in &mut input.acescg {
            for value in pixel {
                *value = half::f16::from_f32(*value).to_f32();
            }
        }
        for pixel in &mut input.device_signal.pixels {
            pixel.r = half::f16::from_f32(pixel.r).to_f32();
            pixel.g = half::f16::from_f32(pixel.g).to_f32();
            pixel.b = half::f16::from_f32(pixel.b).to_f32();
        }
        let source = half_texture(&device, input.width, input.height, &input.acescg);
        let signal_values = input
            .device_signal
            .pixels
            .iter()
            .map(|value| [value.r, value.g, value.b, 1.0])
            .collect::<Vec<_>>();
        let signal = half_texture(&device, input.width, input.height, &signal_values);
        let cpu = evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest { input, plan })
            .expect("CPU oracle");
        let gpu = backend
            .evaluate(&source, &signal, plan, |_| {}, || false)
            .expect("Metal result");
        assert_eq!(gpu.texture.pixel_format(), MTLPixelFormat::RGBA32Float);
        let maximum = read(&gpu.texture)
            .iter()
            .zip(&cpu.acescg)
            .flat_map(|(gpu, cpu)| gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs()))
            .fold(0.0_f32, f32::max);
        eprintln!("physical pipeline half-input CPU/Metal maximum absolute deviation: {maximum}");
        assert!(
            maximum <= 2.0e-3,
            "half input CPU/Metal deviation {maximum}"
        );
    }

    #[test]
    fn metal_temporal_executor_accumulates_animated_source_and_alpha_deterministically() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let (input, mut plan) = fixture(
            RasterPlacement::Stretch,
            FlatPanelQuality::Draft,
            StripeLayout::Rgb,
            0.0,
            0.0,
        );
        plan.screen_amount = 0.0;
        let first_values = vec![[0.0, 0.5, 1.0, 0.25]; input.acescg.len()];
        let second_values = vec![[2.0, 1.5, -1.0, 0.75]; input.acescg.len()];
        let first = texture(&device, input.width, input.height, &first_values);
        let second = texture(&device, input.width, input.height, &second_values);
        let signal = texture(&device, input.width, input.height, &first_values);
        let scheduled = [
            (&*first, &*signal, plan, 1.0_f32, None),
            (&*second, &*signal, plan, 3.0_f32, None),
        ];
        let one = backend
            .evaluate_temporal(&scheduled, |_| {}, || false)
            .expect("first deterministic sequence");
        let two = backend
            .evaluate_temporal(&scheduled, |_| {}, || false)
            .expect("second deterministic sequence");
        let expected = [1.5, 1.25, -0.5, 0.625];
        assert_eq!(read(&one.texture), read(&two.texture));
        for pixel in read(&one.texture) {
            for (actual, expected) in pixel.into_iter().zip(expected) {
                assert!((actual - expected).abs() <= 1.0e-7);
            }
        }
    }

    #[test]
    fn metal_rolling_executor_integrates_only_the_addressed_rows() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let (input, mut plan) = fixture(
            RasterPlacement::Stretch,
            FlatPanelQuality::Draft,
            StripeLayout::Rgb,
            0.0,
            0.0,
        );
        plan.screen_amount = 0.0;
        plan.requested_width = input.width;
        plan.requested_height = input.height;
        let dark_values = vec![[0.0, 0.0, 0.0, 0.25]; input.acescg.len()];
        let bright_values = vec![[1.0, 2.0, 3.0, 0.75]; input.acescg.len()];
        let dark = texture(&device, input.width, input.height, &dark_values);
        let bright = texture(&device, input.width, input.height, &bright_values);
        let signal = texture(&device, input.width, input.height, &dark_values);
        let scheduled = [
            (&*dark, &*signal, plan, 1.0, Some(0)),
            (&*bright, &*signal, plan, 3.0, Some(0)),
            (&*dark, &*signal, plan, 3.0, Some(1)),
            (&*bright, &*signal, plan, 1.0, Some(1)),
        ];
        let result = backend
            .evaluate_temporal(&scheduled, |_| {}, || false)
            .expect("rolling sequence");
        let pixels = read(&result.texture);
        for pixel in &pixels[..input.width as usize] {
            assert_eq!(*pixel, [0.75, 1.5, 2.25, 0.625]);
        }
        for pixel in &pixels[input.width as usize..] {
            assert_eq!(*pixel, [0.25, 0.5, 0.75, 0.375]);
        }
    }

    #[test]
    fn sensor_cfa_noise_and_clipping_match_cpu_for_zero_one_and_artistic_amounts() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for noise_amount in [0.0, 1.0, 2.5] {
            let (input, mut plan) = fixture(
                RasterPlacement::Stretch,
                FlatPanelQuality::High,
                StripeLayout::Rgb,
                0.0,
                1.0,
            );
            plan.sensor = screen_sensor::SensorProfile {
                native_width: plan.requested_width as u16,
                native_height: plan.requested_height as u16,
                ..screen_sensor::SensorProfile::REFERENCE
            };
            plan.sensor_enabled = true;
            plan.sensor_noise_amount = noise_amount;
            plan.shutter_motion_amount = 1.0;
            plan.requested_intermediate = PhysicalIntermediate::RawMosaic;
            let source = texture(&device, input.width, input.height, &input.acescg);
            let signal_values = input
                .device_signal
                .pixels
                .iter()
                .map(|value| [value.r, value.g, value.b, 1.0])
                .collect::<Vec<_>>();
            let signal = texture(&device, input.width, input.height, &signal_values);
            let cpu = evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest {
                input: input.clone(),
                plan,
            })
            .expect("CPU sensor oracle");
            let gpu = backend
                .evaluate(&source, &signal, plan, |_| {}, || false)
                .expect("Metal sensor result");
            let gpu = read(&gpu.texture);
            assert_eq!(gpu.len(), cpu.acescg.len());
            let maximum_code_error = gpu
                .iter()
                .zip(&cpu.acescg)
                .map(|(gpu, cpu)| {
                    ((gpu[0] - cpu[0]).abs() * ((1_u32 << plan.sensor.adc_bits) - 1) as f32).round()
                        as u32
                })
                .max()
                .expect("non-empty sensor");
            let tolerance = if noise_amount == 0.0 { 1 } else { 4 };
            assert!(
                maximum_code_error <= tolerance,
                "sensor CPU/Metal code deviation {maximum_code_error} at amount {noise_amount}"
            );
            assert!(
                gpu.iter()
                    .all(|pixel| pixel[3].to_bits() == 1.0_f32.to_bits())
            );
        }
    }

    #[test]
    fn raw_demosaic_white_balance_and_develop_match_cpu_acescg() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for pattern in [
            screen_sensor::BayerPattern::Rggb,
            screen_sensor::BayerPattern::Bggr,
            screen_sensor::BayerPattern::Grbg,
            screen_sensor::BayerPattern::Gbrg,
        ] {
            let (input, mut plan) = fixture(
                RasterPlacement::Stretch,
                FlatPanelQuality::High,
                StripeLayout::Bgr,
                0.0,
                1.0,
            );
            plan.sensor = screen_sensor::SensorProfile {
                native_width: plan.requested_width as u16,
                native_height: plan.requested_height as u16,
                bayer_pattern: pattern,
                ..screen_sensor::SensorProfile::REFERENCE
            };
            plan.sensor_enabled = true;
            plan.sensor_noise_amount = 0.0;
            plan.development = screen_camera::CameraDevelopment {
                white_balance: screen_contracts::LinearRgb::new(1.8, 1.0, 0.65),
                middle_gray_illuminance_seconds: 0.07,
                develop_exposure_ev: 1.25,
            };
            plan.development_enabled = true;
            plan.shutter_motion_amount = 1.0;
            plan.requested_intermediate = PhysicalIntermediate::DevelopedAcesCg;
            let source = texture(&device, input.width, input.height, &input.acescg);
            let signal_values = input
                .device_signal
                .pixels
                .iter()
                .map(|value| [value.r, value.g, value.b, 1.0])
                .collect::<Vec<_>>();
            let signal = texture(&device, input.width, input.height, &signal_values);
            let cpu = evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest {
                input: input.clone(),
                plan,
            })
            .expect("CPU developed oracle");
            let gpu = backend
                .evaluate(&source, &signal, plan, |_| {}, || false)
                .expect("Metal developed result");
            let maximum = read(&gpu.texture)
                .iter()
                .zip(&cpu.acescg)
                .flat_map(|(gpu, cpu)| gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs()))
                .fold(0.0_f32, f32::max);
            assert!(maximum <= 3.0e-4, "developed CPU/Metal deviation {maximum}");
        }
    }
}
