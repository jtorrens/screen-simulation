//! Closed Application-owned plan for the lightweight Setup-family diagnostics.
//!
//! The host may bind media textures and execute the numeric Metal kernel, but it cannot
//! rematerialize camera, Device, lens, environment or raster-placement semantics from mutable
//! authoring after this plan has been prepared.

use crate::{DeliveryRasterBackground, DeliveryRasterPlacement, RasterExtent, ResolvedSceneFrame};
use screen_contracts::{Meters, Vec2, Vec3};
use screen_cover::{EnvironmentProjection, IncidentEnvironment};
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
                rotation_x_radians: environment.rotation_x_degrees.to_radians(),
                rotation_y_radians: environment.rotation_y_degrees.to_radians(),
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
}
