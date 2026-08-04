# Camera, time and space

Status: normative.

The canonical scene is right-handed. `+X` is right, `+Y` is up and `+Z` points from the screen toward a frontal viewer. A screen's local active area lies on XY, its center is the local origin and its front normal is `+Z`. A camera looks along local `-Z`.

Scene translation and physical screen dimensions use meters. Focal length and sensor aperture use millimeters. Persisted values always name their unit through the owning contract rather than relying on UI labels.

Project, source, camera and screen time use exact rational values. Project frame rate is an authored positive rational value and remains distinct from source cadence and panel refresh. A project frame maps to time by exact rational division; floating-point seconds are not an authored or media-selection boundary.

Camera and screen motion use the same current keyframed transform contract. Translation is canonical in meters and rotation is canonical as a normalized quaternion. UI yaw, pitch and roll are editing projections, not persisted authority. Every keyframe has a stable id, rational time, exact value and explicit `hold`, `linear`, or `smooth` interpolation.

Camera intrinsics own focal length, sensor aperture, lens shift, focus distance, f-stop and clipping planes. The resolver is the single owner of interpolation and emits one immutable camera sample containing world, view and projection matrices plus resolved intrinsics. Geometry consumes that sample and never reads animation tracks directly.

The current evaluator is an ideal pinhole camera with infinite depth of field. A transient inspection camera may be framed from an explicit physical region of the panel. It is resolved by the same geometry and projection path as the authored camera, preserves the current focal length, sensor and incidence angle, and changes physical position to frame the region. At deep oblique inspection, parts of the complete panel may lie behind the camera; the optional full-panel outline is then absent without invalidating the explicitly framed region. Inspection state is workstation interaction state and is not a persisted project camera.

The current version authors camera animation inside the application. External camera files do not have a runtime evaluation route.
