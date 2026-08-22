cmake_minimum_required(VERSION 3.22)
project(ScreenWIPOFXHost LANGUAGES CXX)

set(OPENFX_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../vendor/openfx")
find_package(EXPAT REQUIRED)
if(NOT TARGET expat::expat)
  add_library(expat::expat ALIAS EXPAT::EXPAT)
endif()
file(GLOB OFX_HEADER_FILES "${OPENFX_ROOT}/include/*.h")
set(OFX_HEADER_DIR "${OPENFX_ROOT}/include")
add_subdirectory("${OPENFX_ROOT}/HostSupport" "${CMAKE_CURRENT_BINARY_DIR}/HostSupport")

add_executable(screen-wip-ofx-host main.cpp)
target_compile_features(screen-wip-ofx-host PRIVATE cxx_std_17)
target_link_libraries(screen-wip-ofx-host PRIVATE OfxHost)
target_include_directories(screen-wip-ofx-host PRIVATE
  "${OPENFX_ROOT}/include"
  "${OPENFX_ROOT}/HostSupport/include")
if(APPLE)
  target_link_libraries(screen-wip-ofx-host PRIVATE "-framework CoreFoundation")
endif()
