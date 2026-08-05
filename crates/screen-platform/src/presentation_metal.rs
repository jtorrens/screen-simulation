use core::fmt;
use core::mem::size_of_val;

use metal::{
    Buffer, CompileOptions, ComputePipelineState, Device, MTLCommandBufferStatus, MTLPixelFormat,
    MTLRegion, MTLResourceOptions, MTLSamplerAddressMode, MTLSamplerMinMagFilter, MTLSize,
    MTLStorageMode, MTLTextureType, MTLTextureUsage, SamplerDescriptor, SamplerState, Texture,
    TextureDescriptor,
};
use screen_color::{
    CameraOutputTransform, ColorEngine, OcioGpuShader, OcioGpuTexture, OcioGpuTextureDimension,
    OcioGpuTextureInterpolation,
};
use screen_contracts::LinearRgb;

use crate::presentation_cpu::DisplayPublicationBackend;

pub struct MetalDisplayPublication {
    queue: metal::CommandQueue,
    pipeline: ComputePipelineState,
    textures: Vec<(u32, Texture)>,
    samplers: Vec<(u32, SamplerState)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MetalDisplayPublicationError(String);

impl MetalDisplayPublication {
    pub fn new(transform: CameraOutputTransform) -> Result<Self, MetalDisplayPublicationError> {
        let shader = ColorEngine::bundled()
            .and_then(|engine| engine.camera_output_gpu_shader(transform))
            .map_err(MetalDisplayPublicationError::from_display)?;
        if shader.uniform_count != 0 {
            return Err(MetalDisplayPublicationError(
                "the selected OCIO output requires unsupported dynamic uniforms".to_owned(),
            ));
        }
        let device = Device::system_default().ok_or_else(|| {
            MetalDisplayPublicationError("no Metal device is available".to_owned())
        })?;
        let queue = device.new_command_queue();
        let options = CompileOptions::new();
        options.set_fast_math_enabled(false);
        let library = device
            .new_library_with_source(&generated_compute_source(&shader), &options)
            .map_err(MetalDisplayPublicationError)?;
        let function = library
            .get_function("screenSimulationPresentation", None)
            .map_err(MetalDisplayPublicationError::from_display)?;
        let pipeline = device
            .new_compute_pipeline_state_with_function(&function)
            .map_err(MetalDisplayPublicationError::from_display)?;
        let textures = shader
            .textures
            .iter()
            .map(|texture| {
                make_texture(&device, texture).map(|resource| (texture.binding_index, resource))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let samplers = shader
            .textures
            .iter()
            .map(|texture| {
                (
                    texture.binding_index,
                    make_sampler(&device, texture.interpolation),
                )
            })
            .collect();
        Ok(Self {
            queue,
            pipeline,
            textures,
            samplers,
        })
    }
}

impl DisplayPublicationBackend for MetalDisplayPublication {
    type Error = MetalDisplayPublicationError;

    fn publish_acescg_rgba8(&self, pixels: &[LinearRgb]) -> Result<Vec<u8>, Self::Error> {
        if pixels.is_empty() {
            return Ok(Vec::new());
        }
        let input = pixels
            .iter()
            .map(|pixel| [pixel.r, pixel.g, pixel.b, 1.0_f32])
            .collect::<Vec<_>>();
        let input_buffer = self.queue.device().new_buffer_with_data(
            input.as_ptr().cast(),
            size_of_val(input.as_slice()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let output_size = pixels.len().checked_mul(4).ok_or_else(|| {
            MetalDisplayPublicationError("publication raster is too large".to_owned())
        })?;
        let output_buffer = self
            .queue
            .device()
            .new_buffer(output_size as u64, MTLResourceOptions::StorageModeShared);
        self.encode(&input_buffer, &output_buffer, pixels.len())?;
        // SAFETY: the completed shared buffer contains exactly `output_size` bytes and is copied
        // before either Metal buffer is released.
        let output = unsafe {
            core::slice::from_raw_parts(output_buffer.contents().cast::<u8>(), output_size).to_vec()
        };
        Ok(output)
    }
}

impl MetalDisplayPublication {
    fn encode(
        &self,
        input: &Buffer,
        output: &Buffer,
        pixel_count: usize,
    ) -> Result<(), MetalDisplayPublicationError> {
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.pipeline);
        encoder.set_buffer(0, Some(input), 0);
        encoder.set_buffer(1, Some(output), 0);
        for (index, texture) in &self.textures {
            encoder.set_texture(*index as u64, Some(texture));
        }
        for (index, sampler) in &self.samplers {
            encoder.set_sampler_state(*index as u64, Some(sampler));
        }
        let width = self
            .pipeline
            .thread_execution_width()
            .min(pixel_count as u64)
            .max(1);
        encoder.dispatch_threads(
            MTLSize::new(pixel_count as u64, 1, 1),
            MTLSize::new(width, 1, 1),
        );
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalDisplayPublicationError(format!(
                "Metal publication failed with status {:?}",
                command.status()
            )));
        }
        Ok(())
    }
}

impl MetalDisplayPublicationError {
    fn from_display(error: impl fmt::Display) -> Self {
        Self(error.to_string())
    }
}

impl fmt::Display for MetalDisplayPublicationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for MetalDisplayPublicationError {}

fn generated_compute_source(shader: &OcioGpuShader) -> String {
    let parameters = shader
        .textures
        .iter()
        .map(|texture| {
            let texture_type = match texture.dimension {
                OcioGpuTextureDimension::One => "texture1d<float>",
                OcioGpuTextureDimension::Two => "texture2d<float>",
                OcioGpuTextureDimension::Three => "texture3d<float>",
            };
            format!(
                ", {texture_type} {} [[texture({})]], sampler {} [[sampler({})]]",
                texture.texture_name,
                texture.binding_index,
                texture.sampler_name,
                texture.binding_index
            )
        })
        .collect::<String>();
    let arguments = shader
        .textures
        .iter()
        .flat_map(|texture| [&texture.texture_name, &texture.sampler_name])
        .cloned()
        .collect::<Vec<_>>()
        .join(", ");
    let call_prefix = if arguments.is_empty() {
        String::new()
    } else {
        format!("{arguments}, ")
    };
    format!(
        "#include <metal_stdlib>\nusing namespace metal;\n{}\nkernel void screenSimulationPresentation(\n device const float4 *input [[buffer(0)]],\n device uchar4 *output [[buffer(1)]]{}\n , uint index [[thread_position_in_grid]]) {{\n float4 transformed = {}({}input[index]);\n float3 bounded = select(clamp(transformed.rgb, 0.0f, 1.0f), float3(0.0f), isnan(transformed.rgb));\n uchar3 encoded = uchar3(round(bounded * 255.0f));\n output[index] = uchar4(encoded, uchar(255));\n}}\n",
        shader.source, parameters, shader.function_name, call_prefix
    )
}

fn make_texture(
    device: &metal::DeviceRef,
    source: &OcioGpuTexture,
) -> Result<Texture, MetalDisplayPublicationError> {
    if source.width == 0 || source.height == 0 || source.depth == 0 {
        return Err(MetalDisplayPublicationError(
            "OCIO emitted an empty LUT texture".to_owned(),
        ));
    }
    let texel_count = usize::try_from(source.width)
        .ok()
        .and_then(|width| {
            usize::try_from(source.height)
                .ok()
                .and_then(|height| width.checked_mul(height))
        })
        .and_then(|area| {
            usize::try_from(source.depth)
                .ok()
                .and_then(|depth| area.checked_mul(depth))
        })
        .ok_or_else(|| MetalDisplayPublicationError("OCIO LUT is too large".to_owned()))?;
    let expected_values = texel_count
        .checked_mul(usize::from(source.channel_count))
        .ok_or_else(|| MetalDisplayPublicationError("OCIO LUT is too large".to_owned()))?;
    if source.values.len() != expected_values {
        return Err(MetalDisplayPublicationError(format!(
            "OCIO LUT contains {} values; expected {expected_values}",
            source.values.len()
        )));
    }
    let descriptor = TextureDescriptor::new();
    descriptor.set_width(source.width as u64);
    descriptor.set_height(source.height as u64);
    descriptor.set_depth(source.depth as u64);
    descriptor.set_storage_mode(MTLStorageMode::Shared);
    descriptor.set_usage(MTLTextureUsage::ShaderRead);
    descriptor.set_texture_type(match source.dimension {
        OcioGpuTextureDimension::One => MTLTextureType::D1,
        OcioGpuTextureDimension::Two => MTLTextureType::D2,
        OcioGpuTextureDimension::Three => MTLTextureType::D3,
    });
    let (pixel_format, upload, components) = if source.channel_count == 1 {
        (MTLPixelFormat::R32Float, source.values.clone(), 1_usize)
    } else if source.channel_count == 3 {
        (
            MTLPixelFormat::RGBA32Float,
            source
                .values
                .chunks_exact(3)
                .flat_map(|rgb| [rgb[0], rgb[1], rgb[2], 0.0])
                .collect(),
            4,
        )
    } else {
        return Err(MetalDisplayPublicationError(format!(
            "OCIO emitted an unsupported {}-channel LUT",
            source.channel_count
        )));
    };
    descriptor.set_pixel_format(pixel_format);
    let texture = device.new_texture(&descriptor);
    let bytes_per_row = source.width as usize * components * size_of_val(&0.0_f32);
    let bytes_per_image = bytes_per_row * source.height as usize;
    let region = MTLRegion::new_3d(
        0,
        0,
        0,
        source.width as u64,
        source.height as u64,
        source.depth as u64,
    );
    texture.replace_region_in_slice(
        region,
        0,
        0,
        upload.as_ptr().cast(),
        bytes_per_row as u64,
        bytes_per_image as u64,
    );
    Ok(texture)
}

fn make_sampler(
    device: &metal::DeviceRef,
    interpolation: OcioGpuTextureInterpolation,
) -> SamplerState {
    let descriptor = SamplerDescriptor::new();
    let filter = match interpolation {
        OcioGpuTextureInterpolation::Nearest => MTLSamplerMinMagFilter::Nearest,
        OcioGpuTextureInterpolation::Linear => MTLSamplerMinMagFilter::Linear,
    };
    descriptor.set_min_filter(filter);
    descriptor.set_mag_filter(filter);
    descriptor.set_address_mode_s(MTLSamplerAddressMode::ClampToEdge);
    descriptor.set_address_mode_t(MTLSamplerAddressMode::ClampToEdge);
    descriptor.set_address_mode_r(MTLSamplerAddressMode::ClampToEdge);
    descriptor.set_normalized_coordinates(true);
    device.new_sampler(&descriptor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::presentation_cpu::ExactCpuDisplayPublication;

    #[test]
    fn metal_publication_is_bounded_against_the_cpu_ocio_oracle() {
        let mut pixels = vec![
            LinearRgb::new(f32::NAN, f32::INFINITY, f32::NEG_INFINITY),
            LinearRgb::new(-0.1, 0.18, 4.0),
            LinearRgb::new(1.0, 0.0, 0.0),
            LinearRgb::new(0.0, 1.0, 0.0),
            LinearRgb::new(0.0, 0.0, 1.0),
        ];
        pixels.extend((0..65_536_u32).map(|index| {
            let value = index as f32 / 8_192.0 - 2.0;
            LinearRgb::new(value, value * 0.37, value * 1.91)
        }));
        for transform in CameraOutputTransform::ALL {
            let metal = MetalDisplayPublication::new(transform).unwrap();
            let cpu = ExactCpuDisplayPublication::new(transform).unwrap();
            let actual = metal.publish_acescg_rgba8(&pixels).unwrap();
            assert_eq!(actual, metal.publish_acescg_rgba8(&pixels).unwrap());
            let reference = cpu.publish_acescg_rgba8(&pixels).unwrap();
            let mut differing_channels = 0_usize;
            let mut maximum_delta = 0_u8;
            for (actual, reference) in actual.iter().zip(&reference) {
                let delta = actual.abs_diff(*reference);
                differing_channels += usize::from(delta != 0);
                maximum_delta = maximum_delta.max(delta);
            }
            eprintln!(
                "{}: {differing_channels}/{} channels differ; maximum delta {maximum_delta}",
                transform.label(),
                reference.len()
            );
            assert!(maximum_delta <= 1, "{}", transform.label());
            assert!(
                differing_channels * 1_000 <= reference.len() * 5,
                "{} differs in {differing_channels}/{} channels",
                transform.label(),
                reference.len()
            );
        }
    }
}
