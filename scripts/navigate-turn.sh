#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TMUX_CMD=${TMUX_BIN:-tmux}

direction=${1:-}
count=${2:-1}
pane_id=${3:-}

if [[ -z "$pane_id" ]]; then
  pane_id=$("$TMUX_CMD" display-message -p '#{pane_id}')
fi

if [[ "$direction" == "bottom" ]]; then
  exec "$SCRIPT_DIR/turn-nav" bottom "$pane_id"
fi

exec "$SCRIPT_DIR/turn-nav" navigate "$direction" "$count" "$pane_id"
