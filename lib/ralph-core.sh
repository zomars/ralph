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
  echo "${RALPH_POLL_INTERVAL:-300}"
}
