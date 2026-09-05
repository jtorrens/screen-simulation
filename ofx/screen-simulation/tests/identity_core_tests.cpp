#include "identity_core.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

using screen_simulation::ofx::IdentityCopyStatus;
using screen_simulation::ofx::ImageView;
using screen_simulation::ofx::RectI;

void require(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}

void partial_window_preserves_unrequested_pixels() {
  std::array<std::byte, 48> source{};
  std::array<std::byte, 48> destination{};
  for (std::size_t index = 0; index < source.size(); ++index) {
    source[index] = static_cast<std::byte>(index + 1U);
    destination[index] = std::byte{0xee};
  }
  const ImageView source_view{source.data(), {10, 20, 13, 24}, 12, 4};
  const ImageView destination_view{destination.data(), {10, 20, 13, 24}, 12, 4};
  require(copy_identity(source_view, destination_view, {11, 21, 13, 23}) ==
              IdentityCopyStatus::Ok,
          "partial identity copy failed");
  for (int y = 20; y < 24; ++y) {
    for (int x = 10; x < 13; ++x) {
      for (int channel = 0; channel < 4; ++channel) {
        const auto offset = static_cast<std::size_t>(y - 20) * 12U +
            static_cast<std::size_t>(x - 10) * 4U +
            static_cast<std::size_t>(channel);
        const bool requested = x >= 11 && y >= 21 && y < 23;
        require(destination[offset] ==
                    (requested ? source[offset] : std::byte{0xee}),
                "identity copy wrote outside renderWindow");
      }
    }
  }
}

void negative_row_bytes_are_supported() {
  std::array<std::byte, 24> source{};
  std::array<std::byte, 24> destination{};
  for (std::size_t index = 0; index < source.size(); ++index) {
    source[index] = static_cast<std::byte>(0x40U + index);
  }
  const ImageView source_view{source.data() + 16, {0, 0, 2, 3}, -8, 4};
  const ImageView destination_view{destination.data() + 16, {0, 0, 2, 3}, -8, 4};
  require(copy_identity(source_view, destination_view, {0, 0, 2, 3}) ==
              IdentityCopyStatus::Ok,
          "negative row-byte copy failed");
  require(source == destination, "negative row-byte copy changed pixel order");
}

void every_supported_pixel_size_is_byte_exact() {
  for (const std::size_t pixel_bytes : {4U, 8U, 16U}) {
    std::vector<std::byte> source(pixel_bytes * 6U);
    std::vector<std::byte> destination(source.size(), std::byte{0});
    for (std::size_t index = 0; index < source.size(); ++index) {
      source[index] = static_cast<std::byte>((index * 37U) & 0xffU);
    }
    const auto row_bytes = static_cast<std::ptrdiff_t>(pixel_bytes * 3U);
    const ImageView source_view{source.data(), {0, 0, 3, 2}, row_bytes, pixel_bytes};
    const ImageView destination_view{
        destination.data(), {0, 0, 3, 2}, row_bytes, pixel_bytes};
    require(copy_identity(source_view, destination_view, {0, 0, 3, 2}) ==
                IdentityCopyStatus::Ok,
            "supported pixel-size copy failed");
    require(source == destination, "identity path altered channel bytes");
  }
}

void incompatible_or_unavailable_requests_fail() {
  std::array<std::byte, 32> pixels{};
  const ImageView rgba8{pixels.data(), {0, 0, 2, 2}, 8, 4};
  const ImageView rgba16{pixels.data(), {0, 0, 2, 2}, 16, 8};
  const ImageView missing{nullptr, {0, 0, 2, 2}, 8, 4};
  require(copy_identity(rgba8, rgba16, {0, 0, 2, 2}) ==
              IdentityCopyStatus::IncompatibleLayout,
          "mismatched pixel layouts were accepted");
  require(copy_identity(missing, rgba8, {0, 0, 2, 2}) ==
              IdentityCopyStatus::MissingData,
          "missing source data was accepted");
  require(copy_identity(rgba8, rgba8, {-1, 0, 2, 2}) ==
              IdentityCopyStatus::WindowOutsideImage,
          "out-of-bounds renderWindow was accepted");
}

}  // namespace

int main() {
  partial_window_preserves_unrequested_pixels();
  negative_row_bytes_are_supported();
  every_supported_pixel_size_is_byte_exact();
  incompatible_or_unavailable_requests_fail();
  return 0;
}
