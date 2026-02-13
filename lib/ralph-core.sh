#!/bin/zsh
# ralph-core.sh — Shared functions for Ralph agent ecosystem

# ─── Init ─────────────────────────────────────────────────────────────────────

ralph_init() {
  # Resolve RALPH_HOME via realpath (works through npm symlinks)
  if [[ -z "$RALPH_HOME" ]]; then
    RALPH_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
  fi
  export RALPH_HOME

  # Load .ralphrc from CWD if present
  if [[ -f ".ralphrc" ]]; then
    source ".ralphrc"
  fi

  # Default provider
  export RALPH_PROVIDER="${RALPH_PROVIDER:-jira}"
}

# ─── Logging ──────────────────────────────────────────────────────────────────

ralph_log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

ralph_error() {
  echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

# ─── Environment ──────────────────────────────────────────────────────────────

ralph_validate_env() {
  local var
  for var in "$@"; do
    if [[ -z "${(P)var}" ]]; then
      ralph_error "$var is not set"
      exit 1
    fi
  done
}

# ─── Paths ────────────────────────────────────────────────────────────────────

ralph_get_prompt() {
  local agent="$1"
  echo "$RALPH_HOME/prompts/$agent.md"
}

ralph_get_provider_instructions() {
  echo "$RALPH_HOME/providers/$RALPH_PROVIDER/instructions.md"
}

ralph_get_routing_json() {
  echo "$RALPH_HOME/providers/$RALPH_PROVIDER/routing.json"
}

# ─── Provider ─────────────────────────────────────────────────────────────────

ralph_load_provider() {
  local provider_script="$RALPH_HOME/lib/providers/$RALPH_PROVIDER.sh"
  if [[ ! -f "$provider_script" ]]; then
    ralph_error "Provider not found: $RALPH_PROVIDER (expected $provider_script)"
    exit 1
  fi
  source "$provider_script"
}

# ─── Queries ──────────────────────────────────────────────────────────────────

ralph_get_jql() {
  local agent="$1"
  local routing_json
  routing_json="$(ralph_get_routing_json)"
  if [[ ! -f "$routing_json" ]]; then
    ralph_error "Routing config not found: $routing_json"
    exit 1
  fi
  jq -r ".agents.${agent}.jql" "$routing_json"
}


# ─── Config ───────────────────────────────────────────────────────────────────

ralph_get_poll_interval() {
  echo "${RALPH_POLL_INTERVAL:-5}"
}

# ─── Title Bar ───────────────────────────────────────────────────────────────

_ralph_titlebar_text=""

ralph_titlebar_init() {
  local rows
  rows=$(tput lines)
  # Clear screen, move to 1;1, set scroll region 2–bottom, position at line 2
  printf '\033[2J\033[1;1H\033[2K\033[2;%sr\033[2;1H' "$rows" >/dev/tty
  trap 'ralph_titlebar_resize' WINCH
}

ralph_titlebar_resize() {
  local rows cols
  rows=$(tput lines)
  cols=$(tput cols)
  # Update scroll region to new size
  printf '\033[s\033[2;%sr' "$rows" >/dev/tty
  # Redraw the title if we have one
  if [[ -n "$_ralph_titlebar_text" ]]; then
    local text="${_ralph_titlebar_text[1,$cols]}"
    printf '\033[1;1H\033[2K\033[7m%-*s\033[0m' "$cols" "$text" >/dev/tty
  fi
  printf '\033[u' >/dev/tty
  trap 'ralph_titlebar_resize' WINCH
}

ralph_titlebar_update() {
  local text="$1" cols
  _ralph_titlebar_text="$text"
  cols=$(tput cols)
  text="${text[1,$cols]}"
  # Save cursor, move to 1;1, write full-width inverse bar, restore cursor
  printf '\033[s\033[1;1H\033[2K\033[7m%-*s\033[0m\033[u' "$cols" "$text" >/dev/tty
}

ralph_titlebar_cleanup() {
  _ralph_titlebar_text=""
  # Reset scroll region to full screen, clear the title bar line
  printf '\033[r\033[1;1H\033[2K' >/dev/tty
}
