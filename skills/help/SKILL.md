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

Then check $TMUX env var:
- If set: "Turn Navigator is available if tmux bindings are installed. Search pattern: ${TURN_NAV_PATTERN:-^[❯›]}"
- If empty: "Warning: tmux not detected or bindings not installed."

Keep it brief.
