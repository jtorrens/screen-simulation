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
            if key.focal_length.0 <= 0.0
                || key.sensor_width.0 <= 0.0
                || key.sensor_height.0 <= 0.0
                || key.focus_distance.0 <= 0.0
                || key.f_stop <= 0.0
                || key.near_clip.0 <= 0.0
                || key.far_clip.0 <= key.near_clip.0
                || !key.lens_shift.x.is_finite()
                || !key.lens_shift.y.is_finite()
                || !lens_is_valid(key.lens)
                || key
                    .lens
                    .longitudinal_chromatic_meters
                    .into_iter()
                    .any(|offset| key.focus_distance.0 + offset <= 0.0)
            {
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
        let quaternion_dot = left.rotation.x * next.rotation.x
            + left.rotation.y * next.rotation.y
            + left.rotation.z * next.rotation.z
            + left.rotation.w * next.rotation.w;
        let next_sign = if quaternion_dot < 0.0 { -1.0 } else { 1.0 };
        let rotation = Quaternion {
            x: lerp(left.rotation.x, next.rotation.x * next_sign),
            y: lerp(left.rotation.y, next.rotation.y * next_sign),
            z: lerp(left.rotation.z, next.rotation.z * next_sign),
            w: lerp(left.rotation.w, next.rotation.w * next_sign),
        }
        .normalized();
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
        if !lens_is_valid(optics.lens) {
            return Err(GeometryError::InvalidResolvedLens);
        }
        Ok(camera_sample(
            Vec3 {
                x: lerp(left.position.x, next.position.x),
                y: lerp(left.position.y, next.position.y),
                z: lerp(left.position.z, next.position.z),
            },
            rotation,
            optics,
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
        },
    )
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
    pub sensor_height: Millimeters,
    pub lens_shift: Vec2,
    pub focus_distance: Meters,
    pub f_stop: f32,
    pub near_clip: Meters,
    pub far_clip: Meters,
    pub rotation: Quaternion,
    pub lens: LensModel,
}

fn lens_is_valid(lens: LensModel) -> bool {
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
            .all(|value| value > 0.0)
        && lens
            .transmission_rgb
            .into_iter()
            .all(|value| (0.0..=1.0).contains(&value))
        && distortion_is_invertible(lens)
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
    );
    panel_uv_for_lens_sample(
        camera,
        active_width,
        active_height,
        ideal,
        Vec2 { x: 0.0, y: 0.0 },
        1,
    )
}

pub const APERTURE_SAMPLE_COUNT: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OpticalSample {
    pub panel_uv: [Option<Vec2>; 3],
    pub irradiance_weight: [f32; 3],
}

pub fn panel_uv_aperture_samples(
    camera: CameraSample,
    active_width: Meters,
    active_height: Meters,
    viewport_ndc: Vec2,
) -> [OpticalSample; APERTURE_SAMPLE_COUNT] {
    const DISK: [Vec2; APERTURE_SAMPLE_COUNT] = [
        Vec2 { x: 0.250, y: 0.000 },
        Vec2 {
            x: -0.319,
            y: 0.293,
        },
        Vec2 {
            x: 0.048,
            y: -0.557,
        },
        Vec2 { x: 0.403, y: 0.524 },
        Vec2 {
            x: -0.739,
            y: -0.131,
        },
        Vec2 {
            x: 0.700,
            y: -0.444,
        },
        Vec2 {
            x: -0.236,
            y: 0.870,
        },
        Vec2 {
            x: -0.444,
            y: -0.861,
        },
    ];
    let ideal = inverse_distortion(
        Vec2 {
            x: viewport_ndc.x + 2.0 * camera.lens_shift.x,
            y: -viewport_ndc.y - 2.0 * camera.lens_shift.y,
        },
        camera.lens,
    );
    DISK.map(|lens_sample| {
        let panel_uv = core::array::from_fn(|channel| {
            panel_uv_for_lens_sample(
                camera,
                active_width,
                active_height,
                ideal,
                lens_sample,
                channel,
            )
        });
        let tangent_x = ideal.x * camera.sensor_width.0 / (2.0 * camera.focal_length.0);
        let tangent_y = ideal.y * camera.sensor_height.0 / (2.0 * camera.focal_length.0);
        let cosine = 1.0 / (1.0 + tangent_x * tangent_x + tangent_y * tangent_y).sqrt();
        let natural = cosine.powi(4);
        let vignette = 1.0 + (natural - 1.0) * camera.lens.vignetting_strength;
        let aperture_throughput = 1.0 / (camera.f_stop * camera.f_stop);
        OpticalSample {
            panel_uv,
            irradiance_weight: core::array::from_fn(|channel| {
                aperture_throughput * vignette * camera.lens.transmission_rgb[channel]
            }),
        }
    })
}

fn panel_uv_for_lens_sample(
    camera: CameraSample,
    active_width: Meters,
    active_height: Meters,
    ideal_sensor: Vec2,
    lens_sample: Vec2,
    channel: usize,
) -> Option<Vec2> {
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
    if ray.z.abs() < 1.0e-8 {
        return None;
    }
    let distance = -lens_origin.z / ray.z;
    if distance <= 0.0 {
        return None;
    }
    let point = add(lens_origin, scale(ray, distance));
    let depth = dot(subtract(point, camera.position), forward);
    if depth < camera.near_clip.0 || depth > camera.far_clip.0 {
        return None;
    }
    Some(Vec2 {
        x: point.x / active_width.0 + 0.5,
        y: 0.5 - point.y / active_height.0,
    })
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

fn inverse_distortion(observed: Vec2, lens: LensModel) -> Vec2 {
    let mut ideal = observed;
    for _ in 0..6 {
        let projected = distort(ideal, lens);
        ideal.x += observed.x - projected.x;
        ideal.y += observed.y - projected.y;
    }
    ideal
}

fn distortion_is_invertible(lens: LensModel) -> bool {
    const GRID: [f32; 5] = [-1.0, -0.5, 0.0, 0.5, 1.0];
    const EPSILON: f32 = 1.0e-3;
    GRID.into_iter().all(|x| {
        GRID.into_iter().all(|y| {
            let ideal = Vec2 { x, y };
            let observed = distort(ideal, lens);
            let recovered = inverse_distortion(observed, lens);
            let dx = distort(Vec2 { x: x + EPSILON, y }, lens);
            let dy = distort(Vec2 { x, y: y + EPSILON }, lens);
            let determinant = ((dx.x - observed.x) * (dy.y - observed.y)
                - (dx.y - observed.y) * (dy.x - observed.x))
                / (EPSILON * EPSILON);
            recovered.x.is_finite()
                && recovered.y.is_finite()
                && (recovered.x - x).abs() < 1.0e-4
                && (recovered.y - y).abs() < 1.0e-4
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
    EmptyCameraTrack,
    InvalidCameraKeyframe,
    InvalidCameraRotation,
    UnorderedCameraKeyframes,
    InvalidResolvedLens,
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
            sensor_height: Millimeters(20.25),
            lens_shift: Vec2 { x: 0.0, y: 0.0 },
            focus_distance: Meters(0.8),
            f_stop: 8.0,
            near_clip: Meters(0.01),
            far_clip: Meters(100.0),
            lens: LensModel::REFERENCE_PHOTOGRAPHIC,
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

    #[test]
    fn aperture_rays_converge_on_the_authored_focus_plane() {
        let camera = rig()
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        let samples =
            panel_uv_aperture_samples(camera, Meters(0.6), Meters(0.34), Vec2 { x: 0.0, y: 0.0 });
        let center = samples[0].panel_uv[1].expect("chief ray reaches panel");
        for sample in samples.into_iter().filter_map(|sample| sample.panel_uv[1]) {
            assert!((sample.x - center.x).abs() < 1.0e-5);
            assert!((sample.y - center.y).abs() < 1.0e-5);
        }
    }

    #[test]
    fn defocus_spreads_aperture_rays_and_clipping_rejects_the_panel() {
        let mut track = rig();
        track.keyframes[0].focus_distance = Meters(0.4);
        track.keyframes[0].f_stop = 1.4;
        let camera = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        let samples =
            panel_uv_aperture_samples(camera, Meters(0.6), Meters(0.34), Vec2 { x: 0.0, y: 0.0 });
        let center = samples[0].panel_uv[1].expect("chief ray reaches panel");
        assert!(
            samples
                .into_iter()
                .filter_map(|sample| sample.panel_uv[1])
                .any(|sample| {
                    (sample.x - center.x).abs() > 1.0e-4 || (sample.y - center.y).abs() > 1.0e-4
                })
        );

        track.keyframes[0].far_clip = Meters(0.5);
        let clipped = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        assert!(
            panel_uv_aperture_samples(clipped, Meters(0.6), Meters(0.34), Vec2 { x: 0.0, y: 0.0 })
                .iter()
                .all(|sample| sample.panel_uv.iter().all(Option::is_none))
        );
    }

    #[test]
    fn rgb_lens_model_separates_channels_and_vignettes_the_sensor_edge() {
        let camera = rig()
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("camera sample");
        let center =
            panel_uv_aperture_samples(camera, Meters(0.6), Meters(0.34), Vec2 { x: 0.0, y: 0.0 });
        let edge =
            panel_uv_aperture_samples(camera, Meters(0.6), Meters(0.34), Vec2 { x: 0.75, y: 0.6 });
        let edge_sample = edge[0];
        let red = edge_sample.panel_uv[0].expect("red reaches panel");
        let blue = edge_sample.panel_uv[2].expect("blue reaches panel");
        assert!((red.x - blue.x).abs() > 1.0e-5 || (red.y - blue.y).abs() > 1.0e-5);
        assert!(edge_sample.irradiance_weight[1] < center[0].irradiance_weight[1]);
    }

    #[test]
    fn f_number_controls_physical_optical_throughput() {
        let mut track = rig();
        track.keyframes[0].f_stop = 4.0;
        let f4 = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("f4 sample");
        track.keyframes[0].f_stop = 8.0;
        let f8 = track
            .sample(RationalTime::new(0, 24).expect("valid time"))
            .expect("f8 sample");
        let weight = |camera| {
            panel_uv_aperture_samples(camera, Meters(0.6), Meters(0.34), Vec2 { x: 0.0, y: 0.0 })[0]
                .irradiance_weight[1]
        };
        assert!((weight(f4) / weight(f8) - 4.0).abs() < 1.0e-4);
    }

    #[test]
    fn distortion_inverse_round_trips_and_folding_models_are_rejected() {
        let lens = LensModel::REFERENCE_PHOTOGRAPHIC;
        let ideal = Vec2 { x: 0.8, y: -0.7 };
        let recovered = inverse_distortion(distort(ideal, lens), lens);
        assert!((recovered.x - ideal.x).abs() < 1.0e-4);
        assert!((recovered.y - ideal.y).abs() < 1.0e-4);

        let mut track = rig();
        track.keyframes[0].lens.radial_distortion = [-2.0, 0.0, 0.0];
        assert!(matches!(
            track.validate(),
            Err(GeometryError::NonPositiveIntrinsics)
        ));
    }
}
