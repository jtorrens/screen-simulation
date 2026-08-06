#include "StudioColorABI.h"
#include <CreditsOCIOBridge.h>

uint32_t SCABIVersion(void) { return STUDIO_COLOR_ABI_VERSION; }
const char *SCVersion(void) { return CHOCIOVersion(); }
void SCFreeString(char *value) { CHOCIOFreeString(value); }

SCConfigRef SCConfigCreate(const char *path, char **error) {
    return (SCConfigRef)CHOCIOConfigCreate(path, error);
}
void SCConfigRelease(SCConfigRef config) {
    CHOCIOConfigRelease((CHOCIOConfigRef)config);
}
SCProcessorRef SCProcessorCreateColorSpace(
    SCConfigRef config, const char *source, const char *destination, char **error
) {
    return (SCProcessorRef)CHOCIOProcessorCreateColorSpace(
        (CHOCIOConfigRef)config, source, destination, error
    );
}
SCProcessorRef SCProcessorCreateDisplayView(
    SCConfigRef config, const char *source, const char *display,
    const char *view, char **error
) {
    return (SCProcessorRef)CHOCIOProcessorCreateDisplayView(
        (CHOCIOConfigRef)config, source, display, view, error
    );
}
SCProcessorRef SCProcessorCreateDisplayViewInverse(
    SCConfigRef config, const char *scene, const char *display,
    const char *view, char **error
) {
    return (SCProcessorRef)CHOCIOProcessorCreateDisplayViewInverse(
        (CHOCIOConfigRef)config, scene, display, view, error
    );
}
void SCProcessorRelease(SCProcessorRef processor) {
    CHOCIOProcessorRelease((CHOCIOProcessorRef)processor);
}
bool SCProcessorApplyRGBA(
    SCProcessorRef processor, float *pixels, size_t count, char **error
) {
    return CHOCIOProcessorApplyRGBA(
        (CHOCIOProcessorRef)processor, pixels, count, error
    );
}
char *SCProcessorCopyMSLShader(
    SCProcessorRef processor, const char *name, char **error
) {
    return CHOCIOProcessorCopyMSLShader(
        (CHOCIOProcessorRef)processor, name, error
    );
}
size_t SCProcessorTextureCount(SCProcessorRef processor, char **error) {
    return CHOCIOProcessorTextureCount((CHOCIOProcessorRef)processor, error);
}
bool SCProcessorTextureInfoAtIndex(
    SCProcessorRef processor, size_t index, SCTextureInfo *info, char **error
) {
    CHOCIOTextureInfo source;
    if (!CHOCIOProcessorTextureInfoAtIndex(
        (CHOCIOProcessorRef)processor, index, &source, error
    )) {
        return false;
    }
    info->width = source.width;
    info->height = source.height;
    info->depth = source.depth;
    info->channelCount = source.channelCount;
    info->dimension = (SCTextureDimension)source.dimension;
    info->interpolation = (SCTextureInterpolation)source.interpolation;
    info->values = source.values;
    info->valueCount = source.valueCount;
    return true;
}
