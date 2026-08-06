//! One typed, ordered contract for complete physical-frame evaluation.
//!
//! The structs in this module are Rust's semantic authority. The coarse C ABI
//! materializes these values once per job; Metal never defines stage ordering.

use crate::{DeviceSignalRaster, RasterPlacement, RollingDirection, SensorReadout};
use screen_camera::CameraDevelopment;
use screen_contracts::{RationalTime, Vec2, Vec3};
use screen_cover::{CoverGlassProfile, ProceduralEnvironment};
use screen_geometry::{LensModel, Quaternion};
use screen_panel::{FlatPanelQuality, LcdProfile, PanelLightSpreadProfile};
use screen_sensor::SensorProfile;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum PhysicalStage {
    PanelEmission = 0x101,
    SubpixelGeometry = 0x102,
    PanelLightSpread = 0x103,
    PanelTemporal = 0x104,
    CoverGlass = 0x105,
    Environment = 0x106,
    SceneGeometry = 0x201,
    Lens = 0x202,
    ShutterMotion = 0x203,
    SensorCfa = 0x204,
    SensorNoise = 0x205,
    RawDevelop = 0x206,
}

pub const PHYSICAL_STAGE_ORDER: [PhysicalStage; 12] = [
    PhysicalStage::PanelEmission,
    PhysicalStage::SubpixelGeometry,
    PhysicalStage::PanelLightSpread,
    PhysicalStage::PanelTemporal,
    PhysicalStage::CoverGlass,
    PhysicalStage::Environment,
    PhysicalStage::SceneGeometry,
    PhysicalStage::Lens,
    PhysicalStage::ShutterMotion,
    PhysicalStage::SensorCfa,
    PhysicalStage::SensorNoise,
    PhysicalStage::RawDevelop,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum PhysicalIntermediate {
    SourceAcesCg = 0,
    DeviceSignal = 1,
    PanelEmission = 2,
    SubpixelRadiance = 3,
    PanelLightSpread = 4,
    CoverEnvironment = 5,
    SceneGeometryLens = 6,
    ShutterMotion = 7,
    SensorNoise = 8,
    RawMosaic = 9,
    DevelopedAcesCg = 10,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalStageControl {
    pub stage: PhysicalStage,
    pub amount: f32,
    pub enabled: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SourceAcesCgRaster {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<[f32; 4]>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicalPipelineInput {
    pub source_acescg: SourceAcesCgRaster,
    pub device_signal: DeviceSignalRaster,
    pub placement: RasterPlacement,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedSceneGeometryLensSnapshot {
    pub camera_position: Vec3,
    pub camera_target: Vec3,
    pub camera_yaw_degrees: f32,
    pub focal_length_millimeters: f32,
    pub sensor_width_millimeters: f32,
    pub sensor_height_millimeters: f32,
    pub lens_shift: Vec2,
    pub focus_distance_meters: f32,
    pub f_stop: f32,
    pub near_clip_meters: f32,
    pub far_clip_meters: f32,
    pub camera_rotation: Quaternion,
    pub lens: LensModel,
    pub screen_translation: Vec3,
    pub screen_rotation: Quaternion,
    pub screen_scale: Vec2,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedShutterMotionSnapshot {
    pub exposure_duration: RationalTime,
    pub temporal_samples: u16,
    pub readout: SensorReadout,
    pub neutral_density_stops: f32,
    pub noise_seed: u64,
}

impl ResolvedShutterMotionSnapshot {
    pub fn rolling(
        exposure_duration: RationalTime,
        temporal_samples: u16,
        readout_duration: RationalTime,
        direction: RollingDirection,
        neutral_density_stops: f32,
        noise_seed: u64,
    ) -> Self {
        Self {
            exposure_duration,
            temporal_samples,
            readout: SensorReadout::Rolling {
                duration: readout_duration,
                direction,
            },
            neutral_density_stops,
            noise_seed,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalPipelineSnapshot {
    pub panel: LcdProfile,
    pub panel_light_spread: PanelLightSpreadProfile,
    pub cover: CoverGlassProfile,
    pub environment: ProceduralEnvironment,
    pub scene_geometry_lens: ResolvedSceneGeometryLensSnapshot,
    pub shutter_motion: ResolvedShutterMotionSnapshot,
    pub sensor: SensorProfile,
    pub development: CameraDevelopment,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicalPipelineRequest {
    pub frame_index: i64,
    pub frame_time: RationalTime,
    pub input: PhysicalPipelineInput,
    pub snapshot: PhysicalPipelineSnapshot,
    pub quality: FlatPanelQuality,
    pub requested_width: u32,
    pub requested_height: u32,
    pub screen_amount: f32,
    pub capture_amount: f32,
    pub stages: [PhysicalStageControl; PHYSICAL_STAGE_ORDER.len()],
    pub requested_intermediate: PhysicalIntermediate,
}

impl PhysicalPipelineRequest {
    pub fn stage(&self, stage: PhysicalStage) -> PhysicalStageControl {
        let index = PHYSICAL_STAGE_ORDER
            .iter()
            .position(|candidate| *candidate == stage)
            .expect("every typed physical stage belongs to the fixed order");
        self.stages[index]
    }
}
