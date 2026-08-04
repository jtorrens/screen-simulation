# Camera, time and space

Status: normative.

The canonical scene is right-handed. `+X` is right, `+Y` is up and `+Z` points from the screen toward a frontal viewer. A screen's local active area lies on XY, its center is the local origin and its front normal is `+Z`. A camera looks along local `-Z`.

Scene translation and physical screen dimensions use meters. Focal length and sensor aperture use millimeters. Persisted values always name their unit through the owning contract rather than relying on UI labels.

Project, source, camera and screen time use exact rational values. Project frame rate is an authored positive rational value and remains distinct from source cadence and panel refresh. A project frame maps to time by exact rational division; floating-point seconds are not an authored or media-selection boundary.

Camera and screen motion use the same current keyframed transform contract. Translation is canonical in meters and rotation is canonical as a normalized quaternion. UI yaw, pitch and roll are editing projections, not persisted authority. Every keyframe has a stable id, rational time, exact value and explicit `hold`, `linear`, or `smooth` interpolation.

Interpolation belongs to the outgoing keyframe. Evaluation before the first keyframe holds the first authored value and evaluation after the last keyframe holds the last authored value; a one-key track is therefore explicitly static. Adding or replacing a keyframe in the desktop converts its distance/yaw editing projection immediately into canonical translation and quaternion values. Playback consumes only the resulting track.

Camera intrinsics own focal length, sensor aperture, lens shift, focus distance, f-stop and clipping planes. The resolver is the single owner of interpolation and emits one immutable camera sample containing world, view and projection matrices plus resolved intrinsics. Geometry consumes that sample and never reads animation tracks directly.

The current evaluator is a deterministic thin-lens camera. Focal length and f-stop derive the physical circular aperture; every output sample integrates one fixed equal-area, equal-weight aperture pattern, and all rays for a sample converge on the authored plane perpendicular to the optical axis at focus distance. Optical throughput contains the inverse-square f-number term. Near and far clipping are evaluated as optical-axis distances. The current evaluator requires the authored output aspect to equal the resolved sensor-aperture aspect; a future gate policy must be explicit rather than inferred.

The authored lens approximation contains Brown-Conrady radial and tangential distortion, per-channel longitudinal focus offsets, per-channel lateral magnification, natural cos-fourth vignetting strength and RGB transmission. Distortion is inverted at ray generation and rejected unless the mapping remains finite, round-trippable and orientation-preserving across the current normalized sensor field. RGB channels trace independent rays but sample the same linear panel-emission model. This is the current physically motivated RGB approximation; there is no post-process chromatic-aberration route.

Lens integration occurs in linear emitted radiance and produces physical relative irradiance before any preview transform. The technical desktop owns an explicit, non-project preview exposure in EV so this irradiance remains inspectable; changing it cannot alter geometry, focus, throughput or persisted simulation state.

A transient inspection camera may be framed from an explicit physical region of the panel. It is resolved by the same geometry and projection path as the authored camera, preserves the current focal length, sensor, aperture and incidence angle, and changes physical position to frame the region. At deep oblique inspection, parts of the complete panel may lie behind the camera; the optional full-panel outline is then absent without invalidating the explicitly framed region. Inspection state is workstation interaction state and is not a persisted project camera.

The optical result is irradiance at the virtual sensor plane, not a recorded camera image. Sensor photosite integration, exposure, shutter and screen-refresh interaction, CFA, noise, camera color processing and encoding belong to the later capture boundary and do not alter lens evaluation.

The current version authors camera animation inside the application. External camera files do not have a runtime evaluation route.
