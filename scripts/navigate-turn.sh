#!/usr/bin/env bash
# navigate-turn.sh — jump to a specific conversation turn
# Usage: navigate-turn.sh up|down|bottom [count] [pane_id]
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

DIRECTION=$1
COUNT=${2:-1}
PANE_ID=${3:-%0}

[[ -z "$TMUX" ]] && exit 0

TMUX_SESSION_ID=$(tmux display-message -p '#{session_id}')
STATE_DIR="/tmp/turn-nav-${TMUX_SESSION_ID}"
P="${TURN_NAV_PATTERN:-^❯}"

# --- bottom: 退出浏览 ---
if [[ "$DIRECTION" == "bottom" ]]; then
  rm -f "$STATE_DIR/current-turn" "$STATE_DIR/status"
  tmux send-keys -t "$PANE_ID" -X cancel
  exit 0
fi

# --- 捕获 pane 全部内容，找出所有 turn 行号 ---
CONTENT=$(tmux capture-pane -t "$PANE_ID" -p -S -)
if [[ -z "$CONTENT" ]]; then
  tmux display-message "No content in pane"
  exit 0
fi
LINES=()
while IFS= read -r line; do
  LINES+=("$line")
done < <(echo "$CONTENT" | grep -n "$P" | cut -d: -f1)
TOTAL=${#LINES[@]}

if [[ $TOTAL -eq 0 ]]; then
  tmux display-message "No turns found"
  exit 0
fi

# --- 判断是否已在 copy-mode ---
IN_COPY=$(tmux display-message -t "$PANE_ID" -p '#{pane_in_mode}')

if [[ "$IN_COPY" -eq 0 ]]; then
  CURRENT=$((TOTAL + 1))
else
  CURRENT=$(cat "$STATE_DIR/current-turn" 2>/dev/null || echo "$((TOTAL + 1))")
fi

# --- 计算新位置（不 wrap） ---
if [[ "$DIRECTION" == "up" ]]; then
  NEW=$((CURRENT - COUNT))
  (( NEW < 1 )) && NEW=1
else
  NEW=$((CURRENT + COUNT))
  (( NEW > TOTAL )) && NEW=$TOTAL
fi

# 已到边界
if [[ "$NEW" -eq "$CURRENT" ]]; then
  echo "⇅ Turn $NEW/$TOTAL" > "$STATE_DIR/status"
  tmux display-message -t "$PANE_ID" "Turn $NEW/$TOTAL"
  exit 0
fi

echo "$NEW" > "$STATE_DIR/current-turn"

# --- 跳转 ---
# Always reset to bottom, then search backward to the Nth turn
if [[ "$IN_COPY" -eq 0 ]]; then
  tmux copy-mode -t "$PANE_ID"
fi

tmux send-keys -t "$PANE_ID" -X history-bottom
SEARCH_COUNT=$((TOTAL - NEW + 1))
for (( i=0; i<SEARCH_COUNT; i++ )); do
  tmux send-keys -t "$PANE_ID" -X search-backward "$P"
done
tmux send-keys -t "$PANE_ID" -X select-line

# --- 更新状态指示器 ---
echo "⇅ Turn $NEW/$TOTAL" > "$STATE_DIR/status"
tmux display-message -t "$PANE_ID" "Turn $NEW/$TOTAL"
