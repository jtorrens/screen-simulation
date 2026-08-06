use core::fmt;
use core::mem::{size_of, size_of_val};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use metal::{
    Buffer, CompileOptions, ComputePipelineState, Device, MTLCommandBufferStatus, MTLPixelFormat,
    MTLRegion, MTLResourceOptions, MTLSamplerAddressMode, MTLSamplerMinMagFilter, MTLSize,
    MTLStorageMode, MTLTextureType, MTLTextureUsage, SamplerDescriptor, SamplerState, Texture,
    TextureDescriptor,
};
use screen_application::{NativeDeviceSignalResource, PreparedNativeDeviceSignalRaster};
use screen_color::{
    ColorEngine, DeviceColorTarget, OcioGpuShader, OcioGpuTexture, OcioGpuTextureDimension,
    OcioGpuTextureInterpolation, SourceColorInterpretation,
};
use screen_contracts::RationalTime;
use screen_media::{
    AlphaInterpretation, AlphaPresence, FrameCadence, FrameSelectionPolicy, MediaDescriptor,
    ResolvedSourceDecode,
};
use screen_panel::LcdProfile;

use crate::{MediaDecodeDimensions, PlatformMediaError, decode_rgba16_frame_at_time};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MetalMediaPreparationTimings {
    pub probe_and_decode: Duration,
    pub transfer_and_idt: Duration,
    pub panel_preparation: Duration,
}

#[derive(Clone, Debug)]
pub struct MetalMediaFrameRequest<'a> {
    pub path: &'a Path,
    pub descriptor: &'a MediaDescriptor,
    pub requested_time: RationalTime,
    pub policy: FrameSelectionPolicy,
    pub decode_interpretation: ResolvedSourceDecode,
    pub color_interpretation: SourceColorInterpretation,
    pub alpha_interpretation: AlphaInterpretation,
    pub dimensions: MediaDecodeDimensions,
    pub panel: LcdProfile,
}

#[derive(Clone, Debug)]
pub struct PreparedMetalMediaFrame {
    pub signal: Arc<PreparedNativeDeviceSignalRaster>,
    pub resolved_time: RationalTime,
    pub timings: MetalMediaPreparationTimings,
    pub cache_hit: bool,
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct TimeKey {
    numerator: i64,
    denominator: u32,
}

impl From<RationalTime> for TimeKey {
    fn from(value: RationalTime) -> Self {
        Self {
            numerator: value.numerator(),
            denominator: value.denominator(),
        }
    }
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct PanelSignalKey {
    gamma: u32,
    black: u32,
    white: u32,
}

impl From<LcdProfile> for PanelSignalKey {
    fn from(value: LcdProfile) -> Self {
        Self {
            gamma: value.eotf_gamma.to_bits(),
            black: value.black_level_nits.to_bits(),
            white: value.white_level_nits.to_bits(),
        }
    }
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct FrameKey {
    path: PathBuf,
    time: TimeKey,
    policy: FrameSelectionPolicy,
    decode: ResolvedSourceDecode,
    color: SourceColorInterpretation,
    alpha: AlphaInterpretation,
    dimensions: MediaDecodeDimensions,
    panel: PanelSignalKey,
}

struct InputPipeline {
    idt: ComputePipelineState,
    prefix: ComputePipelineState,
    textures: Vec<(u32, Texture)>,
    samplers: Vec<(u32, SamplerState)>,
}

pub(crate) struct MetalNativeRasterResource {
    pub(crate) signal: Buffer,
    pub(crate) code_integral: Buffer,
    pub(crate) emission_integral: Buffer,
    identity: u64,
}

impl fmt::Debug for MetalNativeRasterResource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("MetalNativeRasterResource")
            .field("identity", &self.identity)
            .finish_non_exhaustive()
    }
}

impl NativeDeviceSignalResource for MetalNativeRasterResource {
    fn identity(&self) -> u64 {
        self.identity
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

struct CacheEntry {
    key: FrameKey,
    frame: Arc<PreparedNativeDeviceSignalRaster>,
    resolved_time: RationalTime,
    last_access: u64,
}

/// Small current-frame cache. Both lookup and authoritative storage include the resolved source
/// timestamp and every interpretation/quality value that changes the prepared GPU representation.
pub struct MetalMediaFrameCache {
    device: Device,
    queue: metal::CommandQueue,
    pipelines: HashMap<(SourceColorInterpretation, DeviceColorTarget), InputPipeline>,
    request_to_resolved: HashMap<FrameKey, FrameKey>,
    entries: Vec<CacheEntry>,
    access_counter: u64,
    identity_counter: u64,
    maximum_entries: usize,
}

impl MetalMediaFrameCache {
    pub fn new(maximum_entries: usize) -> Result<Self, MetalMediaError> {
        if maximum_entries == 0 {
            return Err(MetalMediaError(
                "media cache must retain at least one frame".to_owned(),
            ));
        }
        let device = Device::system_default()
            .ok_or_else(|| MetalMediaError("this Mac exposes no Metal device".to_owned()))?;
        let queue = device.new_command_queue();
        Ok(Self {
            device,
            queue,
            pipelines: HashMap::new(),
            request_to_resolved: HashMap::new(),
            entries: Vec::new(),
            access_counter: 0,
            identity_counter: 0,
            maximum_entries,
        })
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    pub fn prepare(
        &mut self,
        request: MetalMediaFrameRequest<'_>,
    ) -> Result<PreparedMetalMediaFrame, MetalMediaError> {
        validate_alpha(request.descriptor.alpha, request.alpha_interpretation)?;
        let requested_key = frame_key(&request, request.requested_time);
        if let Some(resolved_key) = self.request_to_resolved.get(&requested_key).cloned()
            && let Some(index) = self
                .entries
                .iter()
                .position(|entry| entry.key == resolved_key)
        {
            self.access_counter = self.access_counter.wrapping_add(1);
            self.entries[index].last_access = self.access_counter;
            return Ok(PreparedMetalMediaFrame {
                signal: Arc::clone(&self.entries[index].frame),
                resolved_time: self.entries[index].resolved_time,
                timings: MetalMediaPreparationTimings::default(),
                cache_hit: true,
            });
        }
        if let Some(index) = self.cached_sample_for_request(&request, &requested_key)? {
            self.access_counter = self.access_counter.wrapping_add(1);
            self.entries[index].last_access = self.access_counter;
            self.request_to_resolved
                .insert(requested_key, self.entries[index].key.clone());
            return Ok(PreparedMetalMediaFrame {
                signal: Arc::clone(&self.entries[index].frame),
                resolved_time: self.entries[index].resolved_time,
                timings: MetalMediaPreparationTimings::default(),
                cache_hit: true,
            });
        }

        let decode_started = Instant::now();
        let (descriptor, decoded) = decode_rgba16_frame_at_time(
            request.path,
            request.requested_time,
            request.policy,
            request.decode_interpretation,
            request.dimensions,
        )?;
        let probe_and_decode = decode_started.elapsed();
        if descriptor != *request.descriptor {
            return Err(MetalMediaError(
                "source descriptor changed on disk; reopen the source explicitly".to_owned(),
            ));
        }
        let resolved_key = frame_key(&request, decoded.timestamp);
        if let Some(index) = self
            .entries
            .iter()
            .position(|entry| entry.key == resolved_key)
        {
            self.access_counter = self.access_counter.wrapping_add(1);
            self.entries[index].last_access = self.access_counter;
            self.request_to_resolved.insert(requested_key, resolved_key);
            return Ok(PreparedMetalMediaFrame {
                signal: Arc::clone(&self.entries[index].frame),
                resolved_time: self.entries[index].resolved_time,
                timings: MetalMediaPreparationTimings {
                    probe_and_decode,
                    ..MetalMediaPreparationTimings::default()
                },
                cache_hit: true,
            });
        }

        let pipeline_key = (request.color_interpretation, DeviceColorTarget::SrgbDisplay);
        self.ensure_pipeline(pipeline_key)?;
        let pipeline = self
            .pipelines
            .get(&pipeline_key)
            .expect("pipeline exists after explicit preparation");
        let pixel_count = decoded.pixels.len();
        let prefix_count = (decoded.raster.width as usize + 1)
            .checked_mul(decoded.raster.height as usize)
            .ok_or_else(|| MetalMediaError("prepared media raster is too large".to_owned()))?;
        let rgba_bytes = pixel_count
            .checked_mul(size_of::<[f32; 4]>())
            .ok_or_else(|| MetalMediaError("prepared media raster is too large".to_owned()))?;
        let prefix_bytes = prefix_count
            .checked_mul(size_of::<[f32; 4]>())
            .ok_or_else(|| MetalMediaError("prepared media raster is too large".to_owned()))?;

        let transfer_started = Instant::now();
        let input = self.device.new_buffer_with_data(
            decoded.pixels.as_ptr().cast(),
            size_of_val(decoded.pixels.as_slice()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let signal = self
            .device
            .new_buffer(rgba_bytes as u64, MTLResourceOptions::StorageModeShared);
        let params = MediaInputParams {
            pixel_count: pixel_count as u32,
            alpha_mode: alpha_mode(request.descriptor.alpha, request.alpha_interpretation),
        };
        let params = self.device.new_buffer_with_data(
            core::ptr::from_ref(&params).cast(),
            size_of::<MediaInputParams>() as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&pipeline.idt);
        encoder.set_buffer(0, Some(&input), 0);
        encoder.set_buffer(1, Some(&signal), 0);
        encoder.set_buffer(2, Some(&params), 0);
        for (index, texture) in &pipeline.textures {
            encoder.set_texture(*index as u64, Some(texture));
        }
        for (index, sampler) in &pipeline.samplers {
            encoder.set_sampler_state(*index as u64, Some(sampler));
        }
        dispatch(encoder, &pipeline.idt, pixel_count);
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        require_completed(command, "media transfer/IDT")?;
        let transfer_and_idt = transfer_started.elapsed();

        let panel_started = Instant::now();
        let code_integral = self
            .device
            .new_buffer(prefix_bytes as u64, MTLResourceOptions::StorageModeShared);
        let emission_integral = self
            .device
            .new_buffer(prefix_bytes as u64, MTLResourceOptions::StorageModeShared);
        let prefix_params = PrefixParams {
            width: decoded.raster.width,
            height: decoded.raster.height,
            gamma: request.panel.eotf_gamma,
            black: request.panel.black_level_nits,
            white: request.panel.white_level_nits,
        };
        let prefix_params = self.device.new_buffer_with_data(
            core::ptr::from_ref(&prefix_params).cast(),
            size_of::<PrefixParams>() as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&pipeline.prefix);
        encoder.set_buffer(0, Some(&signal), 0);
        encoder.set_buffer(1, Some(&code_integral), 0);
        encoder.set_buffer(2, Some(&emission_integral), 0);
        encoder.set_buffer(3, Some(&prefix_params), 0);
        dispatch(encoder, &pipeline.prefix, decoded.raster.height as usize);
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        require_completed(command, "media panel-prefix preparation")?;
        let panel_preparation = panel_started.elapsed();

        self.identity_counter = self.identity_counter.wrapping_add(1);
        let resource: Arc<dyn NativeDeviceSignalResource> = Arc::new(MetalNativeRasterResource {
            signal,
            code_integral,
            emission_integral,
            identity: self.identity_counter,
        });
        let frame = Arc::new(PreparedNativeDeviceSignalRaster {
            width: decoded.raster.width,
            height: decoded.raster.height,
            resource,
        });
        self.access_counter = self.access_counter.wrapping_add(1);
        self.entries.push(CacheEntry {
            key: resolved_key.clone(),
            frame: Arc::clone(&frame),
            resolved_time: decoded.timestamp,
            last_access: self.access_counter,
        });
        self.request_to_resolved.insert(requested_key, resolved_key);
        self.evict();
        Ok(PreparedMetalMediaFrame {
            signal: frame,
            resolved_time: decoded.timestamp,
            timings: MetalMediaPreparationTimings {
                probe_and_decode,
                transfer_and_idt,
                panel_preparation,
            },
            cache_hit: false,
        })
    }

    fn evict(&mut self) {
        while self.entries.len() > self.maximum_entries {
            let index = self
                .entries
                .iter()
                .enumerate()
                .min_by_key(|(_, entry)| entry.last_access)
                .map(|(index, _)| index)
                .expect("cache is non-empty while over capacity");
            let removed = self.entries.remove(index);
            self.request_to_resolved
                .retain(|_, resolved| *resolved != removed.key);
        }
    }

    fn ensure_pipeline(
        &mut self,
        key: (SourceColorInterpretation, DeviceColorTarget),
    ) -> Result<(), MetalMediaError> {
        if self.pipelines.contains_key(&key) {
            return Ok(());
        }
        let shader = ColorEngine::bundled()
            .and_then(|engine| engine.source_to_device_gpu_shader(key.0, key.1))
            .map_err(MetalMediaError::from_display)?;
        self.pipelines
            .insert(key, make_input_pipeline(&self.device, &shader)?);
        Ok(())
    }

    fn cached_sample_for_request(
        &self,
        request: &MetalMediaFrameRequest<'_>,
        requested_key: &FrameKey,
    ) -> Result<Option<usize>, MetalMediaError> {
        let FrameCadence::Constant { frame_rate } = request.descriptor.cadence else {
            return Ok(None);
        };
        let frame_duration = RationalTime::new(
            i64::from(frame_rate.denominator()),
            u32::try_from(frame_rate.numerator()).map_err(MetalMediaError::from_display)?,
        )
        .map_err(MetalMediaError::from_display)?;
        Ok(self
            .entries
            .iter()
            .enumerate()
            .filter(|(_, entry)| same_frame_contract(&entry.key, requested_key))
            .find(|(_, entry)| {
                cached_interval_contains(
                    request.policy,
                    request.requested_time,
                    entry.resolved_time,
                    frame_duration,
                    request.descriptor.duration,
                )
            })
            .map(|(index, _)| index))
    }
}

fn cached_interval_contains(
    policy: FrameSelectionPolicy,
    requested: RationalTime,
    resolved: RationalTime,
    frame_duration: RationalTime,
    duration: Option<RationalTime>,
) -> bool {
    let zero = RationalTime::new(0, 1).expect("zero is a valid rational time");
    match policy {
        FrameSelectionPolicy::Exact => requested == resolved,
        FrameSelectionPolicy::Floor => {
            let upper = resolved.checked_add(frame_duration).ok();
            (requested >= resolved && upper.is_some_and(|upper| requested < upper))
                || (requested < zero && resolved == zero)
                || duration.is_some_and(|duration| {
                    upper.is_some_and(|upper| upper >= duration) && requested >= resolved
                })
        }
        FrameSelectionPolicy::Nearest => {
            let half_duration = frame_duration.checked_mul_ratio(1, 2).ok();
            let lower = half_duration.and_then(|half| resolved.checked_sub(half).ok());
            let upper = half_duration.and_then(|half| resolved.checked_add(half).ok());
            (lower.is_some_and(|lower| requested > lower)
                && upper.is_some_and(|upper| requested <= upper))
                || (requested < zero && resolved == zero)
                || duration.is_some_and(|duration| {
                    resolved
                        .checked_add(frame_duration)
                        .is_ok_and(|end| end >= duration)
                        && requested > resolved
                })
        }
    }
}

#[cfg(test)]
impl MetalMediaFrameCache {
    fn transform_test_pixels(
        &mut self,
        pixels: &[[u16; 4]],
        presence: AlphaPresence,
        alpha: AlphaInterpretation,
        color: SourceColorInterpretation,
    ) -> Result<Vec<[f32; 4]>, MetalMediaError> {
        validate_alpha(presence, alpha)?;
        let key = (color, DeviceColorTarget::SrgbDisplay);
        self.ensure_pipeline(key)?;
        let pipeline = self.pipelines.get(&key).expect("test pipeline exists");
        let input = self.device.new_buffer_with_data(
            pixels.as_ptr().cast(),
            size_of_val(pixels) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let output = self.device.new_buffer(
            (pixels.len() * size_of::<[f32; 4]>()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let params = MediaInputParams {
            pixel_count: pixels.len() as u32,
            alpha_mode: alpha_mode(presence, alpha),
        };
        let params = self.device.new_buffer_with_data(
            core::ptr::from_ref(&params).cast(),
            size_of::<MediaInputParams>() as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_compute_pipeline_state(&pipeline.idt);
        encoder.set_buffer(0, Some(&input), 0);
        encoder.set_buffer(1, Some(&output), 0);
        encoder.set_buffer(2, Some(&params), 0);
        for (index, texture) in &pipeline.textures {
            encoder.set_texture(*index as u64, Some(texture));
        }
        for (index, sampler) in &pipeline.samplers {
            encoder.set_sampler_state(*index as u64, Some(sampler));
        }
        dispatch(encoder, &pipeline.idt, pixels.len());
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        require_completed(command, "test media IDT")?;
        // SAFETY: the completed shared output contains exactly one float4 per input pixel and is
        // copied before the Metal buffer is released.
        Ok(unsafe {
            core::slice::from_raw_parts(output.contents().cast::<[f32; 4]>(), pixels.len()).to_vec()
        })
    }
}

#[repr(C)]
struct MediaInputParams {
    pixel_count: u32,
    alpha_mode: u32,
}

#[repr(C)]
struct PrefixParams {
    width: u32,
    height: u32,
    gamma: f32,
    black: f32,
    white: f32,
}

fn frame_key(request: &MetalMediaFrameRequest<'_>, time: RationalTime) -> FrameKey {
    FrameKey {
        path: request.path.to_owned(),
        time: time.into(),
        policy: request.policy,
        decode: request.decode_interpretation,
        color: request.color_interpretation,
        alpha: request.alpha_interpretation,
        dimensions: request.dimensions,
        panel: request.panel.into(),
    }
}

fn same_frame_contract(first: &FrameKey, second: &FrameKey) -> bool {
    first.path == second.path
        && first.policy == second.policy
        && first.decode == second.decode
        && first.color == second.color
        && first.alpha == second.alpha
        && first.dimensions == second.dimensions
        && first.panel == second.panel
}

fn validate_alpha(
    presence: AlphaPresence,
    interpretation: AlphaInterpretation,
) -> Result<(), MetalMediaError> {
    if presence == AlphaPresence::Present && interpretation == AlphaInterpretation::Auto {
        return Err(MetalMediaError(
            "alpha metadata cannot resolve association; author Straight, Premultiplied, or Ignore"
                .to_owned(),
        ));
    }
    Ok(())
}

fn alpha_mode(presence: AlphaPresence, interpretation: AlphaInterpretation) -> u32 {
    match (presence, interpretation) {
        (AlphaPresence::Absent, _) | (_, AlphaInterpretation::Ignore) => 0,
        (_, AlphaInterpretation::Straight) => 1,
        (_, AlphaInterpretation::Premultiplied) => 2,
        (_, AlphaInterpretation::Auto) => unreachable!("Auto was rejected above"),
    }
}

fn make_input_pipeline(
    device: &metal::DeviceRef,
    shader: &OcioGpuShader,
) -> Result<InputPipeline, MetalMediaError> {
    if shader.uniform_count != 0 {
        return Err(MetalMediaError(
            "the selected OCIO input requires unsupported dynamic uniforms".to_owned(),
        ));
    }
    let options = CompileOptions::new();
    options.set_fast_math_enabled(false);
    let library = device
        .new_library_with_source(&generated_media_source(shader), &options)
        .map_err(MetalMediaError)?;
    let pipeline = |name| {
        let function = library
            .get_function(name, None)
            .map_err(MetalMediaError::from_display)?;
        device
            .new_compute_pipeline_state_with_function(&function)
            .map_err(MetalMediaError::from_display)
    };
    let textures = shader
        .textures
        .iter()
        .map(|texture| make_texture(device, texture).map(|value| (texture.binding_index, value)))
        .collect::<Result<Vec<_>, _>>()?;
    let samplers = shader
        .textures
        .iter()
        .map(|texture| {
            (
                texture.binding_index,
                make_sampler(device, texture.interpolation),
            )
        })
        .collect();
    Ok(InputPipeline {
        idt: pipeline("screenSimulationMediaInput")?,
        prefix: pipeline("screenSimulationPanelPrefixes")?,
        textures,
        samplers,
    })
}

fn generated_media_source(shader: &OcioGpuShader) -> String {
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
        "#include <metal_stdlib>\nusing namespace metal;\n{}\n\
         struct MediaInputParams {{ uint pixel_count; uint alpha_mode; }};\n\
         struct PrefixParams {{ uint width; uint height; float gamma; float black; float white; }};\n\
         kernel void screenSimulationMediaInput(\n\
           device const ushort4 *input [[buffer(0)]], device float4 *output [[buffer(1)]],\n\
           constant MediaInputParams &p [[buffer(2)]]{}, uint index [[thread_position_in_grid]]) {{\n\
           if (index >= p.pixel_count) return;\n\
           float4 encoded = float4(input[index]) / 65535.0f;\n\
           float alpha = p.alpha_mode == 0 ? 1.0f : encoded.a;\n\
           if (p.alpha_mode == 2) encoded.rgb = alpha == 0.0f ? float3(0.0f) : encoded.rgb / alpha;\n\
           encoded.a = alpha;\n\
           float4 transformed = {}({}encoded);\n\
           output[index] = float4(transformed.rgb * alpha, 0.0f);\n\
         }}\n\
         kernel void screenSimulationPanelPrefixes(\n\
           device const float4 *signal [[buffer(0)]], device float4 *code_prefix [[buffer(1)]],\n\
           device float4 *emission_prefix [[buffer(2)]], constant PrefixParams &p [[buffer(3)]],\n\
           uint row [[thread_position_in_grid]]) {{\n\
           if (row >= p.height) return; uint stride = p.width + 1; uint base = row * stride;\n\
           float3 code_sum = 0.0f; float3 emission_sum = 0.0f;\n\
           code_prefix[base] = 0.0f; emission_prefix[base] = 0.0f;\n\
           for (uint x = 0; x < p.width; ++x) {{\n\
             float3 code = signal[row * p.width + x].rgb;\n\
             float3 emission = p.black + (p.white - p.black) * sign(code) * pow(abs(code), p.gamma);\n\
             code_sum += code; emission_sum += emission;\n\
             code_prefix[base + x + 1] = float4(code_sum, 0.0f);\n\
             emission_prefix[base + x + 1] = float4(emission_sum, 0.0f);\n\
           }}\n\
         }}\n",
        shader.source, parameters, shader.function_name, call_prefix
    )
}

fn dispatch(
    encoder: &metal::ComputeCommandEncoderRef,
    pipeline: &ComputePipelineState,
    count: usize,
) {
    let width = pipeline.thread_execution_width().min(count as u64).max(1);
    encoder.dispatch_threads(MTLSize::new(count as u64, 1, 1), MTLSize::new(width, 1, 1));
}

fn require_completed(
    command: &metal::CommandBufferRef,
    stage: &str,
) -> Result<(), MetalMediaError> {
    if command.status() != MTLCommandBufferStatus::Completed {
        return Err(MetalMediaError(format!(
            "{stage} ended with Metal status {:?}",
            command.status()
        )));
    }
    Ok(())
}

fn make_texture(
    device: &metal::DeviceRef,
    source: &OcioGpuTexture,
) -> Result<Texture, MetalMediaError> {
    if source.width == 0 || source.height == 0 || source.depth == 0 {
        return Err(MetalMediaError(
            "OCIO emitted an empty LUT texture".to_owned(),
        ));
    }
    let texel_count = source.width as usize * source.height as usize * source.depth as usize;
    let expected = texel_count
        .checked_mul(source.channel_count as usize)
        .ok_or_else(|| MetalMediaError("OCIO LUT is too large".to_owned()))?;
    if source.values.len() != expected {
        return Err(MetalMediaError(format!(
            "OCIO LUT contains {} values; expected {expected}",
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
    let (format, upload, components) = if source.channel_count == 1 {
        (MTLPixelFormat::R32Float, source.values.clone(), 1_usize)
    } else if source.channel_count == 3 {
        (
            MTLPixelFormat::RGBA32Float,
            source
                .values
                .chunks_exact(3)
                .flat_map(|rgb| [rgb[0], rgb[1], rgb[2], 0.0])
                .collect(),
            4_usize,
        )
    } else {
        return Err(MetalMediaError(format!(
            "OCIO emitted unsupported {}-channel LUT",
            source.channel_count
        )));
    };
    descriptor.set_pixel_format(format);
    let texture = device.new_texture(&descriptor);
    let bytes_per_row = source.width as usize * components * size_of::<f32>();
    let bytes_per_image = bytes_per_row * source.height as usize;
    texture.replace_region_in_slice(
        MTLRegion::new_3d(
            0,
            0,
            0,
            source.width as u64,
            source.height as u64,
            source.depth as u64,
        ),
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MetalMediaError(String);

impl MetalMediaError {
    fn from_display(error: impl fmt::Display) -> Self {
        Self(error.to_string())
    }
}

impl From<PlatformMediaError> for MetalMediaError {
    fn from(value: PlatformMediaError) -> Self {
        Self(value.to_string())
    }
}

impl fmt::Display for MetalMediaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for MetalMediaError {}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_color::OcioInputTransform;

    fn cpu_oracle(
        pixels: &[[u16; 4]],
        presence: AlphaPresence,
        alpha: AlphaInterpretation,
        color: SourceColorInterpretation,
    ) -> Vec<[f32; 4]> {
        let processor = ColorEngine::bundled()
            .expect("bundled OCIO")
            .source_to_device_processor(color, DeviceColorTarget::SrgbDisplay)
            .expect("CPU input processor");
        let mut rgba = Vec::with_capacity(pixels.len() * 4);
        let mut association = Vec::with_capacity(pixels.len());
        for pixel in pixels {
            let value = pixel.map(|channel| f32::from(channel) / 65_535.0);
            let resolved_alpha = match (presence, alpha) {
                (AlphaPresence::Absent, _) | (_, AlphaInterpretation::Ignore) => 1.0,
                (_, AlphaInterpretation::Straight | AlphaInterpretation::Premultiplied) => value[3],
                (_, AlphaInterpretation::Auto) => unreachable!("test authors alpha"),
            };
            let rgb = if alpha == AlphaInterpretation::Premultiplied && resolved_alpha > 0.0 {
                [
                    value[0] / resolved_alpha,
                    value[1] / resolved_alpha,
                    value[2] / resolved_alpha,
                ]
            } else if alpha == AlphaInterpretation::Premultiplied {
                [0.0; 3]
            } else {
                [value[0], value[1], value[2]]
            };
            rgba.extend_from_slice(&[rgb[0], rgb[1], rgb[2], resolved_alpha]);
            association.push(resolved_alpha);
        }
        processor
            .apply_rgba_buffer(&mut rgba)
            .expect("CPU input transform");
        rgba.chunks_exact(4)
            .zip(association)
            .map(|(pixel, alpha)| [pixel[0] * alpha, pixel[1] * alpha, pixel[2] * alpha, 0.0])
            .collect()
    }

    #[test]
    fn metal_input_matches_cpu_oracle_for_extremes_and_alpha_modes() {
        let straight = [
            [0, 0, 0, 0],
            [65_535, 65_535, 65_535, 65_535],
            [65_535, 0, 32_768, 0],
            [8_192, 16_384, 49_151, 32_768],
        ];
        let premultiplied = [
            [0, 0, 0, 0],
            [32_768, 16_384, 8_192, 32_768],
            [65_535, 32_768, 16_384, 65_535],
        ];
        let mut cache = MetalMediaFrameCache::new(1).expect("Metal cache");
        for (pixels, alpha) in [
            (straight.as_slice(), AlphaInterpretation::Straight),
            (straight.as_slice(), AlphaInterpretation::Ignore),
            (premultiplied.as_slice(), AlphaInterpretation::Premultiplied),
        ] {
            for color in [
                SourceColorInterpretation::IdentityDeviceSignal,
                SourceColorInterpretation::Ocio(OcioInputTransform::CameraRec709),
            ] {
                let expected = cpu_oracle(pixels, AlphaPresence::Present, alpha, color);
                let actual = cache
                    .transform_test_pixels(pixels, AlphaPresence::Present, alpha, color)
                    .expect("Metal input transform");
                let repeated = cache
                    .transform_test_pixels(pixels, AlphaPresence::Present, alpha, color)
                    .expect("deterministic Metal input transform");
                assert_eq!(actual, repeated);
                for (actual, expected) in actual.iter().zip(expected) {
                    for channel in 0..3 {
                        let absolute = (actual[channel] - expected[channel]).abs();
                        let relative = absolute / expected[channel].abs().max(1.0e-6);
                        assert!(
                            absolute <= 5.0e-4 || relative <= 5.0e-4,
                            "alpha={alpha:?} color={color:?} channel={channel} actual={} expected={} abs={absolute} rel={relative}",
                            actual[channel],
                            expected[channel]
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn auto_alpha_is_not_authorized_and_ignore_keeps_zero_alpha_rgb_opaque() {
        let mut cache = MetalMediaFrameCache::new(1).expect("Metal cache");
        assert!(
            cache
                .transform_test_pixels(
                    &[[65_535, 32_768, 16_384, 0]],
                    AlphaPresence::Present,
                    AlphaInterpretation::Auto,
                    SourceColorInterpretation::IdentityDeviceSignal,
                )
                .is_err()
        );
        let ignored = cache
            .transform_test_pixels(
                &[[65_535, 32_768, 16_384, 0]],
                AlphaPresence::Present,
                AlphaInterpretation::Ignore,
                SourceColorInterpretation::IdentityDeviceSignal,
            )
            .expect("explicit opaque interpretation");
        assert_eq!(ignored[0][0], 1.0);
        assert!(ignored[0][1] > 0.49);
        assert!(ignored[0][2] > 0.24);
    }

    #[test]
    fn cached_intervals_preserve_floor_and_nearest_tie_rules() {
        let zero = RationalTime::new(0, 1).expect("zero");
        let frame = RationalTime::new(1, 25).expect("frame");
        let half = RationalTime::new(1, 50).expect("half frame");
        let next = RationalTime::new(1, 25).expect("next frame");
        let after_half = RationalTime::new(3, 100).expect("after midpoint");

        assert!(cached_interval_contains(
            FrameSelectionPolicy::Floor,
            half,
            zero,
            frame,
            None,
        ));
        assert!(!cached_interval_contains(
            FrameSelectionPolicy::Floor,
            next,
            zero,
            frame,
            None,
        ));
        assert!(cached_interval_contains(
            FrameSelectionPolicy::Nearest,
            half,
            zero,
            frame,
            None,
        ));
        assert!(!cached_interval_contains(
            FrameSelectionPolicy::Nearest,
            half,
            next,
            frame,
            None,
        ));
        assert!(cached_interval_contains(
            FrameSelectionPolicy::Nearest,
            after_half,
            next,
            frame,
            None,
        ));
    }
}
