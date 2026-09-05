cmake_minimum_required(VERSION 3.24)

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin" AND
   "${CMAKE_OSX_ARCHITECTURES}" STREQUAL "")
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING
      "Architectures included in the macOS OFX bundle" FORCE)
endif()
if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin" AND
   "${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING
      "Minimum supported macOS version" FORCE)
endif()

project(ScreenSimulationOFX VERSION 0.2.0 LANGUAGES CXX)

option(SCREEN_SIMULATION_OFX_BUILD_TESTS "Build OFX core and bundle tests" ON)
option(SCREEN_SIMULATION_OFX_ADHOC_SIGN "Ad-hoc sign the macOS bundle" ON)
set(SCREEN_SIMULATION_OPENFX_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/openfx" CACHE PATH
    "Pinned OpenFX SDK checkout")

if(NOT EXISTS "${SCREEN_SIMULATION_OPENFX_ROOT}/include/ofxImageEffect.h")
  message(FATAL_ERROR
      "SCREEN_SIMULATION_OPENFX_ROOT must contain include/ofxImageEffect.h")
endif()

add_library(screen_simulation_openfx_headers INTERFACE)
target_include_directories(screen_simulation_openfx_headers SYSTEM INTERFACE
    "${SCREEN_SIMULATION_OPENFX_ROOT}/include")

find_program(SCREEN_SIMULATION_CARGO_EXECUTABLE cargo REQUIRED)
set(SCREEN_SIMULATION_OFX_BRIDGE_MANIFEST
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-ofx-bridge/Cargo.toml")
file(GLOB_RECURSE SCREEN_SIMULATION_OFX_BRIDGE_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-ofx-bridge/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-application/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-camera/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-color/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-contracts/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-cover/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-geometry/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-media/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-panel/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-recording/src/*"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-sensor/src/*")
list(APPEND SCREEN_SIMULATION_OFX_BRIDGE_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Cargo.lock"
    "${SCREEN_SIMULATION_OFX_BRIDGE_MANIFEST}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-application/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-camera/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-color/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-contracts/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-cover/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-geometry/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-media/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-panel/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-recording/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-sensor/Cargo.toml")

if(APPLE)
  set(SCREEN_SIMULATION_RUST_TARGET_DIR "${CMAKE_BINARY_DIR}/rust")
  set(SCREEN_SIMULATION_RUST_ARM64
      "${SCREEN_SIMULATION_RUST_TARGET_DIR}/aarch64-apple-darwin/release/libscreen_ofx_bridge.a")
  set(SCREEN_SIMULATION_RUST_X86_64
      "${SCREEN_SIMULATION_RUST_TARGET_DIR}/x86_64-apple-darwin/release/libscreen_ofx_bridge.a")
  set(SCREEN_SIMULATION_RUST_UNIVERSAL
      "${SCREEN_SIMULATION_RUST_TARGET_DIR}/universal/libscreen_ofx_bridge.a")
  add_custom_command(
      OUTPUT "${SCREEN_SIMULATION_RUST_UNIVERSAL}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory
              "${SCREEN_SIMULATION_RUST_TARGET_DIR}/universal"
      COMMAND "${CMAKE_COMMAND}" -E env MACOSX_DEPLOYMENT_TARGET=14.0
              "${SCREEN_SIMULATION_CARGO_EXECUTABLE}" build --locked --release
              --package screen-ofx-bridge --target aarch64-apple-darwin
              --target-dir "${SCREEN_SIMULATION_RUST_TARGET_DIR}"
      COMMAND "${CMAKE_COMMAND}" -E env MACOSX_DEPLOYMENT_TARGET=14.0
              "${SCREEN_SIMULATION_CARGO_EXECUTABLE}" build --locked --release
              --package screen-ofx-bridge --target x86_64-apple-darwin
              --target-dir "${SCREEN_SIMULATION_RUST_TARGET_DIR}"
      COMMAND /usr/bin/lipo -create
              "${SCREEN_SIMULATION_RUST_ARM64}"
              "${SCREEN_SIMULATION_RUST_X86_64}"
              -output "${SCREEN_SIMULATION_RUST_UNIVERSAL}"
      DEPENDS ${SCREEN_SIMULATION_OFX_BRIDGE_SOURCES}
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.."
      COMMENT "Building universal host-neutral ScreenSimulation Origin bridge"
      VERBATIM)
  set(SCREEN_SIMULATION_RUST_LIBRARY "${SCREEN_SIMULATION_RUST_UNIVERSAL}")
elseif(WIN32)
  set(SCREEN_SIMULATION_RUST_TARGET_DIR "${CMAKE_BINARY_DIR}/rust")
  set(SCREEN_SIMULATION_RUST_LIBRARY
      "${SCREEN_SIMULATION_RUST_TARGET_DIR}/x86_64-pc-windows-msvc/release/screen_ofx_bridge.lib")
  add_custom_command(
      OUTPUT "${SCREEN_SIMULATION_RUST_LIBRARY}"
      COMMAND "${SCREEN_SIMULATION_CARGO_EXECUTABLE}" build --locked --release
              --package screen-ofx-bridge --target x86_64-pc-windows-msvc
              --target-dir "${SCREEN_SIMULATION_RUST_TARGET_DIR}"
      DEPENDS ${SCREEN_SIMULATION_OFX_BRIDGE_SOURCES}
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.."
      COMMENT "Building Windows host-neutral ScreenSimulation Origin bridge"
      VERBATIM)
endif()

add_custom_target(screen_simulation_ofx_bridge_build
    DEPENDS "${SCREEN_SIMULATION_RUST_LIBRARY}")
add_library(screen_simulation_ofx_bridge STATIC IMPORTED GLOBAL)
set_target_properties(screen_simulation_ofx_bridge PROPERTIES
    IMPORTED_LOCATION "${SCREEN_SIMULATION_RUST_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES
      "${CMAKE_CURRENT_SOURCE_DIR}/../../crates/screen-ofx-bridge/include")
add_dependencies(screen_simulation_ofx_bridge screen_simulation_ofx_bridge_build)

add_library(screen_simulation_identity_core STATIC
    src/identity_core.cpp)
target_include_directories(screen_simulation_identity_core PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_compile_features(screen_simulation_identity_core PUBLIC cxx_std_17)
set_target_properties(screen_simulation_identity_core PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)
if(MSVC)
  target_compile_options(screen_simulation_identity_core PRIVATE /W4 /WX)
else()
  target_compile_options(screen_simulation_identity_core PRIVATE
      -Wall -Wextra -Wpedantic -Werror)
endif()

add_library(screen_simulation_origin_core STATIC
    src/origin_core.cpp)
target_include_directories(screen_simulation_origin_core PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_compile_features(screen_simulation_origin_core PUBLIC cxx_std_17)
set_target_properties(screen_simulation_origin_core PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)
if(MSVC)
  target_compile_options(screen_simulation_origin_core PRIVATE /W4 /WX)
else()
  target_compile_options(screen_simulation_origin_core PRIVATE
      -Wall -Wextra -Wpedantic -Werror)
endif()

add_library(ScreenSimulation MODULE src/plugin.cpp)
target_compile_features(ScreenSimulation PRIVATE cxx_std_17)
target_link_libraries(ScreenSimulation PRIVATE
    screen_simulation_openfx_headers
    screen_simulation_identity_core
    screen_simulation_origin_core
    screen_simulation_ofx_bridge)
if(APPLE)
  target_link_libraries(ScreenSimulation PRIVATE
      "-framework CoreFoundation"
      "-framework CoreGraphics"
      "-framework ColorSync"
      "-framework IOKit"
      "-framework Security")
elseif(WIN32)
  target_link_libraries(ScreenSimulation PRIVATE
      bcrypt ntdll userenv ws2_32)
endif()
target_compile_definitions(ScreenSimulation PRIVATE
    SCREEN_SIMULATION_OFX_VERSION="${PROJECT_VERSION}")
set_target_properties(ScreenSimulation PROPERTIES
    PREFIX ""
    SUFFIX ".ofx"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)
if(MSVC)
  target_compile_options(ScreenSimulation PRIVATE /W4 /WX)
else()
  target_compile_options(ScreenSimulation PRIVATE
      -Wall -Wextra -Wpedantic -Werror)
endif()

if(APPLE)
  set(SCREEN_SIMULATION_BUNDLE_DIR
      "${CMAKE_BINARY_DIR}/ScreenSimulation.ofx.bundle")
  set(SCREEN_SIMULATION_BUNDLE_CONTENTS
      "${SCREEN_SIMULATION_BUNDLE_DIR}/Contents")
  set(SCREEN_SIMULATION_BUNDLE_BINARY_DIR
      "${SCREEN_SIMULATION_BUNDLE_CONTENTS}/MacOS")
  set_target_properties(ScreenSimulation PROPERTIES
      LIBRARY_OUTPUT_DIRECTORY "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}")
  configure_file(
      "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in"
      "${SCREEN_SIMULATION_BUNDLE_CONTENTS}/Info.plist"
      @ONLY)
  if(SCREEN_SIMULATION_OFX_ADHOC_SIGN)
    add_custom_command(TARGET ScreenSimulation POST_BUILD
        COMMAND /usr/bin/codesign --force --sign -
                "${SCREEN_SIMULATION_BUNDLE_DIR}"
        COMMENT "Ad-hoc signing ScreenSimulation.ofx.bundle"
        VERBATIM)
  endif()
elseif(WIN32)
  set(SCREEN_SIMULATION_BUNDLE_DIR
      "${CMAKE_BINARY_DIR}/ScreenSimulation.ofx.bundle")
  set(SCREEN_SIMULATION_BUNDLE_BINARY_DIR
      "${SCREEN_SIMULATION_BUNDLE_DIR}/Contents/Win64")
  set_target_properties(ScreenSimulation PROPERTIES
      LIBRARY_OUTPUT_DIRECTORY "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      RUNTIME_OUTPUT_DIRECTORY "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      LIBRARY_OUTPUT_DIRECTORY_DEBUG "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      LIBRARY_OUTPUT_DIRECTORY_RELEASE "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      LIBRARY_OUTPUT_DIRECTORY_RELWITHDEBINFO "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      LIBRARY_OUTPUT_DIRECTORY_MINSIZEREL "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      RUNTIME_OUTPUT_DIRECTORY_DEBUG "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      RUNTIME_OUTPUT_DIRECTORY_RELEASE "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}"
      RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${SCREEN_SIMULATION_BUNDLE_BINARY_DIR}")
else()
  message(FATAL_ERROR "The OFX bundle currently packages only macOS and Windows")
endif()

install(DIRECTORY "${SCREEN_SIMULATION_BUNDLE_DIR}"
        DESTINATION "." USE_SOURCE_PERMISSIONS)

if(SCREEN_SIMULATION_OFX_BUILD_TESTS)
  enable_testing()
  add_executable(screen_simulation_identity_core_tests
      tests/identity_core_tests.cpp)
  target_link_libraries(screen_simulation_identity_core_tests PRIVATE
      screen_simulation_identity_core)
  add_test(NAME screen_simulation_identity_core
      COMMAND screen_simulation_identity_core_tests)

  add_executable(screen_simulation_identity_bundle_smoke
      tests/bundle_smoke.cpp)
  target_link_libraries(screen_simulation_identity_bundle_smoke PRIVATE
      screen_simulation_openfx_headers ${CMAKE_DL_LIBS})
  add_test(NAME screen_simulation_identity_bundle_exports
      COMMAND screen_simulation_identity_bundle_smoke
              "$<TARGET_FILE:ScreenSimulation>")

  add_executable(screen_simulation_origin_core_tests
      tests/origin_core_tests.cpp)
  target_link_libraries(screen_simulation_origin_core_tests PRIVATE
      screen_simulation_origin_core)
  add_test(NAME screen_simulation_origin_core
      COMMAND screen_simulation_origin_core_tests)
endif()

set(CPACK_PACKAGE_NAME "ScreenSimulationOFX")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_GENERATOR "ZIP")
include(CPack)
