#!/usr/bin/env bash
# Tests for the gitleaks pre-commit hook in .githooks/. Needs gitleaks or Docker.
# Usage: tests/hooks.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email test@example.com
  git -C "$SANDBOX" config user.name test
  git -C "$SANDBOX" config core.hooksPath "$REPO/.githooks"
  cp "$REPO/.gitleaks.toml" "$SANDBOX/"
}
teardown() {
  if [ -n "${WORKTREE:-}" ]; then
    git -C "$SANDBOX" worktree remove --force "$WORKTREE"
  fi
  rm -rf "$SANDBOX"
}

commit() { OUTPUT="$(git -C "$SANDBOX" commit -q -m test 2>&1)"; STATUS=$?; }

test_blocks_a_commit_with_a_secret() {
  # A made-up GitHub token, split so this file doesn't trip gitleaks itself.
  printf 'GITHUB_TOKEN=%s%s\n' "ghp_" "4Yq8vN2kR7tLm3Xz9Bc6Wd1Fh5Jp0Ks8Ua2Ee" > "$SANDBOX/.env.example"
  git -C "$SANDBOX" add .env.example
  commit
  [ "$STATUS" != 0 ] || fail "commit with a secret went through"
  assert_output_contains "leaks found"
}

test_blocks_a_wireguard_private_key() {
  printf 'WIREGUARD_PRIVATE_KEY=%s%s\n' "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3f" "Hk0=" > "$SANDBOX/.env.example"
  git -C "$SANDBOX" add .env.example
  commit
  [ "$STATUS" != 0 ] || fail "commit with a WireGuard key went through"
}

test_blocks_a_password_in_an_env_file() {
  printf 'OPENVPN_PASSWORD=%s\n' "c0rrect-h0rse-battery" > "$SANDBOX/.env.example"
  git -C "$SANDBOX" add .env.example
  commit
  [ "$STATUS" != 0 ] || fail "commit with a password went through"
}

test_allows_a_clean_commit() {
  printf 'WIREGUARD_PRIVATE_KEY=\n' > "$SANDBOX/.env.example"
  git -C "$SANDBOX" add .env.example
  commit
  assert_status 0
}

test_an_empty_secret_does_not_swallow_the_next_line() {
  printf 'TELEGRAM_BOT_TOKEN=\nTELEGRAM_CHAT_ID=\nRESTIC_PASSWORD=\nBACKUP_SOURCE=\n' > "$SANDBOX/.env.example"
  git -C "$SANDBOX" add .env.example
  commit
  assert_status 0
}

docker_worktree() {
  command -v docker >/dev/null || fail 'Docker is required for the worktree regression'
  git -C "$SANDBOX" -c core.hooksPath=/dev/null add .gitleaks.toml
  git -C "$SANDBOX" -c core.hooksPath=/dev/null commit -qm initial
  WORKTREE="$SANDBOX/linked worktree"
  git -C "$SANDBOX" worktree add -q -b linked "$WORKTREE"
  # Force the Docker fallback even on machines with native gitleaks installed.
  mkdir "$SANDBOX/docker-bin"
  local tool
  for tool in bash git docker; do
    ln -s "$(command -v "$tool")" "$SANDBOX/docker-bin/$tool"
  done
}

test_docker_allows_clean_linked_worktree_commit() {
  docker_worktree
  printf 'WIREGUARD_PRIVATE_KEY=\n' > "$WORKTREE/.env.example"
  git -C "$WORKTREE" add .env.example
  OUTPUT="$(PATH="$SANDBOX/docker-bin" git -C "$WORKTREE" commit -qm clean 2>&1)"; STATUS=$?
  assert_status 0
}

test_docker_blocks_secret_in_linked_worktree() {
  docker_worktree
  printf 'GITHUB_TOKEN=%s%s\n' 'ghp_' '4Yq8vN2kR7tLm3Xz9Bc6Wd1Fh5Jp0Ks8Ua2Ee' > "$WORKTREE/.env.example"
  git -C "$WORKTREE" add .env.example
  OUTPUT="$(PATH="$SANDBOX/docker-bin" git -C "$WORKTREE" commit -qm secret 2>&1)"; STATUS=$?
  [ "$STATUS" != 0 ] || fail 'worktree commit with a secret went through'
  assert_output_contains 'leaks found'
  [ "$(git -C "$WORKTREE" rev-list --count HEAD)" = 1 ] || fail 'secret was committed'
}

run_tests
