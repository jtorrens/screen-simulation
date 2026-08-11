use core::fmt;
use core::mem::size_of;
use std::time::Instant;

use metal::{
    ComputePipelineState, DeviceRef, FunctionConstantValues, MTLCommandBufferStatus, MTLDataType,
    MTLOrigin, MTLRegion, MTLResourceOptions, MTLSize, MTLStorageMode, MTLTextureType,
    MTLTextureUsage, Texture, TextureDescriptor, TextureRef,
};
use screen_application::{
    LensEvaluationModel, PhysicalIntermediate, PhysicalPipelineExecutionPlan, RasterPlacement,
    expose_physical_pipeline_raw, physical_environment_reference_sample_count,
    physical_row_temporal_gain, placed_signal_area_fraction,
};
use screen_cover::{EnvironmentPattern, IncidentEnvironment};
use screen_geometry::{project_screen, projected_screen_gate_coverage};
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
    uniformity_amplitudes: [f32; 4],
    uniformity_scales: [f32; 4],
    uniformity_seed: [u32; 4],
    spread_core_radius: [f32; 4],
    spread_core_weight: [f32; 4],
    spread_tail_radius: [f32; 4],
    spread_tail_weight: [f32; 4],
    cover_geometry: [f32; 4],
    cover_absorption_roughness: [f32; 4],
    cover_haze: [f32; 4],
    cover_glow: [f32; 4],
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
    lens_veiling_glare: [f32; 4],
    screen_translation: [f32; 4],
    screen_quaternion: [f32; 4],
    panel_angular_scene: [f32; 4],
    shutter: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct RawPublicationParams {
    width: u32,
    height: u32,
    maximum_code: u32,
    _padding: u32,
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
    thin_lens_procedural_pipeline: ComputePipelineState,
    thin_lens_image_pipeline: ComputePipelineState,
    vfx_depth_blur_procedural_pipeline: ComputePipelineState,
    vfx_depth_blur_image_pipeline: ComputePipelineState,
    row_prefix_pipeline: ComputePipelineState,
    veiling_reduce_pipeline: ComputePipelineState,
    veiling_finalize_pipeline: ComputePipelineState,
    accumulator: ComputePipelineState,
    publish_raw_pipeline: ComputePipelineState,
    reconstruct_green_pipeline: ComputePipelineState,
    develop_pipeline: ComputePipelineState,
}

pub struct MetalPhysicalPipelineResult {
    pub texture: Texture,
    pub geometry: FlatPanelGeometry,
    pub sampling: FlatPanelSampling,
    pub stage_elapsed_nanoseconds: [u64; 16],
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
    fn requests_sensor_evaluation(intermediate: PhysicalIntermediate) -> bool {
        matches!(
            intermediate,
            PhysicalIntermediate::SensorBloom
                | PhysicalIntermediate::SensorNoise
                | PhysicalIntermediate::RawMosaic
                | PhysicalIntermediate::DevelopedAcesCg
        )
    }

    pub fn new(device: &DeviceRef) -> Result<Self, MetalPhysicalPipelineError> {
        let library = device
            .new_library_with_data(SHADER_LIBRARY)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let specialized_pipeline = |vfx_depth_blur: bool, image_environment: bool| {
            let constants = FunctionConstantValues::new();
            constants.set_constant_value_at_index(
                (&raw const vfx_depth_blur).cast(),
                MTLDataType::Bool,
                0,
            );
            constants.set_constant_value_at_index(
                (&raw const image_environment).cast(),
                MTLDataType::Bool,
                1,
            );
            let function = library
                .get_function("evaluate_physical_pipeline", Some(constants))
                .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
            device
                .new_compute_pipeline_state_with_function(&function)
                .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))
        };
        let thin_lens_procedural_pipeline = specialized_pipeline(false, false)?;
        let thin_lens_image_pipeline = specialized_pipeline(false, true)?;
        let vfx_depth_blur_procedural_pipeline = specialized_pipeline(true, false)?;
        let vfx_depth_blur_image_pipeline = specialized_pipeline(true, true)?;
        let row_prefix_function = library
            .get_function("build_physical_row_prefix", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let row_prefix_pipeline = device
            .new_compute_pipeline_state_with_function(&row_prefix_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let veiling_reduce_function = library
            .get_function("reduce_physical_veiling_source", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let veiling_reduce_pipeline = device
            .new_compute_pipeline_state_with_function(&veiling_reduce_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let veiling_finalize_function = library
            .get_function("finalize_physical_veiling_source", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let veiling_finalize_pipeline = device
            .new_compute_pipeline_state_with_function(&veiling_finalize_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let accumulator_function = library
            .get_function("accumulate_physical_pipeline", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let accumulator = device
            .new_compute_pipeline_state_with_function(&accumulator_function)
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
            .get_function("develop_acescg_texture", None)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        let develop_pipeline = device
            .new_compute_pipeline_state_with_function(&develop_function)
            .map_err(|error| MetalPhysicalPipelineError::Backend(error.to_string()))?;
        Ok(Self {
            queue: device.new_command_queue(),
            thin_lens_procedural_pipeline,
            thin_lens_image_pipeline,
            vfx_depth_blur_procedural_pipeline,
            vfx_depth_blur_image_pipeline,
            row_prefix_pipeline,
            veiling_reduce_pipeline,
            veiling_finalize_pipeline,
            accumulator,
            publish_raw_pipeline,
            reconstruct_green_pipeline,
            develop_pipeline,
        })
    }

    /// Copies the accepted radiance map into the immutable private texture consumed by Cover.
    /// Roughness is integrated from this exact level-zero source by the GGX reference evaluator.
    pub fn prepare_equirectangular_environment(
        &self,
        source: &TextureRef,
    ) -> Result<Texture, MetalPhysicalPipelineError> {
        if source.texture_type() != MTLTextureType::D2
            || source.width() < 2
            || source.height() < 2
            || source.width() != source.height().saturating_mul(2)
            || !matches!(
                source.pixel_format(),
                metal::MTLPixelFormat::RGBA16Float | metal::MTLPixelFormat::RGBA32Float
            )
        {
            return Err(MetalPhysicalPipelineError::UnsupportedTexture);
        }
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_pixel_format(source.pixel_format());
        descriptor.set_width(source.width());
        descriptor.set_height(source.height());
        descriptor.set_mipmap_level_count(1);
        descriptor.set_storage_mode(MTLStorageMode::Private);
        descriptor.set_usage(
            MTLTextureUsage::ShaderRead
                | MTLTextureUsage::ShaderWrite
                | MTLTextureUsage::PixelFormatView,
        );
        let destination = source.device().new_texture(&descriptor);
        let copy_command = self.queue.new_command_buffer();
        let blit = copy_command.new_blit_command_encoder();
        blit.copy_from_texture(
            source,
            0,
            0,
            MTLOrigin { x: 0, y: 0, z: 0 },
            MTLSize::new(source.width(), source.height(), 1),
            &destination,
            0,
            0,
            MTLOrigin { x: 0, y: 0, z: 0 },
        );
        blit.end_encoding();
        copy_command.commit();
        copy_command.wait_until_completed();
        if copy_command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalPhysicalPipelineError::Backend(
                "environment level-zero copy did not complete".to_owned(),
            ));
        }
        Ok(destination)
    }

    fn row_prefix_textures(
        &self,
        source_acescg: &TextureRef,
        device_signal: &TextureRef,
    ) -> Result<(Texture, Texture), MetalPhysicalPipelineError> {
        let device = source_acescg.device();
        let descriptor_for = |source: &TextureRef| {
            let descriptor = TextureDescriptor::new();
            descriptor.set_texture_type(MTLTextureType::D2);
            descriptor.set_pixel_format(metal::MTLPixelFormat::RGBA32Float);
            descriptor.set_width(source.width() + 1);
            descriptor.set_height(source.height());
            descriptor.set_storage_mode(MTLStorageMode::Private);
            descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
            descriptor
        };
        let source_prefix = device.new_texture(&descriptor_for(source_acescg));
        let device_prefix = device.new_texture(&descriptor_for(device_signal));
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.row_prefix_pipeline);
        let dispatch = |source: &TextureRef, destination: &TextureRef| {
            encoder.set_texture(0, Some(source));
            encoder.set_texture(1, Some(destination));
            let width = self.row_prefix_pipeline.thread_execution_width().max(1);
            encoder.dispatch_threads(
                MTLSize::new(source.height(), 1, 1),
                MTLSize::new(width, 1, 1),
            );
        };
        dispatch(source_acescg, &source_prefix);
        dispatch(device_signal, &device_prefix);
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalPhysicalPipelineError::Backend(
                "physical row-prefix construction did not complete".to_owned(),
            ));
        }
        Ok((source_prefix, device_prefix))
    }

    fn read_physical_raster(
        texture: &TextureRef,
    ) -> Result<Vec<[f32; 4]>, MetalPhysicalPipelineError> {
        if texture.pixel_format() != metal::MTLPixelFormat::RGBA32Float {
            return Err(MetalPhysicalPipelineError::UnsupportedTexture);
        }
        let count = texture
            .width()
            .checked_mul(texture.height())
            .and_then(|value| usize::try_from(value).ok())
            .ok_or_else(|| {
                MetalPhysicalPipelineError::Backend(
                    "physical raster size exceeds host address space".to_owned(),
                )
            })?;
        let mut values = vec![[0.0_f32; 4]; count];
        texture.get_bytes(
            values.as_mut_ptr().cast(),
            texture.width() * size_of::<[f32; 4]>() as u64,
            MTLRegion::new_2d(0, 0, texture.width(), texture.height()),
            0,
        );
        Ok(values)
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
        let physical_values = Self::read_physical_raster(&physical.texture)?;
        let raw = expose_physical_pipeline_raw(
            &physical_values,
            physical.texture.width() as u32,
            physical.texture.height() as u32,
            plan,
        )
        .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        let sensor = raw.sensor_profile;
        if is_cancelled() {
            return Err(MetalPhysicalPipelineError::Cancelled);
        }
        let pad = |row: [f32; 3]| [row[0], row[1], row[2], 0.0];
        let publication = RawPublicationParams {
            width: raw.width,
            height: raw.height,
            maximum_code: (1_u32 << raw.adc_bits) - 1,
            _padding: 0,
        };
        let pattern = match raw.bayer_pattern {
            screen_sensor::BayerPattern::Rggb => 0,
            screen_sensor::BayerPattern::Bggr => 1,
            screen_sensor::BayerPattern::Grbg => 2,
            screen_sensor::BayerPattern::Gbrg => 3,
        };
        let count = raw.codes.len();
        let device = physical.texture.device();
        let codes = device.new_buffer_with_data(
            raw.codes.as_ptr().cast(),
            size_of_val(raw.codes.as_slice()) as u64,
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
                pattern,
                maximum_code: publication.maximum_code,
                analog_gain: sensor.analog_gain,
                linear_scale: 0.18 / development.middle_gray_illuminance_seconds
                    * development.develop_exposure_ev.exp2(),
                saturation: [
                    sensor.saturation_illuminance_seconds.r,
                    sensor.saturation_illuminance_seconds.g,
                    sensor.saturation_illuminance_seconds.b,
                    0.0,
                ],
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
        let clipping = development_parameters.is_none().then(|| {
            let values = raw
                .full_well_clipped
                .iter()
                .zip(&raw.adc_clipped)
                .map(|(&well, &adc)| [u8::from(well), u8::from(adc)])
                .collect::<Vec<_>>();
            device.new_buffer_with_data(
                values.as_ptr().cast(),
                size_of_val(values.as_slice()) as u64,
                MTLResourceOptions::StorageModeShared,
            )
        });
        let green = development_parameters.as_ref().map(|_| {
            device.new_buffer(
                (count * size_of::<f32>()) as u64,
                MTLResourceOptions::StorageModeShared,
            )
        });
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_pixel_format(metal::MTLPixelFormat::RGBA32Float);
        descriptor.set_width(u64::from(raw.width));
        descriptor.set_height(u64::from(raw.height));
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
        let output = device.new_texture(&descriptor);
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        if let (Some(development), Some(green)) = (development_parameters, green.as_ref()) {
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
            encoder.set_texture(0, Some(&output));
            encoder.set_bytes(
                2,
                size_of::<CameraDevelopmentParams>() as u64,
                (&raw const development).cast(),
            );
        } else {
            encoder.set_compute_pipeline_state(&self.publish_raw_pipeline);
            encoder.set_buffer(0, Some(&codes), 0);
            encoder.set_buffer(
                1,
                Some(
                    clipping
                        .as_ref()
                        .expect("RAW publication prepares its clipping buffer"),
                ),
                0,
            );
            encoder.set_texture(0, Some(&output));
            encoder.set_bytes(
                2,
                size_of::<RawPublicationParams>() as u64,
                (&raw const publication).cast(),
            );
        }
        let publication_pipeline = if development_parameters.is_some() {
            &self.develop_pipeline
        } else {
            &self.publish_raw_pipeline
        };
        let thread_width = publication_pipeline.thread_execution_width();
        let thread_height =
            (publication_pipeline.max_total_threads_per_threadgroup() / thread_width).max(1);
        encoder.dispatch_threads(
            MTLSize::new(u64::from(raw.width), u64::from(raw.height), 1),
            MTLSize::new(thread_width, thread_height, 1),
        );
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalPhysicalPipelineError::Backend(
                "RAW publication or camera development command did not complete".to_owned(),
            ));
        }
        report_progress(1.0);
        let mut stage_elapsed_nanoseconds = physical.stage_elapsed_nanoseconds;
        let capture_elapsed = capture_started
            .elapsed()
            .as_nanos()
            .min(u128::from(u64::MAX)) as u64;
        stage_elapsed_nanoseconds[12] = capture_elapsed;
        stage_elapsed_nanoseconds[13] = capture_elapsed;
        stage_elapsed_nanoseconds[14] = capture_elapsed;
        if plan.development_enabled {
            stage_elapsed_nanoseconds[15] = capture_elapsed;
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
        report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        self.evaluate_temporal_with_environment(samples, None, report_progress, is_cancelled)
    }

    pub fn evaluate_temporal_with_environment(
        &self,
        samples: &[(
            &TextureRef,
            &TextureRef,
            PhysicalPipelineExecutionPlan,
            f32,
            Option<u32>,
        )],
        environment_acescg: Option<&TextureRef>,
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
        let mut stage_elapsed_nanoseconds = [0_u64; 16];
        let mut prefix_cache: Vec<(*const TextureRef, *const TextureRef, Texture, Texture)> =
            Vec::new();
        for (index, (source, signal, plan, weight, row)) in samples.iter().enumerate() {
            if is_cancelled() {
                return Err(MetalPhysicalPipelineError::Cancelled);
            }
            let base = index as f32 / samples.len() as f32;
            let span = 0.85 / samples.len() as f32;
            let row_range = row.map(|row| (row, 1));
            let mut physical_plan = plan.stopped_at_requested_intermediate();
            let evaluate_sensor = physical_plan.sensor_enabled
                && Self::requests_sensor_evaluation(physical_plan.requested_intermediate);
            if evaluate_sensor {
                physical_plan.sensor_enabled = false;
                physical_plan.requested_intermediate = PhysicalIntermediate::ShutterMotion;
            } else {
                physical_plan.sensor_enabled = false;
            }
            let source_key = core::ptr::from_ref(*source);
            let signal_key = core::ptr::from_ref(*signal);
            let prefix_index = if let Some(index) =
                prefix_cache
                    .iter()
                    .position(|(cached_source, cached_signal, _, _)| {
                        *cached_source == source_key && *cached_signal == signal_key
                    }) {
                index
            } else {
                let (source_prefix, signal_prefix) = self.row_prefix_textures(source, signal)?;
                prefix_cache.push((source_key, signal_key, source_prefix, signal_prefix));
                prefix_cache.len() - 1
            };
            let evaluated = self.evaluate_rows(
                source,
                signal,
                environment_acescg,
                physical_plan,
                row_range,
                Some((&prefix_cache[prefix_index].2, &prefix_cache[prefix_index].3)),
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
        let mut final_plan = samples[0].2.stopped_at_requested_intermediate();
        final_plan.sensor_enabled = final_plan.sensor_enabled
            && Self::requests_sensor_evaluation(final_plan.requested_intermediate);
        self.evaluate_sensor_raw(
            physical,
            final_plan,
            |progress| report_progress(0.9 + progress * 0.1),
            is_cancelled,
        )
    }

    pub fn evaluate(
        &self,
        source_acescg: &TextureRef,
        device_signal: &TextureRef,
        plan: PhysicalPipelineExecutionPlan,
        report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        self.evaluate_with_environment(
            source_acescg,
            device_signal,
            None,
            plan,
            report_progress,
            is_cancelled,
        )
    }

    pub fn evaluate_with_environment(
        &self,
        source_acescg: &TextureRef,
        device_signal: &TextureRef,
        environment_acescg: Option<&TextureRef>,
        plan: PhysicalPipelineExecutionPlan,
        mut report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        let plan = plan.stopped_at_requested_intermediate();
        let mut physical_plan = plan;
        let evaluate_sensor = physical_plan.sensor_enabled
            && Self::requests_sensor_evaluation(physical_plan.requested_intermediate);
        if evaluate_sensor {
            physical_plan.sensor_enabled = false;
            physical_plan.requested_intermediate = PhysicalIntermediate::ShutterMotion;
        } else {
            physical_plan.sensor_enabled = false;
        }
        let physical = self.evaluate_rows(
            source_acescg,
            device_signal,
            environment_acescg,
            physical_plan,
            None,
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
        let mut final_plan = plan;
        final_plan.sensor_enabled = evaluate_sensor;
        self.evaluate_sensor_raw(
            physical,
            final_plan,
            |progress| report_progress(0.9 + progress * 0.1),
            is_cancelled,
        )
    }

    fn evaluate_rows(
        &self,
        source_acescg: &TextureRef,
        device_signal: &TextureRef,
        environment_acescg: Option<&TextureRef>,
        plan: PhysicalPipelineExecutionPlan,
        row_range: Option<(u32, u32)>,
        row_prefixes: Option<(&TextureRef, &TextureRef)>,
        mut report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
        let plan = plan.stopped_at_requested_intermediate();
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
        plan.environment
            .validate()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        plan.panel_uniformity
            .validate()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        match (plan.environment, environment_acescg) {
            (IncidentEnvironment::Procedural(_), None) => {}
            (IncidentEnvironment::Equirectangular(_), Some(texture))
                if supported(texture)
                    && texture.width() == texture.height().saturating_mul(2)
                    && texture.mipmap_level_count() == 1 => {}
            (IncidentEnvironment::Equirectangular(_), Some(_)) => {
                return Err(MetalPhysicalPipelineError::InvalidPlan(
                    "equirectangular environment must be an exact single-level 2:1 float texture"
                        .to_owned(),
                ));
            }
            _ => {
                return Err(MetalPhysicalPipelineError::InvalidPlan(
                    "resolved environment source and texture do not match".to_owned(),
                ));
            }
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
            plan.shutter_motion_amount,
            plan.sensor_noise_amount,
        ]
        .into_iter()
        .any(|amount| !amount.is_finite() || !(0.0..=4.0).contains(&amount))
        {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "amount must be finite and inside 0..=4".to_owned(),
            ));
        }
        if !plan.computational_character_strength.is_finite()
            || !(0.0..=1.5).contains(&plan.computational_character_strength)
        {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "computational capture character must be inside 0..=1.5".to_owned(),
            ));
        }
        plan.panel_light_spread
            .validate()
            .map_err(|error| MetalPhysicalPipelineError::InvalidPlan(error.to_string()))?;
        plan.computational_capture
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
                | PhysicalIntermediate::PanelUniformity
                | PhysicalIntermediate::PanelLightSpread
                | PhysicalIntermediate::RelativeGeometry
                | PhysicalIntermediate::CoverEnvironment
                | PhysicalIntermediate::CoverGlow
                | PhysicalIntermediate::LensProjection
                | PhysicalIntermediate::ShutterMotion
                | PhysicalIntermediate::ComputationalCapture
                | PhysicalIntermediate::SensorBloom
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
                stage_elapsed_nanoseconds: [0; 16],
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
        let image_environment_parameters = match plan.environment {
            IncidentEnvironment::Procedural(_) => None,
            IncidentEnvironment::Equirectangular(_) => Some([
                0.0,
                0.0,
                0.0,
                physical_environment_reference_sample_count(plan.quality) as f32,
            ]),
        };
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
                match plan.environment {
                    IncidentEnvironment::Procedural(environment) => match environment.pattern {
                        EnvironmentPattern::UniformNeutral => 0,
                        EnvironmentPattern::StudioSoftboxes => 1,
                        EnvironmentPattern::CalibrationGrid => 2,
                        EnvironmentPattern::OfficeCeiling => 3,
                        EnvironmentPattern::DaylightWindow => 4,
                        EnvironmentPattern::WarmPracticals => 5,
                        EnvironmentPattern::MixedProduction => 6,
                    },
                    IncidentEnvironment::Equirectangular(_) => 0,
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
            uniformity_amplitudes: [
                plan.panel_uniformity.broad_luminance_peak_to_peak,
                plan.panel_uniformity.mid_luminance_peak_to_peak,
                plan.panel_uniformity.fine_luminance_peak_to_peak,
                plan.panel_uniformity.chromatic_peak_to_peak,
            ],
            uniformity_scales: [
                plan.panel_uniformity.mid_scale_millimeters,
                plan.panel_uniformity.fine_scale_millimeters,
                plan.panel_uniformity.low_drive_emphasis,
                plan.panel_uniformity.character_strength,
            ],
            uniformity_seed: [plan.panel_uniformity.seed, 0, 0, 0],
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
            cover_glow: [
                plan.cover.glow.core_radius_millimeters,
                plan.cover.glow.tail_radius_millimeters,
                plan.cover.glow.scatter_fraction * plan.cover.glow.character_strength,
                plan.cover.glow.tail_fraction,
            ],
            environment_ambient_strength: match plan.environment {
                IncidentEnvironment::Procedural(environment) => [
                    environment.ambient_radiance.0.r,
                    environment.ambient_radiance.0.g,
                    environment.ambient_radiance.0.b,
                    environment.character_strength,
                ],
                IncidentEnvironment::Equirectangular(environment) => [
                    environment.source_unit_radiance_candelas_per_square_meter
                        * environment.exposure_stops.exp2(),
                    0.0,
                    0.0,
                    environment.character_strength,
                ],
            },
            environment_key_radius: match plan.environment {
                IncidentEnvironment::Procedural(environment) => [
                    environment.key_radiance.0.r,
                    environment.key_radiance.0.g,
                    environment.key_radiance.0.b,
                    environment.key_angular_radius_degrees.to_radians(),
                ],
                IncidentEnvironment::Equirectangular(_) => {
                    image_environment_parameters.expect("prepared image environment parameters")
                }
            },
            environment_direction_rotation: match plan.environment {
                IncidentEnvironment::Procedural(environment) => [
                    environment.key_direction_local[0],
                    environment.key_direction_local[1],
                    environment.key_direction_local[2],
                    environment.rotation_degrees.to_radians(),
                ],
                IncidentEnvironment::Equirectangular(environment) => {
                    let radians = environment.rotation_degrees.to_radians();
                    let (sine, cosine) = radians.sin_cos();
                    [sine, cosine, 0.0, radians]
                }
            },
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
            lens_veiling_glare: [
                camera.lens.veiling_glare_fraction,
                project_screen(
                    camera,
                    screen,
                    plan.panel.active_width,
                    plan.panel.active_height,
                    sampling.effective_width as f32 / sampling.effective_height as f32,
                )
                .map_or(0.0, projected_screen_gate_coverage)
                    * placed_signal_area_fraction(
                        plan.placement,
                        source_acescg.width() as u32,
                        source_acescg.height() as u32,
                        plan.panel.native_width,
                        plan.panel.native_height,
                    ),
                project_screen(
                    camera,
                    screen,
                    plan.panel.active_width,
                    plan.panel.active_height,
                    sampling.effective_width as f32 / sampling.effective_height as f32,
                )
                .map_or(0.0, |projected| projected.facing_ratio),
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
        let generated_row_prefixes;
        let (source_row_prefix, device_row_prefix) = if let Some(prefixes) = row_prefixes {
            prefixes
        } else {
            generated_row_prefixes = self.row_prefix_textures(source_acescg, device_signal)?;
            (&*generated_row_prefixes.0, &*generated_row_prefixes.1)
        };
        let zero_veiling = [0.0_f32; 4];
        let veiling_gate_average = device.new_buffer_with_data(
            zero_veiling.as_ptr().cast(),
            size_of::<[f32; 4]>() as u64,
            MTLResourceOptions::StorageModeShared,
        );
        if params.lens_veiling_glare[0] != 0.0 {
            let veiling_partials = device.new_buffer(
                (256 * size_of::<[f32; 4]>()) as u64,
                MTLResourceOptions::StorageModeShared,
            );
            let command = self.queue.new_command_buffer();
            let encoder = command.new_compute_command_encoder();
            encoder.set_compute_pipeline_state(&self.veiling_reduce_pipeline);
            encoder.set_texture(0, Some(device_signal));
            encoder.set_buffer(0, Some(&veiling_partials), 0);
            encoder.set_bytes(
                1,
                size_of::<PhysicalPipelineParams>() as u64,
                (&raw const params).cast(),
            );
            let width = self
                .veiling_reduce_pipeline
                .thread_execution_width()
                .min(256)
                .max(1);
            encoder.dispatch_threads(MTLSize::new(256, 1, 1), MTLSize::new(width, 1, 1));
            encoder.memory_barrier_with_resources(&[&veiling_partials]);
            encoder.set_compute_pipeline_state(&self.veiling_finalize_pipeline);
            encoder.set_buffer(0, Some(&veiling_partials), 0);
            encoder.set_buffer(1, Some(&veiling_gate_average), 0);
            encoder.set_bytes(
                2,
                size_of::<PhysicalPipelineParams>() as u64,
                (&raw const params).cast(),
            );
            encoder.dispatch_threads(MTLSize::new(1, 1, 1), MTLSize::new(1, 1, 1));
            encoder.end_encoding();
            command.commit();
            command.wait_until_completed();
            if command.status() != MTLCommandBufferStatus::Completed {
                return Err(MetalPhysicalPipelineError::Backend(
                    "veiling-glare source reduction did not complete".to_owned(),
                ));
            }
        }

        let (work_origin, work_height) = row_range.unwrap_or((0, sampling.effective_height));
        if work_height == 0 || work_origin.saturating_add(work_height) > sampling.effective_height {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "physical work rows exceed the output domain".to_owned(),
            ));
        }
        let tile_count = work_height.div_ceil(TILE_ROWS);
        let physical_pipeline = match (plan.lens_evaluation_model, plan.environment) {
            (LensEvaluationModel::ThinLens, IncidentEnvironment::Procedural(_)) => {
                &self.thin_lens_procedural_pipeline
            }
            (LensEvaluationModel::ThinLens, IncidentEnvironment::Equirectangular(_)) => {
                &self.thin_lens_image_pipeline
            }
            (LensEvaluationModel::VfxDepthBlur, IncidentEnvironment::Procedural(_)) => {
                &self.vfx_depth_blur_procedural_pipeline
            }
            (LensEvaluationModel::VfxDepthBlur, IncidentEnvironment::Equirectangular(_)) => {
                &self.vfx_depth_blur_image_pipeline
            }
        };
        for tile in 0..tile_count {
            if is_cancelled() {
                return Err(MetalPhysicalPipelineError::Cancelled);
            }
            let origin_y = work_origin + tile * TILE_ROWS;
            let height = TILE_ROWS.min(work_origin + work_height - origin_y);
            params.output_tile[2] = origin_y;
            let command = self.queue.new_command_buffer();
            let encoder = command.new_compute_command_encoder();
            encoder.set_compute_pipeline_state(physical_pipeline);
            encoder.set_texture(0, Some(source_acescg));
            encoder.set_texture(1, Some(device_signal));
            encoder.set_texture(2, Some(&output));
            encoder.set_texture(3, Some(&source_row_prefix));
            encoder.set_texture(4, Some(&device_row_prefix));
            encoder.set_texture(5, environment_acescg);
            encoder.set_bytes(
                0,
                size_of::<PhysicalPipelineParams>() as u64,
                (&raw const params).cast(),
            );
            encoder.set_buffer(1, Some(&row_temporal_buffer), 0);
            encoder.set_buffer(2, Some(&veiling_gate_average), 0);
            let thread_width = physical_pipeline.thread_execution_width();
            let thread_height =
                (physical_pipeline.max_total_threads_per_threadgroup() / thread_width).max(1);
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
        let mut stage_elapsed_nanoseconds = [0_u64; 16];
        stage_elapsed_nanoseconds[..11].fill(elapsed);
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
        DeviceSignalRaster, EnvironmentRadianceRaster, PhysicalPipelineInput,
        PhysicalPipelineRequest, evaluate_physical_pipeline_cpu_oracle,
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

    fn read_mip_level(
        device: &DeviceRef,
        queue: &metal::CommandQueueRef,
        texture: &TextureRef,
        level: u64,
    ) -> Vec<[f32; 4]> {
        let width = (texture.width() >> level).max(1);
        let height = (texture.height() >> level).max(1);
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_pixel_format(MTLPixelFormat::RGBA32Float);
        descriptor.set_width(width);
        descriptor.set_height(height);
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        descriptor.set_usage(MTLTextureUsage::ShaderRead);
        let staging = device.new_texture(&descriptor);
        let command = queue.new_command_buffer();
        let blit = command.new_blit_command_encoder();
        blit.copy_from_texture(
            texture,
            0,
            level,
            MTLOrigin { x: 0, y: 0, z: 0 },
            MTLSize::new(width, height, 1),
            &staging,
            0,
            0,
            MTLOrigin { x: 0, y: 0, z: 0 },
        );
        blit.end_encoding();
        command.commit();
        command.wait_until_completed();
        assert_eq!(command.status(), MTLCommandBufferStatus::Completed);
        read(&staging)
    }

    #[test]
    fn prepared_environment_preserves_the_exact_source_radiance() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let source_values = (0..32)
            .map(|index| {
                let value = index as f32 / 31.0;
                [value, value * 2.0, 1.0 - value, 1.0]
            })
            .collect::<Vec<_>>();
        let source = texture(&device, 8, 4, &source_values);
        let prepared = backend
            .prepare_equirectangular_environment(&source)
            .expect("environment preparation");
        assert_eq!(prepared.mipmap_level_count(), 1);
        assert_eq!(
            read_mip_level(&device, &backend.queue, &prepared, 0),
            source_values
        );
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
                environment_acescg: None,
            },
            PhysicalPipelineExecutionPlan {
                panel,
                panel_uniformity: screen_panel::PanelUniformityProfile::PROFESSIONAL_COMPENSATED,
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
                environment: screen_cover::IncidentEnvironment::NONE,
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
                lens_evaluation_model: screen_application::LensEvaluationModel::ThinLens,
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
                computational_capture: screen_sensor::ComputationalCaptureProfile::SINGLE_EXPOSURE,
                computational_character_strength: 0.0,
                sensor: screen_sensor::SensorProfile::REFERENCE,
                radiometric_calibration:
                    screen_application::CameraRadiometricCalibration::REFERENCE,
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
    fn cover_and_procedural_environment_match_the_existing_cpu_authority() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for cover in [
            screen_cover::CoverGlassProfile::NEUTRAL,
            screen_cover::COVER_GLASS_PRESETS[1].profile,
            screen_cover::COVER_GLASS_PRESETS[4].profile,
        ] {
            for environment in [
                screen_cover::ProceduralEnvironment::NONE,
                screen_cover::environment_preset("environment-uniform-neutral")
                    .unwrap()
                    .environment,
                screen_cover::environment_preset("environment-studio-softboxes")
                    .unwrap()
                    .environment,
                screen_cover::environment_preset("environment-calibration-grid")
                    .unwrap()
                    .environment,
            ] {
                let (input, mut plan) = fixture(
                    RasterPlacement::Stretch,
                    FlatPanelQuality::High,
                    StripeLayout::Bgr,
                    0.2,
                    1.0,
                );
                plan.cover = cover;
                plan.environment = screen_cover::IncidentEnvironment::Procedural(environment);
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
                assert!(
                    maximum <= 2.0e-3,
                    "cover CPU/Metal deviation {maximum}; cover={cover:?}; environment={environment:?}"
                );
            }
        }
    }

    #[test]
    fn panel_uniformity_matches_cpu_for_identity_calibrated_and_artistic_amounts() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for layout in [StripeLayout::Rgb, StripeLayout::Bgr] {
            for (placement, amount, intermediate) in [
                (
                    RasterPlacement::Stretch,
                    0.0,
                    PhysicalIntermediate::PanelUniformity,
                ),
                (
                    RasterPlacement::Stretch,
                    1.0,
                    PhysicalIntermediate::PanelUniformity,
                ),
                (
                    RasterPlacement::Stretch,
                    4.0,
                    PhysicalIntermediate::PanelUniformity,
                ),
                (
                    RasterPlacement::Fit,
                    1.0,
                    PhysicalIntermediate::PanelUniformity,
                ),
                (
                    RasterPlacement::Fit,
                    1.0,
                    PhysicalIntermediate::PanelLightSpread,
                ),
            ] {
                let (input, mut plan) =
                    fixture(placement, FlatPanelQuality::High, layout, 0.2, 1.0);
                plan.panel_uniformity.character_strength = amount;
                plan.requested_intermediate = intermediate;
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
                        .expect("CPU uniformity oracle");
                let gpu = backend
                    .evaluate(&source, &signal, plan, |_| {}, || false)
                    .expect("Metal uniformity result");
                let maximum = read(&gpu.texture)
                    .iter()
                    .zip(&cpu.acescg)
                    .flat_map(|(gpu, cpu)| gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs()))
                    .fold(0.0_f32, f32::max);
                assert!(
                    maximum <= 2.0e-3,
                    "uniformity CPU/Metal deviation {maximum}; layout={layout:?}; placement={placement:?}; amount={amount}; intermediate={intermediate:?}"
                );
            }
        }
    }

    #[test]
    fn equirectangular_environment_matches_cpu_for_both_lens_specializations() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let environment_values = (0..32)
            .map(|index| {
                let x = (index % 8) as f32 / 7.0;
                let y = (index / 8) as f32 / 3.0;
                [0.1 + 1.7 * x, 0.2 + 0.8 * y, 1.1 - 0.6 * x, 1.0]
            })
            .collect::<Vec<_>>();
        let environment_source = texture(&device, 8, 4, &environment_values);
        let prepared_environment = backend
            .prepare_equirectangular_environment(&environment_source)
            .expect("environment preparation");

        for lens_evaluation_model in [
            screen_application::LensEvaluationModel::ThinLens,
            screen_application::LensEvaluationModel::VfxDepthBlur,
        ] {
            let (mut input, mut plan) = fixture(
                RasterPlacement::Stretch,
                FlatPanelQuality::High,
                StripeLayout::Bgr,
                0.2,
                1.0,
            );
            input.environment_acescg = Some(EnvironmentRadianceRaster {
                width: 8,
                height: 4,
                rgba: environment_values.clone(),
            });
            plan.cover = screen_cover::COVER_GLASS_PRESETS[0].profile;
            plan.environment = screen_cover::IncidentEnvironment::Equirectangular(
                screen_cover::EquirectangularEnvironment {
                    character_strength: 1.0,
                    source_unit_radiance_candelas_per_square_meter: 100.0,
                    exposure_stops: 0.0,
                    rotation_degrees: 17.0,
                },
            );
            plan.lens_evaluation_model = lens_evaluation_model;
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
                    .expect("CPU image-environment oracle");
            let gpu = backend
                .evaluate_with_environment(
                    &source,
                    &signal,
                    Some(&prepared_environment),
                    plan,
                    |_| {},
                    || false,
                )
                .expect("Metal image-environment result");
            let maximum = read(&gpu.texture)
                .iter()
                .zip(&cpu.acescg)
                .flat_map(|(gpu, cpu)| gpu.iter().zip(cpu).map(|(gpu, cpu)| (gpu - cpu).abs()))
                .fold(0.0_f32, f32::max);
            assert!(
                maximum <= 2.0e-3,
                "image-environment CPU/Metal deviation {maximum}; lens={lens_evaluation_model:?}"
            );
        }
    }

    #[test]
    fn scene_geometry_and_generalized_lens_match_cpu_for_zero_one_and_artistic_amounts() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for lens_evaluation_model in [
            screen_application::LensEvaluationModel::ThinLens,
            screen_application::LensEvaluationModel::VfxDepthBlur,
        ] {
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
                plan.lens_evaluation_model = lens_evaluation_model;
                plan.camera_position = screen_contracts::Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.01,
                };
                plan.scene_geometry_lens.focus_distance_meters = 0.01;
                plan.scene_geometry_lens.focal_length_millimeters = 10.0;
                plan.scene_geometry_lens.sensor_width_millimeters = 4.0;
                plan.scene_geometry_lens.sensor_height_millimeters = 2.0;
                plan.requested_intermediate = PhysicalIntermediate::LensProjection;
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
                    "scene/lens CPU/Metal deviation {maximum}; model={lens_evaluation_model:?}; amount={lens_amount}"
                );
            }
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
    fn metal_adapter_preserves_application_raw_codes_and_masks_exactly() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        for (intermediate, noise_amount) in [
            (PhysicalIntermediate::SensorNoise, 0.0),
            (PhysicalIntermediate::RawMosaic, 1.0),
        ] {
            let (input, mut plan) = fixture(
                RasterPlacement::FillCrop,
                FlatPanelQuality::High,
                StripeLayout::Rgb,
                0.0,
                1.0,
            );
            plan.sensor = screen_sensor::SensorProfile {
                native_width: 13,
                native_height: 9,
                adc_bits: 12,
                ..screen_sensor::SensorProfile::REFERENCE
            };
            plan.sensor_enabled = true;
            plan.sensor_noise_amount = noise_amount;
            plan.requested_intermediate = intermediate;
            let source = texture(&device, input.width, input.height, &input.acescg);
            let signal_values = input
                .device_signal
                .pixels
                .iter()
                .map(|value| [value.r, value.g, value.b, 1.0])
                .collect::<Vec<_>>();
            let signal = texture(&device, input.width, input.height, &signal_values);
            let stopped = plan.stopped_at_requested_intermediate();
            let mut optical_plan = stopped;
            optical_plan.sensor_enabled = false;
            optical_plan.requested_intermediate = PhysicalIntermediate::ShutterMotion;
            let physical = backend
                .evaluate(&source, &signal, optical_plan, |_| {}, || false)
                .expect("Metal shutter checkpoint");
            let physical_values = MetalPhysicalPipeline::read_physical_raster(&physical.texture)
                .expect("shared optical raster");
            let raw = expose_physical_pipeline_raw(
                &physical_values,
                physical.texture.width() as u32,
                physical.texture.height() as u32,
                stopped,
            )
            .expect("Application RAW boundary");
            let result = backend
                .evaluate_sensor_raw(physical, stopped, |_| {}, || false)
                .expect("adapter RAW publication");
            let published = read(&result.texture);
            let maximum_code = ((1_u32 << raw.adc_bits) - 1) as f32;
            let published_codes = published
                .iter()
                .map(|pixel| (pixel[0] * maximum_code).round() as u16)
                .collect::<Vec<_>>();
            let published_full_well = published
                .iter()
                .map(|pixel| pixel[1].to_bits() == 1.0_f32.to_bits())
                .collect::<Vec<_>>();
            let published_adc = published
                .iter()
                .map(|pixel| pixel[2].to_bits() == 1.0_f32.to_bits())
                .collect::<Vec<_>>();
            assert_eq!(published_codes, raw.codes);
            assert_eq!(published_full_well, raw.full_well_clipped);
            assert_eq!(published_adc, raw.adc_clipped);
        }
    }

    #[test]
    fn direct_backend_enforces_clean_sensor_cfa_before_the_noisy_raw_phase() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let (input, mut authored) = fixture(
            RasterPlacement::Stretch,
            FlatPanelQuality::High,
            StripeLayout::Rgb,
            0.0,
            1.0,
        );
        authored.sensor = screen_sensor::SensorProfile {
            native_width: authored.requested_width as u16,
            native_height: authored.requested_height as u16,
            read_noise_electrons_rms: 500.0,
            ..screen_sensor::SensorProfile::REFERENCE
        };
        authored.sensor_enabled = true;
        authored.sensor_noise_amount = 1.0;
        authored.requested_intermediate = PhysicalIntermediate::SensorNoise;
        let source = texture(&device, input.width, input.height, &input.acescg);
        let signal_values = input
            .device_signal
            .pixels
            .iter()
            .map(|value| [value.r, value.g, value.b, 1.0])
            .collect::<Vec<_>>();
        let signal = texture(&device, input.width, input.height, &signal_values);
        let clean = backend
            .evaluate(&source, &signal, authored, |_| {}, || false)
            .expect("clean Sensor/CFA checkpoint");
        let mut explicit_zero = authored;
        explicit_zero.sensor_noise_amount = 0.0;
        let zero = backend
            .evaluate(&source, &signal, explicit_zero, |_| {}, || false)
            .expect("explicit zero-noise checkpoint");
        assert_eq!(read(&clean.texture), read(&zero.texture));

        let mut noisy = authored;
        noisy.requested_intermediate = PhysicalIntermediate::RawMosaic;
        let noisy = backend
            .evaluate(&source, &signal, noisy, |_| {}, || false)
            .expect("authored noisy RAW checkpoint");
        assert_ne!(read(&clean.texture), read(&noisy.texture));
    }

    #[test]
    fn an_earlier_checkpoint_does_not_execute_the_enabled_sensor() {
        let device = metal::Device::system_default().expect("test Mac has Metal");
        let backend = MetalPhysicalPipeline::new(&device).expect("physical pipeline backend");
        let (input, mut plan) = fixture(
            RasterPlacement::Stretch,
            FlatPanelQuality::Draft,
            StripeLayout::Rgb,
            0.0,
            1.0,
        );
        plan.sensor_enabled = true;
        plan.development_enabled = true;
        plan.requested_intermediate = PhysicalIntermediate::PanelEmission;
        let source = texture(&device, input.width, input.height, &input.acescg);
        let signal_values = input
            .device_signal
            .pixels
            .iter()
            .map(|value| [value.r, value.g, value.b, 1.0])
            .collect::<Vec<_>>();
        let signal = texture(&device, input.width, input.height, &signal_values);
        let with_later_stages_enabled = backend
            .evaluate(&source, &signal, plan, |_| {}, || false)
            .expect("panel checkpoint with later stages enabled");
        plan.sensor_enabled = false;
        plan.development_enabled = false;
        let stopped_at_panel = backend
            .evaluate(&source, &signal, plan, |_| {}, || false)
            .expect("panel checkpoint");
        assert_eq!(
            read(&with_later_stages_enabled.texture),
            read(&stopped_at_panel.texture)
        );
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
            // The calibrated nits-to-sensor boundary raises the meaningful
            // developed code range while preserving the same GPU arithmetic;
            // keep an explicit absolute tolerance for the larger physical
            // domain rather than silently comparing a normalized surrogate.
            assert!(maximum <= 2.5e-3, "developed CPU/Metal deviation {maximum}");
        }
    }
}
