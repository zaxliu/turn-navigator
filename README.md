# Turn Navigator

A Claude Code plugin that lets you jump between conversation turns in tmux using keyboard shortcuts.

Works with both **Claude Code** (`❯`) and **Codex CLI** (`›`).

## Requirements

- tmux
- Turn Navigator tmux bindings sourced into your tmux config
- Claude Code automatic activation requires the plugin hooks installed in Claude Code

## Keybindings

| Key | Action |
|-----|--------|
| Shift+Up | Previous turn |
| Shift+Down | Next turn |
| Alt+Up | Jump 5 turns up |
| Alt+Down | Jump 5 turns down |
| Ctrl+G | Exit to bottom |
| q / Escape | Exit browse mode |

A turn counter (for example `Turn 3/12`) appears in the status bar while browsing.

## Installation

Install the Claude Code plugin:

```bash
/plugin install turn-navigator
```

Or install from this repository:

```bash
/plugin marketplace add <owner>/turn_navigator
/plugin install turn-navigator@<marketplace>
```

Then source the tmux bindings from this repository checkout:

```bash
tmux source-file tmux/turn-nav.conf
```

If the plugin is installed outside the default path, point tmux at it before sourcing:

```tmux
set-option -g @turn_nav_root "/absolute/path/to/turn_navigator"
source-file "/absolute/path/to/turn_navigator/tmux/turn-nav.conf"
```

For non-Claude workflows, activate the pane before navigating:

```bash
scripts/turn-nav activate
```

Run `scripts/turn-nav deactivate` when that pane should stop responding to the static tmux bindings.

## Configuration

Set `TURN_NAV_PATTERN` to customize the prompt pattern:

```bash
export TURN_NAV_PATTERN="^MyPrompt>"
```

Default pattern matches both Claude Code and Codex CLI prompts: `^[❯›]`

Codex CLI prompt lines are supported by the default pattern. Codex-only workflows still need the pane to be activated, either by a wrapper that calls `scripts/turn-nav activate` / `scripts/turn-nav deactivate`, or manually with those commands.

## How it works

1. **SessionStart** calls `scripts/turn-nav activate` to mark the current pane active
2. tmux bindings stay static after install and call `scripts/turn-nav navigate`
3. **SessionEnd** calls `scripts/turn-nav deactivate` to clear only the current pane state
4. **Shift+Up/Down** enters tmux copy-mode and jumps between completed user prompt lines

Pane-local state is stored in `/tmp/turn-nav/<tmux_session_id>/<pane_id>/` and cleaned up by `scripts/turn-nav deactivate`, which Claude Code runs from the `SessionEnd` hook.

## License

MIT
