# Project and current-contract policy

Status: normative.

The portable project is a `.screensim` package directory with one strict root manifest and separate owner documents for sources, device profiles, camera/screen tracks and simulation shots. SQLite is not a project format.

Project documents contain portable relative references and stable opaque ids. Machine-specific media associations, recent projects, window state, decoded frames, thumbnails and GPU caches live outside the project and are never authoritative. A missing external association is visible and is never replaced by a same-name or nearby file.

Normal open validates without writing. Each document has one current schema and version. Unknown versions, unknown fields, missing required values and invalid references fail explicitly.

During development, contract, profiles, fixtures, tests and renderer form one current world. A breaking change updates them together and may change every visual result. No earlier reader, evaluator, profile behavior, output result, alias, compatibility flag or version dispatch remains active.

When conversion is useful, an explicit one-way maintenance command operates on a disposable copy or explicitly selected package, writes the complete current representation and validates it. It is not callable from normal open/read/render paths. Once the current data has been updated, temporary conversion code is removed from the delivered runtime.

Build commit, OCIO library/config versions, GPU backend and project content hash may be recorded as provenance. Provenance never selects an earlier implementation.

