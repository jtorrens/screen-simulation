#include "identity_core.hpp"
#include "origin_core.hpp"
#include "screen_ofx_bridge.h"

#include <ofxColour.h>
#include <ofxCore.h>
#include <ofxGPURender.h>
#include <ofxImageEffect.h>
#include <ofxParam.h>
#include <ofxProperty.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define SCREEN_OFX_EXPORT __declspec(dllexport)
#else
#include <unistd.h>
#define SCREEN_OFX_EXPORT __attribute__((visibility("default")))
#endif

#ifndef SCREEN_SIMULATION_OFX_VERSION
#define SCREEN_SIMULATION_OFX_VERSION "dev"
#endif

namespace {

using screen_simulation::ofx::IdentityCopyStatus;
using screen_simulation::ofx::ImageView;
using screen_simulation::ofx::OriginIoStatus;
using screen_simulation::ofx::PixelDepth;
using screen_simulation::ofx::RectI;

constexpr char kPluginIdentifier[] = "com.jtorrens.ScreenSimulation";
constexpr char kNativeColourConfig[] =
    "ofx-native-v1.5_aces-v1.3_ocio-v2.3";
constexpr char kOutputComponentsProperty[] =
    "OfxImageClipPropComponents_Output";
constexpr char kOutputDepthProperty[] = "OfxImageClipPropDepth_Output";
constexpr char kSourceRoiProperty[] = "OfxImageClipPropRoI_Source";
constexpr char kInputTransformParameter[] = "input-transform";
constexpr char kAlphaInterpretationParameter[] = "alpha-interpretation";
constexpr char kPreviewParameter[] = "preview";

OfxHost* g_host = nullptr;
const OfxImageEffectSuiteV1* g_image_suite = nullptr;
const OfxPropertySuiteV1* g_property_suite = nullptr;
const OfxParameterSuiteV1* g_parameter_suite = nullptr;
std::atomic<unsigned long long> g_instance_sequence{1};

const char* status_name(OfxStatus status) noexcept {
  switch (status) {
    case kOfxStatOK: return "OK";
    case kOfxStatFailed: return "Failed";
    case kOfxStatErrFatal: return "ErrFatal";
    case kOfxStatErrUnknown: return "ErrUnknown";
    case kOfxStatErrMissingHostFeature: return "ErrMissingHostFeature";
    case kOfxStatErrUnsupported: return "ErrUnsupported";
    case kOfxStatErrFormat: return "ErrFormat";
    case kOfxStatErrMemory: return "ErrMemory";
    case kOfxStatErrBadHandle: return "ErrBadHandle";
    case kOfxStatErrValue: return "ErrValue";
    case kOfxStatReplyDefault: return "ReplyDefault";
    default: return "Other";
  }
}

const char* copy_status_name(IdentityCopyStatus status) noexcept {
  switch (status) {
    case IdentityCopyStatus::Ok: return "ok";
    case IdentityCopyStatus::MissingData: return "missing-data";
    case IdentityCopyStatus::InvalidLayout: return "invalid-layout";
    case IdentityCopyStatus::IncompatibleLayout: return "incompatible-layout";
    case IdentityCopyStatus::WindowOutsideImage: return "window-outside-image";
  }
  return "unknown";
}

const char* origin_io_status_name(OriginIoStatus status) noexcept {
  switch (status) {
    case OriginIoStatus::Ok: return "ok";
    case OriginIoStatus::MissingData: return "missing-data";
    case OriginIoStatus::InvalidLayout: return "invalid-layout";
    case OriginIoStatus::WindowOutsideImage: return "window-outside-image";
    case OriginIoStatus::InvalidPixel: return "invalid-pixel";
  }
  return "unknown";
}

std::string bridge_string(ScreenOfxStringView value) {
  if (!value.data || value.length == 0) return {};
  return std::string(
      reinterpret_cast<const char*>(value.data), value.length);
}

class Logger {
 public:
  static Logger& shared() {
    static Logger logger;
    return logger;
  }

  void write(const std::string& event, const std::string& fields = {}) noexcept {
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      open_if_needed();
      if (!stream_) return;
      stream_ << timestamp() << " | pid=" << process_id_ << " | " << event;
      if (!fields.empty()) stream_ << " | " << fields;
      stream_ << '\n';
      stream_.flush();
    } catch (...) {
      // Diagnostics cannot change host behavior.
    }
  }

 private:
  Logger() {
#if defined(_WIN32)
    process_id_ = static_cast<unsigned long>(GetCurrentProcessId());
#else
    process_id_ = static_cast<unsigned long>(::getpid());
#endif
  }

  static std::string timestamp() {
    const auto now = std::chrono::system_clock::now();
    const auto value = std::chrono::system_clock::to_time_t(now);
    std::tm local{};
#if defined(_WIN32)
    localtime_s(&local, &value);
#else
    localtime_r(&value, &local);
#endif
    std::ostringstream text;
    text << std::put_time(&local, "%Y-%m-%dT%H:%M:%S");
    return text.str();
  }

  void open_if_needed() {
    if (attempted_) return;
    attempted_ = true;
    if (const char* override_path = std::getenv("SCREEN_SIMULATION_OFX_LOG");
        override_path && *override_path) {
      path_ = override_path;
#if defined(_WIN32)
    } else if (const char* local_data = std::getenv("LOCALAPPDATA");
               local_data && *local_data) {
      path_ = (std::filesystem::path(local_data) / "ScreenSimulation" /
               "Logs" / "ScreenSimulationOFX.log").string();
#else
    } else if (const char* user_home = std::getenv("HOME");
               user_home && *user_home) {
      path_ = (std::filesystem::path(user_home) / "Library" / "Logs" /
               "ScreenSimulationOFX" / "ScreenSimulation.log").string();
#endif
    } else {
      return;
    }
    const std::filesystem::path path(path_);
    std::error_code error;
    std::filesystem::create_directories(path.parent_path(), error);
    if (error) return;
    stream_.open(path_, std::ios::out | std::ios::app);
  }

  std::mutex mutex_;
  std::ofstream stream_;
  std::string path_;
  bool attempted_ = false;
  unsigned long process_id_ = 0;
};

std::string quoted(const char* value) {
  return value ? '"' + std::string(value) + '"' : "<unset>";
}

std::string string_property(OfxPropertySetHandle properties, const char* name) {
  if (!g_property_suite || !properties) return "<unavailable>";
  char* value = nullptr;
  const auto status = g_property_suite->propGetString(properties, name, 0, &value);
  return status == kOfxStatOK ? quoted(value) :
      '<' + std::string(status_name(status)) + '>';
}

std::string ints_property(
    OfxPropertySetHandle properties, const char* name, int count) {
  if (!g_property_suite || !properties) return "<unavailable>";
  std::ostringstream text;
  text << '[';
  for (int index = 0; index < count; ++index) {
    int value = 0;
    const auto status =
        g_property_suite->propGetInt(properties, name, index, &value);
    if (index) text << ',';
    if (status == kOfxStatOK) text << value;
    else text << '<' << status_name(status) << '>';
  }
  return text.str() + ']';
}

std::string doubles_property(
    OfxPropertySetHandle properties, const char* name, int count) {
  if (!g_property_suite || !properties) return "<unavailable>";
  std::ostringstream text;
  text << '[' << std::setprecision(12);
  for (int index = 0; index < count; ++index) {
    double value = 0.0;
    const auto status =
        g_property_suite->propGetDouble(properties, name, index, &value);
    if (index) text << ',';
    if (status == kOfxStatOK) text << value;
    else text << '<' << status_name(status) << '>';
  }
  return text.str() + ']';
}

struct InstanceData {
  OfxImageClipHandle source = nullptr;
  OfxImageClipHandle output = nullptr;
  OfxParamHandle input_transform = nullptr;
  OfxParamHandle alpha_interpretation = nullptr;
  OfxParamHandle preview = nullptr;
  unsigned long long id = 0;
};

InstanceData* instance_data(OfxImageEffectHandle effect) noexcept {
  if (!g_image_suite || !g_property_suite || !effect) return nullptr;
  OfxPropertySetHandle properties = nullptr;
  if (g_image_suite->getPropertySet(effect, &properties) != kOfxStatOK) {
    return nullptr;
  }
  void* value = nullptr;
  if (g_property_suite->propGetPointer(
          properties, kOfxPropInstanceData, 0, &value) != kOfxStatOK) {
    return nullptr;
  }
  return static_cast<InstanceData*>(value);
}

std::string instance_prefix(const InstanceData* instance) {
  return "instance=" + std::to_string(instance ? instance->id : 0);
}

std::size_t bytes_per_component(const char* depth) noexcept {
  if (!depth) return 0;
  if (std::strcmp(depth, kOfxBitDepthByte) == 0) return 1;
  if (std::strcmp(depth, kOfxBitDepthShort) == 0 ||
      std::strcmp(depth, kOfxBitDepthHalf) == 0) return 2;
  if (std::strcmp(depth, kOfxBitDepthFloat) == 0) return 4;
  return 0;
}

bool pixel_depth(const char* depth, PixelDepth& output) noexcept {
  if (!depth) return false;
  if (std::strcmp(depth, kOfxBitDepthByte) == 0) output = PixelDepth::Byte;
  else if (std::strcmp(depth, kOfxBitDepthShort) == 0) output = PixelDepth::Short;
  else if (std::strcmp(depth, kOfxBitDepthHalf) == 0) output = PixelDepth::Half;
  else if (std::strcmp(depth, kOfxBitDepthFloat) == 0) output = PixelDepth::Float;
  else return false;
  return true;
}

struct OfxImageInfo {
  ImageView view{};
  const char* components = nullptr;
  const char* depth = nullptr;
  const char* premultiplication = nullptr;
  const char* colourspace = nullptr;
  double pixel_aspect = 0.0;
};

bool read_image_info(
    OfxPropertySetHandle image, OfxImageInfo& info) noexcept {
  if (!image || !g_property_suite) return false;
  void* data = nullptr;
  int bounds[4]{};
  int row_bytes = 0;
  char* components = nullptr;
  char* depth = nullptr;
  char* premultiplication = nullptr;
  if (g_property_suite->propGetPointer(
          image, kOfxImagePropData, 0, &data) != kOfxStatOK ||
      g_property_suite->propGetIntN(
          image, kOfxImagePropBounds, 4, bounds) != kOfxStatOK ||
      g_property_suite->propGetInt(
          image, kOfxImagePropRowBytes, 0, &row_bytes) != kOfxStatOK ||
      g_property_suite->propGetString(
          image, kOfxImageEffectPropComponents, 0,
          &components) != kOfxStatOK ||
      g_property_suite->propGetString(
          image, kOfxImageEffectPropPixelDepth, 0,
          &depth) != kOfxStatOK ||
      g_property_suite->propGetString(
          image, kOfxImageEffectPropPreMultiplication, 0,
          &premultiplication) != kOfxStatOK ||
      g_property_suite->propGetDouble(
          image, kOfxImagePropPixelAspectRatio, 0,
          &info.pixel_aspect) != kOfxStatOK ||
      !(info.pixel_aspect > 0.0)) {
    return false;
  }
  info.components = components;
  info.depth = depth;
  info.premultiplication = premultiplication;
  if (!info.components ||
      std::strcmp(info.components, kOfxImageComponentRGBA) != 0) {
    return false;
  }
  const auto component_bytes = bytes_per_component(info.depth);
  if (component_bytes == 0) return false;
  char* colourspace = nullptr;
  if (g_property_suite->propGetString(
          image, kOfxImageClipPropColourspace, 0,
          &colourspace) == kOfxStatOK) {
    info.colourspace = colourspace;
  }
  info.view = {
      static_cast<std::byte*>(data),
      {bounds[0], bounds[1], bounds[2], bounds[3]},
      static_cast<std::ptrdiff_t>(row_bytes),
      component_bytes * 4U,
  };
  return true;
}

bool same_raster_contract(const OfxImageInfo& source, const OfxImageInfo& output) {
  return source.components && output.components && source.depth && output.depth &&
      std::strcmp(source.components, output.components) == 0 &&
      std::strcmp(source.depth, output.depth) == 0 &&
      source.pixel_aspect == output.pixel_aspect;
}

OfxStatus load() {
  if (!g_host || !g_host->fetchSuite) return kOfxStatErrMissingHostFeature;
  g_image_suite = static_cast<const OfxImageEffectSuiteV1*>(
      g_host->fetchSuite(g_host->host, kOfxImageEffectSuite, 1));
  g_property_suite = static_cast<const OfxPropertySuiteV1*>(
      g_host->fetchSuite(g_host->host, kOfxPropertySuite, 1));
  g_parameter_suite = static_cast<const OfxParameterSuiteV1*>(
      g_host->fetchSuite(g_host->host, kOfxParameterSuite, 1));
  if (!g_image_suite || !g_property_suite || !g_parameter_suite) {
    return kOfxStatErrMissingHostFeature;
  }
  Logger::shared().write(
      "SESSION_BEGIN",
      "version=" SCREEN_SIMULATION_OFX_VERSION
      " sdk_commit=3de640d6f645fe6e346acd57e568d8b0a5ae4574"
      " host=" + string_property(g_host->host, kOfxPropName));
  return kOfxStatOK;
}

OfxStatus unload() {
  Logger::shared().write("SESSION_END");
  g_image_suite = nullptr;
  g_property_suite = nullptr;
  g_parameter_suite = nullptr;
  return kOfxStatOK;
}

OfxStatus describe(OfxImageEffectHandle effect) {
  OfxPropertySetHandle properties = nullptr;
  auto status = g_image_suite->getPropertySet(effect, &properties);
  if (status != kOfxStatOK) return status;
  g_property_suite->propSetString(properties, kOfxPropLabel, 0,
                                 "ScreenSimulation");
  g_property_suite->propSetString(properties, kOfxPropShortLabel, 0,
                                 "ScreenSimulation");
  g_property_suite->propSetString(properties, kOfxPropLongLabel, 0,
                                 "ScreenSimulation");
  g_property_suite->propSetString(
      properties, kOfxPropPluginDescription, 0,
      "ScreenSimulation physical imaging OFX for Resolve and Fusion. Preview "
      "Source is an exact passthrough; Preview Origin explicitly interprets "
      "Source RGB into the canonical linear ACEScg checkpoint.");
  g_property_suite->propSetString(
      properties, kOfxImageEffectPluginPropGrouping, 0, "Screen Simulation");
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropSupportedContexts, 0,
      kOfxImageEffectContextFilter);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropSupportedContexts, 1,
      kOfxImageEffectContextGeneral);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropSupportedPixelDepths, 0, kOfxBitDepthByte);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropSupportedPixelDepths, 1, kOfxBitDepthShort);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropSupportedPixelDepths, 2, kOfxBitDepthHalf);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropSupportedPixelDepths, 3, kOfxBitDepthFloat);
  g_property_suite->propSetInt(
      properties, kOfxImageEffectPropSupportsMultiResolution, 0, 1);
  g_property_suite->propSetInt(
      properties, kOfxImageEffectPropSupportsTiles, 0, 1);
  g_property_suite->propSetInt(
      properties, kOfxImageEffectPropSupportsMultipleClipDepths, 0, 0);
  g_property_suite->propSetInt(
      properties, kOfxImageEffectPropSupportsMultipleClipPARs, 0, 0);
  g_property_suite->propSetInt(
      properties, kOfxImageEffectPropTemporalClipAccess, 0, 0);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPluginRenderThreadSafety, 0,
      kOfxImageEffectRenderFullySafe);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropCPURenderSupported, 0, "true");
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropMetalRenderSupported, 0, "false");
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropCudaRenderSupported, 0, "false");
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropOpenCLRenderSupported, 0, "false");
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropColourManagementStyle, 0,
      kOfxImageEffectColourManagementFull);
  g_property_suite->propSetString(
      properties, kOfxImageEffectPropColourManagementAvailableConfigs, 0,
      kNativeColourConfig);
  Logger::shared().write(
      "DESCRIBE",
      "contexts=[Filter,General] components=[RGBA] depths=[Byte,Short,Half,Float] "
      "cpu=true gpu=false tiles=true colour_management=Full previews=[Source,Origin]");
  return kOfxStatOK;
}

using ChoiceCountFunction = std::size_t (*)();
using ChoiceValueFunction = ScreenOfxStringView (*)(std::size_t);

OfxStatus define_string_choice(
    OfxParamSetHandle parameter_set,
    const char* parameter_id,
    const char* label,
    const char* hint,
    const char* default_value,
    ChoiceCountFunction count,
    ChoiceValueFunction option_id,
    ChoiceValueFunction option_label) {
  OfxPropertySetHandle properties = nullptr;
  const auto status = g_parameter_suite->paramDefine(
      parameter_set, kOfxParamTypeStrChoice, parameter_id, &properties);
  if (status != kOfxStatOK) return status;
  g_property_suite->propSetString(properties, kOfxPropLabel, 0, label);
  g_property_suite->propSetString(properties, kOfxParamPropHint, 0, hint);
  g_property_suite->propSetString(
      properties, kOfxParamPropDefault, 0, default_value);
  g_property_suite->propSetInt(properties, kOfxParamPropAnimates, 0, 0);
  g_property_suite->propSetInt(properties, kOfxParamPropEvaluateOnChange, 0, 1);
  for (std::size_t index = 0; index < count(); ++index) {
    const auto id = bridge_string(option_id(index));
    const auto option = bridge_string(option_label(index));
    if (id.empty() || option.empty()) return kOfxStatErrValue;
    g_property_suite->propSetString(
        properties, kOfxParamPropChoiceEnum, static_cast<int>(index), id.c_str());
    g_property_suite->propSetString(
        properties, kOfxParamPropChoiceOption, static_cast<int>(index), option.c_str());
  }
  return kOfxStatOK;
}

OfxStatus describe_in_context(OfxImageEffectHandle effect) {
  OfxPropertySetHandle source_properties = nullptr;
  OfxPropertySetHandle output_properties = nullptr;
  auto status = g_image_suite->clipDefine(
      effect, kOfxImageEffectSimpleSourceClipName, &source_properties);
  if (status != kOfxStatOK) return status;
  status = g_image_suite->clipDefine(
      effect, kOfxImageEffectOutputClipName, &output_properties);
  if (status != kOfxStatOK) return status;
  for (const auto clip : {source_properties, output_properties}) {
    g_property_suite->propSetString(
        clip, kOfxImageEffectPropSupportedComponents, 0,
        kOfxImageComponentRGBA);
    g_property_suite->propSetInt(
        clip, kOfxImageEffectPropSupportsTiles, 0, 1);
  }
  g_property_suite->propSetInt(
      source_properties, kOfxImageClipPropOptional, 0, 0);
  OfxParamSetHandle parameter_set = nullptr;
  status = g_image_suite->getParamSet(effect, &parameter_set);
  if (status != kOfxStatOK) return status;
  status = define_string_choice(
      parameter_set,
      kInputTransformParameter,
      "Input Transform",
      "Required for Origin. Select the actual RGB encoding delivered by the host; "
      "Resolve and Fusion do not publish it reliably through OFX.",
      "unselected",
      screen_ofx_origin_input_transform_count,
      screen_ofx_origin_input_transform_id,
      screen_ofx_origin_input_transform_label);
  if (status != kOfxStatOK) return status;
  status = define_string_choice(
      parameter_set,
      kAlphaInterpretationParameter,
      "Alpha Interpretation",
      "Authored interpretation of Source RGB and alpha.",
      "premultiplied",
      screen_ofx_origin_alpha_count,
      screen_ofx_origin_alpha_id,
      screen_ofx_origin_alpha_label);
  if (status != kOfxStatOK) return status;
  status = define_string_choice(
      parameter_set,
      kPreviewParameter,
      "Preview",
      "Source is exact passthrough. Origin evaluates the canonical linear ACEScg "
      "checkpoint and presents it back in the selected Input Transform encoding.",
      "source",
      screen_ofx_origin_preview_count,
      screen_ofx_origin_preview_id,
      screen_ofx_origin_preview_label);
  if (status != kOfxStatOK) return status;
  Logger::shared().write(
      "DESCRIBE_IN_CONTEXT",
      "Source=RGBA Output=RGBA parameters=[input-transform,alpha-interpretation,preview] "
      "origin_schema=" + std::to_string(screen_ofx_origin_schema_version()));
  return kOfxStatOK;
}

OfxStatus create_instance(OfxImageEffectHandle effect) {
  auto* instance = new InstanceData;
  instance->id = g_instance_sequence.fetch_add(1);
  auto status = g_image_suite->clipGetHandle(
      effect, kOfxImageEffectSimpleSourceClipName, &instance->source, nullptr);
  if (status == kOfxStatOK) {
    status = g_image_suite->clipGetHandle(
        effect, kOfxImageEffectOutputClipName, &instance->output, nullptr);
  }
  OfxParamSetHandle parameter_set = nullptr;
  if (status == kOfxStatOK) {
    status = g_image_suite->getParamSet(effect, &parameter_set);
  }
  if (status == kOfxStatOK) {
    status = g_parameter_suite->paramGetHandle(
        parameter_set, kInputTransformParameter, &instance->input_transform, nullptr);
  }
  if (status == kOfxStatOK) {
    status = g_parameter_suite->paramGetHandle(
        parameter_set, kAlphaInterpretationParameter,
        &instance->alpha_interpretation, nullptr);
  }
  if (status == kOfxStatOK) {
    status = g_parameter_suite->paramGetHandle(
        parameter_set, kPreviewParameter, &instance->preview, nullptr);
  }
  OfxPropertySetHandle properties = nullptr;
  if (status == kOfxStatOK) {
    status = g_image_suite->getPropertySet(effect, &properties);
  }
  if (status == kOfxStatOK) {
    status = g_property_suite->propSetPointer(
        properties, kOfxPropInstanceData, 0, instance);
  }
  if (status != kOfxStatOK) {
    delete instance;
    return status;
  }
  Logger::shared().write("INSTANCE_CREATE", instance_prefix(instance));
  return kOfxStatOK;
}

OfxStatus destroy_instance(OfxImageEffectHandle effect) {
  auto* instance = instance_data(effect);
  Logger::shared().write("INSTANCE_DESTROY", instance_prefix(instance));
  OfxPropertySetHandle properties = nullptr;
  if (g_image_suite->getPropertySet(effect, &properties) == kOfxStatOK) {
    g_property_suite->propSetPointer(properties, kOfxPropInstanceData, 0, nullptr);
  }
  delete instance;
  return kOfxStatOK;
}

OfxStatus region_of_definition(
    OfxImageEffectHandle effect,
    OfxPropertySetHandle in_args,
    OfxPropertySetHandle out_args) {
  auto* instance = instance_data(effect);
  if (!instance) return kOfxStatErrBadHandle;
  double time = 0.0;
  g_property_suite->propGetDouble(in_args, kOfxPropTime, 0, &time);
  OfxRectD source_rod{};
  const auto status = g_image_suite->clipGetRegionOfDefinition(
      instance->source, time, &source_rod);
  if (status != kOfxStatOK) return status;
  Logger::shared().write(
      "REGION_OF_DEFINITION",
      instance_prefix(instance) + " source=[" +
          std::to_string(source_rod.x1) + ',' + std::to_string(source_rod.y1) +
          ',' + std::to_string(source_rod.x2) + ',' +
          std::to_string(source_rod.y2) + ']');
  return g_property_suite->propSetDoubleN(
      out_args, kOfxImageEffectPropRegionOfDefinition, 4, &source_rod.x1);
}

OfxStatus regions_of_interest(
    OfxImageEffectHandle effect,
    OfxPropertySetHandle in_args,
    OfxPropertySetHandle out_args) {
  if (!instance_data(effect)) return kOfxStatErrBadHandle;
  double roi[4]{};
  const auto status = g_property_suite->propGetDoubleN(
      in_args, kOfxImageEffectPropRegionOfInterest, 4, roi);
  if (status != kOfxStatOK) return kOfxStatReplyDefault;
  Logger::shared().write(
      "REGIONS_OF_INTEREST",
      "output=" + doubles_property(
          in_args, kOfxImageEffectPropRegionOfInterest, 4));
  return g_property_suite->propSetDoubleN(
      out_args, kSourceRoiProperty, 4, roi);
}

OfxStatus clip_preferences(
    OfxImageEffectHandle effect, OfxPropertySetHandle out_args) {
  auto* instance = instance_data(effect);
  if (!instance) return kOfxStatErrBadHandle;
  OfxPropertySetHandle source_properties = nullptr;
  const auto status = g_image_suite->clipGetPropertySet(
      instance->source, &source_properties);
  if (status != kOfxStatOK) return status;
  char* components = nullptr;
  char* depth = nullptr;
  char* premultiplication = nullptr;
  char* alpha_interpretation = nullptr;
  if (g_property_suite->propGetString(
          source_properties, kOfxImageEffectPropComponents, 0,
          &components) != kOfxStatOK ||
      g_property_suite->propGetString(
          source_properties, kOfxImageEffectPropPixelDepth, 0,
          &depth) != kOfxStatOK ||
      g_property_suite->propGetString(
          source_properties, kOfxImageEffectPropPreMultiplication, 0,
          &premultiplication) != kOfxStatOK ||
      g_parameter_suite->paramGetValue(
          instance->alpha_interpretation, &alpha_interpretation) != kOfxStatOK ||
      !alpha_interpretation) {
    return kOfxStatErrFormat;
  }
  const char* output_premultiplication = nullptr;
  if (std::strcmp(alpha_interpretation, "premultiplied") == 0) {
    output_premultiplication = kOfxImagePreMultiplied;
  } else if (std::strcmp(alpha_interpretation, "straight") == 0) {
    output_premultiplication = kOfxImageUnPreMultiplied;
  } else if (std::strcmp(alpha_interpretation, "ignore") == 0) {
    output_premultiplication = kOfxImageOpaque;
  } else {
    return kOfxStatErrValue;
  }
  g_property_suite->propSetString(
      out_args, kOutputComponentsProperty, 0, components);
  g_property_suite->propSetString(
      out_args, kOutputDepthProperty, 0, depth);
  g_property_suite->propSetString(
      out_args, kOfxImageEffectPropPreMultiplication, 0,
      output_premultiplication);
  g_property_suite->propSetInt(out_args, kOfxImageEffectFrameVarying, 0, 0);
  Logger::shared().write(
      "CLIP_PREFERENCES",
      instance_prefix(instance) + " components=" + quoted(components) +
          " depth=" + quoted(depth) +
          " source_premultiplication=" + quoted(premultiplication) +
          " authored_alpha=" + quoted(alpha_interpretation) +
          " output_premultiplication=" + quoted(output_premultiplication) +
          " source_colourspace=" +
          string_property(source_properties, kOfxImageClipPropColourspace));
  return kOfxStatOK;
}

OfxStatus output_colourspace(
    OfxImageEffectHandle effect,
    OfxPropertySetHandle in_args,
    OfxPropertySetHandle out_args) {
  auto* instance = instance_data(effect);
  if (!instance) return kOfxStatErrBadHandle;
  const auto status = g_property_suite->propSetString(
      out_args, kOfxImageClipPropColourspace, 0, "OfxColourspace_Source");
  Logger::shared().write(
      "OUTPUT_COLOURSPACE",
      instance_prefix(instance) + " requested=\"OfxColourspace_Source\"" +
          " host_first_preference=" +
          string_property(in_args, kOfxImageClipPropPreferredColourspaces));
  return status;
}

OfxStatus render(
    OfxImageEffectHandle effect, OfxPropertySetHandle in_args) {
  auto* instance = instance_data(effect);
  if (!instance) return kOfxStatErrBadHandle;
  int metal_enabled = 0;
  int cuda_enabled = 0;
  int opencl_enabled = 0;
  g_property_suite->propGetInt(
      in_args, kOfxImageEffectPropMetalEnabled, 0, &metal_enabled);
  g_property_suite->propGetInt(
      in_args, kOfxImageEffectPropCudaEnabled, 0, &cuda_enabled);
  g_property_suite->propGetInt(
      in_args, kOfxImageEffectPropOpenCLEnabled, 0, &opencl_enabled);
  if (metal_enabled || cuda_enabled || opencl_enabled) {
    Logger::shared().write(
        "RENDER_REJECTED",
        instance_prefix(instance) + " reason=gpu-buffer cpu_only=true");
    return kOfxStatGPURenderFailed;
  }
  double time = 0.0;
  int window[4]{};
  if (g_property_suite->propGetDouble(
          in_args, kOfxPropTime, 0, &time) != kOfxStatOK ||
      g_property_suite->propGetIntN(
          in_args, kOfxImageEffectPropRenderWindow, 4,
          window) != kOfxStatOK) {
    return kOfxStatErrValue;
  }
  OfxPropertySetHandle source_image = nullptr;
  OfxPropertySetHandle output_image = nullptr;
  const auto source_status = g_image_suite->clipGetImage(
      instance->source, time, nullptr, &source_image);
  const auto output_status = g_image_suite->clipGetImage(
      instance->output, time, nullptr, &output_image);
  if (source_status != kOfxStatOK || !source_image ||
      output_status != kOfxStatOK || !output_image) {
    if (source_image) g_image_suite->clipReleaseImage(source_image);
    if (output_image) g_image_suite->clipReleaseImage(output_image);
    Logger::shared().write(
        "RENDER_REJECTED",
        instance_prefix(instance) + " reason=image-fetch" +
            " source_status=" + status_name(source_status) +
            " output_status=" + status_name(output_status));
    return kOfxStatFailed;
  }
  OfxImageInfo source_info;
  OfxImageInfo output_info;
  const bool source_valid = read_image_info(source_image, source_info);
  const bool output_valid = read_image_info(output_image, output_info);
  char* input_transform = nullptr;
  char* alpha_interpretation = nullptr;
  char* preview = nullptr;
  const bool parameters_valid =
      g_parameter_suite->paramGetValueAtTime(
          instance->input_transform, time, &input_transform) == kOfxStatOK &&
      g_parameter_suite->paramGetValueAtTime(
          instance->alpha_interpretation, time, &alpha_interpretation) == kOfxStatOK &&
      g_parameter_suite->paramGetValueAtTime(
          instance->preview, time, &preview) == kOfxStatOK &&
      input_transform && alpha_interpretation && preview;
  const RectI render_window{window[0], window[1], window[2], window[3]};
  bool render_ok = false;
  std::string render_status = "invalid-contract";
  if (source_valid && output_valid && parameters_valid &&
      same_raster_contract(source_info, output_info)) {
    if (std::strcmp(preview, "source") == 0) {
      const auto copy_status = screen_simulation::ofx::copy_identity(
          source_info.view, output_info.view, render_window);
      render_ok = copy_status == IdentityCopyStatus::Ok;
      render_status = "source-" + std::string(copy_status_name(copy_status));
    } else if (std::strcmp(preview, "origin") == 0) {
      PixelDepth depth = PixelDepth::Float;
      if (!pixel_depth(source_info.depth, depth)) {
        render_status = "origin-unsupported-depth";
      } else {
        std::vector<float> encoded;
        const auto read_status = screen_simulation::ofx::read_origin_window_rgba32f(
            source_info.view, depth, render_window, encoded);
        if (read_status != OriginIoStatus::Ok) {
          render_status = "origin-read-" +
              std::string(origin_io_status_name(read_status));
        } else {
          std::vector<float> presented(encoded.size());
          const auto width = static_cast<std::uint32_t>(render_window.x2 - render_window.x1);
          const auto height = static_cast<std::uint32_t>(render_window.y2 - render_window.y1);
          const auto bridge_status = screen_ofx_origin_process_rgba32f(
              input_transform,
              alpha_interpretation,
              preview,
              width,
              height,
              encoded.data(),
              presented.data());
          if (bridge_status != 0) {
            render_status = "origin-bridge-" +
                bridge_string(screen_ofx_origin_error_message(bridge_status));
          } else {
            const auto write_status =
                screen_simulation::ofx::write_origin_window_rgba32f(
                    presented, output_info.view, depth, render_window);
            render_ok = write_status == OriginIoStatus::Ok;
            render_status = "origin-" +
                std::string(origin_io_status_name(write_status));
          }
        }
      }
    } else {
      render_status = "unknown-preview";
    }
  }
  Logger::shared().write(
      "RENDER",
      instance_prefix(instance) + " time=" + std::to_string(time) +
          " render_window=" +
          ints_property(in_args, kOfxImageEffectPropRenderWindow, 4) +
          " render_scale=" +
          doubles_property(in_args, kOfxImageEffectPropRenderScale, 2) +
          " source_bounds=" +
          ints_property(source_image, kOfxImagePropBounds, 4) +
          " output_bounds=" +
          ints_property(output_image, kOfxImagePropBounds, 4) +
          " source_depth=" + quoted(source_info.depth) +
          " output_depth=" + quoted(output_info.depth) +
          " source_premultiplication=" +
          quoted(source_info.premultiplication) +
          " output_premultiplication=" +
          quoted(output_info.premultiplication) +
          " source_PAR=" + std::to_string(source_info.pixel_aspect) +
          " output_PAR=" + std::to_string(output_info.pixel_aspect) +
          " source_colourspace=" + quoted(source_info.colourspace) +
          " output_colourspace=" + quoted(output_info.colourspace) +
          " input_transform=" + quoted(input_transform) +
          " alpha_interpretation=" + quoted(alpha_interpretation) +
          " preview=" + quoted(preview) +
          " status=" + render_status);
  g_image_suite->clipReleaseImage(source_image);
  g_image_suite->clipReleaseImage(output_image);
  return render_ok ? kOfxStatOK : kOfxStatFailed;
}

OfxStatus plugin_main(
    const char* action,
    const void* handle,
    OfxPropertySetHandle in_args,
    OfxPropertySetHandle out_args) noexcept {
  try {
    const auto effect = reinterpret_cast<OfxImageEffectHandle>(
        const_cast<void*>(handle));
    OfxStatus status = kOfxStatReplyDefault;
    if (std::strcmp(action, kOfxActionLoad) == 0) status = load();
    else if (std::strcmp(action, kOfxActionUnload) == 0) status = unload();
    else if (std::strcmp(action, kOfxActionDescribe) == 0)
      status = describe(effect);
    else if (std::strcmp(
                 action, kOfxImageEffectActionDescribeInContext) == 0)
      status = describe_in_context(effect);
    else if (std::strcmp(action, kOfxActionCreateInstance) == 0)
      status = create_instance(effect);
    else if (std::strcmp(action, kOfxActionDestroyInstance) == 0)
      status = destroy_instance(effect);
    else if (std::strcmp(
                 action, kOfxImageEffectActionGetRegionOfDefinition) == 0)
      status = region_of_definition(effect, in_args, out_args);
    else if (std::strcmp(
                 action, kOfxImageEffectActionGetRegionsOfInterest) == 0)
      status = regions_of_interest(effect, in_args, out_args);
    else if (std::strcmp(
                 action, kOfxImageEffectActionGetClipPreferences) == 0)
      status = clip_preferences(effect, out_args);
    else if (std::strcmp(
                 action, kOfxImageEffectActionGetOutputColourspace) == 0)
      status = output_colourspace(effect, in_args, out_args);
    else if (std::strcmp(action, kOfxImageEffectActionRender) == 0)
      status = render(effect, in_args);
    Logger::shared().write(
        "ACTION", "name=" + quoted(action) + " status=" + status_name(status));
    return status;
  } catch (const std::bad_alloc&) {
    Logger::shared().write("EXCEPTION", "type=bad_alloc");
    return kOfxStatErrMemory;
  } catch (...) {
    Logger::shared().write("EXCEPTION", "type=unknown");
    return kOfxStatErrUnknown;
  }
}

void set_host(OfxHost* host) {
  g_host = host;
}

OfxPlugin g_plugin = {
    kOfxImageEffectPluginApi,
    1,
    kPluginIdentifier,
    0,
    2,
    set_host,
    plugin_main,
};

}  // namespace

extern "C" SCREEN_OFX_EXPORT OfxPlugin* OfxGetPlugin(int index) {
  return index == 0 ? &g_plugin : nullptr;
}

extern "C" SCREEN_OFX_EXPORT int OfxGetNumberOfPlugins() {
  return 1;
}

extern "C" SCREEN_OFX_EXPORT OfxStatus OfxSetHost(const OfxHost* host) {
  g_host = const_cast<OfxHost*>(host);
  return kOfxStatOK;
}
