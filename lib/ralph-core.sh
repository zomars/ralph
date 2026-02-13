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

ralph_titlebar_init() {
  local rows
  rows=$(tput lines)
  # Single atomic write to /dev/tty: save cursor, move to 1;1, clear line,
  # set scroll region 2–bottom, position cursor at line 2
  printf '\033[s\033[1;1H\033[2K\033[2;%sr\033[2;1H' "$rows" >/dev/tty
  trap 'ralph_titlebar_init' WINCH
}

ralph_titlebar_update() {
  local text="$1" cols
  cols=$(tput cols)
  text="${text[1,$cols]}"
  # Single atomic write to /dev/tty: save cursor, move to 1;1, clear line,
  # write text in inverse video, restore cursor
  printf '\033[s\033[1;1H\033[2K\033[7m%s\033[0m\033[u' "$text" >/dev/tty
}

ralph_titlebar_cleanup() {
  # Reset scroll region to full screen, clear the title bar line
  printf '\033[r\033[1;1H\033[2K' >/dev/tty
}
