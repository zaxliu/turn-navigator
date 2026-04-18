#!/usr/bin/env bash
[[ -z "$TMUX" ]] && exit 0

TMUX_SESSION_ID=$(tmux display-message -p '#{session_id}')
STATE_DIR="/tmp/turn-nav-${TMUX_SESSION_ID}"
COPY_TABLE="copy-mode-vi"
[[ -f "$STATE_DIR/copy-table" ]] && COPY_TABLE=$(cat "$STATE_DIR/copy-table")

# 解绑 root 表
for key in S-Up S-Down M-Up M-Down; do
  tmux unbind-key -T root "$key" 2>/dev/null
done

# 解绑 copy-mode 表
for key in S-Up S-Down M-Up M-Down C-g q Escape; do
  tmux unbind-key -T "$COPY_TABLE" "$key" 2>/dev/null
done

# 恢复原有绑定
if [[ -f "$STATE_DIR/original-bindings" && -s "$STATE_DIR/original-bindings" ]]; then
  while IFS= read -r line; do
    eval "$line" 2>/dev/null || true
  done < "$STATE_DIR/original-bindings"
fi

# --- 恢复状态栏 ---
if [[ -f "$STATE_DIR/original-status-right" ]]; then
  tmux set-option -g status-right "$(cat "$STATE_DIR/original-status-right")"
fi

if [[ -f "$STATE_DIR/original-status-right-length" ]]; then
  tmux set-option -g status-right-length "$(cat "$STATE_DIR/original-status-right-length")"
fi

if [[ -f "$STATE_DIR/original-status-interval" ]]; then
  tmux set-option -g status-interval "$(cat "$STATE_DIR/original-status-interval")"
fi

# Preserve baseline for resume, clean up everything else
BASELINE_BAK=""
[[ -f "$STATE_DIR/baseline" ]] && BASELINE_BAK=$(cat "$STATE_DIR/baseline")
rm -rf "$STATE_DIR"
if [[ -n "$BASELINE_BAK" ]]; then
  mkdir -p "$STATE_DIR"
  echo "$BASELINE_BAK" > "$STATE_DIR/baseline"
fi
