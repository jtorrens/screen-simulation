#ifndef SCREEN_PHYSICAL_BRIDGE_H
#define SCREEN_PHYSICAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ScreenDeviceProfile *ScreenDeviceProfileRef;
typedef struct ScreenCoverGlassProfile *ScreenCoverGlassProfileRef;
typedef struct ScreenPhysicalPipelineSnapshot *ScreenPhysicalPipelineSnapshotRef;
typedef struct ScreenPhysicalTexture *ScreenPhysicalTextureRef;
typedef struct ScreenAdjustedSceneTexture *ScreenAdjustedSceneTextureRef;
typedef struct ScreenEnvironmentRadianceTexture *ScreenEnvironmentRadianceTextureRef;
typedef struct ScreenPhysicalTimedInputSetV2 *ScreenPhysicalTimedInputSetV2Ref;
typedef struct ScreenPhysicalCameraPoseTrackV2 *ScreenPhysicalCameraPoseTrackV2Ref;
typedef struct ScreenPhysicalCameraIntrinsicsTrackV1 *ScreenPhysicalCameraIntrinsicsTrackV1Ref;
typedef struct ScreenPhysicalScreenPoseTrackV2 *ScreenPhysicalScreenPoseTrackV2Ref;
typedef struct ScreenSceneFrameResolverV1 *ScreenSceneFrameResolverV1Ref;
typedef struct ScreenPreparedRenderV1 *ScreenPreparedRenderV1Ref;
typedef struct ScreenPhysicalFrameJob *ScreenPhysicalFrameJobRef;
typedef struct ScreenTestPageDescriptor *ScreenTestPageDescriptorRef;
typedef struct ScreenTestAuthoringProfileContext *ScreenTestAuthoringProfileContextRef;

#define SCREEN_PHYSICAL_FRAME_ABI_VERSION 36u
#define SCREEN_DEVICE_VFX_ALPHA_IGNORE 0u
#define SCREEN_DEVICE_VFX_ALPHA_TRANSPARENCY 1u
#define SCREEN_PLANAR_REFERENCE_MATCH_ABI_VERSION 1u
#define SCREEN_PHYSICAL_PARAMETER_HASH_SIZE 32u
#define SCREEN_AUTHORING_CATALOG_ABI_VERSION 10u
#define SCREEN_RECORDING_EXECUTION_PLAN_ABI_VERSION 2u
#define SCREEN_FFMPEG_MEDIA_ABI_VERSION 1u

typedef struct {
    const uint8_t *bytes;
    size_t count;
} ScreenUTF8View;

typedef struct {
    uint32_t abi_version;
    uint32_t adapter_kind;
    uint32_t medium;
    uint32_t bit_depth;
    uint32_t chroma_sampling;
    uint32_t rate_control_kind;
    float quality;
    uint32_t quantizer;
    uint64_t bits_per_second;
} ScreenRecordingExecutionPlanV2;

typedef struct {
    uint32_t abi_version;
    uint32_t width;
    uint32_t height;
    uint32_t frame_rate_numerator;
    uint32_t frame_rate_denominator;
    int64_t duration_numerator;
    uint32_t duration_denominator;
    bool has_duration;
    bool has_alpha;
    /* 0 RGB, 1 YUV, 2 monochrome. */
    uint32_t pixel_encoding;
} ScreenFfmpegMediaInfoV1;

typedef struct {
    float *pixels_rgba;
    uint32_t width;
    uint32_t height;
    int64_t timestamp_numerator;
    uint32_t timestamp_denominator;
} ScreenFfmpegDecodedFrameV1;

#define SCREEN_TEST_AUTHORING_ABI_VERSION 40u

typedef enum {
    SCREEN_TEST_CONTROL_CHOICE = 0,
    SCREEN_TEST_CONTROL_SCALAR = 1,
    SCREEN_TEST_CONTROL_ACTION = 3,
} ScreenTestControlKind;

typedef struct {
    ScreenUTF8View id;
    ScreenUTF8View label;
    uint32_t width;
    uint32_t height;
} ScreenCaptureRasterModeV1;

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
    uint32_t frame_rate_numerator;
    uint32_t frame_rate_denominator;
    float source_exposure_ev;
    float source_contrast;
    float source_saturation;
    float source_temperature_kelvin;
    float source_tint;
    float subpixel_geometry_amount;
    float moire_intensity;
    float moire_saturation;
    float moire_filter_strength;
    float panel_uniformity_amount;
    float panel_light_spread_amount;
    ScreenUTF8View capture_preset_id;
    ScreenUTF8View capture_raster_mode_id;
    ScreenUTF8View lens_evaluation_model_id;
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
    float cover_thickness_millimeters;
    float cover_refractive_index;
    float cover_ar_efficiency;
    float cover_absorption_rgb[3];
    float cover_roughness;
    float cover_haze;
    float cover_ag_rms_slope;
    float cover_ag_correlation_micrometers;
    float cover_ag_anisotropy;
    ScreenUTF8View environment_source_id;
    float environment_amount;
    float environment_rotation_x_degrees;
    float environment_rotation_y_degrees;
    float environment_anchor_longitude_degrees;
    float environment_anchor_latitude_degrees;
    float environment_tangent_transform[4];
    float environment_exposure_ev;
    float environment_contrast;
    float environment_saturation;
    float environment_temperature_kelvin;
    float environment_tint;
    ScreenUTF8View environment_projection_id;
    float environment_sphere_center_x_meters;
    float environment_sphere_center_y_meters;
    float environment_sphere_center_z_meters;
    float environment_sphere_radius_meters;
    float cover_glow_amount;
    float cover_glow_intensity;
    float cover_glow_radius_millimeters;
    float cover_glow_threshold_relative_white;
    float cover_glow_exterior_intensity;
    ScreenUTF8View lens_preset_id;
    float focal_length_millimeters;
    float lens_amount;
    bool autofocus_enabled;
    float autofocus_target_u;
    float autofocus_target_v;
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
    ScreenUTF8View device_vfx_alpha_mode_id;
    ScreenUTF8View delivery_preset_id;
    uint32_t delivery_width;
    uint32_t delivery_height;
    ScreenUTF8View delivery_placement_id;
    ScreenUTF8View delivery_background_id;
    ScreenUTF8View recording_output_transform_id;
    ScreenUTF8View recording_profile_id;
    float recording_character;
} ScreenTestAuthoringSelectionV23;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenUTF8View effect_summary;
    ScreenUTF8View header_control_id;
    ScreenUTF8View input_artifact;
    ScreenUTF8View output_artifact;
    uint32_t preview_result;
    bool has_physical_intermediate;
    uint32_t physical_intermediate;
    ScreenUTF8View calculation_domain;
    ScreenUTF8View preview_route;
} ScreenTestPhaseDescriptorV5;

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
    uint32_t frame_rate_numerator,
    uint32_t frame_rate_denominator,
    ScreenTestAuthoringSelectionV23 *resolved,
    const char **error_message
);
bool screen_test_authoring_default_selection_with_profiles(
    ScreenTestAuthoringProfileContextRef context,
    ScreenUTF8View input_transform_id,
    ScreenUTF8View device_id,
    uint32_t frame_rate_numerator,
    uint32_t frame_rate_denominator,
    ScreenTestAuthoringSelectionV23 *resolved,
    const char **error_message
);

ScreenTestPageDescriptorRef screen_test_page_descriptor_create(
    const ScreenTestAuthoringSelectionV23 *selection,
    const char **error_message
);
ScreenTestPageDescriptorRef screen_test_page_descriptor_create_with_profiles(
    ScreenTestAuthoringProfileContextRef context,
    const ScreenTestAuthoringSelectionV23 *selection,
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
    ScreenTestPhaseDescriptorV5 *phase
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
size_t screen_test_page_quick_control_count(ScreenTestPageDescriptorRef descriptor);
size_t screen_test_page_visible_preview_choice_count(ScreenTestPageDescriptorRef descriptor);
ScreenUTF8View screen_test_page_visible_preview_choice_id(
    ScreenTestPageDescriptorRef descriptor,
    size_t choice_index
);
ScreenUTF8View screen_test_page_quick_control_id(
    ScreenTestPageDescriptorRef descriptor,
    size_t control_index
);
ScreenUTF8View screen_test_page_featured_phase_id(ScreenTestPageDescriptorRef descriptor);
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
    const ScreenTestAuthoringSelectionV23 *selection,
    ScreenUTF8View control_id,
    ScreenUTF8View option_id,
    ScreenTestAuthoringSelectionV23 *resolved,
    const char **error_message
);
bool screen_test_authoring_apply_choice_with_profiles(
    ScreenTestAuthoringProfileContextRef context,
    const ScreenTestAuthoringSelectionV23 *selection,
    ScreenUTF8View control_id,
    ScreenUTF8View option_id,
    ScreenTestAuthoringSelectionV23 *resolved,
    const char **error_message
);
bool screen_test_authoring_apply_scalar(
    const ScreenTestAuthoringSelectionV23 *selection,
    ScreenUTF8View control_id,
    float value,
    ScreenTestAuthoringSelectionV23 *resolved,
    const char **error_message
);
bool screen_test_authoring_apply_scalar_with_profiles(
    ScreenTestAuthoringProfileContextRef context,
    const ScreenTestAuthoringSelectionV23 *selection,
    ScreenUTF8View control_id,
    float value,
    ScreenTestAuthoringSelectionV23 *resolved,
    const char **error_message
);
bool screen_test_authoring_apply_toggle(
    const ScreenTestAuthoringSelectionV23 *selection,
    ScreenUTF8View control_id,
    bool value,
    ScreenTestAuthoringSelectionV23 *resolved,
    const char **error_message
);
bool screen_test_authoring_apply_toggle_with_profiles(
    ScreenTestAuthoringProfileContextRef context,
    const ScreenTestAuthoringSelectionV23 *selection,
    ScreenUTF8View control_id,
    bool value,
    ScreenTestAuthoringSelectionV23 *resolved,
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
    SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_COLLECTION = 0x204,
    SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_READOUT = 0x205,
    SCREEN_PHYSICAL_STAGE_CAPTURE_DEVELOP_DEMOSAIC = 0x206,
    SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_BLOOM = 0x207,
    SCREEN_PHYSICAL_STAGE_CAPTURE_COMPUTATIONAL_CAPTURE = 0x208,
} ScreenPhysicalStageID;

typedef enum {
    SCREEN_PHYSICAL_CONTROL_CONTINUOUS = 0,
    SCREEN_PHYSICAL_CONTROL_DISCRETE = 1,
} ScreenPhysicalControlSemantics;

typedef struct {
    uint32_t abi_version;
    uint32_t domain_id;
    uint32_t stage_id;
    uint32_t control_semantics;
    float visual_minimum;
    float visual_maximum;
    float safe_maximum;
    bool exact_identity_at_zero;
    bool general_overview;
} ScreenPhysicalStageDescriptorV1;

size_t screen_physical_stage_descriptor_count(void);
bool screen_physical_stage_descriptor(
    size_t index,
    ScreenPhysicalStageDescriptorV1 *descriptor
);

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
    SCREEN_PHYSICAL_INTERMEDIATE_SENSOR_COLLECTION = 12,
    SCREEN_PHYSICAL_INTERMEDIATE_SENSOR_BLOOM = 13,
    SCREEN_PHYSICAL_INTERMEDIATE_SENSOR_READOUT_RAW = 14,
    SCREEN_PHYSICAL_INTERMEDIATE_DEVELOPED_ACESCG = 15,
    SCREEN_PHYSICAL_INTERMEDIATE_CAMERA_RENDERED_ACESCG = 16,
    SCREEN_PHYSICAL_INTERMEDIATE_PANEL_TEMPORAL = 17,
    SCREEN_PHYSICAL_INTERMEDIATE_DEVICE_VFX_TRANSPARENCY = 18,
} ScreenPhysicalIntermediate;

typedef struct {
    uint32_t abi_version;
    uint32_t active_width;
    uint32_t active_height;
    bool bake_depth_of_field;
} ScreenPhysicalVfxTransparencySpecV1;

typedef struct {
    uint64_t high;
    uint64_t low;
} ScreenPhysicalIdentity128;

typedef struct {
    uint32_t abi_version;
    uint32_t stage_id;
    float amount;
    bool discrete_enabled;
} ScreenPhysicalStageContributionV3;

typedef struct {
    uint32_t abi_version;
    int64_t time_numerator;
    uint32_t time_denominator;
    ScreenPhysicalTextureRef source_acescg;
    ScreenPhysicalTextureRef device_signal;
} ScreenPhysicalTimedInputSampleV2;

typedef struct {
    uint32_t abi_version;
    int64_t start_numerator;
    uint32_t start_denominator;
    int64_t time_numerator;
    uint32_t time_denominator;
    int64_t end_numerator;
    uint32_t end_denominator;
    double weight_seconds;
} ScreenPhysicalTemporalSampleRequirementV1;

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
    int64_t time_numerator;
    uint32_t time_denominator;
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
    uint32_t interpolation;
} ScreenPhysicalCameraIntrinsicsKnotV1;

typedef struct {
    uint32_t abi_version;
    uint64_t revision;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    float camera_position[3];
    float camera_rotation_xyzw[4];
    float screen_position[3];
    float screen_rotation_xyzw[4];
    uint32_t full_sensor_width;
    uint32_t full_sensor_height;
    uint32_t active_sensor_origin_x;
    uint32_t active_sensor_origin_y;
    uint32_t active_sensor_width;
    uint32_t active_sensor_height;
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
} ScreenResolvedSceneFrameV1;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    uint32_t delivery_width;
    uint32_t delivery_height;
    uint32_t preview_width;
    uint32_t preview_height;
    /* 0 Fit, 1 OneToOne, 2 FillCrop. */
    uint32_t delivery_placement;
    /* 0 transparent, 1 black. */
    uint32_t delivery_background;
} ScreenSetupDiagnosticRequestV1;

typedef struct {
    uint32_t abi_version;
    uint64_t revision;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    float camera_position[3];
    float camera_rotation_xyzw[4];
    float screen_position[3];
    float screen_rotation_xyzw[4];
    uint32_t active_sensor_width;
    uint32_t active_sensor_height;
    uint32_t device_native_width;
    uint32_t device_native_height;
    float device_active_width_meters;
    float device_active_height_meters;
    float device_corner_radius_meters;
    float focal_length_millimeters;
    float sensor_width_millimeters;
    float sensor_height_millimeters;
    float lens_shift[2];
    float focus_distance_meters;
    float f_stop;
    float lens_radial_distortion[3];
    float lens_tangential_distortion[2];
    float environment_rotation_radians[2];
    float environment_placement_anchor_direction_world[3];
    float environment_placement_source_direction[3];
    float environment_placement_tangent_transform[4];
    bool environment_finite_sphere;
    float environment_sphere_center_meters[3];
    float environment_sphere_radius_meters;
    uint32_t delivery_width;
    uint32_t delivery_height;
    uint32_t preview_width;
    uint32_t preview_height;
    uint32_t delivery_placement;
    uint32_t delivery_background;
} ScreenSetupDiagnosticPlanV1;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    uint32_t source_width;
    uint32_t source_height;
    float center_x;
    float center_y;
    float zoom;
    float roll_radians;
} ScreenEnvironmentFramingRequestV1;

typedef struct {
    uint32_t abi_version;
    uint64_t revision;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    float anchor_direction_world[3];
    float source_direction[3];
    float tangent_transform[4];
} ScreenEnvironmentPlacementV1;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    float meters_per_source_unit;
    uint32_t delivery_width;
    uint32_t delivery_height;
    uint32_t preview_width;
    uint32_t preview_height;
    /* 0 Fit, 1 OneToOne, 2 FillCrop. */
    uint32_t delivery_placement;
} ScreenTrackingOverlayRequestV1;

typedef struct {
    float source_position[3];
} ScreenTrackingOverlayPointV1;

typedef struct {
    float pixel[2];
    bool visible;
} ScreenProjectedTrackingPointV1;

typedef struct {
    uint64_t revision;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
} ScreenTrackingOverlayIdentityV1;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    uint32_t delivery_width;
    uint32_t delivery_height;
    uint32_t preview_width;
    uint32_t preview_height;
    uint32_t delivery_placement;
} ScreenSceneFocusTargetRequestV1;

typedef struct {
    float uv[2];
    float pixel[2];
    bool valid;
} ScreenSceneFocusTargetV1;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    int64_t time_numerator;
    uint32_t time_denominator;
    float center_meters[3];
} ScreenSceneEnvironmentRadiusRequestV1;

typedef struct {
    uint32_t abi_version;
    float device_corners_xyz[12];
    float image_corners_xy[8];
    uint32_t image_width;
    uint32_t image_height;
    float focal_length_millimeters;
    float sensor_width_millimeters;
    float sensor_height_millimeters;
    float lens_shift_xy[2];
} ScreenPlanarReferenceMatchV1;

typedef struct {
    float camera_position[3];
    float camera_rotation_xyzw[4];
    float maximum_reprojection_error_pixels;
} ScreenMatchedCameraPoseV1;

#define SCREEN_TRACKING_SCALE_ABI_VERSION 1u
typedef struct {
    uint32_t abi_version;
    float first_point_xyz[3];
    float second_point_xyz[3];
    float measured_distance_meters;
} ScreenTrackingScaleCalibrationV1;

bool screen_geometry_resolve_tracking_scale_v1(
    const ScreenTrackingScaleCalibrationV1 *request,
    float *meters_per_source_unit,
    const char **error_message
);

#define SCREEN_REFLECTION_ENVIRONMENT_ABI_VERSION 2u
typedef struct {
    uint32_t abi_version;
    uint32_t kind;
    float directions_xyz[12];
    float angular_diameter_degrees;
    float distance_meters;
    float radiance_candelas_per_square_meter;
    float temperature_kelvin;
    float tint;
    float edge_softness_degrees;
} ScreenReflectionEmitterV2;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    int64_t shutter_open_numerator;
    uint32_t shutter_open_denominator;
    int64_t shutter_close_numerator;
    uint32_t shutter_close_denominator;
    uint16_t temporal_sample_count;
    uint32_t render_full_width;
    uint32_t render_full_height;
    uint32_t render_window_x;
    uint32_t render_window_y;
    uint32_t render_window_width;
    uint32_t render_window_height;
    uint32_t render_scale_x_numerator;
    uint32_t render_scale_x_denominator;
    uint32_t render_scale_y_numerator;
    uint32_t render_scale_y_denominator;
    uint32_t pixel_aspect_numerator;
    uint32_t pixel_aspect_denominator;
} ScreenPreparedRenderRequestV1;

typedef struct {
    uint32_t abi_version;
    ScreenPhysicalTimedInputSetV2Ref timed_inputs;
    ScreenPhysicalTextureRef environment_acescg;
    ScreenPreparedRenderV1Ref prepared_render;
    uint32_t quality;
    uint32_t device_vfx_alpha_mode;
    float screen_amount;
    const ScreenPhysicalStageContributionV3 *stage_contributions;
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
    float corner_radius_meters;
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
    float glow_intensity;
    float glow_radius_millimeters;
    float glow_threshold_relative_white;
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
    float rotation_x_degrees;
    float rotation_y_degrees;
    float placement_anchor_direction_world[3];
    float placement_source_direction[3];
    float placement_tangent_transform[4];
    uint32_t projection_mode;
    float sphere_center_meters[3];
    float sphere_radius_meters;
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
    uint16_t reserved;
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
    ScreenCameraRadiometricCalibrationV2 radiometric_calibration;
    ScreenCaptureRasterModeV1 raster_modes[3];
    ScreenUTF8View default_raster_mode_id;
    uint32_t default_lens_evaluation_model;
    ScreenUTF8View native_vfx_encoding_id;
} ScreenCapturePresetParametersV4;

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
    float moire_intensity;
    float moire_saturation;
    float moire_filter_strength;
    float cover_glow_exterior_intensity;
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

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenDeviceParametersV3 parameters;
    const ScreenUTF8View *color_mode_ids;
    size_t color_mode_count;
    ScreenUTF8View default_color_mode_id;
    float minimum_white_nits;
    float maximum_white_nits;
    float white_step_nits;
    ScreenUTF8View default_cover_glass_profile_id;
} ScreenTestDeviceProfileV1;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenCoverGlassParametersV2 parameters;
} ScreenTestCoverProfileV1;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenCapturePresetParametersV4 parameters;
    ScreenUTF8View default_recording_profile_id;
    const ScreenUTF8View *recommended_recording_profile_ids;
    size_t recommended_recording_profile_count;
    ScreenUTF8View default_lens_profile_id;
    const ScreenUTF8View *compatible_lens_profile_ids;
    size_t compatible_lens_profile_count;
} ScreenTestCaptureProfileV1;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenLensPresetParametersV1 parameters;
} ScreenTestLensProfileV1;

typedef struct {
    uint32_t abi_version;
    ScreenUTF8View id;
    ScreenUTF8View label;
    ScreenEnvironmentParametersV2 parameters;
} ScreenTestEnvironmentProfileV1;

ScreenTestAuthoringProfileContextRef screen_test_authoring_profile_context_create(
    const ScreenTestDeviceProfileV1 *devices,
    size_t device_count,
    const ScreenTestCoverProfileV1 *covers,
    size_t cover_count,
    const ScreenTestCaptureProfileV1 *captures,
    size_t capture_count,
    const ScreenTestLensProfileV1 *lenses,
    size_t lens_count,
    const ScreenTestEnvironmentProfileV1 *environments,
    size_t environment_count,
    const char **error_message
);
void screen_test_authoring_profile_context_release(
    ScreenTestAuthoringProfileContextRef context
);

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
ScreenUTF8View screen_capture_preset_default_recording_profile_id(size_t index);
size_t screen_capture_preset_recommended_recording_profile_count(size_t index);
ScreenUTF8View screen_capture_preset_recommended_recording_profile_id(
    size_t index,
    size_t recording_profile_index
);
size_t screen_capture_preset_compatible_lens_count(size_t index);
ScreenUTF8View screen_capture_preset_compatible_lens_id(
    size_t index,
    size_t lens_index
);
bool screen_capture_preset_parameters(
    size_t index,
    ScreenCapturePresetParametersV4 *parameters
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
ScreenAdjustedSceneTextureRef screen_scene_adjustment_texture_create_metal(
    const void *source_metal_texture,
    float exposure_ev,
    float contrast,
    float saturation,
    float temperature_kelvin,
    float tint,
    bool incident_radiance,
    const char **error_message
);
ScreenPhysicalTextureRef screen_scene_adjustment_texture_borrow_physical(
    ScreenAdjustedSceneTextureRef texture
);
const void *screen_scene_adjustment_texture_borrow_metal(
    ScreenAdjustedSceneTextureRef texture
);
void screen_scene_adjustment_texture_release(ScreenAdjustedSceneTextureRef texture);
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
ScreenPhysicalCameraIntrinsicsTrackV1Ref screen_physical_camera_intrinsics_track_v1_create(
    const ScreenPhysicalCameraIntrinsicsKnotV1 *knots,
    size_t knot_count,
    const char **error_message
);
ScreenSceneFrameResolverV1Ref screen_scene_frame_resolver_v1_create(
    uint64_t revision,
    uint32_t frame_rate_numerator,
    uint32_t frame_rate_denominator,
    ScreenPhysicalCameraPoseTrackV2Ref camera_pose_track,
    ScreenPhysicalCameraIntrinsicsTrackV1Ref camera_intrinsics_track,
    ScreenPhysicalScreenPoseTrackV2Ref screen_pose_track,
    ScreenDeviceProfileRef resolved_device,
    ScreenPhysicalPipelineSnapshotRef resolved_pipeline,
    bool autofocus_enabled,
    float autofocus_target_u,
    float autofocus_target_v,
    const char **error_message
);
void screen_physical_camera_pose_track_v2_release(ScreenPhysicalCameraPoseTrackV2Ref track);
void screen_physical_camera_intrinsics_track_v1_release(ScreenPhysicalCameraIntrinsicsTrackV1Ref track);
void screen_physical_screen_pose_track_v2_release(ScreenPhysicalScreenPoseTrackV2Ref track);
void screen_scene_frame_resolver_v1_release(ScreenSceneFrameResolverV1Ref resolver);
bool screen_scene_frame_resolver_v1_resolve(
    ScreenSceneFrameResolverV1Ref resolver,
    int64_t frame_index,
    int64_t time_numerator,
    uint32_t time_denominator,
    ScreenResolvedSceneFrameV1 *output,
    const char **error_message
);
bool screen_scene_setup_diagnostic_v1_prepare(
    ScreenSceneFrameResolverV1Ref resolver,
    const ScreenSetupDiagnosticRequestV1 *request,
    ScreenSetupDiagnosticPlanV1 *output,
    const char **error_message
);
bool screen_environment_framing_v1_resolve(
    ScreenSceneFrameResolverV1Ref resolver,
    const ScreenEnvironmentFramingRequestV1 *request,
    ScreenEnvironmentPlacementV1 *output,
    const char **error_message
);
bool screen_tracking_overlay_v1_resolve(
    ScreenSceneFrameResolverV1Ref resolver,
    const ScreenTrackingOverlayRequestV1 *request,
    const ScreenTrackingOverlayPointV1 *points,
    size_t point_count,
    ScreenProjectedTrackingPointV1 *output,
    ScreenTrackingOverlayIdentityV1 *identity,
    const char **error_message
);
bool screen_scene_focus_target_v1_project(
    ScreenSceneFrameResolverV1Ref resolver,
    const ScreenSceneFocusTargetRequestV1 *request,
    ScreenSceneFocusTargetV1 *target,
    ScreenTrackingOverlayIdentityV1 *identity,
    const char **error_message
);
bool screen_scene_focus_target_v1_unproject(
    ScreenSceneFrameResolverV1Ref resolver,
    const ScreenSceneFocusTargetRequestV1 *request,
    ScreenSceneFocusTargetV1 *target,
    ScreenTrackingOverlayIdentityV1 *identity,
    const char **error_message
);
bool screen_scene_environment_minimum_radius_v1(
    ScreenSceneFrameResolverV1Ref resolver,
    const ScreenSceneEnvironmentRadiusRequestV1 *request,
    float *radius_meters,
    ScreenTrackingOverlayIdentityV1 *identity,
    const char **error_message
);
bool screen_geometry_solve_planar_reference_v1(
    const ScreenPlanarReferenceMatchV1 *request,
    ScreenMatchedCameraPoseV1 *result,
    const char **error_message
);
ScreenPhysicalFrameJobRef screen_physical_frame_submit(
    const ScreenPhysicalFrameRequestV2 *request,
    const char **error_message
);
ScreenPreparedRenderV1Ref screen_prepared_render_v1_create(
    ScreenSceneFrameResolverV1Ref resolver,
    const ScreenPreparedRenderRequestV1 *request,
    const char **error_message
);
bool screen_prepared_render_v1_temporal_requirements(
    ScreenPreparedRenderV1Ref prepared,
    ScreenPhysicalTemporalSampleRequirementV1 *requirements,
    size_t requirement_capacity,
    size_t *requirement_count,
    const char **error_message
);
void screen_prepared_render_v1_release(ScreenPreparedRenderV1Ref prepared);
ScreenPhysicalFrameJobRef screen_physical_vfx_transparency_submit(
    const ScreenPhysicalFrameRequestV2 *request,
    const ScreenPhysicalVfxTransparencySpecV1 *spec,
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
bool screen_delivery_raster_rgba32f(
    const float *input_rgba,
    uint32_t input_width,
    uint32_t input_height,
    float *output_rgba,
    uint32_t output_width,
    uint32_t output_height,
    uint32_t placement,
    uint32_t background,
    const char **error_message
);
bool screen_recording_output_transform_rgba32f(
    ScreenUTF8View transform_id,
    const float *input_rgba,
    float *output_rgba,
    uint32_t width,
    uint32_t height,
    const char **error_message
);
bool screen_recording_prepare_execution_plan(
    ScreenUTF8View profile_id,
    float character,
    uint32_t frame_rate_numerator,
    uint32_t frame_rate_denominator,
    int64_t first_frame_index,
    uint64_t frame_count,
    ScreenRecordingExecutionPlanV2 *output,
    const char **error_message
);
bool screen_recording_output_inverse_rgba32f(
    ScreenUTF8View transform_id,
    float *rgba,
    uint32_t width,
    uint32_t height,
    const char **error_message
);
bool screen_reflection_environment_compile_rgba32f(
    const ScreenReflectionEmitterV2 *emitters,
    size_t emitter_count,
    float *output_rgba,
    uint32_t width,
    uint32_t height,
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

bool screen_ffmpeg_probe_media_v1(
    const char *file_path,
    ScreenFfmpegMediaInfoV1 *output,
    const char **error_message
);
bool screen_ffmpeg_decode_frame_v1(
    const char *file_path,
    int64_t requested_time_numerator,
    uint32_t requested_time_denominator,
    uint32_t selection_policy,
    uint32_t authored_color_model,
    uint32_t authored_matrix,
    uint32_t authored_range,
    ScreenFfmpegDecodedFrameV1 *output,
    const char **error_message
);
void screen_ffmpeg_free_rgba_float_v1(float *pixels, uint32_t width, uint32_t height);

#endif
