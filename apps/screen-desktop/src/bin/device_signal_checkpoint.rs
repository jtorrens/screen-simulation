use std::{env, fs, path::PathBuf};

use half::f16;
use image::{ImageBuffer, Rgba};
use screen_color::{ColorEngine, DeviceColorTarget, OcioInputTransform, SourceColorInterpretation};
use serde::{Deserialize, Serialize};

const CHECKPOINT_SCHEMA: &str = "ScreenSimulation.FeederSignalCheckpoint.v2";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckpointMetadata<'a> {
    schema: &'static str,
    width: u32,
    height: u32,
    pixel_encoding: &'static str,
    #[serde(rename = "inputTransformID")]
    input_transform_id: &'a str,
    input_reference_domain: &'a str,
    #[serde(rename = "outputSignalID")]
    output_signal_id: &'a str,
    #[serde(rename = "feederOutputTransformID")]
    feeder_output_transform_id: &'a str,
    alpha_interpretation: &'a str,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    if arguments.len() != 6 {
        return Err(
            "usage: device_signal_checkpoint SOURCE.png PACKAGE.feedersignal DIAGNOSTIC.png INPUT_TRANSFORM_ID OUTPUT_SIGNAL_ID ALPHA"
                .into(),
        );
    }
    let source_path = PathBuf::from(&arguments[0]);
    let package_path = PathBuf::from(&arguments[1]);
    let diagnostic_path = PathBuf::from(&arguments[2]);
    let input = OcioInputTransform::from_stable_id(&arguments[3])
        .ok_or_else(|| format!("unknown Input Transform `{}`", arguments[3]))?;
    let target = DeviceColorTarget::from_stable_id(&arguments[4])
        .ok_or_else(|| format!("unknown Output Signal `{}`", arguments[4]))?;
    let alpha = arguments[5].as_str();
    if !matches!(alpha, "straight" | "premultiplied" | "ignore") {
        return Err(format!("unknown alpha interpretation `{alpha}`").into());
    }
    if package_path.exists() {
        return Err(format!("checkpoint already exists: {}", package_path.display()).into());
    }

    let decoded = image::open(&source_path)?.into_rgba8();
    let (width, height) = decoded.dimensions();
    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for pixel in decoded.pixels() {
        rgba.extend(pixel.0.map(|code| f32::from(code) / 255.0));
    }
    ColorEngine::bundled()?
        .source_to_device_processor(SourceColorInterpretation::Ocio(input), target)?
        .apply_rgba_buffer(&mut rgba)?;

    fs::create_dir(&package_path)?;
    let result = write_checkpoint(
        &package_path,
        &diagnostic_path,
        &rgba,
        CheckpointMetadata {
            schema: CHECKPOINT_SCHEMA,
            width,
            height,
            pixel_encoding: "rgba16Float-little-endian",
            input_transform_id: input.stable_id(),
            input_reference_domain: input.reference_domain().stable_id(),
            output_signal_id: target.stable_id(),
            feeder_output_transform_id: target.feeder_output_id(input.reference_domain()),
            alpha_interpretation: alpha,
        },
    );
    if let Err(error) = result {
        let _ = fs::remove_dir_all(&package_path);
        return Err(error);
    }
    let _ = read_checkpoint(&package_path)?;
    Ok(())
}

fn write_checkpoint(
    package_path: &PathBuf,
    diagnostic_path: &PathBuf,
    rgba: &[f32],
    metadata: CheckpointMetadata<'_>,
) -> Result<(), Box<dyn std::error::Error>> {
    let json = serde_json::to_vec_pretty(&metadata)?;
    fs::write(package_path.join("checkpoint.json"), json)?;
    let mut bytes = Vec::with_capacity(rgba.len() * 2);
    for value in rgba {
        bytes.extend_from_slice(&f16::from_f32(*value).to_bits().to_le_bytes());
    }
    fs::write(package_path.join("rgba16f.bin"), bytes)?;

    let diagnostic =
        ImageBuffer::<Rgba<u8>, Vec<u8>>::from_fn(metadata.width, metadata.height, |x, y| {
            let index = (y as usize * metadata.width as usize + x as usize) * 4;
            Rgba(std::array::from_fn(|channel| {
                (rgba[index + channel].clamp(0.0, 1.0) * 255.0).round() as u8
            }))
        });
    diagnostic.save(diagnostic_path)?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LoadedCheckpointMetadata {
    schema: String,
    width: u32,
    height: u32,
    pixel_encoding: String,
    #[serde(rename = "inputTransformID")]
    input_transform_id: String,
    input_reference_domain: String,
    #[serde(rename = "outputSignalID")]
    output_signal_id: String,
    #[serde(rename = "feederOutputTransformID")]
    feeder_output_transform_id: String,
    alpha_interpretation: String,
}

fn read_checkpoint(
    package_path: &PathBuf,
) -> Result<(LoadedCheckpointMetadata, Vec<f32>), Box<dyn std::error::Error>> {
    let mut entries = fs::read_dir(package_path)?
        .map(|entry| entry.map(|value| value.file_name()))
        .collect::<Result<Vec<_>, _>>()?;
    entries.sort();
    if entries.len() != 2 || entries[0] != "checkpoint.json" || entries[1] != "rgba16f.bin" {
        return Err("checkpoint package contains unknown or missing files".into());
    }
    let metadata: LoadedCheckpointMetadata =
        serde_json::from_slice(&fs::read(package_path.join("checkpoint.json"))?)?;
    if metadata.schema != CHECKPOINT_SCHEMA
        || metadata.pixel_encoding != "rgba16Float-little-endian"
        || OcioInputTransform::from_stable_id(&metadata.input_transform_id).is_none()
        || DeviceColorTarget::from_stable_id(&metadata.output_signal_id).is_none()
        || !matches!(
            metadata.alpha_interpretation.as_str(),
            "straight" | "premultiplied" | "ignore"
        )
    {
        return Err("checkpoint metadata is not current and complete".into());
    }
    let expected_output = DeviceColorTarget::from_stable_id(&metadata.output_signal_id)
        .expect("validated Output Signal")
        .feeder_output_id(
            OcioInputTransform::from_stable_id(&metadata.input_transform_id)
                .expect("validated Input Transform")
                .reference_domain(),
        );
    if metadata.input_reference_domain
        != OcioInputTransform::from_stable_id(&metadata.input_transform_id)
            .expect("validated Input Transform")
            .reference_domain()
            .stable_id()
        || metadata.feeder_output_transform_id != expected_output
    {
        return Err("checkpoint color identities contradict one another".into());
    }
    let bytes = fs::read(package_path.join("rgba16f.bin"))?;
    let expected_bytes = metadata.width as usize * metadata.height as usize * 4 * 2;
    if bytes.len() != expected_bytes {
        return Err("checkpoint raster length does not match metadata".into());
    }
    let values = bytes
        .chunks_exact(2)
        .map(|word| f16::from_bits(u16::from_le_bytes([word[0], word[1]])).to_f32())
        .collect();
    Ok((metadata, values))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_keys_match_the_swift_checkpoint_contract() {
        let metadata = CheckpointMetadata {
            schema: CHECKPOINT_SCHEMA,
            width: 2,
            height: 1,
            pixel_encoding: "rgba16Float-little-endian",
            input_transform_id: "srgb-encoded-rec709",
            input_reference_domain: "displayReferred",
            output_signal_id: "srgb",
            feeder_output_transform_id: "device-srgb-colorimetric",
            alpha_interpretation: "ignore",
        };
        let value = serde_json::to_value(metadata).expect("checkpoint metadata");
        assert_eq!(value["inputTransformID"], "srgb-encoded-rec709");
        assert_eq!(value["outputSignalID"], "srgb");
        assert_eq!(value["feederOutputTransformID"], "device-srgb-colorimetric");
        assert!(value.get("colorModeID").is_none());
    }

    #[test]
    fn reader_rejects_unknown_checkpoint_files() {
        let package = env::temp_dir().join(format!(
            "screen-simulation-checkpoint-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&package);
        fs::create_dir(&package).expect("temporary package");
        fs::write(package.join("unknown"), []).expect("unknown file");
        assert!(read_checkpoint(&package).is_err());
        fs::remove_dir_all(package).expect("temporary cleanup");
    }
}
