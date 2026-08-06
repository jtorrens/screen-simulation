#ifndef SCREEN_PHYSICAL_BRIDGE_H
#define SCREEN_PHYSICAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ScreenPhysicalPipeline *ScreenPhysicalPipelineRef;

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
