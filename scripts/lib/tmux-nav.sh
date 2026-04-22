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

turn_nav_pane_height() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{pane_height}'
}

turn_nav_cursor_y() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{cursor_y}'
}

turn_nav_copy_cursor_line() {
  local pane_id=$1
  "$(turn_nav_tmux_bin)" display-message -t "$pane_id" -p '#{copy_cursor_line}'
}

turn_nav_is_prompt_cursor_line() {
  local line=$1
  [[ "$line" =~ ^(❯|›)([[:space:]]|$) ]]
}

turn_nav_is_prompt_cursor_match() {
  local line=$1
  local search_text=$2
  turn_nav_is_prompt_cursor_line "$line" && [[ "$line" == *"$search_text"* ]]
}

turn_nav_effective_bottom_line() {
  local pane_id=$1
  local history_size pane_height cursor_y
  history_size=$(turn_nav_history_size "$pane_id")
  cursor_y=$(turn_nav_cursor_y "$pane_id")
  if turn_nav_is_nonnegative_integer "$history_size" && turn_nav_is_nonnegative_integer "$cursor_y"; then
    printf '%s\n' "$((history_size + cursor_y + 1))"
    return 0
  fi
  pane_height=$(turn_nav_pane_height "$pane_id" 2>/dev/null || true)
  if turn_nav_is_nonnegative_integer "$history_size" && turn_nav_is_nonnegative_integer "$pane_height" && (( pane_height >= 2 )); then
    printf '%s\n' "$((history_size + pane_height - 2))"
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

turn_nav_list_position() {
  case "${TURN_NAV_LIST_POSITION:-bottom}" in
    right) printf 'right\n' ;;
    bottom|*) printf 'bottom\n' ;;
  esac
}

turn_nav_split_list_pane() {
  local pane_id=$1
  local list_file=$2
  local list_height=${3:-}
  local quoted_file command
  quoted_file=$(turn_nav_shell_quote "$list_file")
  command="last=; while :; do current=\$(cksum $quoted_file 2>/dev/null || true); if [ \"\$current\" != \"\$last\" ]; then printf '\\033[H\\033[J'; cat $quoted_file 2>/dev/null; last=\"\$current\"; fi; sleep 0.2; done"
  if [[ "$(turn_nav_list_position)" == "right" ]]; then
    local width=${TURN_NAV_LIST_WIDTH:-32}
    "$(turn_nav_tmux_bin)" split-window -t "$pane_id" -h -l "$width" -d -P -F '#{pane_id}' "$command"
  else
    if ! turn_nav_is_nonnegative_integer "$list_height" || (( list_height < 1 )); then
      list_height=${TURN_NAV_LIST_MIN_HEIGHT:-5}
    fi
    "$(turn_nav_tmux_bin)" split-window -t "$pane_id" -v -l "$list_height" -d -P -F '#{pane_id}' "$command"
  fi
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
  local search_text=${4:-}
  local prefer_verified_goto=${5:-0}
  if [[ -n "$search_text" ]]; then
    local matched_line attempts found_prompt
    found_prompt=0
    if [[ "$prefer_verified_goto" == "1" ]]; then
      "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X goto-line "$goto_line"
      matched_line=$(turn_nav_copy_cursor_line "$pane_id" 2>/dev/null || true)
      if turn_nav_is_prompt_cursor_match "$matched_line" "$search_text"; then
        found_prompt=1
      fi
    fi
    if [[ "$found_prompt" == "0" ]]; then
      "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X goto-line 0
      "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X search-backward-text "$search_text"
      for ((attempts = 0; attempts < 5; attempts++)); do
        matched_line=$(turn_nav_copy_cursor_line "$pane_id" 2>/dev/null || true)
        if turn_nav_is_prompt_cursor_match "$matched_line" "$search_text"; then
          break
        fi
        "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X search-backward-text "$search_text"
      done
    fi
  else
    "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X goto-line "$goto_line"
  fi
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X start-of-line
  if [[ -z "$search_text" ]] && [[ -n "$top_cursor_down_count" ]] && turn_nav_is_nonnegative_integer "$top_cursor_down_count"; then
    "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X top-line
    local i
    for ((i = 0; i < top_cursor_down_count; i++)); do
      "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X cursor-down
    done
  fi
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X start-of-line
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X select-line
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X scroll-middle
  "$(turn_nav_tmux_bin)" send-keys -t "$pane_id" -X start-of-line
}

turn_nav_status_text() {
  local current=$1
  local total=$2
  printf '⇅ Turn %s/%s' "$current" "$total"
}
