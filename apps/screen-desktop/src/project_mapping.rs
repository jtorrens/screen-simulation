use screen_contracts::{LinearRgb, Meters, Millimeters, RationalTime, Vec2, Vec3};
use screen_geometry::{
    CameraIntrinsicsKeyframe, CameraIntrinsicsTrack, CameraRig, KeyframeInterpolation, LensModel,
    Quaternion, ScreenTrack, TransformKeyframe, TransformTrack,
};
use screen_panel::{Chromaticity, LcdProfile, PanelColorimetry, StripeLayout};
use screen_persistence::{
    CameraIntrinsicsKeyframe as StoredIntrinsics, ExactTime, InterpolationSelection,
    ProjectPackage, StripeSelection, TransformKeyframe as StoredTransform,
};

pub struct ProjectScene {
    pub panel: LcdProfile,
    pub camera: CameraRig,
    pub screen: ScreenTrack,
}

pub fn map_project_scene(package: &ProjectPackage) -> Result<ProjectScene, String> {
    package.validate().map_err(|error| error.to_string())?;
    let device = &package.device;
    let xy = |value: [f32; 2]| Chromaticity {
        x: value[0],
        y: value[1],
    };
    let scene = ProjectScene {
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
            channel_efficiency: LinearRgb::new(
                device.channel_efficiency[0],
                device.channel_efficiency[1],
                device.channel_efficiency[2],
            ),
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
