# Architecture validation

Status: normative.

Architecture is enforced rather than inferred from prose. `architecture/domains.json` is the exact current workspace package and local-dependency matrix. `architecture/validation-owners.json` assigns every repository path to one validation owner. An undeclared package, dependency or path is an error.

The architecture guard also verifies that active documentation does not link into the sealed historical archive and that exact retired paths do not return. It uses Cargo metadata for real package edges rather than accepting source-text conventions.

Contract coverage will reject unknown versions, unknown fields, aliases, missing required values and invalid references. Startup coverage will prove byte-for-byte read-only project opening. Conversion coverage will use disposable copies. CPU/GPU color and numeric implementations will be compared with documented tolerances.

Desktop export coverage decodes an in-memory PNG and requires its raster and RGBA bytes to equal the immutable Native level-zero publication buffer exactly. Display-pyramid tests separately require exact 2× area reduction, including odd raster edges, so export cannot silently consume a presentation level.

Broad tests are never a fallback for an unclassified change. The validation-owner manifest must first assign the changed path to its semantic owner and exact checks.
