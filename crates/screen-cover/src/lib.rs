//! Optical cover glass and incident-environment ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::LinearRgb;

/// Scene-linear ACEScg radiance owned by the incident environment boundary.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AcesCgRadiance(pub LinearRgb);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnvironmentPattern {
    UniformKey,
    ReflectionChart,
}

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
    pub ambient_radiance: AcesCgRadiance,
    pub key_radiance: AcesCgRadiance,
    pub key_direction_local: [f32; 3],
    pub key_angular_radius_degrees: f32,
    pub pattern: EnvironmentPattern,
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
            ambient_radiance: AcesCgRadiance(rgb(0.02)),
            key_radiance: AcesCgRadiance(rgb(0.0)),
            key_direction_local: [0.0, 0.0, 1.0],
            key_angular_radius_degrees: 20.0,
            pattern: EnvironmentPattern::UniformKey,
        },
    },
    EnvironmentPreset {
        id: "environment-neutral-office",
        label: "Neutral office",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(rgb(30.0)),
            key_radiance: AcesCgRadiance(rgb(220.0)),
            key_direction_local: [-0.45, 0.35, 0.821_584],
            key_angular_radius_degrees: 18.0,
            pattern: EnvironmentPattern::UniformKey,
        },
    },
    EnvironmentPreset {
        id: "environment-bright-window",
        label: "Bright window",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(LinearRgb::new(65.0, 70.0, 78.0)),
            key_radiance: AcesCgRadiance(LinearRgb::new(1_250.0, 1_330.0, 1_500.0)),
            key_direction_local: [0.52, 0.18, 0.834_985],
            key_angular_radius_degrees: 13.0,
            pattern: EnvironmentPattern::UniformKey,
        },
    },
    EnvironmentPreset {
        id: "environment-reflection-chart",
        label: "Reflection chart",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(rgb(4.0)),
            key_radiance: AcesCgRadiance(rgb(500.0)),
            key_direction_local: [-0.25, 0.22, 0.942_921],
            key_angular_radius_degrees: 10.0,
            pattern: EnvironmentPattern::ReflectionChart,
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
            self.ambient_radiance.0.r,
            self.ambient_radiance.0.g,
            self.ambient_radiance.0.b,
            self.key_radiance.0.r,
            self.key_radiance.0.g,
            self.key_radiance.0.b,
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
        let transmission = self.transmission(sample.view_cosine);
        let reflected = self.reflected_illuminance(sample);
        LinearRgb::new(
            emitted_illuminance.r * transmission.r + reflected.r,
            emitted_illuminance.g * transmission.g + reflected.g,
            emitted_illuminance.b * transmission.b + reflected.b,
        )
    }

    pub fn transmission(self, view_cosine: f32) -> LinearRgb {
        let (reflection, transmitted_cosine) = self.interface(view_cosine);
        let absorption_scale = self.cover.thickness_millimeters / transmitted_cosine.max(0.01)
            * self.cover.character_strength;
        let haze_loss = (self.cover.haze * self.cover.character_strength).clamp(0.0, 0.95);
        LinearRgb::new(
            (1.0 - reflection)
                * (-self.cover.absorption_per_millimeter.r * absorption_scale).exp()
                * (1.0 - haze_loss),
            (1.0 - reflection)
                * (-self.cover.absorption_per_millimeter.g * absorption_scale).exp()
                * (1.0 - haze_loss),
            (1.0 - reflection)
                * (-self.cover.absorption_per_millimeter.b * absorption_scale).exp()
                * (1.0 - haze_loss),
        )
    }

    /// Returns the lateral displacement, in panel-local meters, introduced by a parallel
    /// cover slab. `surface_direction_local` points along the reflected surface ray; its
    /// tangential components are therefore also the incident ray's tangential components.
    /// Zero character strength and an air-equivalent interface are exact identities.
    pub fn transmitted_lateral_offset_meters(self, surface_direction_local: [f32; 3]) -> [f32; 2] {
        if self.cover.character_strength == 0.0 || self.cover.refractive_index == 1.0 {
            return [0.0, 0.0];
        }
        let direction = normalize(surface_direction_local);
        let cosine_i = direction[2].abs().max(1.0e-4);
        let eta = self.cover.refractive_index;
        let sine_t_squared = (1.0 - cosine_i * cosine_i) / (eta * eta);
        let cosine_t = (1.0 - sine_t_squared).max(0.0).sqrt().max(1.0e-4);
        let thickness_meters =
            self.cover.thickness_millimeters * 0.001 * self.cover.character_strength;
        let tangent_scale = thickness_meters * (1.0 / (eta * cosine_t) - 1.0 / cosine_i);
        [direction[0] * tangent_scale, direction[1] * tangent_scale]
    }

    pub fn reflected_illuminance(self, sample: CoverSurfaceSample) -> LinearRgb {
        let (reflection, _) = self.interface(sample.view_cosine);
        let environment = self.environment_radiance(sample.reflection_direction_local);
        LinearRgb::new(
            environment.r * reflection * sample.lens_irradiance_weight.r,
            environment.g * reflection * sample.lens_irradiance_weight.g,
            environment.b * reflection * sample.lens_irradiance_weight.b,
        )
    }

    fn interface(self, view_cosine: f32) -> (f32, f32) {
        let cosine_i = view_cosine.clamp(0.0, 1.0);
        let eta = self.cover.refractive_index;
        let sine_t_squared = (1.0 - cosine_i * cosine_i) / (eta * eta);
        let cosine_t = (1.0 - sine_t_squared).max(0.0).sqrt();
        if eta == 1.0 || self.cover.anti_reflective_efficiency == 1.0 {
            return (0.0, cosine_t);
        }
        let rs = (cosine_i - eta * cosine_t) / (cosine_i + eta * cosine_t).max(1.0e-8);
        let rp = (eta * cosine_i - cosine_t) / (eta * cosine_i + cosine_t).max(1.0e-8);
        let bare = 0.5 * (rs * rs + rp * rp);
        let authored =
            bare * (1.0 - self.cover.anti_reflective_efficiency) * self.cover.character_strength;
        (authored.clamp(0.0, 0.98), cosine_t)
    }

    fn environment_radiance(self, direction: [f32; 3]) -> LinearRgb {
        let direction = normalize(direction);
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
        let pattern_amount = if self.environment.pattern == EnvironmentPattern::ReflectionChart {
            let u = direction[0] * 0.5 + 0.5;
            let v = direction[1] * 0.5 + 0.5;
            let border = if (u - 0.5).abs() < 0.42 && (v - 0.5).abs() < 0.34 {
                1.0
            } else {
                0.04
            };
            let cells = (((u * 8.0).floor() as i32 + (v * 6.0).floor() as i32) & 1) as f32;
            border * (0.08 + 0.92 * cells)
        } else {
            key_amount
        };
        let strength = self.environment.character_strength;
        // Roughness and haze redistribute the authored key lobe toward its mean instead of
        // inventing radiance. This keeps the procedural approximation energy bounded.
        let redistribution = (self.cover.roughness * 0.75 + self.cover.haze * 0.25).clamp(0.0, 1.0);
        let pattern_amount = pattern_amount * (1.0 - redistribution) + 0.5 * redistribution;
        LinearRgb::new(
            (self.environment.ambient_radiance.0.r
                + self.environment.key_radiance.0.r * pattern_amount)
                * strength,
            (self.environment.ambient_radiance.0.g
                + self.environment.key_radiance.0.g * pattern_amount)
                * strength,
            (self.environment.ambient_radiance.0.b
                + self.environment.key_radiance.0.b * pattern_amount)
                * strength,
        )
    }
}

fn normalize(value: [f32; 3]) -> [f32; 3] {
    let length = (value[0] * value[0] + value[1] * value[1] + value[2] * value[2])
        .sqrt()
        .max(1.0e-8);
    [value[0] / length, value[1] / length, value[2] / length]
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

    #[test]
    fn physically_zero_interfaces_do_not_reflect_at_extreme_angles() {
        let environment = ENVIRONMENT_PRESETS[2].environment;
        let base = CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 1.0,
            refractive_index: 1.0,
            anti_reflective_efficiency: 0.0,
            absorption_per_millimeter: rgb(0.0),
            roughness: 0.0,
            haze: 0.0,
        };
        let no_interface = base.evaluator(environment).expect("valid interface");
        assert_eq!(no_interface.evaluate(rgb(0.0), sample(0.01)), rgb(0.0));
        let perfect_ar = CoverGlassProfile {
            refractive_index: 1.8,
            anti_reflective_efficiency: 1.0,
            ..base
        }
        .evaluator(environment)
        .expect("valid perfect AR");
        assert_eq!(perfect_ar.evaluate(rgb(0.0), sample(0.01)), rgb(0.0));
    }

    #[test]
    fn reflection_chart_is_spatially_structured_and_roughness_reduces_contrast() {
        let environment = ENVIRONMENT_PRESETS[3].environment;
        let glossy = COVER_GLASS_PRESETS[1]
            .profile
            .evaluator(environment)
            .expect("valid glossy chart");
        let mut dark = sample(1.0);
        dark.reflection_direction_local = [-0.95, -0.95, 0.2];
        let mut bright = sample(1.0);
        bright.reflection_direction_local = [-0.1, -0.1, 0.99];
        let glossy_contrast =
            (glossy.evaluate(rgb(0.0), bright).r - glossy.evaluate(rgb(0.0), dark).r).abs();
        assert!(glossy_contrast > 0.01);

        let rough = CoverGlassProfile {
            roughness: 1.0,
            ..COVER_GLASS_PRESETS[1].profile
        }
        .evaluator(environment)
        .expect("valid rough chart");
        let rough_contrast =
            (rough.evaluate(rgb(0.0), bright).r - rough.evaluate(rgb(0.0), dark).r).abs();
        assert!(rough_contrast < glossy_contrast);
    }

    #[test]
    fn thick_cover_refracts_emission_toward_the_surface_normal() {
        let cover = COVER_GLASS_PRESETS[5]
            .profile
            .evaluator(ProceduralEnvironment::DARK)
            .expect("valid thick cover");
        let offset = cover.transmitted_lateral_offset_meters([0.6, 0.0, 0.8]);
        assert!(offset[0] < -0.001);
        assert_eq!(offset[1], 0.0);

        let neutral = CoverGlassProfile::NEUTRAL
            .evaluator(ProceduralEnvironment::DARK)
            .expect("valid neutral cover");
        assert_eq!(
            neutral.transmitted_lateral_offset_meters([0.6, 0.0, 0.8]),
            [0.0, 0.0]
        );
    }
}
