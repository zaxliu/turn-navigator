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
    elif [[ ${1:-} == "-t" && ${3:-} == "-p" && ${4:-} == '#{pane_in_mode}' ]]; then
      cat "$(pane_file "$2" pane_in_mode)"
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
    ;;
  send-keys)
    pane_id=$(pane_id_from_args "$@")
    if [[ ${4:-} == "cancel" ]]; then
      printf '0' >"$(pane_file "$pane_id" pane_in_mode)"
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
