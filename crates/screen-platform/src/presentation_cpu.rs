use core::fmt;
use std::sync::Mutex;
use std::thread;

use screen_color::{CameraOutputProcessor, CameraOutputTransform, ColorEngine};
use screen_contracts::LinearRgb;

/// Presentation-only platform boundary from immutable developed ACEScg to final RGBA8 bytes.
/// Implementations cannot mutate or reinterpret the authoritative scene-linear input.
pub trait DisplayPublicationBackend {
    type Error: fmt::Display;

    fn publish_acescg_rgba8(&self, pixels: &[LinearRgb]) -> Result<Vec<u8>, Self::Error>;
}

pub struct ExactCpuDisplayPublication {
    processors: Vec<Mutex<CameraOutputProcessor>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DisplayPublicationError(String);

impl ExactCpuDisplayPublication {
    pub fn new(transform: CameraOutputTransform) -> Result<Self, DisplayPublicationError> {
        let worker_count = thread::available_parallelism().map_or(1, usize::from);
        let engine = ColorEngine::bundled().map_err(DisplayPublicationError::from_display)?;
        let processors = (0..worker_count)
            .map(|_| {
                engine
                    .camera_output_processor(transform)
                    .map(Mutex::new)
                    .map_err(DisplayPublicationError::from_display)
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self { processors })
    }
}

impl DisplayPublicationError {
    fn from_display(error: impl fmt::Display) -> Self {
        Self(error.to_string())
    }
}

impl DisplayPublicationBackend for ExactCpuDisplayPublication {
    type Error = DisplayPublicationError;

    fn publish_acescg_rgba8(&self, pixels: &[LinearRgb]) -> Result<Vec<u8>, Self::Error> {
        let mut rgba = Vec::with_capacity(pixels.len() * 4);
        for pixel in pixels {
            rgba.extend_from_slice(&[pixel.r, pixel.g, pixel.b, 1.0]);
        }
        let chunk_pixels = pixels.len().div_ceil(self.processors.len());
        let chunk_scalars = chunk_pixels.max(1) * 4;
        thread::scope(|scope| {
            let handles = rgba
                .chunks_mut(chunk_scalars)
                .zip(&self.processors)
                .map(|(chunk, processor)| {
                    scope.spawn(move || {
                        processor
                            .lock()
                            .map_err(|error| DisplayPublicationError(error.to_string()))?
                            .apply_acescg_rgba_buffer(chunk)
                            .map_err(DisplayPublicationError::from_display)
                    })
                })
                .collect::<Vec<_>>();
            for handle in handles {
                handle
                    .join()
                    .map_err(|_| DisplayPublicationError("OCIO worker panicked".to_owned()))??;
            }
            Ok::<(), DisplayPublicationError>(())
        })?;
        Ok(rgba
            .chunks_exact(4)
            .flat_map(|pixel| {
                let channel = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
                [channel(pixel[0]), channel(pixel[1]), channel(pixel[2]), 255]
            })
            .collect())
    }
}

impl fmt::Display for DisplayPublicationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for DisplayPublicationError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parallel_publication_is_byte_exact_against_single_ocio_processor() {
        let mut pixels = vec![
            LinearRgb::new(f32::NAN, f32::INFINITY, f32::NEG_INFINITY),
            LinearRgb::new(-0.1, 0.18, 4.0),
            LinearRgb::new(1.0, 0.0, 0.0),
            LinearRgb::new(0.0, 1.0, 0.0),
            LinearRgb::new(0.0, 0.0, 1.0),
        ];
        pixels.extend((0..131_072_u32).map(|index| {
            let value = index as f32 / 16_384.0 - 2.0;
            LinearRgb::new(value, value * 0.37, value * 1.91)
        }));
        let engine = ColorEngine::bundled().expect("bundled OCIO");
        for transform in CameraOutputTransform::ALL {
            let backend = ExactCpuDisplayPublication::new(transform).expect("publication backend");
            let reference = engine
                .camera_output_processor(transform)
                .expect("reference processor");
            let actual = backend
                .publish_acescg_rgba8(&pixels)
                .expect("parallel publication");
            let mut reference_rgba = Vec::with_capacity(pixels.len() * 4);
            for pixel in &pixels {
                reference_rgba.extend_from_slice(&[pixel.r, pixel.g, pixel.b, 1.0]);
            }
            reference
                .apply_acescg_rgba_buffer(&mut reference_rgba)
                .expect("reference OCIO");
            let expected = reference_rgba
                .chunks_exact(4)
                .flat_map(|pixel| {
                    let channel = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
                    [channel(pixel[0]), channel(pixel[1]), channel(pixel[2]), 255]
                })
                .collect::<Vec<_>>();
            assert_eq!(actual, expected, "{}", transform.label());
        }
    }
}
