# Match Reference Mode — future proposal

Status: non-normative future product proposal. It is intentionally not listed by `Docs/architecture/README.md` and defines no current evaluator, UI, persistence or compatibility behavior.

The future Match Reference Mode will consume a reference raster, explicit image-coordinate mapping, the rigid transformed Device screen geometry and the existing physical camera intrinsics. Four ordered correspondences (`TL`, `TR`, `BR`, `BL`) will constrain an external planar-pose solver. The first supported contract will keep focal length and sensor gate fixed and solve only camera position and orientation by minimizing reprojection error. Unknown-focal solving, distortion calibration, feature detection and tracking remain separate later decisions.

The solver will never move, rotate, scale or corner-pin the Device. Its sole output will be a canonical camera position and quaternion accepted by the same Camera state used by numeric authoring and manual Viewer navigation. `Navigation Pivot` remains the transformed geometric center used only for manual orbit; `Device Origin` remains a local-coordinate convention; `Match Anchor` remains an ordered reference correspondence. No shared `pivot` field may represent those three concepts.

The reference adapter must explicitly convert between Viewer points, backing scale, displayed raster bounds, reference-image pixels and normalized image coordinates. Letterboxing, viewer zoom/pan and HiDPI scale are presentation transforms and cannot alter the solver's image coordinates. A corner drag updates one 2D constraint, invokes the solver and republishes the complete camera pose; all projected corners may move while the Device remains rigid. One drag will later become one Undo operation.

The current implementation prepares this path only by keeping one programmatically settable camera pose and exposing a rigid Device geometry with center, plane axes, dimensions and four world-space corners. It contains no solver, corner handles, reference loader or partial Match behavior.
