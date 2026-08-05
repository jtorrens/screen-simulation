//! Canonical camera/screen animation and physical projection ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::{Meters, Millimeters, RationalTime, Vec2, Vec3};
use std::collections::HashSet;
use std::sync::OnceLock;

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

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LensModel {
    pub radial_distortion: [f32; 3],
    pub tangential_distortion: [f32; 2],
    pub longitudinal_chromatic_meters: [f32; 3],
    pub lateral_chromatic_scale: [f32; 3],
    pub vignetting_strength: f32,
    pub transmission_rgb: [f32; 3],
}

impl LensModel {
    pub const REFERENCE_PHOTOGRAPHIC: Self = Self {
        radial_distortion: [-0.035, 0.008, 0.0],
        tangential_distortion: [0.000_4, -0.000_3],
        longitudinal_chromatic_meters: [0.001_2, 0.0, -0.001_5],
        lateral_chromatic_scale: [1.000_8, 1.0, 0.999_1],
        vignetting_strength: 0.65,
        transmission_rgb: [0.92, 0.94, 0.95],
    };
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LensPresetAuthority {
    GenericApproximation,
    CalibratedApproximation,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LensPreset {
    pub id: &'static str,
    pub label: &'static str,
    pub authority: LensPresetAuthority,
    pub nominal_focal_length: Millimeters,
    pub lens: LensModel,
}

pub const LENS_PRESETS: &[LensPreset] = &[
    LensPreset {
        id: "generic-prime-18mm",
        label: "Generic prime · 18 mm",
        authority: LensPresetAuthority::GenericApproximation,
        nominal_focal_length: Millimeters(18.0),
        lens: LensModel {
            radial_distortion: [-0.12, 0.035, -0.004],
            tangential_distortion: [0.000_7, -0.000_5],
            longitudinal_chromatic_meters: [0.001_8, 0.0, -0.002_2],
            lateral_chromatic_scale: [1.001_5, 1.0, 0.998_3],
            vignetting_strength: 0.9,
            transmission_rgb: [0.88, 0.9, 0.91],
        },
    },
    LensPreset {
        id: "generic-prime-25mm",
        label: "Generic prime · 25 mm",
        authority: LensPresetAuthority::GenericApproximation,
        nominal_focal_length: Millimeters(25.0),
        lens: LensModel {
            radial_distortion: [-0.08, 0.022, -0.002],
            tangential_distortion: [0.000_6, -0.000_4],
            longitudinal_chromatic_meters: [0.001_5, 0.0, -0.001_9],
            lateral_chromatic_scale: [1.001_2, 1.0, 0.998_7],
            vignetting_strength: 0.82,
            transmission_rgb: [0.9, 0.92, 0.93],
        },
    },
    LensPreset {
        id: "generic-prime-35mm",
        label: "Generic prime · 35 mm",
        authority: LensPresetAuthority::GenericApproximation,
        nominal_focal_length: Millimeters(35.0),
        lens: LensModel {
            radial_distortion: [-0.045, 0.011, -0.000_5],
            tangential_distortion: [0.000_45, -0.000_3],
            longitudinal_chromatic_meters: [0.001_3, 0.0, -0.001_6],
            lateral_chromatic_scale: [1.000_9, 1.0, 0.999],
            vignetting_strength: 0.72,
            transmission_rgb: [0.92, 0.94, 0.95],
        },
    },
    LensPreset {
        id: "generic-prime-50mm",
        label: "Generic prime · 50 mm",
        authority: LensPresetAuthority::GenericApproximation,
        nominal_focal_length: Millimeters(50.0),
        lens: LensModel::REFERENCE_PHOTOGRAPHIC,
    },
    LensPreset {
        id: "generic-prime-85mm",
        label: "Generic prime · 85 mm",
        authority: LensPresetAuthority::GenericApproximation,
        nominal_focal_length: Millimeters(85.0),
        lens: LensModel {
            radial_distortion: [0.012, -0.004, 0.000_5],
            tangential_distortion: [0.000_25, -0.000_2],
            longitudinal_chromatic_meters: [0.000_9, 0.0, -0.001_1],
            lateral_chromatic_scale: [1.000_55, 1.0, 0.999_4],
            vignetting_strength: 0.52,
            transmission_rgb: [0.93, 0.95, 0.96],
        },
    },
    LensPreset {
        id: "generic-prime-135mm",
        label: "Generic prime · 135 mm",
        authority: LensPresetAuthority::GenericApproximation,
        nominal_focal_length: Millimeters(135.0),
        lens: LensModel {
            radial_distortion: [0.018, -0.006, 0.001],
            tangential_distortion: [0.000_2, -0.000_15],
            longitudinal_chromatic_meters: [0.000_75, 0.0, -0.000_9],
            lateral_chromatic_scale: [1.000_4, 1.0, 0.999_55],
            vignetting_strength: 0.45,
            transmission_rgb: [0.93, 0.95, 0.96],
        },
    },
    LensPreset {
        id: "iphone-16e-main-integrated",
        label: "iPhone 16e main · integrated",
        authority: LensPresetAuthority::CalibratedApproximation,
        nominal_focal_length: Millimeters(4.2),
        lens: LensModel {
            radial_distortion: [-0.14, 0.045, -0.006],
            tangential_distortion: [0.000_8, -0.000_6],
            longitudinal_chromatic_meters: [0.000_16, 0.0, -0.000_2],
            lateral_chromatic_scale: [1.001_8, 1.0, 0.998],
            vignetting_strength: 0.88,
            transmission_rgb: [0.86, 0.89, 0.9],
        },
    },
];

pub fn lens_preset(id: &str) -> Option<LensPreset> {
    LENS_PRESETS.iter().copied().find(|preset| preset.id == id)
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

    pub fn from_orbit_yaw_pitch_degrees(yaw: f32, pitch: f32) -> Self {
        let yaw_half = yaw.to_radians() * 0.5;
        let pitch_half = pitch.to_radians() * 0.5;
        let yaw_sine = yaw_half.sin();
        let yaw_cosine = yaw_half.cos();
        let pitch_sine = pitch_half.sin();
        let pitch_cosine = pitch_half.cos();
        Self {
            x: -yaw_cosine * pitch_sine,
            y: yaw_sine * pitch_cosine,
            z: yaw_sine * pitch_sine,
            w: yaw_cosine * pitch_cosine,
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

    fn inverse_rotate(self, value: Vec3) -> Vec3 {
        Quaternion {
            x: -self.x,
            y: -self.y,
            z: -self.z,
            w: self.w,
        }
        .rotate(value)
    }

    fn slerp(self, mut other: Self, amount: f32) -> Self {
        let mut cosine = self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w;
        if cosine < 0.0 {
            cosine = -cosine;
            other = Self {
                x: -other.x,
                y: -other.y,
                z: -other.z,
                w: -other.w,
            };
        }
        if cosine > 0.999_5 {
            return Self {
                x: self.x + (other.x - self.x) * amount,
                y: self.y + (other.y - self.y) * amount,
                z: self.z + (other.z - self.z) * amount,
                w: self.w + (other.w - self.w) * amount,
            }
            .normalized();
        }
        let angle = cosine.clamp(-1.0, 1.0).acos();
        let denominator = angle.sin();
        let left = ((1.0 - amount) * angle).sin() / denominator;
        let right = (amount * angle).sin() / denominator;
        Self {
            x: self.x * left + other.x * right,
            y: self.y * left + other.y * right,
            z: self.z * left + other.z * right,
            w: self.w * left + other.w * right,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TransformKeyframe {
    pub id: String,
    pub time: RationalTime,
    pub translation: Vec3,
    pub rotation: Quaternion,
    pub interpolation: KeyframeInterpolation,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TransformTrack {
    pub keyframes: Vec<TransformKeyframe>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransformSample {
    pub translation: Vec3,
    pub rotation: Quaternion,
}

pub type ScreenTrack = TransformTrack;
pub type ScreenSample = TransformSample;

impl TransformSample {
    pub const IDENTITY: Self = Self {
        translation: Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        },
        rotation: Quaternion {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        },
    };

    pub fn local_to_world(self, point: Vec3) -> Vec3 {
        add(self.translation, self.rotation.rotate(point))
    }

    fn world_to_local_point(self, point: Vec3) -> Vec3 {
        self.rotation
            .inverse_rotate(subtract(point, self.translation))
    }

    fn world_to_local_vector(self, vector: Vec3) -> Vec3 {
        self.rotation.inverse_rotate(vector)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CameraIntrinsicsKeyframe {
    pub id: String,
    pub time: RationalTime,
    pub focal_length: Millimeters,
    pub sensor_width: Millimeters,
    pub sensor_height: Millimeters,
    pub lens_shift: Vec2,
    pub focus_distance: Meters,
    pub f_stop: f32,
    pub near_clip: Meters,
    pub far_clip: Meters,
    pub lens: LensModel,
    pub interpolation: KeyframeInterpolation,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CameraIntrinsicsTrack {
    pub keyframes: Vec<CameraIntrinsicsKeyframe>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CameraRig {
    pub transform: TransformTrack,
    pub intrinsics: CameraIntrinsicsTrack,
}

impl TransformTrack {
    pub fn validate(&self) -> Result<(), GeometryError> {
        if self.keyframes.is_empty() {
            return Err(GeometryError::EmptyTransformTrack);
        }
        let mut ids = HashSet::new();
        let mut prior_time = None;
        for key in &self.keyframes {
            if key.id.is_empty()
                || !ids.insert(key.id.as_str())
                || !key.translation.x.is_finite()
                || !key.translation.y.is_finite()
                || !key.translation.z.is_finite()
            {
                return Err(GeometryError::InvalidTransformKeyframe);
            }
            let magnitude = key.rotation.x * key.rotation.x
                + key.rotation.y * key.rotation.y
                + key.rotation.z * key.rotation.z
                + key.rotation.w * key.rotation.w;
            if !magnitude.is_finite() || (magnitude - 1.0).abs() > 1.0e-4 {
                return Err(GeometryError::InvalidCameraRotation);
            }
            if prior_time.is_some_and(|previous| previous >= key.time) {
                return Err(GeometryError::UnorderedTransformKeyframes);
            }
            prior_time = Some(key.time);
        }
        Ok(())
    }

    pub fn sample(&self, time: RationalTime) -> Result<TransformSample, GeometryError> {
        self.validate()?;
        let right = self.keyframes.partition_point(|key| key.time <= time);
        if right == 0 {
            return Ok(transform_sample(&self.keyframes[0]));
        }
        if right == self.keyframes.len() {
            return Ok(transform_sample(&self.keyframes[right - 1]));
        }
        let left = &self.keyframes[right - 1];
        if left.interpolation == KeyframeInterpolation::Hold {
            return Ok(transform_sample(left));
        }
        let next = &self.keyframes[right];
        let span = next.time.as_seconds() - left.time.as_seconds();
        let mut amount = ((time.as_seconds() - left.time.as_seconds()) / span) as f32;
        if left.interpolation == KeyframeInterpolation::Smooth {
            amount = amount * amount * (3.0 - 2.0 * amount);
        }
        let lerp = |a: f32, b: f32| a + (b - a) * amount;
        let rotation = left.rotation.slerp(next.rotation, amount);
        Ok(TransformSample {
            translation: Vec3 {
                x: lerp(left.translation.x, next.translation.x),
                y: lerp(left.translation.y, next.translation.y),
                z: lerp(left.translation.z, next.translation.z),
            },
            rotation,
        })
    }
}

impl CameraIntrinsicsTrack {
    pub fn validate(&self) -> Result<(), GeometryError> {
        if self.keyframes.is_empty() {
            return Err(GeometryError::EmptyCameraIntrinsicsTrack);
        }
        let mut ids = HashSet::new();
        let mut prior_time = None;
        for key in &self.keyframes {
            let scalars = [
                key.focal_length.0,
                key.sensor_width.0,
                key.sensor_height.0,
                key.lens_shift.x,
                key.lens_shift.y,
                key.focus_distance.0,
                key.f_stop,
                key.near_clip.0,
                key.far_clip.0,
            ];
            if key.id.is_empty()
                || !ids.insert(key.id.as_str())
                || scalars.into_iter().any(|v| !v.is_finite())
            {
                return Err(GeometryError::InvalidCameraIntrinsicsKeyframe);
            }
            if key.focal_length.0 <= 0.0
                || key.sensor_width.0 <= 0.0
                || key.sensor_height.0 <= 0.0
                || key.focus_distance.0 <= 0.0
                || key.f_stop <= 0.0
                || key.near_clip.0 <= 0.0
                || key.far_clip.0 <= key.near_clip.0
                || key.lens_shift.x.abs() > 0.5
                || key.lens_shift.y.abs() > 0.5
                || !lens_is_valid_for_gate(key.lens, key.lens_shift)
                || key
                    .lens
                    .longitudinal_chromatic_meters
                    .into_iter()
                    .any(|offset| key.focus_distance.0 + offset <= 0.0)
            {
                return Err(GeometryError::NonPositiveIntrinsics);
            }
            if prior_time.is_some_and(|previous| previous >= key.time) {
                return Err(GeometryError::UnorderedCameraIntrinsicsKeyframes);
            }
            prior_time = Some(key.time);
        }
        Ok(())
    }

    fn sample(&self, time: RationalTime) -> Result<ResolvedOptics, GeometryError> {
        self.validate()?;
        let right = self.keyframes.partition_point(|key| key.time <= time);
        if right == 0 {
            return Ok(resolved_optics(&self.keyframes[0]));
        }
        if right == self.keyframes.len() {
            return Ok(resolved_optics(&self.keyframes[right - 1]));
        }
        let left = &self.keyframes[right - 1];
        if left.interpolation == KeyframeInterpolation::Hold {
            return Ok(resolved_optics(left));
        }
        let next = &self.keyframes[right];
        let span = next.time.as_seconds() - left.time.as_seconds();
        let mut amount = ((time.as_seconds() - left.time.as_seconds()) / span) as f32;
        if left.interpolation == KeyframeInterpolation::Smooth {
            amount = amount * amount * (3.0 - 2.0 * amount);
        }
        let lerp = |a: f32, b: f32| a + (b - a) * amount;
        let optics = ResolvedOptics {
            focal_length: Millimeters(lerp(left.focal_length.0, next.focal_length.0)),
            sensor_width: Millimeters(lerp(left.sensor_width.0, next.sensor_width.0)),
            sensor_height: Millimeters(lerp(left.sensor_height.0, next.sensor_height.0)),
            lens_shift: Vec2 {
                x: lerp(left.lens_shift.x, next.lens_shift.x),
                y: lerp(left.lens_shift.y, next.lens_shift.y),
            },
            focus_distance: Meters(lerp(left.focus_distance.0, next.focus_distance.0)),
            f_stop: lerp(left.f_stop, next.f_stop),
            near_clip: Meters(lerp(left.near_clip.0, next.near_clip.0)),
            far_clip: Meters(lerp(left.far_clip.0, next.far_clip.0)),
            lens: interpolate_lens(left.lens, next.lens, &lerp),
        };
        if !lens_is_valid_for_gate(optics.lens, optics.lens_shift) {
            return Err(GeometryError::InvalidResolvedLens);
        }
        Ok(optics)
    }
}

impl CameraRig {
    pub fn validate(&self) -> Result<(), GeometryError> {
        self.transform.validate()?;
        self.intrinsics.validate()
    }

    pub fn sample(&self, time: RationalTime) -> Result<CameraSample, GeometryError> {
        let pose = self.transform.sample(time)?;
        Ok(camera_sample(
            pose.translation,
            pose.rotation,
            self.intrinsics.sample(time)?,
        ))
    }

    pub fn fit_panel_region(
        &self,
        time: RationalTime,
        region: PanelRegion,
        active_width: Meters,
        active_height: Meters,
        screen: ScreenSample,
        viewport_aspect: f32,
    ) -> Result<CameraSample, GeometryError> {
        region.validate()?;
        let target = screen.local_to_world(Vec3 {
            x: (region.min.x + region.max.x - 1.0) * active_width.0 * 0.5,
            y: (1.0 - region.min.y - region.max.y) * active_height.0 * 0.5,
            z: 0.0,
        });
        let corners = region
            .local_corners(active_width, active_height)
            .map(|point| screen.local_to_world(point));
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

fn transform_sample(key: &TransformKeyframe) -> TransformSample {
    TransformSample {
        translation: key.translation,
        rotation: key.rotation,
    }
}

fn resolved_optics(key: &CameraIntrinsicsKeyframe) -> ResolvedOptics {
    ResolvedOptics {
        focal_length: key.focal_length,
        sensor_width: key.sensor_width,
        sensor_height: key.sensor_height,
        lens_shift: key.lens_shift,
        focus_distance: key.focus_distance,
        f_stop: key.f_stop,
        near_clip: key.near_clip,
        far_clip: key.far_clip,
        lens: key.lens,
    }
}

#[derive(Clone, Copy)]
struct ResolvedOptics {
    focal_length: Millimeters,
    sensor_width: Millimeters,
    sensor_height: Millimeters,
    lens_shift: Vec2,
    focus_distance: Meters,
    f_stop: f32,
    near_clip: Meters,
    far_clip: Meters,
    lens: LensModel,
}

fn camera_sample(position: Vec3, rotation: Quaternion, optics: ResolvedOptics) -> CameraSample {
    let forward = rotation.rotate(Vec3 {
        x: 0.0,
        y: 0.0,
        z: -1.0,
    });
    let right = rotation.rotate(Vec3 {
        x: 1.0,
        y: 0.0,
        z: 0.0,
    });
    let up = rotation.rotate(Vec3 {
        x: 0.0,
        y: 1.0,
        z: 0.0,
    });
    let world_to_view = [
        right.x,
        right.y,
        right.z,
        -dot(right, position),
        up.x,
        up.y,
        up.z,
        -dot(up, position),
        forward.x,
        forward.y,
        forward.z,
        -dot(forward, position),
        0.0,
        0.0,
        0.0,
        1.0,
    ];
    let sx = 2.0 * optics.focal_length.0 / optics.sensor_width.0;
    let sy = 2.0 * optics.focal_length.0 / optics.sensor_height.0;
    let near = optics.near_clip.0;
    let far = optics.far_clip.0;
    let ideal_view_to_clip = [
        sx,
        0.0,
        0.0,
        0.0,
        0.0,
        sy,
        0.0,
        0.0,
        0.0,
        0.0,
        (far + near) / (far - near),
        -2.0 * far * near / (far - near),
        0.0,
        0.0,
        1.0,
        0.0,
    ];
    CameraSample {
        position,
        target: add(position, forward),
        yaw_degrees: (2.0 * rotation.y.atan2(rotation.w)).to_degrees(),
        focal_length: optics.focal_length,
        sensor_width: optics.sensor_width,
        sensor_height: optics.sensor_height,
        lens_shift: optics.lens_shift,
        focus_distance: optics.focus_distance,
        f_stop: optics.f_stop,
        near_clip: optics.near_clip,
        far_clip: optics.far_clip,
        lens: optics.lens,
        rotation,
        world_to_view,
        ideal_view_to_clip,
    }
}

fn inspection_sample(source: CameraSample, target: Vec3, distance: Meters) -> CameraSample {
    let forward = normalize(subtract(source.target, source.position));
    camera_sample(
        subtract(target, scale(forward, distance.0)),
        source.rotation,
        ResolvedOptics {
            focal_length: source.focal_length,
            sensor_width: source.sensor_width,
            sensor_height: source.sensor_height,
            lens_shift: source.lens_shift,
            focus_distance: distance,
            f_stop: source.f_stop,
            near_clip: source.near_clip,
            far_clip: source.far_clip,
            lens: source.lens,
        },
    )
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

    fn local_corners(self, width: Meters, height: Meters) -> [Vec3; 4] {
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
#[non_exhaustive]
pub struct CameraSample {
    pub position: Vec3,
    pub target: Vec3,
    pub yaw_degrees: f32,
    pub focal_length: Millimeters,
    pub sensor_width: Millimeters,
    pub sensor_height: Millimeters,
    pub lens_shift: Vec2,
    pub focus_distance: Meters,
    pub f_stop: f32,
    pub near_clip: Meters,
    pub far_clip: Meters,
    pub rotation: Quaternion,
    pub lens: LensModel,
    /// Row-major world-to-view matrix; +Z is forward in canonical view space.
    pub world_to_view: [f32; 16],
    /// Row-major ideal pinhole view-to-clip matrix before lens distortion and shift.
    pub ideal_view_to_clip: [f32; 16],
}

fn lens_is_valid_for_gate(lens: LensModel, lens_shift: Vec2) -> bool {
    lens.radial_distortion
        .into_iter()
        .chain(lens.tangential_distortion)
        .chain(lens.longitudinal_chromatic_meters)
        .chain(lens.lateral_chromatic_scale)
        .chain([lens.vignetting_strength])
        .chain(lens.transmission_rgb)
        .all(f32::is_finite)
        && (0.0..=1.0).contains(&lens.vignetting_strength)
        && lens
            .lateral_chromatic_scale
            .into_iter()
            .all(|value| (0.5..=1.5).contains(&value))
        && lens
            .transmission_rgb
            .into_iter()
            .all(|value| (0.0..=1.0).contains(&value))
        && distortion_is_certified_family(lens)
        && distortion_is_invertible(lens, lens_shift)
}

fn distortion_is_certified_family(lens: LensModel) -> bool {
    (-0.25..=0.08).contains(&lens.radial_distortion[0])
        && (-0.1..=0.15).contains(&lens.radial_distortion[1])
        && (-0.05..=0.05).contains(&lens.radial_distortion[2])
        && lens
            .tangential_distortion
            .into_iter()
            .all(|coefficient| (-0.01..=0.01).contains(&coefficient))
}

fn interpolate_lens(
    left: LensModel,
    right: LensModel,
    lerp: &impl Fn(f32, f32) -> f32,
) -> LensModel {
    let array3 =
        |left: [f32; 3], right: [f32; 3]| core::array::from_fn(|i| lerp(left[i], right[i]));
    let array2 =
        |left: [f32; 2], right: [f32; 2]| core::array::from_fn(|i| lerp(left[i], right[i]));
    LensModel {
        radial_distortion: array3(left.radial_distortion, right.radial_distortion),
        tangential_distortion: array2(left.tangential_distortion, right.tangential_distortion),
        longitudinal_chromatic_meters: array3(
            left.longitudinal_chromatic_meters,
            right.longitudinal_chromatic_meters,
        ),
        lateral_chromatic_scale: array3(
            left.lateral_chromatic_scale,
            right.lateral_chromatic_scale,
        ),
        vignetting_strength: lerp(left.vignetting_strength, right.vignetting_strength),
        transmission_rgb: array3(left.transmission_rgb, right.transmission_rgb),
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProjectedScreen {
    pub corners: [Vec2; 4],
    pub facing_ratio: f32,
}

pub fn project_screen(
    camera: CameraSample,
    screen: ScreenSample,
    active_width: Meters,
    active_height: Meters,
    viewport_aspect: f32,
) -> Option<ProjectedScreen> {
    let [top_left, top_right, bottom_right, bottom_left] = PanelRegion {
        min: Vec2 { x: 0.0, y: 0.0 },
        max: Vec2 { x: 1.0, y: 1.0 },
    }
    .local_corners(active_width, active_height)
    .map(|point| screen.local_to_world(point));
    Some(ProjectedScreen {
        corners: [
            project_scene_point(camera, top_left, viewport_aspect)?,
            project_scene_point(camera, top_right, viewport_aspect)?,
            project_scene_point(camera, bottom_right, viewport_aspect)?,
            project_scene_point(camera, bottom_left, viewport_aspect)?,
        ],
        facing_ratio: {
            let normal = screen.rotation.rotate(Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            });
            let to_camera = normalize(subtract(camera.position, screen.translation));
            dot(normal, to_camera).max(0.0)
        },
    })
}

pub fn project_scene_point(
    camera: CameraSample,
    point: Vec3,
    _viewport_aspect: f32,
) -> Option<Vec2> {
    let (right, up, forward) = camera_basis(camera);
    let relative = subtract(point, camera.position);
    let depth = dot(relative, forward);
    if depth < camera.near_clip.0 || depth > camera.far_clip.0 {
        return None;
    }
    let focal = camera.focal_length.0;
    let green_scale = camera.lens.lateral_chromatic_scale[1];
    let ideal = Vec2 {
        x: dot(relative, right) / depth * (2.0 * focal / camera.sensor_width.0) / green_scale,
        y: dot(relative, up) / depth * (2.0 * focal / camera.sensor_height.0) / green_scale,
    };
    let observed = distort(ideal, camera.lens);
    Some(Vec2 {
        x: observed.x - 2.0 * camera.lens_shift.x,
        y: -observed.y - 2.0 * camera.lens_shift.y,
    })
}

/// Intersects a viewport position in normalized device coordinates with the unbounded panel plane.
pub fn panel_uv_at_viewport(
    camera: CameraSample,
    screen: ScreenSample,
    active_width: Meters,
    active_height: Meters,
    _viewport_aspect: f32,
    viewport_ndc: Vec2,
) -> Option<Vec2> {
    let ideal = inverse_distortion(
        Vec2 {
            x: viewport_ndc.x + 2.0 * camera.lens_shift.x,
            y: -viewport_ndc.y - 2.0 * camera.lens_shift.y,
        },
        camera.lens,
    )?;
    panel_uv_for_lens_sample(
        camera,
        screen,
        active_width,
        active_height,
        ideal,
        Vec2 { x: 0.0, y: 0.0 },
        1,
    )
    .map(|hit| hit.0)
}

pub const APERTURE_SAMPLE_COUNT: usize = 16;
pub const MAX_APERTURE_SAMPLE_COUNT: usize = 128;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OpticalSample {
    pub panel_uv: [Option<Vec2>; 3],
    pub emission_cosine: [f32; 3],
    pub irradiance_weight: [f32; 3],
}

pub fn panel_uv_aperture_samples(
    camera: CameraSample,
    screen: ScreenSample,
    active_width: Meters,
    active_height: Meters,
    viewport_ndc: Vec2,
) -> [OpticalSample; APERTURE_SAMPLE_COUNT] {
    panel_uv_aperture_samples_with_count::<APERTURE_SAMPLE_COUNT>(
        camera,
        screen,
        active_width,
        active_height,
        viewport_ndc,
    )
}

/// Traces one of the supported nested aperture sample sets. The first N points are
/// identical at every quality level, so changing quality cannot move existing rays.
pub fn panel_uv_aperture_samples_with_count<const SAMPLE_COUNT: usize>(
    camera: CameraSample,
    screen: ScreenSample,
    active_width: Meters,
    active_height: Meters,
    viewport_ndc: Vec2,
) -> [OpticalSample; SAMPLE_COUNT] {
    assert!(matches!(SAMPLE_COUNT, 16 | 32 | 64 | 128));
    let disk = aperture_disk_samples();
    let Some(ideal) = inverse_distortion(
        Vec2 {
            x: viewport_ndc.x + 2.0 * camera.lens_shift.x,
            y: -viewport_ndc.y - 2.0 * camera.lens_shift.y,
        },
        camera.lens,
    ) else {
        return [OpticalSample {
            panel_uv: [None; 3],
            emission_cosine: [0.0; 3],
            irradiance_weight: [0.0; 3],
        }; SAMPLE_COUNT];
    };
    core::array::from_fn(|sample_index| {
        let lens_sample = disk[sample_index];
        let hits = core::array::from_fn(|channel| {
            panel_uv_for_lens_sample(
                camera,
                screen,
                active_width,
                active_height,
                ideal,
                lens_sample,
                channel,
            )
        });
        let aperture_throughput = core::f32::consts::FRAC_PI_4 / (camera.f_stop * camera.f_stop);
        OpticalSample {
            panel_uv: hits.map(|hit| hit.map(|value| value.0)),
            emission_cosine: hits.map(|hit| hit.map_or(0.0, |value| value.1)),
            irradiance_weight: core::array::from_fn(|channel| {
                let scale = camera.lens.lateral_chromatic_scale[channel];
                let tangent_x =
                    ideal.x * scale * camera.sensor_width.0 / (2.0 * camera.focal_length.0);
                let tangent_y =
                    ideal.y * scale * camera.sensor_height.0 / (2.0 * camera.focal_length.0);
                let cosine = 1.0 / (1.0 + tangent_x * tangent_x + tangent_y * tangent_y).sqrt();
                let natural = cosine.powi(4);
                let vignette = 1.0 + (natural - 1.0) * camera.lens.vignetting_strength;
                aperture_throughput * vignette * camera.lens.transmission_rgb[channel]
            }),
        }
    })
}

fn aperture_disk_samples() -> &'static [Vec2; MAX_APERTURE_SAMPLE_COUNT] {
    static SAMPLES: OnceLock<[Vec2; MAX_APERTURE_SAMPLE_COUNT]> = OnceLock::new();
    SAMPLES.get_or_init(|| {
        const GOLDEN_ANGLE: f32 = 2.399_963_1;
        core::array::from_fn(|index| {
            let radius = radical_inverse_base_two(index as u32 + 1).sqrt();
            let angle = index as f32 * GOLDEN_ANGLE;
            let (sin, cos) = angle.sin_cos();
            Vec2 {
                x: radius * cos,
                y: radius * sin,
            }
        })
    })
}

fn radical_inverse_base_two(mut value: u32) -> f32 {
    value = value.reverse_bits();
    value as f32 * (1.0 / 4_294_967_296.0)
}

fn panel_uv_for_lens_sample(
    camera: CameraSample,
    screen: ScreenSample,
    active_width: Meters,
    active_height: Meters,
    ideal_sensor: Vec2,
    lens_sample: Vec2,
    channel: usize,
) -> Option<(Vec2, f32)> {
    let (right, up, forward) = camera_basis(camera);
    let mut ideal = ideal_sensor;
    ideal.x *= camera.lens.lateral_chromatic_scale[channel];
    ideal.y *= camera.lens.lateral_chromatic_scale[channel];
    let pinhole_ray = normalize(add(
        forward,
        add(
            scale(
                right,
                ideal.x * camera.sensor_width.0 / (2.0 * camera.focal_length.0),
            ),
            scale(
                up,
                ideal.y * camera.sensor_height.0 / (2.0 * camera.focal_length.0),
            ),
        ),
    ));
    let channel_focus =
        camera.focus_distance.0 + camera.lens.longitudinal_chromatic_meters[channel];
    let focus_scale = channel_focus / dot(pinhole_ray, forward);
    let focus_point = add(camera.position, scale(pinhole_ray, focus_scale));
    let aperture_radius = camera.focal_length.0 * 0.001 / (2.0 * camera.f_stop);
    let lens_origin = add(
        camera.position,
        add(
            scale(right, lens_sample.x * aperture_radius),
            scale(up, lens_sample.y * aperture_radius),
        ),
    );
    let ray = normalize(subtract(focus_point, lens_origin));
    let local_origin = screen.world_to_local_point(lens_origin);
    let local_ray = screen.world_to_local_vector(ray);
    if local_ray.z.abs() < 1.0e-8 {
        return None;
    }
    let distance = -local_origin.z / local_ray.z;
    if distance <= 0.0 {
        return None;
    }
    let local_point = add(local_origin, scale(local_ray, distance));
    let world_point = screen.local_to_world(local_point);
    let depth = dot(subtract(world_point, camera.position), forward);
    if depth < camera.near_clip.0 || depth > camera.far_clip.0 {
        return None;
    }
    Some((
        Vec2 {
            x: local_point.x / active_width.0 + 0.5,
            y: 0.5 - local_point.y / active_height.0,
        },
        (-local_ray.z).clamp(0.0, 1.0),
    ))
}

fn distort(point: Vec2, lens: LensModel) -> Vec2 {
    let radius2 = point.x * point.x + point.y * point.y;
    let radial = 1.0
        + lens.radial_distortion[0] * radius2
        + lens.radial_distortion[1] * radius2 * radius2
        + lens.radial_distortion[2] * radius2 * radius2 * radius2;
    let p1 = lens.tangential_distortion[0];
    let p2 = lens.tangential_distortion[1];
    Vec2 {
        x: point.x * radial
            + 2.0 * p1 * point.x * point.y
            + p2 * (radius2 + 2.0 * point.x * point.x),
        y: point.y * radial
            + p1 * (radius2 + 2.0 * point.y * point.y)
            + 2.0 * p2 * point.x * point.y,
    }
}

fn inverse_distortion(observed: Vec2, lens: LensModel) -> Option<Vec2> {
    let mut ideal = observed;
    const EPSILON: f32 = 1.0e-4;
    for _ in 0..12 {
        let projected = distort(ideal, lens);
        let residual = Vec2 {
            x: observed.x - projected.x,
            y: observed.y - projected.y,
        };
        if residual.x.abs().max(residual.y.abs()) < 1.0e-6 {
            return Some(ideal);
        }
        let dx = distort(
            Vec2 {
                x: ideal.x + EPSILON,
                y: ideal.y,
            },
            lens,
        );
        let dy = distort(
            Vec2 {
                x: ideal.x,
                y: ideal.y + EPSILON,
            },
            lens,
        );
        let j00 = (dx.x - projected.x) / EPSILON;
        let j10 = (dx.y - projected.y) / EPSILON;
        let j01 = (dy.x - projected.x) / EPSILON;
        let j11 = (dy.y - projected.y) / EPSILON;
        let determinant = j00 * j11 - j01 * j10;
        if !determinant.is_finite() || determinant <= 1.0e-8 {
            return None;
        }
        ideal.x += (j11 * residual.x - j01 * residual.y) / determinant;
        ideal.y += (-j10 * residual.x + j00 * residual.y) / determinant;
        if !ideal.x.is_finite() || !ideal.y.is_finite() {
            return None;
        }
    }
    let residual = distort(ideal, lens);
    ((residual.x - observed.x)
        .abs()
        .max((residual.y - observed.y).abs())
        < 1.0e-5)
        .then_some(ideal)
}

fn distortion_is_invertible(lens: LensModel, lens_shift: Vec2) -> bool {
    const GRID_SEGMENTS: u32 = 64;
    const EPSILON: f32 = 1.0e-3;
    (0..=GRID_SEGMENTS).all(|column| {
        (0..=GRID_SEGMENTS).all(|row| {
            let x = column as f32 / GRID_SEGMENTS as f32 * 2.0 - 1.0;
            let y = row as f32 / GRID_SEGMENTS as f32 * 2.0 - 1.0;
            let observed = Vec2 {
                x: x + 2.0 * lens_shift.x,
                y: y + 2.0 * lens_shift.y,
            };
            let Some(recovered) = inverse_distortion(observed, lens) else {
                return false;
            };
            let projected = distort(recovered, lens);
            let dx = distort(
                Vec2 {
                    x: recovered.x + EPSILON,
                    y: recovered.y,
                },
                lens,
            );
            let dy = distort(
                Vec2 {
                    x: recovered.x,
                    y: recovered.y + EPSILON,
                },
                lens,
            );
            let origin = distort(recovered, lens);
            let determinant = ((dx.x - origin.x) * (dy.y - origin.y)
                - (dx.y - origin.y) * (dy.x - origin.x))
                / (EPSILON * EPSILON);
            recovered.x.is_finite()
                && recovered.y.is_finite()
                && (projected.x - observed.x).abs() < 1.0e-4
                && (projected.y - observed.y).abs() < 1.0e-4
                && determinant > 0.0
        })
    })
}

fn camera_basis(camera: CameraSample) -> (Vec3, Vec3, Vec3) {
    let forward = camera.rotation.rotate(Vec3 {
        x: 0.0,
        y: 0.0,
        z: -1.0,
    });
    let up = camera.rotation.rotate(Vec3 {
        x: 0.0,
        y: 1.0,
        z: 0.0,
    });
    let right = camera.rotation.rotate(Vec3 {
        x: 1.0,
        y: 0.0,
        z: 0.0,
    });
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
    EmptyTransformTrack,
    EmptyCameraIntrinsicsTrack,
    InvalidTransformKeyframe,
    InvalidCameraIntrinsicsKeyframe,
    InvalidCameraRotation,
    UnorderedTransformKeyframes,
    UnorderedCameraIntrinsicsKeyframes,
    InvalidResolvedLens,
    NonPositiveIntrinsics,
    InvalidInspectionRegion,
    InspectionRegionCannotBeFramed,
}

impl fmt::Display for GeometryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::EmptyTransformTrack => "transform track requires at least one keyframe",
            Self::EmptyCameraIntrinsicsTrack => {
                "camera intrinsics track requires at least one keyframe"
            }
            Self::InvalidTransformKeyframe => "transform keyframe is invalid or has a duplicate id",
            Self::InvalidCameraIntrinsicsKeyframe => {
                "camera intrinsics keyframe is invalid or has a duplicate id"
            }
            Self::InvalidCameraRotation => "camera keyframe quaternion must be normalized",
            Self::UnorderedTransformKeyframes => "transform keyframes must have increasing times",
            Self::UnorderedCameraIntrinsicsKeyframes => {
                "camera intrinsics keyframes must have increasing times"
            }
            Self::InvalidResolvedLens => "interpolated lens model is not invertible",
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

    #[test]
    fn orbit_yaw_pitch_rotation_looks_from_spherical_position_to_origin() {
        let yaw = 31.0_f32;
        let pitch = 19.0_f32;
        let horizontal = pitch.to_radians().cos();
        let position = Vec3 {
            x: horizontal * yaw.to_radians().sin(),
            y: pitch.to_radians().sin(),
            z: horizontal * yaw.to_radians().cos(),
        };
        let forward = Quaternion::from_orbit_yaw_pitch_degrees(yaw, pitch).rotate(Vec3 {
            x: 0.0,
            y: 0.0,
            z: -1.0,
        });
        assert!((forward.x + position.x).abs() < 1.0e-6);
        assert!((forward.y + position.y).abs() < 1.0e-6);
        assert!((forward.z + position.z).abs() < 1.0e-6);
    }

    fn rig() -> CameraRig {
        let keys = |id: &str, frame, yaw: f32| {
            (
                TransformKeyframe {
                    id: format!("{id}-transform"),
                    time: RationalTime::new(frame, 24).expect("valid time"),
                    translation: Vec3 {
                        x: 0.8 * yaw.to_radians().sin(),
                        y: 0.0,
                        z: 0.8 * yaw.to_radians().cos(),
                    },
                    rotation: Quaternion::from_yaw_degrees(yaw),
                    interpolation: KeyframeInterpolation::Smooth,
                },
                CameraIntrinsicsKeyframe {
                    id: format!("{id}-intrinsics"),
                    time: RationalTime::new(frame, 24).expect("valid time"),
                    focal_length: Millimeters(50.0),
                    sensor_width: Millimeters(36.0),
                    sensor_height: Millimeters(20.25),
                    lens_shift: Vec2 { x: 0.0, y: 0.0 },
                    focus_distance: Meters(0.8),
                    f_stop: 8.0,
                    near_clip: Meters(0.01),
                    far_clip: Meters(100.0),
                    lens: LensModel::REFERENCE_PHOTOGRAPHIC,
                    interpolation: KeyframeInterpolation::Smooth,
                },
            )
        };
        let (a_t, a_i) = keys("start", 0, -18.0);
        let (b_t, b_i) = keys("middle", 48, 18.0);
        CameraRig {
            transform: TransformTrack {
                keyframes: vec![a_t, b_t],
            },
            intrinsics: CameraIntrinsicsTrack {
                keyframes: vec![a_i, b_i],
            },
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
        let uv = panel_uv_at_viewport(
            camera,
            ScreenSample::IDENTITY,
            width,
            height,
            16.0 / 9.0,
            projected,
        )
        .expect("panel intersection");
        assert!((uv.x - 0.7).abs() < 0.000_1);
        assert!((uv.y - 0.676_470_6).abs() < 0.000_1);
    }

    #[test]
    fn transformed_screen_round_trips_in_its_local_coordinates() {
        let camera = rig()
            .sample(RationalTime::new(24, 24).expect("valid time"))
            .expect("sample");
        let screen = ScreenSample {
            translation: Vec3 {
                x: 0.04,
                y: -0.02,
                z: -0.08,
            },
            rotation: Quaternion::from_yaw_degrees(12.0),
        };
        let local = Vec3 {
            x: 0.09,
            y: -0.04,
            z: 0.0,
        };
        let projected = project_scene_point(camera, screen.local_to_world(local), 16.0 / 9.0)
            .expect("visible point");
        let uv = panel_uv_at_viewport(
            camera,
            screen,
            Meters(0.6),
            Meters(0.34),
            16.0 / 9.0,
            projected,
        )
        .expect("transformed panel hit");
        assert!((uv.x - 0.65).abs() < 2.0e-4);
        assert!((uv.y - (0.5 + 0.04 / 0.34)).abs() < 2.0e-4);
    }

    #[test]
    fn canonical_matrices_match_cpu_projection_and_depth_convention() {
        let camera = rig()
            .sample(RationalTime::new(36, 24).expect("valid time"))
            .expect("sample");
        let point = Vec3 {
            x: 0.08,
            y: 0.03,
            z: 0.0,
        };
        let transform = |matrix: [f32; 16], value: [f32; 4]| -> [f32; 4] {
            core::array::from_fn(|row| {
                matrix[row * 4] * value[0]
                    + matrix[row * 4 + 1] * value[1]
                    + matrix[row * 4 + 2] * value[2]
                    + matrix[row * 4 + 3] * value[3]
            })
        };
        let view = transform(camera.world_to_view, [point.x, point.y, point.z, 1.0]);
        let clip = transform(camera.ideal_view_to_clip, view);
        let ideal = Vec2 {
            x: clip[0] / clip[3],
            y: clip[1] / clip[3],
        };
        let observed = distort(ideal, camera.lens);
        let cpu = project_scene_point(camera, point, 16.0 / 9.0).expect("visible");
        assert!((cpu.x - observed.x).abs() < 1.0e-5);
        assert!(
            (cpu.y + observed.y).abs() < 1.0e-5,
            "viewport Y is explicitly downward"
        );

        let near_clip = transform(
            camera.ideal_view_to_clip,
            [0.0, 0.0, camera.near_clip.0, 1.0],
        );
        let far_clip = transform(
            camera.ideal_view_to_clip,
            [0.0, 0.0, camera.far_clip.0, 1.0],
        );
        assert!((near_clip[2] / near_clip[3] + 1.0).abs() < 1.0e-4);
        assert!((far_clip[2] / far_clip[3] - 1.0).abs() < 1.0e-4);
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
                ScreenSample::IDENTITY,
                16.0 / 9.0,
            )
            .expect("region can be framed");
        assert!(camera.position.z < 0.1);
        assert!(camera.target.x.abs() < 0.001);
    }

    #[test]
    fn aperture_rays_converge_on_the_authored_focus_plane() {
        let camera = rig()
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        let samples = panel_uv_aperture_samples(
            camera,
            ScreenSample::IDENTITY,
            Meters(0.6),
            Meters(0.34),
            Vec2 { x: 0.0, y: 0.0 },
        );
        let center = samples[0].panel_uv[1].expect("chief ray reaches panel");
        for sample in samples.into_iter().filter_map(|sample| sample.panel_uv[1]) {
            assert!((sample.x - center.x).abs() < 1.0e-5);
            assert!((sample.y - center.y).abs() < 1.0e-5);
        }
    }

    #[test]
    fn aperture_quality_levels_are_nested_and_deterministic() {
        let camera = rig()
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        let low = panel_uv_aperture_samples_with_count::<16>(
            camera,
            ScreenSample::IDENTITY,
            Meters(0.6),
            Meters(0.34),
            Vec2 { x: 0.2, y: -0.1 },
        );
        let high = panel_uv_aperture_samples_with_count::<128>(
            camera,
            ScreenSample::IDENTITY,
            Meters(0.6),
            Meters(0.34),
            Vec2 { x: 0.2, y: -0.1 },
        );
        assert_eq!(low.as_slice(), &high[..16]);
    }

    #[test]
    fn defocus_spreads_aperture_rays_and_clipping_rejects_the_panel() {
        let mut track = rig();
        track.intrinsics.keyframes[0].focus_distance = Meters(0.4);
        track.intrinsics.keyframes[0].f_stop = 1.4;
        let camera = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        let samples = panel_uv_aperture_samples(
            camera,
            ScreenSample::IDENTITY,
            Meters(0.6),
            Meters(0.34),
            Vec2 { x: 0.0, y: 0.0 },
        );
        let center = samples[0].panel_uv[1].expect("chief ray reaches panel");
        assert!(
            samples
                .into_iter()
                .filter_map(|sample| sample.panel_uv[1])
                .any(|sample| {
                    (sample.x - center.x).abs() > 1.0e-4 || (sample.y - center.y).abs() > 1.0e-4
                })
        );

        track.intrinsics.keyframes[0].far_clip = Meters(0.5);
        let clipped = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        assert!(
            panel_uv_aperture_samples(
                clipped,
                ScreenSample::IDENTITY,
                Meters(0.6),
                Meters(0.34),
                Vec2 { x: 0.0, y: 0.0 }
            )
            .iter()
            .all(|sample| sample.panel_uv.iter().all(Option::is_none))
        );
    }

    #[test]
    fn rgb_lens_model_separates_channels_and_vignettes_the_sensor_edge() {
        let camera = rig()
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        let center = panel_uv_aperture_samples(
            camera,
            ScreenSample::IDENTITY,
            Meters(0.6),
            Meters(0.34),
            Vec2 { x: 0.0, y: 0.0 },
        );
        let edge = panel_uv_aperture_samples(
            camera,
            ScreenSample::IDENTITY,
            Meters(0.6),
            Meters(0.34),
            Vec2 { x: 0.75, y: 0.6 },
        );
        let edge_sample = edge[0];
        let red = edge_sample.panel_uv[0].expect("red reaches panel");
        let blue = edge_sample.panel_uv[2].expect("blue reaches panel");
        assert!((red.x - blue.x).abs() > 1.0e-5 || (red.y - blue.y).abs() > 1.0e-5);
        assert!(edge_sample.irradiance_weight[1] < center[0].irradiance_weight[1]);
    }

    #[test]
    fn f_number_controls_physical_optical_throughput() {
        let mut track = rig();
        track.intrinsics.keyframes[0].f_stop = 4.0;
        let f4 = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("f4 sample");
        track.intrinsics.keyframes[0].f_stop = 8.0;
        let f8 = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("f8 sample");
        let weight = |camera| {
            panel_uv_aperture_samples(
                camera,
                ScreenSample::IDENTITY,
                Meters(0.6),
                Meters(0.34),
                Vec2 { x: 0.0, y: 0.0 },
            )[0]
            .irradiance_weight[1]
        };
        assert!((weight(f4) / weight(f8) - 4.0).abs() < 1.0e-4);
        let expected_center = core::f32::consts::FRAC_PI_4 / 16.0 * f4.lens.transmission_rgb[1];
        assert!((weight(f4) - expected_center).abs() < 1.0e-6);
    }

    #[test]
    fn distortion_inverse_round_trips_and_folding_models_are_rejected() {
        let lens = LensModel::REFERENCE_PHOTOGRAPHIC;
        let ideal = Vec2 { x: 0.8, y: -0.7 };
        let recovered =
            inverse_distortion(distort(ideal, lens), lens).expect("invertible reference lens");
        assert!((recovered.x - ideal.x).abs() < 1.0e-4);
        assert!((recovered.y - ideal.y).abs() < 1.0e-4);

        let mut track = rig();
        track.intrinsics.keyframes[0].lens.radial_distortion = [-2.0, 0.0, 0.0];
        assert!(matches!(
            track.validate(),
            Err(GeometryError::NonPositiveIntrinsics)
        ));

        let mut adversarial = rig();
        adversarial.intrinsics.keyframes[0].lens.radial_distortion =
            [-2.856_138_5, 3.541_582_3, 1.284_677_7];
        adversarial.intrinsics.keyframes[0].lens_shift = Vec2 { x: 0.5, y: 0.0 };
        assert!(
            adversarial.validate().is_err(),
            "the audit counterexample must never enter ray generation"
        );
    }

    #[test]
    fn domain_validation_rejects_non_finite_intrinsics_and_non_adjacent_duplicate_ids() {
        let mut camera = rig();
        camera.intrinsics.keyframes[0].focal_length = Millimeters(f32::NAN);
        assert!(matches!(
            camera.validate(),
            Err(GeometryError::InvalidCameraIntrinsicsKeyframe)
        ));

        let mut transforms = rig().transform;
        let mut third = transforms.keyframes[0].clone();
        third.time = RationalTime::new(96, 24).expect("valid time");
        transforms.keyframes.push(third);
        assert!(matches!(
            transforms.validate(),
            Err(GeometryError::InvalidTransformKeyframe)
        ));
    }

    #[test]
    fn bundled_lens_presets_are_unique_complete_and_inside_the_certified_domain() {
        let mut ids = HashSet::new();
        for preset in LENS_PRESETS {
            assert!(ids.insert(preset.id));
            assert_eq!(lens_preset(preset.id), Some(*preset));
            assert!(preset.nominal_focal_length.0 > 0.0);
            assert!(lens_is_valid_for_gate(preset.lens, Vec2 { x: 0.0, y: 0.0 }));
        }
        assert_eq!(lens_preset("unknown-or-retired"), None);

        for pair in LENS_PRESETS.windows(2) {
            let midpoint = interpolate_lens(pair[0].lens, pair[1].lens, &|left, right| {
                (left + right) * 0.5
            });
            assert!(lens_is_valid_for_gate(midpoint, Vec2 { x: 0.0, y: 0.0 }));
        }
    }
}
