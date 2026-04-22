# Turn Navigator

A Claude Code plugin that lets you jump between conversation turns in tmux using keyboard shortcuts.

Works with both **Claude Code** (`❯`) and **Codex CLI** (`›`).

## Requirements

- tmux
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
The first navigation keypress also opens a temporary bottom turn list pane. The list shows the completed turns in the current session as `number + prompt first line`, and the highlighted row follows `Shift+Up/Down` and `Alt+Up/Down` as the main pane jumps.

## Installation

### Claude Code from GitHub

Add this repository as a Claude Code marketplace:

```bash
claude plugin marketplace add https://github.com/zaxliu/turn-navigator.git
```

Install the plugin from that marketplace:

```bash
claude plugin install turn-navigator@zaxliu
```

To install only for the current project instead of globally:

```bash
claude plugin marketplace add --scope project https://github.com/zaxliu/turn-navigator.git
claude plugin install --scope project turn-navigator@zaxliu
```

Verify that Claude Code sees the marketplace and plugin:

```bash
claude plugin marketplace list
claude plugin list
```

Claude Code installs the tmux bindings automatically on SessionStart, then activates the current pane.
If the plugin is loaded into an existing Claude Code session, the first navigation keypress also lazily activates that pane and includes existing scrollback turns.

If you installed into an already-running Claude Code session, restart that Claude Code session so the SessionStart hook can install the tmux bindings. In Claude Code you can also run `/plugin list` to confirm `turn-navigator` is enabled.

### Local development install

For a local checkout:

```bash
claude plugin marketplace add /absolute/path/to/turn_navigator
claude plugin install turn-navigator@zaxliu
```

If the checkout moves, remove and re-add the marketplace so Claude Code points at the new path.

### Manual tmux install

For manual install or non-Claude workflows, source the tmux bindings from this repository checkout:

```bash
tmux source-file tmux/turn-nav.conf
```

If the plugin is installed outside the default path, point tmux at it before sourcing:

```tmux
set-option -g @turn_nav_root "/absolute/path/to/turn_navigator"
source-file "/absolute/path/to/turn_navigator/tmux/turn-nav.conf"
```

For non-Claude workflows, the static tmux bindings can lazily activate a pane on first navigation.
Call `activate` explicitly only when a wrapper wants to mark the pane active before the first keypress:

```bash
scripts/turn-nav activate
```

Run `scripts/turn-nav deactivate` when that pane should stop responding to the static tmux bindings.

## Configuration

Set `TURN_NAV_PATTERN` to customize the prompt pattern:

```bash
export TURN_NAV_PATTERN="^MyPrompt>"
```

Default pattern matches both Claude Code and Codex CLI prompts: `^(❯|›)`

Codex CLI prompt lines are supported by the default pattern. Codex-only workflows can rely on lazy activation from the first navigation keypress, or use a wrapper that calls `scripts/turn-nav activate` / `scripts/turn-nav deactivate`.

The turn list opens at the bottom by default so the source pane keeps its original width while browsing. To restore the older right-side list pane:

```bash
export TURN_NAV_LIST_POSITION=right
```

Bottom list height is adaptive. By default it uses enough rows for the visible list, capped at 30% of the source pane height with a minimum of 5 rows. You can tune those limits:

```bash
export TURN_NAV_LIST_MAX_HEIGHT_PERCENT=30
export TURN_NAV_LIST_MIN_HEIGHT=5
```

## How it works

1. **SessionStart** calls `scripts/setup-nav.sh`, which installs the tmux bindings and marks the current pane active
2. tmux bindings stay static after install and call `scripts/turn-nav navigate`
3. If pane state is missing or activation hid all existing scrollback, the first navigation keypress initializes state for that pane
4. **SessionEnd** calls `scripts/turn-nav deactivate` to clear only the current pane state
5. **Shift+Up/Down** enters tmux copy-mode, jumps between completed user prompt lines, and keeps the temporary bottom turn list pane in sync

The list is implemented as a temporary tmux pane instead of a popup because tmux popups pause updates to the underlying pane while they are open. A bottom pane keeps the source pane width stable while the main pane and the turn list update together. `Ctrl+G`, `q`, `Escape`, and `deactivate` close the list pane and clear pane-local list state.

Pane-local state is stored in `/tmp/turn-nav/<tmux_session_id>/<pane_id>/` and cleaned up by `scripts/turn-nav deactivate`, which Claude Code runs from the `SessionEnd` hook.

## License

MIT
