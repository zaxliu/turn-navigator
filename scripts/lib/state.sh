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

turn_nav_is_nonnegative_integer() {
  [[ ${1:-} =~ ^[0-9]+$ ]]
}
