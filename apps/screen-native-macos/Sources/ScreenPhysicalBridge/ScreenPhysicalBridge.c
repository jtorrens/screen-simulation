#include "ScreenPhysicalBridge.h"

extern bool CHOpenEXREncodeRGBAHalf(
    const float *, uint32_t, uint32_t, uint8_t **, size_t *, char **
);
extern void CHOpenEXRFree(void *);

bool screen_openexr_encode_rgba_half(
    const float *pixels,
    uint32_t width,
    uint32_t height,
    uint8_t **encoded_bytes,
    size_t *encoded_byte_count,
    char **error_message
) {
    return CHOpenEXREncodeRGBAHalf(
        pixels, width, height, encoded_bytes, encoded_byte_count, error_message
    );
}

void screen_openexr_free(void *pointer) {
    CHOpenEXRFree(pointer);
}
