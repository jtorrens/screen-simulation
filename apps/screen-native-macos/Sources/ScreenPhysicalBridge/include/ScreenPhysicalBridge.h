#ifndef SCREEN_PHYSICAL_BRIDGE_H
#define SCREEN_PHYSICAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ScreenDeviceProfile *ScreenDeviceProfileRef;
typedef struct ScreenCoverGlassProfile *ScreenCoverGlassProfileRef;
typedef struct ScreenPhysicalPipelineSnapshot *ScreenPhysicalPipelineSnapshotRef;
typedef struct ScreenPhysicalTexture *ScreenPhysicalTextureRef;
typedef struct ScreenPhysicalFrameInput *ScreenPhysicalFrameInputRef;
typedef struct ScreenPhysicalFrameJob *ScreenPhysicalFrameJobRef;

#define SCREEN_PHYSICAL_FRAME_ABI_VERSION 2u
#define SCREEN_PHYSICAL_PARAMETER_HASH_SIZE 32u

typedef struct {
    const uint8_t *bytes;
    size_t count;
} ScreenUTF8View;

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
    SCREEN_PHYSICAL_STAGE_SCREEN_LIGHT_SPREAD = 0x103,
    SCREEN_PHYSICAL_STAGE_SCREEN_TEMPORAL = 0x104,
    SCREEN_PHYSICAL_STAGE_SCREEN_COVER_GLASS = 0x105,
    SCREEN_PHYSICAL_STAGE_SCREEN_ENVIRONMENT = 0x106,
    SCREEN_PHYSICAL_STAGE_CAPTURE_GEOMETRY = 0x201,
    SCREEN_PHYSICAL_STAGE_CAPTURE_LENS = 0x202,
    SCREEN_PHYSICAL_STAGE_CAPTURE_EXPOSURE_SHUTTER = 0x203,
    SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_CFA = 0x204,
    SCREEN_PHYSICAL_STAGE_CAPTURE_NOISE = 0x205,
    SCREEN_PHYSICAL_STAGE_CAPTURE_DEVELOP_DEMOSAIC = 0x206,
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
    SCREEN_PHYSICAL_INTERMEDIATE_SOURCE_ACESCG = 0,
    SCREEN_PHYSICAL_INTERMEDIATE_DEVICE_SIGNAL = 1,
    SCREEN_PHYSICAL_INTERMEDIATE_PANEL_EMISSION = 2,
    SCREEN_PHYSICAL_INTERMEDIATE_SUBPIXEL_RADIANCE = 3,
    SCREEN_PHYSICAL_INTERMEDIATE_PANEL_LIGHT_SPREAD = 4,
    SCREEN_PHYSICAL_INTERMEDIATE_COVER_ENVIRONMENT = 5,
    SCREEN_PHYSICAL_INTERMEDIATE_SCENE_GEOMETRY_LENS = 6,
    SCREEN_PHYSICAL_INTERMEDIATE_SHUTTER_MOTION = 7,
    SCREEN_PHYSICAL_INTERMEDIATE_SENSOR_NOISE = 8,
    SCREEN_PHYSICAL_INTERMEDIATE_RAW_MOSAIC = 9,
    SCREEN_PHYSICAL_INTERMEDIATE_DEVELOPED_ACESCG = 10,
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
    uint8_t reserved[2];
} ScreenPhysicalStageContributionV2;

typedef struct {
    uint32_t abi_version;
    int64_t frame_index;
    int64_t frame_time_numerator;
    uint32_t frame_time_denominator;
    ScreenPhysicalFrameInputRef input;
    ScreenDeviceProfileRef resolved_device;
    ScreenPhysicalPipelineSnapshotRef resolved_pipeline;
    uint32_t quality;
    float screen_amount;
    float capture_amount;
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
} ScreenDeviceParametersV2;

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
} ScreenCoverGlassParametersV2;

typedef struct {
    uint32_t abi_version;
    float character_strength;
    float ambient_radiance_acescg[3];
    float key_radiance_acescg[3];
    float key_direction_local[3];
    float key_angular_radius_degrees;
    float rotation_degrees;
    uint32_t pattern;
} ScreenEnvironmentParametersV2;

typedef struct {
    uint32_t abi_version;
    float camera_position[3];
    float camera_target[3];
    float camera_yaw_degrees;
    float focal_length_millimeters;
    float sensor_width_millimeters;
    float sensor_height_millimeters;
    float lens_shift[2];
    float focus_distance_meters;
    float f_stop;
    float near_clip_meters;
    float far_clip_meters;
    float camera_rotation_xyzw[4];
    float lens_radial_distortion[3];
    float lens_tangential_distortion[2];
    float lens_longitudinal_chromatic_meters[3];
    float lens_lateral_chromatic_scale[3];
    float lens_vignetting_strength;
    float lens_transmission_rgb[3];
    float lens_center_softness_micrometers;
    float lens_edge_softness_micrometers;
    float screen_translation[3];
    float screen_rotation_xyzw[4];
    float screen_scale[2];
} ScreenSceneGeometryLensParametersV2;

typedef struct {
    uint32_t abi_version;
    int64_t exposure_duration_numerator;
    uint32_t exposure_duration_denominator;
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
} ScreenSensorNoiseParametersV2;

typedef struct {
    uint32_t abi_version;
    float white_balance[3];
    float middle_gray_illuminance_seconds;
    float develop_exposure_ev;
} ScreenRawDevelopParametersV2;

typedef struct {
    uint32_t abi_version;
    ScreenCoverGlassParametersV2 cover;
    ScreenEnvironmentParametersV2 environment;
    ScreenSceneGeometryLensParametersV2 scene_geometry_lens;
    ScreenShutterMotionParametersV2 shutter_motion;
    ScreenSensorNoiseParametersV2 sensor_noise;
    ScreenRawDevelopParametersV2 raw_develop;
} ScreenPhysicalPipelineParametersV2;

size_t screen_cover_glass_preset_count(void);
ScreenUTF8View screen_cover_glass_preset_id(size_t index);
ScreenUTF8View screen_cover_glass_preset_label(size_t index);
bool screen_cover_glass_preset_parameters(
    size_t index,
    ScreenCoverGlassParametersV2 *parameters
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
ScreenUTF8View screen_device_preset_default_cover_id(size_t index);
bool screen_device_preset_parameters(
    size_t index,
    ScreenDeviceParametersV2 *parameters
);
ScreenDeviceProfileRef screen_device_profile_create(
    const ScreenDeviceParametersV2 *parameters,
    const char **error_message
);
void screen_device_profile_release(ScreenDeviceProfileRef profile);
/*
 * Physical-frame ABI v2. These declarations are the single UI/engine contract.
 * The opaque input carries both the source linear ACEScg RGBA texture and the
 * nonlinear device-signal RGB texture resolved by StudioColor, plus explicit
 * raster placement. Result textures contain linear ACEScg RGBA. The engine
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
ScreenPhysicalFrameInputRef screen_physical_frame_input_create(
    ScreenPhysicalTextureRef source_acescg,
    ScreenPhysicalTextureRef device_signal,
    uint32_t raster_placement,
    const char **error_message
);
void screen_physical_frame_input_release(ScreenPhysicalFrameInputRef input);
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
