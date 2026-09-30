# Wiring only seeds, it never reconciles

The `wire` container creates the app-to-app connections an Instance is missing (download clients, root folders, Prowlarr apps, Seerr servers, Bazarr links…) and leaves every existing one untouched, even if it differs from what the Template would create. The Operator's changes in the web UIs always win. This is what lets the author's NAS, which was configured by hand long before the Template existed, run `wire` on every `docker compose up` without losing anything (see ADR-0001).

## Considered Options

- **Declarative "config as code" (Configarr, Buildarr)**: one YAML describes the whole state and every run reconciles to it, reverting UI edits and possibly deleting what it doesn't manage. It would overwrite the NAS, and it doesn't cover Jellyfin, Seerr, Bazarr or qBittorrent anyway. Buildarr is also unmaintained.
- **Run once, guarded by a marker file**: simpler, but enabling a Profile later (e.g. `vo`) would leave its apps unwired.

## Consequences

- Every step is "GET, then create only if absent", so running it again changes nothing.
- Quality profiles are the one exception to "never touch": Recyclarr keeps the TRaSH custom formats of the Template's own named profiles up to date, but their qualities and order are seeded only on creation, and profiles the Operator made are never touched.
