//! Replaceable operating-system, GPU, media, display, and filesystem adapters.

#![deny(unsafe_code)]

use core::fmt;
use std::path::Path;
use std::sync::OnceLock;

use ffmpeg_next as ffmpeg;
use screen_contracts::{
    ColorPrimaries, EncodedColorMetadata, MatrixCoefficients, RationalTime, SignalRange,
    TransferCharacteristic,
};
use screen_media::{
    AlphaPresence, DecodedFrame, DecodedRgba, FrameCadence, FrameSelectionPolicy, MediaDescriptor,
    RasterSize,
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
    let color_metadata = EncodedColorMetadata {
        primaries: declared_primaries(decoder.color_primaries()),
        transfer: declared_transfer(decoder.color_transfer_characteristic()),
        matrix: declared_matrix(decoder.color_space()),
        range: declared_range(decoder.color_range()),
    };
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
        color_metadata,
    })
}

fn declared_primaries(value: ffmpeg::util::color::Primaries) -> Option<ColorPrimaries> {
    use ffmpeg::util::color::Primaries;
    match value {
        Primaries::Unspecified => None,
        Primaries::BT709 => Some(ColorPrimaries::Bt709),
        Primaries::BT2020 => Some(ColorPrimaries::Bt2020),
        Primaries::SMPTE432 => Some(ColorPrimaries::P3D65),
        other => Some(ColorPrimaries::Other(
            other.name().unwrap_or("unrecognized primaries").to_owned(),
        )),
    }
}

fn declared_transfer(
    value: ffmpeg::util::color::TransferCharacteristic,
) -> Option<TransferCharacteristic> {
    use ffmpeg::util::color::TransferCharacteristic as FfmpegTransfer;
    match value {
        FfmpegTransfer::Unspecified => None,
        FfmpegTransfer::BT709 => Some(TransferCharacteristic::Bt709),
        FfmpegTransfer::IEC61966_2_1 => Some(TransferCharacteristic::Srgb),
        FfmpegTransfer::GAMMA22 => Some(TransferCharacteristic::Gamma22),
        FfmpegTransfer::GAMMA28 => Some(TransferCharacteristic::Gamma28),
        FfmpegTransfer::Linear => Some(TransferCharacteristic::Linear),
        FfmpegTransfer::SMPTE2084 => Some(TransferCharacteristic::Pq),
        FfmpegTransfer::ARIB_STD_B67 => Some(TransferCharacteristic::Hlg),
        other => Some(TransferCharacteristic::Other(
            other.name().unwrap_or("unrecognized transfer").to_owned(),
        )),
    }
}

fn declared_matrix(value: ffmpeg::util::color::Space) -> Option<MatrixCoefficients> {
    use ffmpeg::util::color::Space;
    match value {
        Space::Unspecified => None,
        Space::RGB => Some(MatrixCoefficients::Rgb),
        Space::BT709 => Some(MatrixCoefficients::Bt709),
        Space::BT2020NCL => Some(MatrixCoefficients::Bt2020Ncl),
        Space::BT2020CL => Some(MatrixCoefficients::Bt2020Cl),
        other => Some(MatrixCoefficients::Other(
            other.name().unwrap_or("unrecognized matrix").to_owned(),
        )),
    }
}

fn declared_range(value: ffmpeg::util::color::Range) -> Option<SignalRange> {
    use ffmpeg::util::color::Range;
    match value {
        Range::Unspecified => None,
        Range::MPEG => Some(SignalRange::Limited),
        Range::JPEG => Some(SignalRange::Full),
    }
}

pub fn decode_frame_at_time(
    path: &Path,
    requested_time: RationalTime,
    policy: FrameSelectionPolicy,
) -> Result<(MediaDescriptor, DecodedFrame), PlatformMediaError> {
    let descriptor = probe_media(path)?;
    if requested_time.numerator() < 0 {
        return Err(PlatformMediaError::NegativeRequestedTime);
    }
    match descriptor.duration {
        Some(duration) if requested_time >= duration => {
            return Err(PlatformMediaError::RequestedTimeOutsideSource);
        }
        None if requested_time.numerator() != 0 => {
            return Err(PlatformMediaError::UnboundedSourceTime);
        }
        _ => {}
    }
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

    let seek_timestamp = time_in_ffmpeg_base(requested_time)?;
    if seek_timestamp > 0 {
        context
            .seek(seek_timestamp, ..seek_timestamp)
            .map_err(|error| PlatformMediaError::Seek(error.to_string()))?;
    }

    let mut earlier = None;
    for (packet_stream, packet) in context.packets() {
        if packet_stream.index() != stream_index {
            continue;
        }
        decoder
            .send_packet(&packet)
            .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;
        while let Some(frame) = receive_frame(&mut decoder, &mut scaler, time_base)? {
            if frame.timestamp == requested_time {
                return Ok((descriptor, frame));
            }
            if frame.timestamp > requested_time {
                return resolve_sample(descriptor, earlier, Some(frame), requested_time, policy);
            }
            earlier = Some(frame);
        }
    }
    decoder
        .send_eof()
        .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;
    while let Some(frame) = receive_frame(&mut decoder, &mut scaler, time_base)? {
        if frame.timestamp == requested_time {
            return Ok((descriptor, frame));
        }
        if frame.timestamp > requested_time {
            return resolve_sample(descriptor, earlier, Some(frame), requested_time, policy);
        }
        earlier = Some(frame);
    }
    resolve_sample(descriptor, earlier, None, requested_time, policy)
}

fn resolve_sample(
    descriptor: MediaDescriptor,
    earlier: Option<DecodedFrame>,
    later: Option<DecodedFrame>,
    requested_time: RationalTime,
    policy: FrameSelectionPolicy,
) -> Result<(MediaDescriptor, DecodedFrame), PlatformMediaError> {
    let selected = match policy {
        FrameSelectionPolicy::Exact => None,
        FrameSelectionPolicy::Floor => earlier,
        FrameSelectionPolicy::Nearest => match (earlier, later) {
            (Some(earlier), Some(later)) => Some(
                if earlier_is_nearer_or_tied(requested_time, earlier.timestamp, later.timestamp) {
                    earlier
                } else {
                    later
                },
            ),
            (Some(earlier), None) => Some(earlier),
            (None, Some(later)) => Some(later),
            (None, None) => None,
        },
    };
    selected
        .map(|frame| (descriptor, frame))
        .ok_or(PlatformMediaError::NoSampleAtRequestedTime)
}

fn earlier_is_nearer_or_tied(
    requested: RationalTime,
    earlier: RationalTime,
    later: RationalTime,
) -> bool {
    let earlier_numerator = (i128::from(requested.numerator()) * i128::from(earlier.denominator())
        - i128::from(earlier.numerator()) * i128::from(requested.denominator()))
    .abs();
    let earlier_denominator =
        i128::from(requested.denominator()) * i128::from(earlier.denominator());
    let later_numerator = (i128::from(later.numerator()) * i128::from(requested.denominator())
        - i128::from(requested.numerator()) * i128::from(later.denominator()))
    .abs();
    let later_denominator = i128::from(later.denominator()) * i128::from(requested.denominator());
    earlier_numerator * later_denominator <= later_numerator * earlier_denominator
}

fn time_in_ffmpeg_base(time: RationalTime) -> Result<i64, PlatformMediaError> {
    let scaled = i128::from(time.numerator())
        .checked_mul(i128::from(ffmpeg::ffi::AV_TIME_BASE))
        .ok_or(PlatformMediaError::TimestampOverflow)?
        / i128::from(time.denominator());
    i64::try_from(scaled).map_err(|_| PlatformMediaError::TimestampOverflow)
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
    let timestamp = decoded
        .timestamp()
        .ok_or(PlatformMediaError::MissingFrameTimestamp)?;
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
    Seek(String),
    NegativeRequestedTime,
    RequestedTimeOutsideSource,
    UnboundedSourceTime,
    NoSampleAtRequestedTime,
    MissingFrameTimestamp,
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
            Self::Seek(message) => write!(formatter, "FFmpeg seek failed: {message}"),
            Self::NegativeRequestedTime => {
                formatter.write_str("source sample time must be non-negative")
            }
            Self::RequestedTimeOutsideSource => {
                formatter.write_str("requested project time lies outside the source duration")
            }
            Self::UnboundedSourceTime => formatter.write_str(
                "source duration is unknown, so only its exact initial sample can be selected",
            ),
            Self::NoSampleAtRequestedTime => {
                formatter.write_str("source has no sample at the requested project time")
            }
            Self::MissingFrameTimestamp => {
                formatter.write_str("decoded source frame has no timestamp")
            }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn time(numerator: i64, denominator: u32) -> RationalTime {
        RationalTime::new(numerator, denominator).expect("valid test time")
    }

    fn descriptor() -> MediaDescriptor {
        MediaDescriptor {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            cadence: FrameCadence::Variable,
            duration: Some(time(1, 1)),
            alpha: AlphaPresence::Absent,
            codec_name: "test".to_owned(),
            pixel_format_name: "rgba64le".to_owned(),
            color_metadata: EncodedColorMetadata::default(),
        }
    }

    fn frame(timestamp: RationalTime) -> DecodedFrame {
        DecodedFrame {
            raster: RasterSize::new(1, 1).expect("valid raster"),
            timestamp,
            pixels: vec![DecodedRgba {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            }],
        }
    }

    #[test]
    fn nearest_sample_uses_exact_distance_and_earlier_tie_break() {
        assert!(earlier_is_nearer_or_tied(
            time(1, 2),
            time(1, 3),
            time(2, 3)
        ));
        assert!(!earlier_is_nearer_or_tied(
            time(3, 5),
            time(1, 3),
            time(2, 3)
        ));
    }

    #[test]
    fn authored_sample_policy_changes_resolution_without_fallback() {
        let requested = time(1, 2);
        let earlier = frame(time(1, 3));
        let later = frame(time(2, 3));
        assert_eq!(
            resolve_sample(
                descriptor(),
                Some(earlier.clone()),
                Some(later.clone()),
                requested,
                FrameSelectionPolicy::Exact,
            ),
            Err(PlatformMediaError::NoSampleAtRequestedTime)
        );
        assert_eq!(
            resolve_sample(
                descriptor(),
                Some(earlier.clone()),
                Some(later.clone()),
                requested,
                FrameSelectionPolicy::Floor,
            )
            .expect("floor sample")
            .1,
            earlier
        );
        assert_eq!(
            resolve_sample(
                descriptor(),
                Some(earlier.clone()),
                Some(later),
                requested,
                FrameSelectionPolicy::Nearest,
            )
            .expect("nearest sample")
            .1,
            earlier
        );
    }

    #[test]
    fn ffmpeg_color_declarations_map_to_typed_metadata_without_selecting_an_idt() {
        use ffmpeg::util::color::{Primaries, Range, Space, TransferCharacteristic as Transfer};

        assert_eq!(
            declared_primaries(Primaries::BT709),
            Some(ColorPrimaries::Bt709)
        );
        assert_eq!(
            declared_transfer(Transfer::BT709),
            Some(TransferCharacteristic::Bt709)
        );
        assert_eq!(
            declared_matrix(Space::BT709),
            Some(MatrixCoefficients::Bt709)
        );
        assert_eq!(declared_range(Range::MPEG), Some(SignalRange::Limited));
        assert_eq!(declared_primaries(Primaries::Unspecified), None);
        assert_eq!(declared_transfer(Transfer::Unspecified), None);
    }
}
