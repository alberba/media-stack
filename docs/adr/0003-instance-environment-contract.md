---
status: accepted
---

# One environment contract for the Instance and Worker

The Template defines one catalog for its public environment settings, with separate scopes for an Instance and a Worker. Docker Compose's `.env` syntax and effective value precedence are the reference: initialization validates the values Compose will use, while the setup assistant shows when a shell override differs from the file it edits. The assistant reports setting names and sources without printing secret values. This avoids different readers silently interpreting the same setting differently.

The catalog owns setting names, defaults, validation metadata and consumer access. The example environment files and the Wiring allowlist are derived from it; CI checks Compose's references against the catalog. Operators may still start Compose directly: Compose keeps its checks for indispensable interpolation values, while `init` performs the full contract validation. Existing `.env` files are read in place and never automatically rewritten to match the catalog.

The normal initialization entry point runs as the Operator so its validation sees the same shell environment as a later Compose invocation. It elevates privileges only for the host changes that need them, such as directory ownership and Docker network creation.

The guarantee covers the documented Compose invocation from the Template root with the same shell environment. An alternate environment file must be selected explicitly for initialization, which then shows the equivalent Compose command; a later command with different options is outside that guarantee. Duplicate active keys are reported, while validation follows Compose's effective value and leaves the Operator's file untouched.

Unknown settings in an Operator's `.env` are preserved with a warning, so an existing Instance can retain its own extensions. Required settings depend on the Core and active Profiles; an optional or already persisted app credential does not become mandatory merely because it appears in the catalog. The Wiring receives only the settings it needs, with its allowlist derived from the catalog, rather than every secret in the Instance's `.env`.

## Considered Options

- Keep separate shell, Python and Compose rules: changes can silently drift, and a missing Wiring variable arrives empty.
- Pass the entire `.env` into the Wiring: simpler to configure, but exposes unrelated credentials such as the backup password.
- Reject unknown settings: catches typos, but breaks Operator extensions and existing Instances.
