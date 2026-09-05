#ifndef SCREEN_OFX_BRIDGE_H
#define SCREEN_OFX_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ScreenOfxStringView {
  const uint8_t* data;
  size_t length;
} ScreenOfxStringView;

uint32_t screen_ofx_origin_schema_version(void);
size_t screen_ofx_origin_input_transform_count(void);
ScreenOfxStringView screen_ofx_origin_input_transform_id(size_t index);
ScreenOfxStringView screen_ofx_origin_input_transform_label(size_t index);
size_t screen_ofx_origin_alpha_count(void);
ScreenOfxStringView screen_ofx_origin_alpha_id(size_t index);
ScreenOfxStringView screen_ofx_origin_alpha_label(size_t index);
size_t screen_ofx_origin_preview_count(void);
ScreenOfxStringView screen_ofx_origin_preview_id(size_t index);
ScreenOfxStringView screen_ofx_origin_preview_label(size_t index);
uint32_t screen_ofx_origin_process_rgba32f(
    const char* input_transform_id,
    const char* alpha_interpretation_id,
    const char* preview_id,
    uint32_t width,
    uint32_t height,
    const float* input_rgba,
    float* output_rgba);
ScreenOfxStringView screen_ofx_origin_error_message(uint32_t status);

#ifdef __cplusplus
}
#endif

#endif
