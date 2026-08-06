#ifndef STUDIO_COLOR_ABI_H
#define STUDIO_COLOR_ABI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STUDIO_COLOR_ABI_VERSION 1

typedef struct SCConfigOpaque *SCConfigRef;
typedef struct SCProcessorOpaque *SCProcessorRef;

typedef enum SCTextureDimension {
    SCTextureDimension1D = 1,
    SCTextureDimension2D = 2,
    SCTextureDimension3D = 3
} SCTextureDimension;

typedef enum SCTextureInterpolation {
    SCTextureInterpolationNearest = 1,
    SCTextureInterpolationLinear = 2
} SCTextureInterpolation;

typedef struct SCTextureInfo {
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t channelCount;
    SCTextureDimension dimension;
    SCTextureInterpolation interpolation;
    const float *values;
    size_t valueCount;
} SCTextureInfo;

uint32_t SCABIVersion(void);
const char *SCVersion(void);
void SCFreeString(char *value);
SCConfigRef SCConfigCreate(const char *configPath, char **errorMessage);
void SCConfigRelease(SCConfigRef config);
SCProcessorRef SCProcessorCreateColorSpace(
    SCConfigRef config,
    const char *sourceColorSpace,
    const char *destinationColorSpace,
    char **errorMessage
);
SCProcessorRef SCProcessorCreateDisplayView(
    SCConfigRef config,
    const char *sourceColorSpace,
    const char *display,
    const char *view,
    char **errorMessage
);
SCProcessorRef SCProcessorCreateDisplayViewInverse(
    SCConfigRef config,
    const char *sceneColorSpace,
    const char *display,
    const char *view,
    char **errorMessage
);
void SCProcessorRelease(SCProcessorRef processor);
bool SCProcessorApplyRGBA(
    SCProcessorRef processor,
    float *pixels,
    size_t pixelCount,
    char **errorMessage
);
char *SCProcessorCopyMSLShader(
    SCProcessorRef processor,
    const char *functionName,
    char **errorMessage
);
size_t SCProcessorTextureCount(
    SCProcessorRef processor,
    char **errorMessage
);
bool SCProcessorTextureInfoAtIndex(
    SCProcessorRef processor,
    size_t index,
    SCTextureInfo *textureInfo,
    char **errorMessage
);

#ifdef __cplusplus
}
#endif

#endif

