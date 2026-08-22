// Narrow Metal OpenFX host for the packaged WIP Review effect.
// Host infrastructure is the official ASWF OpenFX HostSupport submodule;
// no WIP Review renderer source is linked or reproduced here.

#include <ofxCore.h>
#include <ofxImageEffect.h>
#include <ofxGPURender.h>
#include <ofxPixels.h>
#include <ofxhBinary.h>
#include <ofxhPropertySuite.h>
#include <ofxhClip.h>
#include <ofxhParam.h>
#include <ofxhMemory.h>
#include <ofxhImageEffect.h>
#include <ofxhPluginAPICache.h>
#include <ofxhPluginCache.h>
#include <ofxhHost.h>
#include <ofxhImageEffectAPI.h>

#import <Metal/Metal.h>

#include <array>
#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <list>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace ScreenWIPHost {

struct ParameterValue {
  enum class Kind { Integer, Double, String, RGBA } kind = Kind::Integer;
  int integer = 0;
  double number = 0;
  std::string text;
  std::array<double, 4> rgba{0, 0, 0, 0};
};

struct RenderContext {
  int sourceWidth = 0;
  int sourceHeight = 0;
  int outputWidth = 0;
  int outputHeight = 0;
  double time = 0;
  double frameRate = 24;
  std::vector<float> source;
  std::vector<float> output;
  id<MTLDevice> metalDevice = nil;
  id<MTLCommandQueue> metalCommandQueue = nil;
  id<MTLBuffer> sourceBuffer = nil;
  id<MTLBuffer> outputBuffer = nil;
  std::unordered_map<std::string, ParameterValue> parameters;
};

RenderContext gRender;

const ParameterValue* configured(const std::string& name) {
  const auto found = gRender.parameters.find(name);
  return found == gRender.parameters.end() ? nullptr : &found->second;
}

class EffectInstance;

class FloatImage final : public OFX::Host::ImageEffect::Image {
 public:
  FloatImage(OFX::Host::ImageEffect::ClipInstance& clip, bool output)
      : OFX::Host::ImageEffect::Image(clip) {
    const int width = output ? gRender.outputWidth : gRender.sourceWidth;
    const int height = output ? gRender.outputHeight : gRender.sourceHeight;
    id<MTLBuffer> buffer = output ? gRender.outputBuffer : gRender.sourceBuffer;
    const int stride = width * 4 * static_cast<int>(sizeof(float));
    setDoubleProperty(kOfxImageEffectPropRenderScale, 1, 0);
    setDoubleProperty(kOfxImageEffectPropRenderScale, 1, 1);
    setPointerProperty(kOfxImagePropData, (__bridge void*)buffer);
    setIntProperty(kOfxImagePropRowBytes, stride);
    for (const char* property : {kOfxImagePropBounds, kOfxImagePropRegionOfDefinition}) {
      setIntProperty(property, 0, 0);
      setIntProperty(property, 0, 1);
      setIntProperty(property, width, 2);
      setIntProperty(property, height, 3);
    }
    setStringProperty(kOfxImageEffectPropComponents, kOfxImageComponentRGBA);
    setStringProperty(kOfxImageEffectPropPixelDepth, kOfxBitDepthFloat);
    setStringProperty(kOfxImageEffectPropPreMultiplication, kOfxImageUnPreMultiplied);
    setDoubleProperty(kOfxImagePropPixelAspectRatio, 1);
    setStringProperty(kOfxImagePropField, kOfxImageFieldNone);
  }
};

class ClipInstance final : public OFX::Host::ImageEffect::ClipInstance {
 public:
  ClipInstance(EffectInstance* effect, OFX::Host::ImageEffect::ClipDescriptor* descriptor);
  const std::string& getUnmappedBitDepth() const override {
    static const std::string value(kOfxBitDepthFloat); return value;
  }
  const std::string& getUnmappedComponents() const override {
    static const std::string value(kOfxImageComponentRGBA); return value;
  }
  const std::string& getPremult() const override {
    static const std::string value(kOfxImageUnPreMultiplied); return value;
  }
  double getAspectRatio() const override { return 1; }
  double getFrameRate() const override { return gRender.frameRate; }
  void getFrameRange(double& start, double& end) const override { start = end = gRender.time; }
  const std::string& getFieldOrder() const override {
    static const std::string value(kOfxImageFieldNone); return value;
  }
  bool getConnected() const override { return true; }
  double getUnmappedFrameRate() const override { return gRender.frameRate; }
  void getUnmappedFrameRange(double& start, double& end) const override { start = end = gRender.time; }
  bool getContinuousSamples() const override { return false; }
  OFX::Host::ImageEffect::Image* getImage(OfxTime, const OfxRectD*) override {
    return new FloatImage(*this, name_ == "Output");
  }
  OfxRectD getRegionOfDefinition(OfxTime) const override {
    const bool output = name_ == "Output";
    return {0, 0, static_cast<double>(output ? gRender.outputWidth : gRender.sourceWidth),
            static_cast<double>(output ? gRender.outputHeight : gRender.sourceHeight)};
  }
 private:
  std::string name_;
};

int defaultInt(OFX::Host::Param::Descriptor& descriptor) {
  try { return descriptor.getProperties().getIntProperty(kOfxParamPropDefault); } catch (...) { return 0; }
}
double defaultDouble(OFX::Host::Param::Descriptor& descriptor) {
  try { return descriptor.getProperties().getDoubleProperty(kOfxParamPropDefault); } catch (...) { return 0; }
}
std::string defaultString(OFX::Host::Param::Descriptor& descriptor) {
  try { return descriptor.getProperties().getStringProperty(kOfxParamPropDefault); } catch (...) { return {}; }
}

class IntegerParam final : public OFX::Host::Param::IntegerInstance {
 public:
  IntegerParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
               OFX::Host::Param::SetInstance* owner)
      : IntegerInstance(descriptor, owner), name_(name), value_(configured(name) ? configured(name)->integer : defaultInt(descriptor)) {}
  OfxStatus get(int& value) override { value = configured(name_) ? configured(name_)->integer : value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, int& value) override { return get(value); }
  OfxStatus set(int value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, int value) override { return set(value); }
 private: std::string name_; int value_;
};

class ChoiceParam final : public OFX::Host::Param::ChoiceInstance {
 public:
  ChoiceParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
              OFX::Host::Param::SetInstance* owner)
      : ChoiceInstance(descriptor, owner), name_(name), value_(configured(name) ? configured(name)->integer : defaultInt(descriptor)) {}
  OfxStatus get(int& value) override { value = configured(name_) ? configured(name_)->integer : value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, int& value) override { return get(value); }
  OfxStatus set(int value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, int value) override { return set(value); }
 private: std::string name_; int value_;
};

class BooleanParam final : public OFX::Host::Param::BooleanInstance {
 public:
  BooleanParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
               OFX::Host::Param::SetInstance* owner)
      : BooleanInstance(descriptor, owner), name_(name), value_(configured(name) ? configured(name)->integer != 0 : defaultInt(descriptor) != 0) {}
  OfxStatus get(bool& value) override { value = configured(name_) ? configured(name_)->integer != 0 : value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, bool& value) override { return get(value); }
  OfxStatus set(bool value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, bool value) override { return set(value); }
 private: std::string name_; bool value_;
};

class DoubleParam final : public OFX::Host::Param::DoubleInstance {
 public:
  DoubleParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
              OFX::Host::Param::SetInstance* owner)
      : DoubleInstance(descriptor, owner), name_(name), value_(configured(name) ? configured(name)->number : defaultDouble(descriptor)) {}
  OfxStatus get(double& value) override { value = configured(name_) ? configured(name_)->number : value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, double& value) override { return get(value); }
  OfxStatus set(double value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, double value) override { return set(value); }
  OfxStatus derive(OfxTime, double& value) override { value = 0; return kOfxStatOK; }
  OfxStatus integrate(OfxTime a, OfxTime b, double& value) override {
    double current = 0; get(current); value = current * (b - a); return kOfxStatOK;
  }
 private: std::string name_; double value_;
};

class StringParam final : public OFX::Host::Param::StringInstance {
 public:
  StringParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
              OFX::Host::Param::SetInstance* owner)
      : StringInstance(descriptor, owner), name_(name), value_(configured(name) ? configured(name)->text : defaultString(descriptor)) {}
  OfxStatus get(std::string& value) override { value = configured(name_) ? configured(name_)->text : value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, std::string& value) override { return get(value); }
  OfxStatus set(const char* value) override { value_ = value ? value : ""; return kOfxStatOK; }
  OfxStatus set(OfxTime, const char* value) override { return set(value); }
 private: std::string name_; std::string value_;
};

class RGBAParam final : public OFX::Host::Param::RGBAInstance {
 public:
  RGBAParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
            OFX::Host::Param::SetInstance* owner)
      : RGBAInstance(descriptor, owner), name_(name) {
    if (const auto* value = configured(name)) values_ = value->rgba;
    else for (int i = 0; i < 4; ++i) {
      try { values_[i] = descriptor.getProperties().getDoubleProperty(kOfxParamPropDefault, i); }
      catch (...) { values_[i] = i == 3 ? 1 : 0; }
    }
  }
  OfxStatus get(double& r,double& g,double& b,double& a) override {
    const auto values = configured(name_) ? configured(name_)->rgba : values_;
    r=values[0];g=values[1];b=values[2];a=values[3];return kOfxStatOK;
  }
  OfxStatus get(OfxTime,double& r,double& g,double& b,double& a) override { return get(r,g,b,a); }
  OfxStatus set(double r,double g,double b,double a) override { values_={r,g,b,a};return kOfxStatOK; }
  OfxStatus set(OfxTime,double r,double g,double b,double a) override { return set(r,g,b,a); }
 private: std::string name_; std::array<double,4> values_{};
};

class EffectInstance final : public OFX::Host::ImageEffect::Instance {
 public:
  EffectInstance(OFX::Host::ImageEffect::ImageEffectPlugin* plugin,
                 OFX::Host::ImageEffect::Descriptor& descriptor,
                 const std::string& context)
      : Instance(plugin, descriptor, context, false) {}
  OFX::Host::ImageEffect::ClipInstance* newClipInstance(
      OFX::Host::ImageEffect::Instance*, OFX::Host::ImageEffect::ClipDescriptor* descriptor,
      int) override { return new ClipInstance(this, descriptor); }
  const std::string& getDefaultOutputFielding() const override {
    static const std::string value(kOfxImageFieldNone); return value;
  }
  OfxStatus vmessage(const char*, const char*, const char*, va_list) override { return kOfxStatOK; }
  OfxStatus setPersistentMessage(const char*, const char*, const char*, va_list) override { return kOfxStatOK; }
  OfxStatus clearPersistentMessage() override { return kOfxStatOK; }
  void getProjectSize(double& x, double& y) const override { x=gRender.outputWidth;y=gRender.outputHeight; }
  void getProjectOffset(double& x, double& y) const override { x=y=0; }
  void getProjectExtent(double& x, double& y) const override { x=gRender.outputWidth;y=gRender.outputHeight; }
  double getProjectPixelAspectRatio() const override { return 1; }
  double getEffectDuration() const override { return 1; }
  double getFrameRate() const override { return gRender.frameRate; }
  double getFrameRecursive() const override { return gRender.time; }
  void getRenderScaleRecursive(double& x, double& y) const override { x=y=1; }
  OFX::Host::Param::Instance* newParam(
      const std::string& name, OFX::Host::Param::Descriptor& descriptor) override {
    const std::string type = descriptor.getType();
    if (type == kOfxParamTypeInteger) return new IntegerParam(name, descriptor, this);
    if (type == kOfxParamTypeChoice) return new ChoiceParam(name, descriptor, this);
    if (type == kOfxParamTypeBoolean) return new BooleanParam(name, descriptor, this);
    if (type == kOfxParamTypeDouble) return new DoubleParam(name, descriptor, this);
    if (type == kOfxParamTypeString) return new StringParam(name, descriptor, this);
    if (type == kOfxParamTypeRGBA) return new RGBAParam(name, descriptor, this);
    if (type == kOfxParamTypeGroup) return new OFX::Host::Param::GroupInstance(descriptor, this);
    if (type == kOfxParamTypePage) return new OFX::Host::Param::PageInstance(descriptor, this);
    if (type == kOfxParamTypePushButton) return new OFX::Host::Param::PushbuttonInstance(descriptor, this);
    return nullptr;
  }
  OfxStatus editBegin(const std::string&) override { return kOfxStatOK; }
  OfxStatus editEnd() override { return kOfxStatOK; }
  void progressStart(const std::string&, const std::string&) override {}
  void progressEnd() override {}
  bool progressUpdate(double) override { return true; }
  double timeLineGetTime() override { return gRender.time; }
  void timeLineGotoTime(double time) override { gRender.time=time; }
  void timeLineGetBounds(double& first, double& last) override { first=last=gRender.time; }
  OfxStatus renderAction(OfxTime time, const std::string& field,
                         const OfxRectI& renderRoI, OfxPointD renderScale,
                         bool sequentialRender, bool interactiveRender,
                         bool draftRender) override {
    static const OFX::Host::Property::PropSpec properties[] = {
      {kOfxPropTime, OFX::Host::Property::eDouble, 1, true, "0"},
      {kOfxImageEffectPropFieldToRender, OFX::Host::Property::eString, 1, true, ""},
      {kOfxImageEffectPropRenderWindow, OFX::Host::Property::eInt, 4, true, "0"},
      {kOfxImageEffectPropRenderScale, OFX::Host::Property::eDouble, 2, true, "0"},
      {kOfxImageEffectPropSequentialRenderStatus, OFX::Host::Property::eInt, 1, true, "0"},
      {kOfxImageEffectPropInteractiveRenderStatus, OFX::Host::Property::eInt, 1, true, "0"},
      {kOfxImageEffectPropRenderQualityDraft, OFX::Host::Property::eInt, 1, true, "0"},
      {kOfxImageEffectPropMetalEnabled, OFX::Host::Property::eInt, 1, true, "0"},
      {kOfxImageEffectPropMetalCommandQueue, OFX::Host::Property::ePointer, 1, true, nullptr},
      OFX::Host::Property::propSpecEnd
    };
    OFX::Host::Property::Set inArgs(properties);
    inArgs.setStringProperty(kOfxImageEffectPropFieldToRender, field);
    inArgs.setDoubleProperty(kOfxPropTime, time);
    inArgs.setIntPropertyN(kOfxImageEffectPropRenderWindow, &renderRoI.x1, 4);
    inArgs.setDoublePropertyN(kOfxImageEffectPropRenderScale, &renderScale.x, 2);
    inArgs.setIntProperty(kOfxImageEffectPropSequentialRenderStatus, sequentialRender);
    inArgs.setIntProperty(kOfxImageEffectPropInteractiveRenderStatus, interactiveRender);
    inArgs.setIntProperty(kOfxImageEffectPropRenderQualityDraft, draftRender);
    inArgs.setIntProperty(kOfxImageEffectPropMetalEnabled, 1);
    inArgs.setPointerProperty(kOfxImageEffectPropMetalCommandQueue,
                              (__bridge void*)gRender.metalCommandQueue);
    return mainEntry(kOfxImageEffectActionRender, getHandle(), &inArgs, nullptr);
  }
};

ClipInstance::ClipInstance(EffectInstance* effect,
                           OFX::Host::ImageEffect::ClipDescriptor* descriptor)
    : OFX::Host::ImageEffect::ClipInstance(effect, *descriptor),
      name_(descriptor->getName()) {}

class Host final : public OFX::Host::ImageEffect::Host {
 public:
  Host() {
    _properties.setIntProperty(kOfxPropAPIVersion, 1, 0);
    _properties.setIntProperty(kOfxPropAPIVersion, 4, 1);
    _properties.setStringProperty(kOfxPropName, "com.jtorrens.screensimulation.native");
    _properties.setStringProperty(kOfxPropLabel, "SCREEN-SIMULATION");
    _properties.setIntProperty(kOfxPropVersion, 1, 0);
    _properties.setIntProperty(kOfxPropVersion, 0, 1);
    _properties.setIntProperty(kOfxImageEffectHostPropIsBackground, 1);
    _properties.setIntProperty(kOfxImageEffectPropSupportsOverlays, 0);
    _properties.setIntProperty(kOfxImageEffectPropSupportsMultiResolution, 1);
    _properties.setIntProperty(kOfxImageEffectPropSupportsTiles, 0);
    _properties.setIntProperty(kOfxImageEffectPropTemporalClipAccess, 0);
    _properties.setStringProperty(kOfxImageEffectPropSupportedComponents, kOfxImageComponentRGBA, 0);
    _properties.setStringProperty(kOfxImageEffectPropSupportedComponents, kOfxImageComponentRGB, 1);
    _properties.setStringProperty(kOfxImageEffectPropSupportedContexts, kOfxImageEffectContextFilter, 0);
    _properties.setStringProperty(kOfxImageEffectPropSupportedContexts, kOfxImageEffectContextGeneral, 1);
    _properties.setStringProperty(kOfxImageEffectPropSupportedPixelDepths, kOfxBitDepthFloat, 0);
    _properties.setIntProperty(kOfxImageEffectPropSupportsMultipleClipDepths, 0);
    _properties.setIntProperty(kOfxImageEffectPropSupportsMultipleClipPARs, 1);
    _properties.setIntProperty(kOfxImageEffectPropSetableFrameRate, 0);
    _properties.setIntProperty(kOfxImageEffectPropSetableFielding, 0);
    _properties.setIntProperty(kOfxParamHostPropSupportsCustomInteract, 0);
    _properties.setIntProperty(kOfxParamHostPropSupportsStringAnimation, 0);
    _properties.setIntProperty(kOfxParamHostPropSupportsChoiceAnimation, 0);
    _properties.setIntProperty(kOfxParamHostPropSupportsBooleanAnimation, 0);
    _properties.setIntProperty(kOfxParamHostPropSupportsCustomAnimation, 0);
    _properties.setIntProperty(kOfxParamHostPropMaxParameters, -1);
    _properties.setIntProperty(kOfxParamHostPropMaxPages, -1);
    _properties.setStringProperty(kOfxImageEffectPropCPURenderSupported, "false");
    _properties.setStringProperty(kOfxImageEffectPropMetalRenderSupported, "true");
  }
  OFX::Host::ImageEffect::Instance* newInstance(
      void*, OFX::Host::ImageEffect::ImageEffectPlugin* plugin,
      OFX::Host::ImageEffect::Descriptor& descriptor,
      const std::string& context) override {
    return new EffectInstance(plugin, descriptor, context);
  }
  OFX::Host::ImageEffect::Descriptor* makeDescriptor(
      OFX::Host::ImageEffect::ImageEffectPlugin* plugin) override {
    return new OFX::Host::ImageEffect::Descriptor(plugin);
  }
  OFX::Host::ImageEffect::Descriptor* makeDescriptor(
      const OFX::Host::ImageEffect::Descriptor& root,
      OFX::Host::ImageEffect::ImageEffectPlugin* plugin) override {
    return new OFX::Host::ImageEffect::Descriptor(root, plugin);
  }
  OFX::Host::ImageEffect::Descriptor* makeDescriptor(
      const std::string& bundlePath,
      OFX::Host::ImageEffect::ImageEffectPlugin* plugin) override {
    return new OFX::Host::ImageEffect::Descriptor(bundlePath, plugin);
  }
  OfxStatus vmessage(const char*, const char*, const char*, va_list) override { return kOfxStatOK; }
  OfxStatus setPersistentMessage(const char*, const char*, const char*, va_list) override { return kOfxStatOK; }
  OfxStatus clearPersistentMessage() override { return kOfxStatOK; }
};

constexpr uint32_t kRequestMagic = 0x31504957;   // WIP1
constexpr uint32_t kResponseMagic = 0x31524f57;  // WOR1

bool readExact(void* destination, size_t count, bool allowCleanEOF = false) {
  auto* bytes = static_cast<char*>(destination);
  size_t offset = 0;
  while (offset < count) {
    std::cin.read(bytes + offset, static_cast<std::streamsize>(count - offset));
    const auto consumed = static_cast<size_t>(std::cin.gcount());
    if (consumed == 0) {
      if (allowCleanEOF && offset == 0 && std::cin.eof()) return false;
      throw std::runtime_error("truncated WIP session request");
    }
    offset += consumed;
  }
  return true;
}

template <typename T> bool readValue(T& value, bool allowCleanEOF = false) {
  return readExact(&value, sizeof(T), allowCleanEOF);
}

template <typename T> void writeValue(const T& value) {
  std::cout.write(reinterpret_cast<const char*>(&value), sizeof(T));
}

std::string readString() {
  uint32_t length = 0;
  readValue(length);
  if (length > 1'048'576) throw std::runtime_error("WIP session string is too large");
  std::string value(length, '\0');
  if (length) readExact(value.data(), length);
  return value;
}

void parseParameter(const std::string& type, const std::string& name,
                    const std::string& value) {
  ParameterValue parameter;
  if (type == "i") { parameter.kind=ParameterValue::Kind::Integer; parameter.integer=std::stoi(value); }
  else if (type == "d") { parameter.kind=ParameterValue::Kind::Double; parameter.number=std::stod(value); }
  else if (type == "s") { parameter.kind=ParameterValue::Kind::String; parameter.text=value; }
  else if (type == "c") {
    parameter.kind=ParameterValue::Kind::RGBA;
    size_t start=0;
    for (int channel=0; channel<4; ++channel) {
      const size_t end=value.find(',', start);
      parameter.rgba[channel]=std::stod(value.substr(start, end-start));
      start=end == std::string::npos ? value.size() : end+1;
    }
  } else throw std::runtime_error("unknown parameter type");
  gRender.parameters[name] = parameter;
}

bool readFrameRequest() {
  uint32_t magic = 0;
  if (!readValue(magic, true)) return false;
  if (magic != kRequestMagic) throw std::runtime_error("invalid WIP session request magic");
  readValue(gRender.time);
  uint32_t parameterCount = 0;
  readValue(parameterCount);
  if (parameterCount > 512) throw std::runtime_error("too many WIP session parameters");
  gRender.parameters.clear();
  for (uint32_t index = 0; index < parameterCount; ++index) {
    const std::string type = readString();
    const std::string name = readString();
    const std::string value = readString();
    parseParameter(type, name, value);
  }
  uint64_t floatCount = 0;
  readValue(floatCount);
  const uint64_t expected = static_cast<uint64_t>(gRender.sourceWidth) *
                            gRender.sourceHeight * 4;
  if (floatCount != expected) throw std::runtime_error("invalid WIP session RGBA32F count");
  gRender.source.resize(static_cast<size_t>(floatCount));
  readExact(gRender.source.data(), gRender.source.size() * sizeof(float));
  return true;
}

void writeFrameResponse(const std::vector<float>& pixels) {
  writeValue(kResponseMagic);
  const uint32_t status = 0;
  const uint32_t messageLength = 0;
  const uint64_t floatCount = pixels.size();
  writeValue(status);
  writeValue(messageLength);
  writeValue(floatCount);
  std::cout.write(reinterpret_cast<const char*>(pixels.data()),
                  static_cast<std::streamsize>(pixels.size() * sizeof(float)));
  std::cout.flush();
  if (!std::cout) throw std::runtime_error("cannot publish WIP session response");
}

void writeErrorResponse(const std::string& message) {
  writeValue(kResponseMagic);
  const uint32_t status = 1;
  const uint32_t messageLength = static_cast<uint32_t>(message.size());
  const uint64_t floatCount = 0;
  writeValue(status);
  writeValue(messageLength);
  writeValue(floatCount);
  std::cout.write(message.data(), static_cast<std::streamsize>(message.size()));
  std::cout.flush();
}

void renderCurrentFrame(OFX::Host::ImageEffect::Instance& instance) {
  std::memcpy(gRender.sourceBuffer.contents, gRender.source.data(),
              gRender.source.size() * sizeof(float));
  std::memset(gRender.outputBuffer.contents, 0,
              gRender.output.size() * sizeof(float));
  const OfxPointD scale{1, 1};
  const OfxRectI window{0, 0, gRender.outputWidth, gRender.outputHeight};
  const OfxStatus status = instance.renderAction(
      gRender.time, kOfxImageFieldNone, window, scale, true, false, false);
  if (status != kOfxStatOK) throw std::runtime_error("WIP Review render action failed");
  id<MTLCommandBuffer> completion = [gRender.metalCommandQueue commandBuffer];
  if (!completion) throw std::runtime_error("Metal completion command buffer is unavailable");
  [completion commit];
  [completion waitUntilCompleted];
  if (completion.status == MTLCommandBufferStatusError)
    throw std::runtime_error("WIP Review Metal command buffer failed");
  std::memcpy(gRender.output.data(), gRender.outputBuffer.contents,
              gRender.output.size() * sizeof(float));
}

}  // namespace ScreenWIPHost

int main(int argc, char** argv) {
  using namespace ScreenWIPHost;
  bool protocolStarted = false;
  try {
    if (argc != 9) throw std::runtime_error(
        "usage: screen-wip-ofx-host BUNDLE SW SH OW OH FPS FIRST LAST");
    const std::filesystem::path bundle = argv[1];
    gRender.sourceWidth=std::stoi(argv[2]); gRender.sourceHeight=std::stoi(argv[3]);
    gRender.outputWidth=std::stoi(argv[4]); gRender.outputHeight=std::stoi(argv[5]);
    gRender.frameRate=std::stod(argv[6]);
    const double firstFrame=std::stod(argv[7]);
    const double lastFrame=std::stod(argv[8]);
    if (gRender.sourceWidth<=0 || gRender.sourceHeight<=0 ||
        gRender.outputWidth<=0 || gRender.outputHeight<=0 || gRender.frameRate<=0 ||
        firstFrame>lastFrame) {
      throw std::runtime_error("invalid render context");
    }
    if (!readFrameRequest()) throw std::runtime_error("WIP session requires at least one frame");
    protocolStarted = true;
    gRender.output.assign(static_cast<size_t>(gRender.outputWidth) * gRender.outputHeight * 4, 0);
    gRender.metalDevice = MTLCreateSystemDefaultDevice();
    if (!gRender.metalDevice) throw std::runtime_error("Metal device is unavailable");
    gRender.metalCommandQueue = [gRender.metalDevice newCommandQueue];
    if (!gRender.metalCommandQueue) throw std::runtime_error("Metal command queue is unavailable");
    gRender.sourceBuffer = [gRender.metalDevice
        newBufferWithBytes:gRender.source.data()
                  length:gRender.source.size() * sizeof(float)
                 options:MTLResourceStorageModeShared];
    gRender.outputBuffer = [gRender.metalDevice
        newBufferWithLength:gRender.output.size() * sizeof(float)
                    options:MTLResourceStorageModeShared];
    if (!gRender.sourceBuffer || !gRender.outputBuffer)
      throw std::runtime_error("Metal image buffer allocation failed");

    const auto pluginRoot = bundle.parent_path();
    auto* sharedCache = OFX::Host::PluginCache::getPluginCache();
    auto& pluginPaths = const_cast<std::list<std::string>&>(sharedCache->getPluginPath());
    pluginPaths.clear();
    sharedCache->addFileToPath(pluginRoot.string(), false);
    sharedCache->setCacheVersion("screen-wip-ofx-host-v1");
    Host host;
    OFX::Host::ImageEffect::PluginCache imageCache(host);
    imageCache.registerInCache(*sharedCache);
    sharedCache->scanPluginFiles();
    auto* plugin=imageCache.getPluginById("com.jtorrens.WIPReviewProbe");
    if (!plugin) throw std::runtime_error("required com.jtorrens.WIPReviewProbe was not discovered");
    std::unique_ptr<OFX::Host::ImageEffect::Instance> instance(
        plugin->createInstance(kOfxImageEffectContextFilter, nullptr));
    if (!instance) throw std::runtime_error("cannot create WIP Review instance");
    OfxStatus status=instance->createInstanceAction();
    if (status!=kOfxStatOK && status!=kOfxStatReplyDefault)
      throw std::runtime_error("WIP Review create-instance action failed");
    if (!instance->getClipPreferences())
      throw std::runtime_error("WIP Review clip preferences failed");
    const OfxPointD scale{1,1};
    status=instance->beginRenderAction(firstFrame,lastFrame,1,false,scale,true,false);
    if (status!=kOfxStatOK && status!=kOfxStatReplyDefault)
      throw std::runtime_error("WIP Review begin-render action failed");
    do {
      renderCurrentFrame(*instance);
      writeFrameResponse(gRender.output);
    } while (readFrameRequest());
    status=instance->endRenderAction(firstFrame,lastFrame,1,false,scale,true,false);
    if (status!=kOfxStatOK && status!=kOfxStatReplyDefault)
      throw std::runtime_error("WIP Review end-render action failed");
    instance.reset();
    OFX::Host::PluginCache::clearPluginCache();
    return 0;
  } catch (const std::exception& error) {
    if (protocolStarted) writeErrorResponse(error.what());
    std::cerr << error.what() << '\n';
    return 1;
  }
}
