use screen_application::{
    DeviceSignalRaster, PhysicalIntermediate, PhysicalPipelineExecutionPlan, PhysicalPipelineInput,
    PhysicalPipelineRequest, RasterPlacement, evaluate_physical_pipeline_cpu_oracle,
};
use screen_contracts::{DeviceRgb, Meters};
use screen_panel::{DEVICE_PRESETS, FlatPanelQuality, PanelLightSpreadProfile, StripeLayout};

fn request(
    quality: FlatPanelQuality,
    screen_amount: f32,
    emission_amount: f32,
    geometry_amount: f32,
) -> PhysicalPipelineRequest {
    let mut panel = DEVICE_PRESETS[0].profile();
    panel.native_width = 2;
    panel.native_height = 1;
    panel.active_width = Meters(0.002);
    panel.active_height = Meters(0.001);
    let acescg = vec![[1.5, -0.25, 0.5, 0.25], [0.0, 0.5, 2.0, 0.75]];
    PhysicalPipelineRequest {
        input: PhysicalPipelineInput {
            width: 2,
            height: 1,
            device_signal: DeviceSignalRaster {
                width: 2,
                height: 1,
                pixels: acescg
                    .iter()
                    .map(|value| DeviceRgb::new(value[0], value[1], value[2]))
                    .collect(),
            },
            acescg,
        },
        plan: PhysicalPipelineExecutionPlan {
            panel,
            panel_light_spread: PanelLightSpreadProfile {
                character_strength: 0.0,
                ..PanelLightSpreadProfile::LCD_DESKTOP
            },
            placement: RasterPlacement::Stretch,
            quality,
            requested_width: 6,
            requested_height: 3,
            screen_amount,
            emission_amount,
            subpixel_geometry_amount: geometry_amount,
            temporal_emission_amount: 0.0,
            temporal_emission_gain: 1.0,
            cover: screen_cover::CoverGlassProfile::NEUTRAL,
            environment: screen_cover::ProceduralEnvironment::NONE,
            scene_geometry_lens: screen_application::ResolvedSceneGeometryLensSnapshot::REFERENCE,
            camera_position: screen_contracts::Vec3 {
                x: 0.0,
                y: 0.0,
                z: 1.0,
            },
            camera_rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
            screen_translation: screen_contracts::Vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            screen_rotation: screen_geometry::Quaternion::from_yaw_degrees(0.0),
            scene_geometry_amount: 0.0,
            lens_amount: 0.0,
            lens_evaluation_model: screen_application::LensEvaluationModel::ThinLens,
            frame_time: screen_contracts::RationalTime::new(0, 1).expect("valid fixture time"),
            shutter_open: screen_contracts::RationalTime::new(-1, 96).expect("valid open"),
            shutter_close: screen_contracts::RationalTime::new(1, 96).expect("valid close"),
            shutter_motion: screen_application::ResolvedShutterMotionSnapshot {
                temporal_samples: 1,
                readout: screen_application::SensorReadout::Global,
                neutral_density_stops: 0.0,
                noise_seed: 0,
            },
            shutter_motion_amount: 0.0,
            sensor: screen_sensor::SensorProfile::REFERENCE,
            radiometric_calibration: screen_application::CameraRadiometricCalibration::REFERENCE,
            sensor_enabled: false,
            sensor_noise_amount: 0.0,
            development: screen_camera::CameraDevelopment::NEUTRAL,
            development_enabled: false,
            frame_index: 0,
            requested_intermediate: PhysicalIntermediate::DevelopedAcesCg,
        },
    }
}

#[test]
fn domain_and_stage_amounts_have_independent_continuous_meaning() {
    let identity =
        evaluate_physical_pipeline_cpu_oracle(request(FlatPanelQuality::Native, 0.0, 4.0, 4.0))
            .expect("screen identity");
    assert_eq!(
        identity.acescg,
        request(FlatPanelQuality::Native, 0.0, 4.0, 4.0)
            .input
            .acescg
    );

    let ideal =
        evaluate_physical_pipeline_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 0.0, 0.0))
            .expect("stage identities");
    let continuous =
        evaluate_physical_pipeline_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 1.0, 0.0))
            .expect("continuous emission");
    let physical =
        evaluate_physical_pipeline_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 1.0, 1.0))
            .expect("physical geometry");
    assert_ne!(ideal.acescg, continuous.acescg);
    assert_ne!(continuous.acescg, physical.acescg);
    for pixel in &continuous.acescg[0..3] {
        for (sample, reference) in pixel.iter().zip(&continuous.acescg[0]) {
            assert!((sample - reference).abs() <= 1.0e-6);
        }
    }
    let artistic =
        evaluate_physical_pipeline_cpu_oracle(request(FlatPanelQuality::Native, 1.5, 2.0, 2.5))
            .expect("artistic extension");
    assert!(
        artistic
            .acescg
            .iter()
            .flatten()
            .all(|value| value.is_finite())
    );
}

#[test]
fn rgb_and_bgr_are_discrete_topologies_with_the_same_frame() {
    let rgb =
        evaluate_physical_pipeline_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 1.0, 1.0))
            .expect("RGB");
    let mut bgr_request = request(FlatPanelQuality::Native, 1.0, 1.0, 1.0);
    bgr_request.plan.panel.stripe_layout = StripeLayout::Bgr;
    let bgr = evaluate_physical_pipeline_cpu_oracle(bgr_request).expect("BGR");
    assert_eq!((rgb.width, rgb.height), (bgr.width, bgr.height));
    assert_ne!(rgb.acescg, bgr.acescg);
    assert_eq!(rgb.diagnostic.geometry.stripe_layout, StripeLayout::Rgb);
    assert_eq!(bgr.diagnostic.geometry.stripe_layout, StripeLayout::Bgr);
}

#[test]
fn quality_lattices_keep_frame_and_reach_the_native_authority() {
    let results = [
        FlatPanelQuality::Draft,
        FlatPanelQuality::Medium,
        FlatPanelQuality::High,
        FlatPanelQuality::Native,
    ]
    .map(|quality| {
        evaluate_physical_pipeline_cpu_oracle(request(quality, 1.0, 1.0, 1.0))
            .expect("quality result")
    });
    assert!(
        results
            .iter()
            .all(|value| (value.width, value.height) == (6, 3))
    );
    assert_eq!(
        results
            .each_ref()
            .map(|value| value.diagnostic.sampling.samples_per_output_pixel),
        [1, 4, 16, 1]
    );
    let high_native_maximum = results[2]
        .acescg
        .iter()
        .zip(&results[3].acescg)
        .flat_map(|(high, native)| {
            high.iter()
                .zip(native)
                .map(|(high, native)| (high - native).abs())
        })
        .fold(0.0_f32, f32::max);
    assert!(
        high_native_maximum <= 3.0e-5,
        "High/Native maximum deviation {high_native_maximum} exceeds the declared bound"
    );
}

#[test]
fn light_spread_zero_is_exact_and_calibrated_and_artistic_are_finite() {
    let baseline =
        evaluate_physical_pipeline_cpu_oracle(request(FlatPanelQuality::High, 1.0, 1.0, 1.0))
            .expect("unspread baseline");
    let mut zero = request(FlatPanelQuality::High, 1.0, 1.0, 1.0);
    zero.plan.panel_light_spread = PanelLightSpreadProfile {
        character_strength: 0.0,
        core_radius_micrometers: screen_contracts::LinearRgb::new(2.0, 3.0, 4.0),
        core_weight: screen_contracts::LinearRgb::new(0.4, 0.3, 0.2),
        tail_radius_micrometers: screen_contracts::LinearRgb::new(200.0, 300.0, 400.0),
        tail_weight: screen_contracts::LinearRgb::new(0.1, 0.1, 0.1),
    };
    assert_eq!(
        evaluate_physical_pipeline_cpu_oracle(zero)
            .expect("spread identity")
            .acescg,
        baseline.acescg
    );

    for amount in [1.0, 2.5] {
        let mut spread = request(FlatPanelQuality::High, 1.0, 1.0, 1.0);
        spread.plan.panel_light_spread = PanelLightSpreadProfile {
            character_strength: amount,
            ..PanelLightSpreadProfile::LCD_DESKTOP
        };
        let result = evaluate_physical_pipeline_cpu_oracle(spread).expect("spread result");
        assert!(
            result
                .acescg
                .iter()
                .flatten()
                .all(|value| value.is_finite())
        );
        assert_eq!(
            result
                .acescg
                .iter()
                .map(|pixel| pixel[3])
                .collect::<Vec<_>>(),
            baseline
                .acescg
                .iter()
                .map(|pixel| pixel[3])
                .collect::<Vec<_>>()
        );
    }
}

#[test]
fn requested_checkpoint_neutralizes_every_later_physical_stage() {
    let mut baseline = request(FlatPanelQuality::High, 1.0, 1.0, 1.0);
    baseline.plan.panel_light_spread = PanelLightSpreadProfile::LCD_DESKTOP;
    baseline.plan.requested_intermediate = PhysicalIntermediate::PanelLightSpread;
    let expected =
        evaluate_physical_pipeline_cpu_oracle(baseline.clone()).expect("panel-spread checkpoint");

    let mut later_stages_enabled = baseline;
    later_stages_enabled.plan.scene_geometry_amount = 1.0;
    later_stages_enabled.plan.lens_amount = 1.0;
    later_stages_enabled.plan.camera_position.x = 0.3;
    later_stages_enabled
        .plan
        .scene_geometry_lens
        .lens
        .radial_distortion = [0.2, -0.05, 0.01];
    later_stages_enabled.plan.cover = screen_cover::COVER_GLASS_PRESETS[1].profile;
    later_stages_enabled.plan.environment =
        screen_cover::environment_preset("environment-studio-softboxes")
            .expect("current environment")
            .environment;
    let stopped = evaluate_physical_pipeline_cpu_oracle(later_stages_enabled)
        .expect("stopped panel-spread checkpoint");
    assert_eq!(stopped.acescg, expected.acescg);

    let mut geometry = request(FlatPanelQuality::High, 1.0, 1.0, 1.0);
    geometry.plan.requested_intermediate = PhysicalIntermediate::RelativeGeometry;
    geometry.plan.scene_geometry_amount = 1.0;
    let expected_geometry = evaluate_physical_pipeline_cpu_oracle(geometry.clone())
        .expect("relative-geometry checkpoint");
    assert_ne!(expected_geometry.acescg, expected.acescg);
    geometry.plan.lens_amount = 1.0;
    geometry.plan.scene_geometry_lens.lens.radial_distortion = [0.2, -0.05, 0.01];
    geometry.plan.cover = screen_cover::COVER_GLASS_PRESETS[1].profile;
    geometry.plan.environment = screen_cover::environment_preset("environment-studio-softboxes")
        .expect("current environment")
        .environment;
    let stopped_geometry = evaluate_physical_pipeline_cpu_oracle(geometry)
        .expect("geometry checkpoint with later stages enabled");
    assert_eq!(stopped_geometry.acescg, expected_geometry.acescg);

    let mut cover_without_lens = request(FlatPanelQuality::High, 1.0, 1.0, 1.0);
    cover_without_lens.plan.requested_intermediate = PhysicalIntermediate::CoverEnvironment;
    cover_without_lens.plan.scene_geometry_amount = 1.0;
    cover_without_lens.plan.cover = screen_cover::COVER_GLASS_PRESETS[1].profile;
    let expected_cover = evaluate_physical_pipeline_cpu_oracle(cover_without_lens.clone())
        .expect("cover checkpoint");
    cover_without_lens.plan.lens_amount = 1.0;
    cover_without_lens
        .plan
        .scene_geometry_lens
        .lens
        .radial_distortion = [0.2, -0.05, 0.01];
    let stopped_cover = evaluate_physical_pipeline_cpu_oracle(cover_without_lens)
        .expect("cover checkpoint with later lens enabled");
    assert_eq!(stopped_cover.acescg, expected_cover.acescg);
}

#[test]
fn supported_intermediate_outputs_match_frozen_domain_goldens() {
    let mut hashes = Vec::new();
    for intermediate in [
        PhysicalIntermediate::SourceAcesCg,
        PhysicalIntermediate::DeviceSignal,
        PhysicalIntermediate::PanelEmission,
        PhysicalIntermediate::SubpixelRadiance,
        PhysicalIntermediate::PanelLightSpread,
        PhysicalIntermediate::DevelopedAcesCg,
    ] {
        let mut value = request(FlatPanelQuality::High, 1.0, 1.0, 1.0);
        value.input.device_signal.pixels = vec![
            DeviceRgb::new(0.1, 0.4, 0.8),
            DeviceRgb::new(1.2, -0.1, 0.3),
        ];
        value.plan.panel_light_spread = PanelLightSpreadProfile::LCD_DESKTOP;
        value.plan.requested_intermediate = intermediate;
        let result = evaluate_physical_pipeline_cpu_oracle(value).expect("intermediate");
        let hash = result
            .acescg
            .iter()
            .flatten()
            .fold(0xcbf2_9ce4_8422_2325_u64, |hash, sample| {
                (hash ^ u64::from(sample.to_bits())).wrapping_mul(0x0000_0100_0000_01b3)
            });
        hashes.push(hash);
    }
    assert_eq!(
        hashes,
        [
            17_533_449_732_142_382_789,
            7_175_188_628_288_640_885,
            1_821_817_943_419_426_288,
            7_822_282_370_568_033_078,
            7_008_296_159_193_486_740,
            16_849_740_274_292_448_334,
        ]
    );
}

#[test]
fn exact_shutter_schedule_preserves_bounds_for_one_and_many_samples() {
    let open = screen_contracts::RationalTime::new(1_001, 24_000).expect("open");
    let close = screen_contracts::RationalTime::new(2_002, 24_000).expect("close");
    for count in [1, 7] {
        let schedule = screen_application::physical_shutter_schedule(
            open,
            close,
            count,
            screen_application::SensorReadout::Global,
            4,
        )
        .expect("global schedule");
        assert_eq!(schedule.len(), usize::from(count));
        assert_eq!(schedule.first().expect("first").start, open);
        assert_eq!(schedule.last().expect("last").end, close);
        assert!(schedule.windows(2).all(|pair| pair[0].end == pair[1].start));
    }
}

#[test]
fn rolling_schedule_is_row_ordered_and_direction_reversible() {
    let open = screen_contracts::RationalTime::new(-1, 48).expect("open");
    let close = screen_contracts::RationalTime::new(1, 48).expect("close");
    let readout = screen_contracts::RationalTime::new(1, 24).expect("readout");
    let top = screen_application::physical_shutter_schedule(
        open,
        close,
        2,
        screen_application::SensorReadout::Rolling {
            duration: readout,
            direction: screen_application::RollingDirection::TopToBottom,
        },
        3,
    )
    .expect("top-down schedule");
    let bottom = screen_application::physical_shutter_schedule(
        open,
        close,
        2,
        screen_application::SensorReadout::Rolling {
            duration: readout,
            direction: screen_application::RollingDirection::BottomToTop,
        },
        3,
    )
    .expect("bottom-up schedule");
    assert_eq!(top.len(), 6);
    assert_eq!(
        top.iter().map(|sample| sample.row).collect::<Vec<_>>(),
        [Some(0), Some(0), Some(1), Some(1), Some(2), Some(2)]
    );
    assert_eq!(top[0].time, bottom[4].time);
    assert_eq!(top[4].time, bottom[0].time);
}

#[test]
fn raw_and_developed_intermediates_have_separate_frozen_domain_goldens() {
    let mut hashes = Vec::new();
    for intermediate in [
        PhysicalIntermediate::RawMosaic,
        PhysicalIntermediate::DevelopedAcesCg,
    ] {
        let mut value = request(FlatPanelQuality::High, 1.0, 1.0, 1.0);
        value.plan.sensor = screen_sensor::SensorProfile {
            native_width: 6,
            native_height: 3,
            ..screen_sensor::SensorProfile::REFERENCE
        };
        value.plan.sensor_enabled = true;
        value.plan.sensor_noise_amount = 0.0;
        value.plan.development = screen_camera::CameraDevelopment {
            white_balance: screen_contracts::LinearRgb::new(1.7, 1.0, 0.7),
            middle_gray_illuminance_seconds: 0.09,
            develop_exposure_ev: 0.5,
        };
        value.plan.development_enabled = intermediate == PhysicalIntermediate::DevelopedAcesCg;
        value.plan.shutter_motion_amount = 1.0;
        value.plan.requested_intermediate = intermediate;
        let result = evaluate_physical_pipeline_cpu_oracle(value).expect("capture intermediate");
        hashes.push(
            result
                .acescg
                .iter()
                .flatten()
                .fold(0xcbf2_9ce4_8422_2325_u64, |hash, sample| {
                    (hash ^ u64::from(sample.to_bits())).wrapping_mul(0x0000_0100_0000_01b3)
                }),
        );
    }
    // Sensor input restores absolute panel luminance after the lens has
    // applied its pupil throughput exactly once.
    assert_eq!(
        hashes,
        [14_388_517_383_653_141_572, 13_374_690_546_901_320_500]
    );
}
