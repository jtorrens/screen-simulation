#ifndef SCREEN_PHYSICAL_BRIDGE_H
#define SCREEN_PHYSICAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ScreenPhysicalPipeline *ScreenPhysicalPipelineRef;
typedef struct ScreenDeviceProfile *ScreenDeviceProfileRef;

typedef struct {
    const uint8_t *bytes;
    size_t count;
} ScreenUTF8View;

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
} ScreenDeviceParametersV1;

size_t screen_device_preset_count(void);
ScreenUTF8View screen_device_preset_id(size_t index);
ScreenUTF8View screen_device_preset_label(size_t index);
ScreenUTF8View screen_device_preset_category(size_t index);
ScreenUTF8View screen_device_preset_white_basis(size_t index);
ScreenUTF8View screen_device_preset_default_cover_id(size_t index);
bool screen_device_preset_parameters(
    size_t index,
    ScreenDeviceParametersV1 *parameters
);
ScreenDeviceProfileRef screen_device_profile_create(
    const ScreenDeviceParametersV1 *parameters,
    const char **error_message
);
void screen_device_profile_release(ScreenDeviceProfileRef profile);

ScreenPhysicalPipelineRef screen_physical_pipeline_create(void);
void screen_physical_pipeline_release(ScreenPhysicalPipelineRef pipeline);
bool screen_physical_pipeline_process_rgba32f(
    ScreenPhysicalPipelineRef pipeline,
    float *pixels,
    size_t pixel_count,
    const char **error_message
);

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
