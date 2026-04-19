#!/usr/bin/env bash

turn_nav_capture_pane() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" capture-pane -t "$pane_id" -p -S -
}

turn_nav_pane_in_copy_mode() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{pane_in_mode}'
}

turn_nav_pane_exists() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{pane_id}' >/dev/null 2>&1
}

turn_nav_history_size() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{history_size}'
}

turn_nav_effective_bottom_line() {
  local pane_id=$1
  local history_size cursor_y
  history_size=$(turn_nav_history_size "$pane_id")
  cursor_y=$("$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{cursor_y}')
  if turn_nav_is_nonnegative_integer "$history_size" && turn_nav_is_nonnegative_integer "$cursor_y"; then
    printf '%s\n' "$((history_size + cursor_y + 1))"
  fi
}

turn_nav_enter_copy_mode() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" copy-mode -t "$pane_id"
}

turn_nav_cancel_copy_mode() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X cancel
}

turn_nav_select_pane() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" select-pane -t "$pane_id"
}

turn_nav_shell_quote() {
  local value=$1
  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

turn_nav_split_list_pane() {
  local pane_id=$1
  local list_file=$2
  local width=${TURN_NAV_LIST_WIDTH:-32}
  local quoted_file command
  quoted_file=$(turn_nav_shell_quote "$list_file")
  command="while :; do clear; cat $quoted_file 2>/dev/null; sleep 0.2; done"
  "$(turn_nav_tmux_bin)" split-window -t "$pane_id" -h -l "$width" -d -P -F '#{pane_id}' "$command"
}

turn_nav_kill_pane() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" kill-pane -t "$pane_id"
}

turn_nav_show_message() {
  local pane_id=$1
  local message=$2
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" "$message"
}

turn_nav_jump_to_line() {
  local pane_id=$1
  local goto_line=$2
  local top_cursor_down_count=${3:-}
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X goto-line "$goto_line"
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X start-of-line
  if [[ -n "$top_cursor_down_count" ]] && turn_nav_is_nonnegative_integer "$top_cursor_down_count"; then
    "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X top-line
    local i
    for ((i = 0; i < top_cursor_down_count; i++)); do
      "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X cursor-down
    done
  fi
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X start-of-line
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X select-line
}

turn_nav_status_text() {
  local current=$1
  local total=$2
  printf '⇅ Turn %s/%s' "$current" "$total"
}
