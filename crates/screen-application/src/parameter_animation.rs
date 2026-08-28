//! Application-owned exact-time animation for stable non-physical properties.

use screen_contracts::RationalTime;
use std::collections::HashSet;

pub const SIMULATION_OPACITY_PROPERTY_ID: &str = "simulation-opacity";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScalarInterpolation {
    Hold,
    Linear,
    Smooth,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScalarKeyframe {
    pub id: String,
    pub time: RationalTime,
    pub value: f64,
    pub interpolation: ScalarInterpolation,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScalarPropertyTrack {
    pub property_id: String,
    pub keyframes: Vec<ScalarKeyframe>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScalarPropertyDescriptor {
    pub stable_id: &'static str,
    pub display_name: &'static str,
    pub hold_label: &'static str,
    pub linear_label: &'static str,
    pub smooth_label: &'static str,
    pub minimum: f64,
    pub maximum: f64,
    pub default_value: f64,
    pub default_interpolation: ScalarInterpolation,
    pub supported_interpolation_mask: u32,
}

pub const SIMULATION_OPACITY_DESCRIPTOR: ScalarPropertyDescriptor = ScalarPropertyDescriptor {
    stable_id: SIMULATION_OPACITY_PROPERTY_ID,
    display_name: "Opacidad",
    hold_label: "Hold",
    linear_label: "Linear",
    smooth_label: "Ease",
    minimum: 0.0,
    maximum: 1.0,
    default_value: 1.0,
    default_interpolation: ScalarInterpolation::Smooth,
    supported_interpolation_mask: 0b111,
};

pub fn resolve_simulation_opacity_samples(
    keyframes: &[(RationalTime, f64, ScalarInterpolation)],
    time: RationalTime,
) -> Result<f64, ScalarTrackError> {
    if keyframes.is_empty() {
        return Err(ScalarTrackError::EmptyTrack);
    }
    for (index, (key_time, value, _)) in keyframes.iter().enumerate() {
        if !value.is_finite()
            || *value < SIMULATION_OPACITY_DESCRIPTOR.minimum
            || *value > SIMULATION_OPACITY_DESCRIPTOR.maximum
        {
            return Err(ScalarTrackError::InvalidValue);
        }
        if index > 0 && keyframes[index - 1].0 >= *key_time {
            return Err(ScalarTrackError::UnorderedKeyframes);
        }
    }
    if keyframes.len() == 1 {
        return Ok(keyframes[0].1);
    }
    if time < keyframes[0].0 {
        return Ok(extrapolate_terminal(keyframes[0], keyframes[1], time));
    }
    let last = keyframes.last().expect("validated non-empty samples");
    if time > last.0 {
        return Ok(extrapolate_terminal(
            *last,
            keyframes[keyframes.len() - 2],
            time,
        ));
    }
    if time == last.0 {
        return Ok(last.1);
    }
    let right_index = keyframes.partition_point(|key| key.0 <= time);
    let left = keyframes[right_index - 1];
    let right = keyframes[right_index];
    if left.2 == ScalarInterpolation::Hold {
        return Ok(left.1);
    }
    let left_seconds = left.0.as_seconds();
    let right_seconds = right.0.as_seconds();
    let mut amount = (time.as_seconds() - left_seconds) / (right_seconds - left_seconds);
    if left.2 == ScalarInterpolation::Smooth {
        amount = amount * amount * (3.0 - 2.0 * amount);
    }
    Ok(left.1 + (right.1 - left.1) * amount)
}

fn extrapolate_terminal(
    terminal: (RationalTime, f64, ScalarInterpolation),
    neighbor: (RationalTime, f64, ScalarInterpolation),
    time: RationalTime,
) -> f64 {
    if terminal.2 == ScalarInterpolation::Hold {
        return terminal.1;
    }
    let amount = (time.as_seconds() - terminal.0.as_seconds())
        / (neighbor.0.as_seconds() - terminal.0.as_seconds());
    terminal.1 + (neighbor.1 - terminal.1) * amount
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScalarTrackError {
    UnknownProperty,
    EmptyTrack,
    DuplicateKeyframeId,
    InvalidValue,
    UnorderedKeyframes,
}

impl ScalarPropertyTrack {
    pub fn validate(&self) -> Result<(), ScalarTrackError> {
        if self.property_id != SIMULATION_OPACITY_PROPERTY_ID {
            return Err(ScalarTrackError::UnknownProperty);
        }
        if self.keyframes.is_empty() {
            return Err(ScalarTrackError::EmptyTrack);
        }
        let mut ids = HashSet::with_capacity(self.keyframes.len());
        for (index, keyframe) in self.keyframes.iter().enumerate() {
            if keyframe.id.is_empty() || !ids.insert(keyframe.id.as_str()) {
                return Err(ScalarTrackError::DuplicateKeyframeId);
            }
            if !keyframe.value.is_finite()
                || keyframe.value < SIMULATION_OPACITY_DESCRIPTOR.minimum
                || keyframe.value > SIMULATION_OPACITY_DESCRIPTOR.maximum
            {
                return Err(ScalarTrackError::InvalidValue);
            }
            if index > 0 && self.keyframes[index - 1].time >= keyframe.time {
                return Err(ScalarTrackError::UnorderedKeyframes);
            }
        }
        Ok(())
    }

    pub fn sample(&self, time: RationalTime) -> Result<f64, ScalarTrackError> {
        self.validate()?;
        let samples = self
            .keyframes
            .iter()
            .map(|key| (key.time, key.value, key.interpolation))
            .collect::<Vec<_>>();
        resolve_simulation_opacity_samples(&samples, time)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(id: &str, frame: i64, value: f64, interpolation: ScalarInterpolation) -> ScalarKeyframe {
        ScalarKeyframe {
            id: id.into(),
            time: RationalTime::new(frame, 24).expect("valid time"),
            value,
            interpolation,
        }
    }

    #[test]
    fn opacity_samples_hold_linear_and_smooth_at_exact_rational_times() {
        for (interpolation, expected) in [
            (ScalarInterpolation::Hold, 0.0),
            (ScalarInterpolation::Linear, 0.25),
            (ScalarInterpolation::Smooth, 0.15625),
        ] {
            let track = ScalarPropertyTrack {
                property_id: SIMULATION_OPACITY_PROPERTY_ID.into(),
                keyframes: vec![
                    key("left", 0, 0.0, interpolation),
                    key("right", 24, 1.0, ScalarInterpolation::Hold),
                ],
            };
            assert_eq!(
                track.sample(RationalTime::new(6, 24).expect("valid time")),
                Ok(expected)
            );
        }
    }

    #[test]
    fn terminal_hold_is_constant_outside_the_authored_range() {
        let track = ScalarPropertyTrack {
            property_id: SIMULATION_OPACITY_PROPERTY_ID.into(),
            keyframes: vec![
                key("left", 10, 0.25, ScalarInterpolation::Hold),
                key("right", 20, 0.75, ScalarInterpolation::Hold),
            ],
        };
        assert_eq!(
            track.sample(RationalTime::new(-1, 24).expect("valid time")),
            Ok(0.25)
        );
        assert_eq!(
            track.sample(RationalTime::new(40, 24).expect("valid time")),
            Ok(0.75)
        );
    }

    #[test]
    fn continuous_terminals_extrapolate_the_terminal_chord_without_clamping() {
        let track = ScalarPropertyTrack {
            property_id: SIMULATION_OPACITY_PROPERTY_ID.into(),
            keyframes: vec![
                key("left", 10, 0.25, ScalarInterpolation::Linear),
                key("right", 20, 0.75, ScalarInterpolation::Linear),
            ],
        };
        assert_eq!(
            track.sample(RationalTime::new(5, 24).expect("valid time")),
            Ok(0.0)
        );
        assert_eq!(
            track.sample(RationalTime::new(25, 24).expect("valid time")),
            Ok(1.0)
        );
    }

    #[test]
    fn opacity_rejects_invalid_tracks_without_clamping_or_aliases() {
        let duplicate = ScalarPropertyTrack {
            property_id: SIMULATION_OPACITY_PROPERTY_ID.into(),
            keyframes: vec![
                key("same", 0, 0.0, ScalarInterpolation::Linear),
                key("same", 1, 1.0, ScalarInterpolation::Linear),
            ],
        };
        assert_eq!(
            duplicate.validate(),
            Err(ScalarTrackError::DuplicateKeyframeId)
        );
        let out_of_range = ScalarPropertyTrack {
            property_id: SIMULATION_OPACITY_PROPERTY_ID.into(),
            keyframes: vec![key("one", 0, 1.01, ScalarInterpolation::Hold)],
        };
        assert_eq!(out_of_range.validate(), Err(ScalarTrackError::InvalidValue));
    }
}
