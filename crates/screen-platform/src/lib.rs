//! Replaceable operating-system, GPU, media, display, and filesystem adapters.

#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "macos")]
mod media_metal;
#[cfg(target_os = "macos")]
mod native_metal;
#[cfg(target_os = "macos")]
mod presentation_cpu;
#[cfg(target_os = "macos")]
mod presentation_metal;
#[cfg(target_os = "macos")]
mod spatial_metal;
#[cfg(target_os = "macos")]
pub use media_metal::{
    MetalMediaError, MetalMediaFrameCache, MetalMediaFrameRequest, MetalMediaPreparationTimings,
    PreparedMetalMediaFrame,
};
#[cfg(target_os = "macos")]
pub use native_metal::{MetalNativeError, MetalRawDevelopment};
#[cfg(target_os = "macos")]
pub use presentation_cpu::{
    DisplayPublicationBackend, DisplayPublicationError, ExactCpuDisplayPublication,
};
#[cfg(target_os = "macos")]
pub use presentation_metal::{MetalDisplayPublication, MetalDisplayPublicationError};

use core::fmt;
use std::path::Path;
use std::sync::OnceLock;

use ffmpeg_next as ffmpeg;
use screen_contracts::{
    ColorPrimaries, EncodedColorMetadata, MatrixCoefficients, RationalTime, SignalRange,
    TransferCharacteristic,
};
use screen_media::{
    AlphaPresence, DecodedFrame, DecodedRgba, DecodedRgba16Frame, FrameCadence,
    FrameSelectionPolicy, MediaDescriptor, PixelEncoding, RasterSize, ResolvedSignalRange,
    ResolvedSourceDecode, ResolvedYuvMatrix,
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
        pixel_encoding: pixel_descriptor
            .map(ffmpeg_bridge::pixel_encoding)
            .ok_or_else(|| {
                PlatformMediaError::InvalidVideoStream(
                    "pixel format has no FFmpeg descriptor".to_owned(),
                )
            })?,
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
        Space::BT470BG | Space::SMPTE170M => Some(MatrixCoefficients::Bt601),
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

/// CPU materialization retained only for conformance and before/after benchmarks.
pub fn decode_frame_at_time_cpu_oracle(
    path: &Path,
    requested_time: RationalTime,
    policy: FrameSelectionPolicy,
    interpretation: ResolvedSourceDecode,
) -> Result<(MediaDescriptor, DecodedFrame), PlatformMediaError> {
    let descriptor = probe_media(path)?;
    if requested_time.numerator() < 0 && policy == FrameSelectionPolicy::Exact {
        return Err(PlatformMediaError::NegativeRequestedTime);
    }
    match descriptor.duration {
        Some(duration) if requested_time >= duration && policy == FrameSelectionPolicy::Exact => {
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
    ffmpeg_bridge::configure_scaler(&mut scaler, descriptor.pixel_encoding, interpretation)?;

    let seek_timestamp = time_in_ffmpeg_base(media_seek_anchor(
        requested_time,
        descriptor.duration,
        policy,
    )?)?;
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

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
pub enum MediaDecodeDimensions {
    Native,
    Maximum { width: u32, height: u32 },
}

impl MediaDecodeDimensions {
    fn resolve(self, source: RasterSize) -> Result<RasterSize, PlatformMediaError> {
        match self {
            Self::Native => Ok(source),
            Self::Maximum { width, height } if width > 0 && height > 0 => {
                let scale = (f64::from(width) / f64::from(source.width))
                    .min(f64::from(height) / f64::from(source.height))
                    .min(1.0);
                RasterSize::new(
                    (f64::from(source.width) * scale).round().max(1.0) as u32,
                    (f64::from(source.height) * scale).round().max(1.0) as u32,
                )
                .map_err(|error| PlatformMediaError::Decode(error.to_string()))
            }
            Self::Maximum { .. } => Err(PlatformMediaError::Decode(
                "requested decode dimensions must be non-zero".to_owned(),
            )),
        }
    }
}

/// Product media decode boundary. It resolves one sample and retains normalized-integer RGBA
/// storage for direct Metal upload; it never materializes a full float raster on the CPU.
pub fn decode_rgba16_frame_at_time(
    path: &Path,
    requested_time: RationalTime,
    policy: FrameSelectionPolicy,
    interpretation: ResolvedSourceDecode,
    dimensions: MediaDecodeDimensions,
) -> Result<(MediaDescriptor, DecodedRgba16Frame), PlatformMediaError> {
    let descriptor = probe_media(path)?;
    if requested_time.numerator() < 0 && policy == FrameSelectionPolicy::Exact {
        return Err(PlatformMediaError::NegativeRequestedTime);
    }
    match descriptor.duration {
        Some(duration) if requested_time >= duration && policy == FrameSelectionPolicy::Exact => {
            return Err(PlatformMediaError::RequestedTimeOutsideSource);
        }
        None if requested_time.numerator() != 0 => {
            return Err(PlatformMediaError::UnboundedSourceTime);
        }
        _ => {}
    }
    let output = dimensions.resolve(descriptor.raster)?;
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
        output.width,
        output.height,
        ffmpeg::software::scaling::flag::Flags::BILINEAR,
    )
    .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;
    ffmpeg_bridge::configure_scaler(&mut scaler, descriptor.pixel_encoding, interpretation)?;
    let seek_timestamp = time_in_ffmpeg_base(media_seek_anchor(
        requested_time,
        descriptor.duration,
        policy,
    )?)?;
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
        while let Some(frame) = receive_rgba16_frame(&mut decoder, &mut scaler, time_base)? {
            if frame.timestamp == requested_time {
                return Ok((descriptor, frame));
            }
            if frame.timestamp > requested_time {
                return resolve_rgba16_sample(
                    descriptor,
                    earlier,
                    Some(frame),
                    requested_time,
                    policy,
                );
            }
            earlier = Some(frame);
        }
    }
    decoder
        .send_eof()
        .map_err(|error| PlatformMediaError::Decode(error.to_string()))?;
    while let Some(frame) = receive_rgba16_frame(&mut decoder, &mut scaler, time_base)? {
        if frame.timestamp == requested_time {
            return Ok((descriptor, frame));
        }
        if frame.timestamp > requested_time {
            return resolve_rgba16_sample(descriptor, earlier, Some(frame), requested_time, policy);
        }
        earlier = Some(frame);
    }
    resolve_rgba16_sample(descriptor, earlier, None, requested_time, policy)
}

fn resolve_rgba16_sample(
    descriptor: MediaDescriptor,
    earlier: Option<DecodedRgba16Frame>,
    later: Option<DecodedRgba16Frame>,
    requested_time: RationalTime,
    policy: FrameSelectionPolicy,
) -> Result<(MediaDescriptor, DecodedRgba16Frame), PlatformMediaError> {
    let selected = match policy {
        FrameSelectionPolicy::Exact => None,
        FrameSelectionPolicy::Floor => {
            earlier.or_else(|| (requested_time.numerator() < 0).then_some(later).flatten())
        }
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

fn resolve_sample(
    descriptor: MediaDescriptor,
    earlier: Option<DecodedFrame>,
    later: Option<DecodedFrame>,
    requested_time: RationalTime,
    policy: FrameSelectionPolicy,
) -> Result<(MediaDescriptor, DecodedFrame), PlatformMediaError> {
    let selected = match policy {
        FrameSelectionPolicy::Exact => None,
        FrameSelectionPolicy::Floor => {
            earlier.or_else(|| (requested_time.numerator() < 0).then_some(later).flatten())
        }
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

fn media_seek_anchor(
    requested_time: RationalTime,
    duration: Option<RationalTime>,
    policy: FrameSelectionPolicy,
) -> Result<RationalTime, PlatformMediaError> {
    if policy == FrameSelectionPolicy::Exact {
        return Ok(requested_time);
    }
    let zero = RationalTime::new(0, 1).map_err(|_| PlatformMediaError::TimestampOverflow)?;
    if requested_time < zero {
        return Ok(zero);
    }
    let Some(duration) = duration else {
        return Ok(requested_time);
    };
    if requested_time < duration {
        return Ok(requested_time);
    }
    let ffmpeg_time_base = u32::try_from(ffmpeg::ffi::AV_TIME_BASE)
        .map_err(|_| PlatformMediaError::TimestampOverflow)?;
    duration
        .checked_sub(
            RationalTime::new(1, ffmpeg_time_base)
                .map_err(|_| PlatformMediaError::TimestampOverflow)?,
        )
        .map(|time| time.max(zero))
        .map_err(|_| PlatformMediaError::TimestampOverflow)
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

fn receive_rgba16_frame(
    decoder: &mut ffmpeg::decoder::Video,
    scaler: &mut ffmpeg::software::scaling::context::Context,
    time_base: ffmpeg::Rational,
) -> Result<Option<DecodedRgba16Frame>, PlatformMediaError> {
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
        pixels.extend(row_data.chunks_exact(8).map(|pixel| {
            let channel = |offset| u16::from_le_bytes([pixel[offset], pixel[offset + 1]]);
            [channel(0), channel(2), channel(4), channel(6)]
        }));
    }
    DecodedRgba16Frame {
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

#[allow(unsafe_code)]
mod ffmpeg_bridge {
    use super::*;

    pub(super) fn pixel_encoding(descriptor: ffmpeg::format::pixel::Descriptor) -> PixelEncoding {
        if descriptor.nb_components() <= 2 {
            return PixelEncoding::Monochrome;
        }
        // SAFETY: `Descriptor` is constructed by FFmpeg from its static pixel-format table, and
        // its public `as_ptr` remains valid for the lifetime of the process.
        let flags = unsafe { (*descriptor.as_ptr()).flags };
        if flags & u64::try_from(ffmpeg::ffi::AV_PIX_FMT_FLAG_RGB).expect("RGB flag is positive")
            != 0
        {
            PixelEncoding::Rgb
        } else {
            PixelEncoding::Yuv
        }
    }

    pub(super) fn configure_scaler(
        scaler: &mut ffmpeg::software::scaling::context::Context,
        encoding: PixelEncoding,
        interpretation: ResolvedSourceDecode,
    ) -> Result<(), PlatformMediaError> {
        let (matrix, range) = match (encoding, interpretation) {
            (PixelEncoding::Rgb, ResolvedSourceDecode::Rgb) => return Ok(()),
            (PixelEncoding::Yuv, ResolvedSourceDecode::Yuv(yuv)) => (yuv.matrix, yuv.range),
            (PixelEncoding::Monochrome, ResolvedSourceDecode::Monochrome(range)) => {
                // libswscale requires a coefficient table even though monochrome conversion does
                // not consume chroma. This value therefore has no image-semantic effect.
                (ResolvedYuvMatrix::Bt709, range)
            }
            _ => return Err(PlatformMediaError::DecodeInterpretationMismatch),
        };
        let coefficient_id = match matrix {
            ResolvedYuvMatrix::Bt601 => ffmpeg::ffi::SWS_CS_ITU601,
            ResolvedYuvMatrix::Bt709 => ffmpeg::ffi::SWS_CS_ITU709,
            ResolvedYuvMatrix::Bt2020 => ffmpeg::ffi::SWS_CS_BT2020,
        };
        let source_full_range = match range {
            ResolvedSignalRange::Limited => 0,
            ResolvedSignalRange::Full => 1,
        };
        // SAFETY: `scaler` owns a live `SwsContext`; FFmpeg owns the immutable coefficient table;
        // all scalar arguments follow the documented 16.16 fixed-point contract. The pointers are
        // used only for the duration of this call and no Rust reference aliases their storage.
        let result = unsafe {
            let coefficients = ffmpeg::ffi::sws_getCoefficients(coefficient_id);
            ffmpeg::ffi::sws_setColorspaceDetails(
                scaler.as_mut_ptr(),
                coefficients,
                source_full_range,
                coefficients,
                1,
                0,
                1 << 16,
                1 << 16,
            )
        };
        if result < 0 {
            Err(PlatformMediaError::CannotConfigureDecodeInterpretation)
        } else {
            Ok(())
        }
    }
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
    DecodeInterpretationMismatch,
    CannotConfigureDecodeInterpretation,
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
            Self::DecodeInterpretationMismatch => formatter.write_str(
                "resolved source decode interpretation does not match the decoded pixel encoding",
            ),
            Self::CannotConfigureDecodeInterpretation => {
                formatter.write_str("FFmpeg rejected the resolved source matrix or range")
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
            pixel_encoding: PixelEncoding::Rgb,
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
    fn floor_and_nearest_hold_bounded_source_edges_explicitly() {
        let first = frame(time(0, 25));
        let last = frame(time(24, 25));
        assert_eq!(
            resolve_sample(
                descriptor(),
                None,
                Some(first.clone()),
                time(-1, 1_000),
                FrameSelectionPolicy::Floor,
            )
            .expect("floor holds first sample")
            .1,
            first
        );
        assert_eq!(
            resolve_sample(
                descriptor(),
                Some(last.clone()),
                None,
                time(1_001, 1_000),
                FrameSelectionPolicy::Nearest,
            )
            .expect("nearest holds last sample")
            .1,
            last
        );
    }

    #[test]
    fn bounded_edge_hold_seeks_inside_the_source_without_changing_selection_time() {
        let duration = time(1, 1);
        assert_eq!(
            media_seek_anchor(time(-1, 1_000), Some(duration), FrameSelectionPolicy::Floor,)
                .expect("leading anchor"),
            time(0, 1)
        );
        assert_eq!(
            media_seek_anchor(time(2, 1), Some(duration), FrameSelectionPolicy::Floor,)
                .expect("trailing anchor"),
            time(999_999, 1_000_000)
        );
        assert_eq!(
            media_seek_anchor(time(1, 24), Some(duration), FrameSelectionPolicy::Floor,)
                .expect("interior anchor"),
            time(1, 24)
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
        assert_eq!(
            declared_matrix(Space::SMPTE170M),
            Some(MatrixCoefficients::Bt601)
        );
        assert_eq!(declared_range(Range::MPEG), Some(SignalRange::Limited));
        assert_eq!(declared_primaries(Primaries::Unspecified), None);
        assert_eq!(declared_transfer(Transfer::Unspecified), None);
    }

    #[test]
    fn pixel_encoding_is_derived_from_ffmpeg_pixel_descriptors() {
        assert_eq!(
            ffmpeg_bridge::pixel_encoding(
                ffmpeg::format::Pixel::RGBA
                    .descriptor()
                    .expect("RGBA descriptor"),
            ),
            PixelEncoding::Rgb
        );
        assert_eq!(
            ffmpeg_bridge::pixel_encoding(
                ffmpeg::format::Pixel::YUV444P
                    .descriptor()
                    .expect("YUV descriptor"),
            ),
            PixelEncoding::Yuv
        );
        assert_eq!(
            ffmpeg_bridge::pixel_encoding(
                ffmpeg::format::Pixel::GRAY8
                    .descriptor()
                    .expect("gray descriptor"),
            ),
            PixelEncoding::Monochrome
        );
    }

    #[test]
    fn resolved_signal_range_changes_the_reference_yuv_decode() {
        initialize_ffmpeg().expect("FFmpeg initializes");
        let mut source =
            ffmpeg::util::frame::video::Video::new(ffmpeg::format::Pixel::YUV444P, 1, 1);
        source.data_mut(0)[0] = 16;
        source.data_mut(1)[0] = 128;
        source.data_mut(2)[0] = 128;
        let decode = |range| {
            let mut scaler = ffmpeg::software::scaling::context::Context::get(
                ffmpeg::format::Pixel::YUV444P,
                1,
                1,
                ffmpeg::format::Pixel::RGBA64LE,
                1,
                1,
                ffmpeg::software::scaling::flag::Flags::POINT,
            )
            .expect("test scaler");
            ffmpeg_bridge::configure_scaler(
                &mut scaler,
                PixelEncoding::Yuv,
                ResolvedSourceDecode::Yuv(screen_media::ResolvedYuvInterpretation {
                    matrix: ResolvedYuvMatrix::Bt709,
                    range,
                }),
            )
            .expect("resolved interpretation");
            let mut output = ffmpeg::util::frame::video::Video::empty();
            scaler.run(&source, &mut output).expect("scaled frame");
            u16::from_le_bytes([output.data(0)[0], output.data(0)[1]])
        };
        let limited_black = decode(ResolvedSignalRange::Limited);
        let full_dark_gray = decode(ResolvedSignalRange::Full);
        assert!(limited_black < 512, "limited code 16 must decode as black");
        assert!(
            full_dark_gray > 3_000,
            "full-range code 16 must remain above black"
        );
    }
}
