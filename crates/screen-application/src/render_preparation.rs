//! Host-neutral preparation of exact temporal and spatial render requirements.
//!
//! A host supplies one immutable render context. Application expands that context into exact
//! rational sample times and global-coordinate regions before any backend is invoked. Backends
//! cannot choose another time, raster, sensor window, scale or pixel aspect.

use crate::{ApplicationError, ResolvedSceneFrame, SceneFrameResolutionError, SceneFrameResolver};
use screen_contracts::{FrameRate, RationalTime};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SceneRevision(u64);

impl SceneRevision {
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RasterExtent {
    width: u32,
    height: u32,
}

impl RasterExtent {
    pub fn new(width: u32, height: u32) -> Result<Self, PreparedRenderError> {
        if width == 0 || height == 0 {
            return Err(PreparedRenderError::EmptyRaster);
        }
        Ok(Self { width, height })
    }

    pub const fn width(self) -> u32 {
        self.width
    }

    pub const fn height(self) -> u32 {
        self.height
    }
}

/// Complete photosite raster owned by the selected capture profile.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FullSensorRaster(RasterExtent);

impl FullSensorRaster {
    pub fn new(width: u32, height: u32) -> Result<Self, PreparedRenderError> {
        Ok(Self(RasterExtent::new(width, height)?))
    }

    pub const fn extent(self) -> RasterExtent {
        self.0
    }
}

/// Exact photosite rectangle exposed by the camera recording format inside the complete sensor.
/// Its origin remains in complete-sensor coordinates so CFA and noise cannot be re-anchored to a
/// crop or tile.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ActiveSensorWindow {
    full_sensor: FullSensorRaster,
    origin_x: u32,
    origin_y: u32,
    extent: RasterExtent,
}

impl ActiveSensorWindow {
    pub fn new(
        full_sensor: FullSensorRaster,
        origin_x: u32,
        origin_y: u32,
        width: u32,
        height: u32,
    ) -> Result<Self, PreparedRenderError> {
        let extent = RasterExtent::new(width, height)?;
        let end_x = origin_x
            .checked_add(width)
            .ok_or(PreparedRenderError::RasterOverflow)?;
        let end_y = origin_y
            .checked_add(height)
            .ok_or(PreparedRenderError::RasterOverflow)?;
        if end_x > full_sensor.extent().width() || end_y > full_sensor.extent().height() {
            return Err(PreparedRenderError::WindowOutsideRaster);
        }
        Ok(Self {
            full_sensor,
            origin_x,
            origin_y,
            extent,
        })
    }

    /// Resolves the largest centred integer window matching an explicitly authored physical gate.
    /// This is a crop only: no source, reference or delivery raster participates.
    pub fn centered_for_gate(
        full_sensor: FullSensorRaster,
        gate_width_millimeters: f64,
        gate_height_millimeters: f64,
    ) -> Result<Self, PreparedRenderError> {
        if !gate_width_millimeters.is_finite()
            || !gate_height_millimeters.is_finite()
            || gate_width_millimeters <= 0.0
            || gate_height_millimeters <= 0.0
        {
            return Err(PreparedRenderError::InvalidGate);
        }
        let full = full_sensor.extent();
        let gate_aspect = gate_width_millimeters / gate_height_millimeters;
        let full_aspect = f64::from(full.width()) / f64::from(full.height());
        let (width, height) = if gate_aspect >= full_aspect {
            (
                full.width(),
                ((f64::from(full.width()) / gate_aspect).floor() as u32).clamp(1, full.height()),
            )
        } else {
            (
                ((f64::from(full.height()) * gate_aspect).floor() as u32).clamp(1, full.width()),
                full.height(),
            )
        };
        Self::new(
            full_sensor,
            (full.width() - width) / 2,
            (full.height() - height) / 2,
            width,
            height,
        )
    }

    pub const fn full_sensor(self) -> FullSensorRaster {
        self.full_sensor
    }

    pub const fn origin_x(self) -> u32 {
        self.origin_x
    }

    pub const fn origin_y(self) -> u32 {
        self.origin_y
    }

    pub const fn extent(self) -> RasterExtent {
        self.extent
    }
}

/// Global output rectangle requested by a host. It is never tile-local.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RenderWindow {
    full: RasterExtent,
    origin_x: u32,
    origin_y: u32,
    extent: RasterExtent,
}

impl RenderWindow {
    pub fn new(
        full: RasterExtent,
        origin_x: u32,
        origin_y: u32,
        width: u32,
        height: u32,
    ) -> Result<Self, PreparedRenderError> {
        let extent = RasterExtent::new(width, height)?;
        let end_x = origin_x
            .checked_add(width)
            .ok_or(PreparedRenderError::RasterOverflow)?;
        let end_y = origin_y
            .checked_add(height)
            .ok_or(PreparedRenderError::RasterOverflow)?;
        if end_x > full.width() || end_y > full.height() {
            return Err(PreparedRenderError::WindowOutsideRaster);
        }
        Ok(Self {
            full,
            origin_x,
            origin_y,
            extent,
        })
    }

    pub fn full_frame(full: RasterExtent) -> Self {
        Self {
            full,
            origin_x: 0,
            origin_y: 0,
            extent: full,
        }
    }

    pub const fn full(self) -> RasterExtent {
        self.full
    }

    pub const fn origin_x(self) -> u32 {
        self.origin_x
    }

    pub const fn origin_y(self) -> u32 {
        self.origin_y
    }

    pub const fn extent(self) -> RasterExtent {
        self.extent
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RenderScale {
    x_numerator: u32,
    x_denominator: u32,
    y_numerator: u32,
    y_denominator: u32,
}

impl RenderScale {
    pub const ONE: Self = Self {
        x_numerator: 1,
        x_denominator: 1,
        y_numerator: 1,
        y_denominator: 1,
    };

    pub fn new(
        x_numerator: u32,
        x_denominator: u32,
        y_numerator: u32,
        y_denominator: u32,
    ) -> Result<Self, PreparedRenderError> {
        if x_numerator == 0 || x_denominator == 0 || y_numerator == 0 || y_denominator == 0 {
            return Err(PreparedRenderError::InvalidRatio);
        }
        Ok(Self {
            x_numerator,
            x_denominator,
            y_numerator,
            y_denominator,
        })
    }

    pub const fn x(self) -> (u32, u32) {
        (self.x_numerator, self.x_denominator)
    }

    pub const fn y(self) -> (u32, u32) {
        (self.y_numerator, self.y_denominator)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HostRenderContext {
    time: RationalTime,
    frame_rate: FrameRate,
    output_window: RenderWindow,
    render_scale: RenderScale,
    pixel_aspect_numerator: u32,
    pixel_aspect_denominator: u32,
}

impl HostRenderContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        time: RationalTime,
        frame_rate: FrameRate,
        output_window: RenderWindow,
        render_scale: RenderScale,
        pixel_aspect_numerator: u32,
        pixel_aspect_denominator: u32,
    ) -> Result<Self, PreparedRenderError> {
        if pixel_aspect_numerator == 0 || pixel_aspect_denominator == 0 {
            return Err(PreparedRenderError::InvalidRatio);
        }
        Ok(Self {
            time,
            frame_rate,
            output_window,
            render_scale,
            pixel_aspect_numerator,
            pixel_aspect_denominator,
        })
    }

    pub const fn time(self) -> RationalTime {
        self.time
    }

    pub const fn frame_rate(self) -> FrameRate {
        self.frame_rate
    }

    pub const fn output_window(self) -> RenderWindow {
        self.output_window
    }

    pub const fn render_scale(self) -> RenderScale {
        self.render_scale
    }

    pub const fn pixel_aspect(self) -> (u32, u32) {
        (self.pixel_aspect_numerator, self.pixel_aspect_denominator)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhaseSpatialRequirement {
    SameRegion,
    Expanded {
        left: u32,
        right: u32,
        top: u32,
        bottom: u32,
    },
    FullFrame,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TemporalSampleUse {
    pub start: RationalTime,
    pub time: RationalTime,
    pub end: RationalTime,
    pub weight_seconds: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PreparedRenderRequirements {
    temporal_samples: Vec<TemporalSampleUse>,
    spatial: PhaseSpatialRequirement,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedSceneSample {
    use_: TemporalSampleUse,
    scene: ResolvedSceneFrame,
}

impl PreparedSceneSample {
    pub const fn use_(&self) -> TemporalSampleUse {
        self.use_
    }

    pub const fn scene(&self) -> ResolvedSceneFrame {
        self.scene
    }
}

impl PreparedRenderRequirements {
    pub fn temporal_samples(&self) -> &[TemporalSampleUse] {
        &self.temporal_samples
    }

    pub const fn spatial(&self) -> PhaseSpatialRequirement {
        self.spatial
    }
}

/// Closed render preparation. Its fields are private so a host cannot replace the scene revision,
/// exact time or declared phase requirements after Application has prepared them.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedRender {
    scene_revision: SceneRevision,
    context: HostRenderContext,
    center: ResolvedSceneFrame,
    requirements: PreparedRenderRequirements,
    samples: Vec<PreparedSceneSample>,
}

impl PreparedRender {
    pub const fn scene_revision(&self) -> SceneRevision {
        self.scene_revision
    }

    pub const fn context(&self) -> HostRenderContext {
        self.context
    }

    pub const fn center(&self) -> ResolvedSceneFrame {
        self.center
    }

    pub const fn requirements(&self) -> &PreparedRenderRequirements {
        &self.requirements
    }

    pub fn samples(&self) -> &[PreparedSceneSample] {
        &self.samples
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreparedRenderError {
    EmptyRaster,
    RasterOverflow,
    WindowOutsideRaster,
    InvalidGate,
    InvalidRatio,
    InvalidShutter,
    FrameRateMismatch,
    ActiveSensorChangesDuringExposure,
    SceneResolution,
}

impl From<SceneFrameResolutionError> for PreparedRenderError {
    fn from(_: SceneFrameResolutionError) -> Self {
        Self::SceneResolution
    }
}

impl From<ApplicationError> for PreparedRenderError {
    fn from(_: ApplicationError) -> Self {
        Self::InvalidShutter
    }
}

pub fn prepare_capture_render(
    resolver: &SceneFrameResolver,
    frame_index: i64,
    context: HostRenderContext,
    shutter_open: RationalTime,
    shutter_close: RationalTime,
    temporal_sample_count: u16,
    spatial: PhaseSpatialRequirement,
) -> Result<PreparedRender, PreparedRenderError> {
    let center = resolver.resolve_at(frame_index, context.time())?;
    if center.frame_rate() != context.frame_rate() {
        return Err(PreparedRenderError::FrameRateMismatch);
    }
    let scheduled =
        crate::physical_shutter_schedule(shutter_open, shutter_close, temporal_sample_count)?;
    let temporal_samples = scheduled
        .into_iter()
        .map(|sample| TemporalSampleUse {
            start: sample.start,
            time: sample.time,
            end: sample.end,
            weight_seconds: sample.weight_seconds,
        })
        .collect::<Vec<_>>();
    let samples = temporal_samples
        .iter()
        .copied()
        .map(|use_| {
            Ok(PreparedSceneSample {
                use_,
                scene: if use_.time == center.time() {
                    center
                } else {
                    resolver.resolve_prepared_at(
                        frame_index,
                        use_.time,
                        center.active_sensor(),
                        context,
                    )?
                },
            })
        })
        .collect::<Result<Vec<_>, PreparedRenderError>>()?;
    if samples
        .iter()
        .any(|sample| sample.scene.active_sensor() != center.active_sensor())
    {
        return Err(PreparedRenderError::ActiveSensorChangesDuringExposure);
    }
    Ok(PreparedRender {
        scene_revision: center.revision(),
        context,
        center,
        requirements: PreparedRenderRequirements {
            temporal_samples,
            spatial,
        },
        samples,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn active_sensor_window_is_a_crop_with_global_origin() {
        let full = FullSensorRaster::new(4608, 3164).unwrap();
        let active = ActiveSensorWindow::centered_for_gate(full, 16.0, 9.0).unwrap();
        assert_eq!(active.full_sensor(), full);
        assert_eq!(active.origin_x(), 0);
        assert_eq!(active.origin_y(), 286);
        assert_eq!(active.extent(), RasterExtent::new(4608, 2592).unwrap());
    }

    #[test]
    fn global_render_prepares_one_ordered_motion_sample_set_for_the_complete_frame() {
        let full = FullSensorRaster::new(8, 6).unwrap();
        let _active = ActiveSensorWindow::new(full, 0, 1, 8, 4).unwrap();
        let prepared = prepare_capture_render(
            &crate::scene_resolution::tests::resolver_for_sensor(8, 6, 2.0),
            12,
            HostRenderContext::new(
                RationalTime::new(1, 2).unwrap(),
                FrameRate::new(24, 1).unwrap(),
                RenderWindow::full_frame(RasterExtent::new(3840, 2160).unwrap()),
                RenderScale::ONE,
                1,
                1,
            )
            .unwrap(),
            RationalTime::new(23, 48).unwrap(),
            RationalTime::new(25, 48).unwrap(),
            2,
            PhaseSpatialRequirement::Expanded {
                left: 2,
                right: 2,
                top: 3,
                bottom: 3,
            },
        )
        .unwrap();
        assert_eq!(prepared.requirements().temporal_samples().len(), 2);
        assert!(
            prepared
                .requirements()
                .temporal_samples()
                .iter()
                .all(|sample| sample.weight_seconds > 0.0)
        );
        assert_eq!(prepared.samples()[0].scene().active_sensor().origin_y(), 1);
    }

    #[test]
    fn one_sample_at_track_start_resolves_only_the_shutter_midpoint() {
        let prepared = prepare_capture_render(
            &crate::scene_resolution::tests::resolver_for_sensor(8, 6, 4.0 / 3.0),
            0,
            HostRenderContext::new(
                RationalTime::new(0, 1).unwrap(),
                FrameRate::new(24, 1).unwrap(),
                RenderWindow::full_frame(RasterExtent::new(8, 6).unwrap()),
                RenderScale::ONE,
                1,
                1,
            )
            .unwrap(),
            RationalTime::new(-1, 48).unwrap(),
            RationalTime::new(1, 48).unwrap(),
            1,
            PhaseSpatialRequirement::FullFrame,
        )
        .unwrap();
        assert_eq!(prepared.samples().len(), 1);
        assert_eq!(
            prepared.samples()[0].use_().time,
            RationalTime::new(0, 1).unwrap()
        );
    }

    #[test]
    fn motion_samples_at_track_start_keep_the_extrapolated_scene_motion() {
        let prepared = prepare_capture_render(
            &crate::scene_resolution::tests::resolver_for_sensor(8, 6, 4.0 / 3.0),
            0,
            HostRenderContext::new(
                RationalTime::new(0, 1).unwrap(),
                FrameRate::new(24, 1).unwrap(),
                RenderWindow::full_frame(RasterExtent::new(8, 6).unwrap()),
                RenderScale::ONE,
                1,
                1,
            )
            .unwrap(),
            RationalTime::new(-1, 48).unwrap(),
            RationalTime::new(1, 48).unwrap(),
            2,
            PhaseSpatialRequirement::FullFrame,
        )
        .unwrap();
        assert_eq!(prepared.samples().len(), 2);
        assert_eq!(
            prepared.samples()[0].use_().time,
            RationalTime::new(-1, 96).unwrap()
        );
        assert_eq!(
            prepared.samples()[1].use_().time,
            RationalTime::new(1, 96).unwrap()
        );
        assert!(prepared.samples()[0].scene().camera().position.x < 0.0);
        assert!(prepared.samples()[1].scene().camera().position.x > 0.0);
    }

    #[test]
    fn repeated_preparation_reuses_only_exact_resolved_scene_samples() {
        let resolver = crate::scene_resolution::tests::resolver_for_sensor(8, 6, 4.0 / 3.0);
        resolver.set_temporal_cache_configuration(crate::TemporalCacheConfiguration::new(4096));
        let context = HostRenderContext::new(
            RationalTime::new(0, 1).unwrap(),
            FrameRate::new(24, 1).unwrap(),
            RenderWindow::full_frame(RasterExtent::new(8, 6).unwrap()),
            RenderScale::ONE,
            1,
            1,
        )
        .unwrap();
        let prepare = || {
            prepare_capture_render(
                &resolver,
                0,
                context,
                RationalTime::new(-1, 48).unwrap(),
                RationalTime::new(1, 48).unwrap(),
                2,
                PhaseSpatialRequirement::FullFrame,
            )
            .unwrap()
        };
        let first = prepare();
        let after_first = resolver.temporal_cache_stats();
        let second = prepare();
        let after_second = resolver.temporal_cache_stats();
        assert_eq!(first.samples(), second.samples());
        assert_eq!(after_first.misses, 2);
        assert_eq!(after_second.hits, 2);
        assert_eq!(after_second.misses, after_first.misses);
    }

    #[test]
    fn render_window_cannot_escape_its_full_raster() {
        let full = RasterExtent::new(1920, 1080).unwrap();
        assert_eq!(
            RenderWindow::new(full, 1900, 0, 40, 1080),
            Err(PreparedRenderError::WindowOutsideRaster)
        );
    }
}
