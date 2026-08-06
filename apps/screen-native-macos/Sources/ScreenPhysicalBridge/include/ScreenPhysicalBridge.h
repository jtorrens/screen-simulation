#ifndef SCREEN_PHYSICAL_BRIDGE_H
#define SCREEN_PHYSICAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

typedef struct ScreenPhysicalPipeline *ScreenPhysicalPipelineRef;

ScreenPhysicalPipelineRef screen_physical_pipeline_create(void);
void screen_physical_pipeline_release(ScreenPhysicalPipelineRef pipeline);
bool screen_physical_pipeline_process_rgba32f(
    ScreenPhysicalPipelineRef pipeline,
    float *pixels,
    size_t pixel_count,
    const char **error_message
);

#endif

