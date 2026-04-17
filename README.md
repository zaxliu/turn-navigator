# Turn Navigator

A Claude Code plugin that lets you jump between conversation turns in tmux using keyboard shortcuts.

Works with both **Claude Code** (`❯`) and **Codex CLI** (`›`).

## Requirements

- tmux

## Keybindings

| Key | Action |
|-----|--------|
| Shift+Up | Previous turn |
| Shift+Down | Next turn |
| Alt+Up | Jump 5 turns up |
| Alt+Down | Jump 5 turns down |
| Ctrl+G | Exit to bottom |
| q / Escape | Exit browse mode |

A turn counter (e.g. `Turn 3/12`) appears in the status bar while browsing.

## Installation

```bash
/plugin install turn-navigator
```

Or install from this repository:

```bash
/plugin marketplace add <owner>/turn_navigator
/plugin install turn-navigator@<marketplace>
```

## Configuration

Set `TURN_NAV_PATTERN` to customize the prompt pattern:

```bash
export TURN_NAV_PATTERN="^MyPrompt>"
```

Default pattern matches both Claude Code and Codex CLI prompts: `^[❯›]`

## How it works

1. **SessionStart** hook binds tmux keys and sets up the status bar indicator
2. **Shift+Up/Down** enters tmux copy-mode and searches backward/forward for user prompt lines
3. **SessionEnd** hook unbinds keys and restores the original status bar

All state is stored in `/tmp/turn-nav-<session_id>/` and cleaned up automatically.

## License

MIT
