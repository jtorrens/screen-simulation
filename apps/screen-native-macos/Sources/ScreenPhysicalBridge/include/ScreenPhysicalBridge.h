#ifndef SCREEN_PHYSICAL_BRIDGE_H
#define SCREEN_PHYSICAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ScreenDeviceProfile *ScreenDeviceProfileRef;
typedef struct ScreenCoverGlassProfile *ScreenCoverGlassProfileRef;
typedef struct ScreenPhysicalPipelineSnapshot *ScreenPhysicalPipelineSnapshotRef;
typedef struct ScreenPhysicalTexture *ScreenPhysicalTextureRef;
typedef struct ScreenEnvironmentRadianceTexture *ScreenEnvironmentRadianceTextureRef;
typedef struct ScreenPhysicalTimedInputSetV2 *ScreenPhysicalTimedInputSetV2Ref;
typedef struct ScreenPhysicalCameraPoseTrackV2 *ScreenPhysicalCameraPoseTrackV2Ref;
typedef struct ScreenPhysicalScreenPoseTrackV2 *ScreenPhysicalScreenPoseTrackV2Ref;
typedef struct ScreenPhysicalFrameJob *ScreenPhysicalFrameJobRef;
typedef struct ScreenTestPageDescriptor *ScreenTestPageDescriptorRef;

#define SCREEN_PHYSICAL_FRAME_ABI_VERSION 11u
#define SCREEN_PHYSICAL_PARAMETER_HASH_SIZE 32u
#define SCREEN_AUTHORING_CATALOG_ABI_VERSION 4u

typedef struct {
    const uint8_t *bytes;
    size_t count;
} ScreenUTF8View;

#define SCREEN_TEST_AUTHORING_ABI_VERSION 13u

typedef enum {
    SCREEN_TEST_CONTROL_CHOICE = 0,
    SCREEN_TEST_CONTROL_SCALAR = 1,
} ScreenTestControlKind;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View input_transform_id;
    ScreenUTF8View output_signal_id;
    ScreenUTF8View device_id;
    ScreenUTF8View color_mode_id;
    float device_eotf_gamma;
    float white_luminance_nits;
    ScreenUTF8View placement_id;
    ScreenUTF8View preview_quality_id;
    float frame_rate;
    float subpixel_geometry_amount;
    float panel_uniformity_amount;
    float panel_light_spread_amount;
    ScreenUTF8View capture_preset_id;
    ScreenUTF8View geometry_mode_id;
    float camera_distance_meters;
    float camera_orbit_x_degrees;
    float camera_orbit_y_degrees;
    float camera_position_x_meters;
    float camera_position_y_meters;
    float camera_position_z_meters;
    float camera_rotation_x_degrees;
    float camera_rotation_y_degrees;
    float camera_rotation_z_degrees;
    float screen_position_x_meters;
    float screen_position_y_meters;
    float screen_position_z_meters;
    float screen_rotation_x_degrees;
    float screen_yaw_degrees;
    float screen_rotation_z_degrees;
    ScreenUTF8View cover_glass_preset_id;
    float cover_glass_amount;
    float cover_ag_microtexture_amount;
    ScreenUTF8View environment_preset_id;
    float environment_amount;
    float cover_glow_amount;
    ScreenUTF8View lens_preset_id;
    float lens_amount;
    bool autofocus_enabled;
    float focus_distance_meters;
    float f_stop;
    float exposure_time_seconds;
    float shutter_motion_amount;
    float computational_character_strength;
    float computational_exposure_count;
    float computational_bracket_spacing_stops;
    float sensor_bloom_amount;
    float sensor_bloom_crosstalk_fraction;
    float sensor_bloom_overflow_transfer_fraction;
    float sensor_noise_amount;
    float camera_look_exposure_ev;
    float camera_look_contrast;
    float camera_look_saturation;
    float camera_look_temperature_kelvin;
    float camera_look_tint;
} ScreenTestAuthoringSelectionV13;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenUTF8View effect_summary;
    ScreenUTF8View header_control_id;
    ScreenUTF8View input_artifact;
    ScreenUTF8View output_artifact;
    uint32_t preview_result;
} ScreenTestPhaseDescriptorV3;

typedef struct {
    uint32_t abi_version;
    uint32_t kind;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenUTF8View selected_id;
    ScreenUTF8View reset_id;
    float value;
    float reset_value;
    float minimum;
    float maximum;
    float step;
    bool slider_visible;
    ScreenUTF8View unit;
} ScreenTestControlDescriptorV5;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
} ScreenTestChoiceOptionV2;

bool screen_test_authoring_default_selection(
    ScreenUTF8View input_transform_id,
    ScreenUTF8View device_id,
    float frame_rate,
    ScreenTestAuthoringSelectionV13 *resolved,
    const char **error_message
);

ScreenTestPageDescriptorRef screen_test_page_descriptor_create(
    const ScreenTestAuthoringSelectionV13 *selection,
    const char **error_message
);
void screen_test_page_descriptor_release(ScreenTestPageDescriptorRef descriptor);
size_t screen_test_page_phase_count(ScreenTestPageDescriptorRef descriptor);
ScreenUTF8View screen_test_page_default_preview_phase_id(
    ScreenTestPageDescriptorRef descriptor
);
bool screen_test_page_phase_descriptor(
    ScreenTestPageDescriptorRef descriptor,
    size_t phase_index,
    ScreenTestPhaseDescriptorV3 *phase
);
size_t screen_test_page_control_count(
    ScreenTestPageDescriptorRef descriptor,
    size_t phase_index
);
bool screen_test_page_control_descriptor(
    ScreenTestPageDescriptorRef descriptor,
    size_t phase_index,
    size_t control_index,
    ScreenTestControlDescriptorV5 *control
);
size_t screen_test_page_choice_option_count(
    ScreenTestPageDescriptorRef descriptor,
    size_t phase_index,
    size_t control_index
);
bool screen_test_page_choice_option(
    ScreenTestPageDescriptorRef descriptor,
    size_t phase_index,
    size_t control_index,
    size_t option_index,
    ScreenTestChoiceOptionV2 *option
);
size_t screen_test_page_preview_control_count(ScreenTestPageDescriptorRef descriptor);
bool screen_test_page_preview_control_descriptor(
    ScreenTestPageDescriptorRef descriptor,
    size_t control_index,
    ScreenTestControlDescriptorV5 *control
);
size_t screen_test_page_preview_choice_option_count(
    ScreenTestPageDescriptorRef descriptor,
    size_t control_index
);
bool screen_test_page_preview_choice_option(
    ScreenTestPageDescriptorRef descriptor,
    size_t control_index,
    size_t option_index,
    ScreenTestChoiceOptionV2 *option
);
bool screen_test_authoring_apply_choice(
    const ScreenTestAuthoringSelectionV13 *selection,
    ScreenUTF8View control_id,
    ScreenUTF8View option_id,
    ScreenTestAuthoringSelectionV13 *resolved,
    const char **error_message
);
bool screen_test_authoring_apply_scalar(
    const ScreenTestAuthoringSelectionV13 *selection,
    ScreenUTF8View control_id,
    float value,
    ScreenTestAuthoringSelectionV13 *resolved,
    const char **error_message
);
bool screen_test_authoring_apply_toggle(
    const ScreenTestAuthoringSelectionV13 *selection,
    ScreenUTF8View control_id,
    bool value,
    ScreenTestAuthoringSelectionV13 *resolved,
    const char **error_message
);

typedef enum {
    SCREEN_PHYSICAL_QUALITY_DRAFT = 0,
    SCREEN_PHYSICAL_QUALITY_MEDIUM = 1,
    SCREEN_PHYSICAL_QUALITY_HIGH = 2,
    SCREEN_PHYSICAL_QUALITY_NATIVE = 3,
} ScreenPhysicalQuality;

typedef enum {
    SCREEN_PHYSICAL_DOMAIN_SCREEN = 0x100,
    SCREEN_PHYSICAL_DOMAIN_CAPTURE = 0x200,
} ScreenPhysicalDomainID;

typedef enum {
    SCREEN_PHYSICAL_STAGE_SCREEN_EMISSION = 0x101,
    SCREEN_PHYSICAL_STAGE_SCREEN_SUBPIXEL_GEOMETRY = 0x102,
    SCREEN_PHYSICAL_STAGE_SCREEN_UNIFORMITY = 0x108,
    SCREEN_PHYSICAL_STAGE_SCREEN_LIGHT_SPREAD = 0x103,
    SCREEN_PHYSICAL_STAGE_SCREEN_TEMPORAL = 0x104,
    SCREEN_PHYSICAL_STAGE_SCREEN_COVER_GLASS = 0x105,
    SCREEN_PHYSICAL_STAGE_SCREEN_ENVIRONMENT = 0x106,
    SCREEN_PHYSICAL_STAGE_SCREEN_COVER_GLOW = 0x107,
    SCREEN_PHYSICAL_STAGE_CAPTURE_GEOMETRY = 0x201,
    SCREEN_PHYSICAL_STAGE_CAPTURE_LENS = 0x202,
    SCREEN_PHYSICAL_STAGE_CAPTURE_EXPOSURE_SHUTTER = 0x203,
    SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_CFA = 0x204,
    SCREEN_PHYSICAL_STAGE_CAPTURE_NOISE = 0x205,
    SCREEN_PHYSICAL_STAGE_CAPTURE_DEVELOP_DEMOSAIC = 0x206,
    SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_BLOOM = 0x207,
    SCREEN_PHYSICAL_STAGE_CAPTURE_COMPUTATIONAL_CAPTURE = 0x208,
} ScreenPhysicalStageID;

typedef enum {
    SCREEN_PHYSICAL_CONTROL_CONTINUOUS = 0,
    SCREEN_PHYSICAL_CONTROL_DISCRETE = 1,
} ScreenPhysicalControlSemantics;

typedef enum {
    SCREEN_PHYSICAL_STATE_IDLE = 0,
    SCREEN_PHYSICAL_STATE_STALE = 1,
    SCREEN_PHYSICAL_STATE_RENDERING = 2,
    SCREEN_PHYSICAL_STATE_CANCELLED = 3,
    SCREEN_PHYSICAL_STATE_FAILED = 4,
    SCREEN_PHYSICAL_STATE_COMPLETE = 5,
} ScreenPhysicalFrameState;

typedef enum {
    SCREEN_PHYSICAL_RASTER_FIT = 0,
    SCREEN_PHYSICAL_RASTER_FILL_CROP = 1,
    SCREEN_PHYSICAL_RASTER_STRETCH = 2,
    SCREEN_PHYSICAL_RASTER_ONE_TO_ONE = 3,
} ScreenPhysicalRasterPlacement;

typedef enum {
    SCREEN_PHYSICAL_SOURCE_SAMPLE_EXACT = 0,
    SCREEN_PHYSICAL_SOURCE_SAMPLE_FLOOR = 1,
    SCREEN_PHYSICAL_SOURCE_SAMPLE_NEAREST = 2,
} ScreenPhysicalSourceSamplingPolicy;

typedef enum {
    SCREEN_PHYSICAL_POSE_HOLD = 0,
    SCREEN_PHYSICAL_POSE_LINEAR = 1,
    SCREEN_PHYSICAL_POSE_SMOOTH = 2,
} ScreenPhysicalPoseInterpolation;

typedef enum {
    SCREEN_PHYSICAL_INTERMEDIATE_SOURCE_ACESCG = 0,
    SCREEN_PHYSICAL_INTERMEDIATE_DEVICE_SIGNAL = 1,
    SCREEN_PHYSICAL_INTERMEDIATE_PANEL_EMISSION = 2,
    SCREEN_PHYSICAL_INTERMEDIATE_SUBPIXEL_RADIANCE = 3,
    SCREEN_PHYSICAL_INTERMEDIATE_PANEL_UNIFORMITY = 4,
    SCREEN_PHYSICAL_INTERMEDIATE_PANEL_LIGHT_SPREAD = 5,
    SCREEN_PHYSICAL_INTERMEDIATE_RELATIVE_GEOMETRY = 6,
    SCREEN_PHYSICAL_INTERMEDIATE_COVER_ENVIRONMENT = 7,
    SCREEN_PHYSICAL_INTERMEDIATE_COVER_GLOW = 8,
    SCREEN_PHYSICAL_INTERMEDIATE_LENS_PROJECTION = 9,
    SCREEN_PHYSICAL_INTERMEDIATE_SHUTTER_MOTION = 10,
    SCREEN_PHYSICAL_INTERMEDIATE_COMPUTATIONAL_CAPTURE = 11,
    SCREEN_PHYSICAL_INTERMEDIATE_SENSOR_BLOOM = 12,
    SCREEN_PHYSICAL_INTERMEDIATE_SENSOR_NOISE = 13,
    SCREEN_PHYSICAL_INTERMEDIATE_RAW_MOSAIC = 14,
    SCREEN_PHYSICAL_INTERMEDIATE_DEVELOPED_ACESCG = 15,
    SCREEN_PHYSICAL_INTERMEDIATE_CAMERA_RENDERED_ACESCG = 16,
} ScreenPhysicalIntermediate;

typedef struct {
    uint64_t high;
    uint64_t low;
} ScreenPhysicalIdentity128;

typedef struct {
    uint32_t abi_version;
    uint32_t domain_id;
    uint32_t stage_id;
    uint32_t control_semantics;
    float amount;
    float visual_minimum;
    float visual_maximum;
    float safe_maximum;
    bool discrete_enabled;
    bool exact_identity_at_zero;
} ScreenPhysicalStageContributionV2;

typedef struct {
    uint32_t abi_version;
    int64_t time_numerator;
    uint32_t time_denominator;
    ScreenPhysicalTextureRef source_acescg;
    ScreenPhysicalTextureRef device_signal;
} ScreenPhysicalTimedInputSampleV2;

typedef struct {
    uint32_t abi_version;
    int64_t time_numerator;
    uint32_t time_denominator;
    float position[3];
    float rotation_xyzw[4];
    uint32_t interpolation;
} ScreenPhysicalPoseKnotV2;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    ScreenPhysicalTimedInputSetV2Ref timed_inputs;
    ScreenPhysicalTextureRef environment_acescg;
    ScreenPhysicalCameraPoseTrackV2Ref camera_pose_track;
    ScreenPhysicalScreenPoseTrackV2Ref screen_pose_track;
    int64_t shutter_open_numerator;
    uint32_t shutter_open_denominator;
    int64_t shutter_close_numerator;
    uint32_t shutter_close_denominator;
    ScreenDeviceProfileRef resolved_device;
    ScreenPhysicalPipelineSnapshotRef resolved_pipeline;
    uint32_t quality;
    float screen_amount;
    const ScreenPhysicalStageContributionV2 *stage_contributions;
    size_t stage_contribution_count;
    uint32_t requested_width;
    uint32_t requested_height;
    uint32_t requested_intermediate;
    ScreenPhysicalIdentity128 cancellation_identity;
    ScreenPhysicalIdentity128 progress_identity;
    uint64_t parameter_revision;
    uint8_t parameter_hash[SCREEN_PHYSICAL_PARAMETER_HASH_SIZE];
} ScreenPhysicalFrameRequestV2;

typedef struct {
    uint32_t abi_version;
    uint32_t domain_id;
    uint32_t stage_id;
    uint32_t state;
    float progress;
    uint64_t elapsed_nanoseconds;
    ScreenUTF8View message;
} ScreenPhysicalStageDiagnosticV2;

typedef struct {
    uint32_t abi_version;
    ScreenPhysicalTextureRef output_texture;
    uint32_t native_width;
    uint32_t native_height;
    uint32_t effective_width;
    uint32_t effective_height;
    uint32_t computed_quality;
    uint32_t returned_intermediate;
    uint32_t state;
    float progress;
    const ScreenPhysicalStageDiagnosticV2 *stage_diagnostics;
    size_t stage_diagnostic_count;
    uint64_t parameter_revision;
    uint8_t parameter_hash[SCREEN_PHYSICAL_PARAMETER_HASH_SIZE];
} ScreenPhysicalFrameResultV2;

typedef struct {
    uint32_t abi_version;
    uint32_t native_width;
    uint32_t native_height;
    uint32_t panel_technology;
    uint32_t stripe_layout;
    float active_width_meters;
    float active_height_meters;
    float black_matrix_fraction;
    float eotf_gamma;
    float black_level_nits;
    float white_level_nits;
    float primary_xy[6];
    float white_xy[2];
    float angular_emission_power[3];
    float uniformity_character_strength;
    uint32_t uniformity_seed;
    float uniformity_broad_luminance_peak_to_peak;
    float uniformity_mid_luminance_peak_to_peak;
    float uniformity_fine_luminance_peak_to_peak;
    float uniformity_chromatic_peak_to_peak;
    float uniformity_mid_scale_millimeters;
    float uniformity_fine_scale_millimeters;
    float uniformity_low_drive_emphasis;
    float light_spread_character_strength;
    float light_spread_core_radius_micrometers[3];
    float light_spread_core_weight[3];
    float light_spread_tail_radius_micrometers[3];
    float light_spread_tail_weight[3];
    int64_t residual_period_numerator;
    uint32_t residual_period_denominator;
    float residual_amplitude;
    int64_t residual_phase_numerator;
    uint32_t residual_phase_denominator;
    int64_t banding_period_numerator;
    uint32_t banding_period_denominator;
    int64_t banding_on_numerator;
    uint32_t banding_on_denominator;
    int64_t banding_phase_numerator;
    uint32_t banding_phase_denominator;
    float banding_amount;
} ScreenDeviceParametersV3;

typedef struct {
    uint32_t abi_version;
    uint32_t authority;
    float character_strength;
    float thickness_millimeters;
    float refractive_index;
    float anti_reflective_efficiency;
    float absorption_per_millimeter[3];
    float roughness;
    float haze;
    float ag_microtexture_character_strength;
    float ag_microtexture_rms_slope;
    float ag_microtexture_correlation_length_micrometers;
    float ag_microtexture_anisotropy;
    uint32_t ag_microtexture_seed;
    float glow_character_strength;
    float glow_scatter_fraction;
    float glow_core_radius_millimeters;
    float glow_tail_radius_millimeters;
    float glow_tail_fraction;
} ScreenCoverGlassParametersV2;

typedef struct {
    uint32_t abi_version;
    uint32_t source_kind;
    float character_strength;
    float source_unit_radiance_candelas_per_square_meter;
    float exposure_stops;
    float ambient_radiance_acescg[3];
    float key_radiance_acescg[3];
    float key_direction_local[3];
    float key_angular_radius_degrees;
    float rotation_degrees;
    uint32_t pattern;
} ScreenEnvironmentParametersV2;

typedef struct {
    uint32_t abi_version;
    uint32_t lens_evaluation_model;
    float focal_length_millimeters;
    float sensor_width_millimeters;
    float sensor_height_millimeters;
    float lens_shift[2];
    float focus_distance_meters;
    float f_stop;
    float near_clip_meters;
    float far_clip_meters;
    float lens_radial_distortion[3];
    float lens_tangential_distortion[2];
    float lens_longitudinal_chromatic_meters[3];
    float lens_lateral_chromatic_scale[3];
    float lens_vignetting_strength;
    float lens_transmission_rgb[3];
    float lens_center_softness_micrometers;
    float lens_edge_softness_micrometers;
    float lens_veiling_glare_fraction;
} ScreenSceneGeometryLensParametersV2;

typedef struct {
    uint32_t abi_version;
    uint16_t temporal_samples;
    uint16_t readout_kind;
    int64_t readout_duration_numerator;
    uint32_t readout_duration_denominator;
    uint32_t readout_direction;
    float neutral_density_stops;
    uint64_t noise_seed;
} ScreenShutterMotionParametersV2;

typedef struct {
    uint32_t abi_version;
    uint32_t native_width;
    uint32_t native_height;
    uint32_t bayer_pattern;
    float acescg_to_sensor[9];
    float saturation_illuminance_seconds[3];
    float full_well_electrons;
    float dark_current_electrons_per_second;
    float read_noise_electrons_rms;
    float analog_gain;
    uint32_t adc_bits;
    float bloom_character_strength;
    float bloom_crosstalk_fraction;
    float bloom_overflow_transfer_fraction;
} ScreenSensorNoiseParametersV2;

typedef struct {
    uint32_t abi_version;
    uint32_t exposure_count;
    float bracket_spacing_stops;
} ScreenComputationalCaptureParametersV3;

// Explicit conversion between panel/scene photometry and the effective
// exposure domain of the selected sensor profile. It is calibration data, not
// a display or preview gain.
typedef struct {
    uint32_t abi_version;
    float base_exposure_index;
    float reference_lambertian_reflectance;
    float reference_illuminance_lux;
    float reference_t_stop;
    float reference_shutter_seconds;
    float effective_sensor_exposure_scale;
} ScreenCameraRadiometricCalibrationV2;

typedef struct {
    uint32_t abi_version;
    float white_balance[3];
    float middle_gray_illuminance_seconds;
    float develop_exposure_ev;
} ScreenRawDevelopParametersV2;

typedef struct {
    uint32_t abi_version;
    float exposure_ev;
    float contrast;
    float saturation;
    float temperature_kelvin;
    float tint;
} ScreenCameraRenderingIntentParametersV1;

typedef struct {
    uint32_t abi_version;
    ScreenSensorNoiseParametersV2 sensor;
    ScreenComputationalCaptureParametersV3 computational_capture;
    ScreenCameraRenderingIntentParametersV1 camera_rendering_intent;
    float gate_width_millimeters;
    float gate_height_millimeters;
    float default_f_stop;
    float reference_exposure_index;
    float middle_gray_illuminance_seconds;
    float default_shutter_angle_degrees;
    uint16_t default_temporal_samples;
    uint16_t lens_association_policy;
    float default_readout_duration_milliseconds;
    ScreenCameraRadiometricCalibrationV2 radiometric_calibration;
} ScreenCapturePresetParametersV2;

typedef struct {
    uint32_t abi_version;
    float nominal_focal_length_millimeters;
    float radial_distortion[3];
    float tangential_distortion[2];
    float longitudinal_chromatic_meters[3];
    float lateral_chromatic_scale[3];
    float vignetting_strength;
    float transmission_rgb[3];
    float center_softness_micrometers;
    float edge_softness_micrometers;
    float veiling_glare_fraction;
} ScreenLensPresetParametersV1;

typedef struct {
    uint32_t abi_version;
    ScreenCoverGlassParametersV2 cover;
    ScreenEnvironmentParametersV2 environment;
    ScreenSceneGeometryLensParametersV2 scene_geometry_lens;
    ScreenShutterMotionParametersV2 shutter_motion;
    ScreenComputationalCaptureParametersV3 computational_capture;
    ScreenSensorNoiseParametersV2 sensor_noise;
    ScreenRawDevelopParametersV2 raw_develop;
    ScreenCameraRenderingIntentParametersV1 camera_rendering_intent;
    ScreenCameraRadiometricCalibrationV2 radiometric_calibration;
} ScreenPhysicalPipelineParametersV2;

size_t screen_cover_glass_preset_count(void);
ScreenUTF8View screen_cover_glass_preset_id(size_t index);
ScreenUTF8View screen_cover_glass_preset_label(size_t index);
bool screen_cover_glass_preset_parameters(
    size_t index,
    ScreenCoverGlassParametersV2 *parameters
);
size_t screen_environment_preset_count(void);
ScreenUTF8View screen_environment_preset_id(size_t index);
ScreenUTF8View screen_environment_preset_label(size_t index);
bool screen_environment_preset_parameters(
    size_t index,
    ScreenEnvironmentParametersV2 *parameters
);
ScreenCoverGlassProfileRef screen_cover_glass_profile_create(
    const ScreenCoverGlassParametersV2 *parameters,
    const char **error_message
);
void screen_cover_glass_profile_release(ScreenCoverGlassProfileRef profile);
ScreenPhysicalPipelineSnapshotRef screen_physical_pipeline_snapshot_create(
    const ScreenPhysicalPipelineParametersV2 *parameters,
    const char **error_message
);
void screen_physical_pipeline_snapshot_release(ScreenPhysicalPipelineSnapshotRef snapshot);

size_t screen_device_preset_count(void);
ScreenUTF8View screen_device_preset_id(size_t index);
ScreenUTF8View screen_device_preset_label(size_t index);
ScreenUTF8View screen_device_preset_category(size_t index);
ScreenUTF8View screen_device_preset_white_basis(size_t index);
size_t screen_device_preset_color_mode_count(size_t index);
ScreenUTF8View screen_device_preset_color_mode_id(
    size_t index,
    size_t color_mode_index
);
ScreenUTF8View screen_device_preset_default_color_mode_id(size_t index);
float screen_device_preset_minimum_white_nits(size_t index);
float screen_device_preset_maximum_white_nits(size_t index);
float screen_device_preset_white_step_nits(size_t index);
ScreenUTF8View screen_device_preset_default_cover_id(size_t index);
bool screen_device_preset_parameters(
    size_t index,
    ScreenDeviceParametersV3 *parameters
);
ScreenDeviceProfileRef screen_device_profile_create(
    const ScreenDeviceParametersV3 *parameters,
    const char **error_message
);
void screen_device_profile_release(ScreenDeviceProfileRef profile);
size_t screen_capture_preset_count(void);
ScreenUTF8View screen_capture_preset_id(size_t index);
ScreenUTF8View screen_capture_preset_label(size_t index);
ScreenUTF8View screen_capture_preset_calibration(size_t index);
ScreenUTF8View screen_capture_preset_default_lens_id(size_t index);
size_t screen_capture_preset_compatible_lens_count(size_t index);
ScreenUTF8View screen_capture_preset_compatible_lens_id(
    size_t index,
    size_t lens_index
);
bool screen_capture_preset_parameters(
    size_t index,
    ScreenCapturePresetParametersV2 *parameters
);
size_t screen_lens_preset_count(void);
ScreenUTF8View screen_lens_preset_id(size_t index);
ScreenUTF8View screen_lens_preset_label(size_t index);
uint32_t screen_lens_preset_authority(size_t index);
bool screen_lens_preset_parameters(
    size_t index,
    ScreenLensPresetParametersV1 *parameters
);
/*
 * Physical-frame ABI v3. These declarations are the single UI/engine contract.
 * The immutable timed input set retains every source linear ACEScg texture and
 * matching nonlinear device-signal texture resolved by StudioColor until its
 * release. A submitted job retains the selected Metal textures independently,
 * so the set and its lightweight wrappers may be released after submit. Pose
 * tracks and shutter bounds are exact rational-time inputs. Result textures
 * contain linear ACEScg RGBA. The engine
 * never applies a preview, DeckLink or render ODT. Texture/result views are
 * borrowed for the documented lifetime of their owning opaque handle; no
 * per-pixel ABI exists.
 */
ScreenPhysicalTextureRef screen_physical_texture_create_borrowed_metal(
    const void *metal_texture,
    const char **error_message
);
const void *screen_physical_texture_borrow_metal(ScreenPhysicalTextureRef texture);
void screen_physical_texture_release(ScreenPhysicalTextureRef texture);
ScreenEnvironmentRadianceTextureRef screen_environment_radiance_texture_create_metal(
    const void *source_metal_texture,
    const char **error_message
);
ScreenPhysicalTextureRef screen_environment_radiance_texture_borrow_physical(
    ScreenEnvironmentRadianceTextureRef texture
);
void screen_environment_radiance_texture_release(
    ScreenEnvironmentRadianceTextureRef texture
);
ScreenPhysicalTimedInputSetV2Ref screen_physical_timed_input_set_v2_create(
    const ScreenPhysicalTimedInputSampleV2 *samples,
    size_t sample_count,
    uint32_t raster_placement,
    uint32_t sampling_policy,
    const char **error_message
);
void screen_physical_timed_input_set_v2_release(ScreenPhysicalTimedInputSetV2Ref input);
ScreenPhysicalCameraPoseTrackV2Ref screen_physical_camera_pose_track_v2_create(
    const ScreenPhysicalPoseKnotV2 *knots,
    size_t knot_count,
    const char **error_message
);
ScreenPhysicalScreenPoseTrackV2Ref screen_physical_screen_pose_track_v2_create(
    const ScreenPhysicalPoseKnotV2 *knots,
    size_t knot_count,
    const char **error_message
);
void screen_physical_camera_pose_track_v2_release(ScreenPhysicalCameraPoseTrackV2Ref track);
void screen_physical_screen_pose_track_v2_release(ScreenPhysicalScreenPoseTrackV2Ref track);
ScreenPhysicalFrameJobRef screen_physical_frame_submit(
    const ScreenPhysicalFrameRequestV2 *request,
    const char **error_message
);
bool screen_physical_frame_job_cancel(
    ScreenPhysicalFrameJobRef job,
    ScreenPhysicalIdentity128 cancellation_identity
);
bool screen_physical_frame_job_snapshot(
    ScreenPhysicalFrameJobRef job,
    ScreenPhysicalFrameResultV2 *result,
    const char **error_message
);
void screen_physical_frame_job_release(ScreenPhysicalFrameJobRef job);

bool screen_test_pattern_dimensions(
    uint32_t pattern,
    uint32_t *width,
    uint32_t *height
);
bool screen_test_pattern_render_rgba32f(
    uint32_t pattern,
    double time_seconds,
    float *pixels,
    size_t pixel_count,
    const char **error_message
);

bool screen_openexr_encode_rgba_half(
    const float *pixels,
    uint32_t width,
    uint32_t height,
    uint8_t **encoded_bytes,
    size_t *encoded_byte_count,
    char **error_message
);
bool screen_openexr_decode_rgba_float(
    const char *file_path,
    float **pixels,
    uint32_t *width,
    uint32_t *height,
    char **declared_color_space,
    char **error_message
);
void screen_openexr_free(void *pointer);

#endif
