use core::fmt;

use metal::{
    CompileOptions, ComputePipelineState, DeviceRef, MTLCommandBufferStatus, MTLPixelFormat,
    MTLSize, MTLStorageMode, MTLTextureUsage, Texture, TextureDescriptor, TextureRef,
};
use screen_color::SceneLinearAdjustment;

pub struct MetalSceneAdjustment {
    queue: metal::CommandQueue,
    pipeline: ComputePipelineState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MetalSceneAdjustmentError(&'static str);

#[repr(C)]
#[derive(Clone, Copy)]
struct Parameters {
    adjustment: [f32; 4],
    white_gains: [f32; 4],
    incident_radiance: u32,
    _padding: [u32; 3],
}

impl MetalSceneAdjustment {
    pub fn new(device: &DeviceRef) -> Result<Self, MetalSceneAdjustmentError> {
        let options = CompileOptions::new();
        options.set_fast_math_enabled(false);
        let library = device
            .new_library_with_source(SHADER, &options)
            .map_err(|_| MetalSceneAdjustmentError("scene adjustment shader compilation failed"))?;
        let function = library
            .get_function("adjustSceneLinearAcesCg", None)
            .map_err(|_| {
                MetalSceneAdjustmentError("scene adjustment shader function is missing")
            })?;
        let pipeline = device
            .new_compute_pipeline_state_with_function(&function)
            .map_err(|_| MetalSceneAdjustmentError("scene adjustment pipeline creation failed"))?;
        Ok(Self {
            queue: device.new_command_queue(),
            pipeline,
        })
    }

    pub fn evaluate(
        &self,
        source: &TextureRef,
        adjustment: SceneLinearAdjustment,
        incident_radiance: bool,
    ) -> Result<Texture, MetalSceneAdjustmentError> {
        adjustment
            .validate()
            .map_err(|_| MetalSceneAdjustmentError("invalid scene adjustment"))?;
        if source.width() == 0
            || source.height() == 0
            || source.texture_type() != metal::MTLTextureType::D2
        {
            return Err(MetalSceneAdjustmentError("invalid source texture"));
        }
        let gains = adjustment
            .acescg_white_gains()
            .map_err(|_| MetalSceneAdjustmentError("invalid white adjustment"))?;
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(metal::MTLTextureType::D2);
        descriptor.set_pixel_format(MTLPixelFormat::RGBA32Float);
        descriptor.set_width(source.width());
        descriptor.set_height(source.height());
        descriptor.set_storage_mode(MTLStorageMode::Private);
        descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
        let output = self.queue.device().new_texture(&descriptor);
        let parameters = Parameters {
            adjustment: [
                adjustment.exposure_ev,
                adjustment.contrast,
                adjustment.saturation,
                0.0,
            ],
            white_gains: [gains.r, gains.g, gains.b, 0.0],
            incident_radiance: u32::from(incident_radiance),
            _padding: [0; 3],
        };
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&self.pipeline);
        encoder.set_texture(0, Some(source));
        encoder.set_texture(1, Some(&output));
        encoder.set_bytes(
            0,
            core::mem::size_of::<Parameters>() as u64,
            (&parameters as *const Parameters).cast(),
        );
        let width = self.pipeline.thread_execution_width();
        let height = (self.pipeline.max_total_threads_per_threadgroup() / width).max(1);
        encoder.dispatch_threads(
            MTLSize::new(source.width(), source.height(), 1),
            MTLSize::new(width, height, 1),
        );
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalSceneAdjustmentError("scene adjustment command failed"));
        }
        Ok(output)
    }
}

impl fmt::Display for MetalSceneAdjustmentError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for MetalSceneAdjustmentError {}

const SHADER: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct Parameters { float4 adjustment; float4 white_gains; uint incident_radiance; uint3 padding; };
inline float signed_contrast(float value, float contrast) {
    return sign(value) * 0.18f * pow(abs(value) / 0.18f, contrast);
}
kernel void adjustSceneLinearAcesCg(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Parameters& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 input = source.read(gid);
    if (p.adjustment.x == 0.0f && p.adjustment.y == 1.0f && p.adjustment.z == 1.0f &&
        all(p.white_gains.xyz == float3(1.0f))) {
        output.write(input, gid);
        return;
    }
    float3 value = input.rgb * exp2(p.adjustment.x) * p.white_gains.xyz;
    value = float3(signed_contrast(value.x, p.adjustment.y),
                   signed_contrast(value.y, p.adjustment.y),
                   signed_contrast(value.z, p.adjustment.y));
    float y = dot(value, float3(0.27222872f, 0.67408174f, 0.053689517f));
    value = y + (value - y) * p.adjustment.z;
    if (p.incident_radiance != 0u) {
        y = max(y, 0.0f);
        float scale = 1.0f;
        if (value.x < 0.0f) scale = min(scale, y / (y - value.x));
        if (value.y < 0.0f) scale = min(scale, y / (y - value.y));
        if (value.z < 0.0f) scale = min(scale, y / (y - value.z));
        value = y + (value - y) * scale;
    }
    output.write(float4(value, input.a), gid);
}
"#;
