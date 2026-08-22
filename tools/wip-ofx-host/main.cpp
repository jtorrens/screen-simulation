// Narrow CPU OpenFX host for the packaged WIP Review effect.
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

#include <array>
#include <cstdarg>
#include <cstdio>
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
    float* base = output ? gRender.output.data() : gRender.source.data();
    const int stride = width * 4 * static_cast<int>(sizeof(float));
    setDoubleProperty(kOfxImageEffectPropRenderScale, 1, 0);
    setDoubleProperty(kOfxImageEffectPropRenderScale, 1, 1);
    // Raw exchange is top-down; a negative OFX row stride preserves image orientation.
    setPointerProperty(kOfxImagePropData, base + static_cast<size_t>(height - 1) * width * 4);
    setIntProperty(kOfxImagePropRowBytes, -stride);
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
      : IntegerInstance(descriptor, owner), value_(configured(name) ? configured(name)->integer : defaultInt(descriptor)) {}
  OfxStatus get(int& value) override { value = value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, int& value) override { return get(value); }
  OfxStatus set(int value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, int value) override { return set(value); }
 private: int value_;
};

class ChoiceParam final : public OFX::Host::Param::ChoiceInstance {
 public:
  ChoiceParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
              OFX::Host::Param::SetInstance* owner)
      : ChoiceInstance(descriptor, owner), value_(configured(name) ? configured(name)->integer : defaultInt(descriptor)) {}
  OfxStatus get(int& value) override { value = value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, int& value) override { return get(value); }
  OfxStatus set(int value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, int value) override { return set(value); }
 private: int value_;
};

class BooleanParam final : public OFX::Host::Param::BooleanInstance {
 public:
  BooleanParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
               OFX::Host::Param::SetInstance* owner)
      : BooleanInstance(descriptor, owner), value_(configured(name) ? configured(name)->integer != 0 : defaultInt(descriptor) != 0) {}
  OfxStatus get(bool& value) override { value = value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, bool& value) override { return get(value); }
  OfxStatus set(bool value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, bool value) override { return set(value); }
 private: bool value_;
};

class DoubleParam final : public OFX::Host::Param::DoubleInstance {
 public:
  DoubleParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
              OFX::Host::Param::SetInstance* owner)
      : DoubleInstance(descriptor, owner), value_(configured(name) ? configured(name)->number : defaultDouble(descriptor)) {}
  OfxStatus get(double& value) override { value = value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, double& value) override { return get(value); }
  OfxStatus set(double value) override { value_ = value; return kOfxStatOK; }
  OfxStatus set(OfxTime, double value) override { return set(value); }
  OfxStatus derive(OfxTime, double& value) override { value = 0; return kOfxStatOK; }
  OfxStatus integrate(OfxTime a, OfxTime b, double& value) override { value = value_ * (b - a); return kOfxStatOK; }
 private: double value_;
};

class StringParam final : public OFX::Host::Param::StringInstance {
 public:
  StringParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
              OFX::Host::Param::SetInstance* owner)
      : StringInstance(descriptor, owner), value_(configured(name) ? configured(name)->text : defaultString(descriptor)) {}
  OfxStatus get(std::string& value) override { value = value_; return kOfxStatOK; }
  OfxStatus get(OfxTime, std::string& value) override { return get(value); }
  OfxStatus set(const char* value) override { value_ = value ? value : ""; return kOfxStatOK; }
  OfxStatus set(OfxTime, const char* value) override { return set(value); }
 private: std::string value_;
};

class RGBAParam final : public OFX::Host::Param::RGBAInstance {
 public:
  RGBAParam(const std::string& name, OFX::Host::Param::Descriptor& descriptor,
            OFX::Host::Param::SetInstance* owner)
      : RGBAInstance(descriptor, owner) {
    if (const auto* value = configured(name)) values_ = value->rgba;
    else for (int i = 0; i < 4; ++i) {
      try { values_[i] = descriptor.getProperties().getDoubleProperty(kOfxParamPropDefault, i); }
      catch (...) { values_[i] = i == 3 ? 1 : 0; }
    }
  }
  OfxStatus get(double& r,double& g,double& b,double& a) override { r=values_[0];g=values_[1];b=values_[2];a=values_[3];return kOfxStatOK; }
  OfxStatus get(OfxTime,double& r,double& g,double& b,double& a) override { return get(r,g,b,a); }
  OfxStatus set(double r,double g,double b,double a) override { values_={r,g,b,a};return kOfxStatOK; }
  OfxStatus set(OfxTime,double r,double g,double b,double a) override { return set(r,g,b,a); }
 private: std::array<double,4> values_{};
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
    _properties.setStringProperty(kOfxImageEffectPropCPURenderSupported, "true");
    _properties.setStringProperty(kOfxImageEffectPropMetalRenderSupported, "false");
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

void loadRaw(const std::filesystem::path& path, std::vector<float>& pixels, size_t count) {
  std::ifstream input(path, std::ios::binary);
  pixels.resize(count);
  input.read(reinterpret_cast<char*>(pixels.data()), static_cast<std::streamsize>(count * sizeof(float)));
  if (!input || input.gcount() != static_cast<std::streamsize>(count * sizeof(float))) {
    throw std::runtime_error("invalid input RGBA32F payload");
  }
}

void saveRaw(const std::filesystem::path& path, const std::vector<float>& pixels) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(reinterpret_cast<const char*>(pixels.data()),
               static_cast<std::streamsize>(pixels.size() * sizeof(float)));
  if (!output) throw std::runtime_error("cannot write output RGBA32F payload");
}

void parseParameter(int& index, int argc, char** argv) {
  if (index + 2 >= argc) throw std::runtime_error("incomplete parameter argument");
  const std::string type = argv[index++];
  const std::string name = argv[index++];
  const std::string value = argv[index++];
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

}  // namespace ScreenWIPHost

int main(int argc, char** argv) {
  using namespace ScreenWIPHost;
  try {
    if (argc < 10) throw std::runtime_error(
        "usage: screen-wip-ofx-host BUNDLE INPUT OUTPUT SW SH OW OH TIME FPS [TYPE NAME VALUE]...");
    const std::filesystem::path bundle = argv[1];
    const std::filesystem::path input = argv[2];
    const std::filesystem::path output = argv[3];
    gRender.sourceWidth=std::stoi(argv[4]); gRender.sourceHeight=std::stoi(argv[5]);
    gRender.outputWidth=std::stoi(argv[6]); gRender.outputHeight=std::stoi(argv[7]);
    gRender.time=std::stod(argv[8]); gRender.frameRate=std::stod(argv[9]);
    int argument=10;
    while (argument < argc) parseParameter(argument, argc, argv);
    if (gRender.sourceWidth<=0 || gRender.sourceHeight<=0 ||
        gRender.outputWidth<=0 || gRender.outputHeight<=0 || gRender.frameRate<=0) {
      throw std::runtime_error("invalid render context");
    }
    loadRaw(input, gRender.source,
            static_cast<size_t>(gRender.sourceWidth) * gRender.sourceHeight * 4);
    gRender.output.assign(static_cast<size_t>(gRender.outputWidth) * gRender.outputHeight * 4, 0);

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
    const OfxRectI window{0,0,gRender.outputWidth,gRender.outputHeight};
    status=instance->beginRenderAction(gRender.time,gRender.time,1,false,scale,true,false);
    if (status!=kOfxStatOK && status!=kOfxStatReplyDefault)
      throw std::runtime_error("WIP Review begin-render action failed");
    status=instance->renderAction(gRender.time,kOfxImageFieldNone,window,scale,true,false,false);
    if (status!=kOfxStatOK) throw std::runtime_error("WIP Review render action failed");
    instance->endRenderAction(gRender.time,gRender.time,1,false,scale,true,false);
    saveRaw(output,gRender.output);
    instance.reset();
    OFX::Host::PluginCache::clearPluginCache();
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
