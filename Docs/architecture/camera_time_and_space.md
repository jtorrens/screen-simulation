# Camera, time and space

Status: normative.

The canonical scene is right-handed. `+X` is right, `+Y` is up and `+Z` points from the screen toward a frontal viewer. A screen's local active area lies on XY, its center is the local origin and its front normal is `+Z`. A camera looks along local `-Z`.

Scene translation and physical screen dimensions use meters. Focal length and sensor aperture use millimeters. Persisted values always name their unit through the owning contract rather than relying on UI labels.

Project, source, camera and screen time use exact rational values. Project frame rate is an authored positive rational value and remains distinct from source cadence and panel refresh. A project frame maps to time by exact rational division; floating-point seconds are not an authored or media-selection boundary.

Camera and screen motion use the same current keyframed transform contract. Camera transform and camera intrinsics are independent tracks and are resolved at the requested rational time into one immutable sample. Translation is canonical in meters and rotation is canonical as a normalized quaternion. UI yaw, pitch and roll are editing projections, not persisted authority. Every keyframe has a globally unique id within its track, rational time, exact value and explicit `hold`, `linear`, or `smooth` interpolation.

Interpolation belongs to the outgoing keyframe. Quaternion rotation uses shortest-path SLERP; `smooth` applies its authored smoothstep timing before SLERP. Evaluation before the first keyframe holds the first authored value and evaluation after the last keyframe holds the last authored value; a one-key track is therefore explicitly static. Adding or replacing a keyframe in the desktop converts its distance/yaw editing projection immediately into canonical translation and quaternion values. Playback consumes only the resulting track.

Camera intrinsics own focal length, sensor aperture, lens shift, focus distance, f-stop and clipping planes. Lens shift is dimensionless in sensor-gate widths/heights, is applied before distortion inversion and is limited to `[-0.5, 0.5]` per axis in the current contract. The resolver is the single owner of interpolation and emits one immutable camera sample containing row-major canonical world-to-view and ideal pre-distortion view-to-clip matrices plus resolved intrinsics. Geometry consumes that sample and never reads animation tracks directly.

The current evaluator is a deterministic thin-lens camera. Focal length and f-stop derive the physical circular aperture; every output sample integrates one fixed equal-area, equal-weight aperture pattern, and all rays for a sample converge on the authored plane perpendicular to the optical axis at focus distance. Optical throughput contains the inverse-square f-number term. Near and far clipping are evaluated as optical-axis distances. The current evaluator requires the authored output aspect to equal the resolved sensor-aperture aspect; a future gate policy must be explicit rather than inferred.

The authored lens approximation contains Brown-Conrady radial and tangential distortion, per-emitter longitudinal focus offsets, per-emitter lateral magnification, natural cos-fourth vignetting strength and emitter transmission. Distortion uses a bounded Newton inversion and is rejected unless the mapping remains finite, convergent, round-trippable and orientation-preserving across the complete shifted sensor gate. The three physical panel emitters trace independent rays in the panel's native primary basis and convert to ACEScg only after optical integration. This is the current physically motivated tristimulus approximation; there is no post-process chromatic-aberration route.

Lens integration occurs in linear emitted radiance and produces physical relative ACEScg irradiance through a public immutable Application result before any preview transform. The technical desktop owns an explicit, non-project preview exposure in EV as a separate presentation adapter; changing it cannot alter geometry, focus, throughput, the linear optical result or persisted simulation state. Future still and OFX adapters must consume this same linear result.

A transient inspection camera may be framed from an explicit physical region of the transformed panel. It is resolved by the same geometry and projection path as the authored camera, preserves the current focal length, sensor, aperture and incidence angle, changes physical position to frame the region and explicitly refocuses that region. Whether subpixels are resolved is derived from the per-channel sensor-pixel and aperture footprint, not pinhole magnification alone. At deep oblique inspection, parts of the complete panel may lie behind the camera; the optional full-panel outline is then absent without invalidating the explicitly framed region. Inspection state is workstation interaction state and is not a persisted project camera.

The optical result is irradiance at the virtual sensor plane, not a recorded camera image. Sensor photosite integration, exposure, shutter and screen-refresh interaction, CFA, noise, camera color processing and encoding belong to the later capture boundary and do not alter lens evaluation.

The current version authors camera animation inside the application. External camera files do not have a runtime evaluation route.
