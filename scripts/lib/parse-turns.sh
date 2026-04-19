#!/usr/bin/env bash

turn_nav_prompt_pattern() {
  printf '%s\n' "${TURN_NAV_PATTERN:-^(❯|›)}"
}

turn_nav_claude_session_boundary_line() {
  local content=$1
  printf '%s\n' "$content" |
    grep -nE '^(╭─── Claude Code v[0-9]|[[:space:]]?▐▛███▜▌[[:space:]]+Claude Code v[0-9])' 2>/dev/null |
    tail -1 |
    cut -d: -f1 || true
}

turn_nav_codex_session_boundary_line() {
  local content=$1
  printf '%s\n' "$content" |
    grep -nE '^[[:space:]]*│ >_ OpenAI Codex \(v[0-9]' 2>/dev/null |
    tail -1 |
    cut -d: -f1 || true
}

turn_nav_session_boundary_line() {
  local content=$1
  local claude_boundary codex_boundary
  claude_boundary=$(turn_nav_claude_session_boundary_line "$content")
  codex_boundary=$(turn_nav_codex_session_boundary_line "$content")
  claude_boundary=${claude_boundary:-0}
  codex_boundary=${codex_boundary:-0}
  if (( codex_boundary > claude_boundary )); then
    printf '%s\n' "$codex_boundary"
  else
    printf '%s\n' "$claude_boundary"
  fi
}

turn_nav_completed_turn_lines() {
  local content=$1
  local pattern
  pattern=$(turn_nav_prompt_pattern)
  local boundary
  boundary=$(turn_nav_session_boundary_line "$content")
  local lines=()
  while IFS= read -r line; do
    if (( line > boundary )); then
      lines+=("$line")
    fi
  done < <(printf '%s\n' "$content" | grep -nE -- "$pattern" 2>/dev/null | cut -d: -f1 || true)
  local count=${#lines[@]}
  if (( count == 0 )); then
    return 0
  fi
  unset "lines[$((count - 1))]"
  printf '%s\n' "${lines[@]}"
}

turn_nav_visible_turn_lines() {
  local content=$1
  local baseline=$2
  local completed=()
  while IFS= read -r line; do
    completed+=("$line")
  done < <(turn_nav_completed_turn_lines "$content")
  if ! [[ ${baseline:-} =~ ^[0-9]+$ ]]; then
    return 0
  fi
  local total=${#completed[@]}
  if (( baseline < 0 )); then
    baseline=0
  fi
  if (( baseline > total )); then
    baseline=$total
  fi
  if (( baseline >= total )); then
    return 0
  fi
  printf '%s\n' "${completed[@]:$baseline}"
}

turn_nav_count_completed_turns() {
  local content=$1
  local completed=()
  while IFS= read -r line; do
    completed+=("$line")
  done < <(turn_nav_completed_turn_lines "$content")
  printf '%s\n' "${#completed[@]}"
}
