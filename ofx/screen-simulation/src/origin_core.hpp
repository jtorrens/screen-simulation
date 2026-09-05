#pragma once

#include "identity_core.hpp"

#include <cstdint>
#include <vector>

namespace screen_simulation::ofx {

enum class PixelDepth {
  Byte,
  Short,
  Half,
  Float,
};

enum class OriginIoStatus {
  Ok,
  MissingData,
  InvalidLayout,
  WindowOutsideImage,
  InvalidPixel,
};

[[nodiscard]] OriginIoStatus read_origin_window_rgba32f(
    const ImageView& source,
    PixelDepth depth,
    RectI render_window,
    std::vector<float>& output);

[[nodiscard]] OriginIoStatus write_origin_window_rgba32f(
    const std::vector<float>& input,
    const ImageView& destination,
    PixelDepth depth,
    RectI render_window);

}  // namespace screen_simulation::ofx
