//! Optical cover glass and incident-environment ownership.

#![forbid(unsafe_code)]

use core::fmt;
use screen_contracts::LinearRgb;

/// Scene-linear ACEScg radiance owned by the incident environment boundary.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AcesCgRadiance(pub LinearRgb);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnvironmentPattern {
    UniformNeutral,
    StudioSoftboxes,
    CalibrationGrid,
    OfficeCeiling,
    DaylightWindow,
    WarmPracticals,
    MixedProduction,
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
    pub glow: CoverGlowProfile,
}

/// Energy-redistributing lateral scatter inside the cover stack. Radii are
/// measured on the physical panel surface rather than in preview pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CoverGlowProfile {
    /// Zero is exact identity, one is calibrated and values above one
    /// extrapolate the redistributed fraction without changing its radii.
    pub character_strength: f32,
    pub scatter_fraction: f32,
    pub core_radius_millimeters: f32,
    pub tail_radius_millimeters: f32,
    pub tail_fraction: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CoverGlowSample {
    pub offset_meters: [f32; 2],
    pub weight: f32,
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
            glow: CoverGlowProfile::GLOSSY_STRONG_AR,
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
            glow: CoverGlowProfile::GLOSSY_STANDARD_AR,
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
            glow: CoverGlowProfile::SEMI_GLOSS,
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
            roughness: 0.65,
            haze: 0.030,
            glow: CoverGlowProfile::MATTE_AR,
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
            glow: CoverGlowProfile::HEAVY_MATTE,
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
            glow: CoverGlowProfile::THICK_GLASS,
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
    /// Horizontal rotation of the complete synthetic latitude-longitude environment around panel-local Y.
    pub rotation_degrees: f32,
    pub pattern: EnvironmentPattern,
}

/// Parameters for an equirectangular incident-radiance map that has already
/// been decoded and transformed to scene-linear ACEScg by the owning adapters.
/// The map pixels remain dimensionless source units until the explicit
/// radiometric scale is applied at this boundary.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EquirectangularEnvironment {
    /// Zero emits no incident environment radiance, one is the authored calibration.
    pub character_strength: f32,
    /// Physical radiance represented by one linear map unit, in cd/m².
    pub source_unit_radiance_candelas_per_square_meter: f32,
    /// Photometric adjustment applied before reflection, in stops.
    pub exposure_stops: f32,
    /// Horizontal rotation of the latitude-longitude map around panel-local Y.
    pub rotation_degrees: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum IncidentEnvironment {
    Procedural(ProceduralEnvironment),
    Equirectangular(EquirectangularEnvironment),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EnvironmentPreset {
    pub id: &'static str,
    pub label: &'static str,
    pub environment: ProceduralEnvironment,
}

pub const ENVIRONMENT_PRESETS: &[EnvironmentPreset] = &[
    EnvironmentPreset {
        id: "environment-none",
        label: "Sin entorno",
        environment: ProceduralEnvironment::NONE,
    },
    EnvironmentPreset {
        id: "environment-uniform-neutral",
        label: "HDR · uniform neutral",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(rgb(50.0)),
            key_radiance: AcesCgRadiance(rgb(0.0)),
            key_direction_local: [0.0, 0.0, 1.0],
            key_angular_radius_degrees: 20.0,
            rotation_degrees: 0.0,
            pattern: EnvironmentPattern::UniformNeutral,
        },
    },
    EnvironmentPreset {
        id: "environment-studio-softboxes",
        label: "HDR · studio softboxes",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(LinearRgb::new(4.0, 4.2, 4.5)),
            key_radiance: AcesCgRadiance(LinearRgb::new(900.0, 940.0, 1_000.0)),
            key_direction_local: [-0.45, 0.35, 0.821_584],
            key_angular_radius_degrees: 24.0,
            rotation_degrees: 0.0,
            pattern: EnvironmentPattern::StudioSoftboxes,
        },
    },
    EnvironmentPreset {
        id: "environment-calibration-grid",
        label: "HDR · calibration grid",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(rgb(1.0)),
            key_radiance: AcesCgRadiance(rgb(1_000.0)),
            key_direction_local: [0.0, 0.0, 1.0],
            key_angular_radius_degrees: 10.0,
            rotation_degrees: 0.0,
            pattern: EnvironmentPattern::CalibrationGrid,
        },
    },
    EnvironmentPreset {
        id: "environment-office-ceiling",
        label: "HDR · office ceiling",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(LinearRgb::new(7.0, 8.0, 9.5)),
            key_radiance: AcesCgRadiance(LinearRgb::new(420.0, 455.0, 500.0)),
            key_direction_local: [0.0, 0.8, 0.6],
            key_angular_radius_degrees: 16.0,
            rotation_degrees: 0.0,
            pattern: EnvironmentPattern::OfficeCeiling,
        },
    },
    EnvironmentPreset {
        id: "environment-daylight-window",
        label: "HDR · daylight window",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(LinearRgb::new(18.0, 22.0, 30.0)),
            key_radiance: AcesCgRadiance(LinearRgb::new(2_800.0, 3_250.0, 4_000.0)),
            key_direction_local: [-0.58, 0.12, 0.805_977],
            key_angular_radius_degrees: 24.0,
            rotation_degrees: 0.0,
            pattern: EnvironmentPattern::DaylightWindow,
        },
    },
    EnvironmentPreset {
        id: "environment-warm-practicals",
        label: "HDR · warm practicals",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(LinearRgb::new(0.55, 0.75, 1.35)),
            key_radiance: AcesCgRadiance(LinearRgb::new(780.0, 315.0, 92.0)),
            key_direction_local: [0.52, -0.18, 0.834_985],
            key_angular_radius_degrees: 7.0,
            rotation_degrees: 0.0,
            pattern: EnvironmentPattern::WarmPracticals,
        },
    },
    EnvironmentPreset {
        id: "environment-mixed-production",
        label: "HDR · mixed production set",
        environment: ProceduralEnvironment {
            character_strength: 1.0,
            ambient_radiance: AcesCgRadiance(LinearRgb::new(2.0, 3.5, 7.0)),
            key_radiance: AcesCgRadiance(LinearRgb::new(1_150.0, 560.0, 210.0)),
            key_direction_local: [0.56, -0.08, 0.824_621],
            key_angular_radius_degrees: 10.0,
            rotation_degrees: 0.0,
            pattern: EnvironmentPattern::MixedProduction,
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
        glow: CoverGlowProfile::NEUTRAL,
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
        self.glow.validate()?;
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

impl CoverGlowProfile {
    pub const NEUTRAL: Self = Self {
        character_strength: 0.0,
        scatter_fraction: 0.0,
        core_radius_millimeters: 0.1,
        tail_radius_millimeters: 1.0,
        tail_fraction: 0.5,
    };
    pub const GLOSSY_STRONG_AR: Self = Self {
        character_strength: 1.0,
        scatter_fraction: 0.018,
        core_radius_millimeters: 0.12,
        tail_radius_millimeters: 1.2,
        tail_fraction: 0.35,
    };
    pub const GLOSSY_STANDARD_AR: Self = Self {
        character_strength: 1.0,
        scatter_fraction: 0.030,
        core_radius_millimeters: 0.18,
        tail_radius_millimeters: 1.8,
        tail_fraction: 0.40,
    };
    pub const SEMI_GLOSS: Self = Self {
        character_strength: 1.0,
        scatter_fraction: 0.060,
        core_radius_millimeters: 0.28,
        tail_radius_millimeters: 2.5,
        tail_fraction: 0.45,
    };
    pub const MATTE_AR: Self = Self {
        character_strength: 1.0,
        scatter_fraction: 0.10,
        core_radius_millimeters: 0.42,
        tail_radius_millimeters: 3.5,
        tail_fraction: 0.50,
    };
    pub const HEAVY_MATTE: Self = Self {
        character_strength: 1.0,
        scatter_fraction: 0.16,
        core_radius_millimeters: 0.65,
        tail_radius_millimeters: 5.0,
        tail_fraction: 0.55,
    };
    pub const THICK_GLASS: Self = Self {
        character_strength: 1.0,
        scatter_fraction: 0.035,
        core_radius_millimeters: 0.80,
        tail_radius_millimeters: 8.0,
        tail_fraction: 0.65,
    };

    pub fn validate(self) -> Result<Self, CoverError> {
        if !self.character_strength.is_finite()
            || !(0.0..=4.0).contains(&self.character_strength)
            || !self.scatter_fraction.is_finite()
            || !(0.0..=0.35).contains(&self.scatter_fraction)
            || !self.core_radius_millimeters.is_finite()
            || !(0.01..=5.0).contains(&self.core_radius_millimeters)
            || !self.tail_radius_millimeters.is_finite()
            || self.tail_radius_millimeters < self.core_radius_millimeters
            || self.tail_radius_millimeters > 30.0
            || !self.tail_fraction.is_finite()
            || !(0.0..=1.0).contains(&self.tail_fraction)
            || self.scatter_fraction * self.character_strength > 0.95
        {
            return Err(CoverError::InvalidGlow);
        }
        Ok(self)
    }

    pub fn samples(self) -> Result<[CoverGlowSample; 9], CoverError> {
        let profile = self.validate()?;
        let scattered = profile.scatter_fraction * profile.character_strength;
        let core_weight = scattered * (1.0 - profile.tail_fraction) * 0.25;
        let tail_weight = scattered * profile.tail_fraction * 0.25;
        let core = profile.core_radius_millimeters * 0.001;
        let tail = profile.tail_radius_millimeters * 0.001 * core::f32::consts::FRAC_1_SQRT_2;
        Ok([
            CoverGlowSample {
                offset_meters: [0.0, 0.0],
                weight: 1.0 - scattered,
            },
            CoverGlowSample {
                offset_meters: [core, 0.0],
                weight: core_weight,
            },
            CoverGlowSample {
                offset_meters: [-core, 0.0],
                weight: core_weight,
            },
            CoverGlowSample {
                offset_meters: [0.0, core],
                weight: core_weight,
            },
            CoverGlowSample {
                offset_meters: [0.0, -core],
                weight: core_weight,
            },
            CoverGlowSample {
                offset_meters: [tail, tail],
                weight: tail_weight,
            },
            CoverGlowSample {
                offset_meters: [-tail, tail],
                weight: tail_weight,
            },
            CoverGlowSample {
                offset_meters: [tail, -tail],
                weight: tail_weight,
            },
            CoverGlowSample {
                offset_meters: [-tail, -tail],
                weight: tail_weight,
            },
        ])
    }
}

impl ProceduralEnvironment {
    pub const NONE: Self = Self {
        character_strength: 0.0,
        ambient_radiance: AcesCgRadiance(rgb(0.0)),
        key_radiance: AcesCgRadiance(rgb(0.0)),
        key_direction_local: [0.0, 0.0, 1.0],
        key_angular_radius_degrees: 20.0,
        rotation_degrees: 0.0,
        pattern: EnvironmentPattern::UniformNeutral,
    };

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
        if !self.rotation_degrees.is_finite() || !(-180.0..=180.0).contains(&self.rotation_degrees)
        {
            return Err(CoverError::InvalidEnvironmentRotation);
        }
        Ok(self)
    }
}

impl EquirectangularEnvironment {
    pub fn validate(self) -> Result<Self, CoverError> {
        if !self.character_strength.is_finite() || !(0.0..=4.0).contains(&self.character_strength) {
            return Err(CoverError::InvalidEnvironmentStrength);
        }
        if !self
            .source_unit_radiance_candelas_per_square_meter
            .is_finite()
            || !(0.001..=100_000.0).contains(&self.source_unit_radiance_candelas_per_square_meter)
            || !self.exposure_stops.is_finite()
            || !(-16.0..=16.0).contains(&self.exposure_stops)
        {
            return Err(CoverError::InvalidEnvironmentRadiance);
        }
        if !self.rotation_degrees.is_finite() || !(-180.0..=180.0).contains(&self.rotation_degrees)
        {
            return Err(CoverError::InvalidEnvironmentRotation);
        }
        Ok(self)
    }

    pub fn radiance_scale(self) -> f32 {
        self.character_strength
            * self.source_unit_radiance_candelas_per_square_meter
            * self.exposure_stops.exp2()
    }
}

impl IncidentEnvironment {
    pub const NONE: Self = Self::Procedural(ProceduralEnvironment::NONE);

    pub fn validate(self) -> Result<Self, CoverError> {
        match self {
            Self::Procedural(environment) => environment.validate().map(Self::Procedural),
            Self::Equirectangular(environment) => environment.validate().map(Self::Equirectangular),
        }
    }
}

impl ValidatedCoverEvaluator {
    pub fn glow_samples(self) -> [CoverGlowSample; 9] {
        self.cover
            .glow
            .samples()
            .expect("validated cover owns a validated glow profile")
    }

    /// Stratifies the unit-sum core/tail quadrature over angle and radius. Every invocation
    /// remains exactly centered through opposite pairs, while optical integration varies the
    /// radii deterministically so neither fixed displaced copies nor a fixed-radius ring can
    /// survive as a coherent image feature.
    pub fn glow_samples_rotated(self, turns: f32) -> [CoverGlowSample; 9] {
        let mut samples = self.glow_samples();
        let angle = turns * 2.0 * core::f32::consts::PI;
        let (sine, cosine) = angle.sin_cos();
        let axis_x = [cosine, sine];
        let axis_y = [-sine, cosine];
        let diagonal_x = core::f32::consts::FRAC_1_SQRT_2 * (axis_x[0] + axis_y[0]);
        let diagonal_y = core::f32::consts::FRAC_1_SQRT_2 * (axis_x[1] + axis_y[1]);
        let cross_x = core::f32::consts::FRAC_1_SQRT_2 * (axis_x[0] - axis_y[0]);
        let cross_y = core::f32::consts::FRAC_1_SQRT_2 * (axis_x[1] - axis_y[1]);
        let core_radius = self.cover.glow.core_radius_millimeters * 0.001;
        let tail_radius = self.cover.glow.tail_radius_millimeters * 0.001;
        let phase = turns.rem_euclid(1.0);
        let core_a = core_radius * smooth_radial_scale((phase + 0.125).fract());
        let core_b = core_radius * smooth_radial_scale((phase + 0.625).fract());
        let tail_a = tail_radius * smooth_radial_scale((phase + 0.375).fract());
        let tail_b = tail_radius * smooth_radial_scale((phase + 0.875).fract());
        samples[1].offset_meters = [axis_x[0] * core_a, axis_x[1] * core_a];
        samples[2].offset_meters = [-axis_x[0] * core_a, -axis_x[1] * core_a];
        samples[3].offset_meters = [axis_y[0] * core_b, axis_y[1] * core_b];
        samples[4].offset_meters = [-axis_y[0] * core_b, -axis_y[1] * core_b];
        samples[5].offset_meters = [diagonal_x * tail_a, diagonal_y * tail_a];
        samples[6].offset_meters = [-diagonal_x * tail_a, -diagonal_y * tail_a];
        samples[7].offset_meters = [cross_x * tail_b, cross_y * tail_b];
        samples[8].offset_meters = [-cross_x * tail_b, -cross_y * tail_b];
        samples
    }

    pub fn evaluate(self, emitted_illuminance: LinearRgb, sample: CoverSurfaceSample) -> LinearRgb {
        let transmission = self.transmission(sample.view_cosine);
        let reflected = self.reflected_illuminance(sample);
        LinearRgb::new(
            emitted_illuminance.r * transmission.r + reflected.r,
            emitted_illuminance.g * transmission.g + reflected.g,
            emitted_illuminance.b * transmission.b + reflected.b,
        )
    }

    /// Applies the cover interface to incident radiance sampled by an external,
    /// explicitly typed environment source. This preserves one Fresnel owner for
    /// procedural and image-backed environments.
    pub fn evaluate_with_incident_radiance(
        self,
        emitted_illuminance: LinearRgb,
        incident_radiance: AcesCgRadiance,
        sample: CoverSurfaceSample,
    ) -> LinearRgb {
        let transmission = self.transmission(sample.view_cosine);
        let reflected = self.reflected_illuminance_from_radiance(incident_radiance, sample);
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
        let environment = self.environment_radiance(sample.reflection_direction_local);
        self.reflected_illuminance_from_radiance(AcesCgRadiance(environment), sample)
    }

    pub fn reflected_illuminance_from_radiance(
        self,
        incident_radiance: AcesCgRadiance,
        sample: CoverSurfaceSample,
    ) -> LinearRgb {
        let (reflection, _) = self.interface(sample.view_cosine);
        let environment = incident_radiance.0;
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
        let direction = rotate_environment(normalize(direction), self.environment.rotation_degrees);
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
        let (pattern_amount, pattern_mean) = match self.environment.pattern {
            EnvironmentPattern::UniformNeutral => (0.0, 0.0),
            EnvironmentPattern::StudioSoftboxes => {
                let large = rectangular_source(direction, [-0.48, 0.02], [0.30, 0.42], softness);
                let top = rectangular_source(direction, [0.18, 0.68], [0.46, 0.16], softness);
                ((large + top * 0.55 + key_amount * 0.08).min(1.0), 0.14)
            }
            EnvironmentPattern::CalibrationGrid => (calibration_grid(direction), 0.19),
            EnvironmentPattern::OfficeCeiling => {
                let left = rectangular_source(direction, [-0.56, 0.72], [0.18, 0.055], softness);
                let center = rectangular_source(direction, [0.0, 0.72], [0.18, 0.055], softness);
                let right = rectangular_source(direction, [0.56, 0.72], [0.18, 0.055], softness);
                ((left + center + right + key_amount * 0.12).min(1.0), 0.045)
            }
            EnvironmentPattern::DaylightWindow => {
                let window = rectangular_source(direction, [-0.58, 0.12], [0.28, 0.52], softness);
                let sky = rectangular_source(direction, [0.18, 0.78], [0.68, 0.08], softness);
                ((window + sky * 0.12 + key_amount * 0.18).min(1.0), 0.12)
            }
            EnvironmentPattern::WarmPracticals => {
                let upper = circular_source(direction, [-0.34, 0.46, 0.82], 5.0, softness);
                let side = circular_source(direction, [0.64, 0.10, 0.76], 4.0, softness);
                ((key_amount + upper * 0.62 + side * 0.45).min(1.0), 0.025)
            }
            EnvironmentPattern::MixedProduction => {
                let softbox = rectangular_source(direction, [-0.50, 0.16], [0.30, 0.38], softness);
                let ceiling = rectangular_source(direction, [0.12, 0.76], [0.58, 0.08], softness);
                (
                    (softbox * 0.72 + ceiling * 0.18 + key_amount).min(1.0),
                    0.11,
                )
            }
        };
        let strength = self.environment.character_strength;
        // Roughness and haze redistribute the authored key lobe toward its mean instead of
        // inventing radiance. This keeps the procedural approximation energy bounded.
        let redistribution = (self.cover.roughness * 0.75 + self.cover.haze * 0.25).clamp(0.0, 1.0);
        let pattern_amount =
            pattern_amount * (1.0 - redistribution) + pattern_mean * redistribution;
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

fn smooth_radial_scale(unit: f32) -> f32 {
    // Inverse CDF of a two-dimensional Gaussian truncated at three sigma.
    // The authored radius is therefore finite support, not a bright sampling ring.
    const TRUNCATED_MASS: f32 = 0.988_891;
    (-2.0 * (1.0 - unit * TRUNCATED_MASS).ln()).sqrt() / 3.0
}

fn normalize(value: [f32; 3]) -> [f32; 3] {
    let length = (value[0] * value[0] + value[1] * value[1] + value[2] * value[2])
        .sqrt()
        .max(1.0e-8);
    [value[0] / length, value[1] / length, value[2] / length]
}

fn rotate_environment(direction: [f32; 3], rotation_degrees: f32) -> [f32; 3] {
    let angle = rotation_degrees.to_radians();
    let (sine, cosine) = angle.sin_cos();
    [
        direction[0] * cosine + direction[2] * sine,
        direction[1],
        -direction[0] * sine + direction[2] * cosine,
    ]
}

fn rectangular_source(
    direction: [f32; 3],
    center: [f32; 2],
    half_extent: [f32; 2],
    softness: f32,
) -> f32 {
    let x = 1.0
        - smoothstep(
            half_extent[0] - softness,
            half_extent[0] + softness,
            (direction[0] - center[0]).abs(),
        );
    let y = 1.0
        - smoothstep(
            half_extent[1] - softness,
            half_extent[1] + softness,
            (direction[1] - center[1]).abs(),
        );
    x * y * smoothstep(0.0, 0.12, direction[2])
}

fn circular_source(
    direction: [f32; 3],
    center: [f32; 3],
    radius_degrees: f32,
    softness: f32,
) -> f32 {
    let center = normalize(center);
    let alignment = direction
        .into_iter()
        .zip(center)
        .map(|(left, right)| left * right)
        .sum::<f32>()
        .clamp(-1.0, 1.0);
    let edge = radius_degrees.to_radians().cos();
    smoothstep(edge - softness, edge + softness, alignment)
}

fn calibration_grid(direction: [f32; 3]) -> f32 {
    let u = direction[0].atan2(direction[2]) / (2.0 * core::f32::consts::PI) + 0.5;
    let v = direction[1].asin() / core::f32::consts::PI + 0.5;
    let longitude = ((u * 24.0).fract() - 0.5).abs();
    let latitude = ((v * 12.0).fract() - 0.5).abs();
    let lines: f32 = if longitude > 0.46 || latitude > 0.43 {
        1.0
    } else {
        0.0
    };
    let stop_band = (u * 8.0).floor().clamp(0.0, 7.0);
    let calibrated = 2.0_f32.powf(stop_band - 7.0);
    lines.max(calibrated)
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
    InvalidGlow,
    InvalidEnvironmentStrength,
    InvalidEnvironmentRadiance,
    InvalidEnvironmentDirection,
    InvalidEnvironmentSourceSize,
    InvalidEnvironmentRotation,
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
            Self::InvalidGlow => "cover glow profile is outside its physical bounds",
            Self::InvalidEnvironmentStrength => "environment strength must be finite in [0, 4]",
            Self::InvalidEnvironmentRadiance => {
                "environment radiance must be finite and non-negative"
            }
            Self::InvalidEnvironmentDirection => {
                "environment key direction must be normalized on the front hemisphere"
            }
            Self::InvalidEnvironmentSourceSize => {
                "environment source size must be finite in [0.1, 89] degrees"
            }
            Self::InvalidEnvironmentRotation => {
                "environment rotation must be finite in [-180, 180] degrees"
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
            .evaluator(
                environment_preset("environment-calibration-grid")
                    .unwrap()
                    .environment,
            )
            .expect("valid evaluator");
        let emitted = LinearRgb::new(12.0, 8.0, 4.0);
        assert_eq!(cover.evaluate(emitted, sample(0.5)), emitted);
    }

    #[test]
    fn glow_kernel_is_exactly_neutral_at_zero_and_conserves_emitted_energy() {
        let neutral = CoverGlowProfile::NEUTRAL.samples().expect("neutral glow");
        assert_eq!(neutral[0].offset_meters, [0.0, 0.0]);
        assert_eq!(neutral[0].weight, 1.0);
        assert!(neutral[1..].iter().all(|sample| sample.weight == 0.0));

        for preset in COVER_GLASS_PRESETS {
            let samples = preset.profile.glow.samples().expect("catalog glow");
            let weight = samples.iter().map(|sample| sample.weight).sum::<f32>();
            assert!((weight - 1.0).abs() <= 2.0 * f32::EPSILON);
            assert!(samples.iter().all(|sample| sample.weight >= 0.0));
            assert!(
                samples[1..]
                    .iter()
                    .any(|sample| sample.offset_meters != [0.0, 0.0])
            );
        }
    }

    #[test]
    fn rotated_glow_quadrature_preserves_energy_center_and_breaks_fixed_radii() {
        let evaluator = COVER_GLASS_PRESETS[2]
            .profile
            .evaluator(ProceduralEnvironment::NONE)
            .expect("valid semi-gloss evaluator");
        let reference = evaluator.glow_samples_rotated(0.0);
        let rotated = evaluator.glow_samples_rotated(0.381_966_02);
        assert_eq!(
            reference.iter().map(|sample| sample.weight).sum::<f32>(),
            rotated.iter().map(|sample| sample.weight).sum::<f32>()
        );
        for samples in [reference, rotated] {
            let center = samples.iter().fold([0.0_f32; 2], |center, sample| {
                [
                    center[0] + sample.offset_meters[0] * sample.weight,
                    center[1] + sample.offset_meters[1] * sample.weight,
                ]
            });
            assert!(center[0].abs() <= f32::EPSILON);
            assert!(center[1].abs() <= f32::EPSILON);
        }
        assert_ne!(reference[1].offset_meters, rotated[1].offset_meters);
        let reference_radius = reference[1].offset_meters[0].hypot(reference[1].offset_meters[1]);
        let rotated_radius = rotated[1].offset_meters[0].hypot(rotated[1].offset_meters[1]);
        assert_ne!(reference_radius, rotated_radius);
        assert!(reference[5].offset_meters[0].hypot(reference[5].offset_meters[1]) <= 0.0025);
        assert!(rotated[5].offset_meters[0].hypot(rotated[5].offset_meters[1]) <= 0.0025);
    }

    #[test]
    fn fresnel_reflection_grows_at_grazing_angles() {
        let cover = COVER_GLASS_PRESETS[1]
            .profile
            .evaluator(
                environment_preset("environment-studio-softboxes")
                    .unwrap()
                    .environment,
            )
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
        let mut environment = environment_preset("environment-calibration-grid")
            .unwrap()
            .environment;
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
    fn synthetic_hdr_rotation_moves_the_reflected_distribution() {
        let mut environment = environment_preset("environment-studio-softboxes")
            .unwrap()
            .environment;
        environment.rotation_degrees = -90.0;
        let rotated = COVER_GLASS_PRESETS[1]
            .profile
            .evaluator(environment)
            .expect("valid negative rotation");
        environment.rotation_degrees = 0.0;
        let unrotated = COVER_GLASS_PRESETS[1]
            .profile
            .evaluator(environment)
            .expect("valid unrotated environment");
        let mut softbox = sample(1.0);
        softbox.reflection_direction_local = [-0.48, 0.02, 0.877_268];
        let black = rgb(0.0);
        assert_ne!(
            rotated.evaluate(black, softbox),
            unrotated.evaluate(black, softbox)
        );
    }

    #[test]
    fn physically_zero_interfaces_do_not_reflect_at_extreme_angles() {
        let environment = environment_preset("environment-calibration-grid")
            .unwrap()
            .environment;
        let base = CoverGlassProfile {
            character_strength: 1.0,
            thickness_millimeters: 1.0,
            refractive_index: 1.0,
            anti_reflective_efficiency: 0.0,
            absorption_per_millimeter: rgb(0.0),
            roughness: 0.0,
            haze: 0.0,
            glow: CoverGlowProfile::NEUTRAL,
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
    fn calibration_grid_is_spatially_structured_and_roughness_reduces_contrast() {
        let environment = environment_preset("environment-calibration-grid")
            .unwrap()
            .environment;
        let glossy = COVER_GLASS_PRESETS[1]
            .profile
            .evaluator(environment)
            .expect("valid glossy grid");
        let mut dark = sample(1.0);
        dark.reflection_direction_local = [-0.048, -0.988, -0.148];
        let mut bright = sample(1.0);
        bright.reflection_direction_local = [0.0, 0.0, 1.0];
        let glossy_contrast =
            (glossy.evaluate(rgb(0.0), bright).r - glossy.evaluate(rgb(0.0), dark).r).abs();
        assert!(glossy_contrast > 0.01);

        let rough = CoverGlassProfile {
            roughness: 1.0,
            ..COVER_GLASS_PRESETS[1].profile
        }
        .evaluator(environment)
        .expect("valid rough grid");
        let rough_contrast =
            (rough.evaluate(rgb(0.0), bright).r - rough.evaluate(rgb(0.0), dark).r).abs();
        assert!(rough_contrast < glossy_contrast);
    }

    #[test]
    fn thick_cover_refracts_emission_toward_the_surface_normal() {
        let cover = COVER_GLASS_PRESETS[5]
            .profile
            .evaluator(ProceduralEnvironment::NONE)
            .expect("valid thick cover");
        let offset = cover.transmitted_lateral_offset_meters([0.6, 0.0, 0.8]);
        assert!(offset[0] < -0.001);
        assert_eq!(offset[1], 0.0);

        let neutral = CoverGlassProfile::NEUTRAL
            .evaluator(ProceduralEnvironment::NONE)
            .expect("valid neutral cover");
        assert_eq!(
            neutral.transmitted_lateral_offset_meters([0.6, 0.0, 0.8]),
            [0.0, 0.0]
        );
    }

    #[test]
    fn equirectangular_environment_has_explicit_bounded_radiometric_scale() {
        let environment = EquirectangularEnvironment {
            character_strength: 1.0,
            source_unit_radiance_candelas_per_square_meter: 100.0,
            exposure_stops: -2.0,
            rotation_degrees: 15.0,
        };
        assert_eq!(environment.validate(), Ok(environment));
        assert_eq!(environment.radiance_scale(), 25.0);
        assert!(
            IncidentEnvironment::Equirectangular(EquirectangularEnvironment {
                source_unit_radiance_candelas_per_square_meter: 0.0,
                ..environment
            })
            .validate()
            .is_err()
        );
    }

    #[test]
    fn externally_sampled_radiance_uses_the_same_cover_interface() {
        let cover = COVER_GLASS_PRESETS[1]
            .profile
            .evaluator(ProceduralEnvironment::NONE)
            .expect("valid cover");
        let reflected = cover.evaluate_with_incident_radiance(
            rgb(0.0),
            AcesCgRadiance(LinearRgb::new(100.0, 20.0, 5.0)),
            sample(1.0),
        );
        assert!(reflected.r > reflected.g && reflected.g > reflected.b);
        assert!(reflected.r > 0.0);
    }
}
