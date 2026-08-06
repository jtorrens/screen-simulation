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
            scene_geometry_amount: 0.0,
            lens_amount: 0.0,
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
        assert_eq!(pixel, &continuous.acescg[0]);
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
    assert!(high_native_maximum <= 1.0e-5);
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
            15_685_145_297_129_364_453,
            2_562_316_643_544_865_759,
            17_584_836_761_831_715_200,
            1_095_139_996_456_996_558,
            5_832_955_122_466_670_301,
        ]
    );
}
