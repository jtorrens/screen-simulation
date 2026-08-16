//! One typed, ordered contract for complete physical-frame evaluation.
//!
//! The structs in this module are Rust's semantic authority. The coarse C ABI
//! materializes these values once per job; Metal never defines stage ordering.

use crate::{RollingDirection, SensorReadout};
use screen_camera::{CameraDevelopment, CameraRenderingIntent};
use screen_contracts::{Meters, Millimeters, RationalTime, Vec2, Vec3};
use screen_cover::{CoverGlassProfile, IncidentEnvironment};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, CameraSample, GeometryError,
    KeyframeInterpolation, LensModel, Quaternion, ScreenSample, TransformKeyframe, TransformTrack,
};
use screen_panel::{LcdProfile, PanelLightSpreadProfile, PanelUniformityProfile};
use screen_sensor::{ComputationalCaptureProfile, SensorProfile};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum PhysicalStage {
    PanelEmission = 0x101,
    SubpixelGeometry = 0x102,
    PanelUniformity = 0x108,
    PanelLightSpread = 0x103,
    PanelTemporal = 0x104,
    CoverGlass = 0x105,
    Environment = 0x106,
    CoverGlow = 0x107,
    SceneGeometry = 0x201,
    Lens = 0x202,
    ShutterMotion = 0x203,
    SensorCollection = 0x204,
    SensorReadout = 0x205,
    RawDevelop = 0x206,
    SensorBloom = 0x207,
    ComputationalCapture = 0x208,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum PhysicalDomain {
    Screen = 0x100,
    Capture = 0x200,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum PhysicalStageControlSemantics {
    Continuous = 0,
    Discrete = 1,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalStageDescriptor {
    pub stage: PhysicalStage,
    pub domain: PhysicalDomain,
    pub control_semantics: PhysicalStageControlSemantics,
    pub visual_minimum: f32,
    pub visual_maximum: f32,
    pub safe_maximum: f32,
    pub exact_identity_at_zero: bool,
    pub general_overview: bool,
}

const fn continuous_stage(
    stage: PhysicalStage,
    domain: PhysicalDomain,
    visual_maximum: f32,
    safe_maximum: f32,
    general_overview: bool,
) -> PhysicalStageDescriptor {
    PhysicalStageDescriptor {
        stage,
        domain,
        control_semantics: PhysicalStageControlSemantics::Continuous,
        visual_minimum: 0.0,
        visual_maximum,
        safe_maximum,
        exact_identity_at_zero: true,
        general_overview,
    }
}

const fn discrete_stage(stage: PhysicalStage, domain: PhysicalDomain) -> PhysicalStageDescriptor {
    PhysicalStageDescriptor {
        stage,
        domain,
        control_semantics: PhysicalStageControlSemantics::Discrete,
        visual_minimum: 0.0,
        visual_maximum: 0.0,
        safe_maximum: 0.0,
        exact_identity_at_zero: false,
        general_overview: false,
    }
}

pub const PHYSICAL_STAGE_DESCRIPTORS: [PhysicalStageDescriptor; 16] = [
    continuous_stage(
        PhysicalStage::PanelEmission,
        PhysicalDomain::Screen,
        2.0,
        4.0,
        false,
    ),
    continuous_stage(
        PhysicalStage::SubpixelGeometry,
        PhysicalDomain::Screen,
        2.0,
        4.0,
        false,
    ),
    continuous_stage(
        PhysicalStage::PanelUniformity,
        PhysicalDomain::Screen,
        2.0,
        4.0,
        false,
    ),
    continuous_stage(
        PhysicalStage::PanelLightSpread,
        PhysicalDomain::Screen,
        2.0,
        4.0,
        false,
    ),
    continuous_stage(
        PhysicalStage::PanelTemporal,
        PhysicalDomain::Screen,
        2.0,
        4.0,
        true,
    ),
    continuous_stage(
        PhysicalStage::SceneGeometry,
        PhysicalDomain::Capture,
        2.0,
        4.0,
        false,
    ),
    continuous_stage(
        PhysicalStage::CoverGlass,
        PhysicalDomain::Screen,
        2.0,
        2.0,
        true,
    ),
    continuous_stage(
        PhysicalStage::Environment,
        PhysicalDomain::Screen,
        2.0,
        4.0,
        true,
    ),
    continuous_stage(
        PhysicalStage::CoverGlow,
        PhysicalDomain::Screen,
        2.0,
        4.0,
        true,
    ),
    continuous_stage(PhysicalStage::Lens, PhysicalDomain::Capture, 2.0, 4.0, true),
    continuous_stage(
        PhysicalStage::ShutterMotion,
        PhysicalDomain::Capture,
        2.0,
        4.0,
        true,
    ),
    continuous_stage(
        PhysicalStage::ComputationalCapture,
        PhysicalDomain::Capture,
        1.5,
        1.5,
        true,
    ),
    continuous_stage(
        PhysicalStage::SensorCollection,
        PhysicalDomain::Capture,
        2.0,
        4.0,
        true,
    ),
    continuous_stage(
        PhysicalStage::SensorBloom,
        PhysicalDomain::Capture,
        2.0,
        4.0,
        true,
    ),
    discrete_stage(PhysicalStage::SensorReadout, PhysicalDomain::Capture),
    discrete_stage(PhysicalStage::RawDevelop, PhysicalDomain::Capture),
];

pub const PHYSICAL_STAGE_ORDER: [PhysicalStage; 16] = [
    PHYSICAL_STAGE_DESCRIPTORS[0].stage,
    PHYSICAL_STAGE_DESCRIPTORS[1].stage,
    PHYSICAL_STAGE_DESCRIPTORS[2].stage,
    PHYSICAL_STAGE_DESCRIPTORS[3].stage,
    PHYSICAL_STAGE_DESCRIPTORS[4].stage,
    PHYSICAL_STAGE_DESCRIPTORS[5].stage,
    PHYSICAL_STAGE_DESCRIPTORS[6].stage,
    PHYSICAL_STAGE_DESCRIPTORS[7].stage,
    PHYSICAL_STAGE_DESCRIPTORS[8].stage,
    PHYSICAL_STAGE_DESCRIPTORS[9].stage,
    PHYSICAL_STAGE_DESCRIPTORS[10].stage,
    PHYSICAL_STAGE_DESCRIPTORS[11].stage,
    PHYSICAL_STAGE_DESCRIPTORS[12].stage,
    PHYSICAL_STAGE_DESCRIPTORS[13].stage,
    PHYSICAL_STAGE_DESCRIPTORS[14].stage,
    PHYSICAL_STAGE_DESCRIPTORS[15].stage,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum PhysicalIntermediate {
    SourceAcesCg = 0,
    DeviceSignal = 1,
    PanelEmission = 2,
    SubpixelRadiance = 3,
    PanelUniformity = 4,
    PanelLightSpread = 5,
    RelativeGeometry = 6,
    CoverEnvironment = 7,
    CoverGlow = 8,
    LensProjection = 9,
    ShutterMotion = 10,
    ComputationalCapture = 11,
    SensorCollection = 12,
    SensorBloom = 13,
    SensorReadoutRaw = 14,
    DevelopedAcesCg = 15,
    CameraRenderedAcesCg = 16,
    /// Temporally integrated panel radiance. Appended rather than inserted in
    /// the numeric ABI so existing stable intermediate identities do not move.
    PanelTemporal = 17,
}

impl TryFrom<u32> for PhysicalIntermediate {
    type Error = ();

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::SourceAcesCg),
            1 => Ok(Self::DeviceSignal),
            2 => Ok(Self::PanelEmission),
            3 => Ok(Self::SubpixelRadiance),
            4 => Ok(Self::PanelUniformity),
            5 => Ok(Self::PanelLightSpread),
            6 => Ok(Self::RelativeGeometry),
            7 => Ok(Self::CoverEnvironment),
            8 => Ok(Self::CoverGlow),
            9 => Ok(Self::LensProjection),
            10 => Ok(Self::ShutterMotion),
            11 => Ok(Self::ComputationalCapture),
            12 => Ok(Self::SensorCollection),
            13 => Ok(Self::SensorBloom),
            14 => Ok(Self::SensorReadoutRaw),
            15 => Ok(Self::DevelopedAcesCg),
            16 => Ok(Self::CameraRenderedAcesCg),
            17 => Ok(Self::PanelTemporal),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalStageControl {
    pub stage: PhysicalStage,
    pub amount: f32,
    pub enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedPhysicalStageContributions {
    pub emission: f32,
    pub subpixel_geometry: f32,
    pub panel_uniformity: f32,
    pub panel_light_spread: f32,
    pub temporal_emission: f32,
    pub scene_geometry: f32,
    pub cover: f32,
    pub environment: f32,
    pub cover_glow: f32,
    pub lens: f32,
    pub shutter_motion: f32,
    pub computational_capture: f32,
    pub sensor_collection: f32,
    pub sensor_bloom: f32,
    pub sensor_readout_enabled: bool,
    pub raw_develop_enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicalStageContributionError {
    WrongCount,
    WrongOrder,
    InvalidContinuousValue,
    InvalidDiscreteValue,
    CaptureStageRequiresSensorReadout,
}

pub fn resolve_physical_stage_contributions(
    controls: &[PhysicalStageControl],
) -> Result<ResolvedPhysicalStageContributions, PhysicalStageContributionError> {
    if controls.len() != PHYSICAL_STAGE_DESCRIPTORS.len() {
        return Err(PhysicalStageContributionError::WrongCount);
    }
    for (control, descriptor) in controls.iter().zip(PHYSICAL_STAGE_DESCRIPTORS) {
        if control.stage != descriptor.stage {
            return Err(PhysicalStageContributionError::WrongOrder);
        }
        match descriptor.control_semantics {
            PhysicalStageControlSemantics::Continuous => {
                if control.enabled
                    || !control.amount.is_finite()
                    || !(descriptor.visual_minimum..=descriptor.safe_maximum)
                        .contains(&control.amount)
                {
                    return Err(PhysicalStageContributionError::InvalidContinuousValue);
                }
            }
            PhysicalStageControlSemantics::Discrete => {
                if control.amount != 0.0 {
                    return Err(PhysicalStageContributionError::InvalidDiscreteValue);
                }
            }
        }
    }
    let resolved = ResolvedPhysicalStageContributions {
        emission: controls[0].amount,
        subpixel_geometry: controls[1].amount,
        panel_uniformity: controls[2].amount,
        panel_light_spread: controls[3].amount,
        temporal_emission: controls[4].amount,
        scene_geometry: controls[5].amount,
        cover: controls[6].amount,
        environment: controls[7].amount,
        cover_glow: controls[8].amount,
        lens: controls[9].amount,
        shutter_motion: controls[10].amount,
        computational_capture: controls[11].amount,
        sensor_collection: controls[12].amount,
        sensor_bloom: controls[13].amount,
        sensor_readout_enabled: controls[14].enabled,
        raw_develop_enabled: controls[15].enabled,
    };
    if (resolved.sensor_collection != 0.0
        || resolved.sensor_bloom != 0.0
        || resolved.raw_develop_enabled)
        && !resolved.sensor_readout_enabled
    {
        return Err(PhysicalStageContributionError::CaptureStageRequiresSensorReadout);
    }
    Ok(resolved)
}

#[derive(Clone, Debug, PartialEq)]
pub struct SourceAcesCgRaster {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<[f32; 4]>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedSceneGeometryLensSnapshot {
    pub focal_length_millimeters: f32,
    pub sensor_width_millimeters: f32,
    pub sensor_height_millimeters: f32,
    pub lens_shift: Vec2,
    pub focus_distance_meters: f32,
    pub f_stop: f32,
    pub near_clip_meters: f32,
    pub far_clip_meters: f32,
    pub lens: LensModel,
}

impl ResolvedSceneGeometryLensSnapshot {
    pub const REFERENCE: Self = Self {
        focal_length_millimeters: 50.0,
        sensor_width_millimeters: 36.0,
        sensor_height_millimeters: 24.0,
        lens_shift: Vec2 { x: 0.0, y: 0.0 },
        focus_distance_meters: 1.0,
        f_stop: 2.8,
        near_clip_meters: 0.01,
        far_clip_meters: 100.0,
        lens: LensModel::REFERENCE_PHOTOGRAPHIC,
    };

    /// Materializes the historical camera/screen domain without preset lookups.
    /// Position + quaternion are the sole pose authority; target/yaw are derived
    /// diagnostics in `CameraSample`, never competing request inputs.
    pub fn resolve(
        self,
        camera_position: Vec3,
        camera_rotation: Quaternion,
        screen_translation: Vec3,
        screen_rotation: Quaternion,
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
                    translation: camera_position,
                    rotation: camera_rotation,
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
                translation: screen_translation,
                rotation: screen_rotation,
                interpolation: KeyframeInterpolation::Hold,
            }],
        };
        Ok((camera.sample(time)?, screen.sample(time)?))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedShutterMotionSnapshot {
    pub temporal_samples: u16,
    pub readout: SensorReadout,
    pub neutral_density_stops: f32,
    pub noise_seed: u64,
}

impl ResolvedShutterMotionSnapshot {
    pub fn rolling(
        temporal_samples: u16,
        readout_duration: RationalTime,
        direction: RollingDirection,
        neutral_density_stops: f32,
        noise_seed: u64,
    ) -> Self {
        Self {
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
    pub panel_uniformity: PanelUniformityProfile,
    pub panel_light_spread: PanelLightSpreadProfile,
    pub cover: CoverGlassProfile,
    pub environment: IncidentEnvironment,
    pub scene_geometry_lens: ResolvedSceneGeometryLensSnapshot,
    pub shutter_motion: ResolvedShutterMotionSnapshot,
    pub computational_capture: ComputationalCaptureProfile,
    pub sensor: SensorProfile,
    pub development: CameraDevelopment,
    pub rendering_intent: CameraRenderingIntent,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_stage_controls() -> Vec<PhysicalStageControl> {
        PHYSICAL_STAGE_DESCRIPTORS
            .iter()
            .map(|descriptor| PhysicalStageControl {
                stage: descriptor.stage,
                amount: if descriptor.control_semantics == PhysicalStageControlSemantics::Continuous
                {
                    1.0
                } else {
                    0.0
                },
                enabled: descriptor.control_semantics == PhysicalStageControlSemantics::Discrete,
            })
            .collect()
    }

    #[test]
    fn application_alone_resolves_ordered_stage_contributions_and_dependencies() {
        let controls = valid_stage_controls();
        let resolved = resolve_physical_stage_contributions(&controls).expect("valid controls");
        assert_eq!(resolved.panel_uniformity, 1.0);
        assert!(resolved.sensor_readout_enabled);
        assert!(resolved.raw_develop_enabled);

        let mut reordered = controls.clone();
        reordered.swap(0, 1);
        assert_eq!(
            resolve_physical_stage_contributions(&reordered),
            Err(PhysicalStageContributionError::WrongOrder)
        );

        let mut invalid_dependency = controls;
        invalid_dependency[14].enabled = false;
        assert_eq!(
            resolve_physical_stage_contributions(&invalid_dependency),
            Err(PhysicalStageContributionError::CaptureStageRequiresSensorReadout)
        );
    }

    fn resolved() -> ResolvedSceneGeometryLensSnapshot {
        ResolvedSceneGeometryLensSnapshot {
            focal_length_millimeters: 50.0,
            sensor_width_millimeters: 36.0,
            sensor_height_millimeters: 24.0,
            lens_shift: Vec2 { x: 0.0, y: 0.0 },
            focus_distance_meters: 1.0,
            f_stop: 2.8,
            near_clip_meters: 0.01,
            far_clip_meters: 100.0,
            lens: LensModel::REFERENCE_PHOTOGRAPHIC,
        }
    }

    #[test]
    fn identity_orientation_derives_one_consistent_implicit_target() {
        let (camera, screen) = resolved()
            .resolve(
                Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 1.0,
                },
                Quaternion::from_yaw_degrees(0.0),
                Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
                Quaternion::from_yaw_degrees(0.0),
                0.0,
            )
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
        let (camera, _) = resolved()
            .resolve(
                Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 1.0,
                },
                rotation,
                Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
                Quaternion::from_yaw_degrees(0.0),
                1.0,
            )
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
