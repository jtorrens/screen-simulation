use screen_application::{
    DeviceSignalRaster, FlatPanelInput, FlatPanelPlan, FlatPanelRequest, RasterPlacement,
    evaluate_flat_panel_cpu_oracle,
};
use screen_contracts::{DeviceRgb, Meters};
use screen_panel::{DEVICE_PRESETS, FlatPanelQuality, StripeLayout};

fn request(
    quality: FlatPanelQuality,
    screen_amount: f32,
    emission_amount: f32,
    geometry_amount: f32,
) -> FlatPanelRequest {
    let mut panel = DEVICE_PRESETS[0].profile();
    panel.native_width = 2;
    panel.native_height = 1;
    panel.active_width = Meters(0.002);
    panel.active_height = Meters(0.001);
    let acescg = vec![[1.5, -0.25, 0.5, 0.25], [0.0, 0.5, 2.0, 0.75]];
    FlatPanelRequest {
        input: FlatPanelInput {
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
        plan: FlatPanelPlan {
            panel,
            placement: RasterPlacement::Stretch,
            quality,
            requested_width: 6,
            requested_height: 1,
            screen_amount,
            emission_amount,
            subpixel_geometry_amount: geometry_amount,
        },
    }
}

#[test]
fn domain_and_stage_amounts_have_independent_continuous_meaning() {
    let identity = evaluate_flat_panel_cpu_oracle(request(FlatPanelQuality::Native, 0.0, 4.0, 4.0))
        .expect("screen identity");
    assert_eq!(
        identity.acescg,
        request(FlatPanelQuality::Native, 0.0, 4.0, 4.0)
            .input
            .acescg
    );

    let ideal = evaluate_flat_panel_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 0.0, 0.0))
        .expect("stage identities");
    let continuous =
        evaluate_flat_panel_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 1.0, 0.0))
            .expect("continuous emission");
    let physical = evaluate_flat_panel_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 1.0, 1.0))
        .expect("physical geometry");
    assert_ne!(ideal.acescg, continuous.acescg);
    assert_ne!(continuous.acescg, physical.acescg);
    for pixel in &continuous.acescg[0..3] {
        assert_eq!(pixel, &continuous.acescg[0]);
    }
    let artistic = evaluate_flat_panel_cpu_oracle(request(FlatPanelQuality::Native, 1.5, 2.0, 2.5))
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
    let rgb = evaluate_flat_panel_cpu_oracle(request(FlatPanelQuality::Native, 1.0, 1.0, 1.0))
        .expect("RGB");
    let mut bgr_request = request(FlatPanelQuality::Native, 1.0, 1.0, 1.0);
    bgr_request.plan.panel.stripe_layout = StripeLayout::Bgr;
    let bgr = evaluate_flat_panel_cpu_oracle(bgr_request).expect("BGR");
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
        evaluate_flat_panel_cpu_oracle(request(quality, 1.0, 1.0, 1.0)).expect("quality result")
    });
    assert!(
        results
            .iter()
            .all(|value| (value.width, value.height) == (6, 1))
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
