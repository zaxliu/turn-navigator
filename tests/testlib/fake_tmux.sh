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
touch "$log_file"
printf '%s\n' "$*" >>"$log_file"

cmd=${1:-}
shift || true

pane_file() {
  printf '%s/panes/%s.%s\n' "$root" "$1" "$2"
}

append_action() {
  local pane_id=$1
  shift
  printf '%s\n' "$*" >>"$(pane_file "$pane_id" actions)"
}

next_pane_id() {
  local path="$root/next_pane"
  local next
  if [[ -f "$path" ]]; then
    next=$(cat "$path")
  else
    next=2
  fi
  printf '%%%s\n' "$next"
  printf '%s' "$((next + 1))" >"$path"
}

pane_id_from_args() {
  local pane_id=
  while (($#)); do
    case $1 in
      -t)
        pane_id=${2:-}
        break
        ;;
    esac
    shift
  done
  printf '%s\n' "$pane_id"
}

split_window_summary_from_args() {
  local orientation=unknown
  local size=unknown
  while (($#)); do
    case $1 in
      -h|-v)
        orientation=$1
        ;;
      -l)
        size=${2:-unknown}
        shift
        ;;
    esac
    shift
  done
  printf '%s -l %s\n' "$orientation" "$size"
}

case "$cmd" in
  display-message)
    if [[ ${1:-} == "-p" ]]; then
      case ${2:-} in
        '#{session_id}')
          printf '%s\n' "${FAKE_TMUX_SESSION_ID:?}"
          ;;
        '#{pane_id}')
          printf '%s\n' "${FAKE_TMUX_PANE_ID:?}"
          ;;
        *)
          exit 1
          ;;
      esac
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{pane_id}' ]]; then
      if [[ -f "$(pane_file "$2" pane_in_mode)" ]]; then
        printf '%s\n' "$2"
      else
        exit 1
      fi
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{pane_in_mode}' ]]; then
      cat "$(pane_file "$2" pane_in_mode)"
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{history_size}' ]]; then
      cat "$(pane_file "$2" history_size)"
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{pane_height}' ]]; then
      cat "$(pane_file "$2" pane_height)"
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{cursor_y}' ]]; then
      cat "$(pane_file "$2" cursor_y)"
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{copy_cursor_line}' ]]; then
      if [[ -f "$(pane_file "$2" copy_cursor_lines)" ]]; then
        IFS= read -r first <"$(pane_file "$2" copy_cursor_lines)" || first=
        printf '%s\n' "$first"
        tail -n +2 "$(pane_file "$2" copy_cursor_lines)" >"$(pane_file "$2" copy_cursor_lines.tmp)" || true
        mv "$(pane_file "$2" copy_cursor_lines.tmp)" "$(pane_file "$2" copy_cursor_lines)"
      elif [[ -f "$(pane_file "$2" copy_cursor_line)" ]]; then
        cat "$(pane_file "$2" copy_cursor_line)"
      fi
    elif [[ ${1:-} == "-t" ]]; then
      printf '%s\n' "${3:-}" >>"$log_file"
    else
      exit 1
    fi
    ;;
  capture-pane)
    pane_id=$(pane_id_from_args "$@")
    cat "$(pane_file "$pane_id" content)"
    ;;
  copy-mode)
    pane_id=$(pane_id_from_args "$@")
    printf '1' >"$(pane_file "$pane_id" pane_in_mode)"
    append_action "$pane_id" "copy-mode"
    ;;
  split-window)
    pane_id=$(pane_id_from_args "$@")
    split_summary=$(split_window_summary_from_args "$@")
    new_pane=$(next_pane_id)
    if [[ -f "$(pane_file "$pane_id" content_after_split)" ]]; then
      cp "$(pane_file "$pane_id" content_after_split)" "$(pane_file "$pane_id" content)"
      line_count=$(wc -l <"$(pane_file "$pane_id" content)" | tr -d ' ')
      printf '%s' "$((line_count - 1))" >"$(pane_file "$pane_id" history_size)"
    fi
    printf '' >"$(pane_file "$new_pane" content)"
    printf '0' >"$(pane_file "$new_pane" pane_in_mode)"
    printf '0' >"$(pane_file "$new_pane" history_size)"
    printf '0' >"$(pane_file "$new_pane" cursor_y)"
    printf '3' >"$(pane_file "$new_pane" pane_height)"
    append_action "$pane_id" "split-window $split_summary $new_pane"
    append_action "$new_pane" "list-pane-command"
    printf '%s\n' "$new_pane"
    ;;
  select-pane)
    pane_id=$(pane_id_from_args "$@")
    append_action "$pane_id" "select-pane"
    ;;
  kill-pane)
    pane_id=$(pane_id_from_args "$@")
    append_action "$pane_id" "kill-pane"
    rm -f "$(pane_file "$pane_id" content)" "$(pane_file "$pane_id" pane_in_mode)" "$(pane_file "$pane_id" history_size)" "$(pane_file "$pane_id" cursor_y)"
    ;;
  set-option|source-file)
    ;;
  send-keys)
    pane_id=$(pane_id_from_args "$@")
    action=${4:-}
    case "$action" in
      cancel)
      printf '0' >"$(pane_file "$pane_id" pane_in_mode)"
        append_action "$pane_id" "send-keys cancel"
        ;;
      goto-line|search-backward|search-backward-text)
        append_action "$pane_id" "send-keys $action ${5:-}"
        ;;
      start-of-line|select-line|cursor-up|cursor-down|top-line)
        append_action "$pane_id" "send-keys $action"
        ;;
    esac
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
  local line_count cursor_y history_size
  line_count=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
  cursor_y=0
  history_size=$((line_count - 1))
  printf '%s' "$history_size" >"${FAKE_TMUX_ROOT}/panes/${pane}.history_size"
  printf '%s' "$cursor_y" >"${FAKE_TMUX_ROOT}/panes/${pane}.cursor_y"
}

fake_tmux_set_pane_position() {
  local pane=$1
  local history_size=$2
  local cursor_y=$3
  mkdir -p "${FAKE_TMUX_ROOT}/panes"
  printf '%s' "$history_size" >"${FAKE_TMUX_ROOT}/panes/${pane}.history_size"
  printf '%s' "$cursor_y" >"${FAKE_TMUX_ROOT}/panes/${pane}.cursor_y"
}

fake_tmux_set_pane_height() {
  local pane=$1
  local pane_height=$2
  mkdir -p "${FAKE_TMUX_ROOT}/panes"
  printf '%s' "$pane_height" >"${FAKE_TMUX_ROOT}/panes/${pane}.pane_height"
}

fake_tmux_set_copy_cursor_lines() {
  local pane=$1
  shift
  mkdir -p "${FAKE_TMUX_ROOT}/panes"
  printf '%s\n' "$@" >"${FAKE_TMUX_ROOT}/panes/${pane}.copy_cursor_lines"
}

fake_tmux_write_pane_after_split() {
  local pane=$1
  local content=$2
  mkdir -p "${FAKE_TMUX_ROOT}/panes"
  printf '%s\n' "$content" >"${FAKE_TMUX_ROOT}/panes/${pane}.content_after_split"
}

fake_tmux_read_pane_actions() {
  local pane=$1
  local path="${FAKE_TMUX_ROOT}/panes/${pane}.actions"
  if [[ -f "$path" ]]; then
    cat "$path"
  fi
}
