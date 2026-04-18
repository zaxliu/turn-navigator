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
P="${TURN_NAV_PATTERN:-^[❯›]}"

# --- bottom: 退出浏览 ---
if [[ "$DIRECTION" == "bottom" ]]; then
  rm -f "$STATE_DIR/current-turn" "$STATE_DIR/status"
  tmux send-keys -t "$PANE_ID" -X cancel
  exit 0
fi

# --- 捕获 pane 全部内容，找出当前 session 的 turn ---
CONTENT=$(tmux capture-pane -t "$PANE_ID" -p -S -)
if [[ -z "$CONTENT" ]]; then
  tmux display-message "No content in pane"
  exit 0
fi
SKIP=$(cat "$STATE_DIR/baseline" 2>/dev/null || echo "0")
ALL_LINES=()
while IFS= read -r line; do
  ALL_LINES+=("$line")
done < <(echo "$CONTENT" | grep -n "$P" | cut -d: -f1)

# Skip turns from previous sessions (clamp if scrollback was truncated)
ALL_TOTAL=${#ALL_LINES[@]}
if (( SKIP > ALL_TOTAL )); then
  SKIP=$ALL_TOTAL
fi
LINES=("${ALL_LINES[@]:$SKIP}")
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
# Use goto-line for instant jump (no flashing), then single search to snap
TARGET_LINE=${LINES[$((NEW - 1))]}
TOTAL_LINES=$(echo "$CONTENT" | wc -l | tr -d ' ')
# goto-line counts from bottom (0=last line)
GOTO=$((TOTAL_LINES - TARGET_LINE))
(( GOTO < 0 )) && GOTO=0

if [[ "$IN_COPY" -eq 0 ]]; then
  tmux copy-mode -t "$PANE_ID"
fi

# Instant jump to approximate position, then snap to exact turn
tmux send-keys -t "$PANE_ID" -X goto-line "$GOTO"
tmux send-keys -t "$PANE_ID" -X start-of-line
tmux send-keys -t "$PANE_ID" -X search-backward "$P"
tmux send-keys -t "$PANE_ID" -X select-line

# --- 更新状态指示器 ---
echo "⇅ Turn $NEW/$TOTAL" > "$STATE_DIR/status"
tmux display-message -t "$PANE_ID" "Turn $NEW/$TOTAL"
