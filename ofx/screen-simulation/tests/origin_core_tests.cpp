#include "origin_core.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

using screen_simulation::ofx::ImageView;
using screen_simulation::ofx::OriginIoStatus;
using screen_simulation::ofx::PixelDepth;
using screen_simulation::ofx::RectI;

void require(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}

void byte_partial_window_preserves_unrequested_pixels() {
  std::vector<std::byte> storage(3U * 2U * 4U, std::byte{0x55});
  ImageView view{storage.data(), {10, 20, 13, 22}, 12, 4};
  const std::vector<float> values = {
      0.0F, 0.25F, 0.5F, 1.0F,
      1.0F, 0.5F, 0.25F, 0.0F,
  };
  require(
      screen_simulation::ofx::write_origin_window_rgba32f(
          values, view, PixelDepth::Byte, {11, 20, 13, 21}) == OriginIoStatus::Ok,
      "byte partial write failed");
  for (std::size_t index = 0; index < 4U; ++index) {
    require(storage[index] == std::byte{0x55}, "partial write touched the left pixel");
  }
  for (std::size_t index = 12U; index < storage.size(); ++index) {
    require(storage[index] == std::byte{0x55}, "partial write touched another row");
  }
}

void half_roundtrip_preserves_extended_finite_values() {
  std::vector<std::byte> storage(2U * 4U * 2U);
  ImageView view{storage.data(), {0, 0, 2, 1}, 16, 8};
  const std::vector<float> expected = {
      -0.25F, 0.18F, 4.0F, 0.5F,
      16.0F, -2.0F, 1.0F, 0.0F,
  };
  require(
      screen_simulation::ofx::write_origin_window_rgba32f(
          expected, view, PixelDepth::Half, {0, 0, 2, 1}) == OriginIoStatus::Ok,
      "half write failed");
  std::vector<float> actual;
  require(
      screen_simulation::ofx::read_origin_window_rgba32f(
          view, PixelDepth::Half, {0, 0, 2, 1}, actual) == OriginIoStatus::Ok,
      "half read failed");
  require(actual.size() == expected.size(), "half roundtrip size changed");
  for (std::size_t index = 0; index < actual.size(); ++index) {
    require(std::abs(actual[index] - expected[index]) <= 5.0e-4F,
            "half roundtrip exceeded tolerance");
  }
}

void negative_rows_and_nonzero_bounds_are_supported() {
  std::vector<float> storage(2U * 2U * 4U, 0.0F);
  auto* bottom_row = reinterpret_cast<std::byte*>(storage.data() + 8U);
  ImageView view{bottom_row, {7, 9, 9, 11}, -32, 16};
  const std::vector<float> expected = {
      0.1F, 0.2F, 0.3F, 0.4F,
      0.5F, 0.6F, 0.7F, 0.8F,
      0.9F, 1.0F, 1.1F, 1.2F,
      1.3F, 1.4F, 1.5F, 1.0F,
  };
  require(
      screen_simulation::ofx::write_origin_window_rgba32f(
          expected, view, PixelDepth::Float, {7, 9, 9, 11}) == OriginIoStatus::Ok,
      "negative-row write failed");
  std::vector<float> actual;
  require(
      screen_simulation::ofx::read_origin_window_rgba32f(
          view, PixelDepth::Float, {7, 9, 9, 11}, actual) == OriginIoStatus::Ok,
      "negative-row read failed");
  require(actual == expected, "negative-row roundtrip changed float pixels");
}

void invalid_layouts_fail_explicitly() {
  std::vector<std::byte> storage(16U);
  ImageView view{storage.data(), {0, 0, 1, 1}, 16, 16};
  std::vector<float> output;
  require(
      screen_simulation::ofx::read_origin_window_rgba32f(
          view, PixelDepth::Float, {-1, 0, 1, 1}, output) ==
          OriginIoStatus::WindowOutsideImage,
      "out-of-bounds Origin read did not fail");
  view.pixel_bytes = 8;
  require(
      screen_simulation::ofx::read_origin_window_rgba32f(
          view, PixelDepth::Float, {0, 0, 1, 1}, output) == OriginIoStatus::InvalidLayout,
      "mismatched Origin layout did not fail");
}

}  // namespace

int main() {
  byte_partial_window_preserves_unrequested_pixels();
  half_roundtrip_preserves_extended_finite_values();
  negative_rows_and_nonzero_bounds_are_supported();
  invalid_layouts_fail_explicitly();
  return 0;
}
