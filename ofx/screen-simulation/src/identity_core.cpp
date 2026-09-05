#include "identity_core.hpp"

#include <cstring>
#include <limits>

namespace screen_simulation::ofx {
namespace {

bool valid_rect(RectI value) noexcept {
  return value.x1 <= value.x2 && value.y1 <= value.y2;
}

bool contains(RectI outer, RectI inner) noexcept {
  return inner.x1 >= outer.x1 && inner.y1 >= outer.y1 &&
      inner.x2 <= outer.x2 && inner.y2 <= outer.y2;
}

bool valid_layout(const ImageView& image) noexcept {
  if (!valid_rect(image.bounds) || image.pixel_bytes == 0 || image.row_bytes == 0) {
    return false;
  }
  const auto width = static_cast<std::size_t>(image.bounds.x2 - image.bounds.x1);
  if (width > std::numeric_limits<std::size_t>::max() / image.pixel_bytes) {
    return false;
  }
  const auto required_row_bytes = width * image.pixel_bytes;
  const auto magnitude = image.row_bytes < 0
      ? static_cast<std::size_t>(-(image.row_bytes + 1)) + 1U
      : static_cast<std::size_t>(image.row_bytes);
  return magnitude >= required_row_bytes;
}

std::byte* pixel_address(const ImageView& image, int x, int y) noexcept {
  return image.data +
      static_cast<std::ptrdiff_t>(y - image.bounds.y1) * image.row_bytes +
      static_cast<std::ptrdiff_t>(x - image.bounds.x1) *
          static_cast<std::ptrdiff_t>(image.pixel_bytes);
}

}  // namespace

IdentityCopyStatus copy_identity(
    const ImageView& source,
    const ImageView& destination,
    RectI render_window) noexcept {
  if (!source.data || !destination.data) {
    return IdentityCopyStatus::MissingData;
  }
  if (!valid_layout(source) || !valid_layout(destination) ||
      !valid_rect(render_window)) {
    return IdentityCopyStatus::InvalidLayout;
  }
  if (source.pixel_bytes != destination.pixel_bytes) {
    return IdentityCopyStatus::IncompatibleLayout;
  }
  if (!contains(source.bounds, render_window) ||
      !contains(destination.bounds, render_window)) {
    return IdentityCopyStatus::WindowOutsideImage;
  }
  if (render_window.x1 == render_window.x2 ||
      render_window.y1 == render_window.y2) {
    return IdentityCopyStatus::Ok;
  }
  const auto row_size = static_cast<std::size_t>(
      render_window.x2 - render_window.x1) * source.pixel_bytes;
  for (int y = render_window.y1; y < render_window.y2; ++y) {
    std::memmove(
        pixel_address(destination, render_window.x1, y),
        pixel_address(source, render_window.x1, y),
        row_size);
  }
  return IdentityCopyStatus::Ok;
}

}  // namespace screen_simulation::ofx
