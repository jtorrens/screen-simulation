#include "origin_core.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace screen_simulation::ofx {
namespace {

bool valid(RectI value) noexcept {
  return value.x2 >= value.x1 && value.y2 >= value.y1;
}

bool contains(RectI outer, RectI inner) noexcept {
  return valid(outer) && valid(inner) && inner.x1 >= outer.x1 &&
      inner.y1 >= outer.y1 && inner.x2 <= outer.x2 && inner.y2 <= outer.y2;
}

std::size_t component_bytes(PixelDepth depth) noexcept {
  switch (depth) {
    case PixelDepth::Byte: return 1;
    case PixelDepth::Short:
    case PixelDepth::Half: return 2;
    case PixelDepth::Float: return 4;
  }
  return 0;
}

std::byte* row_pointer(const ImageView& image, int y) noexcept {
  return image.data +
      static_cast<std::ptrdiff_t>(y - image.bounds.y1) * image.row_bytes;
}

std::uint32_t float_bits(float value) noexcept {
  std::uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

float bits_float(std::uint32_t bits) noexcept {
  float value = 0.0F;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

float half_to_float(std::uint16_t value) noexcept {
  const std::uint32_t sign = static_cast<std::uint32_t>(value & 0x8000U) << 16U;
  std::uint32_t exponent = (value >> 10U) & 0x1FU;
  std::uint32_t mantissa = value & 0x03FFU;
  if (exponent == 0U) {
    if (mantissa == 0U) return bits_float(sign);
    exponent = 127U - 15U + 1U;
    while ((mantissa & 0x0400U) == 0U) {
      mantissa <<= 1U;
      --exponent;
    }
    mantissa &= 0x03FFU;
    return bits_float(sign | (exponent << 23U) | (mantissa << 13U));
  }
  if (exponent == 0x1FU) {
    return bits_float(sign | 0x7F800000U | (mantissa << 13U));
  }
  exponent += 127U - 15U;
  return bits_float(sign | (exponent << 23U) | (mantissa << 13U));
}

std::uint16_t float_to_half(float value) noexcept {
  const std::uint32_t bits = float_bits(value);
  const std::uint16_t sign = static_cast<std::uint16_t>((bits >> 16U) & 0x8000U);
  const std::uint32_t raw_exponent = (bits >> 23U) & 0xFFU;
  const std::uint32_t mantissa = bits & 0x7FFFFFU;
  if (raw_exponent == 0xFFU) {
    if (mantissa == 0U) return static_cast<std::uint16_t>(sign | 0x7C00U);
    return static_cast<std::uint16_t>(sign | 0x7E00U);
  }
  const int exponent = static_cast<int>(raw_exponent) - 127 + 15;
  if (exponent >= 31) return static_cast<std::uint16_t>(sign | 0x7C00U);
  if (exponent <= 0) {
    if (exponent < -10) return sign;
    std::uint32_t normalized = mantissa | 0x800000U;
    const unsigned shift = static_cast<unsigned>(14 - exponent);
    std::uint32_t rounded = normalized >> shift;
    const std::uint32_t remainder = normalized & ((1U << shift) - 1U);
    const std::uint32_t halfway = 1U << (shift - 1U);
    if (remainder > halfway || (remainder == halfway && (rounded & 1U))) ++rounded;
    return static_cast<std::uint16_t>(sign | rounded);
  }
  std::uint32_t rounded = mantissa >> 13U;
  const std::uint32_t remainder = mantissa & 0x1FFFU;
  if (remainder > 0x1000U || (remainder == 0x1000U && (rounded & 1U))) {
    ++rounded;
    if (rounded == 0x400U) {
      rounded = 0;
      if (exponent + 1 >= 31) return static_cast<std::uint16_t>(sign | 0x7C00U);
      return static_cast<std::uint16_t>(sign | ((exponent + 1) << 10U));
    }
  }
  return static_cast<std::uint16_t>(sign | (exponent << 10U) | rounded);
}

float read_component(const std::byte* data, PixelDepth depth) noexcept {
  switch (depth) {
    case PixelDepth::Byte:
      return static_cast<float>(*reinterpret_cast<const std::uint8_t*>(data)) / 255.0F;
    case PixelDepth::Short: {
      std::uint16_t value = 0;
      std::memcpy(&value, data, sizeof(value));
      return static_cast<float>(value) / 65535.0F;
    }
    case PixelDepth::Half: {
      std::uint16_t value = 0;
      std::memcpy(&value, data, sizeof(value));
      return half_to_float(value);
    }
    case PixelDepth::Float: {
      float value = 0.0F;
      std::memcpy(&value, data, sizeof(value));
      return value;
    }
  }
  return std::numeric_limits<float>::quiet_NaN();
}

void write_component(std::byte* data, PixelDepth depth, float value) noexcept {
  switch (depth) {
    case PixelDepth::Byte: {
      const auto encoded = static_cast<std::uint8_t>(
          std::lround(std::clamp(value, 0.0F, 1.0F) * 255.0F));
      std::memcpy(data, &encoded, sizeof(encoded));
      break;
    }
    case PixelDepth::Short: {
      const auto encoded = static_cast<std::uint16_t>(
          std::lround(std::clamp(value, 0.0F, 1.0F) * 65535.0F));
      std::memcpy(data, &encoded, sizeof(encoded));
      break;
    }
    case PixelDepth::Half: {
      const auto encoded = float_to_half(value);
      std::memcpy(data, &encoded, sizeof(encoded));
      break;
    }
    case PixelDepth::Float:
      std::memcpy(data, &value, sizeof(value));
      break;
  }
}

bool valid_view(const ImageView& view, PixelDepth depth) noexcept {
  const auto bytes = component_bytes(depth);
  return view.data && valid(view.bounds) && view.row_bytes != 0 &&
      view.pixel_bytes == bytes * 4U;
}

}  // namespace

OriginIoStatus read_origin_window_rgba32f(
    const ImageView& source,
    PixelDepth depth,
    RectI render_window,
    std::vector<float>& output) {
  if (!source.data) return OriginIoStatus::MissingData;
  if (!valid_view(source, depth) || !valid(render_window)) {
    return OriginIoStatus::InvalidLayout;
  }
  if (!contains(source.bounds, render_window)) {
    return OriginIoStatus::WindowOutsideImage;
  }
  const auto width = static_cast<std::size_t>(render_window.x2 - render_window.x1);
  const auto height = static_cast<std::size_t>(render_window.y2 - render_window.y1);
  if (width > std::numeric_limits<std::size_t>::max() / 4U ||
      height > std::numeric_limits<std::size_t>::max() / (width == 0 ? 1U : width * 4U)) {
    return OriginIoStatus::InvalidLayout;
  }
  output.resize(width * height * 4U);
  const auto bytes = component_bytes(depth);
  for (int y = render_window.y1; y < render_window.y2; ++y) {
    const auto* row = row_pointer(source, y);
    for (int x = render_window.x1; x < render_window.x2; ++x) {
      const auto* pixel = row + static_cast<std::ptrdiff_t>(x - source.bounds.x1) *
          static_cast<std::ptrdiff_t>(source.pixel_bytes);
      const auto offset =
          (static_cast<std::size_t>(y - render_window.y1) * width +
           static_cast<std::size_t>(x - render_window.x1)) * 4U;
      for (std::size_t channel = 0; channel < 4U; ++channel) {
        const float value = read_component(pixel + channel * bytes, depth);
        if (!std::isfinite(value)) return OriginIoStatus::InvalidPixel;
        output[offset + channel] = value;
      }
    }
  }
  return OriginIoStatus::Ok;
}

OriginIoStatus write_origin_window_rgba32f(
    const std::vector<float>& input,
    const ImageView& destination,
    PixelDepth depth,
    RectI render_window) {
  if (!destination.data) return OriginIoStatus::MissingData;
  if (!valid_view(destination, depth) || !valid(render_window)) {
    return OriginIoStatus::InvalidLayout;
  }
  if (!contains(destination.bounds, render_window)) {
    return OriginIoStatus::WindowOutsideImage;
  }
  const auto width = static_cast<std::size_t>(render_window.x2 - render_window.x1);
  const auto height = static_cast<std::size_t>(render_window.y2 - render_window.y1);
  if (input.size() != width * height * 4U ||
      !std::all_of(input.begin(), input.end(), [](float value) { return std::isfinite(value); })) {
    return OriginIoStatus::InvalidPixel;
  }
  const auto bytes = component_bytes(depth);
  for (int y = render_window.y1; y < render_window.y2; ++y) {
    auto* row = row_pointer(destination, y);
    for (int x = render_window.x1; x < render_window.x2; ++x) {
      auto* pixel = row + static_cast<std::ptrdiff_t>(x - destination.bounds.x1) *
          static_cast<std::ptrdiff_t>(destination.pixel_bytes);
      const auto offset =
          (static_cast<std::size_t>(y - render_window.y1) * width +
           static_cast<std::size_t>(x - render_window.x1)) * 4U;
      for (std::size_t channel = 0; channel < 4U; ++channel) {
        write_component(pixel + channel * bytes, depth, input[offset + channel]);
      }
    }
  }
  return OriginIoStatus::Ok;
}

}  // namespace screen_simulation::ofx
