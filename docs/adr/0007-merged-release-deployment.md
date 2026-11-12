# A reviewed merge authorizes deployment on each configured host

Supersedes ADR-0005's manual-major release gate and extends ADR-0006 beyond security-only
updates. Merging to main is the Operator's approval to deploy the resulting image major,
minor or patch. Renovate majors still require a merge; this decision does not enable
Renovate automerge for majors.

A successful CI push run on the exact current main commit triggers release publication.
The scheduled workflow remains a fallback. A release contains a deployment manifest
identifying the CI-tested source commit. Opted-in hosts poll published releases every
five minutes, validate that the tag belongs to main, and use this manifest to distinguish
merge-authorized releases from older manual releases. Initial installation records a
release floor so an ahead-of-release bootstrap is never downgraded to an old tag.

Each host uses its own Compose project and Operator configuration. Effective service
configuration and source fingerprints identify the affected running services; network
namespace consumers follow their gateway. Only those apps are fetched, stopped,
snapshotted and recreated. Documentation-only or other-host changes advance source
without restarting local apps. Operator overrides take precedence, including local holds.

Before a migrated app can write, stopped-app snapshots and the old code, environment,
image identities and pins are journaled. Failed health checks restore code and App data;
boot recovery resumes from the same journal. Failed candidates are not retried without a
new release or changed Operator configuration. The security updater's lock and the backup lock exclude concurrent writers.
The monitor's own operational journal is never restored over an active transaction.

The older upgrade CLI retains its conservative defaults. `--follow-merges` is an explicit
opt-in for reviewed major/minor deployment, independently for Instance and apps server.
Missing required settings and service topology changes still stop before deployment.
Workers are separate execution hosts: release notes call out their coordination, while
this follower only manages the Instance and apps server.
