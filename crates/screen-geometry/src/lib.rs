//! Canonical camera/screen animation and physical projection ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{Meters, Millimeters, RationalTime, Vec2, Vec3};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyframeInterpolation {
    Hold,
    Linear,
    Smooth,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quaternion {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl Quaternion {
    pub fn from_yaw_degrees(yaw: f32) -> Self {
        let half = yaw.to_radians() * 0.5;
        Self {
            x: 0.0,
            y: half.sin(),
            z: 0.0,
            w: half.cos(),
        }
    }

    fn normalized(self) -> Self {
        let length = (self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w).sqrt();
        Self {
            x: self.x / length,
            y: self.y / length,
            z: self.z / length,
            w: self.w / length,
        }
    }

    fn rotate(self, value: Vec3) -> Vec3 {
        let q = Vec3 {
            x: self.x,
            y: self.y,
            z: self.z,
        };
        let t = scale(cross(q, value), 2.0);
        add(value, add(scale(t, self.w), cross(q, t)))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CameraKeyframe {
    pub id: String,
    pub time: RationalTime,
    pub position: Vec3,
    pub rotation: Quaternion,
    pub focal_length: Millimeters,
    pub sensor_width: Millimeters,
    pub interpolation: KeyframeInterpolation,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CameraTrack {
    pub keyframes: Vec<CameraKeyframe>,
}

impl CameraTrack {
    pub fn validate(&self) -> Result<(), GeometryError> {
        if self.keyframes.is_empty() {
            return Err(GeometryError::EmptyCameraTrack);
        }
        let mut prior: Option<&CameraKeyframe> = None;
        for key in &self.keyframes {
            if key.id.is_empty()
                || !key.position.x.is_finite()
                || !key.position.y.is_finite()
                || !key.position.z.is_finite()
            {
                return Err(GeometryError::InvalidCameraKeyframe);
            }
            let magnitude = key.rotation.x * key.rotation.x
                + key.rotation.y * key.rotation.y
                + key.rotation.z * key.rotation.z
                + key.rotation.w * key.rotation.w;
            if !magnitude.is_finite() || (magnitude - 1.0).abs() > 1.0e-4 {
                return Err(GeometryError::InvalidCameraRotation);
            }
            if key.focal_length.0 <= 0.0 || key.sensor_width.0 <= 0.0 {
                return Err(GeometryError::NonPositiveIntrinsics);
            }
            if let Some(previous) = prior
                && (previous.time >= key.time || previous.id == key.id)
            {
                return Err(GeometryError::UnorderedCameraKeyframes);
            }
            prior = Some(key);
        }
        Ok(())
    }

    pub fn sample(&self, time: RationalTime) -> Result<CameraSample, GeometryError> {
        self.validate()?;
        let right = self.keyframes.partition_point(|key| key.time <= time);
        if right == 0 {
            return Ok(sample_key(&self.keyframes[0]));
        }
        if right == self.keyframes.len() {
            return Ok(sample_key(&self.keyframes[right - 1]));
        }
        let left = &self.keyframes[right - 1];
        if left.interpolation == KeyframeInterpolation::Hold {
            return Ok(sample_key(left));
        }
        let next = &self.keyframes[right];
        let span = next.time.as_seconds() - left.time.as_seconds();
        let mut amount = ((time.as_seconds() - left.time.as_seconds()) / span) as f32;
        if left.interpolation == KeyframeInterpolation::Smooth {
            amount = amount * amount * (3.0 - 2.0 * amount);
        }
        let lerp = |a: f32, b: f32| a + (b - a) * amount;
        let rotation = Quaternion {
            x: lerp(left.rotation.x, next.rotation.x),
            y: lerp(left.rotation.y, next.rotation.y),
            z: lerp(left.rotation.z, next.rotation.z),
            w: lerp(left.rotation.w, next.rotation.w),
        }
        .normalized();
        Ok(camera_sample(
            Vec3 {
                x: lerp(left.position.x, next.position.x),
                y: lerp(left.position.y, next.position.y),
                z: lerp(left.position.z, next.position.z),
            },
            rotation,
            Millimeters(lerp(left.focal_length.0, next.focal_length.0)),
            Millimeters(lerp(left.sensor_width.0, next.sensor_width.0)),
        ))
    }

    pub fn fit_panel_region(
        &self,
        time: RationalTime,
        region: PanelRegion,
        active_width: Meters,
        active_height: Meters,
        viewport_aspect: f32,
    ) -> Result<CameraSample, GeometryError> {
        region.validate()?;
        let target = Vec2 {
            x: (region.min.x + region.max.x - 1.0) * active_width.0 * 0.5,
            y: (1.0 - region.min.y - region.max.y) * active_height.0 * 0.5,
        };
        let corners = region.scene_corners(active_width, active_height);
        let source = self.sample(time)?;
        let fits = |distance: Meters| {
            let sample = inspection_sample(source, target, distance);
            corners.iter().all(|point| {
                project_scene_point(sample, *point, viewport_aspect)
                    .is_some_and(|projected| projected.x.abs() <= 0.92 && projected.y.abs() <= 0.92)
            })
        };

        let forward = normalize(subtract(source.target, source.position));
        let mut upper = dot(scale(source.position, -1.0), forward).abs().max(0.001);
        for _ in 0..24 {
            if fits(Meters(upper)) {
                break;
            }
            upper *= 2.0;
        }
        if !fits(Meters(upper)) {
            return Err(GeometryError::InspectionRegionCannotBeFramed);
        }

        let mut lower = 0.000_1;
        for _ in 0..48 {
            let candidate = (lower + upper) * 0.5;
            if fits(Meters(candidate)) {
                upper = candidate;
            } else {
                lower = candidate;
            }
        }
        Ok(inspection_sample(source, target, Meters(upper)))
    }
}

fn sample_key(key: &CameraKeyframe) -> CameraSample {
    camera_sample(
        key.position,
        key.rotation,
        key.focal_length,
        key.sensor_width,
    )
}

fn camera_sample(
    position: Vec3,
    rotation: Quaternion,
    focal_length: Millimeters,
    sensor_width: Millimeters,
) -> CameraSample {
    let forward = rotation.rotate(Vec3 {
        x: 0.0,
        y: 0.0,
        z: -1.0,
    });
    CameraSample {
        position,
        target: add(position, forward),
        yaw_degrees: (2.0 * rotation.y.atan2(rotation.w)).to_degrees(),
        focal_length,
        sensor_width,
    }
}

fn inspection_sample(source: CameraSample, target: Vec2, distance: Meters) -> CameraSample {
    let forward = normalize(subtract(source.target, source.position));
    let target = Vec3 {
        x: target.x,
        y: target.y,
        z: 0.0,
    };
    CameraSample {
        position: subtract(target, scale(forward, distance.0)),
        target,
        ..source
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelRegion {
    pub min: Vec2,
    pub max: Vec2,
}

impl PanelRegion {
    pub fn validate(self) -> Result<Self, GeometryError> {
        if !self.min.x.is_finite()
            || !self.min.y.is_finite()
            || !self.max.x.is_finite()
            || !self.max.y.is_finite()
            || self.max.x <= self.min.x
            || self.max.y <= self.min.y
        {
            return Err(GeometryError::InvalidInspectionRegion);
        }
        Ok(self)
    }

    pub fn contains(self, uv: Vec2) -> bool {
        uv.x >= self.min.x && uv.x <= self.max.x && uv.y >= self.min.y && uv.y <= self.max.y
    }

    fn scene_corners(self, width: Meters, height: Meters) -> [Vec3; 4] {
        let point = |uv: Vec2| Vec3 {
            x: (uv.x - 0.5) * width.0,
            y: (0.5 - uv.y) * height.0,
            z: 0.0,
        };
        [
            point(self.min),
            point(Vec2 {
                x: self.max.x,
                y: self.min.y,
            }),
            point(self.max),
            point(Vec2 {
                x: self.min.x,
                y: self.max.y,
            }),
        ]
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraSample {
    pub position: Vec3,
    pub target: Vec3,
    pub yaw_degrees: f32,
    pub focal_length: Millimeters,
    pub sensor_width: Millimeters,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProjectedScreen {
    pub corners: [Vec2; 4],
    pub facing_ratio: f32,
}

pub fn project_screen(
    camera: CameraSample,
    active_width: Meters,
    active_height: Meters,
    viewport_aspect: f32,
) -> Option<ProjectedScreen> {
    let [top_left, top_right, bottom_right, bottom_left] = PanelRegion {
        min: Vec2 { x: 0.0, y: 0.0 },
        max: Vec2 { x: 1.0, y: 1.0 },
    }
    .scene_corners(active_width, active_height);
    Some(ProjectedScreen {
        corners: [
            project_scene_point(camera, top_left, viewport_aspect)?,
            project_scene_point(camera, top_right, viewport_aspect)?,
            project_scene_point(camera, bottom_right, viewport_aspect)?,
            project_scene_point(camera, bottom_left, viewport_aspect)?,
        ],
        facing_ratio: camera.yaw_degrees.to_radians().cos().abs(),
    })
}

pub fn project_scene_point(
    camera: CameraSample,
    point: Vec3,
    viewport_aspect: f32,
) -> Option<Vec2> {
    let (right, up, forward) = camera_basis(camera);
    let relative = subtract(point, camera.position);
    let depth = dot(relative, forward);
    if depth <= 0.0 {
        return None;
    }
    let focal = camera.focal_length.0;
    let sensor_height = camera.sensor_width.0 / viewport_aspect;
    Some(Vec2 {
        x: dot(relative, right) / depth * (2.0 * focal / camera.sensor_width.0),
        y: -dot(relative, up) / depth * (2.0 * focal / sensor_height),
    })
}

/// Intersects a viewport position in normalized device coordinates with the unbounded panel plane.
pub fn panel_uv_at_viewport(
    camera: CameraSample,
    active_width: Meters,
    active_height: Meters,
    viewport_aspect: f32,
    viewport_ndc: Vec2,
) -> Option<Vec2> {
    let (right, up, forward) = camera_basis(camera);
    let sensor_height = camera.sensor_width.0 / viewport_aspect;
    let ray = normalize(add(
        forward,
        add(
            scale(
                right,
                viewport_ndc.x * camera.sensor_width.0 / (2.0 * camera.focal_length.0),
            ),
            scale(
                up,
                -viewport_ndc.y * sensor_height / (2.0 * camera.focal_length.0),
            ),
        ),
    ));
    if ray.z.abs() < 1.0e-8 {
        return None;
    }
    let distance = -camera.position.z / ray.z;
    if distance <= 0.0 {
        return None;
    }
    let point = add(camera.position, scale(ray, distance));
    Some(Vec2 {
        x: point.x / active_width.0 + 0.5,
        y: 0.5 - point.y / active_height.0,
    })
}

fn camera_basis(camera: CameraSample) -> (Vec3, Vec3, Vec3) {
    let forward = normalize(subtract(camera.target, camera.position));
    let up = Vec3 {
        x: 0.0,
        y: 1.0,
        z: 0.0,
    };
    let right = normalize(cross(forward, up));
    (right, up, forward)
}

fn add(left: Vec3, right: Vec3) -> Vec3 {
    Vec3 {
        x: left.x + right.x,
        y: left.y + right.y,
        z: left.z + right.z,
    }
}

fn subtract(left: Vec3, right: Vec3) -> Vec3 {
    Vec3 {
        x: left.x - right.x,
        y: left.y - right.y,
        z: left.z - right.z,
    }
}

fn scale(value: Vec3, factor: f32) -> Vec3 {
    Vec3 {
        x: value.x * factor,
        y: value.y * factor,
        z: value.z * factor,
    }
}

fn dot(left: Vec3, right: Vec3) -> f32 {
    left.x * right.x + left.y * right.y + left.z * right.z
}

fn cross(left: Vec3, right: Vec3) -> Vec3 {
    Vec3 {
        x: left.y * right.z - left.z * right.y,
        y: left.z * right.x - left.x * right.z,
        z: left.x * right.y - left.y * right.x,
    }
}

fn normalize(value: Vec3) -> Vec3 {
    let length = dot(value, value).sqrt();
    scale(value, 1.0 / length)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GeometryError {
    EmptyCameraTrack,
    InvalidCameraKeyframe,
    InvalidCameraRotation,
    UnorderedCameraKeyframes,
    NonPositiveIntrinsics,
    InvalidInspectionRegion,
    InspectionRegionCannotBeFramed,
}

impl fmt::Display for GeometryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::EmptyCameraTrack => "camera track requires at least one keyframe",
            Self::InvalidCameraKeyframe => "camera keyframe is invalid",
            Self::InvalidCameraRotation => "camera keyframe quaternion must be normalized",
            Self::UnorderedCameraKeyframes => {
                "camera keyframes must have unique ids and increasing times"
            }
            Self::NonPositiveIntrinsics => "camera focal length and sensor width must be positive",
            Self::InvalidInspectionRegion => "inspection region must have finite positive area",
            Self::InspectionRegionCannotBeFramed => {
                "inspection camera cannot frame the selected region"
            }
        })
    }
}

impl std::error::Error for GeometryError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn rig() -> CameraTrack {
        let key = |id: &str, frame, yaw: f32| CameraKeyframe {
            id: id.to_owned(),
            time: RationalTime::new(frame, 24).expect("valid time"),
            position: Vec3 {
                x: 0.8 * yaw.to_radians().sin(),
                y: 0.0,
                z: 0.8 * yaw.to_radians().cos(),
            },
            rotation: Quaternion::from_yaw_degrees(yaw),
            focal_length: Millimeters(50.0),
            sensor_width: Millimeters(36.0),
            interpolation: KeyframeInterpolation::Smooth,
        };
        CameraTrack {
            keyframes: vec![key("start", 0, -18.0), key("middle", 48, 18.0)],
        }
    }

    #[test]
    fn animation_is_exactly_sampled_from_rational_time() {
        let start = rig()
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("sample");
        let middle = rig()
            .sample(RationalTime::new(48, 24).expect("valid time"))
            .expect("sample");
        assert!((start.yaw_degrees + 18.0).abs() < 0.001);
        assert!((middle.yaw_degrees - 18.0).abs() < 0.001);
    }

    #[test]
    fn viewport_ray_round_trips_through_panel_plane() {
        let camera = rig()
            .sample(RationalTime::new(24, 24).expect("valid time"))
            .expect("sample");
        let width = Meters(0.6);
        let height = Meters(0.34);
        let point = Vec3 {
            x: 0.12,
            y: -0.06,
            z: 0.0,
        };
        let projected = project_scene_point(camera, point, 16.0 / 9.0).expect("visible point");
        let uv = panel_uv_at_viewport(camera, width, height, 16.0 / 9.0, projected)
            .expect("panel intersection");
        assert!((uv.x - 0.7).abs() < 0.000_1);
        assert!((uv.y - 0.676_470_6).abs() < 0.000_1);
    }

    #[test]
    fn inspection_camera_physically_frames_selected_region() {
        let region = PanelRegion {
            min: Vec2 { x: 0.49, y: 0.48 },
            max: Vec2 { x: 0.51, y: 0.52 },
        };
        let camera = rig()
            .fit_panel_region(
                RationalTime::new(24, 24).expect("valid time"),
                region,
                Meters(0.6),
                Meters(0.34),
                16.0 / 9.0,
            )
            .expect("region can be framed");
        assert!(camera.position.z < 0.1);
        assert!(camera.target.x.abs() < 0.001);
    }
}
