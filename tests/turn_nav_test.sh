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

assert_file_not_contains() {
  local path=$1
  local needle=$2
  if grep -Fq "$needle" "$path"; then
    printf 'ASSERTION FAILED: did not expect [%s] in %s\n' "$needle" "$path" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local message=$3
  if ! printf '%s\n' "$haystack" | grep -Fq "$needle"; then
    printf 'ASSERTION FAILED: %s\nexpected to find: [%s]\nin:\n%s\n' "$message" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_empty() {
  local actual=$1
  local message=$2
  if [[ -n "$actual" ]]; then
    printf 'ASSERTION FAILED: %s\nactual: [%s]\n' "$message" "$actual" >&2
    exit 1
  fi
}

setup_case() {
  unset TURN_NAV_PATTERN
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

tmux_socket_wrapper() {
  local wrapper=$1
  cat >"$wrapper" <<'EOF'
#!/usr/bin/env bash
exec tmux -L "$TURN_NAV_TMUX_SOCKET" "$@"
EOF
  chmod +x "$wrapper"
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

assert_pane_actions_not() {
  local pane_id=$1
  local actions=$2
  shift 2
  for unexpected in "$@"; do
    if printf '%s\n' "$actions" | grep -Fq "$unexpected"; then
      printf 'ASSERTION FAILED: expected pane %s actions not to include [%s]\nactions:\n%s\n' "$pane_id" "$unexpected" "$actions" >&2
      exit 1
    fi
  done
}

assert_action_count() {
  local expected=$1
  local actions=$2
  local needle=$3
  local actual
  actual=$(printf '%s\n' "$actions" | grep -Fc "$needle" || true)
  assert_eq "$expected" "$actual" "expected [$needle] action count"
}

assert_action_after() {
  local actions=$1
  local first=$2
  local second=$3
  local first_line second_line
  first_line=$(printf '%s\n' "$actions" | grep -nFx "$first" | tail -1 | cut -d: -f1 || true)
  second_line=$(printf '%s\n' "$actions" | grep -nFx "$second" | tail -1 | cut -d: -f1 || true)
  if [[ -z "$first_line" || -z "$second_line" || "$second_line" -le "$first_line" ]]; then
    printf 'ASSERTION FAILED: expected action [%s] after [%s]\nactions:\n%s\n' "$second" "$first" "$actions" >&2
    exit 1
  fi
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

test_visible_turn_records_include_prompt_labels() {
  setup_case
  source "$ROOT/scripts/lib/parse-turns.sh"
  local content actual
  content=$'› first request\nanswer\n› second request with more detail\nanswer\n› '
  actual=$(turn_nav_visible_turn_records "$content" 0 | tr '\t' '|')
  assert_eq $'1|1|first request\n2|3|second request with more detail' "$actual" "visible turn records should include index, line, and prompt label"
}

test_invalid_prompt_pattern_is_treated_as_zero_matches() {
  setup_case
  source "$ROOT/scripts/lib/parse-turns.sh"
  local stdout stderr
  TURN_NAV_PATTERN='[' stdout=$(turn_nav_completed_turn_lines $'❯ one\nanswer\n❯ ' 2>"$TEST_TMPDIR/stderr")
  stderr=$(cat "$TEST_TMPDIR/stderr")
  assert_empty "$stdout" "invalid prompt pattern should produce no matches"
  assert_empty "$stderr" "invalid prompt pattern should not leak grep diagnostics"
}

test_default_prompt_pattern_does_not_match_claude_status_lines() {
  setup_case
  source "$ROOT/scripts/lib/parse-turns.sh"
  local content actual
  content=$'› first\nanswer\n• Ran command\n─ Worked for 1m\n  ❯ quoted prompt\n❯ second\nanswer\n› '
  actual=$(turn_nav_completed_turn_lines "$content" | tr '\n' ',' | sed 's/,$//')
  assert_eq "1,6" "$actual" "default prompt pattern should not match Claude status, separator, or quoted prompt lines"
}

test_claude_banner_limits_turns_to_current_session() {
  setup_case
  source "$ROOT/scripts/lib/parse-turns.sh"
  local content actual
  content=$'❯ source ~/.zshrc\ncompinit:527: no such file\n❯ happy claude --resume abc --dangerously-skip-permissions\nUsing Claude Code v2.1.92 from npm\n ▐▛███▜▌   Claude Code v2.1.92\n▝▜█████▛▘  Opus 4.6\n  ▘▘ ▝▝    ~/Documents/code/turn_navigator\n\n❯ analyze pane turns\nanswer\n❯ /reload-plugins\nreloaded\n❯ '
  actual=$(turn_nav_visible_turn_lines "$content" 0 | tr '\n' ',' | sed 's/,$//')
  assert_eq "9,11" "$actual" "Claude banner should exclude shell prompts before the current Claude session"
}

test_codex_banner_limits_turns_to_current_session() {
  setup_case
  source "$ROOT/scripts/lib/parse-turns.sh"
  local content actual
  content=$'❯ cd ../frameworks/autokernel\n❯ codex\n╭────────────────────────╮\n│ >_ OpenAI Codex (v0.121.0) │\n╰────────────────────────╯\n› ^C%\n❯\n❯ codex resume\n╭────────────────────────╮\n│ >_ OpenAI Codex (v0.121.0) │\n╰────────────────────────╯\n› 最近在聊什么\nanswer\n› /learn\nlearned\n› '
  actual=$(turn_nav_visible_turn_lines "$content" 0 | tr '\n' ',' | sed 's/,$//')
  assert_eq "12,14" "$actual" "Codex banner should exclude shell prompts and interrupted prior Codex sessions"
}

test_corrupt_numeric_navigation_state_does_not_abort() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ new two\nanswer\n❯ ' 1
  printf 'abc' >"$TURN_NAV_STATE_ROOT/session-1/%1/current_turn"

  local stderr current status
  turn_nav_cmd navigate up 1 %1 2>"$TEST_TMPDIR/stderr"
  stderr=$(cat "$TEST_TMPDIR/stderr")
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  assert_empty "$stderr" "corrupt current_turn should not abort with shell diagnostics"
  assert_eq "2" "$current" "corrupt current_turn should reset to the bottom sentinel behavior"
  assert_eq "⇅ Turn 2/2" "$status" "status should reflect safe current_turn reset"
}

test_corrupt_baseline_state_is_treated_as_inactive_navigation() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ new two\nanswer\n❯ ' 0
  printf 'nope' >"$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count"

  local stderr current_exists
  turn_nav_cmd navigate up 1 %1 2>"$TEST_TMPDIR/stderr"
  stderr=$(cat "$TEST_TMPDIR/stderr")
  current_exists=$(find "$TURN_NAV_STATE_ROOT/session-1/%1" -name current_turn -print | wc -l | tr -d ' ')
  assert_empty "$stderr" "corrupt baseline_turn_count should not leak shell diagnostics"
  assert_eq "0" "$current_exists" "corrupt baseline_turn_count should not navigate"
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
    "send-keys select-line"
  assert_pane_actions_not "%1" "$actions" "send-keys search-backward"
}

test_navigation_returns_to_line_start_after_selecting_line() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two with a long prompt that may wrap in copy mode\nanswer\n❯ ' 0

  turn_nav_cmd navigate up 1 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_action_after "$actions" "send-keys select-line" "send-keys start-of-line"
}

test_first_navigation_searches_prompt_when_cursor_is_above_pane_bottom() {
  setup_case
  fake_tmux_write_pane "%1" $'intro\nmore intro\n❯ newest completed\nanswer line 1\nanswer line 2\n❯\nfooter 1\nfooter 2\nfooter 3\nfooter 4' 0
  fake_tmux_set_pane_position "%1" 7 0
  fake_tmux_set_pane_height "%1" 5

  turn_nav_cmd navigate up 1 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$actions" "send-keys goto-line 0" "send-keys search-backward-text ❯ newest completed"
  assert_pane_actions_not "%1" "$actions" "send-keys goto-line 5"
}

test_navigation_opens_and_renders_turn_list_pane() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ three\nanswer\n❯ ' 0

  turn_nav_cmd navigate up 1 %1

  local list_pane list_file list_content source_actions list_actions
  list_pane=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/list_pane_id")
  list_file=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/list_file")
  list_content=$(cat "$list_file")
  source_actions=$(fake_tmux_read_pane_actions "%1")
  list_actions=$(fake_tmux_read_pane_actions "$list_pane")

  assert_eq "%2" "$list_pane" "navigation should record the created list pane id"
  assert_contains "$list_content" "Turn 3/3" "list should show current progress"
  assert_contains "$list_content" "  1  one" "list should show older turns"
  assert_contains "$list_content" "> 3  three" "list should highlight the current turn"
  assert_pane_actions "%1" "$source_actions" "split-window -v -l 5 %2" "select-pane"
  assert_pane_actions "$list_pane" "$list_actions" "list-pane-command"
}

test_turn_list_pane_height_is_capped_to_thirty_percent_of_source_pane() {
  setup_case
  local content=$'❯ one\nanswer'
  local i
  for ((i = 2; i <= 20; i++)); do
    content+=$'\n'"❯ turn $i"$'\nanswer'
  done
  content+=$'\n❯ '
  fake_tmux_write_pane "%1" "$content" 0
  fake_tmux_set_pane_height "%1" 20

  turn_nav_cmd navigate up 1 %1

  local source_actions list_content
  source_actions=$(fake_tmux_read_pane_actions "%1")
  list_content=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/turn-list")
  assert_pane_actions "%1" "$source_actions" "split-window -v -l 6 %2"
  assert_contains "$list_content" "Turn 20/20" "list should still show current progress when height is capped"
  assert_contains "$list_content" "  ..." "height-capped list should show elision"
}

test_turn_list_pane_can_use_legacy_right_position() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ three\nanswer\n❯ ' 0

  TURN_NAV_LIST_POSITION=right turn_nav_cmd navigate up 1 %1

  local source_actions
  source_actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$source_actions" "split-window -h -l 32 %2"
}

test_navigation_updates_existing_turn_list_pane_highlight() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ three\nanswer\n❯ ' 0

  turn_nav_cmd navigate up 1 %1
  turn_nav_cmd navigate up 1 %1

  local list_pane list_file list_content source_actions
  list_pane=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/list_pane_id")
  list_file=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/list_file")
  list_content=$(cat "$list_file")
  source_actions=$(fake_tmux_read_pane_actions "%1")

  assert_eq "%3" "$list_pane" "second navigation should reopen the list pane after restoring full-width jump coordinates"
  assert_contains "$list_content" "Turn 2/3" "list should update current progress"
  assert_contains "$list_content" "> 2  two" "list should move the highlighted turn"
  assert_action_count "1" "$source_actions" "split-window -v -l 5 %2"
  assert_action_count "1" "$source_actions" "split-window -v -l 5 %3"
}

test_bottom_closes_turn_list_pane() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1

  turn_nav_cmd bottom %1

  local actions list_state_exists
  actions=$(fake_tmux_read_pane_actions "%2")
  list_state_exists=$(find "$TURN_NAV_STATE_ROOT/session-1/%1" -name list_pane_id -print | wc -l | tr -d ' ')
  assert_eq "0" "$list_state_exists" "bottom should clear the list pane id state"
  assert_pane_actions "%2" "$actions" "kill-pane"
}

test_deactivate_closes_turn_list_pane() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1

  turn_nav_cmd deactivate %1

  local actions pane_exists
  actions=$(fake_tmux_read_pane_actions "%2")
  pane_exists=$(find "$TURN_NAV_STATE_ROOT/session-1" -maxdepth 1 -type d -name '%1' | wc -l | tr -d ' ')
  assert_eq "0" "$pane_exists" "deactivate should clear the source pane state directory"
  assert_pane_actions "%2" "$actions" "kill-pane"
}

test_stale_turn_list_pane_is_replaced() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ three\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1
  rm -f "$FAKE_TMUX_ROOT/panes/%2.pane_in_mode"

  turn_nav_cmd navigate up 1 %1

  local list_pane source_actions
  list_pane=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/list_pane_id")
  source_actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "%3" "$list_pane" "navigation should replace a stale list pane id"
  assert_pane_actions "%1" "$source_actions" "split-window -v -l 5 %2" "split-window -v -l 5 %3"
}

test_navigation_does_not_search_backward_from_exact_prompt_line() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ source ~/.zshrc\ncompinit:527: no such file\n❯ happy claude --resume abc\nUsing Claude Code v2.1.92 from npm\n ▐▛███▜▌   Claude Code v2.1.92\n\n❯ first claude turn\nanswer\n❯ second claude turn\nanswer\n❯ ' 0

  turn_nav_cmd navigate up 2 %1

  local current actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "1" "$current" "jumping to the first Claude turn should target the first visible turn"
  assert_pane_actions "%1" "$actions" "copy-mode" "send-keys goto-line 4" "send-keys start-of-line" "send-keys select-line"
  assert_pane_actions_not "%1" "$actions" "send-keys search-backward"
}

test_navigation_uses_tmux_cursor_bottom_not_capture_footer() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ first\nanswer\n❯ second\nanswer\n❯ third\nanswer\n❯\nfooter 1\nfooter 2\nfooter 3\nfooter 4\nfooter 5' 0
  fake_tmux_set_pane_position "%1" 5 1

  turn_nav_cmd navigate up 1 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$actions" "send-keys goto-line 2" "send-keys select-line"
  assert_pane_actions_not "%1" "$actions" "send-keys goto-line 7" "send-keys top-line" "send-keys cursor-down"
}

test_effective_bottom_line_prefers_cursor_when_height_includes_footer() {
  setup_case
  source "$ROOT/scripts/lib/state.sh"
  source "$ROOT/scripts/lib/tmux-nav.sh"
  fake_tmux_write_pane "%1" $'❯ first\nanswer\n❯ second\nanswer\n❯\nfooter 1\nfooter 2\nfooter 3\nfooter 4' 0
  fake_tmux_set_pane_position "%1" 5 1
  fake_tmux_set_pane_height "%1" 10

  local actual
  actual=$(turn_nav_effective_bottom_line "%1")

  assert_eq "7" "$actual" "effective bottom should follow the live prompt cursor, not footer rows"
}

test_navigation_preserves_turn_count_when_list_split_truncates_capture() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ three\nanswer\n❯ ' 0
  fake_tmux_write_pane_after_split "%1" $'❯ one\nanswer\n❯ '

  turn_nav_cmd navigate up 1 %1

  local current status list_content actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  list_content=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/turn-list")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "3" "$current" "navigation should keep the selected turn from the pre-split capture"
  assert_eq "⇅ Turn 3/3" "$status" "status should keep the pre-split turn count"
  assert_contains "$list_content" "Turn 3/3" "list should keep the pre-split turn count"
  assert_action_after "$actions" "send-keys select-line" "split-window -v -l 5 %2"
}

test_navigation_does_not_add_older_history_revealed_while_browsing() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ current one\nanswer\n❯ current two\nanswer\n❯ ' 0
  fake_tmux_write_pane_after_split "%1" $'❯ older revealed\nanswer\n❯ current one\nanswer\n❯ current two\nanswer\n❯ '

  turn_nav_cmd navigate up 1 %1
  turn_nav_cmd navigate down 1 %1

  local baseline current status list_content actions
  baseline=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count")
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  list_content=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/turn-list")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "1" "$baseline" "browsing should fold newly revealed older history into the baseline"
  assert_eq "2" "$current" "down from newest turn should stay on the newest visible turn"
  assert_eq "⇅ Turn 2/2" "$status" "status should keep the original visible turn count"
  assert_contains "$list_content" "Turn 2/2" "list should keep the original visible turn count"
  assert_file_not_contains "$TURN_NAV_STATE_ROOT/session-1/%1/turn-list" "older revealed"
  assert_action_count "1" "$actions" "split-window -v -l 5 %2"
}

test_navigation_searches_prompt_when_already_browsing() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ three\nanswer\n❯ ' 0
  fake_tmux_set_pane_position "%1" 6 72
  fake_tmux_set_pane_height "%1" 75

  turn_nav_cmd navigate up 1 %1
  turn_nav_cmd navigate up 1 %1

  local current actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "2" "$current" "second up while browsing should move to the previous turn"
  assert_pane_actions "%1" "$actions" "send-keys search-backward-text ❯ two"
}

test_browsing_navigation_prefers_verified_goto_before_ambiguous_search() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ three\nanswer\n❯ ' 0
  fake_tmux_set_pane_position "%1" 6 72
  fake_tmux_set_pane_height "%1" 75

  turn_nav_cmd navigate up 1 %1
  fake_tmux_set_copy_cursor_lines "%1" '❯ two'
  turn_nav_cmd navigate up 1 %1

  local current actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "2" "$current" "second up while browsing should move to the previous turn"
  assert_pane_actions "%1" "$actions" "send-keys goto-line 6"
  assert_pane_actions_not "%1" "$actions" "send-keys search-backward-text ❯ two"
}

test_browsing_boundary_rejumps_current_turn_after_layout_restore() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ ' 0
  fake_tmux_set_pane_position "%1" 4 72
  fake_tmux_set_pane_height "%1" 75

  turn_nav_cmd navigate up 2 %1
  fake_tmux_set_copy_cursor_lines "%1" '❯ one'
  turn_nav_cmd navigate up 1 %1

  local current actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "1" "$current" "up at the oldest turn should keep the current turn"
  assert_action_count "2" "$actions" "send-keys select-line"
  assert_pane_actions_not "%1" "$actions" "send-keys search-backward-text ❯ one"
}

test_search_navigation_retries_until_match_is_prompt_line() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ target prompt\nanswer\n  ❯ target prompt\n• Ran printf "❯ target prompt"\n❯ next\nanswer\n❯ ' 0
  fake_tmux_set_pane_position "%1" 10 5
  fake_tmux_set_pane_height "%1" 12
  fake_tmux_set_copy_cursor_lines "%1" '  ❯ target prompt' '• Ran printf "❯ target prompt"' '❯ target prompt'

  turn_nav_cmd navigate up 2 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_action_count "3" "$actions" "send-keys search-backward-text ❯ target prompt"
}

test_search_navigation_does_not_apply_history_top_fallback() {
  setup_case
  fake_tmux_write_pane "%1" $'intro\nmore intro\n❯ first\nanswer\n❯ second\nanswer\n❯ third\nanswer\n❯ ' 0
  fake_tmux_set_pane_position "%1" 10 5
  fake_tmux_set_pane_height "%1" 12

  turn_nav_cmd navigate up 3 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$actions" "send-keys goto-line 0" "send-keys search-backward-text ❯ first"
  assert_pane_actions_not "%1" "$actions" "send-keys top-line" "send-keys cursor-down"
}

test_search_navigation_anchors_short_prompt_labels_to_prompt_marker() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ done\nanswer\n---Progress: say "done" to advance\n❯ skip\nState machine: DONE/SKIPPED\n❯ next\nanswer\n❯ ' 0
  fake_tmux_set_pane_position "%1" 10 5
  fake_tmux_set_pane_height "%1" 12

  turn_nav_cmd navigate up 2 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$actions" "send-keys goto-line 0" "send-keys search-backward-text ❯ skip"
  assert_pane_actions_not "%1" "$actions" "send-keys search-backward-text skip"
}

test_search_navigation_uses_short_prompt_prefix_for_long_labels() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ “如果 profiler 抓到一个 rmsnorm 的 bf16 kernel，容差是 atol=0.1。这意味着优化后的 kernel 每个元素允许偏差多大？”\nanswer\n这就是为什么代码写成循环累减 remaining_frac，而不是一次性算\n❯ next\nanswer\n❯ ' 0
  fake_tmux_set_pane_position "%1" 10 5
  fake_tmux_set_pane_height "%1" 12

  turn_nav_cmd navigate up 2 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$actions" "send-keys search-backward-text ❯ “如果 profiler 抓到一个 rmsnorm 的 bf16 kernel"
  assert_pane_actions_not "%1" "$actions" "search-backward-text ❯ “如果 profiler 抓到一个 rmsnorm 的 bf16 kernel，容差是 atol=0.1。这意味着优化后的 kernel 每个元素允许偏差多大？”"
}

test_search_navigation_keeps_utf8_prompt_prefix_readable() {
  setup_case
  local prompt=$'› 现在当前这个pane （TurnNavigator window3）左pane的navigation右坏掉了'
  fake_tmux_write_pane "%1" "${prompt}"$'\nanswer\n› next\nanswer\n› ' 0
  fake_tmux_set_pane_position "%1" 10 5
  fake_tmux_set_pane_height "%1" 12

  TURN_NAV_SEARCH_TEXT_WIDTH=41 turn_nav_cmd navigate up 2 %1

  local actions
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_pane_actions "%1" "$actions" "send-keys search-backward-text › 现在当前这个pane （TurnNavigat"
  assert_pane_actions_not "%1" "$actions" "âº"
}

test_navigation_adjusts_cursor_when_target_is_on_history_top_page() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ first\nanswer\n❯ second\nanswer\n❯ third\nanswer\n❯\nfooter 1\nfooter 2\nfooter 3\nfooter 4\nfooter 5' 0
  fake_tmux_set_pane_position "%1" 5 6

  turn_nav_cmd navigate up 2 %1

  local current actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "2" "$current" "navigation should target a turn on the history top page"
  assert_pane_actions "%1" "$actions" "send-keys goto-line 5" "send-keys top-line" "send-keys select-line"
  assert_action_count "2" "$actions" "send-keys cursor-down"
  assert_pane_actions_not "%1" "$actions" "send-keys cursor-up"
  assert_pane_actions_not "%1" "$actions" "send-keys goto-line 9"
}

test_missing_pane_state_lazy_activates_on_navigation() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ ' 0

  turn_nav_cmd navigate up 1 %1

  local active baseline current actions
  active=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/active")
  baseline=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count")
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "1" "$active" "navigation should lazily activate panes without state"
  assert_eq "0" "$baseline" "lazy activation should include existing scrollback turns"
  assert_eq "2" "$current" "first lazy up navigation should land on newest completed turn"
  assert_pane_actions "%1" "$actions" "copy-mode" "send-keys goto-line 2"
}

test_first_navigation_after_activation_can_use_existing_scrollback() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ two\nanswer\n❯ ' 0
  turn_nav_cmd activate

  turn_nav_cmd navigate up 1 %1

  local baseline current actions
  baseline=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count")
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "0" "$baseline" "first navigation should include existing scrollback when activation hid every turn"
  assert_eq "2" "$current" "first up navigation should land on newest completed scrollback turn"
  assert_pane_actions "%1" "$actions" "copy-mode" "send-keys goto-line 2"
}

test_stale_current_turn_is_clamped_before_navigation() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ new two\nanswer\n❯ new three\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ only remaining\nanswer\n❯ ' 1
  fake_tmux_set_copy_cursor_lines "%1" '❯ only remaining'

  turn_nav_cmd navigate up 1 %1

  local current status actions
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "1" "$current" "stale current_turn should clamp to the visible total before indexing"
  assert_eq "⇅ Turn 1/1" "$status" "status should reflect the clamped visible turn"
  assert_pane_actions "%1" "$actions" \
    "send-keys goto-line 2" \
    "send-keys select-line"
  assert_pane_actions_not "%1" "$actions" "send-keys search-backward"
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
    "send-keys search-backward-text ❯ new two" \
    "send-keys select-line"
}

test_codex_resume_session_ignores_activation_baseline_before_banner() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ cd ../frameworks/autokernel\n❯ codex\n╭────────────────────────╮\n│ >_ OpenAI Codex (v0.121.0) │\n╰────────────────────────╯\n› ^C%\n❯\n❯ codex resume\n╭────────────────────────╮\n│ >_ OpenAI Codex (v0.121.0) │\n╰────────────────────────╯\n› first resumed turn\nanswer\n› second resumed turn\nanswer\n› third resumed turn\nanswer\n› ' 0
  turn_nav_cmd activate
  printf '6' >"$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count"
  printf '2' >"$TURN_NAV_STATE_ROOT/session-1/%1/current_turn"
  printf '⇅ Turn 2/2' >"$TURN_NAV_STATE_ROOT/session-1/%1/last_status"

  turn_nav_cmd navigate up 1 %1

  local baseline current status actions
  baseline=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count")
  current=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  status=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/last_status")
  actions=$(fake_tmux_read_pane_actions "%1")
  assert_eq "0" "$baseline" "session boundary should clamp stale activation baseline to the current Codex session"
  assert_eq "3" "$current" "navigation should include all completed turns in the resumed Codex session"
  assert_eq "⇅ Turn 3/3" "$status" "status should count the full resumed Codex session"
  assert_pane_actions "%1" "$actions" "copy-mode" "send-keys goto-line 2" "send-keys select-line"
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

test_install_tmux_subcommand_loads_static_bindings_for_current_plugin_root() {
  setup_tmux_config_case
  TEST_TMPDIR=$(mktemp -d)
  tmux_socket_wrapper "$TEST_TMPDIR/tmux"

  TMUX=1 TMUX_BIN="$TEST_TMPDIR/tmux" turn_nav_cmd install-tmux

  local root status_right binding
  root=$(tmux_config_cmd show-option -gv @turn_nav_root)
  status_right=$(tmux_config_cmd show-option -gv status-right)
  binding=$(tmux_config_cmd list-keys -T root S-Up)
  cleanup_tmux_config_case

  assert_eq "$ROOT" "$root" "install-tmux should point @turn_nav_root at the current plugin checkout"
  assert_file_contains "$ROOT/hooks/hooks.json" 'scripts/setup-nav.sh'
  if ! printf '%s\n' "$status_right" | grep -Fq 'scripts/turn-nav status #{pane_id}'; then
    printf 'ASSERTION FAILED: install-tmux should install status segment\nstatus-right: [%s]\n' "$status_right" >&2
    exit 1
  fi
  if ! printf '%s\n' "$binding" | grep -Fq 'scripts/turn-nav navigate up 1 #{pane_id}'; then
    printf 'ASSERTION FAILED: install-tmux should install root S-Up binding\nbinding: [%s]\n' "$binding" >&2
    exit 1
  fi
}

test_readme_documents_static_tmux_installation() {
  assert_file_contains "$ROOT/README.md" 'tmux source-file tmux/turn-nav.conf'
  assert_file_contains "$ROOT/README.md" '@turn_nav_root'
  assert_file_contains "$ROOT/README.md" '/tmp/turn-nav/<tmux_session_id>/<pane_id>/'
  assert_file_contains "$ROOT/README.md" 'tmux bindings stay static after install'
  assert_file_contains "$ROOT/README.md" 'Claude Code installs the tmux bindings automatically on SessionStart'
  assert_file_contains "$ROOT/README.md" 'first navigation keypress also lazily activates that pane'
  assert_file_contains "$ROOT/README.md" 'Claude Code automatic activation'
  assert_file_contains "$ROOT/README.md" 'Codex CLI prompt lines are supported by the default pattern'
  assert_file_contains "$ROOT/README.md" 'For non-Claude workflows, the static tmux bindings can lazily activate a pane'
  # shellcheck disable=SC2016
  assert_file_contains "$ROOT/README.md" 'cleaned up by `scripts/turn-nav deactivate`'
  assert_file_contains "$ROOT/README.md" 'temporary bottom turn list pane'
  assert_file_contains "$ROOT/README.md" 'TURN_NAV_LIST_POSITION=right'
  assert_file_contains "$ROOT/README.md" 'TURN_NAV_LIST_MAX_HEIGHT_PERCENT'
  assert_file_contains "$ROOT/README.md" 'tmux popups pause updates to the underlying pane'
  assert_file_not_contains "$ROOT/README.md" 'Turn Navigator hooks installed in Claude Code'
  assert_file_not_contains "$ROOT/README.md" 'cleaned up when the pane session ends'
}

test_help_skill_mentions_tmux_binding_requirement() {
  assert_file_contains "$ROOT/skills/help/SKILL.md" 'Claude Code installs tmux bindings automatically on SessionStart'
  assert_file_contains "$ROOT/skills/help/SKILL.md" 'Warning: tmux not detected or bindings not installed.'
  assert_file_contains "$ROOT/skills/help/SKILL.md" 'opens a temporary bottom turn list pane'
}

run_all() {
  test_completed_turns_exclude_live_prompt
  test_baseline_is_clamped_by_visible_turn_count
  test_visible_turn_records_include_prompt_labels
  test_invalid_prompt_pattern_is_treated_as_zero_matches
  test_default_prompt_pattern_does_not_match_claude_status_lines
  test_claude_banner_limits_turns_to_current_session
  test_codex_banner_limits_turns_to_current_session
  test_corrupt_numeric_navigation_state_does_not_abort
  test_corrupt_baseline_state_is_treated_as_inactive_navigation
  test_activate_records_pane_baseline
  test_deactivate_clears_only_pane_state
  test_navigation_issues_tmux_actions
  test_navigation_returns_to_line_start_after_selecting_line
  test_first_navigation_searches_prompt_when_cursor_is_above_pane_bottom
  test_navigation_opens_and_renders_turn_list_pane
  test_navigation_updates_existing_turn_list_pane_highlight
  test_bottom_closes_turn_list_pane
  test_deactivate_closes_turn_list_pane
  test_stale_turn_list_pane_is_replaced
  test_navigation_does_not_search_backward_from_exact_prompt_line
  test_navigation_uses_tmux_cursor_bottom_not_capture_footer
  test_effective_bottom_line_prefers_cursor_when_height_includes_footer
  test_navigation_preserves_turn_count_when_list_split_truncates_capture
  test_navigation_does_not_add_older_history_revealed_while_browsing
  test_navigation_searches_prompt_when_already_browsing
  test_browsing_navigation_prefers_verified_goto_before_ambiguous_search
  test_browsing_boundary_rejumps_current_turn_after_layout_restore
  test_search_navigation_retries_until_match_is_prompt_line
  test_search_navigation_does_not_apply_history_top_fallback
  test_search_navigation_anchors_short_prompt_labels_to_prompt_marker
  test_search_navigation_uses_short_prompt_prefix_for_long_labels
  test_search_navigation_keeps_utf8_prompt_prefix_readable
  test_navigation_adjusts_cursor_when_target_is_on_history_top_page
  test_missing_pane_state_lazy_activates_on_navigation
  test_first_navigation_after_activation_can_use_existing_scrollback
  test_stale_current_turn_is_clamped_before_navigation
  test_copy_mode_without_current_turn_uses_bottom_sentinel
  test_codex_resume_session_ignores_activation_baseline_before_banner
  test_two_panes_keep_navigation_state_isolated
  test_legacy_shims_delegate_to_turn_nav
  test_navigate_shim_delegates_to_turn_nav
  test_cleanup_shim_delegates_to_turn_nav
  test_static_tmux_config_references_turn_nav_entrypoints
  test_static_tmux_config_preserves_preconfigured_root
  test_static_tmux_config_sets_default_root_when_unset
  test_static_tmux_config_status_right_is_idempotent
  test_install_tmux_subcommand_loads_static_bindings_for_current_plugin_root
  test_readme_documents_static_tmux_installation
  test_help_skill_mentions_tmux_binding_requirement
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi
