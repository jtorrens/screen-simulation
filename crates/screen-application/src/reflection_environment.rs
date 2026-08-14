//! Host-neutral authoring of plausible reflection environments.
//!
//! A vector rig is compiled to an explicit 2:1 ACEScg radiance raster. The
//! existing image-Environment route remains the only reflection evaluator.

use core::fmt;
use screen_color::SceneLinearAdjustment;
use screen_contracts::{LinearRgb, Vec3};

pub const REFLECTION_ENVIRONMENT_RIG_ID: &str = "reflection-environment-rig-v1";

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReflectionLightAppearance {
    pub radiance_candelas_per_square_meter: f32,
    pub temperature_kelvin: f32,
    pub tint: f32,
    pub edge_softness_degrees: f32,
}

impl ReflectionLightAppearance {
    pub const WARM_PRACTICAL: Self = Self {
        radiance_candelas_per_square_meter: 4_000.0,
        temperature_kelvin: 3_200.0,
        tint: 0.0,
        edge_softness_degrees: 0.15,
    };
    pub const DAYLIGHT_WINDOW: Self = Self {
        radiance_candelas_per_square_meter: 8_000.0,
        temperature_kelvin: 5_600.0,
        tint: 0.0,
        edge_softness_degrees: 0.2,
    };
    pub const SUN: Self = Self {
        radiance_candelas_per_square_meter: 1_600_000.0,
        temperature_kelvin: 5_500.0,
        tint: 0.0,
        edge_softness_degrees: 0.02,
    };

    fn validate(self) -> Result<Self, ReflectionEnvironmentError> {
        if !self.radiance_candelas_per_square_meter.is_finite()
            || !(0.0..=10_000_000.0).contains(&self.radiance_candelas_per_square_meter)
            || !self.temperature_kelvin.is_finite()
            || !(2_000.0..=12_000.0).contains(&self.temperature_kelvin)
            || !self.tint.is_finite()
            || !(-1.0..=1.0).contains(&self.tint)
            || !self.edge_softness_degrees.is_finite()
            || !(0.0..=10.0).contains(&self.edge_softness_degrees)
        {
            return Err(ReflectionEnvironmentError::InvalidAppearance);
        }
        Ok(self)
    }

    fn radiance(self) -> Result<LinearRgb, ReflectionEnvironmentError> {
        let value = self.validate()?;
        let rgb = SceneLinearAdjustment {
            temperature_kelvin: value.temperature_kelvin,
            tint: value.tint,
            ..SceneLinearAdjustment::NEUTRAL
        }
        .acescg_white_gains()
        .map_err(|_| ReflectionEnvironmentError::InvalidAppearance)?;
        let y = rgb.r * 0.272_228_72 + rgb.g * 0.674_081_74 + rgb.b * 0.053_689_517;
        if !y.is_finite() || y <= 0.0 {
            return Err(ReflectionEnvironmentError::InvalidAppearance);
        }
        let scale = value.radiance_candelas_per_square_meter / y;
        Ok(LinearRgb::new(rgb.r * scale, rgb.g * scale, rgb.b * scale))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReflectionAreaLight {
    pub center_direction: Vec3,
    pub angular_width_degrees: f32,
    pub angular_height_degrees: f32,
    pub roll_degrees: f32,
    /// Derives plausible physical dimensions; it does not add HDRI parallax.
    pub distance_meters: f32,
    pub appearance: ReflectionLightAppearance,
}

impl ReflectionAreaLight {
    pub fn physical_size_meters(self) -> Result<(f32, f32), ReflectionEnvironmentError> {
        self.validate()?;
        Ok((
            2.0 * self.distance_meters * (self.angular_width_degrees.to_radians() * 0.5).tan(),
            2.0 * self.distance_meters * (self.angular_height_degrees.to_radians() * 0.5).tan(),
        ))
    }
    fn validate(self) -> Result<Self, ReflectionEnvironmentError> {
        unit(self.center_direction)?;
        if !self.angular_width_degrees.is_finite()
            || !(0.05..=170.0).contains(&self.angular_width_degrees)
            || !self.angular_height_degrees.is_finite()
            || !(0.05..=170.0).contains(&self.angular_height_degrees)
            || !self.roll_degrees.is_finite()
            || !(-180.0..=180.0).contains(&self.roll_degrees)
            || !self.distance_meters.is_finite()
            || !(0.01..=10_000.0).contains(&self.distance_meters)
        {
            return Err(ReflectionEnvironmentError::InvalidAreaLight);
        }
        self.appearance.validate()?;
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReflectionWindowLight {
    pub corner_directions: [Vec3; 4],
    pub distance_meters: f32,
    pub appearance: ReflectionLightAppearance,
}

impl ReflectionWindowLight {
    fn validate(self) -> Result<Self, ReflectionEnvironmentError> {
        let corners = normalized_corners(self.corner_directions)?;
        let center = unit(corners.into_iter().fold(
            Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            add,
        ))?;
        if (0..4).any(|i| dot(cross(corners[i], corners[(i + 1) % 4]), center).abs() <= 1.0e-5)
            || !self.distance_meters.is_finite()
            || !(0.01..=10_000.0).contains(&self.distance_meters)
        {
            return Err(ReflectionEnvironmentError::InvalidWindowLight);
        }
        self.appearance.validate()?;
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReflectionSunLight {
    pub direction: Vec3,
    pub angular_diameter_degrees: f32,
    pub appearance: ReflectionLightAppearance,
}

impl ReflectionSunLight {
    fn validate(self) -> Result<Self, ReflectionEnvironmentError> {
        unit(self.direction)?;
        if !self.angular_diameter_degrees.is_finite()
            || !(0.05..=10.0).contains(&self.angular_diameter_degrees)
        {
            return Err(ReflectionEnvironmentError::InvalidSunLight);
        }
        self.appearance.validate()?;
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ReflectionEmitter {
    Area(ReflectionAreaLight),
    Window(ReflectionWindowLight),
    Sun(ReflectionSunLight),
}

impl ReflectionEmitter {
    fn validate(self) -> Result<Self, ReflectionEnvironmentError> {
        match self {
            Self::Area(v) => v.validate().map(Self::Area),
            Self::Window(v) => v.validate().map(Self::Window),
            Self::Sun(v) => v.validate().map(Self::Sun),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ReflectionEnvironmentRig {
    pub emitters: Vec<ReflectionEmitter>,
    pub background_radiance_acescg: LinearRgb,
}

impl ReflectionEnvironmentRig {
    pub const MAX_EMITTERS: usize = 64;
    pub fn validate(&self) -> Result<(), ReflectionEnvironmentError> {
        if self.emitters.len() > Self::MAX_EMITTERS
            || [
                self.background_radiance_acescg.r,
                self.background_radiance_acescg.g,
                self.background_radiance_acescg.b,
            ]
            .into_iter()
            .any(|v| !v.is_finite() || v < 0.0)
        {
            return Err(ReflectionEnvironmentError::InvalidRig);
        }
        for emitter in &self.emitters {
            emitter.validate()?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ReflectionEnvironmentRaster {
    pub width: u32,
    pub height: u32,
    pub rgba_acescg: Vec<[f32; 4]>,
}

pub fn compile_reflection_environment(
    rig: &ReflectionEnvironmentRig,
    width: u32,
    height: u32,
) -> Result<ReflectionEnvironmentRaster, ReflectionEnvironmentError> {
    rig.validate()?;
    if width < 16 || height < 8 || width != height.saturating_mul(2) || width > 8_192 {
        return Err(ReflectionEnvironmentError::InvalidRaster);
    }
    let emitters = rig
        .emitters
        .iter()
        .copied()
        .map(PreparedEmitter::new)
        .collect::<Result<Vec<_>, _>>()?;
    let mut rgba = Vec::with_capacity(width as usize * height as usize);
    for y in 0..height {
        let latitude = (0.5 - (y as f32 + 0.5) / height as f32) * core::f32::consts::PI;
        let (slat, clat) = latitude.sin_cos();
        for x in 0..width {
            let longitude = ((x as f32 + 0.5) / width as f32 - 0.5) * 2.0 * core::f32::consts::PI;
            let (slon, clon) = longitude.sin_cos();
            let direction = Vec3 {
                x: slon * clat,
                y: slat,
                z: clon * clat,
            };
            let mut value = rig.background_radiance_acescg;
            for emitter in &emitters {
                let amount = emitter.weight(direction);
                value.r += emitter.radiance.r * amount;
                value.g += emitter.radiance.g * amount;
                value.b += emitter.radiance.b * amount;
            }
            rgba.push([value.r, value.g, value.b, 1.0]);
        }
    }
    Ok(ReflectionEnvironmentRaster {
        width,
        height,
        rgba_acescg: rgba,
    })
}

#[derive(Clone, Copy)]
enum Shape {
    Area {
        center: Vec3,
        tangent: Vec3,
        bitangent: Vec3,
        half_width: f32,
        half_height: f32,
        softness: f32,
    },
    Window {
        edges: [Vec3; 4],
        signs: [f32; 4],
        softness: f32,
    },
    Sun {
        center: Vec3,
        radius: f32,
        softness: f32,
    },
}

#[derive(Clone, Copy)]
struct PreparedEmitter {
    shape: Shape,
    radiance: LinearRgb,
}

impl PreparedEmitter {
    fn new(emitter: ReflectionEmitter) -> Result<Self, ReflectionEnvironmentError> {
        emitter.validate()?;
        let (shape, appearance) = match emitter {
            ReflectionEmitter::Area(v) => {
                let center = unit(v.center_direction)?;
                let reference = if center.y.abs() < 0.95 {
                    Vec3 {
                        x: 0.0,
                        y: 1.0,
                        z: 0.0,
                    }
                } else {
                    Vec3 {
                        x: 1.0,
                        y: 0.0,
                        z: 0.0,
                    }
                };
                let t0 = unit(cross(reference, center))?;
                let b0 = unit(cross(center, t0))?;
                let (s, c) = v.roll_degrees.to_radians().sin_cos();
                (
                    Shape::Area {
                        center,
                        tangent: add(scale(t0, c), scale(b0, s)),
                        bitangent: add(scale(b0, c), scale(t0, -s)),
                        half_width: v.angular_width_degrees.to_radians() * 0.5,
                        half_height: v.angular_height_degrees.to_radians() * 0.5,
                        softness: v.appearance.edge_softness_degrees.to_radians(),
                    },
                    v.appearance,
                )
            }
            ReflectionEmitter::Window(v) => {
                let corners = normalized_corners(v.corner_directions)?;
                let center = unit(corners.into_iter().fold(
                    Vec3 {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                    },
                    add,
                ))?;
                let edges = core::array::from_fn(|i| {
                    unit(cross(corners[i], corners[(i + 1) % 4])).expect("validated edge")
                });
                (
                    Shape::Window {
                        signs: edges.map(|edge| dot(edge, center).signum()),
                        edges,
                        softness: v.appearance.edge_softness_degrees.to_radians().sin(),
                    },
                    v.appearance,
                )
            }
            ReflectionEmitter::Sun(v) => (
                Shape::Sun {
                    center: unit(v.direction)?,
                    radius: v.angular_diameter_degrees.to_radians() * 0.5,
                    softness: v.appearance.edge_softness_degrees.to_radians(),
                },
                v.appearance,
            ),
        };
        Ok(Self {
            shape,
            radiance: appearance.radiance()?,
        })
    }

    fn weight(self, d: Vec3) -> f32 {
        match self.shape {
            Shape::Area {
                center,
                tangent,
                bitangent,
                half_width,
                half_height,
                softness,
            } => {
                let forward = dot(d, center);
                if forward <= 0.0 {
                    return 0.0;
                }
                edge(dot(d, tangent).atan2(forward).abs(), half_width, softness)
                    * edge(
                        dot(d, bitangent).atan2(forward).abs(),
                        half_height,
                        softness,
                    )
            }
            Shape::Window {
                edges,
                signs,
                softness,
            } => edges
                .into_iter()
                .zip(signs)
                .map(|(e, s)| smoothstep(-softness, softness, dot(e, d) * s))
                .product(),
            Shape::Sun {
                center,
                radius,
                softness,
            } => edge(dot(center, d).clamp(-1.0, 1.0).acos(), radius, softness),
        }
    }
}

fn edge(distance: f32, boundary: f32, softness: f32) -> f32 {
    if softness <= f32::EPSILON {
        if distance <= boundary { 1.0 } else { 0.0 }
    } else {
        1.0 - smoothstep(boundary - softness, boundary + softness, distance)
    }
}
fn smoothstep(a: f32, b: f32, v: f32) -> f32 {
    let t = ((v - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
fn unit(v: Vec3) -> Result<Vec3, ReflectionEnvironmentError> {
    let l = dot(v, v).sqrt();
    if !l.is_finite() || l <= 1.0e-6 {
        Err(ReflectionEnvironmentError::InvalidDirection)
    } else {
        Ok(scale(v, 1.0 / l))
    }
}
fn normalized_corners(values: [Vec3; 4]) -> Result<[Vec3; 4], ReflectionEnvironmentError> {
    Ok([
        unit(values[0])?,
        unit(values[1])?,
        unit(values[2])?,
        unit(values[3])?,
    ])
}
fn add(a: Vec3, b: Vec3) -> Vec3 {
    Vec3 {
        x: a.x + b.x,
        y: a.y + b.y,
        z: a.z + b.z,
    }
}
fn scale(v: Vec3, s: f32) -> Vec3 {
    Vec3 {
        x: v.x * s,
        y: v.y * s,
        z: v.z * s,
    }
}
fn dot(a: Vec3, b: Vec3) -> f32 {
    a.x * b.x + a.y * b.y + a.z * b.z
}
fn cross(a: Vec3, b: Vec3) -> Vec3 {
    Vec3 {
        x: a.y * b.z - a.z * b.y,
        y: a.z * b.x - a.x * b.z,
        z: a.x * b.y - a.y * b.x,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReflectionEnvironmentError {
    InvalidRig,
    InvalidAppearance,
    InvalidDirection,
    InvalidAreaLight,
    InvalidWindowLight,
    InvalidSunLight,
    InvalidRaster,
}
impl fmt::Display for ReflectionEnvironmentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidRig => "reflection environment rig is invalid",
            Self::InvalidAppearance => "reflection light appearance is invalid",
            Self::InvalidDirection => "reflection light direction is invalid",
            Self::InvalidAreaLight => "reflection area light is invalid",
            Self::InvalidWindowLight => "reflection window light is invalid",
            Self::InvalidSunLight => "reflection sun light is invalid",
            Self::InvalidRaster => "reflection environment raster must be a bounded 2:1 image",
        })
    }
}
impl std::error::Error for ReflectionEnvironmentError {}

#[cfg(test)]
mod tests {
    use super::*;
    fn forward() -> Vec3 {
        Vec3 {
            x: 0.0,
            y: 0.0,
            z: 1.0,
        }
    }
    #[test]
    fn rejects_invalid_direction_and_raster() {
        let rig = ReflectionEnvironmentRig {
            emitters: vec![ReflectionEmitter::Sun(ReflectionSunLight {
                direction: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
                angular_diameter_degrees: 0.53,
                appearance: ReflectionLightAppearance::SUN,
            })],
            background_radiance_acescg: LinearRgb::new(0.0, 0.0, 0.0),
        };
        assert_eq!(
            rig.validate(),
            Err(ReflectionEnvironmentError::InvalidDirection)
        );
        let empty = ReflectionEnvironmentRig {
            emitters: vec![],
            background_radiance_acescg: LinearRgb::new(0.0, 0.0, 0.0),
        };
        assert_eq!(
            compile_reflection_environment(&empty, 64, 64),
            Err(ReflectionEnvironmentError::InvalidRaster)
        );
    }
    #[test]
    fn distance_derives_physical_size() {
        let light = ReflectionAreaLight {
            center_direction: forward(),
            angular_width_degrees: 20.0,
            angular_height_degrees: 10.0,
            roll_degrees: 0.0,
            distance_meters: 2.0,
            appearance: ReflectionLightAppearance::WARM_PRACTICAL,
        };
        let size = light.physical_size_meters().unwrap();
        assert!((size.0 - 4.0 * 10.0_f32.to_radians().tan()).abs() < 1.0e-6);
    }
    #[test]
    fn compiles_non_negative_centered_area() {
        let rig = ReflectionEnvironmentRig {
            emitters: vec![ReflectionEmitter::Area(ReflectionAreaLight {
                center_direction: forward(),
                angular_width_degrees: 24.0,
                angular_height_degrees: 12.0,
                roll_degrees: 0.0,
                distance_meters: 3.0,
                appearance: ReflectionLightAppearance::DAYLIGHT_WINDOW,
            })],
            background_radiance_acescg: LinearRgb::new(0.0, 0.0, 0.0),
        };
        let raster = compile_reflection_environment(&rig, 256, 128).unwrap();
        assert!(
            raster
                .rgba_acescg
                .iter()
                .flatten()
                .all(|v| v.is_finite() && *v >= 0.0)
        );
        assert!(raster.rgba_acescg[64 * 256 + 128][1] > 1_000.0);
        assert_eq!(raster.rgba_acescg[64 * 256], [0.0, 0.0, 0.0, 1.0]);
    }
    #[test]
    fn spherical_window_is_bounded() {
        let direction = |lon: f32, lat: f32| {
            let (slon, clon) = lon.to_radians().sin_cos();
            let (slat, clat) = lat.to_radians().sin_cos();
            Vec3 {
                x: slon * clat,
                y: slat,
                z: clon * clat,
            }
        };
        let rig = ReflectionEnvironmentRig {
            emitters: vec![ReflectionEmitter::Window(ReflectionWindowLight {
                corner_directions: [
                    direction(-10.0, 8.0),
                    direction(10.0, 8.0),
                    direction(10.0, -8.0),
                    direction(-10.0, -8.0),
                ],
                distance_meters: 2.0,
                appearance: ReflectionLightAppearance::DAYLIGHT_WINDOW,
            })],
            background_radiance_acescg: LinearRgb::new(0.0, 0.0, 0.0),
        };
        let lit = compile_reflection_environment(&rig, 256, 128)
            .unwrap()
            .rgba_acescg
            .into_iter()
            .filter(|p| p[1] > 1.0)
            .count();
        assert!(lit > 100 && lit < 2_000);
    }
}
