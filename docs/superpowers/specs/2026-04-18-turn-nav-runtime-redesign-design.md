# Turn Navigator Runtime Redesign

**Date:** 2026-04-18
**Status:** Draft approved in chat, captured for review
**Scope:** Redefine plugin runtime behavior without changing the user-facing navigation workflow

## Goal

Keep the existing turn-browsing behavior and keybindings while removing the current runtime pattern of globally mutating tmux configuration on every session start and end.

## Current Problems

The current implementation couples three concerns that should be independent:

1. tmux global configuration ownership
2. pane-local navigation state
3. turn parsing and navigation logic

That coupling creates the failure modes already visible in recent changes:

- repeated `SessionStart` can overwrite the real "original" tmux configuration snapshot
- `SessionEnd` restores or unbinds global tmux state even when other active panes still rely on it
- navigation state is tracked at tmux session scope instead of pane scope
- baseline logic has oscillated between turn count and line count because the turn model is not explicit
- scrollback truncation and resumed sessions are difficult to reason about because state is derived from unstable line offsets

## Design Principles

- Preserve the existing browsing workflow: `Shift+Up/Down`, `Alt+Up/Down`, `Ctrl+G`, `q`, `Escape`, and turn counter display
- Stop modifying tmux global bindings and `status-right` at runtime
- Track runtime state per pane, not per tmux session
- Define a turn as one completed user prompt
- Exclude the current live prompt from turn navigation
- Degrade safely: if state is missing or invalid, do nothing rather than corrupting tmux behavior

## Recommended Architecture

### 1. Static tmux integration

tmux keybindings and status integration should become a stable installation-time configuration, not a runtime side effect of hooks.

The plugin should expose fixed bindings that call a single command entrypoint:

```tmux
bind-key -T root S-Up   run-shell "turn-nav navigate up 1 #{pane_id}"
bind-key -T root S-Down run-shell "turn-nav navigate down 1 #{pane_id}"
bind-key -T root M-Up   run-shell "turn-nav navigate up 5 #{pane_id}"
bind-key -T root M-Down run-shell "turn-nav navigate down 5 #{pane_id}"
bind-key -T copy-mode-vi S-Up   run-shell "turn-nav navigate up 1 #{pane_id}"
bind-key -T copy-mode-vi S-Down run-shell "turn-nav navigate down 1 #{pane_id}"
bind-key -T copy-mode-vi M-Up   run-shell "turn-nav navigate up 5 #{pane_id}"
bind-key -T copy-mode-vi M-Down run-shell "turn-nav navigate down 5 #{pane_id}"
bind-key -T copy-mode-vi C-g    run-shell "turn-nav bottom #{pane_id}"
bind-key -T copy-mode-vi q      send-keys -X cancel
bind-key -T copy-mode-vi Escape send-keys -X cancel
```

The final exact installation surface can vary, but the key point is fixed ownership: these bindings exist independently of any single Claude Code or Codex CLI session.

Status display should also be a fixed tmux integration point, for example by including a small status segment that shells out to:

```tmux
#(turn-nav status #{pane_id})
```

The plugin should not rewrite the entire `status-right` string during each session.

### 2. Unified runtime entrypoint

Replace the current split lifecycle scripts with a single command:

```text
scripts/turn-nav
```

Supported subcommands:

- `activate`
- `deactivate`
- `navigate up <count> <pane_id>`
- `navigate down <count> <pane_id>`
- `bottom <pane_id>`
- `status <pane_id>`

This makes hooks, bindings, and status display depend on one stable interface instead of several scripts with duplicated state assumptions.

### 3. Pane-scoped runtime state

Runtime state should move from:

```text
/tmp/turn-nav-<session_id>/
```

to:

```text
/tmp/turn-nav/<tmux_session_id>/<pane_id>/
```

Each pane directory stores only pane-local state:

- `active`
- `baseline_turn_count`
- `current_turn`
- `last_status`

This isolates concurrent panes in the same tmux session and prevents one pane from corrupting another pane's navigation index.

## Turn Model

### Turn definition

A turn is one completed user prompt line that matches `TURN_NAV_PATTERN` or the default pattern `^[❯›]`.

The currently visible live prompt is not a completed turn and must be excluded from navigation.

### Baseline definition

`baseline_turn_count` means:

> how many completed turns already existed in this pane at activation time

This replaces any line-based baseline concept.

The navigation candidate list is computed as:

1. capture current pane content
2. extract all prompt-matching lines
3. drop the final live prompt
4. treat the remaining matches as completed turns
5. discard the first `baseline_turn_count` turns

If scrollback truncation reduces the visible completed-turn count below the saved baseline, clamp the baseline to the visible total and continue. This keeps behavior stable even when tmux history is truncated.

## Lifecycle Design

### `activate`

`SessionStart` calls `turn-nav activate`.

Responsibilities:

- detect the current `pane_id`
- capture pane content once
- compute current completed-turn count
- write `baseline_turn_count`
- clear stale `current_turn` and `last_status`
- mark the pane `active`

Semantics:

> only turns created after activation belong to this plugin session

`activate` must not modify tmux key tables, status bar settings, or any global tmux option.

### `deactivate`

`SessionEnd` calls `turn-nav deactivate`.

Responsibilities:

- remove `active`
- remove `current_turn`
- remove `last_status`
- remove `baseline_turn_count`

`deactivate` must not restore tmux bindings, reset `status-right`, or make assumptions about owning global tmux configuration.

## Navigation Flow

On each navigation request:

1. verify tmux is available
2. verify the target pane is active
3. capture pane content
4. parse completed turns using the unified turn model
5. clamp baseline if scrollback has shrunk
6. determine the current logical turn index
7. calculate the target logical turn with boundary clamping
8. enter copy-mode if needed
9. jump to the target line
10. update `current_turn` and `last_status`

The current index rules stay close to today's behavior:

- when starting from the live prompt outside copy-mode, logical position is `TOTAL + 1`
- `up` moves toward older turns
- `down` moves toward newer turns
- no wraparound

## Status Display

`turn-nav status <pane_id>` returns text only when all of these are true:

- the pane is active
- the pane is currently in copy-mode
- `last_status` exists

Example return value:

```text
⇅ Turn 3/12
```

Otherwise it returns an empty string.

This preserves the existing UI behavior without dynamic rewriting of the user's full status bar configuration.

## Error Handling

All failures should degrade to no-op or empty output instead of changing tmux configuration.

Rules:

- outside tmux: exit successfully with no output
- inactive pane: no-op
- no turns found: optionally show a lightweight tmux message, but do not fail hard
- missing or corrupt state directory: treat as inactive
- boundary navigation: keep current turn and refresh status message
- invalid prompt pattern: treat as zero matches

The plugin may occasionally refuse to navigate when pane state is inconsistent, but it must never leave tmux in a modified or partially restored global state.

## File-Level Changes

### Keep

- `README.md`
- `hooks/hooks.json`

### Add

- `scripts/turn-nav`
- `scripts/lib/state.sh`
- `scripts/lib/parse-turns.sh`
- `scripts/lib/tmux-nav.sh`

### Remove or reduce to compatibility shims

- `scripts/setup-nav.sh`
- `scripts/navigate-turn.sh`
- `scripts/cleanup-nav.sh`

The preferred end state is one public runtime entrypoint and small focused helpers. If backward compatibility is needed, the legacy scripts may remain as thin shims that immediately delegate to `turn-nav`.

## Testing Strategy

This redesign should be validated with shell-level regression tests around the state model and navigation semantics.

Minimum coverage:

1. live prompt is excluded from completed turns
2. baseline is counted in turns, not lines
3. scrollback truncation clamps baseline safely
4. two panes in the same tmux session do not share `current_turn`
5. repeated `activate` does not mutate global tmux configuration
6. `deactivate` only clears pane-local state
7. inactive panes ignore navigation requests

The tests can use a fake tmux shim or harness rather than full interactive tmux integration for most state-machine cases.

## Migration Notes

The user-facing experience should remain materially unchanged, but the installation contract changes:

- tmux integration becomes stable configuration rather than runtime mutation
- hooks only activate and deactivate pane-local state
- the plugin no longer claims ownership over restoring the user's global tmux state after each session

This is an intentional simplification. The current runtime mutation model is the root cause of the most fragile behavior in the repository.

## Non-Goals

- changing the default navigation keys
- adding wraparound navigation
- introducing a non-shell runtime
- indexing historical turns outside tmux scrollback
- redesigning prompt matching beyond the existing configurable pattern approach

## Decision

Adopt the static-integration, pane-scoped runtime model.

This is the smallest redesign that preserves the existing UX while removing the lifecycle bugs caused by dynamic global tmux ownership.
