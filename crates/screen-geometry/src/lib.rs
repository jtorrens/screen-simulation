//! Canonical camera/screen animation and physical projection ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{Meters, Millimeters, RationalTime, Vec2, Vec3};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraRig {
    pub distance: Meters,
    pub focal_length: Millimeters,
    pub sensor_width: Millimeters,
    pub orbit_amplitude_degrees: f32,
    pub orbit_duration: RationalTime,
}

impl CameraRig {
    pub fn validate(self) -> Result<Self, GeometryError> {
        if self.distance.0 <= 0.0 {
            return Err(GeometryError::NonPositiveCameraDistance);
        }
        if self.focal_length.0 <= 0.0 || self.sensor_width.0 <= 0.0 {
            return Err(GeometryError::NonPositiveIntrinsics);
        }
        if self.orbit_duration.numerator() <= 0 {
            return Err(GeometryError::NonPositiveOrbitDuration);
        }
        Ok(self)
    }

    pub fn sample(self, time: RationalTime) -> CameraSample {
        self.sample_at(time, Vec2 { x: 0.0, y: 0.0 }, self.distance)
    }

    pub fn fit_panel_region(
        self,
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
        let fits = |distance: Meters| {
            let sample = self.sample_at(time, target, distance);
            corners.iter().all(|point| {
                project_scene_point(sample, *point, viewport_aspect)
                    .is_some_and(|projected| projected.x.abs() <= 0.92 && projected.y.abs() <= 0.92)
            })
        };

        let mut upper = self.distance.0.max(0.001);
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
        Ok(self.sample_at(time, target, Meters(upper)))
    }

    fn sample_at(self, time: RationalTime, target: Vec2, distance: Meters) -> CameraSample {
        let phase = (time.as_seconds() / self.orbit_duration.as_seconds()) as f32;
        let eased = 0.5 - 0.5 * (core::f32::consts::TAU * phase).cos();
        let yaw_degrees = self.orbit_amplitude_degrees * (eased * 2.0 - 1.0);
        let yaw = yaw_degrees.to_radians();
        CameraSample {
            position: Vec3 {
                x: target.x + distance.0 * yaw.sin(),
                y: target.y,
                z: distance.0 * yaw.cos(),
            },
            target: Vec3 {
                x: target.x,
                y: target.y,
                z: 0.0,
            },
            yaw_degrees,
            focal_length: self.focal_length,
            sensor_width: self.sensor_width,
        }
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
) -> ProjectedScreen {
    let corners = PanelRegion {
        min: Vec2 { x: 0.0, y: 0.0 },
        max: Vec2 { x: 1.0, y: 1.0 },
    }
    .scene_corners(active_width, active_height)
    .map(|point| {
        project_scene_point(camera, point, viewport_aspect)
            .expect("a validated frontal camera projects the screen plane")
    });
    ProjectedScreen {
        corners,
        facing_ratio: camera.yaw_degrees.to_radians().cos().abs(),
    }
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
    NonPositiveCameraDistance,
    NonPositiveIntrinsics,
    NonPositiveOrbitDuration,
    InvalidInspectionRegion,
    InspectionRegionCannotBeFramed,
}

impl fmt::Display for GeometryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::NonPositiveCameraDistance => "camera distance must be positive",
            Self::NonPositiveIntrinsics => "camera focal length and sensor width must be positive",
            Self::NonPositiveOrbitDuration => "camera orbit duration must be positive",
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

    fn rig() -> CameraRig {
        CameraRig {
            distance: Meters(0.8),
            focal_length: Millimeters(50.0),
            sensor_width: Millimeters(36.0),
            orbit_amplitude_degrees: 18.0,
            orbit_duration: RationalTime::new(96, 24).expect("valid duration"),
        }
    }

    #[test]
    fn animation_is_exactly_sampled_from_rational_time() {
        let start = rig().sample(RationalTime::new(0, 24).expect("valid time"));
        let middle = rig().sample(RationalTime::new(48, 24).expect("valid time"));
        assert!((start.yaw_degrees + 18.0).abs() < 0.001);
        assert!((middle.yaw_degrees - 18.0).abs() < 0.001);
    }

    #[test]
    fn viewport_ray_round_trips_through_panel_plane() {
        let camera = rig().sample(RationalTime::new(24, 24).expect("valid time"));
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
