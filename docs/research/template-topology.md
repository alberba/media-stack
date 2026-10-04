# Shared Template topology design

**Status: implemented.** Current behavior lives in [topology.json](../../stacks/wire/wire/topology.json)
and [topology.py](../../stacks/wire/wire/topology.py); decisions are in
[ADR-0004](../adr/0004-template-topology-contract.md). This note retains design and acceptance criteria.

Design from the architecture review's candidate 3, implemented in `stacks/wire/wire/topology.json` and `topology.py`. See ADR-0004 for the trade-off and CONTEXT.md for terminology.

## Scope

Cover the Core and `vo`: service identity, activation, network namespace, internal listener ports, host publications, manager kind, library roots and download categories. Include `wire` and `wire-seed` as one-shot services with distinct completion expectations.

Keep existing ports, aliases, library names, categories and API behaviour. Other Profiles, App data directories and ownership, Worker configuration, public URLs, VPN-provider-assigned torrent ports and new `.env` options remain outside this change. Gluetun's existing publications and aliases for other Profiles remain valid; comparisons are restricted to covered services.

## Definition and consumption

Use `stacks/wire/wire/topology.json` for defaults and `topology.py` for the Python reader using the standard library. Both live in the Wiring build context so the existing Docker build includes them; host scripts access that same reader from the checkout.

The reader exposes a small Python API for Wiring and explicit CLI queries for Bash consumers. It returns active services and manager metadata, library/download paths, internal endpoints and verification expectations. It does not parse `.env`, own the Profile catalogue or store API keys. Existing callers supply their resolved enabled Profiles.

Distinguish a service's identity from its network namespace. A caller sharing Gluetun's namespace reaches another covered service in that namespace through `localhost`; an external caller uses the target's Docker alias. Internal connections use listener ports, never published host ports. Host publications identify the publishing service, which can be Gluetun rather than the target app.

For managers, record library roots and download categories once. Derive download directory paths from their categories, and host-relative library paths from their `/data` paths. Both `init` and `wire-seed` consume the same selected layout. Container creation and host ownership operations remain the consumers' responsibility.

Reject malformed definitions, missing required fields, duplicate identities, invalid ports, unsafe paths and conflicting listener ports within a shared namespace. Consumers fail with an actionable error before creating directories or making API writes; there is no fallback catalogue.

Python 3 becomes an explicit host prerequisite. Preparation reports its absence before modifying the Instance, and installation documentation lists it. No additional Python packages are required.

## Preserved behaviour and deliberate verification change

Wiring retains its existing resource-specific existence checks and only seeds what is missing. Centralising defaults does not add live topology discovery, migrate existing connections or rewrite Operator configuration. In particular, enabling `vo` does not extend an existing Jellyfin library automatically; that would require a separate decision under ADR-0002.

Verification checks all covered active long-running services, including the VO managers when enabled. It distinguishes health expectations from successful one-shot completion instead of treating every service as a daemon. Other Profiles retain their current verification behaviour. The VPN egress check remains independent of this catalogue.

## Validation and completion

PR CI checks the resolved Compose model against the shared definition for Core and Core plus `vo`. It checks service activation, namespace ownership, aliases, published ports, explicit listener settings, healthcheck endpoints and required mounts. It also checks that Gluetun's forwarding hooks use qBittorrent's declared API listener; the provider-assigned torrent port remains dynamic. Image-defined default listener ports are corroborated by existing healthchecks; static validation does not prove what an image actually listens on.

Consistency tests compare the two independently maintained representations; they do not recreate a third catalogue of expected ports and paths. Separate behavioural cases use small synthetic definitions to prove that address resolution selects `localhost` or the Docker alias correctly, listener and published ports can differ, inactive VO managers are excluded, and deliberate Compose discrepancies fail with a service-specific diagnostic. Tests also cover invalid definitions and preservation of existing Wiring configuration.

Run the existing preparation, verification, Wiring and Template tests after adapting their consumers. Keep unrelated policy tests intact. Run the manual real-app integration test when validating the change in an environment that can execute Docker containers; report whether it was run. Its fixtures should consume the definition for the covered topology while preserving independent assertions about actual API connections and idempotence.

The change is complete when covered production consumers no longer carry independent topology catalogues, Compose disagreements fail CI, preparation and seeding agree on folders, active VO services are verified, and existing Operator configuration is preserved. Compose remains a deliberate independently checked representation. No services, ports or library folders are renamed or migrated.
