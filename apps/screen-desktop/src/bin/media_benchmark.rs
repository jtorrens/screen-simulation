use std::path::{Path, PathBuf};
use std::time::Instant;

use screen_application::{
    DiagnosticView, OpticalRequest, PanelTemporalEvaluation, PreparedDeviceSignalRaster,
    ProceduralTestPattern, SimulationRequest, decoded_frame_to_device_signal_cpu_oracle,
    prepare_raster_from_native_device_signal_with_backend,
};
use screen_color::{ColorEngine, DeviceColorTarget, OcioInputTransform, SourceColorInterpretation};
use screen_contracts::{LinearRgb, Meters, Millimeters, RationalTime, Vec2, Vec3};
use screen_cover::{CoverGlassProfile, ProceduralEnvironment};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation, Quaternion,
    TransformKeyframe, TransformTrack, lens_preset,
};
use screen_media::{
    AlphaInterpretation, FrameSelectionPolicy, ResolvedSignalRange, ResolvedSourceDecode,
    ResolvedYuvInterpretation, ResolvedYuvMatrix,
};
use screen_panel::{
    AnalyticBanding, LcdProfile, PanelColorimetry, PanelTemporalEmission, ResidualFlicker,
    StripeLayout,
};
use screen_platform::{
    MediaDecodeDimensions, MetalMediaFrameCache, MetalMediaFrameRequest, MetalRawDevelopment,
    decode_frame_at_time_cpu_oracle, probe_media,
};

const DEFAULT_SOURCE: &str = "/Volumes/SD_02/PROYECTOS/FOQN/FOQN_E06/CHATS/FOQN_E06_0010.mov";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_SOURCE));
    let descriptor_started = Instant::now();
    let descriptor = probe_media(&path)?;
    let probe = descriptor_started.elapsed();
    let decode = ResolvedSourceDecode::Yuv(ResolvedYuvInterpretation {
        matrix: ResolvedYuvMatrix::Bt709,
        range: ResolvedSignalRange::Limited,
    });
    let color = SourceColorInterpretation::Ocio(OcioInputTransform::CameraRec709);
    let alpha = AlphaInterpretation::Ignore;
    let time = RationalTime::new(0, 1)?;
    let panel = reference_panel();

    let cpu_decode_started = Instant::now();
    let (_, cpu_frame) =
        decode_frame_at_time_cpu_oracle(&path, time, FrameSelectionPolicy::Floor, decode)?;
    let cpu_decode = cpu_decode_started.elapsed();
    let processor = ColorEngine::bundled()?
        .source_to_device_processor(color, DeviceColorTarget::SrgbDisplay)?;
    let cpu_idt_started = Instant::now();
    let cpu_signal =
        decoded_frame_to_device_signal_cpu_oracle(&cpu_frame, descriptor.alpha, alpha, &processor)?;
    let cpu_idt = cpu_idt_started.elapsed();
    let cpu_panel_started = Instant::now();
    let _cpu_prepared = PreparedDeviceSignalRaster::new(cpu_signal)?;
    let cpu_panel = cpu_panel_started.elapsed();

    let mut cache = MetalMediaFrameCache::new(2)?;
    let native = cache.prepare(request(
        &path,
        &descriptor,
        time,
        decode,
        color,
        alpha,
        MediaDecodeDimensions::Native,
        panel,
    ))?;
    let cached = cache.prepare(request(
        &path,
        &descriptor,
        time,
        decode,
        color,
        alpha,
        MediaDecodeDimensions::Native,
        panel,
    ))?;
    let held_sample = cache.prepare(request(
        &path,
        &descriptor,
        RationalTime::new(1, 100)?,
        decode,
        color,
        alpha,
        MediaDecodeDimensions::Native,
        panel,
    ))?;
    let draft = cache.prepare(request(
        &path,
        &descriptor,
        time,
        decode,
        color,
        alpha,
        MediaDecodeDimensions::Maximum {
            width: 960,
            height: 960,
        },
        panel,
    ))?;
    let next = cache.prepare(request(
        &path,
        &descriptor,
        RationalTime::new(1, 25)?,
        decode,
        color,
        alpha,
        MediaDecodeDimensions::Native,
        panel,
    ))?;
    let simulation = preview_request(panel, time);
    let metal = MetalRawDevelopment::new()?;
    let draft_preview_started = Instant::now();
    let _draft_preview = prepare_raster_from_native_device_signal_with_backend(
        simulation.clone(),
        360,
        225,
        &draft.signal,
        screen_application::RasterPlacement::Fit,
        &metal,
    )?;
    let draft_preview = draft_preview_started.elapsed();
    let native_preview_started = Instant::now();
    let _native_preview = prepare_raster_from_native_device_signal_with_backend(
        simulation,
        1_024,
        640,
        &native.signal,
        screen_application::RasterPlacement::Fit,
        &metal,
    )?;
    let native_preview = native_preview_started.elapsed();

    println!("source={}", path.display());
    println!(
        "descriptor={}x{} {} {} probe_ms={:.3}",
        descriptor.raster.width,
        descriptor.raster.height,
        descriptor.codec_name,
        descriptor.pixel_format_name,
        probe.as_secs_f64() * 1_000.0
    );
    println!(
        "before_cpu decode_ms={:.3} idt_ms={:.3} panel_prefix_ms={:.3} total_ms={:.3}",
        cpu_decode.as_secs_f64() * 1_000.0,
        cpu_idt.as_secs_f64() * 1_000.0,
        cpu_panel.as_secs_f64() * 1_000.0,
        (cpu_decode + cpu_idt + cpu_panel).as_secs_f64() * 1_000.0
    );
    report("after_gpu_native", &native);
    report("after_gpu_native_cache_hit", &cached);
    report("after_gpu_same_resolved_frame", &held_sample);
    report("after_gpu_draft_960", &draft);
    report("after_gpu_next_frame", &next);
    println!(
        "first_preview draft_spatial_ms={:.3} draft_media_plus_spatial_ms={:.3} native_1024_spatial_ms={:.3} native_media_plus_spatial_ms={:.3}",
        draft_preview.as_secs_f64() * 1_000.0,
        (draft.timings.probe_and_decode
            + draft.timings.transfer_and_idt
            + draft.timings.panel_preparation
            + draft_preview)
            .as_secs_f64()
            * 1_000.0,
        native_preview.as_secs_f64() * 1_000.0,
        (native.timings.probe_and_decode
            + native.timings.transfer_and_idt
            + native.timings.panel_preparation
            + native_preview)
            .as_secs_f64()
            * 1_000.0,
    );
    println!(
        "cache_entries={} exact_cache_hit={} held_cache_hit={} held_resolved={}/{} next_resolved={}/{}",
        cache.entry_count(),
        cached.cache_hit,
        held_sample.cache_hit,
        held_sample.resolved_time.numerator(),
        held_sample.resolved_time.denominator(),
        next.resolved_time.numerator(),
        next.resolved_time.denominator()
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn request<'a>(
    path: &'a Path,
    descriptor: &'a screen_media::MediaDescriptor,
    requested_time: RationalTime,
    decode_interpretation: ResolvedSourceDecode,
    color_interpretation: SourceColorInterpretation,
    alpha_interpretation: AlphaInterpretation,
    dimensions: MediaDecodeDimensions,
    panel: LcdProfile,
) -> MetalMediaFrameRequest<'a> {
    MetalMediaFrameRequest {
        path,
        descriptor,
        requested_time,
        policy: FrameSelectionPolicy::Floor,
        decode_interpretation,
        color_interpretation,
        alpha_interpretation,
        dimensions,
        panel,
    }
}

fn report(label: &str, frame: &screen_platform::PreparedMetalMediaFrame) {
    let timings = frame.timings;
    println!(
        "{label} raster={}x{} decode_ms={:.3} transfer_idt_ms={:.3} panel_prefix_ms={:.3} total_ms={:.3} cache_hit={}",
        frame.signal.width,
        frame.signal.height,
        timings.probe_and_decode.as_secs_f64() * 1_000.0,
        timings.transfer_and_idt.as_secs_f64() * 1_000.0,
        timings.panel_preparation.as_secs_f64() * 1_000.0,
        (timings.probe_and_decode + timings.transfer_and_idt + timings.panel_preparation)
            .as_secs_f64()
            * 1_000.0,
        frame.cache_hit
    );
}

fn reference_panel() -> LcdProfile {
    let zero = RationalTime::new(0, 1).expect("zero time");
    let period = RationalTime::new(1, 240).expect("valid period");
    LcdProfile {
        native_width: 3_840,
        native_height: 2_160,
        active_width: Meters(0.708_480),
        active_height: Meters(0.398_520),
        stripe_layout: StripeLayout::Rgb,
        black_matrix_fraction: 0.08,
        eotf_gamma: 2.2,
        black_level_nits: 0.08,
        white_level_nits: 350.0,
        colorimetry: PanelColorimetry::SRGB_D65,
        angular_emission_power: LinearRgb::new(1.7, 1.5, 1.8),
        temporal_emission: PanelTemporalEmission {
            residual_flicker: ResidualFlicker {
                period,
                amplitude: 0.0,
                phase: zero,
            },
            analytic_banding: AnalyticBanding {
                period,
                on_duration: period,
                phase: zero,
                amount: 0.0,
            },
        },
    }
}

fn preview_request(panel: LcdProfile, time: RationalTime) -> SimulationRequest {
    let lens = lens_preset("generic-prime-50mm")
        .expect("current reference lens")
        .lens;
    let camera = CameraRig {
        transform: TransformTrack {
            keyframes: vec![TransformKeyframe {
                id: "media-benchmark-camera".to_owned(),
                time,
                translation: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 0.82,
                },
                rotation: Quaternion::from_yaw_degrees(0.0),
                interpolation: KeyframeInterpolation::Hold,
            }],
        },
        intrinsics: CameraIntrinsicsTrack {
            keyframes: vec![CameraIntrinsicsKeyframe {
                id: "media-benchmark-intrinsics".to_owned(),
                time,
                focal_length: Millimeters(50.0),
                sensor_width: Millimeters(36.0),
                sensor_height: Millimeters(22.5),
                lens_shift: Vec2 { x: 0.0, y: 0.0 },
                focus_distance: Meters(0.82),
                f_stop: 4.0,
                near_clip: Meters(0.01),
                far_clip: Meters(100.0),
                lens,
                interpolation: KeyframeInterpolation::Hold,
            }],
        },
    };
    let screen = TransformTrack {
        keyframes: vec![TransformKeyframe {
            id: "media-benchmark-screen".to_owned(),
            time,
            translation: Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            rotation: Quaternion::from_yaw_degrees(0.0),
            interpolation: KeyframeInterpolation::Hold,
        }],
    };
    SimulationRequest {
        optics: OpticalRequest {
            time,
            panel_temporal_evaluation: PanelTemporalEvaluation::Instantaneous,
            panel_character_strength: 1.0,
            lens_character_strength: 1.0,
            viewport_aspect: 1.6,
            panel,
            cover: CoverGlassProfile::NEUTRAL,
            environment: ProceduralEnvironment::NONE,
            camera,
            screen,
            inspection: None,
            procedural_pattern: ProceduralTestPattern::EyeChart,
        },
        view: DiagnosticView::Composite,
        preview_exposure_ev: 0.0,
    }
}
