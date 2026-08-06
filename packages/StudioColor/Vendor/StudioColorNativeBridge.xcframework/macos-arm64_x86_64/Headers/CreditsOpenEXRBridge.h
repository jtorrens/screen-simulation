#ifndef CREDITS_OPENEXR_BRIDGE_H
#define CREDITS_OPENEXR_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *CHOpenEXRVersion(void);
void CHOpenEXRFree(void *value);

bool CHOpenEXREncodeRGBAHalf(
    const float *pixels,
    uint32_t width,
    uint32_t height,
    uint8_t **encodedBytes,
    size_t *encodedByteCount,
    char **errorMessage
);

bool CHOpenEXRDecodeRGBAFloat(
    const char *filePath,
    float **pixels,
    uint32_t *width,
    uint32_t *height,
    char **declaredColorSpace,
    char **errorMessage
);

#ifdef __cplusplus
}
#endif

#endif
