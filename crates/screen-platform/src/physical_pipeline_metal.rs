use core::fmt;
use core::mem::size_of;

use metal::{
    ComputePipelineState, DeviceRef, MTLCommandBufferStatus, MTLSize, MTLStorageMode,
    MTLTextureType, MTLTextureUsage, Texture, TextureDescriptor, TextureRef,
};
use screen_application::{PhysicalPipelineExecutionPlan, RasterPlacement};
use screen_panel::{FlatPanelGeometry, FlatPanelSampling, StripeLayout};

const SHADER_LIBRARY: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/native_camera.metallib"));
const TILE_ROWS: u32 = 64;

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
}

pub struct MetalPhysicalPipeline {
    queue: metal::CommandQueue,
    pipeline: ComputePipelineState,
}

pub struct MetalPhysicalPipelineResult {
    pub texture: Texture,
    pub geometry: FlatPanelGeometry,
    pub sampling: FlatPanelSampling,
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
        Ok(Self {
            queue: device.new_command_queue(),
            pipeline,
        })
    }

    pub fn evaluate(
        &self,
        source_acescg: &TextureRef,
        device_signal: &TextureRef,
        plan: PhysicalPipelineExecutionPlan,
        mut report_progress: impl FnMut(f32),
        is_cancelled: impl Fn() -> bool,
    ) -> Result<MetalPhysicalPipelineResult, MetalPhysicalPipelineError> {
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
        ]
        .into_iter()
        .any(|amount| !amount.is_finite() || !(0.0..=4.0).contains(&amount))
        {
            return Err(MetalPhysicalPipelineError::InvalidPlan(
                "amount must be finite and inside 0..=4".to_owned(),
            ));
        }
        if is_cancelled() {
            return Err(MetalPhysicalPipelineError::Cancelled);
        }
        if plan.screen_amount == 0.0 {
            report_progress(1.0);
            return Ok(MetalPhysicalPipelineResult {
                texture: source_acescg.to_owned(),
                geometry,
                sampling,
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
                0,
                0,
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
                0.0,
            ],
            matrix0: pad(values.native_to_acescg[0]),
            matrix1: pad(values.native_to_acescg[1]),
            matrix2: pad(values.native_to_acescg[2]),
        };

        let tile_count = sampling.effective_height.div_ceil(TILE_ROWS);
        for tile in 0..tile_count {
            if is_cancelled() {
                return Err(MetalPhysicalPipelineError::Cancelled);
            }
            let origin_y = tile * TILE_ROWS;
            let height = TILE_ROWS.min(sampling.effective_height - origin_y);
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
        Ok(MetalPhysicalPipelineResult {
            texture: output,
            geometry,
            sampling,
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
    use screen_panel::{DEVICE_PRESETS, FlatPanelQuality};

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
                placement,
                quality,
                requested_width: 12,
                requested_height: 8,
                screen_amount: amount,
                emission_amount: 1.0,
                subpixel_geometry_amount: 1.0,
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
                        let (input, plan) = fixture(placement, quality, layout, matrix, 1.5);
                        let source = texture(&device, input.width, input.height, &input.acescg);
                        let signal_values = input
                            .device_signal
                            .pixels
                            .iter()
                            .map(|value| [value.r, value.g, value.b, 1.0])
                            .collect::<Vec<_>>();
                        let signal = texture(&device, input.width, input.height, &signal_values);
                        let cpu = evaluate_physical_pipeline_cpu_oracle(PhysicalPipelineRequest {
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
}
