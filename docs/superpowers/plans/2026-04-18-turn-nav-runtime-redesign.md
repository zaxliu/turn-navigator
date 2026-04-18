# Turn Navigator Runtime Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current hook-driven tmux mutation model with a static tmux integration plus pane-scoped runtime state while preserving the existing turn navigation UX.

**Architecture:** Introduce a single `scripts/turn-nav` entrypoint with small shell libraries for state, parsing, and tmux interaction. Hooks become pane activation/deactivation only, tmux bindings move to a static config file, and regression tests use a fake `tmux` binary so the navigation state machine can be verified without an interactive tmux session.

**Tech Stack:** Bash, tmux, shell test harness with a fake tmux shim

---

## File Map

- Create: `scripts/turn-nav`
  Public CLI entrypoint for `activate`, `deactivate`, `navigate`, `bottom`, and `status`.
- Create: `scripts/lib/state.sh`
  Pane-scoped state path calculation and file IO helpers.
- Create: `scripts/lib/parse-turns.sh`
  Prompt parsing, completed-turn filtering, and baseline clamping.
- Create: `scripts/lib/tmux-nav.sh`
  tmux command wrappers, copy-mode checks, jump behavior, and status messaging.
- Create: `tests/testlib/fake_tmux.sh`
  Fake tmux executable generator and test fixture helpers.
- Create: `tests/turn_nav_test.sh`
  End-to-end shell regression tests for parsing, activation, navigation, and cleanup.
- Create: `tmux/turn-nav.conf`
  Static tmux bindings and status segment referencing `scripts/turn-nav`.
- Modify: `hooks/hooks.json`
  Replace setup/cleanup script calls with `turn-nav activate` and `turn-nav deactivate`; remove prompt-only activation message.
- Modify: `scripts/setup-nav.sh`
  Compatibility shim forwarding to `scripts/turn-nav activate`.
- Modify: `scripts/navigate-turn.sh`
  Compatibility shim forwarding to `scripts/turn-nav navigate|bottom`.
- Modify: `scripts/cleanup-nav.sh`
  Compatibility shim forwarding to `scripts/turn-nav deactivate`.
- Modify: `README.md`
  Document static tmux integration, new runtime model, and updated installation steps.
- Modify: `skills/help/SKILL.md`
  Keep repo-local help output aligned with the new tmux install contract.

### Task 1: Build the test harness and pure state/parsing helpers

**Files:**
- Create: `tests/testlib/fake_tmux.sh`
- Create: `tests/turn_nav_test.sh`
- Create: `scripts/lib/state.sh`
- Create: `scripts/lib/parse-turns.sh`

- [ ] **Step 1: Write the failing tests**

Create `tests/testlib/fake_tmux.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

create_fake_tmux_bin() {
  local bin_dir=$1
  mkdir -p "$bin_dir"
  cat >"$bin_dir/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=${FAKE_TMUX_ROOT:?}
log_file="$root/log"
mkdir -p "$root/panes"
printf '%s\n' "$*" >>"$log_file"

cmd=${1:-}
shift || true

pane_file() {
  printf '%s/panes/%s.%s\n' "$root" "$1" "$2"
}

case "$cmd" in
  display-message)
    if [[ ${1:-} == "-p" ]]; then
      case ${2:-} in
        '#{session_id}') printf '%s\n' "${FAKE_TMUX_SESSION_ID:?}" ;;
        '#{pane_id}') printf '%s\n' "${FAKE_TMUX_PANE_ID:?}" ;;
        *) exit 1 ;;
      esac
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{pane_in_mode}' ]]; then
      cat "$(pane_file "$2" pane_in_mode)"
    elif [[ ${1:-} == "-t" ]]; then
      printf '%s\n' "${3:-}" >>"$log_file"
    else
      exit 1
    fi
    ;;
  capture-pane)
    cat "$(pane_file "$2" content)"
    ;;
  copy-mode)
    printf '1' >"$(pane_file "$2" pane_in_mode)"
    ;;
  send-keys)
    pane=$2
    action=$4
    if [[ "$action" == "cancel" ]]; then
      printf '0' >"$(pane_file "$pane" pane_in_mode)"
    fi
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/tmux"
}

fake_tmux_write_pane() {
  local pane=$1
  local content=$2
  local in_mode=${3:-0}
  mkdir -p "${FAKE_TMUX_ROOT}/panes"
  printf '%s\n' "$content" >"${FAKE_TMUX_ROOT}/panes/${pane}.content"
  printf '%s' "$in_mode" >"${FAKE_TMUX_ROOT}/panes/${pane}.pane_in_mode"
}
```

Create `tests/turn_nav_test.sh`:

```bash
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

run_all() {
  test_completed_turns_exclude_live_prompt
  test_baseline_is_clamped_by_visible_turn_count
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/turn_nav_test.sh`

Expected: FAIL with `turn_nav_completed_turn_lines: command not found`

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/lib/state.sh`:

```bash
#!/usr/bin/env bash

turn_nav_tmux_bin() {
  printf '%s\n' "${TMUX_BIN:-tmux}"
}

turn_nav_state_root() {
  printf '%s\n' "${TURN_NAV_STATE_ROOT:-/tmp/turn-nav}"
}

turn_nav_in_tmux() {
  [[ -n "${TMUX:-}" ]]
}

turn_nav_current_session_id() {
  "$(turn_nav_tmux_bin)" display-message -p '#{session_id}'
}

turn_nav_current_pane_id() {
  "$(turn_nav_tmux_bin)" display-message -p '#{pane_id}'
}

turn_nav_pane_dir() {
  local pane_id=$1
  printf '%s/%s/%s\n' "$(turn_nav_state_root)" "$(turn_nav_current_session_id)" "$pane_id"
}

turn_nav_ensure_pane_dir() {
  mkdir -p "$(turn_nav_pane_dir "$1")"
}

turn_nav_write_state() {
  local pane_id=$1
  local name=$2
  local value=$3
  turn_nav_ensure_pane_dir "$pane_id"
  printf '%s' "$value" >"$(turn_nav_pane_dir "$pane_id")/$name"
}

turn_nav_read_state() {
  local pane_id=$1
  local name=$2
  local default_value=${3:-}
  local path
  path="$(turn_nav_pane_dir "$pane_id")/$name"
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    printf '%s' "$default_value"
  fi
}

turn_nav_delete_state() {
  local pane_id=$1
  local name=$2
  rm -f "$(turn_nav_pane_dir "$pane_id")/$name"
}

turn_nav_clear_pane_state() {
  local pane_id=$1
  rm -rf "$(turn_nav_pane_dir "$pane_id")"
}

turn_nav_is_active() {
  [[ "$(turn_nav_read_state "$1" active 0)" == "1" ]]
}
```

Create `scripts/lib/parse-turns.sh`:

```bash
#!/usr/bin/env bash

turn_nav_prompt_pattern() {
  printf '%s\n' "${TURN_NAV_PATTERN:-^[❯›]}"
}

turn_nav_completed_turn_lines() {
  local content=$1
  local pattern
  pattern=$(turn_nav_prompt_pattern)
  local lines=()
  mapfile -t lines < <(printf '%s\n' "$content" | grep -nE -- "$pattern" | cut -d: -f1 || true)
  local count=${#lines[@]}
  if (( count == 0 )); then
    return 0
  fi
  unset "lines[$((count - 1))]"
  printf '%s\n' "${lines[@]}"
}

turn_nav_visible_turn_lines() {
  local content=$1
  local baseline=$2
  local completed=()
  mapfile -t completed < <(turn_nav_completed_turn_lines "$content")
  local total=${#completed[@]}
  if (( baseline > total )); then
    baseline=$total
  fi
  printf '%s\n' "${completed[@]:$baseline}"
}

turn_nav_count_completed_turns() {
  local content=$1
  turn_nav_completed_turn_lines "$content" | sed '/^$/d' | wc -l | tr -d ' '
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/turn_nav_test.sh`

Expected:

```text
[no output]
```

Exit status: `0`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/state.sh scripts/lib/parse-turns.sh tests/testlib/fake_tmux.sh tests/turn_nav_test.sh
git commit -m "test: add turn parsing and pane state harness"
```

### Task 2: Implement the unified runtime entrypoint and pane-scoped navigation

**Files:**
- Create: `scripts/lib/tmux-nav.sh`
- Create: `scripts/turn-nav`
- Modify: `tests/turn_nav_test.sh`

- [ ] **Step 1: Write the failing tests**

Replace `tests/turn_nav_test.sh` with:

```bash
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

test_inactive_pane_ignores_navigation() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ one\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1
  if [[ -e "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn" ]]; then
    printf 'ASSERTION FAILED: inactive pane should not write current_turn\n' >&2
    exit 1
  fi
}

test_two_panes_do_not_share_current_turn() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ ' 0
  turn_nav_cmd activate
  fake_tmux_write_pane "%1" $'❯ old\nanswer\n❯ new one\nanswer\n❯ ' 0
  turn_nav_cmd navigate up 1 %1

  export FAKE_TMUX_PANE_ID='%2'
  fake_tmux_write_pane "%2" $'❯ another old\nanswer\n❯ ' 0
  turn_nav_cmd activate

  local pane_one pane_two
  pane_one=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/current_turn")
  pane_two=$(find "$TURN_NAV_STATE_ROOT/session-1/%2" -name current_turn -print | wc -l | tr -d ' ')
  assert_eq "1" "$pane_one" "pane one should keep its own current turn"
  assert_eq "0" "$pane_two" "pane two should not inherit pane one current turn"
}

run_all() {
  test_completed_turns_exclude_live_prompt
  test_baseline_is_clamped_by_visible_turn_count
  test_activate_records_pane_baseline
  test_inactive_pane_ignores_navigation
  test_two_panes_do_not_share_current_turn
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/turn_nav_test.sh test_activate_records_pane_baseline`

Expected: FAIL with `bash: .../scripts/turn-nav: No such file or directory`

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/lib/tmux-nav.sh`:

```bash
#!/usr/bin/env bash

turn_nav_capture_pane() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" capture-pane -t "$pane_id" -p -S -
}

turn_nav_pane_in_copy_mode() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{pane_in_mode}'
}

turn_nav_enter_copy_mode() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" copy-mode -t "$pane_id"
}

turn_nav_cancel_copy_mode() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X cancel
}

turn_nav_show_message() {
  local pane_id=$1
  local message=$2
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" "$message"
}

turn_nav_jump_to_line() {
  local pane_id=$1
  local goto_line=$2
  local pattern=$3
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X goto-line "$goto_line"
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X start-of-line
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X search-backward "$pattern"
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X select-line
}

turn_nav_status_text() {
  local current=$1
  local total=$2
  printf '⇅ Turn %s/%s' "$current" "$total"
}
```

Create `scripts/turn-nav`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/parse-turns.sh"
source "$SCRIPT_DIR/lib/tmux-nav.sh"

activate_cmd() {
  turn_nav_in_tmux || exit 0
  local pane_id=${1:-$(turn_nav_current_pane_id)}
  local content baseline
  content=$(turn_nav_capture_pane "$pane_id")
  baseline=$(turn_nav_count_completed_turns "$content")
  turn_nav_write_state "$pane_id" baseline_turn_count "$baseline"
  turn_nav_delete_state "$pane_id" current_turn
  turn_nav_delete_state "$pane_id" last_status
  turn_nav_write_state "$pane_id" active 1
}

deactivate_cmd() {
  turn_nav_in_tmux || exit 0
  local pane_id=${1:-$(turn_nav_current_pane_id)}
  turn_nav_clear_pane_state "$pane_id"
}

bottom_cmd() {
  turn_nav_in_tmux || exit 0
  local pane_id=$1
  turn_nav_delete_state "$pane_id" current_turn
  turn_nav_delete_state "$pane_id" last_status
  if [[ "$(turn_nav_pane_in_copy_mode "$pane_id")" == "1" ]]; then
    turn_nav_cancel_copy_mode "$pane_id"
  fi
}

navigate_cmd() {
  turn_nav_in_tmux || exit 0
  local direction=$1
  local count=$2
  local pane_id=$3

  turn_nav_is_active "$pane_id" || exit 0

  local content baseline total_lines
  content=$(turn_nav_capture_pane "$pane_id")
  baseline=$(turn_nav_read_state "$pane_id" baseline_turn_count 0)

  local lines=()
  mapfile -t lines < <(turn_nav_visible_turn_lines "$content" "$baseline")
  local total=${#lines[@]}
  if (( total == 0 )); then
    turn_nav_show_message "$pane_id" "No turns found"
    exit 0
  fi

  local in_copy current new
  in_copy=$(turn_nav_pane_in_copy_mode "$pane_id")
  if [[ "$in_copy" == "1" ]]; then
    current=$(turn_nav_read_state "$pane_id" current_turn "$((total + 1))")
  else
    current=$((total + 1))
  fi

  if [[ "$direction" == "up" ]]; then
    new=$((current - count))
    (( new < 1 )) && new=1
  else
    new=$((current + count))
    (( new > total )) && new=$total
  fi

  local status
  status=$(turn_nav_status_text "$new" "$total")
  turn_nav_write_state "$pane_id" current_turn "$new"
  turn_nav_write_state "$pane_id" last_status "$status"

  if [[ "$new" == "$current" ]]; then
    turn_nav_show_message "$pane_id" "$status"
    exit 0
  fi

  total_lines=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
  local target_line=${lines[$((new - 1))]}
  local goto_line=$((total_lines - target_line))
  (( goto_line < 0 )) && goto_line=0

  if [[ "$in_copy" == "0" ]]; then
    turn_nav_enter_copy_mode "$pane_id"
  fi

  turn_nav_jump_to_line "$pane_id" "$goto_line" "$(turn_nav_prompt_pattern)"
  turn_nav_show_message "$pane_id" "$status"
}

status_cmd() {
  turn_nav_in_tmux || exit 0
  local pane_id=$1
  turn_nav_is_active "$pane_id" || exit 0
  [[ "$(turn_nav_pane_in_copy_mode "$pane_id")" == "1" ]] || exit 0
  turn_nav_read_state "$pane_id" last_status ""
}

main() {
  local command=${1:-}
  case "$command" in
    activate) shift; activate_cmd "$@" ;;
    deactivate) shift; deactivate_cmd "$@" ;;
    navigate) shift; navigate_cmd "$@" ;;
    bottom) shift; bottom_cmd "$@" ;;
    status) shift; status_cmd "$@" ;;
    *)
      printf 'usage: %s {activate|deactivate|navigate|bottom|status}\n' "$0" >&2
      exit 1
      ;;
  esac
}

main "$@"
```

Make the new entrypoint executable:

```bash
chmod +x scripts/turn-nav
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/turn_nav_test.sh`

Expected:

```text
[no output]
```

Exit status: `0`

- [ ] **Step 5: Commit**

```bash
git add scripts/turn-nav scripts/lib/tmux-nav.sh tests/turn_nav_test.sh
git commit -m "feat: add unified pane-scoped turn-nav runtime"
```

### Task 3: Wire static tmux integration and compatibility shims

**Files:**
- Create: `tmux/turn-nav.conf`
- Modify: `hooks/hooks.json`
- Modify: `scripts/setup-nav.sh`
- Modify: `scripts/navigate-turn.sh`
- Modify: `scripts/cleanup-nav.sh`
- Modify: `tests/turn_nav_test.sh`

- [ ] **Step 1: Write the failing tests**

Replace `tests/turn_nav_test.sh` with:

```bash
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

test_legacy_shims_delegate_to_turn_nav() {
  setup_case
  fake_tmux_write_pane "%1" $'❯ before\nanswer\n❯ ' 0
  bash "$ROOT/scripts/setup-nav.sh"
  local baseline
  baseline=$(cat "$TURN_NAV_STATE_ROOT/session-1/%1/baseline_turn_count")
  assert_eq "1" "$baseline" "setup-nav shim should delegate to activate"
}

test_static_tmux_config_uses_turn_nav_entrypoint() {
  assert_file_contains "$ROOT/tmux/turn-nav.conf" 'scripts/turn-nav navigate up 1 #{pane_id}'
  assert_file_contains "$ROOT/tmux/turn-nav.conf" 'scripts/turn-nav bottom #{pane_id}'
  assert_file_contains "$ROOT/tmux/turn-nav.conf" 'scripts/turn-nav status #{pane_id}'
  assert_file_contains "$ROOT/tmux/turn-nav.conf" 'set-option -ag status-right'
}

run_all() {
  test_activate_records_pane_baseline
  test_deactivate_clears_only_pane_state
  test_legacy_shims_delegate_to_turn_nav
  test_static_tmux_config_uses_turn_nav_entrypoint
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/turn_nav_test.sh test_static_tmux_config_uses_turn_nav_entrypoint`

Expected: FAIL because `tmux/turn-nav.conf` does not exist

- [ ] **Step 3: Write the minimal implementation**

Create `tmux/turn-nav.conf`:

```tmux
set-option -gq @turn_nav_root "$HOME/.claude/plugins/turn-navigator"

bind-key -T root S-Up   run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate up 1 #{pane_id}'"
bind-key -T root S-Down run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate down 1 #{pane_id}'"
bind-key -T root M-Up   run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate up 5 #{pane_id}'"
bind-key -T root M-Down run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate down 5 #{pane_id}'"

bind-key -T copy-mode S-Up   run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate up 1 #{pane_id}'"
bind-key -T copy-mode S-Down run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate down 1 #{pane_id}'"
bind-key -T copy-mode M-Up   run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate up 5 #{pane_id}'"
bind-key -T copy-mode M-Down run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate down 5 #{pane_id}'"
bind-key -T copy-mode C-g    run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav bottom #{pane_id}'"
bind-key -T copy-mode q      run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav bottom #{pane_id}'"
bind-key -T copy-mode Escape run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav bottom #{pane_id}'"

bind-key -T copy-mode-vi S-Up   run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate up 1 #{pane_id}'"
bind-key -T copy-mode-vi S-Down run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate down 1 #{pane_id}'"
bind-key -T copy-mode-vi M-Up   run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate up 5 #{pane_id}'"
bind-key -T copy-mode-vi M-Down run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav navigate down 5 #{pane_id}'"
bind-key -T copy-mode-vi C-g    run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav bottom #{pane_id}'"
bind-key -T copy-mode-vi q      run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav bottom #{pane_id}'"
bind-key -T copy-mode-vi Escape run-shell "sh -c '#{@turn_nav_root}/scripts/turn-nav bottom #{pane_id}'"

set-option -gq @turn_nav_status '#{?pane_in_mode,#[fg=colour0,bg=colour39,bold] #(sh -c "#{@turn_nav_root}/scripts/turn-nav status #{pane_id}") #[default],}'
set-option -ag status-right '#{@turn_nav_status}'
```

Replace `hooks/hooks.json` with:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/turn-nav activate"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/turn-nav deactivate"
          }
        ]
      }
    ]
  }
}
```

Replace `scripts/setup-nav.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/turn-nav" activate "$@"
```

Replace `scripts/navigate-turn.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

direction=${1:-}
count=${2:-1}
pane_id=${3:-}

if [[ "$direction" == "bottom" ]]; then
  exec "$SCRIPT_DIR/turn-nav" bottom "${pane_id:-$(tmux display-message -p '#{pane_id}')}"
fi

exec "$SCRIPT_DIR/turn-nav" navigate "$direction" "$count" "${pane_id:-$(tmux display-message -p '#{pane_id}')}"
```

Replace `scripts/cleanup-nav.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/turn-nav" deactivate "$@"
```

Make the shims executable:

```bash
chmod +x scripts/setup-nav.sh scripts/navigate-turn.sh scripts/cleanup-nav.sh
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/turn_nav_test.sh`

Expected:

```text
[no output]
```

Exit status: `0`

- [ ] **Step 5: Commit**

```bash
git add tmux/turn-nav.conf hooks/hooks.json scripts/setup-nav.sh scripts/navigate-turn.sh scripts/cleanup-nav.sh tests/turn_nav_test.sh
git commit -m "feat: switch turn navigator to static tmux integration"
```

### Task 4: Update documentation and verify the full migration

**Files:**
- Modify: `README.md`
- Modify: `skills/help/SKILL.md`

- [ ] **Step 1: Write the failing documentation checks**

Replace `tests/turn_nav_test.sh` with:

```bash
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

test_readme_documents_static_tmux_installation() {
  assert_file_contains "$ROOT/README.md" 'tmux source-file tmux/turn-nav.conf'
  assert_file_contains "$ROOT/README.md" '@turn_nav_root'
  assert_file_contains "$ROOT/README.md" '/tmp/turn-nav/<tmux_session_id>/<pane_id>/'
}

test_help_skill_mentions_tmux_binding_requirement() {
  assert_file_contains "$ROOT/skills/help/SKILL.md" 'tmux bindings are installed'
  assert_file_contains "$ROOT/skills/help/SKILL.md" 'Warning: tmux not detected or bindings not installed.'
}

run_all() {
  test_deactivate_clears_only_pane_state
  test_readme_documents_static_tmux_installation
  test_help_skill_mentions_tmux_binding_requirement
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `bash tests/turn_nav_test.sh test_readme_documents_static_tmux_installation`

Expected: FAIL because `README.md` still describes hook-driven binding and `/tmp/turn-nav-<session_id>/`

- [ ] **Step 3: Write the minimal documentation updates**

Replace the install and runtime sections in `README.md` with:

```markdown
# Turn Navigator

A Claude Code plugin that lets you jump between conversation turns in tmux using keyboard shortcuts.

Works with both **Claude Code** (`❯`) and **Codex CLI** (`›`).

## Requirements

- tmux
- Turn Navigator hooks installed in Claude Code
- Turn Navigator tmux bindings sourced into your tmux config

## Keybindings

| Key | Action |
|-----|--------|
| Shift+Up | Previous turn |
| Shift+Down | Next turn |
| Alt+Up | Jump 5 turns up |
| Alt+Down | Jump 5 turns down |
| Ctrl+G | Exit to bottom |
| q / Escape | Exit browse mode |

A turn counter (for example `Turn 3/12`) appears in the status bar while browsing.

## Installation

Install the plugin:

```bash
/plugin install turn-navigator
```

Then source the tmux bindings:

```bash
tmux source-file tmux/turn-nav.conf
```

If the plugin is installed outside the default path, point tmux at it before sourcing:

```tmux
set-option -g @turn_nav_root "/absolute/path/to/turn_navigator"
source-file "/absolute/path/to/turn_navigator/tmux/turn-nav.conf"
```

## Configuration

Set `TURN_NAV_PATTERN` to customize the prompt pattern:

```bash
export TURN_NAV_PATTERN="^MyPrompt>"
```

Default pattern matches both Claude Code and Codex CLI prompts: `^[❯›]`

## Runtime model

- `SessionStart` calls `scripts/turn-nav activate`
- `SessionEnd` calls `scripts/turn-nav deactivate`
- tmux bindings stay static after install and call `scripts/turn-nav navigate`
- Pane-local state is stored in `/tmp/turn-nav/<tmux_session_id>/<pane_id>/`

## License

MIT
```

Replace `skills/help/SKILL.md` with:

```markdown
---
description: Show turn navigator keybindings
disable-model-invocation: true
---

Show the turn-navigator keybinding table:

| Key | Action |
|-----|--------|
| Shift+↑ | Previous turn |
| Shift+↓ | Next turn |
| Alt+↑ | Up 5 turns |
| Alt+↓ | Down 5 turns |
| Ctrl+G | Jump to bottom |
| q | Exit browse mode |

Then check `$TMUX`:
- If set: "Turn Navigator is available if tmux bindings are installed. Search pattern: ${TURN_NAV_PATTERN:-^[❯›]}"
- If empty: "Warning: tmux not detected or bindings not installed."

Keep it brief.
```

- [ ] **Step 4: Run the full verification suite**

Run:

```bash
bash tests/turn_nav_test.sh
for file in scripts/turn-nav scripts/lib/state.sh scripts/lib/parse-turns.sh scripts/lib/tmux-nav.sh scripts/setup-nav.sh scripts/navigate-turn.sh scripts/cleanup-nav.sh; do
  bash -n "$file"
done
```

Expected:

```text
[no output from tests]
[no output from bash -n]
```

Exit status: `0`

- [ ] **Step 5: Commit**

```bash
git add README.md skills/help/SKILL.md tests/turn_nav_test.sh
git commit -m "docs: document static turn navigator runtime"
```

## Self-Review

**Spec coverage:**  
Task 1 covers turn parsing, live prompt exclusion, baseline clamping, and pane-scoped state helpers.  
Task 2 covers the unified `scripts/turn-nav` entrypoint, `activate`, `deactivate`, `navigate`, `bottom`, `status`, and pane isolation.  
Task 3 covers static tmux integration, hook rewiring, and compatibility shims for legacy script names.  
Task 4 covers README/help updates and full verification.

**Placeholder scan:**  
No `TODO`, `TBD`, or deferred implementation placeholders remain in the tasks.

**Type consistency:**  
The plan consistently uses `baseline_turn_count`, `current_turn`, `last_status`, `active`, and the `turn_nav_*` function naming scheme across all tasks.
