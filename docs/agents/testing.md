# Testing and failure diagnosis

[scripts/check.sh](../../scripts/check.sh) is the shared local/CI validation entry
point. Run it from the Template checkout on Linux with Bash 4+, Python 3, Git,
Docker Engine and Compose v2. Full checks also need sqlite3, curl and sudo/root for
the host-preparation tests. ShellCheck uses the installed command or a pinned
Docker image. macOS's BSD `stat` and other utilities do not support these Linux
tests; use a Linux VM or the workflows instead.

| Command | Scope | Cost |
| --- | --- | --- |
| `scripts/check.sh fast` | ShellCheck and generated environment contract | No app stack; may pull ShellCheck |
| `bash tests/<area>.test.sh` | One affected area; see [navigation](navigation.md) | Some tests use Docker; `init.test.sh` needs root |
| `scripts/check.sh ci` | Fast checks, Compose variants/Worker, all shell test files except real-app Wiring, local image builds | Several minutes; container tests and image downloads |
| `scripts/check.sh integration` | Wiring against the pinned real apps, including VO, then a second run for idempotence | Starts a second scratch stack; approximately 3 GB of images |
| `scripts/check.sh release` | CI checks plus real-app Wiring | Full release gate, without making a tag |

The [push/PR workflow](../../.github/workflows/ci.yml) runs `check.sh ci` plus a
full-history secret scan. The [manual Wiring workflow](../../.github/workflows/wiring-integration.yml)
runs `check.sh integration` on a separate Linux runner. Use that runner or a
dedicated Linux test machine for the second scratch stack, rather than competing
with a production Instance's RAM. `tests/wire-fixture.test.sh`, included in CI,
checks the Seerr image can write to its prepared directory without starting the stack.

Enable the local secret hook once per clone:

```sh
git config core.hooksPath .githooks
```

The hook supports ordinary clones and linked worktrees with either native
gitleaks or Docker. `tests/hooks.test.sh` checks that the Docker fallback accepts
a clean linked-worktree commit and rejects one containing a secret.

## Keep the failure evidence

Keep output and preserve the command's exit status, including when using `tee`:

```sh
set -o pipefail
scripts/check.sh ci 2>&1 | tee /tmp/media-stack-check.log
```

Wiring failures save redacted container states, recent logs and Seerr directory
ownership under the printed `/tmp/wire-it-diagnostics.*` directory before
cleaning up. The manual workflow uploads those logs on failure. Start with an
exited container's error, exit code, OOM flag and mount ownership; a 300-second
HTTP timeout alone does not establish memory pressure or a buildx problem.
Logs mask the test's disposable passwords and API keys; review artifacts before sharing.

To retain the scratch containers for a deeper investigation:

```sh
KEEP=1 scripts/check.sh integration
```

The script prints its unique `wire-it-*` prefix. Inspect only those containers,
then remove that scratch stack and its network/image when finished. Keep Instance
secrets out of logs. Release tagging/publishing follows [upgrading.md](../upgrading.md);
passing CI alone does not replace the real-app release gate or Instance verification.
