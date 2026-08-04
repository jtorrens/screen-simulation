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
        let phase = (time.as_seconds() / self.orbit_duration.as_seconds()) as f32;
        let eased = 0.5 - 0.5 * (core::f32::consts::TAU * phase).cos();
        let yaw_degrees = self.orbit_amplitude_degrees * (eased * 2.0 - 1.0);
        let yaw = yaw_degrees.to_radians();
        CameraSample {
            position: Vec3 {
                x: self.distance.0 * yaw.sin(),
                y: 0.0,
                z: self.distance.0 * yaw.cos(),
            },
            yaw_degrees,
            focal_length: self.focal_length,
            sensor_width: self.sensor_width,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraSample {
    pub position: Vec3,
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
    let yaw = camera.yaw_degrees.to_radians();
    let facing_ratio = yaw.cos().abs();
    let angular_scale = camera.focal_length.0 / camera.sensor_width.0;
    let half_width = active_width.0 * 0.5 / camera.position.z * angular_scale * 2.0;
    let half_height =
        active_height.0 * 0.5 / camera.position.z * angular_scale * 2.0 * viewport_aspect;
    let perspective_skew = yaw.sin() * half_width * 0.18;
    ProjectedScreen {
        corners: [
            Vec2 {
                x: -half_width,
                y: -half_height - perspective_skew,
            },
            Vec2 {
                x: half_width,
                y: -half_height + perspective_skew,
            },
            Vec2 {
                x: half_width,
                y: half_height + perspective_skew,
            },
            Vec2 {
                x: -half_width,
                y: half_height - perspective_skew,
            },
        ],
        facing_ratio,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GeometryError {
    NonPositiveCameraDistance,
    NonPositiveIntrinsics,
    NonPositiveOrbitDuration,
}

impl fmt::Display for GeometryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::NonPositiveCameraDistance => "camera distance must be positive",
            Self::NonPositiveIntrinsics => "camera focal length and sensor width must be positive",
            Self::NonPositiveOrbitDuration => "camera orbit duration must be positive",
        })
    }
}

impl std::error::Error for GeometryError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn animation_is_exactly_sampled_from_rational_time() {
        let rig = CameraRig {
            distance: Meters(0.8),
            focal_length: Millimeters(50.0),
            sensor_width: Millimeters(36.0),
            orbit_amplitude_degrees: 18.0,
            orbit_duration: RationalTime::new(96, 24).expect("valid duration"),
        };
        let start = rig.sample(RationalTime::new(0, 24).expect("valid time"));
        let middle = rig.sample(RationalTime::new(48, 24).expect("valid time"));
        assert!((start.yaw_degrees + 18.0).abs() < 0.001);
        assert!((middle.yaw_degrees - 18.0).abs() < 0.001);
    }
}
