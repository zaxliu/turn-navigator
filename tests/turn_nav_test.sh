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

test_state_helpers_manage_pane_scoped_files() {
  setup_case
  source "$ROOT/scripts/lib/state.sh"

  local pane_dir
  pane_dir=$(turn_nav_pane_dir "%1")
  assert_eq "$TURN_NAV_STATE_ROOT/session-1/%1" "$pane_dir" "pane dir should be scoped by session and pane"

  turn_nav_write_state "%1" baseline_turn_count "3"
  assert_eq "3" "$(turn_nav_read_state "%1" baseline_turn_count)" "write/read should round-trip state values"

  turn_nav_write_state "%1" current_turn "2"
  turn_nav_delete_state "%1" current_turn
  assert_eq "" "$(turn_nav_read_state "%1" current_turn)" "delete should remove one state file"

  turn_nav_write_state "%1" active "1"
  turn_nav_write_state "%1" last_status "Turn 2/3"
  turn_nav_clear_pane_state "%1"

  if [[ -e "$TURN_NAV_STATE_ROOT/session-1/%1" ]]; then
    printf 'ASSERTION FAILED: clear should remove the entire pane state directory\n' >&2
    exit 1
  fi
}

run_all() {
  test_completed_turns_exclude_live_prompt
  test_baseline_is_clamped_by_visible_turn_count
  test_state_helpers_manage_pane_scoped_files
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi
