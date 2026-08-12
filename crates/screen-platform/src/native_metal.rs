use core::fmt;
use core::mem::size_of;

use metal::{
    Buffer, ComputePipelineState, Device, MTLCommandBufferStatus, MTLResourceOptions, MTLSize,
};
use screen_camera::{
    CameraDevelopment, DevelopedCameraRegion, RawDevelopmentBackend, prepare_raw_region_development,
};
use screen_contracts::LinearRgb;
use screen_sensor::{BayerPattern, RawSensorRegion, SensorProfile};

const SHADER_LIBRARY: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/native_camera.metallib"));

#[repr(C)]
#[derive(Clone, Copy)]
struct CameraParams {
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
    rendering_intent: [f32; 4],
    rendering_white_gains: [f32; 4],
}

pub struct MetalRawDevelopment {
    pub(crate) device: Device,
    pub(crate) queue: metal::CommandQueue,
    green_pipeline: ComputePipelineState,
    develop_pipeline: ComputePipelineState,
    pub(crate) spatial_pipeline: ComputePipelineState,
    pub(crate) spatial_batch_pipeline: ComputePipelineState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MetalNativeError(pub(crate) String);

impl MetalRawDevelopment {
    pub fn new() -> Result<Self, MetalNativeError> {
        let device = Device::system_default()
            .ok_or_else(|| MetalNativeError("this Mac exposes no Metal device".to_owned()))?;
        let library = device
            .new_library_with_data(SHADER_LIBRARY)
            .map_err(|error| {
                MetalNativeError(format!("cannot load native shader library: {error}"))
            })?;
        let pipeline = |name| {
            let function = library.get_function(name, None).map_err(|error| {
                MetalNativeError(format!("native shader {name} is unavailable: {error}"))
            })?;
            device
                .new_compute_pipeline_state_with_function(&function)
                .map_err(|error| {
                    MetalNativeError(format!("cannot create native pipeline {name}: {error}"))
                })
        };
        let green_pipeline = pipeline("reconstruct_green")?;
        let develop_pipeline = pipeline("develop_acescg")?;
        let spatial_pipeline = pipeline("evaluate_spatial_optics")?;
        let spatial_batch_pipeline = pipeline("evaluate_spatial_optics_batch")?;
        let queue = device.new_command_queue();
        Ok(Self {
            device,
            queue,
            green_pipeline,
            develop_pipeline,
            spatial_pipeline,
            spatial_batch_pipeline,
        })
    }

    pub fn device_name(&self) -> &str {
        self.device.name()
    }

    fn shared_buffer<T>(&self, values: &[T]) -> Buffer {
        self.device.new_buffer_with_data(
            values.as_ptr().cast(),
            (size_of_val(values)) as u64,
            MTLResourceOptions::StorageModeShared,
        )
    }

    fn dispatch(
        encoder: &metal::ComputeCommandEncoderRef,
        pipeline: &ComputePipelineState,
        count: usize,
    ) {
        encoder.set_compute_pipeline_state(pipeline);
        let width = pipeline.thread_execution_width().min(count as u64).max(1);
        encoder.dispatch_threads(MTLSize::new(count as u64, 1, 1), MTLSize::new(width, 1, 1));
    }
}

impl RawDevelopmentBackend for MetalRawDevelopment {
    type Error = MetalNativeError;

    fn develop_region(
        &self,
        raw: &RawSensorRegion,
        sensor: SensorProfile,
        development: CameraDevelopment,
    ) -> Result<DevelopedCameraRegion, Self::Error> {
        let plan = prepare_raw_region_development(raw, sensor, development)
            .map_err(|error| MetalNativeError(error.to_string()))?;
        let pad = |row: [f32; 3]| [row[0], row[1], row[2], 0.0];
        let params = CameraParams {
            width: u32::from(raw.region.width),
            height: u32::from(raw.region.height),
            origin_x: u32::from(raw.region.origin_x),
            origin_y: u32::from(raw.region.origin_y),
            pattern: match raw.bayer_pattern {
                BayerPattern::Rggb => 0,
                BayerPattern::Bggr => 1,
                BayerPattern::Grbg => 2,
                BayerPattern::Gbrg => 3,
            },
            maximum_code: plan.maximum_code,
            analog_gain: plan.analog_gain,
            linear_scale: plan.linear_scale,
            saturation: pad(plan.saturation),
            white_balance: pad(plan.white_balance),
            sensor_to_acescg_0: pad(plan.sensor_to_acescg[0]),
            sensor_to_acescg_1: pad(plan.sensor_to_acescg[1]),
            sensor_to_acescg_2: pad(plan.sensor_to_acescg[2]),
            rendering_intent: [0.0, 1.0, 1.0, 0.0],
            rendering_white_gains: [1.0, 1.0, 1.0, 0.0],
        };
        let count = raw.codes.len();
        let codes = self.shared_buffer(&raw.codes);
        let params = self.shared_buffer(core::slice::from_ref(&params));
        let green = self.device.new_buffer(
            (count * size_of::<f32>()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let output = self.device.new_buffer(
            (count * size_of::<[f32; 4]>()) as u64,
            MTLResourceOptions::StorageModeShared,
        );
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        encoder.set_buffer(0, Some(&codes), 0);
        encoder.set_buffer(1, Some(&green), 0);
        encoder.set_buffer(2, Some(&params), 0);
        Self::dispatch(encoder, &self.green_pipeline, count);
        encoder.memory_barrier_with_resources(&[&green]);
        encoder.set_buffer(0, Some(&codes), 0);
        encoder.set_buffer(1, Some(&green), 0);
        encoder.set_buffer(2, Some(&output), 0);
        encoder.set_buffer(3, Some(&params), 0);
        Self::dispatch(encoder, &self.develop_pipeline, count);
        encoder.end_encoding();
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(MetalNativeError(format!(
                "native Metal command ended with status {:?}",
                command.status()
            )));
        }
        // SAFETY: `output` is a shared Metal buffer allocated above for exactly `count` float4
        // values. The command buffer has completed, so the GPU no longer writes it, and the slice
        // is copied into owned Rust values before the Metal buffer is released.
        let gpu_pixels =
            unsafe { core::slice::from_raw_parts(output.contents().cast::<[f32; 4]>(), count) };
        let acescg = gpu_pixels
            .iter()
            .map(|pixel| LinearRgb::new(pixel[0], pixel[1], pixel[2]))
            .collect();
        Ok(DevelopedCameraRegion {
            sensor_width: raw.sensor_width,
            sensor_height: raw.sensor_height,
            region: raw.region,
            acescg,
        })
    }
}

impl fmt::Display for MetalNativeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for MetalNativeError {}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_camera::{CpuRawDevelopment, RawDevelopmentBackend};
    use screen_sensor::SensorRegion;

    fn raw_region(pattern: BayerPattern) -> (RawSensorRegion, SensorProfile, CameraDevelopment) {
        let sensor = SensorProfile {
            native_width: 12,
            native_height: 10,
            bayer_pattern: pattern,
            ..SensorProfile::REFERENCE
        };
        let region = SensorRegion {
            origin_x: 1,
            origin_y: 1,
            width: 8,
            height: 7,
        };
        let maximum = (1_u32 << sensor.adc_bits) - 1;
        let codes = (0..u32::from(region.width) * u32::from(region.height))
            .map(|index| ((index * 997 + 31) % maximum) as u16)
            .collect::<Vec<_>>();
        let count = codes.len();
        (
            RawSensorRegion {
                sensor_width: sensor.native_width,
                sensor_height: sensor.native_height,
                region,
                bayer_pattern: pattern,
                adc_bits: sensor.adc_bits,
                sensor_profile: sensor,
                codes,
                full_well_clipped: vec![false; count],
                adc_clipped: vec![false; count],
            },
            sensor,
            CameraDevelopment {
                white_balance: LinearRgb::new(2.0, 1.0, 0.55),
                middle_gray_illuminance_seconds: 0.037,
                develop_exposure_ev: 1.25,
            },
        )
    }

    #[test]
    fn metal_matches_cpu_oracle_for_all_cfa_phases_and_extreme_development() {
        let metal = MetalRawDevelopment::new().expect("Metal backend on supported Mac");
        for pattern in [
            BayerPattern::Rggb,
            BayerPattern::Bggr,
            BayerPattern::Grbg,
            BayerPattern::Gbrg,
        ] {
            let (raw, sensor, development) = raw_region(pattern);
            let cpu = CpuRawDevelopment
                .develop_region(&raw, sensor, development)
                .expect("CPU oracle");
            let gpu = metal
                .develop_region(&raw, sensor, development)
                .expect("Metal result");
            assert_eq!(gpu.region, cpu.region);
            assert_eq!(gpu.acescg.len(), cpu.acescg.len());
            let maximum_error = gpu
                .acescg
                .iter()
                .zip(&cpu.acescg)
                .flat_map(|(gpu, cpu)| {
                    [
                        (gpu.r - cpu.r).abs(),
                        (gpu.g - cpu.g).abs(),
                        (gpu.b - cpu.b).abs(),
                    ]
                })
                .fold(0.0_f32, f32::max);
            assert!(
                maximum_error <= 2.0e-5,
                "Metal/CPU maximum absolute error {maximum_error} exceeds 2e-5 for {pattern:?}"
            );
        }
    }
}
