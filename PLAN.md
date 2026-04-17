# Turn Navigator - Claude Code Plugin 实现方案

## 概述

为 Claude Code 开发一个 Turn Navigator 插件，在 tmux 环境下通过快捷键在多轮对话的用户输入之间快速跳转。

仅支持 tmux，不支持 iTerm2 原生 marks。

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Ctrl+↑` | 上一轮用户输入 |
| `Ctrl+↓` | 下一轮用户输入 |
| `Alt+↑` | 上跳 5 轮 |
| `Alt+↓` | 下跳 5 轮 |
| `Ctrl+G` | 退出浏览模式，回到对话底部 |

退出浏览：按 `q` 或 `Ctrl+G` 退出 copy-mode。

## 插件目录结构

```
turn-navigator/
├── .claude-plugin/
│   └── plugin.json
├── hooks/
│   └── hooks.json
├── scripts/
│   ├── setup-nav.sh             # SessionStart: 绑定快捷键
│   └── cleanup-nav.sh           # SessionEnd: 恢复快捷键
├── skills/
│   └── help/
│       └── SKILL.md             # /turn-navigator:help
└── README.md
```

## 核心组件

### 1. setup-nav.sh

触发：`SessionStart`

```bash
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

# --- 备份原有绑定（保存为可直接 eval 的命令）---
for table in root "$COPY_TABLE"; do
  tmux list-keys -T "$table" 2>/dev/null \
    | grep -E 'C-Up|C-Down|M-Up|M-Down|C-g' \
    | sed 's/^/tmux /' \
    >> "$STATE_DIR/original-bindings" || true
done

# --- 搜索模式（可通过环境变量覆盖）---
P="${TURN_NAV_PATTERN:-❯}"

# --- 单步导航（root 表：从普通模式进入搜索）---
# 注意：bash 中 tmux 命令分隔符必须用 '\;' 而非 \;，否则 shell 会截断命令
tmux bind-key -T root C-Up   copy-mode '\;' send-keys -X search-backward "$P"
tmux bind-key -T root C-Down copy-mode '\;' send-keys -X search-forward  "$P"

# --- 单步导航（copy-mode 表：已在浏览模式中继续搜索）---
tmux bind-key -T "$COPY_TABLE" C-Up   send-keys -X search-backward "$P"
tmux bind-key -T "$COPY_TABLE" C-Down send-keys -X search-forward  "$P"

# --- 5 轮跳转（root 表）---
tmux bind-key -T root M-Up copy-mode '\;' \
  send-keys -X search-backward "$P" '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again
tmux bind-key -T root M-Down copy-mode '\;' \
  send-keys -X search-forward "$P" '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again

# --- 5 轮跳转（copy-mode 表）---
tmux bind-key -T "$COPY_TABLE" M-Up \
  send-keys -X search-backward "$P" '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again
tmux bind-key -T "$COPY_TABLE" M-Down \
  send-keys -X search-forward "$P" '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again '\;' \
  send-keys -X search-again

# --- 跳到底部（仅 copy-mode 表：退出浏览模式回到底部）---
tmux bind-key -T "$COPY_TABLE" C-g send-keys -X cancel

echo "$P" > "$STATE_DIR/active"
```

### 2. cleanup-nav.sh

触发：`SessionEnd`

```bash
#!/usr/bin/env bash
[[ -z "$TMUX" ]] && exit 0

TMUX_SESSION_ID=$(tmux display-message -p '#{session_id}')
STATE_DIR="/tmp/turn-nav-${TMUX_SESSION_ID}"
COPY_TABLE="copy-mode-vi"
[[ -f "$STATE_DIR/copy-table" ]] && COPY_TABLE=$(cat "$STATE_DIR/copy-table")

# 解绑 root 表
for key in C-Up C-Down M-Up M-Down; do
  tmux unbind-key -T root "$key" 2>/dev/null
done

# 解绑 copy-mode 表
for key in C-Up C-Down M-Up M-Down C-g; do
  tmux unbind-key -T "$COPY_TABLE" "$key" 2>/dev/null
done

# 恢复原有绑定
if [[ -f "$STATE_DIR/original-bindings" && -s "$STATE_DIR/original-bindings" ]]; then
  while IFS= read -r line; do
    eval "$line" 2>/dev/null || true
  done < "$STATE_DIR/original-bindings"
fi

rm -rf "$STATE_DIR"
```

### 3. hooks.json

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/setup-nav.sh"
          },
          {
            "type": "prompt",
            "prompt": "Turn Navigator plugin is active. Show the user a compact keybinding table:\n\n| Key | Action |\n|-----|--------|\n| Ctrl+↑ | Previous turn |\n| Ctrl+↓ | Next turn |\n| Alt+↑ | Up 5 turns |\n| Alt+↓ | Down 5 turns |\n| Ctrl+G | Jump to bottom |\n| q | Exit browse mode |\n\nKeep it to just the table, no extra explanation. Add a note: requires tmux."
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-nav.sh"
          }
        ]
      }
    ]
  }
}
```

### 4. plugin.json

```json
{
  "name": "turn-navigator",
  "description": "Navigate between conversation turns in tmux with keyboard shortcuts (Ctrl+Up/Down, Alt+Up/Down for 5-turn jump, Ctrl+G to bottom).",
  "version": "1.0.0",
  "author": {
    "name": "Lewis"
  },
  "keywords": ["navigation", "turns", "tmux"]
}
```

### 5. help Skill

`/turn-navigator:help`

```markdown
---
description: Show turn navigator keybindings
disable-model-invocation: true
---

Show the turn-navigator keybinding table:

| Key | Action |
|-----|--------|
| Ctrl+↑ | Previous turn |
| Ctrl+↓ | Next turn |
| Alt+↑ | Up 5 turns |
| Alt+↓ | Down 5 turns |
| Ctrl+G | Jump to bottom |
| q | Exit browse mode |

Then check $TMUX env var:
- If set: "Turn Navigator is active. Search pattern: ${TURN_NAV_PATTERN:-❯}"
- If empty: "Warning: tmux not detected. Turn Navigator requires tmux."

Keep it brief.
```

## 工作原理

1. **SessionStart** → `setup-nav.sh` 检测 vi/emacs 模式，备份原有 tmux 绑定，注入导航快捷键到 root 和 copy-mode 两张表
2. **SessionStart** → `prompt` hook 让 Claude 输出快捷键速查表
3. 用户按快捷键 → tmux 进入 `copy-mode` → `search-backward/forward` 搜索 `❯`（Claude Code 用户输入标记）
4. 已在 copy-mode 中 → 直接在 copy-mode 表中搜索，无需重复进入
5. `search-again` 重复搜索实现 5 轮批量跳转
6. `Ctrl+G` 在 copy-mode 中执行 `cancel`，退出回到底部
7. **SessionEnd** → `cleanup-nav.sh` 恢复原有绑定（使用 `eval` 回放备份），清理状态文件

## 技术风险

| 风险 | 应对 |
|------|------|
| `❯` 匹配 Claude 输出内容 | `TURN_NAV_PATTERN` 环境变量可自定义 |
| `❯` 是多字节 Unicode | tmux 3.1+ 支持良好；低版本可改用 ASCII 替代符 |
| 覆盖用户 tmux 绑定 | 按 session_id 备份（`sed 's/^/tmux /'` 格式），SessionEnd 用 `eval` 精确恢复 |
| 崩溃后 SessionEnd 未触发 | SessionStart 幂等清理残留 |
| 多会话并发 | 状态文件按 tmux session_id 隔离 |
| `search-again` 链式执行 | tmux `\;` 保证顺序执行，bash 中必须用 `'\;'` 转义 |
| Alt 键被 macOS 拦截 | iTerm2 需开启 "Option as Meta"；Terminal.app 需配置 |
| vi vs emacs copy-mode | 自动检测 `mode-keys` 选项，绑定到对应表 |

## 实现步骤

1. 创建插件骨架：目录 + plugin.json
2. 实现 setup-nav.sh
3. 实现 cleanup-nav.sh
4. 配置 hooks.json（command + prompt）
5. 实现 help skill
6. 本地测试：`claude --plugin-dir ./turn-navigator`
7. 编写 README.md
