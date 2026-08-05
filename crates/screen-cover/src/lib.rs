//! Optical cover glass and incident-environment ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::LinearRgb;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CoverGlassProfile {
    /// Neutral-to-authored interpolation. Zero is an ideal absent cover, one is the preset.
    pub character_strength: f32,
    pub thickness_millimeters: f32,
    pub refractive_index: f32,
    pub anti_reflective_efficiency: f32,
    pub absorption_per_millimeter: LinearRgb,
    pub roughness: f32,
    pub haze: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CoverGlassPresetAuthority {
    GenericApproximation,
    PublishedCategoryApproximation,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CoverGlassPreset {
    pub id: &'static str,
    pub label: &'static str,
    pub authority: CoverGlassPresetAuthority,
    pub profile: CoverGlassProfile,
}

const fn rgb(value: f32) -> LinearRgb {
    LinearRgb::new(value, value, value)
}

pub const COVER_GLASS_PRESETS: &[CoverGlassPreset] = &[
    CoverGlassPreset {
        id: "cover-glossy-strong-ar",
        label: "Glossy · strong AR",
        authority: CoverGlassPresetAuthority::GenericApproximation,
        profile: CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 0.75,
            refractive_index: 1.52,
            anti_reflective_efficiency: 0.85,
            absorption_per_millimeter: rgb(0.006),
            roughness: 0.025,
            haze: 0.002,
        },
    },
    CoverGlassPreset {
        id: "cover-glossy-standard-ar",
        label: "Glossy · standard AR",
        authority: CoverGlassPresetAuthority::GenericApproximation,
        profile: CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 1.2,
            refractive_index: 1.52,
            anti_reflective_efficiency: 0.58,
            absorption_per_millimeter: rgb(0.008),
            roughness: 0.045,
            haze: 0.004,
        },
    },
    CoverGlassPreset {
        id: "cover-semi-gloss",
        label: "Semi-gloss",
        authority: CoverGlassPresetAuthority::GenericApproximation,
        profile: CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 1.0,
            refractive_index: 1.50,
            anti_reflective_efficiency: 0.45,
            absorption_per_millimeter: rgb(0.010),
            roughness: 0.20,
            haze: 0.012,
        },
    },
    CoverGlassPreset {
        id: "cover-matte-ar",
        label: "Matte anti-glare",
        authority: CoverGlassPresetAuthority::PublishedCategoryApproximation,
        profile: CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 0.8,
            refractive_index: 1.50,
            anti_reflective_efficiency: 0.62,
            absorption_per_millimeter: rgb(0.012),
            roughness: 0.46,
            haze: 0.030,
        },
    },
    CoverGlassPreset {
        id: "cover-heavy-matte",
        label: "Heavy matte",
        authority: CoverGlassPresetAuthority::GenericApproximation,
        profile: CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 1.0,
            refractive_index: 1.50,
            anti_reflective_efficiency: 0.40,
            absorption_per_millimeter: rgb(0.018),
            roughness: 0.72,
            haze: 0.075,
        },
    },
    CoverGlassPreset {
        id: "cover-thick-crt",
        label: "Thick glossy glass",
        authority: CoverGlassPresetAuthority::GenericApproximation,
        profile: CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 5.0,
            refractive_index: 1.54,
            anti_reflective_efficiency: 0.05,
            absorption_per_millimeter: LinearRgb::new(0.010, 0.008, 0.006),
            roughness: 0.035,
            haze: 0.010,
        },
    },
];

pub fn cover_glass_preset(id: &str) -> Option<CoverGlassPreset> {
    COVER_GLASS_PRESETS
        .iter()
        .copied()
        .find(|preset| preset.id == id)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProceduralEnvironment {
    /// Neutral-to-authored interpolation. Zero emits no incident environment radiance.
    pub character_strength: f32,
    pub ambient_radiance: LinearRgb,
    pub key_radiance: LinearRgb,
    pub key_direction_local: [f32; 3],
    pub key_angular_radius_degrees: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EnvironmentPreset {
    pub id: &'static str,
    pub label: &'static str,
    pub environment: ProceduralEnvironment,
}

pub const ENVIRONMENT_PRESETS: &[EnvironmentPreset] = &[
    EnvironmentPreset {
        id: "environment-dark-studio",
        label: "Dark studio",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: rgb(0.02),
            key_radiance: rgb(0.0),
            key_direction_local: [0.0, 0.0, 1.0],
            key_angular_radius_degrees: 20.0,
        },
    },
    EnvironmentPreset {
        id: "environment-neutral-office",
        label: "Neutral office",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: rgb(30.0),
            key_radiance: rgb(220.0),
            key_direction_local: [-0.45, 0.35, 0.821_584],
            key_angular_radius_degrees: 18.0,
        },
    },
    EnvironmentPreset {
        id: "environment-bright-window",
        label: "Bright window",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: LinearRgb::new(65.0, 70.0, 78.0),
            key_radiance: LinearRgb::new(1_250.0, 1_330.0, 1_500.0),
            key_direction_local: [0.52, 0.18, 0.834_985],
            key_angular_radius_degrees: 13.0,
        },
    },
    EnvironmentPreset {
        id: "environment-reflection-chart",
        label: "Reflection chart",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: rgb(4.0),
            key_radiance: rgb(500.0),
            key_direction_local: [-0.25, 0.22, 0.942_921],
            key_angular_radius_degrees: 10.0,
        },
    },
];

pub fn environment_preset(id: &str) -> Option<EnvironmentPreset> {
    ENVIRONMENT_PRESETS
        .iter()
        .copied()
        .find(|preset| preset.id == id)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CoverSurfaceSample {
    pub view_cosine: f32,
    pub reflection_direction_local: [f32; 3],
    /// Lens conversion from incident radiance to sensor-plane illuminance.
    pub lens_irradiance_weight: LinearRgb,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ValidatedCoverEvaluator {
    cover: CoverGlassProfile,
    environment: ProceduralEnvironment,
}

impl CoverGlassProfile {
    pub const NEUTRAL: Self = Self {
        character_strength: 0.0,
        thickness_millimeters: 1.0,
        refractive_index: 1.5,
        anti_reflective_efficiency: 0.0,
        absorption_per_millimeter: LinearRgb::new(0.0, 0.0, 0.0),
        roughness: 0.0,
        haze: 0.0,
    };

    pub fn validate(self) -> Result<Self, CoverError> {
        if !self.character_strength.is_finite() || !(0.0..=2.0).contains(&self.character_strength) {
            return Err(CoverError::InvalidCharacterStrength);
        }
        if !self.thickness_millimeters.is_finite()
            || !(0.01..=20.0).contains(&self.thickness_millimeters)
        {
            return Err(CoverError::InvalidThickness);
        }
        if !self.refractive_index.is_finite() || !(1.0..=2.5).contains(&self.refractive_index) {
            return Err(CoverError::InvalidRefractiveIndex);
        }
        if !self.anti_reflective_efficiency.is_finite()
            || !(0.0..=1.0).contains(&self.anti_reflective_efficiency)
        {
            return Err(CoverError::InvalidCoating);
        }
        if [
            self.absorption_per_millimeter.r,
            self.absorption_per_millimeter.g,
            self.absorption_per_millimeter.b,
        ]
        .into_iter()
        .any(|value| !value.is_finite() || !(0.0..=2.0).contains(&value))
        {
            return Err(CoverError::InvalidAbsorption);
        }
        if !self.roughness.is_finite()
            || !(0.0..=1.0).contains(&self.roughness)
            || !self.haze.is_finite()
            || !(0.0..=1.0).contains(&self.haze)
        {
            return Err(CoverError::InvalidSurface);
        }
        Ok(self)
    }

    pub fn evaluator(
        self,
        environment: ProceduralEnvironment,
    ) -> Result<ValidatedCoverEvaluator, CoverError> {
        Ok(ValidatedCoverEvaluator {
            cover: self.validate()?,
            environment: environment.validate()?,
        })
    }
}

impl ProceduralEnvironment {
    pub const DARK: Self = ENVIRONMENT_PRESETS[0].environment;

    pub fn validate(self) -> Result<Self, CoverError> {
        if !self.character_strength.is_finite() || !(0.0..=4.0).contains(&self.character_strength) {
            return Err(CoverError::InvalidEnvironmentStrength);
        }
        if [
            self.ambient_radiance.r,
            self.ambient_radiance.g,
            self.ambient_radiance.b,
            self.key_radiance.r,
            self.key_radiance.g,
            self.key_radiance.b,
        ]
        .into_iter()
        .any(|value| !value.is_finite() || !(0.0..=100_000.0).contains(&value))
        {
            return Err(CoverError::InvalidEnvironmentRadiance);
        }
        let length_squared = self
            .key_direction_local
            .into_iter()
            .map(|value| value * value)
            .sum::<f32>();
        if self
            .key_direction_local
            .into_iter()
            .any(|value| !value.is_finite())
            || (length_squared - 1.0).abs() > 1.0e-3
            || self.key_direction_local[2] < 0.0
        {
            return Err(CoverError::InvalidEnvironmentDirection);
        }
        if !self.key_angular_radius_degrees.is_finite()
            || !(0.1..=89.0).contains(&self.key_angular_radius_degrees)
        {
            return Err(CoverError::InvalidEnvironmentSourceSize);
        }
        Ok(self)
    }
}

impl ValidatedCoverEvaluator {
    pub fn evaluate(self, emitted_illuminance: LinearRgb, sample: CoverSurfaceSample) -> LinearRgb {
        let cosine = sample.view_cosine.clamp(0.0, 1.0);
        let bare_f0 =
            ((self.cover.refractive_index - 1.0) / (self.cover.refractive_index + 1.0)).powi(2);
        let coated_f0 = bare_f0 * (1.0 - self.cover.anti_reflective_efficiency);
        let authored_fresnel = coated_f0 + (1.0 - coated_f0) * (1.0 - cosine).powi(5);
        let reflection = (authored_fresnel * self.cover.character_strength).clamp(0.0, 0.98);
        let path_scale = 1.0 / cosine.max(0.05);
        let absorption_scale =
            self.cover.thickness_millimeters * path_scale * self.cover.character_strength;
        let haze_loss = (self.cover.haze * self.cover.character_strength).clamp(0.0, 0.95);
        let transmission = LinearRgb::new(
            (1.0 - reflection)
                * (-self.cover.absorption_per_millimeter.r * absorption_scale).exp()
                * (1.0 - haze_loss),
            (1.0 - reflection)
                * (-self.cover.absorption_per_millimeter.g * absorption_scale).exp()
                * (1.0 - haze_loss),
            (1.0 - reflection)
                * (-self.cover.absorption_per_millimeter.b * absorption_scale).exp()
                * (1.0 - haze_loss),
        );
        let environment = self.environment_radiance(sample.reflection_direction_local);
        LinearRgb::new(
            emitted_illuminance.r * transmission.r
                + environment.r * reflection * sample.lens_irradiance_weight.r,
            emitted_illuminance.g * transmission.g
                + environment.g * reflection * sample.lens_irradiance_weight.g,
            emitted_illuminance.b * transmission.b
                + environment.b * reflection * sample.lens_irradiance_weight.b,
        )
    }

    fn environment_radiance(self, direction: [f32; 3]) -> LinearRgb {
        let alignment = direction
            .into_iter()
            .zip(self.environment.key_direction_local)
            .map(|(left, right)| left * right)
            .sum::<f32>()
            .clamp(-1.0, 1.0);
        let radius = self.environment.key_angular_radius_degrees.to_radians();
        let edge = radius.cos();
        let softness = 0.005 + self.cover.roughness * 0.35;
        let key_amount = smoothstep(edge - softness, edge + softness, alignment);
        let strength = self.environment.character_strength;
        let haze_veil = self.cover.haze * (0.15 + 0.35 * self.cover.roughness);
        LinearRgb::new(
            (self.environment.ambient_radiance.r
                + self.environment.key_radiance.r * key_amount
                + self.environment.key_radiance.r * haze_veil)
                * strength,
            (self.environment.ambient_radiance.g
                + self.environment.key_radiance.g * key_amount
                + self.environment.key_radiance.g * haze_veil)
                * strength,
            (self.environment.ambient_radiance.b
                + self.environment.key_radiance.b * key_amount
                + self.environment.key_radiance.b * haze_veil)
                * strength,
        )
    }
}

fn smoothstep(first: f32, second: f32, value: f32) -> f32 {
    let amount = ((value - first) / (second - first)).clamp(0.0, 1.0);
    amount * amount * (3.0 - 2.0 * amount)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CoverError {
    InvalidCharacterStrength,
    InvalidThickness,
    InvalidRefractiveIndex,
    InvalidCoating,
    InvalidAbsorption,
    InvalidSurface,
    InvalidEnvironmentStrength,
    InvalidEnvironmentRadiance,
    InvalidEnvironmentDirection,
    InvalidEnvironmentSourceSize,
}

impl fmt::Display for CoverError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidCharacterStrength => "cover character strength must be finite in [0, 2]",
            Self::InvalidThickness => "cover thickness must be finite in [0.01, 20] mm",
            Self::InvalidRefractiveIndex => "cover refractive index must be finite in [1, 2.5]",
            Self::InvalidCoating => "cover coating efficiency must be finite in [0, 1]",
            Self::InvalidAbsorption => "cover absorption must be finite in [0, 2] per millimeter",
            Self::InvalidSurface => "cover roughness and haze must be finite in [0, 1]",
            Self::InvalidEnvironmentStrength => "environment strength must be finite in [0, 4]",
            Self::InvalidEnvironmentRadiance => {
                "environment radiance must be finite and non-negative"
            }
            Self::InvalidEnvironmentDirection => {
                "environment key direction must be normalized on the front hemisphere"
            }
            Self::InvalidEnvironmentSourceSize => {
                "environment key angular radius must be finite in [0.1, 89] degrees"
            }
        })
    }
}

impl std::error::Error for CoverError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn sample(cosine: f32) -> CoverSurfaceSample {
        CoverSurfaceSample {
            view_cosine: cosine,
            reflection_direction_local: [0.0, 0.0, 1.0],
            lens_irradiance_weight: rgb(1.0),
        }
    }

    #[test]
    fn catalogs_have_unique_valid_stable_ids() {
        let mut ids = HashSet::new();
        for preset in COVER_GLASS_PRESETS {
            assert!(ids.insert(preset.id));
            assert_eq!(cover_glass_preset(preset.id), Some(*preset));
            preset.profile.validate().expect("valid cover preset");
        }
        for preset in ENVIRONMENT_PRESETS {
            assert!(ids.insert(preset.id));
            assert_eq!(environment_preset(preset.id), Some(*preset));
            preset
                .environment
                .validate()
                .expect("valid environment preset");
        }
    }

    #[test]
    fn zero_character_strength_is_exactly_neutral() {
        let cover = CoverGlassProfile::NEUTRAL
            .evaluator(ENVIRONMENT_PRESETS[2].environment)
            .expect("valid evaluator");
        let emitted = LinearRgb::new(12.0, 8.0, 4.0);
        assert_eq!(cover.evaluate(emitted, sample(0.5)), emitted);
    }

    #[test]
    fn fresnel_reflection_grows_at_grazing_angles() {
        let cover = COVER_GLASS_PRESETS[1]
            .profile
            .evaluator(ENVIRONMENT_PRESETS[1].environment)
            .expect("valid evaluator");
        let black = LinearRgb::new(0.0, 0.0, 0.0);
        let frontal = cover.evaluate(black, sample(1.0));
        let grazing = cover.evaluate(black, sample(0.2));
        assert!(grazing.r > frontal.r);
        assert!(grazing.g > frontal.g);
        assert!(grazing.b > frontal.b);
    }

    #[test]
    fn environment_zero_removes_reflection_without_changing_cover_transmission() {
        let mut environment = ENVIRONMENT_PRESETS[2].environment;
        environment.character_strength = 0.0;
        let cover = COVER_GLASS_PRESETS[0]
            .profile
            .evaluator(environment)
            .expect("valid evaluator");
        let emitted = rgb(100.0);
        let result = cover.evaluate(emitted, sample(1.0));
        assert!(result.r < emitted.r);
        assert_eq!(result.r, result.g);
        assert_eq!(result.g, result.b);
    }
}
