#!/usr/bin/env bash
# Tests for the Profile module (scripts/lib/profiles.sh), through its interface.
# Usage: tests/profiles.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"
. "$REPO/scripts/lib/profiles.sh"

test_profile_on_finds_a_listed_profile() {
  profile_on vo "backup,vo,remote" || fail "vo is listed"
}

test_profile_on_is_false_for_a_profile_that_is_not_listed() {
  ! profile_on vo "backup,remote" || fail "vo is not listed"
  ! profile_on vo "" || fail "nothing is listed"
}

test_profile_on_ignores_spaces_around_names() {
  profile_on vo "backup, vo ,remote" || fail "spaces around a name are not part of it"
}

test_profile_on_needs_the_whole_name_and_the_same_case() {
  ! profile_on vo "vo2,xvo" || fail "vo matched part of another name"
  ! profile_on vo "VO" || fail "names are case sensitive"
}

test_profile_on_ignores_empty_items() {
  profile_on vo ",,vo," || fail "empty items between commas are dropped"
}

test_profiles_are_listed_once_each_in_the_order_the_wizard_asks() {
  local names dupes
  names="$(profiles_all)"
  [ -n "$names" ] || fail "no Profiles listed"
  [ "$(echo "$names" | head -n1)" = backup ] || fail "backup is asked first"
  dupes="$(echo "$names" | sort | uniq -d)"
  [ -z "$dupes" ] || fail "listed twice: $dupes"
  ! echo "$names" | grep -qvE '^[a-z]+$' || fail "a Profile name is not a lowercase word: $names"
}

test_every_profile_has_a_one_line_help_text() {
  local name help
  for name in $(profiles_all); do
    help="$(profile_help "$name")"
    [ -n "$help" ] || fail "$name has no help text"
    [[ "$help" != *$'\n'* ]] || fail "$name help is more than one line"
  done
}

test_every_profile_has_folders_with_a_known_owner() {
  local name kind dir
  for name in $(profiles_all); do
    [ -n "$(profile_dirs "$name")" ] || fail "$name has no folders"
    while read -r kind dir; do
      [[ "$kind" =~ ^(app|root|private)$ ]] || fail "$name: unknown owner '$kind' for $dir"
      [ -n "$dir" ] || fail "$name: owner '$kind' without a folder"
    done < <(profile_dirs "$name")
  done
}

# The reference cases: one Profile of each kind, written out by hand.
test_backup_keeps_its_folder_as_root() {
  [ "$(profile_dirs backup)" = "root backup" ] || fail "got: $(profile_dirs backup)"
}

test_vo_folders_belong_to_the_instance_user() {
  [ "$(profile_dirs vo)" = $'app radarr-vo\napp sonarr-vo' ] || fail "got: $(profile_dirs vo)"
}

test_remote_keeps_the_tailscale_state_private_to_root() {
  [ "$(profile_dirs remote)" = "private tailscale" ] || fail "got: $(profile_dirs remote)"
}

test_asking_about_a_profile_that_does_not_exist_fails() {
  ! profile_help nope >/dev/null || fail "help for an unknown Profile"
  ! profile_dirs nope >/dev/null || fail "folders for an unknown Profile"
  ! profile_requires nope >/dev/null || fail "settings for an unknown Profile"
}

test_backup_requires_the_restic_password() {
  [ "$(profile_requires backup)" = "RESTIC_PASSWORD" ] || fail "got: $(profile_requires backup)"
}

test_a_profile_without_required_settings_lists_none() {
  profile_requires vo >/dev/null || fail "vo is a Profile: asking must not fail"
  [ -z "$(profile_requires vo)" ] || fail "vo needs no setting, got: $(profile_requires vo)"
}

test_required_settings_exist_in_env_example() {
  local name setting
  for name in $(profiles_all); do
    for setting in $(profile_requires "$name"); do
      grep -qE "^$setting=" "$REPO/.env.example" || fail "$name requires $setting, which .env.example does not define"
    done
  done
}

test_unknown_profiles_are_the_listed_names_that_do_not_exist() {
  [ "$(profiles_unknown "backup, nope,Vo,vo")" = $'nope\nVo' ] || fail "got: $(profiles_unknown "backup, nope,Vo,vo")"
  [ -z "$(profiles_unknown "")" ] || fail "an empty list has no unknown names"
  [ -z "$(profiles_unknown "backup,vo")" ] || fail "known names reported"
}

# The wire container reads COMPOSE_PROFILES in Python (stacks/wire/wire/config.py): both
# readers must agree on what a value means.
test_the_wire_container_reads_compose_profiles_the_same_way() {
  local value profile in_python
  for value in "backup,vo" "backup, vo" " vo ,jackett" ",vo," "v o" "Vo" "vo;jackett" ""; do
    in_python="$(COMPOSE_PROFILES="$value" PYTHONPATH="$REPO/stacks/wire" python3 -B -c \
      'import os; from wire import config; print(*sorted(config.profiles(os.environ)))')" \
      || fail "wire could not read '$value'"
    for profile in $(profiles_all); do
      if profile_on "$profile" "$value"; then
        [[ " $in_python " == *" $profile "* ]] || fail "'$value': bash has $profile on, wire has: $in_python"
      else
        [[ " $in_python " != *" $profile "* ]] || fail "'$value': wire has $profile on, bash does not"
      fi
    done
  done
}

run_tests
