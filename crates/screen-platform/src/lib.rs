//! Replaceable operating-system, GPU, media, display, and filesystem adapters.

#![deny(unsafe_code)]

use core::fmt;
use std::path::Path;
use std::sync::OnceLock;

use ffmpeg_next as ffmpeg;
use screen_contracts::RationalTime;
use screen_media::{
    AlphaPresence, DecodedFrame, DecodedRgba, FrameCadence, MediaDescriptor, RasterSize,
};

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

pub fn decode_first_frame(
    path: &Path,
) -> Result<(MediaDescriptor, DecodedFrame), PlatformMediaError> {
    let descriptor = probe_media(path)?;
    let mut context = ffmpeg::format::input(path)
        .map_err(|error| PlatformMediaError::CannotOpen(error.to_string()))?;
    let stream = context
        .streams()
        .best(ffmpeg::media::Type::Video)
        .ok_or(PlatformMediaError::NoVideoStream)?;
    let stream_index = stream.index();
    let time_base = stream.time_base();
    let codec_context = ffmpeg::codec::context::Context::from_parameters(stream.parameters())
        .map_err(|error| PlatformMediaError::InvalidVideoStream(error.to_string()))?;
    let mut decoder = codec_context
        .decoder()
        .video()
        .map_err(|error| PlatformMediaError::InvalidVideoStream(error.to_string()))?;
    let mut scaler = ffmpeg::software::scaling::context::Context::get(
        decoder.format(),
        decoder.width(),
        decoder.height(),
        ffmpeg::format::Pixel::RGBA64LE,
        decoder.width(),
        decoder.height(),
        ffmpeg::software::scaling::flag::Flags::BILINEAR,
    )
    .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;

    for (packet_stream, packet) in context.packets() {
        if packet_stream.index() != stream_index {
            continue;
        }
        decoder
            .send_packet(&packet)
            .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;
        if let Some(frame) = receive_frame(&mut decoder, &mut scaler, time_base)? {
            return Ok((descriptor, frame));
        }
    }
    decoder
        .send_eof()
        .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;
    receive_frame(&mut decoder, &mut scaler, time_base)?
        .map(|frame| (descriptor, frame))
        .ok_or(PlatformMediaError::NoDecodedFrame)
}

fn receive_frame(
    decoder: &mut ffmpeg::decoder::Video,
    scaler: &mut ffmpeg::software::scaling::context::Context,
    time_base: ffmpeg::Rational,
) -> Result<Option<DecodedFrame>, PlatformMediaError> {
    let mut decoded = ffmpeg::util::frame::video::Video::empty();
    if decoder.receive_frame(&mut decoded).is_err() {
        return Ok(None);
    }
    let mut rgba = ffmpeg::util::frame::video::Video::empty();
    scaler
        .run(&decoded, &mut rgba)
        .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;
    let timestamp = decoded.timestamp().unwrap_or(0);
    let exact_timestamp = timestamp
        .checked_mul(i64::from(time_base.numerator()))
        .ok_or(PlatformMediaError::TimestampOverflow)?;
    let denominator = u32::try_from(time_base.denominator())
        .map_err(|_| PlatformMediaError::TimestampOverflow)?;
    let timestamp = RationalTime::new(exact_timestamp, denominator)
        .map_err(|_| PlatformMediaError::TimestampOverflow)?;
    let width = rgba.width();
    let height = rgba.height();
    let row_bytes = usize::try_from(width)
        .map_err(|_| PlatformMediaError::FrameTooLarge)?
        .checked_mul(8)
        .ok_or(PlatformMediaError::FrameTooLarge)?;
    let stride = rgba.stride(0);
    if stride < row_bytes {
        return Err(PlatformMediaError::InvalidDecodedStorage);
    }
    let data = rgba.data(0);
    let capacity = usize::try_from(u64::from(width) * u64::from(height))
        .map_err(|_| PlatformMediaError::FrameTooLarge)?;
    let mut pixels = Vec::with_capacity(capacity);
    for row in 0..height as usize {
        let start = row
            .checked_mul(stride)
            .ok_or(PlatformMediaError::FrameTooLarge)?;
        let end = start
            .checked_add(row_bytes)
            .ok_or(PlatformMediaError::FrameTooLarge)?;
        let row_data = data
            .get(start..end)
            .ok_or(PlatformMediaError::InvalidDecodedStorage)?;
        for pixel in row_data.chunks_exact(8) {
            let channel = |offset| {
                f32::from(u16::from_le_bytes([pixel[offset], pixel[offset + 1]])) / 65_535.0
            };
            pixels.push(DecodedRgba {
                r: channel(0),
                g: channel(2),
                b: channel(4),
                a: channel(6),
            });
        }
    }
    DecodedFrame {
        raster: RasterSize::new(width, height)
            .map_err(|error| PlatformMediaError::Decode(error.to_string()))?,
        timestamp,
        pixels,
    }
    .validate()
    .map(Some)
    .map_err(|error| PlatformMediaError::Decode(error.to_string()))
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
    Decode(String),
    NoDecodedFrame,
    TimestampOverflow,
    FrameTooLarge,
    InvalidDecodedStorage,
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
            Self::Decode(message) => write!(formatter, "FFmpeg decode failed: {message}"),
            Self::NoDecodedFrame => formatter.write_str("the source produced no decoded frame"),
            Self::TimestampOverflow => {
                formatter.write_str("decoded frame timestamp exceeds the exact time contract")
            }
            Self::FrameTooLarge => formatter.write_str("decoded frame exceeds addressable memory"),
            Self::InvalidDecodedStorage => {
                formatter.write_str("FFmpeg returned invalid decoded frame storage")
            }
        }
    }
}

impl std::error::Error for PlatformMediaError {}
