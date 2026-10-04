# Implementation navigation

Read [CONTEXT.md](../../CONTEXT.md) for vocabulary and the relevant ADR before changing behavior.

| Change | Start here | Related checks / decision |
| --- | --- | --- |
| Environment settings, defaults, validation, consumer access | [env/catalog.json](../../env/catalog.json), [env_contract.py](../../scripts/env_contract.py), [env templates](../../env/) | `tests/env-contract.test.sh`; [ADR-0003](../adr/0003-instance-environment-contract.md) |
| Internal endpoints, network namespaces, library/download folders for Core and VO | [topology.json](../../stacks/wire/wire/topology.json), [topology.py](../../stacks/wire/wire/topology.py), affected `stacks/*/compose.yaml` | `tests/topology.test.sh`; [ADR-0004](../adr/0004-template-topology-contract.md) |
| Profiles, host directories, wizard choices | [profiles.sh](../../scripts/lib/profiles.sh), [init.sh](../../scripts/init.sh), [setup.sh](../../scripts/setup.sh), affected `stacks/*/compose.yaml` | `tests/profiles.test.sh`, `tests/init.test.sh`, `tests/setup.test.sh`, `tests/template.test.sh` |
| Initial files versus app API connections | [seed.py](../../stacks/wire/wire/seed.py) writes missing files; [steps.py](../../stacks/wire/wire/steps.py) connects apps; [extras.py](../../stacks/wire/wire/extras.py) adds optional customizations | `tests/wire.test.sh`; [ADR-0002](../adr/0002-wiring-only-seeds.md) |
| Requests inside Jellyfin, plugins, themes | [Jellyfin customizations](../jellyfin-customizations.md#requests-inside-jellyfin-web) | [Viewer-status research](../research/viewer-request-status.md) records rationale and pending validation |
| Release or test failures | [Testing](testing.md), [release procedure](../upgrading.md) | Shared runner: [check.sh](../../scripts/check.sh) |

`.env.example`, `worker/.env.example` and the Wiring environment allowlist in
[compose.yaml](../../stacks/wire/compose.yaml) are generated from the environment
catalog/templates. Edit their sources, then run
`python3 scripts/env_contract.py generate` and `scripts/check.sh fast`.
Instance `.env` and App data are Operator-owned and stay outside git ([ADR-0001](../adr/0001-instance-runs-the-template.md)).

Compose remains handwritten: a topology change can require updating both JSON and
Compose. The topology contract covers Core and VO; other Profiles and the Worker
keep their definitions in Compose. Research notes record dated investigation;
use their status and implementation links to distinguish proposals from current behavior.
