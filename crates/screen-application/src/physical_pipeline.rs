//! One typed, ordered contract for complete physical-frame evaluation.
//!
//! The structs in this module are Rust's semantic authority. The coarse C ABI
//! materializes these values once per job; Metal never defines stage ordering.

use crate::{RollingDirection, SensorReadout};
use screen_camera::CameraDevelopment;
use screen_contracts::{Meters, Millimeters, RationalTime, Vec2, Vec3};
use screen_cover::{CoverGlassProfile, ProceduralEnvironment};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, CameraSample, GeometryError,
    KeyframeInterpolation, LensModel, Quaternion, ScreenSample, TransformKeyframe, TransformTrack,
};
use screen_panel::{LcdProfile, PanelLightSpreadProfile};
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

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedSceneGeometryLensSnapshot {
    pub camera_position: Vec3,
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
}

impl ResolvedSceneGeometryLensSnapshot {
    pub const REFERENCE: Self = Self {
        camera_position: Vec3 {
            x: 0.0,
            y: 0.0,
            z: 1.0,
        },
        focal_length_millimeters: 50.0,
        sensor_width_millimeters: 36.0,
        sensor_height_millimeters: 24.0,
        lens_shift: Vec2 { x: 0.0, y: 0.0 },
        focus_distance_meters: 1.0,
        f_stop: 2.8,
        near_clip_meters: 0.01,
        far_clip_meters: 100.0,
        camera_rotation: Quaternion {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        },
        lens: LensModel::REFERENCE_PHOTOGRAPHIC,
        screen_translation: Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        },
        screen_rotation: Quaternion {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        },
    };

    /// Materializes the historical camera/screen domain without preset lookups.
    /// Position + quaternion are the sole pose authority; target/yaw are derived
    /// diagnostics in `CameraSample`, never competing request inputs.
    pub fn resolve(
        self,
        lens_character_strength: f32,
    ) -> Result<(CameraSample, ScreenSample), GeometryError> {
        let time = RationalTime::new(0, 1).expect("constant track time is valid");
        let lens = self
            .lens
            .with_character_strength(lens_character_strength)
            .ok_or(GeometryError::InvalidResolvedLens)?;
        let camera = CameraRig {
            transform: TransformTrack {
                keyframes: vec![TransformKeyframe {
                    id: "resolved-camera".to_owned(),
                    time,
                    translation: self.camera_position,
                    rotation: self.camera_rotation,
                    interpolation: KeyframeInterpolation::Hold,
                }],
            },
            intrinsics: CameraIntrinsicsTrack {
                keyframes: vec![CameraIntrinsicsKeyframe {
                    id: "resolved-intrinsics".to_owned(),
                    time,
                    focal_length: Millimeters(self.focal_length_millimeters),
                    sensor_width: Millimeters(self.sensor_width_millimeters),
                    sensor_height: Millimeters(self.sensor_height_millimeters),
                    lens_shift: self.lens_shift,
                    focus_distance: Meters(self.focus_distance_meters),
                    f_stop: self.f_stop,
                    near_clip: Meters(self.near_clip_meters),
                    far_clip: Meters(self.far_clip_meters),
                    lens,
                    interpolation: KeyframeInterpolation::Hold,
                }],
            },
        };
        let screen = TransformTrack {
            keyframes: vec![TransformKeyframe {
                id: "resolved-screen".to_owned(),
                time,
                translation: self.screen_translation,
                rotation: self.screen_rotation,
                interpolation: KeyframeInterpolation::Hold,
            }],
        };
        Ok((camera.sample(time)?, screen.sample(time)?))
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn resolved(rotation: Quaternion) -> ResolvedSceneGeometryLensSnapshot {
        ResolvedSceneGeometryLensSnapshot {
            camera_position: Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            },
            focal_length_millimeters: 50.0,
            sensor_width_millimeters: 36.0,
            sensor_height_millimeters: 24.0,
            lens_shift: Vec2 { x: 0.0, y: 0.0 },
            focus_distance_meters: 1.0,
            f_stop: 2.8,
            near_clip_meters: 0.01,
            far_clip_meters: 100.0,
            camera_rotation: rotation,
            lens: LensModel::REFERENCE_PHOTOGRAPHIC,
            screen_translation: Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            screen_rotation: Quaternion::from_yaw_degrees(0.0),
        }
    }

    #[test]
    fn identity_orientation_derives_one_consistent_implicit_target() {
        let (camera, screen) = resolved(Quaternion::from_yaw_degrees(0.0))
            .resolve(0.0)
            .expect("resolved identity camera");
        assert_eq!(camera.yaw_degrees.to_bits(), 0.0_f32.to_bits());
        assert_eq!(camera.target.x.to_bits(), camera.position.x.to_bits());
        assert_eq!(camera.target.y.to_bits(), camera.position.y.to_bits());
        assert!((camera.target.z - (camera.position.z - 1.0)).abs() <= 1.0e-7);
        assert_eq!(screen.translation.z.to_bits(), 0.0_f32.to_bits());
    }

    #[test]
    fn yaw_and_pitch_are_derived_only_from_the_quaternion() {
        let rotation = Quaternion::from_orbit_yaw_pitch_degrees(30.0, -12.0);
        let (camera, _) = resolved(rotation)
            .resolve(1.0)
            .expect("resolved yaw/pitch camera");
        let forward = Vec3 {
            x: camera.target.x - camera.position.x,
            y: camera.target.y - camera.position.y,
            z: camera.target.z - camera.position.z,
        };
        assert!((camera.yaw_degrees - 30.0).abs() <= 1.0e-4);
        let derived_pitch = -forward.y.asin().to_degrees();
        assert!((derived_pitch - (-12.0)).abs() <= 1.0e-4);
        assert!(
            (forward.x * forward.x + forward.y * forward.y + forward.z * forward.z - 1.0).abs()
                <= 1.0e-4
        );
    }
}
