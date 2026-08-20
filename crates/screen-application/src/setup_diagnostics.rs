//! Closed Application-owned plan for the lightweight Setup-family diagnostics.
//!
//! The host may bind media textures and execute the numeric Metal kernel, but it cannot
//! rematerialize camera, Device, lens, environment or raster-placement semantics from mutable
//! authoring after this plan has been prepared.

use crate::{DeliveryRasterBackground, DeliveryRasterPlacement, RasterExtent, ResolvedSceneFrame};
use screen_contracts::{Meters, Vec2, Vec3};
use screen_cover::{EnvironmentProjection, IncidentEnvironment, SphericalEnvironmentPlacement};
use screen_geometry::Quaternion;
use screen_panel::LcdProfile;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SetupDiagnosticIdentity {
    pub revision: u64,
    pub frame_index: i64,
    pub time_numerator: i64,
    pub time_denominator: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SetupEnvironmentGeometry {
    pub rotation_x_radians: f32,
    pub rotation_y_radians: f32,
    pub placement_anchor_direction_world: Vec3,
    pub placement_source_direction: Vec3,
    pub placement_tangent_transform: [f32; 4],
    pub finite_sphere: bool,
    pub sphere_center_meters: Vec3,
    pub sphere_radius_meters: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SetupDiagnosticPlan {
    pub identity: SetupDiagnosticIdentity,
    pub camera_position: Vec3,
    pub camera_rotation: Quaternion,
    pub screen_position: Vec3,
    pub screen_rotation: Quaternion,
    pub active_sensor: RasterExtent,
    pub device_native: RasterExtent,
    pub device_active_width: Meters,
    pub device_active_height: Meters,
    pub device_corner_radius: Meters,
    pub focal_length_millimeters: f32,
    pub sensor_width_millimeters: f32,
    pub sensor_height_millimeters: f32,
    pub lens_shift: Vec2,
    pub focus_distance_meters: f32,
    pub f_stop: f32,
    pub radial_distortion: [f32; 3],
    pub tangential_distortion: [f32; 2],
    pub environment: SetupEnvironmentGeometry,
    pub delivery: RasterExtent,
    pub preview: RasterExtent,
    pub delivery_placement: DeliveryRasterPlacement,
    pub delivery_background: DeliveryRasterBackground,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetupDiagnosticError {
    InvalidDevice,
    InvalidEnvironment,
    InvalidEnvironmentFraming,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlanarEnvironmentFraming {
    pub center_x: f32,
    pub center_y: f32,
    pub zoom: f32,
    pub roll_radians: f32,
    pub source: RasterExtent,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedEnvironmentPlacement {
    pub anchor_direction_world: Vec3,
    pub source_direction: Vec3,
    pub tangent_transform: [f32; 4],
}

pub fn resolve_planar_environment_framing(
    plan: SetupDiagnosticPlan,
    framing: PlanarEnvironmentFraming,
) -> Result<ResolvedEnvironmentPlacement, SetupDiagnosticError> {
    if !framing.center_x.is_finite()
        || !framing.center_y.is_finite()
        || !(0.0..=1.0).contains(&framing.center_x)
        || !(0.0..=1.0).contains(&framing.center_y)
        || !framing.zoom.is_finite()
        || !(1.0 / 65_536.0..=65_536.0).contains(&framing.zoom)
        || !framing.roll_radians.is_finite()
        || framing.source.width() != framing.source.height().saturating_mul(2)
    {
        return Err(SetupDiagnosticError::InvalidEnvironmentFraming);
    }
    let anchor = environment_query_direction(plan, 0.5, 0.5)?;
    let source = equirectangular_direction(framing.center_x, framing.center_y);
    let tangent_transform = fit_environment_placement_projectively(plan, framing, anchor, source)?;
    Ok(ResolvedEnvironmentPlacement {
        anchor_direction_world: anchor,
        source_direction: source,
        tangent_transform,
    })
}

/// Fits the anchored Mobius map `w = a*z/(c*z + 1)` between stereographic tangent planes after
/// the exact centre correspondence has been fixed. The complex `c` coefficient captures the
/// non-linear projective skew created by an oblique Device while preserving a bijection of the
/// complete sphere.
fn fit_environment_placement_projectively(
    plan: SetupDiagnosticPlan,
    framing: PlanarEnvironmentFraming,
    anchor: Vec3,
    source: Vec3,
) -> Result<[f32; 4], SetupDiagnosticError> {
    const GRID: usize = 9;
    let mut normal = [[0.0_f32; 4]; 4];
    let mut right_hand_side = [0.0_f32; 4];
    let mut sample_count = 0;
    for row in 0..GRID {
        for column in 0..GRID {
            let u = column as f32 / (GRID - 1) as f32;
            let v = row as f32 / (GRID - 1) as f32;
            if !device_point_is_inside_rounded_outline(plan, u, v) {
                continue;
            }
            let (target_u, target_v) = planar_source_uv(plan, framing, u, v);
            if !(0.0..=1.0).contains(&target_u) || !(0.0..=1.0).contains(&target_v) {
                continue;
            }
            let Ok(world) = environment_query_direction(plan, u, v) else {
                continue;
            };
            let target = equirectangular_direction(target_u, target_v);
            let Some((world_x, world_y)) = stereographic_coordinates(anchor, world) else {
                continue;
            };
            let Some((source_x, source_y)) = stereographic_coordinates(source, target) else {
                continue;
            };
            let dx = (u - 0.5) * 2.0;
            let dy = (v - 0.5) * 2.0;
            let radius_squared = dx * dx + dy * dy;
            let weight = 0.35 + 0.65 * (-1.5 * radius_squared).exp();
            let product_re = world_x * source_x - world_y * source_y;
            let product_im = world_x * source_y + world_y * source_x;
            let rows = [
                ([world_x, -world_y, -product_re, product_im], source_x),
                ([world_y, world_x, -product_im, -product_re], source_y),
            ];
            for (coefficients, value) in rows {
                for left in 0..4 {
                    right_hand_side[left] += weight * coefficients[left] * value;
                    for right in 0..4 {
                        normal[left][right] += weight * coefficients[left] * coefficients[right];
                    }
                }
            }
            sample_count += 1;
        }
    }
    if sample_count < 5 {
        return Err(SetupDiagnosticError::InvalidEnvironmentFraming);
    }
    let tangent_transform = solve_linear_system_4(normal, right_hand_side)
        .ok_or(SetupDiagnosticError::InvalidEnvironmentFraming)?;
    let tangent_transform =
        refine_environment_mobius_fit(plan, framing, anchor, source, tangent_transform)?;
    let placement = SphericalEnvironmentPlacement {
        anchor_direction_world: [anchor.x, anchor.y, anchor.z],
        source_direction: [source.x, source.y, source.z],
        tangent_transform,
    };
    placement
        .validate()
        .map_err(|_| SetupDiagnosticError::InvalidEnvironmentFraming)?;
    Ok(tangent_transform)
}

fn refine_environment_mobius_fit(
    plan: SetupDiagnosticPlan,
    framing: PlanarEnvironmentFraming,
    anchor: Vec3,
    source: Vec3,
    mut parameters: [f32; 4],
) -> Result<[f32; 4], SetupDiagnosticError> {
    const GRID: usize = 9;
    for _ in 0..12 {
        let mut normal = [[0.0_f32; 4]; 4];
        let mut right_hand_side = [0.0_f32; 4];
        for row in 0..GRID {
            for column in 0..GRID {
                let u = column as f32 / (GRID - 1) as f32;
                let v = row as f32 / (GRID - 1) as f32;
                if !device_point_is_inside_rounded_outline(plan, u, v) {
                    continue;
                }
                let (target_u, target_v) = planar_source_uv(plan, framing, u, v);
                if !(0.0..=1.0).contains(&target_u) || !(0.0..=1.0).contains(&target_v) {
                    continue;
                }
                let Ok(world) = environment_query_direction(plan, u, v) else {
                    continue;
                };
                let target_direction = equirectangular_direction(target_u, target_v);
                let Some(z) = stereographic_coordinates(anchor, world) else {
                    continue;
                };
                let Some(expected) = stereographic_coordinates(source, target_direction) else {
                    continue;
                };
                let Some((mapped, derivatives)) = mobius_value_and_derivatives(z, parameters)
                else {
                    continue;
                };
                let residual = [mapped.0 - expected.0, mapped.1 - expected.1];
                let dx = (u - 0.5) * 2.0;
                let dy = (v - 0.5) * 2.0;
                let weight = 0.35 + 0.65 * (-1.5 * (dx * dx + dy * dy)).exp();
                for left in 0..4 {
                    right_hand_side[left] -= weight
                        * (derivatives[left].0 * residual[0] + derivatives[left].1 * residual[1]);
                    for right in 0..4 {
                        normal[left][right] += weight
                            * (derivatives[left].0 * derivatives[right].0
                                + derivatives[left].1 * derivatives[right].1);
                    }
                }
            }
        }
        let Some(delta) = solve_linear_system_4(normal, right_hand_side) else {
            break;
        };
        for index in 0..4 {
            parameters[index] += delta[index];
        }
        if delta.iter().map(|value| value * value).sum::<f32>() <= 1.0e-12 {
            break;
        }
    }
    let placement = SphericalEnvironmentPlacement {
        anchor_direction_world: [anchor.x, anchor.y, anchor.z],
        source_direction: [source.x, source.y, source.z],
        tangent_transform: parameters,
    };
    placement
        .validate()
        .map_err(|_| SetupDiagnosticError::InvalidEnvironmentFraming)?;
    Ok(parameters)
}

fn mobius_value_and_derivatives(
    z: (f32, f32),
    parameters: [f32; 4],
) -> Option<((f32, f32), [(f32, f32); 4])> {
    let a = (parameters[0], parameters[1]);
    let c = (parameters[2], parameters[3]);
    let numerator = complex_multiply(a, z);
    let denominator_product = complex_multiply(c, z);
    let denominator = (1.0 + denominator_product.0, denominator_product.1);
    let value = complex_divide(numerator, denominator)?;
    let base = complex_divide(z, denominator)?;
    let z_squared = complex_multiply(z, z);
    let denominator_squared = complex_multiply(denominator, denominator);
    let c_derivative = complex_divide(
        (
            -complex_multiply(a, z_squared).0,
            -complex_multiply(a, z_squared).1,
        ),
        denominator_squared,
    )?;
    Some((
        value,
        [
            base,
            (-base.1, base.0),
            c_derivative,
            (-c_derivative.1, c_derivative.0),
        ],
    ))
}

fn complex_multiply(left: (f32, f32), right: (f32, f32)) -> (f32, f32) {
    (
        left.0 * right.0 - left.1 * right.1,
        left.0 * right.1 + left.1 * right.0,
    )
}

fn complex_divide(numerator: (f32, f32), denominator: (f32, f32)) -> Option<(f32, f32)> {
    let norm = denominator.0 * denominator.0 + denominator.1 * denominator.1;
    if !norm.is_finite() || norm <= 1.0e-20 {
        return None;
    }
    Some((
        (numerator.0 * denominator.0 + numerator.1 * denominator.1) / norm,
        (numerator.1 * denominator.0 - numerator.0 * denominator.1) / norm,
    ))
}

fn solve_linear_system_4(mut matrix: [[f32; 4]; 4], mut target: [f32; 4]) -> Option<[f32; 4]> {
    for column in 0..4 {
        let pivot = (column..4).max_by(|left, right| {
            matrix[*left][column]
                .abs()
                .total_cmp(&matrix[*right][column].abs())
        })?;
        if !matrix[pivot][column].is_finite() || matrix[pivot][column].abs() <= 1.0e-10 {
            return None;
        }
        matrix.swap(column, pivot);
        target.swap(column, pivot);
        let divisor = matrix[column][column];
        for index in column..4 {
            matrix[column][index] /= divisor;
        }
        target[column] /= divisor;
        for row in 0..4 {
            if row == column {
                continue;
            }
            let factor = matrix[row][column];
            for index in column..4 {
                matrix[row][index] -= factor * matrix[column][index];
            }
            target[row] -= factor * target[column];
        }
    }
    target
        .iter()
        .all(|value| value.is_finite())
        .then_some(target)
}

fn device_point_is_inside_rounded_outline(plan: SetupDiagnosticPlan, u: f32, v: f32) -> bool {
    let half_width = plan.device_active_width.0 * 0.5;
    let half_height = plan.device_active_height.0 * 0.5;
    let radius = plan
        .device_corner_radius
        .0
        .clamp(0.0, half_width.min(half_height));
    if radius <= 0.0 {
        return true;
    }
    let x = ((u - 0.5) * plan.device_active_width.0).abs();
    let y = ((v - 0.5) * plan.device_active_height.0).abs();
    let corner_x = (x - (half_width - radius)).max(0.0);
    let corner_y = (y - (half_height - radius)).max(0.0);
    corner_x * corner_x + corner_y * corner_y <= radius * radius
}

fn environment_query_direction(
    plan: SetupDiagnosticPlan,
    u: f32,
    v: f32,
) -> Result<Vec3, SetupDiagnosticError> {
    let right = rotate(
        plan.screen_rotation,
        Vec3 {
            x: 1.0,
            y: 0.0,
            z: 0.0,
        },
    );
    let up = rotate(
        plan.screen_rotation,
        Vec3 {
            x: 0.0,
            y: 1.0,
            z: 0.0,
        },
    );
    let normal = rotate(
        plan.screen_rotation,
        Vec3 {
            x: 0.0,
            y: 0.0,
            z: 1.0,
        },
    );
    let point = add(
        plan.screen_position,
        add(
            scale(right, (u - 0.5) * plan.device_active_width.0),
            scale(up, (0.5 - v) * plan.device_active_height.0),
        ),
    );
    let ray = normalize(subtract(point, plan.camera_position))?;
    let reflected = normalize(subtract(ray, scale(normal, 2.0 * dot(ray, normal))))?;
    if !plan.environment.finite_sphere {
        return Ok(reflected);
    }
    let relative = subtract(point, plan.environment.sphere_center_meters);
    let b = dot(relative, reflected);
    let c = dot(relative, relative)
        - plan.environment.sphere_radius_meters * plan.environment.sphere_radius_meters;
    let discriminant = b * b - c;
    if !discriminant.is_finite() || discriminant <= 0.0 {
        return Err(SetupDiagnosticError::InvalidEnvironmentFraming);
    }
    let distance = -b + discriminant.sqrt();
    if !distance.is_finite() || distance <= 0.0 {
        return Err(SetupDiagnosticError::InvalidEnvironmentFraming);
    }
    normalize(add(relative, scale(reflected, distance)))
}

#[cfg(test)]
fn planar_source_direction(
    plan: SetupDiagnosticPlan,
    framing: PlanarEnvironmentFraming,
    u: f32,
    v: f32,
) -> Vec3 {
    let (source_u, source_v) = planar_source_uv(plan, framing, u, v);
    equirectangular_direction(source_u, source_v)
}

fn planar_source_uv(
    plan: SetupDiagnosticPlan,
    framing: PlanarEnvironmentFraming,
    u: f32,
    v: f32,
) -> (f32, f32) {
    let source_aspect = framing.source.width() as f32 / framing.source.height() as f32;
    let device_aspect = plan.device_native.width() as f32 / plan.device_native.height() as f32;
    let fit = if source_aspect > device_aspect {
        (1.0, source_aspect / device_aspect)
    } else {
        (device_aspect / source_aspect, 1.0)
    };
    let angle = -framing.roll_radians;
    let (sine, cosine) = angle.sin_cos();
    let x = u - 0.5;
    let y = v - 0.5;
    let rotated_x = x * cosine - y * sine;
    let rotated_y = x * sine + y * cosine;
    (
        framing.center_x + rotated_x * fit.0 / framing.zoom,
        framing.center_y + rotated_y * fit.1 / framing.zoom,
    )
}

fn equirectangular_direction(u: f32, v: f32) -> Vec3 {
    let longitude = (u - 0.5) * std::f32::consts::TAU;
    let latitude = (0.5 - v) * std::f32::consts::PI;
    let latitude_cosine = latitude.cos();
    Vec3 {
        x: longitude.sin() * latitude_cosine,
        y: latitude.sin(),
        z: longitude.cos() * latitude_cosine,
    }
}

fn rotate(q: Quaternion, v: Vec3) -> Vec3 {
    let imaginary = Vec3 {
        x: q.x,
        y: q.y,
        z: q.z,
    };
    let t = scale(cross(imaginary, v), 2.0);
    add(v, add(scale(t, q.w), cross(imaginary, t)))
}

fn tangent_basis(direction: Vec3) -> (Vec3, Vec3) {
    let reference = if direction.y.abs() < 0.999 {
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
    let right = normalize(cross(reference, direction)).expect("finite normalized direction");
    let up = normalize(cross(direction, right)).expect("finite normalized direction");
    (right, up)
}

fn tangent_from(center: Vec3, direction: Vec3) -> Vec3 {
    normalize(subtract(direction, scale(center, dot(direction, center))))
        .expect("distinct finite direction")
}

fn stereographic_coordinates(center: Vec3, direction: Vec3) -> Option<(f32, f32)> {
    let cosine = dot(center, direction).clamp(-1.0, 1.0);
    let radius = (cosine.acos() * 0.5).tan();
    if !radius.is_finite() {
        return None;
    }
    if radius <= 1.0e-8 {
        return Some((0.0, 0.0));
    }
    let tangent = tangent_from(center, direction);
    let (right, up) = tangent_basis(center);
    Some((radius * dot(tangent, right), radius * dot(tangent, up)))
}

#[cfg(test)]
fn angle_between(left: Vec3, right: Vec3) -> f32 {
    dot(left, right).clamp(-1.0, 1.0).acos()
}

fn normalize(value: Vec3) -> Result<Vec3, SetupDiagnosticError> {
    let length = dot(value, value).sqrt();
    if !length.is_finite() || length <= 1.0e-8 {
        return Err(SetupDiagnosticError::InvalidEnvironmentFraming);
    }
    Ok(scale(value, 1.0 / length))
}

fn dot(left: Vec3, right: Vec3) -> f32 {
    left.x * right.x + left.y * right.y + left.z * right.z
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
fn cross(left: Vec3, right: Vec3) -> Vec3 {
    Vec3 {
        x: left.y * right.z - left.z * right.y,
        y: left.z * right.x - left.x * right.z,
        z: left.x * right.y - left.y * right.x,
    }
}

pub fn prepare_setup_diagnostic(
    scene: ResolvedSceneFrame,
    panel: LcdProfile,
    delivery: RasterExtent,
    preview: RasterExtent,
    delivery_placement: DeliveryRasterPlacement,
    delivery_background: DeliveryRasterBackground,
) -> Result<SetupDiagnosticPlan, SetupDiagnosticError> {
    if panel.validate().is_err()
        || panel.active_width.0 <= 0.0
        || panel.active_height.0 <= 0.0
        || panel.corner_radius.0 < 0.0
        || panel.corner_radius.0 > panel.active_width.0.min(panel.active_height.0) * 0.5
    {
        return Err(SetupDiagnosticError::InvalidDevice);
    }
    let device_native = RasterExtent::new(panel.native_width, panel.native_height)
        .map_err(|_| SetupDiagnosticError::InvalidDevice)?;
    let environment = match scene.pipeline().environment {
        IncidentEnvironment::Procedural(environment) => SetupEnvironmentGeometry {
            rotation_x_radians: environment.rotation_x_degrees.to_radians(),
            rotation_y_radians: environment.rotation_y_degrees.to_radians(),
            placement_anchor_direction_world: Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            },
            placement_source_direction: Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            },
            placement_tangent_transform: [1.0, 0.0, 0.0, 0.0],
            finite_sphere: false,
            sphere_center_meters: Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            sphere_radius_meters: 1.0,
        },
        IncidentEnvironment::Equirectangular(environment) => {
            let (finite_sphere, center, radius) = match environment.projection {
                EnvironmentProjection::Distant => (
                    false,
                    Vec3 {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                    },
                    1.0,
                ),
                EnvironmentProjection::FiniteSphere {
                    center_meters,
                    radius_meters,
                } => (
                    true,
                    Vec3 {
                        x: center_meters[0],
                        y: center_meters[1],
                        z: center_meters[2],
                    },
                    radius_meters,
                ),
            };
            if !radius.is_finite() || radius <= 0.0 {
                return Err(SetupDiagnosticError::InvalidEnvironment);
            }
            SetupEnvironmentGeometry {
                rotation_x_radians: 0.0,
                rotation_y_radians: 0.0,
                placement_anchor_direction_world: Vec3 {
                    x: environment.placement.anchor_direction_world[0],
                    y: environment.placement.anchor_direction_world[1],
                    z: environment.placement.anchor_direction_world[2],
                },
                placement_source_direction: Vec3 {
                    x: environment.placement.source_direction[0],
                    y: environment.placement.source_direction[1],
                    z: environment.placement.source_direction[2],
                },
                placement_tangent_transform: environment.placement.tangent_transform,
                finite_sphere,
                sphere_center_meters: center,
                sphere_radius_meters: radius,
            }
        }
    };
    let camera = scene.camera();
    let lens = camera.lens;
    Ok(SetupDiagnosticPlan {
        identity: SetupDiagnosticIdentity {
            revision: scene.revision().value(),
            frame_index: scene.frame_index(),
            time_numerator: scene.time().numerator(),
            time_denominator: scene.time().denominator(),
        },
        camera_position: camera.position,
        camera_rotation: camera.rotation,
        screen_position: scene.screen().translation,
        screen_rotation: scene.screen().rotation,
        active_sensor: scene.active_sensor().extent(),
        device_native,
        device_active_width: panel.active_width,
        device_active_height: panel.active_height,
        device_corner_radius: panel.corner_radius,
        focal_length_millimeters: camera.focal_length.0,
        sensor_width_millimeters: camera.sensor_width.0,
        sensor_height_millimeters: camera.sensor_height.0,
        lens_shift: camera.lens_shift,
        focus_distance_meters: camera.focus_distance.0,
        f_stop: camera.f_stop,
        radial_distortion: lens.radial_distortion,
        tangential_distortion: lens.tangential_distortion,
        environment,
        delivery,
        preview,
        delivery_placement,
        delivery_background,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scene_resolution::tests::resolver;

    #[test]
    fn plan_uses_only_the_resolved_frame_and_selected_panel() {
        let resolver = resolver();
        let scene = resolver.resolve_frame(5).unwrap();
        let panel = scene.pipeline().panel;
        let plan = prepare_setup_diagnostic(
            scene,
            panel,
            RasterExtent::new(3840, 2160).unwrap(),
            RasterExtent::new(960, 540).unwrap(),
            DeliveryRasterPlacement::Fit,
            DeliveryRasterBackground::Black,
        )
        .unwrap();
        assert_eq!(plan.identity.revision, scene.revision().value());
        assert_eq!(plan.camera_position, scene.camera().position);
        assert_eq!(plan.screen_position, scene.screen().translation);
        assert_eq!(plan.active_sensor, scene.active_sensor().extent());
        assert_eq!(plan.device_active_width, panel.active_width);
        assert_eq!(plan.focal_length_millimeters, scene.camera().focal_length.0);
        assert_eq!(plan.delivery.width(), 3840);
        assert_eq!(plan.preview.width(), 960);
    }

    #[test]
    fn planar_framing_materializes_finite_sphere_projective_placement() {
        let resolver = resolver();
        let scene = resolver.resolve_frame(5).unwrap();
        let panel = scene.pipeline().panel;
        let mut plan = prepare_setup_diagnostic(
            scene,
            panel,
            RasterExtent::new(3840, 2160).unwrap(),
            RasterExtent::new(960, 540).unwrap(),
            DeliveryRasterPlacement::Fit,
            DeliveryRasterBackground::Black,
        )
        .unwrap();
        plan.camera_position = Vec3 {
            x: 0.0,
            y: 0.0,
            z: 1.0,
        };
        plan.camera_rotation = Quaternion {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        };
        plan.screen_position = Vec3 {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        };
        plan.screen_rotation = Quaternion {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        };
        plan.environment.finite_sphere = true;
        plan.environment.sphere_center_meters = Vec3 {
            x: 0.2,
            y: 0.1,
            z: 0.0,
        };
        plan.environment.sphere_radius_meters = 5.0;
        let framing = PlanarEnvironmentFraming {
            center_x: 0.3,
            center_y: 0.4,
            zoom: 2.4,
            roll_radians: 0.37,
            source: RasterExtent::new(200, 100).unwrap(),
        };
        let placement = resolve_planar_environment_framing(plan, framing).unwrap();
        let expected_anchor = environment_query_direction(plan, 0.5, 0.5).unwrap();
        assert_eq!(placement.anchor_direction_world, expected_anchor);
        let expected_source = equirectangular_direction(framing.center_x, framing.center_y);
        assert_eq!(placement.source_direction, expected_source);
        let projective = screen_cover::SphericalEnvironmentPlacement {
            anchor_direction_world: [expected_anchor.x, expected_anchor.y, expected_anchor.z],
            source_direction: [expected_source.x, expected_source.y, expected_source.z],
            tangent_transform: placement.tangent_transform,
        };
        projective.validate().unwrap();

        let sample_world = environment_query_direction(plan, 0.5, 0.51).unwrap();
        let mapped = screen_cover::place_environment_direction(
            [sample_world.x, sample_world.y, sample_world.z],
            projective,
        );
        let mapped = Vec3 {
            x: mapped[0],
            y: mapped[1],
            z: mapped[2],
        };
        let expected = planar_source_direction(plan, framing, 0.5, 0.51);
        let local_error = angle_between(mapped, expected);
        assert!(local_error < 5.0e-3, "local error {local_error}");

        plan.environment.finite_sphere = false;
        let distant = resolve_planar_environment_framing(plan, framing).unwrap();
        assert_eq!(
            distant.anchor_direction_world,
            environment_query_direction(plan, 0.5, 0.5).unwrap()
        );
        assert_eq!(distant.source_direction, expected_source);
    }
}
