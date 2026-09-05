#pragma once

#include <cstddef>

namespace screen_simulation::ofx {

struct RectI {
  int x1 = 0;
  int y1 = 0;
  int x2 = 0;
  int y2 = 0;
};

struct ImageView {
  std::byte* data = nullptr;
  RectI bounds{};
  std::ptrdiff_t row_bytes = 0;
  std::size_t pixel_bytes = 0;
};

enum class IdentityCopyStatus {
  Ok,
  MissingData,
  InvalidLayout,
  IncompatibleLayout,
  WindowOutsideImage,
};

[[nodiscard]] IdentityCopyStatus copy_identity(
    const ImageView& source,
    const ImageView& destination,
    RectI render_window) noexcept;

}  // namespace screen_simulation::ofx
