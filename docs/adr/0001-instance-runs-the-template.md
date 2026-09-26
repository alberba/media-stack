# The author's NAS is an Instance of the public Template

The repository is published as a public Template so that other Operators can deploy the same stack. The author's own NAS runs that same Template (a plain clone plus its own `.env`) instead of a private fork. This way what gets published is exactly what runs in production, and the two cannot drift apart. It follows that nothing specific to one Instance can live in git: secrets, domain, IPs, app data and databases stay out of the repo. App data lives under `APPDATA_ROOT` outside the working tree, and is protected by an encrypted off-site backup (restic to Google Drive), not by git.

## Considered Options

- **Private repo with configs and secrets committed** (the previous approach): cannot be shared, and it still wasn't a real recovery point because databases were ignored.
- **Private fork for the NAS plus a sanitised public copy**: two sources of truth, and the public one silently rots.

## Consequences

- Anything that only the author uses (mousehole, issue-automator, Jackett for Spanish trackers) ships as an opt-in Profile, not as a local patch.
- Service names in the Core are language-neutral (`radarr`, `sonarr`), so the author's Instance renames `radarr-es`/`sonarr-es`.
- The previous private repo is archived as `docker-media-stack-legacy`; its history is never made public.
