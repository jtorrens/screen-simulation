use screen_application::{RasterPlacement, RollingDirection, SensorReadout};
use screen_camera::CameraDevelopment;
use screen_color::{CameraOutputTransform, OcioInputTransform, SourceColorInterpretation};
use screen_contracts::{FrameRate, LinearRgb, Meters, Millimeters, RationalTime, Vec2, Vec3};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation, LensModel,
    Quaternion, ScreenTrack, TransformKeyframe, TransformTrack,
};
use screen_media::{
    AlphaInterpretation, SignalRangeSelection, SourceDecodeInterpretation, YuvMatrixSelection,
};
use screen_panel::{
    Chromaticity, LcdProfile, PanelColorimetry, PanelTemporalEmission, StripeLayout,
};
use screen_persistence::{
    AlphaSelection, BayerSelection, CameraIntrinsicsKeyframe as StoredIntrinsics, ExactTime,
    InterpolationSelection, MatrixSelection, PlacementSelection, ProjectPackage, RangeSelection,
    RollingDirectionSelection, SensorReadoutDocument, SourceColorSelection, StripeSelection,
    TransformKeyframe as StoredTransform,
};
use screen_sensor::{BayerPattern, SensorProfile};

pub struct ProjectScene {
    pub packaged_media_path: String,
    pub decode: SourceDecodeInterpretation,
    pub color: SourceColorInterpretation,
    pub alpha: AlphaInterpretation,
    pub placement: RasterPlacement,
    pub frame_rate: FrameRate,
    pub panel: LcdProfile,
    pub camera: CameraRig,
    pub screen: ScreenTrack,
    pub sensor: SensorProfile,
    pub shutter_duration: RationalTime,
    pub temporal_samples: u16,
    pub sensor_readout: SensorReadout,
    pub sensor_noise_seed: u64,
    pub camera_development: CameraDevelopment,
    pub camera_output_transform: CameraOutputTransform,
}

pub fn map_project_scene(package: &ProjectPackage) -> Result<ProjectScene, String> {
    package.validate().map_err(|error| error.to_string())?;
    let device = &package.device;
    let xy = |value: [f32; 2]| Chromaticity {
        x: value[0],
        y: value[1],
    };
    let scene = ProjectScene {
        packaged_media_path: package.source.media.as_str().to_owned(),
        decode: SourceDecodeInterpretation {
            matrix: match package.source.decode.matrix {
                MatrixSelection::Auto => YuvMatrixSelection::Auto,
                MatrixSelection::Bt601 => YuvMatrixSelection::Bt601,
                MatrixSelection::Bt709 => YuvMatrixSelection::Bt709,
                MatrixSelection::Bt2020 => YuvMatrixSelection::Bt2020,
            },
            range: match package.source.decode.range {
                RangeSelection::Auto => SignalRangeSelection::Auto,
                RangeSelection::Limited => SignalRangeSelection::Limited,
                RangeSelection::Full => SignalRangeSelection::Full,
            },
        },
        color: match &package.source.color {
            SourceColorSelection::Identity => SourceColorInterpretation::IdentityDeviceSignal,
            SourceColorSelection::Named { transform_id } => SourceColorInterpretation::Ocio(
                OcioInputTransform::from_stable_id(transform_id.as_str()).ok_or_else(|| {
                    format!(
                        "unknown current color transform id `{}`",
                        transform_id.as_str()
                    )
                })?,
            ),
        },
        alpha: match package.source.alpha {
            AlphaSelection::Auto => AlphaInterpretation::Auto,
            AlphaSelection::Straight => AlphaInterpretation::Straight,
            AlphaSelection::Premultiplied => AlphaInterpretation::Premultiplied,
        },
        placement: match package.source.placement {
            PlacementSelection::Fit => RasterPlacement::Fit,
            PlacementSelection::FillCrop => RasterPlacement::FillCrop,
            PlacementSelection::Stretch => RasterPlacement::Stretch,
            PlacementSelection::OneToOne => RasterPlacement::OneToOne,
        },
        frame_rate: FrameRate::new(
            package.shot.project_frame_rate.numerator,
            package.shot.project_frame_rate.denominator,
        )
        .map_err(|error| error.to_string())?,
        panel: LcdProfile {
            native_width: device.native_width,
            native_height: device.native_height,
            active_width: Meters(device.active_width_meters),
            active_height: Meters(device.active_height_meters),
            stripe_layout: match device.stripe {
                StripeSelection::Rgb => StripeLayout::Rgb,
                StripeSelection::Bgr => StripeLayout::Bgr,
            },
            black_matrix_fraction: device.black_matrix_fraction,
            eotf_gamma: device.eotf_gamma,
            black_level_nits: device.black_level_nits,
            white_level_nits: device.white_level_nits,
            colorimetry: PanelColorimetry {
                red: xy(device.primary_xy[0]),
                green: xy(device.primary_xy[1]),
                blue: xy(device.primary_xy[2]),
                white: xy(device.white_xy),
            },
            angular_emission_power: LinearRgb::new(
                device.angular_emission_power[0],
                device.angular_emission_power[1],
                device.angular_emission_power[2],
            ),
            temporal_emission: PanelTemporalEmission {
                pwm_period: map_time(device.pwm_period)?,
                pwm_on_duration: map_time(device.pwm_on_duration)?,
                phase: map_time(device.pwm_phase)?,
            },
        }
        .validate()
        .map_err(|error| error.to_string())?,
        camera: CameraRig {
            transform: TransformTrack {
                keyframes: package
                    .camera
                    .transform_keyframes
                    .iter()
                    .map(map_transform)
                    .collect::<Result<_, _>>()?,
            },
            intrinsics: CameraIntrinsicsTrack {
                keyframes: package
                    .camera
                    .intrinsics_keyframes
                    .iter()
                    .map(map_intrinsics)
                    .collect::<Result<_, _>>()?,
            },
        },
        screen: TransformTrack {
            keyframes: package
                .screen
                .transform_keyframes
                .iter()
                .map(map_transform)
                .collect::<Result<_, _>>()?,
        },
        sensor: SensorProfile {
            native_width: package.sensor.native_width,
            native_height: package.sensor.native_height,
            bayer_pattern: match package.sensor.bayer_pattern {
                BayerSelection::Rggb => BayerPattern::Rggb,
                BayerSelection::Bggr => BayerPattern::Bggr,
                BayerSelection::Grbg => BayerPattern::Grbg,
                BayerSelection::Gbrg => BayerPattern::Gbrg,
            },
            acescg_to_sensor: package.sensor.acescg_to_sensor,
            saturation_exposure: LinearRgb::new(
                package.sensor.saturation_exposure[0],
                package.sensor.saturation_exposure[1],
                package.sensor.saturation_exposure[2],
            ),
            full_well_electrons: package.sensor.full_well_electrons,
            dark_current_electrons_per_second: package.sensor.dark_current_electrons_per_second,
            read_noise_electrons_rms: package.sensor.read_noise_electrons_rms,
            analog_gain: package.sensor.analog_gain,
            adc_bits: package.sensor.adc_bits,
        }
        .validate()
        .map_err(|error| error.to_string())?,
        shutter_duration: map_time(package.sensor.shutter_duration)?,
        temporal_samples: package.sensor.temporal_samples,
        sensor_readout: match package.sensor.readout {
            SensorReadoutDocument::Global => SensorReadout::Global,
            SensorReadoutDocument::Rolling {
                duration,
                direction,
            } => SensorReadout::Rolling {
                duration: map_time(duration)?,
                direction: match direction {
                    RollingDirectionSelection::TopToBottom => RollingDirection::TopToBottom,
                    RollingDirectionSelection::BottomToTop => RollingDirection::BottomToTop,
                },
            },
        },
        sensor_noise_seed: package.shot.sensor_noise_seed,
        camera_development: CameraDevelopment {
            white_balance: LinearRgb::new(
                package.shot.white_balance_gains[0],
                package.shot.white_balance_gains[1],
                package.shot.white_balance_gains[2],
            ),
            linear_exposure_scale: package.shot.camera_linear_exposure_scale,
        }
        .validate()
        .map_err(|error| error.to_string())?,
        camera_output_transform: CameraOutputTransform::from_stable_id(
            &package.shot.camera_output_transform_id,
        )
        .ok_or_else(|| {
            format!(
                "unknown camera output transform: {}",
                package.shot.camera_output_transform_id
            )
        })?,
    };
    scene.camera.validate().map_err(|error| error.to_string())?;
    scene.screen.validate().map_err(|error| error.to_string())?;
    Ok(scene)
}

fn map_transform(key: &StoredTransform) -> Result<TransformKeyframe, String> {
    Ok(TransformKeyframe {
        id: key.keyframe_id.as_str().to_owned(),
        time: map_time(key.time)?,
        translation: Vec3 {
            x: key.translation_meters[0],
            y: key.translation_meters[1],
            z: key.translation_meters[2],
        },
        rotation: Quaternion {
            x: key.rotation_quaternion[0],
            y: key.rotation_quaternion[1],
            z: key.rotation_quaternion[2],
            w: key.rotation_quaternion[3],
        },
        interpolation: map_interpolation(key.interpolation),
    })
}

fn map_intrinsics(key: &StoredIntrinsics) -> Result<CameraIntrinsicsKeyframe, String> {
    Ok(CameraIntrinsicsKeyframe {
        id: key.keyframe_id.as_str().to_owned(),
        time: map_time(key.time)?,
        focal_length: Millimeters(key.focal_length_mm),
        sensor_width: Millimeters(key.sensor_width_mm),
        sensor_height: Millimeters(key.sensor_height_mm),
        lens_shift: Vec2 {
            x: key.lens_shift[0],
            y: key.lens_shift[1],
        },
        focus_distance: Meters(key.focus_distance_meters),
        f_stop: key.f_stop,
        near_clip: Meters(key.near_clip_meters),
        far_clip: Meters(key.far_clip_meters),
        lens: LensModel {
            radial_distortion: key.lens.radial_distortion,
            tangential_distortion: key.lens.tangential_distortion,
            longitudinal_chromatic_meters: key.lens.longitudinal_chromatic_meters,
            lateral_chromatic_scale: key.lens.lateral_chromatic_scale,
            vignetting_strength: key.lens.vignetting_strength,
            transmission_rgb: key.lens.transmission_rgb,
        },
        interpolation: map_interpolation(key.interpolation),
    })
}

fn map_time(time: ExactTime) -> Result<RationalTime, String> {
    RationalTime::new(time.numerator, time.denominator).map_err(|error| error.to_string())
}

fn map_interpolation(value: InterpolationSelection) -> KeyframeInterpolation {
    match value {
        InterpolationSelection::Hold => KeyframeInterpolation::Hold,
        InterpolationSelection::Linear => KeyframeInterpolation::Linear,
        InterpolationSelection::Smooth => KeyframeInterpolation::Smooth,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use screen_geometry::{ScreenSample, panel_uv_at_viewport};
    use screen_persistence::*;

    fn id(value: &str) -> OpaqueId {
        OpaqueId::parse(value).expect("valid id")
    }
    fn path(value: &str) -> PortablePath {
        PortablePath::parse(value).expect("valid path")
    }
    fn stored_transform(id_value: &str, z: f32) -> screen_persistence::TransformKeyframe {
        screen_persistence::TransformKeyframe {
            keyframe_id: id(id_value),
            time: ExactTime {
                numerator: 0,
                denominator: 24,
            },
            translation_meters: [0.0, 0.0, z],
            rotation_quaternion: [0.0, 0.0, 0.0, 1.0],
            interpolation: InterpolationSelection::Linear,
        }
    }

    #[test]
    fn complete_current_package_maps_to_one_executable_scene() {
        let package = ProjectPackage {
            manifest: ProjectManifest {
                schema: "screen_simulation_project".into(),
                version: CURRENT_VERSION,
                project_id: id("project-01"),
                title: "mapping".into(),
                source_document: path("sources/source.json"),
                device_document: path("devices/device.json"),
                camera_document: path("tracks/camera.json"),
                sensor_document: path("cameras/sensor.json"),
                screen_document: path("tracks/screen.json"),
                shot_document: path("shots/shot.json"),
            },
            source: SourceDocument {
                schema: "screen_simulation_source".into(),
                version: CURRENT_VERSION,
                source_id: id("source-01"),
                media: path("media/source.mov"),
                decode: PixelDecodeSelection {
                    matrix: MatrixSelection::Bt709,
                    range: RangeSelection::Limited,
                },
                color: SourceColorSelection::Named {
                    transform_id: id("arri-logc4"),
                },
                alpha: AlphaSelection::Premultiplied,
                placement: PlacementSelection::OneToOne,
            },
            device: DeviceDocument {
                schema: "screen_simulation_device".into(),
                version: CURRENT_VERSION,
                device_id: id("device-01"),
                native_width: 1920,
                native_height: 1080,
                active_width_meters: 0.531,
                active_height_meters: 0.299,
                stripe: StripeSelection::Rgb,
                black_matrix_fraction: 0.1,
                eotf_gamma: 2.2,
                black_level_nits: 0.05,
                white_level_nits: 500.0,
                primary_xy: [[0.64, 0.33], [0.30, 0.60], [0.15, 0.06]],
                white_xy: [0.3127, 0.3290],
                angular_emission_power: [1.7, 1.5, 1.8],
                pwm_period: ExactTime {
                    numerator: 1,
                    denominator: 960,
                },
                pwm_on_duration: ExactTime {
                    numerator: 1,
                    denominator: 1_920,
                },
                pwm_phase: ExactTime {
                    numerator: 0,
                    denominator: 1,
                },
            },
            camera: CameraDocument {
                schema: "screen_simulation_camera".into(),
                version: CURRENT_VERSION,
                camera_id: id("camera-01"),
                transform_keyframes: vec![stored_transform("camera-transform-01", 0.8)],
                intrinsics_keyframes: vec![screen_persistence::CameraIntrinsicsKeyframe {
                    keyframe_id: id("camera-intrinsics-01"),
                    time: ExactTime {
                        numerator: 0,
                        denominator: 24,
                    },
                    focal_length_mm: 50.0,
                    sensor_width_mm: 36.0,
                    sensor_height_mm: 20.25,
                    lens_shift: [0.0, 0.0],
                    focus_distance_meters: 0.8,
                    f_stop: 8.0,
                    near_clip_meters: 0.01,
                    far_clip_meters: 100.0,
                    lens: LensDocument {
                        radial_distortion: [-0.035, 0.008, 0.0],
                        tangential_distortion: [0.0004, -0.0003],
                        longitudinal_chromatic_meters: [0.0012, 0.0, -0.0015],
                        lateral_chromatic_scale: [1.0008, 1.0, 0.9991],
                        vignetting_strength: 0.65,
                        transmission_rgb: [0.92, 0.94, 0.95],
                    },
                    interpolation: InterpolationSelection::Linear,
                }],
            },
            sensor: SensorDocument {
                schema: "screen_simulation_sensor".into(),
                version: CURRENT_VERSION,
                sensor_id: id("sensor-01"),
                native_width: 3_840,
                native_height: 2_160,
                bayer_pattern: BayerSelection::Rggb,
                acescg_to_sensor: [[0.72, 0.21, 0.07], [0.10, 0.82, 0.08], [0.03, 0.16, 0.81]],
                saturation_exposure: [0.018, 0.018, 0.018],
                full_well_electrons: 45_000.0,
                dark_current_electrons_per_second: 0.1,
                read_noise_electrons_rms: 2.0,
                analog_gain: 1.0,
                adc_bits: 14,
                shutter_duration: ExactTime {
                    numerator: 1,
                    denominator: 48,
                },
                temporal_samples: 8,
                readout: SensorReadoutDocument::Rolling {
                    duration: ExactTime {
                        numerator: 1,
                        denominator: 60,
                    },
                    direction: RollingDirectionSelection::TopToBottom,
                },
            },
            screen: ScreenDocument {
                schema: "screen_simulation_screen".into(),
                version: CURRENT_VERSION,
                screen_id: id("screen-01"),
                transform_keyframes: vec![stored_transform("screen-transform-01", 0.0)],
            },
            shot: ShotDocument {
                schema: "screen_simulation_shot".into(),
                version: CURRENT_VERSION,
                shot_id: id("shot-01"),
                source_id: id("source-01"),
                device_id: id("device-01"),
                camera_id: id("camera-01"),
                sensor_id: id("sensor-01"),
                screen_id: id("screen-01"),
                project_frame_rate: ExactFrameRate {
                    numerator: 24,
                    denominator: 1,
                },
                sensor_noise_seed: 42,
                white_balance_gains: [2.0, 1.0, 1.5],
                camera_linear_exposure_scale: 55.555_557,
                camera_output_transform_id: "aces2-srgb-sdr-100".into(),
            },
        };
        let scene = map_project_scene(&package).expect("strict complete mapping");
        assert_eq!(scene.packaged_media_path, "media/source.mov");
        assert_eq!(
            scene.color,
            SourceColorInterpretation::Ocio(OcioInputTransform::ArriLogC4)
        );
        assert_eq!(scene.alpha, AlphaInterpretation::Premultiplied);
        assert_eq!(scene.placement, RasterPlacement::OneToOne);
        assert_eq!(scene.sensor.bayer_pattern, BayerPattern::Rggb);
        assert_eq!(scene.sensor.native_width, 3_840);
        assert_eq!(scene.sensor.native_height, 2_160);
        assert_eq!(scene.shutter_duration, RationalTime::new(1, 48).unwrap());
        assert_eq!(scene.temporal_samples, 8);
        assert_eq!(
            scene.sensor_readout,
            SensorReadout::Rolling {
                duration: RationalTime::new(1, 60).unwrap(),
                direction: RollingDirection::TopToBottom,
            }
        );
        assert_eq!(scene.sensor_noise_seed, 42);
        assert_eq!(
            scene.camera_development.white_balance,
            LinearRgb::new(2.0, 1.0, 1.5)
        );
        assert_eq!(scene.camera_development.linear_exposure_scale, 55.555_557);
        assert_eq!(
            scene.camera_output_transform,
            CameraOutputTransform::SrgbSdr100
        );
        let time = scene.frame_rate.time_at_frame(0).expect("time");
        let camera = scene.camera.sample(time).expect("camera");
        let screen = scene.screen.sample(time).expect("screen");
        let uv = panel_uv_at_viewport(
            camera,
            screen,
            scene.panel.active_width,
            scene.panel.active_height,
            16.0 / 9.0,
            Vec2 { x: 0.0, y: 0.0 },
        )
        .expect("ray");
        assert!((uv.x - 0.5).abs() < 1.0e-5 && (uv.y - 0.5).abs() < 1.0e-5);
        assert_ne!(
            screen,
            ScreenSample {
                translation: Vec3 {
                    x: 0.0,
                    y: 0.0,
                    z: 1.0
                },
                rotation: Quaternion {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                    w: 1.0
                }
            }
        );
    }
}
