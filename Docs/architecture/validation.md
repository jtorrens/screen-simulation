# Architecture validation

Status: normative.

Architecture is enforced rather than inferred from prose. `architecture/domains.json` is the exact current workspace package and local-dependency matrix. `architecture/validation-owners.json` assigns every repository path to one validation owner. An undeclared package, dependency or path is an error.

The architecture guard also verifies that active documentation does not link into the sealed historical archive and that exact retired paths do not return. It uses Cargo metadata for real package edges rather than accepting source-text conventions.

Contract coverage will reject unknown versions, unknown fields, aliases, missing required values and invalid references. Startup coverage will prove byte-for-byte read-only project opening. Conversion coverage will use disposable copies. CPU/GPU color and numeric implementations will be compared with documented tolerances.

Desktop export coverage decodes an in-memory PNG and requires its raster and RGBA bytes to equal the immutable Native level-zero publication buffer exactly. Display-pyramid tests separately require exact 2× area reduction, including odd raster edges, so export cannot silently consume a presentation level.

Photometric coverage owns one explicit device-code scale and verifies every patch is exactly achromatic. A uniform half-code panel with zero authored black level must retain the exact authored EOTF ratio relative to white after physical optical evaluation. Separate owning-domain tests verify analytic shutter/ND scaling, photosite quantization and clipping identity, explicit middle-gray development placement, and parity between the ideal camera preview and the complete Native RAW/develop route for the same calibrated exposure. The pinned ACES 2.0 sRGB SDR output also owns fixed middle-gray and diffuse-white code anchors. No photographic file is a golden value for these tests.

Lens coverage requires unique stable template ids, complete finite coefficients, successful full-gate inversion certification for every bundled model and valid midpoint interpolation across the current catalog. Capture templates must resolve one explicit lens template whose nominal focal length equals the capture default.

Broad tests are never a fallback for an unclassified change. The validation-owner manifest must first assign the changed path to its semantic owner and exact checks.
