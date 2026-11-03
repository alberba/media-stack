# Compatible updates release and install themselves

Keeping an Instance current used to need three manual steps: merge Renovate's PRs, cut a release with `scripts/release.sh`, and run `sudo scripts/upgrade.sh`. In practice merges piled up on main while the author's NAS stayed behind and no release was ever published. Now compatible changes go through the whole path on their own. Renovate automerges minor, patch and digest updates once CI passes. A daily workflow turns what is new on main into a release (`scripts/auto-release.sh`). A daily timer on the Instance installs it with `scripts/upgrade.sh --unattended`, which takes a backup, verifies the result and rolls back on failure. Anything that needs a person stops the chain: major updates, breaking changes, Worker changes and new settings.

## Considered Options

- **Instances follow main directly** (`git pull` + `compose up`): simplest, but it bypasses release notes, the per-release backup and rollback points, and other Operators of the public Template would get every merge untested.
- **Keep everything manual**: safest per change, but it does not happen, and stale images miss security fixes.

## Consequences

- Automatic releases rely on CI (`scripts/check.sh ci`) instead of the full `scripts/release.sh` validation. The author's Instance is the first real one to install each release.
- Release notes of automatic releases are generated from the history. Their Fixes section is only as good as the commit subjects.
- Unattended upgrades never cross a major version, `Breaking changes: yes` or a missing setting. They report the held release once and wait for `sudo scripts/upgrade.sh`.
- Security pins and Template releases meet on the Instance: a release that reaches a pinned version replaces the pin.
