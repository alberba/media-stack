# Apps server uses the same security updater as the Instance

An optional apps server runs services that need API access rather than the Media library.
It is its own Compose project under `apps-server/`, with its own Operator-owned `.env`,
App data, update journal, image pins and systemd timer. It is not a Tdarr Worker.
The first supported app is Seerr. Compose extends the existing service definitions,
including the security monitor and WUD, instead of maintaining another updater.

The Instance may replace its local Seerr with the optional `compose.seerr-remote.yaml`
relay. The relay preserves the service name, port and Wiring defaults. Its remote URL
is Operator configuration; no existing app settings are reconciled (ADR-0002).

Each host discovers and verifies corrections on its own architecture and updates only
containers belonging to its Compose project. The existing policy remains unchanged:
verified HIGH/CRITICAL corrections, no new severe findings, stable nonmajor versions,
healthy apps, stopped-app snapshots, persistent pins and health-based recovery. This role does not install Template releases automatically. The Instance release timer
from ADR-0005 remains a separate opt-in mechanism: Operators selecting security-only
automation must leave that timer disabled. Locally built images remain reviewed changes.
The update pins file must be last, including after an Operator relay override.

The environment catalog gains an `apps-server` scope (extending ADR-0003). Template
source contains no host addresses or credentials. A remote app's App data must be
backed up on its execution host or exported to the Instance's backup source; the
Instance's original app directory no longer contains current remote requests.
