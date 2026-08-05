use core::mem::size_of_val;

use metal::{
    CompileOptions, Device, MTLCommandBufferStatus, MTLPixelFormat, MTLRegion, MTLResourceOptions,
    MTLSamplerAddressMode, MTLSamplerMinMagFilter, MTLSize, MTLStorageMode, MTLTextureType,
    MTLTextureUsage, SamplerDescriptor, TextureDescriptor,
};
use screen_color::{
    CameraOutputTransform, ColorEngine, OcioGpuShader, OcioGpuTextureInterpolation,
};

fn generated_compute_source(shader: &OcioGpuShader) -> String {
    let parameters = shader
        .textures
        .iter()
        .map(|texture| {
            format!(
                ", texture2d<float> {} [[texture({})]], sampler {} [[sampler({})]]",
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
    format!(
        "#include <metal_stdlib>\nusing namespace metal;\n{}\nkernel void screenSimulationPresentation(\n device const float4 *input [[buffer(0)]],\n device float4 *output [[buffer(1)]],\n constant uint &count [[buffer(2)]]{}\n , uint index [[thread_position_in_grid]]) {{\n if (index < count) output[index] = {}({}, input[index]);\n}}\n",
        shader.source, parameters, shader.function_name, arguments
    )
}

fn metal_apply(shader: &OcioGpuShader, input: &[[f32; 4]]) -> Vec<[f32; 4]> {
    assert_eq!(
        shader.uniform_count, 0,
        "probe does not guess OCIO uniforms"
    );
    let device = Device::system_default().expect("Metal device");
    let options = CompileOptions::new();
    options.set_fast_math_enabled(false);
    let library = device
        .new_library_with_source(&generated_compute_source(shader), &options)
        .expect("OCIO-generated MSL compiles");
    let function = library
        .get_function("screenSimulationPresentation", None)
        .expect("presentation function");
    let pipeline = device
        .new_compute_pipeline_state_with_function(&function)
        .expect("presentation pipeline");
    let input_buffer = device.new_buffer_with_data(
        input.as_ptr().cast(),
        size_of_val(input) as u64,
        MTLResourceOptions::StorageModeShared,
    );
    let output_buffer = device.new_buffer(
        size_of_val(input) as u64,
        MTLResourceOptions::StorageModeShared,
    );
    let count = input.len() as u32;
    let count_buffer = device.new_buffer_with_data(
        core::ptr::from_ref(&count).cast(),
        size_of_val(&count) as u64,
        MTLResourceOptions::StorageModeShared,
    );
    let mut textures = Vec::new();
    let mut samplers = Vec::new();
    for resource in &shader.textures {
        assert_eq!(
            resource.depth, 1,
            "probe handles the generated 2D LUT contract"
        );
        let descriptor = TextureDescriptor::new();
        descriptor.set_texture_type(MTLTextureType::D2);
        descriptor.set_width(resource.width as u64);
        descriptor.set_height(resource.height as u64);
        descriptor.set_storage_mode(MTLStorageMode::Shared);
        descriptor.set_usage(MTLTextureUsage::ShaderRead);
        let upload;
        let bytes_per_pixel;
        if resource.channel_count == 1 {
            descriptor.set_pixel_format(MTLPixelFormat::R32Float);
            upload = resource.values.clone();
            bytes_per_pixel = size_of_val(&resource.values[0]);
        } else {
            assert_eq!(resource.channel_count, 3);
            descriptor.set_pixel_format(MTLPixelFormat::RGBA32Float);
            upload = resource
                .values
                .chunks_exact(3)
                .flat_map(|rgb| [rgb[0], rgb[1], rgb[2], 0.0])
                .collect();
            bytes_per_pixel = size_of_val(&[0.0_f32; 4]);
        }
        let texture = device.new_texture(&descriptor);
        texture.replace_region(
            MTLRegion::new_2d(0, 0, resource.width as u64, resource.height as u64),
            0,
            upload.as_ptr().cast(),
            bytes_per_pixel as u64 * resource.width as u64,
        );
        let sampler_descriptor = SamplerDescriptor::new();
        let filter = match resource.interpolation {
            OcioGpuTextureInterpolation::Nearest => MTLSamplerMinMagFilter::Nearest,
            OcioGpuTextureInterpolation::Linear => MTLSamplerMinMagFilter::Linear,
        };
        sampler_descriptor.set_min_filter(filter);
        sampler_descriptor.set_mag_filter(filter);
        sampler_descriptor.set_address_mode_s(MTLSamplerAddressMode::ClampToEdge);
        sampler_descriptor.set_address_mode_t(MTLSamplerAddressMode::ClampToEdge);
        sampler_descriptor.set_normalized_coordinates(true);
        textures.push((resource.binding_index, texture));
        samplers.push((
            resource.binding_index,
            device.new_sampler(&sampler_descriptor),
        ));
    }
    let queue = device.new_command_queue();
    let command = queue.new_command_buffer();
    let encoder = command.new_compute_command_encoder();
    encoder.set_compute_pipeline_state(&pipeline);
    encoder.set_buffer(0, Some(&input_buffer), 0);
    encoder.set_buffer(1, Some(&output_buffer), 0);
    encoder.set_buffer(2, Some(&count_buffer), 0);
    for (index, texture) in &textures {
        encoder.set_texture(*index as u64, Some(texture));
    }
    for (index, sampler) in &samplers {
        encoder.set_sampler_state(*index as u64, Some(sampler));
    }
    let width = pipeline
        .thread_execution_width()
        .min(input.len() as u64)
        .max(1);
    encoder.dispatch_threads(
        MTLSize::new(input.len() as u64, 1, 1),
        MTLSize::new(width, 1, 1),
    );
    encoder.end_encoding();
    command.commit();
    command.wait_until_completed();
    assert_eq!(command.status(), MTLCommandBufferStatus::Completed);
    // SAFETY: the shared output has exactly `input.len()` float4 values and the command completed.
    unsafe {
        core::slice::from_raw_parts(output_buffer.contents().cast::<[f32; 4]>(), input.len())
            .to_vec()
    }
}

fn quantize(value: [f32; 4]) -> [u8; 4] {
    let channel = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
    [channel(value[0]), channel(value[1]), channel(value[2]), 255]
}

#[test]
fn generated_msl_is_not_byte_exact_enough_for_native_product() {
    let processor = ColorEngine::bundled()
        .expect("bundled OCIO")
        .camera_output_processor(CameraOutputTransform::SrgbSdr100)
        .expect("pinned output processor");
    let shader = ColorEngine::bundled()
        .expect("bundled OCIO")
        .camera_output_gpu_shader(CameraOutputTransform::SrgbSdr100)
        .expect("pinned generated shader");
    let mut input = vec![
        [-0.1, -0.1, -0.1, 1.0],
        [0.0, 0.0, 0.0, 1.0],
        [0.18, 0.18, 0.18, 1.0],
        [1.0, 0.0, 0.0, 1.0],
        [0.0, 1.0, 0.0, 1.0],
        [0.0, 0.0, 1.0, 1.0],
        [4.0, 2.0, 0.5, 1.0],
        [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 1.0],
    ];
    for index in 0..65_536_u32 {
        let value = index as f32 / 8_192.0 - 2.0;
        input.push([value, value * 0.37, value * 1.91, 1.0]);
    }
    let gpu = metal_apply(&shader, &input);
    let mut cpu = input.iter().flatten().copied().collect::<Vec<_>>();
    processor
        .apply_acescg_rgba_buffer(&mut cpu)
        .expect("CPU reference");
    let mismatches = cpu
        .chunks_exact(4)
        .map(|rgba| [rgba[0], rgba[1], rgba[2], rgba[3]])
        .zip(gpu)
        .filter(|(cpu, gpu)| quantize(*cpu) != quantize(*gpu))
        .count();
    assert!(
        mismatches > 0,
        "generated MSL unexpectedly became byte-exact; product eligibility must be re-audited"
    );
    eprintln!(
        "OCIO generated-MSL byte mismatches: {mismatches}/{}",
        input.len()
    );
}
