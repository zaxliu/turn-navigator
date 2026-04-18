#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

assert_eq() {
  local expected=$1
  local actual=$2
  local message=$3
  if [[ "$expected" != "$actual" ]]; then
    printf 'ASSERTION FAILED: %s\nexpected: [%s]\nactual:   [%s]\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_file_contains() {
  local path=$1
  local needle=$2
  if ! grep -Fq "$needle" "$path"; then
    printf 'ASSERTION FAILED: expected [%s] in %s\n' "$needle" "$path" >&2
    exit 1
  fi
}

setup_case() {
  export TEST_TMPDIR
  TEST_TMPDIR=$(mktemp -d)
  export TMUX=1
  export TURN_NAV_STATE_ROOT="$TEST_TMPDIR/state"
  export FAKE_TMUX_ROOT="$TEST_TMPDIR/fake"
  export FAKE_TMUX_SESSION_ID='session-1'
  export FAKE_TMUX_PANE_ID='%1'
  export TMUX_BIN="$TEST_TMPDIR/bin/tmux"
  source "$ROOT/tests/testlib/fake_tmux.sh"
  create_fake_tmux_bin "$TEST_TMPDIR/bin"
}

turn_nav_cmd() {
  bash "$ROOT/scripts/turn-nav" "$@"
}

setup_tmux_config_case() {
  export TURN_NAV_TMUX_SOCKET="turn-nav-test-$$-$RANDOM"
  tmux -L "$TURN_NAV_TMUX_SOCKET" -f /dev/null new-session -d -s turn-nav-test >/dev/null
}

tmux_config_cmd() {
  tmux -L "$TURN_NAV_TMUX_SOCKET" "$@"
}

cleanup_tmux_config_case() {
  if [[ -n "${TURN_NAV_TMUX_SOCKET:-}" ]]; then
    tmux -L "$TURN_NAV_TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
    unset TURN_NAV_TMUX_SOCKET
  fi
}

assert_pane_actions() {
  local pane_id=$1
  local actions=$2
  shift 2
  for expected in "$@"; do
    if ! printf '%s\n' "$actions" | grep -Fq "$expected"; then
      printf 'ASSERTION FAILED: expected pane %s actions to include [%s]\nactions:\n%s\n' "$pane_id" "$expected" "$actions" >&2
      exit 1
    fi
  done
}

test_completed_turns_exclude_live_prompt() {
  setup_case
  source "$ROOT/scripts/lib/parse-turns.sh"
  local content=$'❯ first\nanswer\n❯ second\nanswer\n❯ '
  local actual
  actual=$(turn_nav_completed_turn_lines "$content" | tr '\n' ',' | sed 's/,$//')
  assert_eq "1,3" "$actual" "completed turns should drop the live prompt"
}

test_baseline_is_clamped_by_visible_turn_count() {
  setup_case
  source "$ROOT/scripts/lib/parse-turns.sh"
  local content=$'❯ kept\nanswer\n❯ '
  local actual
  actual=$(turn_nav_visible_turn_lines "$content" 5 | wc -l | tr -d ' ')
  assert_eq "0" "$actual" "baseline should clamp to visible completed turn count"
}

test_activate_records_pane_baseline() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ before\nanswer\n❯ ' 0
  turn_nav_cmd activate
  local baseline
  baseline=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count")
  assert_eq "1" "$baseline" "activate should store completed turn count at activation time"
}

test_deactivate_clears_only_pane_state() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ ' 0
  turn_nav_cmd activate

  export FAKE_TMUX_PANE_ID='%2'
  fake_tmux_write_pane "%2" $'❯ two\nanswer\n❯ ' 0
  turn_nav_cmd activate

  export FAKE_TMUX_PANE_ID='%1'
  turn_nav_cmd deactivate

  local pane_one_exists pane_two_exists
  pane_one_exists=$(find "$TURN_NAV_STATE_ROOT/session-1" -maxdepth 1 -type d -name '%1' | wc -l | tr -d ' ')
  pane_two_exists=$(find "$TURN_NAV_STATE_ROOT/session-1" -maxdepth 1 -type d -name '%2' | wc -l | tr -d ' ')
  assert_eq "0" "$pane_one_exists" "deactivate should delete the active pane state directory"
  assert_eq "1" "$pane_two_exists" "deactivate should not touch other pane state"
}

test_navigation_issues_tmux_actions() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ new two\nanswer\n❯ ' 0

  turn_nav_cmd navigate up 1 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$actions" \
    "copy-mode" \
    "send-keys goto-line 2" \
    "send-keys start-of-line" \
    "send-keys search-backward ^[❯›]" \
    "send-keys select-line"
}

test_inactive_pane_ignores_navigation() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1
  if [[ -e "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn" ]]; then
    printf 'ASSERTION FAILED: inactive pane should not write current_turn\n' >&2
    exit 1
  fi
}

test_stale_current_turn_is_clamped_before_navigation() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ new two\nanswer\n❯ new three\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ only remaining\nanswer\n❯ ' 1

  turn_nav_cmd navigate up 1 %1

  local current status actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "1" "$current" "stale current_turn should clamp to the visible total before indexing"
  assert_eq "⇅ Turn 1/1" "$status" "status should reflect the clamped visible turn"
  assert_pane_actions "%1" "$actions" \
    "send-keys goto-line 2" \
    "send-keys search-backward ^[❯›]" \
    "send-keys select-line"
}

test_copy_mode_without_current_turn_uses_bottom_sentinel() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ new two\nanswer\n❯ ' 1

  turn_nav_cmd navigate up 1 %1

  local current status actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "2" "$current" "copy mode without saved current_turn should start from the bottom sentinel"
  assert_eq "⇅ Turn 2/2" "$status" "first up from copy mode should land on the newest visible turn"
  assert_pane_actions "%1" "$actions" \
    "send-keys goto-line 2" \
    "send-keys search-backward ^[❯›]" \
    "send-keys select-line"
}

test_two_panes_keep_navigation_state_isolated() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ pane one old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ pane one old\nanswer\n❯ pane one new a\nanswer\n❯ pane one new b\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 2 %1

  export FAKE_TMUX_PANE_ID='%2'
  fake_tmux_write_pane "%2" $'❯ pane two old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%2" $'❯ pane two old\nanswer\n❯ pane two new a\nanswer\n❯ pane two new b\nanswer\n❯ pane two new c\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %2

  local pane_one_turn pane_one_status pane_two_turn pane_two_status pane_one_actions pane_two_actions
  pane_one_turn=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  pane_one_status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  pane_two_turn=$(cat "$TURN_NAV_STATE_ROOT/session-1/%2/current_turn")
  pane_two_status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%2/last_status")
  pane_one_actions=$(fake_tmux_read_pane_actions "%1")
  pane_two_actions=$(fake_tmux_read_pane_actions "%2")
  assert_eq "1" "$pane_one_turn" "pane one should keep its own current_turn"
  assert_eq "⇅ Turn 1/2" "$pane_one_status" "pane one should keep its own status"
  assert_eq "3" "$pane_two_turn" "pane two should keep its own current_turn"
  assert_eq "⇅ Turn 3/3" "$pane_two_status" "pane two should keep its own status"
  assert_pane_actions "%1" "$pane_one_actions" "copy-mode" "send-keys goto-line 4"
  assert_pane_actions "%2" "$pane_two_actions" "copy-mode" "send-keys goto-line 2"
}

test_legacy_shims_delegate_to_turn_nav() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ before\nanswer\n❯ ' 0
  bash "$ROOT/scripts/setup-nav.sh"
  local baseline
  baseline=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count")
  assert_eq "1" "$baseline" "setup-nav shim should delegate to activate"
}

test_navigate_shim_delegates_to_turn_nav() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ new two\nanswer\n❯ ' 0

  bash "$ROOT/scripts/navigate-turn.sh" up 1 %1

  local current actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "2" "$current" "navigate-turn shim should delegate to navigate"
  assert_pane_actions "%1" "$actions" "copy-mode" "send-keys goto-line 2"
}

test_cleanup_shim_delegates_to_turn_nav() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ ' 0
  turn_nav_cmd activate

  bash "$ROOT/scripts/cleanup-nav.sh"

  local pane_exists
  pane_exists=$(find "$TURN_NAV_STATE_ROOT/session-1" -maxdepth 1 -type d -name '%1' | wc -l | tr -d ' ')
  assert_eq "0" "$pane_exists" "cleanup-nav shim should delegate to deactivate"
}

test_static_tmux_config_references_turn_nav_entrypoints() {
  assert_file_contains "$ROOT/tmux/turn-nav.conf" 'scripts/turn-nav navigate up 1 #{pane_id}'
  assert_file_contains "$ROOT/tmux/turn-nav.conf" 'scripts/turn-nav bottom #{pane_id}'
  assert_file_contains "$ROOT/tmux/turn-nav.conf" 'scripts/turn-nav status #{pane_id}'
}

test_static_tmux_config_preserves_preconfigured_root() {
  setup_tmux_config_case
  tmux_config_cmd set-option -g @turn_nav_root "/tmp/custom-turn-nav"
  tmux_config_cmd source-file "$ROOT/tmux/turn-nav.conf"

  local actual
  actual=$(tmux_config_cmd show-option -gv @turn_nav_root)
  cleanup_tmux_config_case
  assert_eq "/tmp/custom-turn-nav" "$actual" "tmux config should preserve a caller-provided @turn_nav_root"
}

test_static_tmux_config_sets_default_root_when_unset() {
  setup_tmux_config_case
  tmux_config_cmd source-file "$ROOT/tmux/turn-nav.conf"

  local actual
  actual=$(tmux_config_cmd show-option -gv @turn_nav_root)
  cleanup_tmux_config_case
  assert_eq "$HOME/.claude/plugins/turn-navigator" "$actual" "tmux config should set the default @turn_nav_root when unset"
}

test_static_tmux_config_status_right_is_idempotent() {
  setup_tmux_config_case
  tmux_config_cmd set-option -g status-right "BASE"
  tmux_config_cmd source-file "$ROOT/tmux/turn-nav.conf"
  tmux_config_cmd source-file "$ROOT/tmux/turn-nav.conf"

  local status_right occurrences
  status_right=$(tmux_config_cmd show-option -gv status-right)
  cleanup_tmux_config_case

  occurrences=$(printf '%s' "$status_right" | grep -oF 'scripts/turn-nav status #{pane_id}' | wc -l | tr -d ' ')
  assert_eq "1" "$occurrences" "tmux config should append the turn-nav status segment only once when re-sourced"
  assert_eq 'BASE#{?pane_in_mode,#[fg=colour0,bg=colour39,bold] #(sh -c "#{@turn_nav_root}/scripts/turn-nav status #{pane_id}") #[default],}' "$status_right" "tmux config should preserve existing status-right content and append the segment once"
}

run_all() {
  test_completed_turns_exclude_live_prompt
  test_baseline_is_clamped_by_visible_turn_count
  test_activate_records_pane_baseline
  test_deactivate_clears_only_pane_state
  test_navigation_issues_tmux_actions
  test_inactive_pane_ignores_navigation
  test_stale_current_turn_is_clamped_before_navigation
  test_copy_mode_without_current_turn_uses_bottom_sentinel
  test_two_panes_keep_navigation_state_isolated
  test_legacy_shims_delegate_to_turn_nav
  test_navigate_shim_delegates_to_turn_nav
  test_cleanup_shim_delegates_to_turn_nav
  test_static_tmux_config_references_turn_nav_entrypoints
  test_static_tmux_config_preserves_preconfigured_root
  test_static_tmux_config_sets_default_root_when_unset
  test_static_tmux_config_status_right_is_idempotent
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi
