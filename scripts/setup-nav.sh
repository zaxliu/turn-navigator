#!/usr/bin/env bash
[[ -z "$TMUX" ]] && exit 0

# --- 崩溃恢复 + 幂等：清理上次残留 ---
TMUX_SESSION_ID=$(tmux display-message -p '#{session_id}')
STATE_DIR="/tmp/turn-nav-${TMUX_SESSION_ID}"
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"

# --- 检测 copy-mode 类型 ---
if tmux show-options -gv mode-keys 2>/dev/null | grep -q vi; then
  COPY_TABLE="copy-mode-vi"
else
  COPY_TABLE="copy-mode"
fi
echo "$COPY_TABLE" > "$STATE_DIR/copy-table"

# --- 备份原有绑定 ---
for table in root "$COPY_TABLE"; do
  tmux list-keys -T "$table" 2>/dev/null \
    | grep -E 'S-Up|S-Down|M-Up|M-Down|C-g| q | Escape ' \
    | sed 's/^/tmux /' \
    >> "$STATE_DIR/original-bindings" || true
done

# --- 脚本路径 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAV="$SCRIPT_DIR/navigate-turn.sh"

# --- 绑定快捷键（root 表：从普通模式触发）---
# #{pane_id} 在按键时动态解析为当前 pane，确保 capture-pane 定位正确
tmux bind-key -T root S-Up   run-shell "$NAV up 1 #{pane_id}"
tmux bind-key -T root S-Down run-shell "$NAV down 1 #{pane_id}"
tmux bind-key -T root M-Up   run-shell "$NAV up 5 #{pane_id}"
tmux bind-key -T root M-Down run-shell "$NAV down 5 #{pane_id}"

# --- 绑定快捷键（copy-mode 表：浏览模式中继续跳转）---
tmux bind-key -T "$COPY_TABLE" S-Up   run-shell "$NAV up 1 #{pane_id}"
tmux bind-key -T "$COPY_TABLE" S-Down run-shell "$NAV down 1 #{pane_id}"
tmux bind-key -T "$COPY_TABLE" M-Up   run-shell "$NAV up 5 #{pane_id}"
tmux bind-key -T "$COPY_TABLE" M-Down run-shell "$NAV down 5 #{pane_id}"
tmux bind-key -T "$COPY_TABLE" C-g    run-shell "$NAV bottom 0 #{pane_id}"

# --- 拦截 copy-mode 退出键，清除状态文件后再退出 ---
tmux bind-key -T "$COPY_TABLE" q      run-shell "rm -f $STATE_DIR/current-turn $STATE_DIR/status; tmux send-keys -t #{pane_id} -X cancel"
tmux bind-key -T "$COPY_TABLE" Escape run-shell "rm -f $STATE_DIR/current-turn $STATE_DIR/status; tmux send-keys -t #{pane_id} -X cancel"

# --- 状态栏指示器 ---
# 备份原始 status-right
ORIG_STATUS_RIGHT=$(tmux show-options -gv status-right 2>/dev/null)
echo "$ORIG_STATUS_RIGHT" > "$STATE_DIR/original-status-right"

ORIG_STATUS_RIGHT_LEN=$(tmux show-options -gv status-right-length 2>/dev/null)
echo "$ORIG_STATUS_RIGHT_LEN" > "$STATE_DIR/original-status-right-length"

ORIG_STATUS_INTERVAL=$(tmux show-options -gv status-interval 2>/dev/null)
echo "$ORIG_STATUS_INTERVAL" > "$STATE_DIR/original-status-interval"

# 加长 status-right 容纳指示器
NEW_LEN=$((ORIG_STATUS_RIGHT_LEN + 20))
tmux set-option -g status-right-length "$NEW_LEN"

# 1 秒刷新，确保指示器及时出现/消失
tmux set-option -g status-interval 1

# 指示器：copy-mode 时读取状态文件，否则隐藏
# #(cat ...) 每秒执行一次，读取 navigate-turn.sh 写入的状态
INDICATOR="#{?pane_in_mode,#[fg=colour0#,bg=colour39#,bold] #(cat $STATE_DIR/status 2>/dev/null) #[default] ,}"

# 前置到原始 status-right
tmux set-option -g status-right "${INDICATOR}${ORIG_STATUS_RIGHT}"

echo "active" > "$STATE_DIR/active"
