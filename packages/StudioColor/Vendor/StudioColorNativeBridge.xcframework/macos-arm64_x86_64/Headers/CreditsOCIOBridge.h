#ifndef CREDITS_OCIO_BRIDGE_H
#define CREDITS_OCIO_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CHOCIOConfigOpaque *CHOCIOConfigRef;
typedef struct CHOCIOProcessorOpaque *CHOCIOProcessorRef;

typedef enum CHOCIOTextureDimension {
    CHOCIOTextureDimension1D = 1,
    CHOCIOTextureDimension2D = 2,
    CHOCIOTextureDimension3D = 3
} CHOCIOTextureDimension;

typedef enum CHOCIOTextureInterpolation {
    CHOCIOTextureInterpolationNearest = 1,
    CHOCIOTextureInterpolationLinear = 2
} CHOCIOTextureInterpolation;

typedef struct CHOCIOTextureInfo {
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t channelCount;
    CHOCIOTextureDimension dimension;
    CHOCIOTextureInterpolation interpolation;
    const float *values;
    size_t valueCount;
} CHOCIOTextureInfo;

const char *CHOCIOVersion(void);
void CHOCIOFreeString(char *value);

CHOCIOConfigRef CHOCIOConfigCreate(
    const char *configPath,
    char **errorMessage
);
void CHOCIOConfigRelease(CHOCIOConfigRef config);

CHOCIOProcessorRef CHOCIOProcessorCreateColorSpace(
    CHOCIOConfigRef config,
    const char *sourceColorSpace,
    const char *destinationColorSpace,
    char **errorMessage
);

CHOCIOProcessorRef CHOCIOProcessorCreateDisplayView(
    CHOCIOConfigRef config,
    const char *sourceColorSpace,
    const char *display,
    const char *view,
    char **errorMessage
);

CHOCIOProcessorRef CHOCIOProcessorCreateDisplayViewInverse(
    CHOCIOConfigRef config,
    const char *sceneColorSpace,
    const char *display,
    const char *view,
    char **errorMessage
);

void CHOCIOProcessorRelease(CHOCIOProcessorRef processor);

bool CHOCIOProcessorApplyRGBA(
    CHOCIOProcessorRef processor,
    float *pixels,
    size_t pixelCount,
    char **errorMessage
);

char *CHOCIOProcessorCopyMSLShader(
    CHOCIOProcessorRef processor,
    const char *functionName,
    char **errorMessage
);

size_t CHOCIOProcessorTextureCount(
    CHOCIOProcessorRef processor,
    char **errorMessage
);

bool CHOCIOProcessorTextureInfoAtIndex(
    CHOCIOProcessorRef processor,
    size_t index,
    CHOCIOTextureInfo *textureInfo,
    char **errorMessage
);

#ifdef __cplusplus
}
#endif

#endif
