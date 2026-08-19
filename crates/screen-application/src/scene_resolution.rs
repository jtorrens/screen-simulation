//! Sole host-neutral materialization of one scene at one exact rational time.
//!
//! Hosts may provide complete authored tracks, but only this module samples those tracks and
//! constructs a [`ResolvedSceneFrame`]. Downstream renderers consume this closed value and cannot
//! consult profiles, tracking assets or mutable host state.

use crate::{
    ActiveSensorWindow, FullSensorRaster, PhysicalPipelineSnapshot,
    ResolvedSceneGeometryLensSnapshot, SceneRevision,
};
use screen_contracts::{FrameRate, Meters, RationalTime, Vec3};
use screen_geometry::{
    CameraRig, CameraSample, GeometryError, ScreenSample, ScreenTrack, camera_forward,
};

#[derive(Clone, Debug, PartialEq)]
pub struct SceneFrameAuthoring {
    revision: SceneRevision,
    frame_rate: FrameRate,
    camera: CameraRig,
    screen: ScreenTrack,
    full_sensor: FullSensorRaster,
    pipeline: PhysicalPipelineSnapshot,
    focus: SceneFocusAuthoring,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SceneFocusAuthoring {
    Manual,
    DevicePoint {
        u: f32,
        v: f32,
        active_width: Meters,
        active_height: Meters,
    },
}

impl SceneFocusAuthoring {
    fn validate(self) -> Result<(), SceneFrameResolutionError> {
        match self {
            Self::Manual => Ok(()),
            Self::DevicePoint {
                u,
                v,
                active_width,
                active_height,
            } if u.is_finite()
                && v.is_finite()
                && (0.0..=1.0).contains(&u)
                && (0.0..=1.0).contains(&v)
                && active_width.0.is_finite()
                && active_width.0 > 0.0
                && active_height.0.is_finite()
                && active_height.0 > 0.0 =>
            {
                Ok(())
            }
            Self::DevicePoint { .. } => Err(SceneFrameResolutionError::InvalidFocusAuthoring),
        }
    }
}

impl SceneFrameAuthoring {
    pub fn new(
        revision: SceneRevision,
        frame_rate: FrameRate,
        camera: CameraRig,
        screen: ScreenTrack,
        full_sensor: FullSensorRaster,
        pipeline: PhysicalPipelineSnapshot,
        focus: SceneFocusAuthoring,
    ) -> Result<Self, SceneFrameResolutionError> {
        camera
            .validate()
            .map_err(SceneFrameResolutionError::Geometry)?;
        screen
            .validate()
            .map_err(SceneFrameResolutionError::Geometry)?;
        if u32::from(pipeline.sensor.native_width) != full_sensor.extent().width()
            || u32::from(pipeline.sensor.native_height) != full_sensor.extent().height()
        {
            return Err(SceneFrameResolutionError::SensorRasterMismatch);
        }
        focus.validate()?;
        Ok(Self {
            revision,
            frame_rate,
            camera,
            screen,
            full_sensor,
            pipeline,
            focus,
        })
    }
}

/// Immutable scene owner retained across frame requests.
#[derive(Clone, Debug, PartialEq)]
pub struct SceneFrameResolver {
    authoring: SceneFrameAuthoring,
}

impl SceneFrameResolver {
    pub const fn new(authoring: SceneFrameAuthoring) -> Self {
        Self { authoring }
    }

    pub fn resolve_frame(
        &self,
        frame_index: i64,
    ) -> Result<ResolvedSceneFrame, SceneFrameResolutionError> {
        let time = self
            .authoring
            .frame_rate
            .time_at_frame(frame_index)
            .map_err(|_| SceneFrameResolutionError::InvalidTime)?;
        self.resolve_at(frame_index, time)
    }

    pub fn resolve_at(
        &self,
        frame_index: i64,
        time: RationalTime,
    ) -> Result<ResolvedSceneFrame, SceneFrameResolutionError> {
        let mut camera = self
            .authoring
            .camera
            .sample(time)
            .map_err(SceneFrameResolutionError::Geometry)?;
        let screen = self
            .authoring
            .screen
            .sample(time)
            .map_err(SceneFrameResolutionError::Geometry)?;
        if let SceneFocusAuthoring::DevicePoint {
            u,
            v,
            active_width,
            active_height,
        } = self.authoring.focus
        {
            let target = screen.local_to_world(Vec3 {
                x: (u - 0.5) * active_width.0,
                y: (0.5 - v) * active_height.0,
                z: 0.0,
            });
            let forward = camera_forward(camera);
            let relative = Vec3 {
                x: target.x - camera.position.x,
                y: target.y - camera.position.y,
                z: target.z - camera.position.z,
            };
            let distance = relative.x * forward.x + relative.y * forward.y + relative.z * forward.z;
            if !distance.is_finite() || distance <= 0.0 {
                return Err(SceneFrameResolutionError::InvalidResolvedFocusDistance);
            }
            camera.focus_distance = Meters(distance);
        }
        let active_sensor = ActiveSensorWindow::centered_for_gate(
            self.authoring.full_sensor,
            f64::from(camera.sensor_width.0),
            f64::from(camera.sensor_height.0),
        )
        .map_err(|_| SceneFrameResolutionError::InvalidActiveSensorWindow)?;
        let mut pipeline = self.authoring.pipeline;
        pipeline.scene_geometry_lens = ResolvedSceneGeometryLensSnapshot {
            focal_length_millimeters: camera.focal_length.0,
            sensor_width_millimeters: camera.sensor_width.0,
            sensor_height_millimeters: camera.sensor_height.0,
            lens_shift: camera.lens_shift,
            focus_distance_meters: camera.focus_distance.0,
            f_stop: camera.f_stop,
            near_clip_meters: camera.near_clip.0,
            far_clip_meters: camera.far_clip.0,
            lens: camera.lens,
        };
        Ok(ResolvedSceneFrame {
            revision: self.authoring.revision,
            frame_rate: self.authoring.frame_rate,
            frame_index,
            time,
            camera,
            screen,
            active_sensor,
            pipeline,
        })
    }

    pub fn covers(&self, start: RationalTime, end: RationalTime) -> bool {
        fn track_covers(
            track: &screen_geometry::TransformTrack,
            start: RationalTime,
            end: RationalTime,
        ) -> bool {
            track.keyframes.len() == 1
                || track
                    .keyframes
                    .first()
                    .zip(track.keyframes.last())
                    .is_some_and(|(first, last)| first.time <= start && last.time >= end)
        }
        fn intrinsics_covers(
            track: &screen_geometry::CameraIntrinsicsTrack,
            start: RationalTime,
            end: RationalTime,
        ) -> bool {
            track.keyframes.len() == 1
                || track
                    .keyframes
                    .first()
                    .zip(track.keyframes.last())
                    .is_some_and(|(first, last)| first.time <= start && last.time >= end)
        }
        track_covers(&self.authoring.camera.transform, start, end)
            && intrinsics_covers(&self.authoring.camera.intrinsics, start, end)
            && track_covers(&self.authoring.screen, start, end)
    }

    pub fn is_temporally_varying(&self) -> bool {
        self.authoring.camera.transform.keyframes.len() > 1
            || self.authoring.camera.intrinsics.keyframes.len() > 1
            || self.authoring.screen.keyframes.len() > 1
    }
}

/// The only scene value accepted by downstream render preparation.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedSceneFrame {
    revision: SceneRevision,
    frame_rate: FrameRate,
    frame_index: i64,
    time: RationalTime,
    camera: CameraSample,
    screen: ScreenSample,
    active_sensor: ActiveSensorWindow,
    pipeline: PhysicalPipelineSnapshot,
}

impl ResolvedSceneFrame {
    pub const fn revision(self) -> SceneRevision {
        self.revision
    }

    pub const fn frame_rate(self) -> FrameRate {
        self.frame_rate
    }

    pub const fn frame_index(self) -> i64 {
        self.frame_index
    }

    pub const fn time(self) -> RationalTime {
        self.time
    }

    pub const fn camera(self) -> CameraSample {
        self.camera
    }

    pub const fn screen(self) -> ScreenSample {
        self.screen
    }

    pub const fn active_sensor(self) -> ActiveSensorWindow {
        self.active_sensor
    }

    pub const fn pipeline(self) -> PhysicalPipelineSnapshot {
        self.pipeline
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum SceneFrameResolutionError {
    InvalidTime,
    InvalidActiveSensorWindow,
    SensorRasterMismatch,
    InvalidFocusAuthoring,
    InvalidResolvedFocusDistance,
    Geometry(GeometryError),
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{CAPTURE_DEVICE_PRESETS, ResolvedShutterMotionSnapshot};
    use screen_camera::{CameraDevelopment, CameraRenderingIntent};
    use screen_contracts::{Meters, Millimeters, Vec2, Vec3};
    use screen_cover::{CoverGlassProfile, IncidentEnvironment};
    use screen_geometry::{
        CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, KeyframeInterpolation, LensModel,
        Quaternion, TransformKeyframe, TransformTrack,
    };
    use screen_panel::DEVICE_PRESETS;

    fn key_time(frame: i64) -> RationalTime {
        FrameRate::new(24, 1)
            .expect("fixture cadence")
            .time_at_frame(frame)
            .expect("fixture time")
    }

    fn transform_key(id: &str, frame: i64, x: f32) -> TransformKeyframe {
        TransformKeyframe {
            id: id.to_owned(),
            time: key_time(frame),
            translation: Vec3 { x, y: 0.0, z: 1.0 },
            rotation: Quaternion {
                x: 0.0,
                y: 0.0,
                z: 0.0,
                w: 1.0,
            },
            interpolation: KeyframeInterpolation::Linear,
        }
    }

    fn intrinsics_key(
        id: &str,
        frame: i64,
        focal_length: f32,
        gate_aspect: f32,
    ) -> CameraIntrinsicsKeyframe {
        CameraIntrinsicsKeyframe {
            id: id.to_owned(),
            time: key_time(frame),
            focal_length: Millimeters(focal_length),
            // Imported tracking gate: centered 16:9 window within the full ARRI sensor.
            sensor_width: Millimeters(27.99),
            sensor_height: Millimeters(27.99 / gate_aspect),
            lens_shift: Vec2 { x: 0.0, y: 0.0 },
            focus_distance: Meters(2.0),
            f_stop: 4.0,
            near_clip: Meters(0.01),
            far_clip: Meters(1_000.0),
            lens: LensModel::REFERENCE_PHOTOGRAPHIC,
            interpolation: KeyframeInterpolation::Linear,
        }
    }

    fn snapshot(width: u32, height: u32) -> PhysicalPipelineSnapshot {
        let camera = CAPTURE_DEVICE_PRESETS[0];
        let device = DEVICE_PRESETS[0];
        let mut sensor = camera.sensor;
        sensor.native_width = width
            .try_into()
            .expect("fixture width fits sensor contract");
        sensor.native_height = height
            .try_into()
            .expect("fixture height fits sensor contract");
        PhysicalPipelineSnapshot {
            panel: device.profile(),
            panel_uniformity: device.uniformity,
            panel_light_spread: device.light_spread,
            cover: CoverGlassProfile::NEUTRAL,
            environment: IncidentEnvironment::NONE,
            scene_geometry_lens: ResolvedSceneGeometryLensSnapshot::REFERENCE,
            shutter_motion: ResolvedShutterMotionSnapshot {
                temporal_samples: 1,
                neutral_density_stops: 0.0,
                noise_seed: 1,
            },
            computational_capture: camera.computational_capture,
            sensor,
            development: CameraDevelopment::NEUTRAL,
            rendering_intent: CameraRenderingIntent::NEUTRAL,
        }
    }

    pub(crate) fn resolver() -> SceneFrameResolver {
        resolver_for_sensor(4_608, 3_164, 16.0 / 9.0)
    }

    pub(crate) fn resolver_for_sensor(
        width: u32,
        height: u32,
        gate_aspect: f32,
    ) -> SceneFrameResolver {
        let frame_rate = FrameRate::new(24, 1).expect("fixture cadence");
        let camera = CameraRig {
            transform: TransformTrack {
                keyframes: vec![
                    transform_key("camera-0", 0, 0.0),
                    transform_key("camera-24", 24, 2.0),
                ],
            },
            intrinsics: CameraIntrinsicsTrack {
                keyframes: vec![
                    intrinsics_key("lens-0", 0, 40.0, gate_aspect),
                    intrinsics_key("lens-24", 24, 80.0, gate_aspect),
                ],
            },
        };
        let screen = ScreenTrack {
            keyframes: vec![
                transform_key("screen-0", 0, -1.0),
                transform_key("screen-24", 24, 1.0),
            ],
        };
        let full_sensor = FullSensorRaster::new(width, height).expect("fixture full sensor");
        SceneFrameResolver::new(
            SceneFrameAuthoring::new(
                SceneRevision::new(7),
                frame_rate,
                camera,
                screen,
                full_sensor,
                snapshot(width, height),
                SceneFocusAuthoring::Manual,
            )
            .expect("valid fixture authoring"),
        )
    }

    pub(crate) fn resolver_for_sensor_with_world_scale(
        width: u32,
        height: u32,
        gate_aspect: f32,
        scale: f32,
    ) -> SceneFrameResolver {
        let mut resolver = resolver_for_sensor(width, height, gate_aspect);
        for key in &mut resolver.authoring.camera.transform.keyframes {
            key.translation.x *= scale;
            key.translation.y *= scale;
            key.translation.z *= scale;
        }
        for key in &mut resolver.authoring.screen.keyframes {
            key.translation.x *= scale;
            key.translation.y *= scale;
            key.translation.z *= scale;
        }
        resolver
    }

    pub(crate) fn resolver_with_visible_device() -> SceneFrameResolver {
        let mut resolver = resolver_for_sensor(4_608, 3_164, 16.0 / 9.0);
        for key in &mut resolver.authoring.screen.keyframes {
            key.translation.z = 0.0;
        }
        resolver
    }

    #[test]
    fn one_exact_time_materializes_camera_screen_lens_and_active_sensor_together() {
        let resolved = resolver().resolve_frame(12).expect("resolved frame");

        assert_eq!(resolved.revision(), SceneRevision::new(7));
        assert_eq!(resolved.time(), key_time(12));
        assert!((resolved.camera().position.x - 1.0).abs() < 1.0e-6);
        assert!((resolved.screen().translation.x - 0.0).abs() < 1.0e-6);
        assert!((resolved.camera().focal_length.0 - 60.0).abs() < 1.0e-6);
        assert_eq!(resolved.active_sensor().origin_x(), 0);
        assert_eq!(resolved.active_sensor().origin_y(), 286);
        assert_eq!(resolved.active_sensor().extent().width(), 4_608);
        assert_eq!(resolved.active_sensor().extent().height(), 2_592);
        assert_eq!(
            resolved
                .pipeline()
                .scene_geometry_lens
                .focal_length_millimeters,
            resolved.camera().focal_length.0
        );
    }

    #[test]
    fn sensor_profile_must_describe_the_declared_full_sensor() {
        let mut mismatched = snapshot(4_608, 3_164);
        mismatched.sensor.native_width = 1_920;
        let result = SceneFrameAuthoring::new(
            SceneRevision::new(1),
            FrameRate::new(24, 1).expect("fixture cadence"),
            resolver().authoring.camera,
            resolver().authoring.screen,
            FullSensorRaster::new(4_608, 3_164).expect("fixture full sensor"),
            mismatched,
            SceneFocusAuthoring::Manual,
        );
        assert_eq!(result, Err(SceneFrameResolutionError::SensorRasterMismatch));
    }

    #[test]
    fn autofocus_is_resolved_after_sampling_the_animated_camera() {
        let mut resolver = resolver_with_visible_device();
        resolver.authoring.camera.transform.keyframes[0]
            .translation
            .z = 1.0;
        resolver.authoring.camera.transform.keyframes[1]
            .translation
            .z = 2.0;
        resolver.authoring.focus = SceneFocusAuthoring::DevicePoint {
            u: 0.5,
            v: 0.5,
            active_width: Meters(0.3),
            active_height: Meters(0.2),
        };

        let first = resolver.resolve_frame(0).expect("first autofocus frame");
        let last = resolver.resolve_frame(24).expect("last autofocus frame");
        assert!((first.camera().focus_distance.0 - 1.0).abs() < 1.0e-6);
        assert!((last.camera().focus_distance.0 - 2.0).abs() < 1.0e-6);
        assert_eq!(
            first.pipeline().scene_geometry_lens.focus_distance_meters,
            first.camera().focus_distance.0
        );
        assert_eq!(
            last.pipeline().scene_geometry_lens.focus_distance_meters,
            last.camera().focus_distance.0
        );
    }
}
