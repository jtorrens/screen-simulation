//! Diagnostic tracking overlay evaluated from the same immutable scene frame as image renders.

use crate::{DeliveryRasterPlacement, RasterExtent, ResolvedSceneFrame};
use screen_contracts::{Meters, RationalTime, Vec2, Vec3};
use screen_geometry::{panel_uv_at_viewport, project_scene_point};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrackingOverlayIdentity {
    pub revision: u64,
    pub frame_index: i64,
    pub time: RationalTime,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProjectedTrackingPoint {
    pub pixel: Vec2,
    pub visible: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TrackingOverlayFrame {
    identity: TrackingOverlayIdentity,
    points: Vec<ProjectedTrackingPoint>,
}

impl TrackingOverlayFrame {
    pub const fn identity(&self) -> TrackingOverlayIdentity {
        self.identity
    }

    pub fn points(&self) -> &[ProjectedTrackingPoint] {
        &self.points
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackingOverlayError {
    InvalidScale,
    InvalidRaster,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct RasterProjection {
    camera_size: Vec2,
    delivery_size: Vec2,
    scale: f32,
    offset: Vec2,
    preview_scale: Vec2,
    placement: DeliveryRasterPlacement,
}

impl RasterProjection {
    fn new(
        scene: ResolvedSceneFrame,
        delivery: RasterExtent,
        preview: RasterExtent,
        placement: DeliveryRasterPlacement,
    ) -> Result<Self, TrackingOverlayError> {
        let camera = scene.active_sensor().extent();
        if camera.width() == 0
            || camera.height() == 0
            || delivery.width() == 0
            || delivery.height() == 0
            || preview.width() == 0
            || preview.height() == 0
        {
            return Err(TrackingOverlayError::InvalidRaster);
        }
        let camera_size = Vec2 {
            x: camera.width() as f32,
            y: camera.height() as f32,
        };
        let delivery_size = Vec2 {
            x: delivery.width() as f32,
            y: delivery.height() as f32,
        };
        let scale = match placement {
            DeliveryRasterPlacement::Fit => {
                (delivery_size.x / camera_size.x).min(delivery_size.y / camera_size.y)
            }
            DeliveryRasterPlacement::FillCrop => {
                (delivery_size.x / camera_size.x).max(delivery_size.y / camera_size.y)
            }
            DeliveryRasterPlacement::OneToOne => 1.0,
        };
        Ok(Self {
            camera_size,
            delivery_size,
            scale,
            offset: Vec2 {
                x: (delivery_size.x - camera_size.x * scale) * 0.5,
                y: (delivery_size.y - camera_size.y * scale) * 0.5,
            },
            preview_scale: Vec2 {
                x: preview.width() as f32 / delivery_size.x,
                y: preview.height() as f32 / delivery_size.y,
            },
            placement,
        })
    }

    fn ndc_to_preview(self, ndc: Vec2) -> Vec2 {
        let camera_pixel = Vec2 {
            x: (ndc.x + 1.0) * 0.5 * self.camera_size.x - 0.5,
            y: (ndc.y + 1.0) * 0.5 * self.camera_size.y - 0.5,
        };
        let delivery_pixel = if self.placement == DeliveryRasterPlacement::OneToOne {
            Vec2 {
                x: camera_pixel.x + self.offset.x,
                y: camera_pixel.y + self.offset.y,
            }
        } else {
            Vec2 {
                x: (camera_pixel.x + 0.5) * self.scale - 0.5 + self.offset.x,
                y: (camera_pixel.y + 0.5) * self.scale - 0.5 + self.offset.y,
            }
        };
        Vec2 {
            x: (delivery_pixel.x + 0.5) * self.preview_scale.x - 0.5,
            y: (delivery_pixel.y + 0.5) * self.preview_scale.y - 0.5,
        }
    }

    fn preview_to_ndc(self, preview_pixel: Vec2) -> Vec2 {
        let delivery_pixel = Vec2 {
            x: (preview_pixel.x + 0.5) / self.preview_scale.x - 0.5,
            y: (preview_pixel.y + 0.5) / self.preview_scale.y - 0.5,
        };
        let camera_pixel = if self.placement == DeliveryRasterPlacement::OneToOne {
            Vec2 {
                x: delivery_pixel.x - self.offset.x,
                y: delivery_pixel.y - self.offset.y,
            }
        } else {
            Vec2 {
                x: (delivery_pixel.x + 0.5 - self.offset.x) / self.scale - 0.5,
                y: (delivery_pixel.y + 0.5 - self.offset.y) / self.scale - 0.5,
            }
        };
        Vec2 {
            x: (camera_pixel.x + 0.5) * 2.0 / self.camera_size.x - 1.0,
            y: (camera_pixel.y + 0.5) * 2.0 / self.camera_size.y - 1.0,
        }
    }
}

pub fn project_device_focus_target(
    scene: ResolvedSceneFrame,
    active_width: Meters,
    active_height: Meters,
    target_uv: Vec2,
    delivery: RasterExtent,
    preview: RasterExtent,
    placement: DeliveryRasterPlacement,
) -> Result<ProjectedTrackingPoint, TrackingOverlayError> {
    if !target_uv.x.is_finite()
        || !target_uv.y.is_finite()
        || !(0.0..=1.0).contains(&target_uv.x)
        || !(0.0..=1.0).contains(&target_uv.y)
    {
        return Err(TrackingOverlayError::InvalidRaster);
    }
    let mapping = RasterProjection::new(scene, delivery, preview, placement)?;
    let world = scene.screen().local_to_world(Vec3 {
        x: (target_uv.x - 0.5) * active_width.0,
        y: (0.5 - target_uv.y) * active_height.0,
        z: 0.0,
    });
    let Some(ndc) = project_scene_point(scene.camera(), world, 1.0) else {
        return Ok(ProjectedTrackingPoint {
            pixel: Vec2 { x: 0.0, y: 0.0 },
            visible: false,
        });
    };
    Ok(ProjectedTrackingPoint {
        pixel: mapping.ndc_to_preview(ndc),
        visible: true,
    })
}

pub fn device_focus_target_at_preview_pixel(
    scene: ResolvedSceneFrame,
    active_width: Meters,
    active_height: Meters,
    preview_pixel: Vec2,
    delivery: RasterExtent,
    preview: RasterExtent,
    placement: DeliveryRasterPlacement,
) -> Result<Option<Vec2>, TrackingOverlayError> {
    let mapping = RasterProjection::new(scene, delivery, preview, placement)?;
    let uv = panel_uv_at_viewport(
        scene.camera(),
        scene.screen(),
        active_width,
        active_height,
        1.0,
        mapping.preview_to_ndc(preview_pixel),
    );
    Ok(uv.filter(|value| (0.0..=1.0).contains(&value.x) && (0.0..=1.0).contains(&value.y)))
}

pub fn evaluate_tracking_overlay(
    scene: ResolvedSceneFrame,
    source_points: &[Vec3],
    meters_per_source_unit: f32,
    delivery: RasterExtent,
    preview: RasterExtent,
    placement: DeliveryRasterPlacement,
) -> Result<TrackingOverlayFrame, TrackingOverlayError> {
    if !meters_per_source_unit.is_finite() || meters_per_source_unit <= 0.0 {
        return Err(TrackingOverlayError::InvalidScale);
    }
    let mapping = RasterProjection::new(scene, delivery, preview, placement)?;
    let points = source_points
        .iter()
        .map(|source| {
            let world = Vec3 {
                x: source.x * meters_per_source_unit,
                y: source.y * meters_per_source_unit,
                z: source.z * meters_per_source_unit,
            };
            let Some(ndc) = project_scene_point(scene.camera(), world, 1.0) else {
                return ProjectedTrackingPoint {
                    pixel: Vec2 { x: 0.0, y: 0.0 },
                    visible: false,
                };
            };
            ProjectedTrackingPoint {
                pixel: mapping.ndc_to_preview(ndc),
                visible: true,
            }
        })
        .collect();
    Ok(TrackingOverlayFrame {
        identity: TrackingOverlayIdentity {
            revision: scene.revision().value(),
            frame_index: scene.frame_index(),
            time: scene.time(),
        },
        points,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn world_scale_preserves_projection_when_camera_and_point_share_the_scale() {
        let first_scene = crate::scene_resolution::tests::resolver_for_sensor_with_world_scale(
            4_608,
            3_164,
            16.0 / 9.0,
            1.0,
        )
        .resolve_frame(12)
        .expect("first scene");
        let second_scene = crate::scene_resolution::tests::resolver_for_sensor_with_world_scale(
            4_608,
            3_164,
            16.0 / 9.0,
            2.0,
        )
        .resolve_frame(12)
        .expect("second scene");
        let point = [Vec3 {
            x: 0.25,
            y: -0.125,
            z: 0.1,
        }];
        let first = evaluate_tracking_overlay(
            first_scene,
            &point,
            1.0,
            RasterExtent::new(3_840, 2_160).unwrap(),
            RasterExtent::new(1_280, 720).unwrap(),
            DeliveryRasterPlacement::Fit,
        )
        .unwrap();
        let second = evaluate_tracking_overlay(
            second_scene,
            &point,
            2.0,
            RasterExtent::new(3_840, 2_160).unwrap(),
            RasterExtent::new(1_280, 720).unwrap(),
            DeliveryRasterPlacement::Fit,
        )
        .unwrap();
        let first = first.points()[0];
        let second = second.points()[0];
        assert!(first.visible && second.visible);
        assert!((first.pixel.x - second.pixel.x).abs() <= 1.0e-5);
        assert!((first.pixel.y - second.pixel.y).abs() <= 1.0e-5);
    }

    #[test]
    fn active_sensor_delivery_and_preview_are_one_explicit_projection_chain() {
        let scene = crate::scene_resolution::tests::resolver_for_sensor(4_608, 3_164, 16.0 / 9.0)
            .resolve_frame(12)
            .expect("scene");
        assert_eq!(scene.active_sensor().origin_y(), 286);
        assert_eq!(scene.active_sensor().extent().width(), 4_608);
        assert_eq!(scene.active_sensor().extent().height(), 2_592);
        let points = [
            Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            Vec3 {
                x: 0.2,
                y: 0.1,
                z: 0.0,
            },
        ];
        let delivery = RasterExtent::new(2_048, 1_080).unwrap();
        let preview = RasterExtent::new(1_024, 540).unwrap();
        let fit = evaluate_tracking_overlay(
            scene,
            &points,
            1.0,
            delivery,
            preview,
            DeliveryRasterPlacement::Fit,
        )
        .unwrap();
        let fill = evaluate_tracking_overlay(
            scene,
            &points,
            1.0,
            delivery,
            preview,
            DeliveryRasterPlacement::FillCrop,
        )
        .unwrap();
        let one = evaluate_tracking_overlay(
            scene,
            &points,
            1.0,
            delivery,
            preview,
            DeliveryRasterPlacement::OneToOne,
        )
        .unwrap();
        assert_eq!(fit.identity().revision, scene.revision().value());
        assert_eq!(fit.identity().frame_index, scene.frame_index());
        assert_eq!(fit.identity().time, scene.time());
        assert!(fit.points().iter().all(|point| point.visible));
        assert!(fill.points().iter().all(|point| point.visible));
        assert!(one.points().iter().all(|point| point.visible));
        assert_ne!(fit.points()[1].pixel, fill.points()[1].pixel);
        assert_ne!(fit.points()[1].pixel, one.points()[1].pixel);
        assert_ne!(fill.points()[1].pixel, one.points()[1].pixel);
    }

    #[test]
    fn focus_target_projection_and_unprojection_share_the_resolved_scene() {
        let resolver = crate::scene_resolution::tests::resolver_with_visible_device();
        let scene = resolver.resolve_frame(12).expect("scene");
        let delivery = RasterExtent::new(3_840, 2_160).unwrap();
        let preview = RasterExtent::new(1_280, 720).unwrap();
        let expected = Vec2 { x: 0.23, y: 0.71 };
        let projected = project_device_focus_target(
            scene,
            Meters(0.3),
            Meters(0.2),
            expected,
            delivery,
            preview,
            DeliveryRasterPlacement::FillCrop,
        )
        .unwrap();
        assert!(projected.visible);
        let recovered = device_focus_target_at_preview_pixel(
            scene,
            Meters(0.3),
            Meters(0.2),
            projected.pixel,
            delivery,
            preview,
            DeliveryRasterPlacement::FillCrop,
        )
        .unwrap()
        .expect("focus target on Device");
        assert!((recovered.x - expected.x).abs() < 1.0e-4);
        assert!((recovered.y - expected.y).abs() < 1.0e-4);
    }
}
