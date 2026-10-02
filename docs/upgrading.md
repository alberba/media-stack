# Releases and upgrades

An Instance follows published releases of the Template. Renovate proposes image
bumps on main; maintainers test and bundle them into a release. What's Up Docker
(the monitoring Profile) reports upstream image updates, not tested Template
releases, and must not replace this upgrade procedure.

## Versioning and maintainer checklist

Use stable SemVer tags `vMAJOR.MINOR.PATCH`:

- Major: manual intervention, removed Profiles, renamed settings, or incompatible
  App data migrations. Declare all manual steps and database downgrade limits.
- Minor: new Profiles/settings and compatible image bumps.
- Patch: compatible fixes.

Before releasing, add `docs/releases/vX.Y.Z.md`, using the headings below. All
releases, including patches, need notes. The upgrade command displays every note
between the installed version and its target. A major release always requires
Operator confirmation. Use `Breaking changes: yes` for an incompatible migration
in any release (prefer a major).

```markdown
# vX.Y.Z
Breaking changes: no

## Images bumped
- Old and new image tags, including the Worker when applicable.

## New settings
- Name, default, purpose; write None when there are none.

## New Profiles
- Name and purpose; write None when there are none.

## Fixes
- Operator-visible changes.

## Manual steps
- Ordered steps to perform before continuing, or None.
- Database migration/downgrade limits and the backup needed to restore App data.
```

Run `scripts/release.sh vX.Y.Z`. It requires a clean main branch, validates the
Core, each Profile individually, all Profiles together, GPU and Worker configs,
runs all `tests/*.test.sh` (including the provider check against the pinned
Gluetun image), and then creates an annotated local tag. It uses a temporary .env
and never reads Instance secrets. Tests needing root must run with sudo. Review
the resulting tag, then publish explicitly:

```sh
git push origin vX.Y.Z
gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file docs/releases/vX.Y.Z.md
```

The first release must tag a commit in the public Template history. Publish tags
in ascending version order on main; never move a published tag. Verify on a real
Instance before publishing, including enabled Profiles and the VPN. Test results
with simulated Docker do not replace this check.

## Operator commands

From the Instance clone (requires Bash 4+, Git, curl, Python 3 and Docker Compose):

```sh
scripts/upgrade.sh --version
scripts/upgrade.sh --list
scripts/upgrade.sh --dry-run             # defaults to latest stable GitHub Release
sudo scripts/upgrade.sh [vX.Y.Z]
sudo scripts/upgrade.sh --rollback
```

The script fetches published stable Releases from `alberba/media-stack`, fetches
their tags from origin, and refuses dirty tracked files or untracked Template
files. Ignored Instance files, including .env, remain in place. Dry-run fetches
metadata/tags but changes no checkout, version record, .env or running services.
Version state lives in `.git/media-stack-upgrade/`, outside the Template.

Existing clones infer their base from the latest reachable release tag. A commit
beyond it is reported as unreleased. Unknown/local/fork commits require an
explicit `--assume-version vX.Y.Z`; without reachable releases, specify a base
published release as well. This selects a changelog base, not a claim that the
local code matches it. Keep a full clone, not a shallow clone.

Read every intermediate release's manual steps. The script asks for explicit
confirmation for breaking changes; perform those steps before confirming. With
the backup Profile enabled it takes a backup before changing code. Otherwise it
prints the backup instructions. Missing settings prompt to run the target
`setup.sh` (current values are defaults) or fill just the missing variables.
Only confirmed new settings are appended in the latter mode. init.sh runs at
each intermediate release, followed by pull, build of local images, up and a
bounded wait for verify.sh. Settings from intermediate releases are therefore
processed even when jumping several versions. Do not export Compose settings
that override .env while upgrading.

If an upgrade fails, its original checkout and the last applied release remain
recorded. The script offers rollback and exits unsuccessfully even if rollback
succeeds. You can also rerun `--rollback`. Rollback restores the previous code
and images, rebuilds local images, and verifies the Instance; it preserves .env
and all App data. A failed rollback keeps recovery state so it can be retried.

**Rollback does not undo database migrations.** Restore App data from the backup
when release notes require it: [backup guide](backup.en.md). New .env settings
remain after rollback. Restart your Worker with the release's matching Tdarr
image after an upgrade or rollback.
