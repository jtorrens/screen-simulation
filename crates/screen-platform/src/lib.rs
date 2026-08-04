//! Replaceable operating-system, GPU, media, display, and filesystem adapters.

#![deny(unsafe_code)]

use core::fmt;
use std::path::Path;
use std::sync::OnceLock;

use ffmpeg_next as ffmpeg;
use screen_contracts::RationalTime;
use screen_media::{AlphaPresence, FrameCadence, MediaDescriptor, RasterSize};

static FFMPEG_INITIALIZED: OnceLock<Result<(), String>> = OnceLock::new();

pub fn probe_media(path: &Path) -> Result<MediaDescriptor, PlatformMediaError> {
    initialize_ffmpeg()?;
    let context = ffmpeg::format::input(path)
        .map_err(|error| PlatformMediaError::CannotOpen(error.to_string()))?;
    let stream = context
        .streams()
        .best(ffmpeg::media::Type::Video)
        .ok_or(PlatformMediaError::NoVideoStream)?;
    let codec_context = ffmpeg::codec::context::Context::from_parameters(stream.parameters())
        .map_err(|error| PlatformMediaError::InvalidVideoStream(error.to_string()))?;
    let decoder = codec_context
        .decoder()
        .video()
        .map_err(|error| PlatformMediaError::InvalidVideoStream(error.to_string()))?;
    let raster = RasterSize::new(decoder.width(), decoder.height())
        .map_err(|error| PlatformMediaError::InvalidVideoStream(error.to_string()))?;
    let rate = stream.rate();
    let cadence = if rate.numerator() > 0 && rate.denominator() > 0 {
        FrameCadence::Constant {
            frame_rate: RationalTime::new(i64::from(rate.numerator()), rate.denominator() as u32)
                .map_err(|error| {
                PlatformMediaError::InvalidVideoStream(error.to_string())
            })?,
        }
    } else {
        FrameCadence::Variable
    };
    let duration = (context.duration() > 0)
        .then(|| RationalTime::new(context.duration(), ffmpeg::ffi::AV_TIME_BASE as u32))
        .transpose()
        .map_err(|error| PlatformMediaError::InvalidVideoStream(error.to_string()))?;
    let pixel_descriptor = decoder.format().descriptor();
    Ok(MediaDescriptor {
        raster,
        cadence,
        duration,
        alpha: if pixel_descriptor.is_some_and(|descriptor| descriptor.nb_components() == 4) {
            AlphaPresence::Present
        } else {
            AlphaPresence::Absent
        },
        codec_name: decoder
            .codec()
            .map_or_else(|| "unknown".to_owned(), |codec| codec.name().to_owned()),
        pixel_format_name: pixel_descriptor.map_or_else(
            || "unknown".to_owned(),
            |descriptor| descriptor.name().to_owned(),
        ),
    })
}

fn initialize_ffmpeg() -> Result<(), PlatformMediaError> {
    FFMPEG_INITIALIZED
        .get_or_init(|| ffmpeg::init().map_err(|error| error.to_string()))
        .clone()
        .map_err(PlatformMediaError::Initialization)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlatformMediaError {
    Initialization(String),
    CannotOpen(String),
    NoVideoStream,
    InvalidVideoStream(String),
}

impl fmt::Display for PlatformMediaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Initialization(message) => {
                write!(formatter, "FFmpeg initialization failed: {message}")
            }
            Self::CannotOpen(message) => {
                write!(formatter, "FFmpeg could not open the source: {message}")
            }
            Self::NoVideoStream => formatter.write_str("the selected source has no video stream"),
            Self::InvalidVideoStream(message) => {
                write!(formatter, "invalid video stream: {message}")
            }
        }
    }
}

impl std::error::Error for PlatformMediaError {}
