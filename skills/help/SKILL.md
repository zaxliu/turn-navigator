---
description: Show turn navigator keybindings
disable-model-invocation: true
---

Show the turn-navigator keybinding table:

| Key | Action |
|-----|--------|
| Shift+↑ | Previous turn |
| Shift+↓ | Next turn |
| Alt+↑ | Up 5 turns |
| Alt+↓ | Down 5 turns |
| Ctrl+G | Jump to bottom |
| q | Exit browse mode |

Mention that browse mode opens a temporary right-side turn list pane showing `Turn x/y` and prompt first lines. The highlighted list item follows the main pane as the user jumps between turns.

Then check $TMUX env var:
- If set: "Turn Navigator is available. Claude Code installs tmux bindings automatically on SessionStart. Search pattern: ${TURN_NAV_PATTERN:-^(❯|›)}"
- If empty: "Warning: tmux not detected or bindings not installed."

Keep it brief.
