cmake_minimum_required(VERSION 3.22)
project(ScreenWIPOFXHost LANGUAGES CXX OBJCXX)

set(OPENFX_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../vendor/openfx")
find_package(EXPAT REQUIRED)
if(NOT TARGET expat::expat)
  add_library(expat::expat ALIAS EXPAT::EXPAT)
endif()
file(GLOB OFX_HEADER_FILES "${OPENFX_ROOT}/include/*.h")
set(OFX_HEADER_DIR "${OPENFX_ROOT}/include")
add_subdirectory("${OPENFX_ROOT}/HostSupport" "${CMAKE_CURRENT_BINARY_DIR}/HostSupport")

add_executable(screen-wip-ofx-host main.cpp)
set_source_files_properties(main.cpp PROPERTIES LANGUAGE OBJCXX)
target_compile_features(screen-wip-ofx-host PRIVATE cxx_std_17)
set_target_properties(screen-wip-ofx-host PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES)
target_compile_options(screen-wip-ofx-host PRIVATE -fobjc-arc)
target_link_libraries(screen-wip-ofx-host PRIVATE OfxHost)
target_include_directories(screen-wip-ofx-host PRIVATE
  "${OPENFX_ROOT}/include"
  "${OPENFX_ROOT}/HostSupport/include")
if(APPLE)
  target_link_libraries(screen-wip-ofx-host PRIVATE
    "-framework CoreFoundation"
    "-framework Metal")
endif()
