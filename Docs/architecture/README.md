# Current architecture

Status: normative.

This directory contains only the documents required to implement and validate the current version:

- `current_system.md`: product boundary, stack, domains and dependency direction.
- `color_and_panel.md`: source interpretation, device signal, physical panel emission and optical cover.
- `camera_time_and_space.md`: canonical coordinates, rational time and animated camera/screen tracks.
- `sensor_capture.md`: shutter integration, photosite response, noise and RAW ownership.
- `native_compute.md`: replaceable Native compute boundary and current Metal execution slice.
- `project_and_change_policy.md`: portable project ownership, current-only contracts and explicit maintenance.
- `validation.md`: executable architecture and contract enforcement.

Documents that stop describing the current version are removed from this index and placed in the sealed historical archive without remaining as active context.

`architecture/decision-authority.json` indexes cross-boundary product decisions by stable id. It records only bounded scope, canonical owner section and focused enforcement; decision meaning remains exclusively in the named active owner. `scripts/check_decision_authority.py` rejects duplicate or missing owners, unknown references, inactive owners and missing enforcement.
