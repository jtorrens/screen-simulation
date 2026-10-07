//! Camera-lattice evaluation and Device-plane publication are separate raster boundaries.
use super::*;
use screen_sensor::{ExtrapolatedSensorRaw, ExtrapolatedSensorWindow};

/// Conservative local magnification bound for a perspective plane, in pixels/metre.
/// Corners are camera-local (right, up, positive depth), in 00,10,11,01 order.
/// Each cell bounds the Jacobian numerator and its minimum positive depth; edge
/// lengths alone are insufficient when the near edge is strongly magnified.
pub fn frontal_density_bound(
    corners: [[f64; 3]; 4],
    size: [f64; 2],
    focal_pixels: [f64; 2],
) -> Option<f64> {
    if corners
        .iter()
        .flatten()
        .chain(size.iter())
        .chain(focal_pixels.iter())
        .any(|v| !v.is_finite())
        || size.iter().chain(focal_pixels.iter()).any(|v| *v <= 0.0)
        || corners.iter().any(|p| p[2] <= 0.0)
    {
        return None;
    }
    if (0..3).any(|c| {
        (corners[0][c] + corners[2][c] - corners[1][c] - corners[3][c]).abs()
            > 1e-8 * corners.iter().map(|p| p[c].abs()).fold(1.0_f64, f64::max)
    }) {
        return None;
    }
    let u: [f64; 3] = std::array::from_fn(|c| (corners[1][c] - corners[0][c]) / size[0]);
    let v: [f64; 3] = std::array::from_fn(|c| (corners[3][c] - corners[0][c]) / size[1]);
    let point = |x: f64, y: f64| -> [f64; 3] {
        std::array::from_fn(|c| corners[0][c] + u[c] * x + v[c] * y)
    };
    let numerator = |p: [f64; 3]| -> [f64; 4] {
        [
            focal_pixels[0] * (u[0] * p[2] - p[0] * u[2]),
            focal_pixels[0] * (v[0] * p[2] - p[0] * v[2]),
            focal_pixels[1] * (u[1] * p[2] - p[1] * u[2]),
            focal_pixels[1] * (v[1] * p[2] - p[1] * v[2]),
        ]
    };
    let norm = |a: [f64; 4]| {
        let s = a.iter().map(|v| v * v).sum::<f64>();
        let det = a[0] * a[3] - a[1] * a[2];
        ((s + (s * s - 4.0 * det * det).max(0.0).sqrt()) * 0.5).sqrt()
    };
    let mut maximum: f64 = 0.0;
    for y in 0..16 {
        for x in 0..16 {
            let center = numerator(point(
                (x as f64 + 0.5) * size[0] / 16.0,
                (y as f64 + 0.5) * size[1] / 16.0,
            ));
            let mut deviation = [0.0_f64; 4];
            let mut depth = f64::INFINITY;
            for dy in [0.0, 1.0] {
                for dx in [0.0, 1.0] {
                    let p = point(
                        (x as f64 + dx) * size[0] / 16.0,
                        (y as f64 + dy) * size[1] / 16.0,
                    );
                    depth = depth.min(p[2]);
                    let n = numerator(p);
                    for c in 0..4 {
                        deviation[c] = deviation[c].max((n[c] - center[c]).abs());
                    }
                }
            }
            maximum = maximum.max(
                (norm(center) + deviation.iter().map(|v| v * v).sum::<f64>().sqrt())
                    / (depth * depth),
            );
        }
    }
    (maximum.is_finite() && maximum > 0.0).then_some(maximum)
}

#[derive(Clone, Copy, Debug)]
pub struct FrontalCameraWindow {
    pub lattice: ExtrapolatedSensorWindow,
    /// Normalized camera viewport origin and span; does not modify the physical gate.
    pub viewport: [f32; 4],
    pub active_width: u32,
    pub active_height: u32,
    pub output_width: u32,
    pub output_height: u32,
}

fn ideal_scene(
    plan: PhysicalPipelineExecutionPlan,
) -> Result<(screen_geometry::CameraSample, screen_geometry::ScreenSample), ApplicationError> {
    let (mut camera, screen) = plan
        .scene_geometry_lens
        .resolve(
            plan.camera_position,
            plan.camera_rotation,
            plan.screen_translation,
            plan.screen_rotation,
            plan.lens_amount,
        )
        .map_err(ApplicationError::Geometry)?;
    // Common distortion is delegated. This mapping does not remove optical RGB separation
    // from the evaluator: it only names the undistorted carrier's camera coordinate.
    camera.lens.radial_distortion = [0.0; 3];
    camera.lens.tangential_distortion = [0.0; 2];
    camera.lens.lateral_chromatic_scale = [1.0; 3];
    Ok((camera, screen))
}

fn project_uv(
    plan: PhysicalPipelineExecutionPlan,
    camera: screen_geometry::CameraSample,
    screen: screen_geometry::ScreenSample,
    uv: [f32; 2],
) -> Result<[f32; 2], ApplicationError> {
    let point = screen.local_to_world(Vec3 {
        x: (uv[0] - 0.5) * plan.panel.active_width.0,
        y: (0.5 - uv[1]) * plan.panel.active_height.0,
        z: 0.0,
    });
    let projected = screen_geometry::project_scene_point(camera, point, 1.0)
        .ok_or(ApplicationError::InvalidRenderContext)?;
    Ok([(projected.x + 1.0) * 0.5, (projected.y + 1.0) * 0.5])
}

pub fn prepare_frontal_camera_window(
    plan: PhysicalPipelineExecutionPlan,
    active_width: u32,
    active_height: u32,
) -> Result<FrontalCameraWindow, ApplicationError> {
    if active_width == 0
        || active_height == 0
        || active_width > plan.requested_width
        || active_height > plan.requested_height
    {
        return Err(ApplicationError::InvalidRenderContext);
    }
    let (camera, screen) = ideal_scene(plan)?;
    let camera_width = f32::from(plan.sensor_region.width);
    let camera_height = f32::from(plan.sensor_region.height);
    if camera_width == 0.0 || camera_height == 0.0 {
        return Err(ApplicationError::InvalidRenderContext);
    }
    let extent = [
        plan.requested_width as f32 / active_width as f32,
        plan.requested_height as f32 / active_height as f32,
    ];
    let mut minimum = [f32::INFINITY; 2];
    let mut maximum = [f32::NEG_INFINITY; 2];
    for y in [-0.5, 0.5] {
        for x in [-0.5, 0.5] {
            let uv = project_uv(
                plan,
                camera,
                screen,
                [0.5 + x * extent[0], 0.5 + y * extent[1]],
            )?;
            for c in 0..2 {
                minimum[c] = minimum[c].min(uv[c]);
                maximum[c] = maximum[c].max(uv[c]);
            }
        }
    }
    // Bloom two-site support plus three-site develop support and interpolation.
    let support = 6.0;
    let start = [
        (minimum[0] * camera_width).floor() - support,
        (minimum[1] * camera_height).floor() - support,
    ];
    let end = [
        (maximum[0] * camera_width).ceil() + support,
        (maximum[1] * camera_height).ceil() + support,
    ];
    if start
        .iter()
        .chain(end.iter())
        .any(|v| !v.is_finite() || v.abs() > 900_000.0)
        || (0..2).any(|c| end[c] - start[c] > 16_384.0 || end[c] <= start[c])
    {
        return Err(ApplicationError::UnsupportedRenderContext);
    }
    let lattice = ExtrapolatedSensorWindow {
        origin: [
            start[0] as i32 + i32::from(plan.sensor_region.origin_x),
            start[1] as i32 + i32::from(plan.sensor_region.origin_y),
        ],
        width: (end[0] - start[0]) as u16,
        height: (end[1] - start[1]) as u16,
    }
    .validate()
    .map_err(ApplicationError::Sensor)?;
    Ok(FrontalCameraWindow {
        lattice,
        viewport: [
            start[0] / camera_width,
            start[1] / camera_height,
            f32::from(lattice.width) / camera_width,
            f32::from(lattice.height) / camera_height,
        ],
        active_width,
        active_height,
        output_width: plan.requested_width,
        output_height: plan.requested_height,
    })
}

pub fn rectify_camera_raster(
    plan: PhysicalPipelineExecutionPlan,
    window: FrontalCameraWindow,
    camera_pixels: &[[f32; 4]],
) -> Result<PhysicalRgbaRaster, ApplicationError> {
    let width = usize::from(window.lattice.width);
    let height = usize::from(window.lattice.height);
    if camera_pixels.len() != width * height {
        return Err(ApplicationError::OpticalSampleRasterMismatch);
    }
    let (camera, screen) = ideal_scene(plan)?;
    let mut rgba = Vec::with_capacity(window.output_width as usize * window.output_height as usize);
    for y in 0..window.output_height {
        for x in 0..window.output_width {
            let uv = [
                (x as f32 + 0.5 - window.output_width as f32 * 0.5) / window.active_width as f32
                    + 0.5,
                (y as f32 + 0.5 - window.output_height as f32 * 0.5) / window.active_height as f32
                    + 0.5,
            ];
            let projected = project_uv(plan, camera, screen, uv)?;
            let sx = (projected[0] - window.viewport[0]) / window.viewport[2] * width as f32 - 0.5;
            let sy = (projected[1] - window.viewport[1]) / window.viewport[3] * height as f32 - 0.5;
            let ix = sx.floor() as i32;
            let iy = sy.floor() as i32;
            if ix < 0 || iy < 0 || ix + 1 >= width as i32 || iy + 1 >= height as i32 {
                return Err(ApplicationError::InvalidRenderContext);
            }
            let dx = sx - ix as f32;
            let dy = sy - iy as f32;
            let a = camera_pixels[iy as usize * width + ix as usize];
            let b = camera_pixels[iy as usize * width + ix as usize + 1];
            let c = camera_pixels[(iy as usize + 1) * width + ix as usize];
            let d = camera_pixels[(iy as usize + 1) * width + ix as usize + 1];
            rgba.push(std::array::from_fn(|k| {
                (a[k] * (1.0 - dx) + b[k] * dx) * (1.0 - dy) + (c[k] * (1.0 - dx) + d[k] * dx) * dy
            }));
        }
    }
    Ok(PhysicalRgbaRaster {
        width: window.output_width,
        height: window.output_height,
        rgba,
    })
}

pub fn expose_frontal_camera_raw(
    plan: PhysicalPipelineExecutionPlan,
    window: FrontalCameraWindow,
    shuttered: &[[f32; 4]],
) -> Result<ExtrapolatedSensorRaw, ApplicationError> {
    if plan.render_model != SimulationRenderModel::Physical {
        return Err(ApplicationError::InvalidRenderContext);
    }
    plan.radiometric_calibration
        .validate()
        .map_err(ApplicationError::InvalidRadiometricCalibration)?;
    let profile = plan
        .computational_capture
        .effective_sensor(plan.sensor, plan.computational_character_strength)
        .map_err(ApplicationError::Sensor)?;
    let scale =
        plan.panel.white_level_nits * plan.radiometric_calibration.effective_sensor_exposure_scale;
    let exposure = IntegratedOpticalExposure {
        width: u32::from(window.lattice.width),
        height: u32::from(window.lattice.height),
        duration_seconds: plan
            .shutter_close
            .checked_sub(plan.shutter_open)
            .map_err(ApplicationError::Time)?
            .as_seconds() as f32,
        acescg_illuminance_seconds: shuttered
            .iter()
            .map(|p| LinearRgb::new(p[0] * scale, p[1] * scale, p[2] * scale))
            .collect(),
    };
    screen_sensor::expose_extrapolated_lattice(
        profile,
        window.lattice,
        &exposure,
        CaptureIdentity {
            noise_seed: plan.shutter_motion.noise_seed,
            frame_index: plan.frame_index,
        },
        plan.sensor_noise_amount,
    )
    .map_err(ApplicationError::Sensor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontal_density_is_exact_for_frontal_and_bounds_oblique_local_magnification() {
        let front = [
            [-0.5, -0.5, 2.0],
            [0.5, -0.5, 2.0],
            [0.5, 0.5, 2.0],
            [-0.5, 0.5, 2.0],
        ];
        assert_eq!(
            frontal_density_bound(front, [1.0, 1.0], [1000.0, 1000.0]),
            Some(500.0)
        );
        // At the near edge, vertical magnification is 1000 px/m although the
        // far edge is only 333 px/m. An average edge-length rule undersamples it.
        let oblique = [
            [-0.5, -0.5, 1.0],
            [0.5, -0.5, 3.0],
            [0.5, 0.5, 3.0],
            [-0.5, 0.5, 1.0],
        ];
        let bound = frontal_density_bound(oblique, [1.0, 1.0], [1000.0, 1000.0]).unwrap();
        assert!(bound >= 1000.0);
        for y in 0..101 {
            for x in 0..101 {
                let px = x as f64 / 100.0 - 0.5;
                let py = y as f64 / 100.0 - 0.5;
                let z = 2.0 + 2.0 * px;
                let a = 1000.0 * (z - 2.0 * px) / (z * z);
                let c = -2000.0 * py / (z * z);
                let d = 1000.0 / z;
                for i in 0..32 {
                    let angle = i as f64 * std::f64::consts::TAU / 32.0;
                    let length = (a * angle.cos()).hypot(c * angle.cos() + d * angle.sin());
                    assert!(bound + 1e-8 >= length);
                }
            }
        }
        let mut invalid = front;
        invalid[2][2] = 3.0;
        assert!(frontal_density_bound(invalid, [1.0, 1.0], [1000.0, 1000.0]).is_none());
    }

    #[test]
    fn model_terminal_and_raster_are_application_owned() {
        use PhysicalIntermediate::*;
        let vfx = SimulationRenderModel::VfxContinuity;
        for stage in [
            ShutterMotion,
            ComputationalCapture,
            SensorCollection,
            SensorBloom,
            SensorReadoutRaw,
            DevelopedAcesCg,
            CameraRenderedAcesCg,
        ] {
            assert_eq!(vfx.resolve_intermediate(stage), LensProjection);
            assert!(PhysicalPipelineExecutionPlan::uses_camera_raster(
                vfx, stage
            ));
        }
        assert!(!PhysicalPipelineExecutionPlan::uses_camera_raster(
            vfx,
            SubpixelRadiance
        ));
        assert!(PhysicalPipelineExecutionPlan::uses_camera_raster(
            SimulationRenderModel::Physical,
            LensProjection
        ));
    }
}
