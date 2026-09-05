#include <ofxCore.h>
#include <ofxImageEffect.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include <cstring>
#include <iostream>

namespace {

using GetPluginCount = int (*)();
using GetPlugin = OfxPlugin* (*)(int);

#if defined(_WIN32)
using LibraryHandle = HMODULE;
LibraryHandle open_library(const char* path) { return LoadLibraryA(path); }
void* load_symbol(LibraryHandle library, const char* name) {
  return reinterpret_cast<void*>(GetProcAddress(library, name));
}
void close_library(LibraryHandle library) { FreeLibrary(library); }
#else
using LibraryHandle = void*;
LibraryHandle open_library(const char* path) {
  return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}
void* load_symbol(LibraryHandle library, const char* name) {
  return dlsym(library, name);
}
void close_library(LibraryHandle library) { dlclose(library); }
#endif

int fail(const char* message) {
  std::cerr << message << '\n';
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) return fail("expected path to OFX binary");
  const auto library = open_library(argv[1]);
  if (!library) return fail("could not load OFX binary");
  const auto get_count = reinterpret_cast<GetPluginCount>(
      load_symbol(library, "OfxGetNumberOfPlugins"));
  const auto get_plugin = reinterpret_cast<GetPlugin>(
      load_symbol(library, "OfxGetPlugin"));
  if (!get_count || !get_plugin || get_count() != 1) {
    close_library(library);
    return fail("mandatory OpenFX exports are invalid");
  }
  const auto* plugin = get_plugin(0);
  const bool valid = plugin && plugin->pluginApi &&
      std::strcmp(plugin->pluginApi, kOfxImageEffectPluginApi) == 0 &&
      plugin->apiVersion == 1 && plugin->setHost && plugin->mainEntry &&
      plugin->pluginIdentifier &&
      std::strcmp(plugin->pluginIdentifier,
                  "com.jtorrens.ScreenSimulation") == 0 &&
      get_plugin(1) == nullptr;
  close_library(library);
  return valid ? 0 : fail("plugin metadata is invalid");
}
