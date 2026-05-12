#!/bin/zsh
# ralph-github-app.sh — Mint GitHub App installation tokens (RS256 JWT).
#
# Replaces personal access tokens for bot agents so reviews appear as
# `<app-slug>[bot]` and the bot identity doesn't consume an org seat.
#
# Required env vars (validated by ralph_require_pr_reviewer_app_config):
#   RALPH_PR_REVIEWER_APP_ID          numeric App ID from github.com/settings/apps/<app>
#   RALPH_PR_REVIEWER_INSTALLATION_ID numeric Installation ID (shown after installing the App on a repo)
#   RALPH_PR_REVIEWER_APP_SLUG        the App's slug (login of bot user is "${slug}[bot]")
#   RALPH_PR_REVIEWER_APP_PRIVATE_KEY path to the .pem file generated when the App was created

# base64url encode stdin: standard base64 minus padding, '+' -> '-', '/' -> '_'
_ralph_b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# ralph_mint_installation_token <app_id> <installation_id> <private_key_path>
# Echoes a short-lived (1h) installation access token to stdout.
# Returns nonzero (and writes diagnostics to stderr) on failure.
ralph_mint_installation_token() {
  local app_id="$1"
  local installation_id="$2"
  local pem_path="$3"

  if [[ ! -r "$pem_path" ]]; then
    echo "ralph-github-app: private key not readable at: $pem_path" >&2
    return 1
  fi

  local now iat exp header payload signing_input signature jwt
  now=$(date +%s)
  iat=$(( now - 60 ))   # clock-skew tolerance
  exp=$(( now + 540 ))  # 9 min (GitHub max is 10)

  header=$(printf '{"alg":"RS256","typ":"JWT"}' | _ralph_b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | _ralph_b64url)
  signing_input="${header}.${payload}"

  signature=$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign "$pem_path" 2>/dev/null \
    | _ralph_b64url)
  if [[ -z "$signature" ]]; then
    echo "ralph-github-app: openssl failed to sign JWT (bad key?)" >&2
    return 1
  fi
  jwt="${signing_input}.${signature}"

  local response token http_status
  response=$(curl -sS -w '\n%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" 2>&1)

  http_status=$(printf '%s' "$response" | tail -n1)
  local body
  body=$(printf '%s' "$response" | sed '$d')

  if [[ "$http_status" != "201" ]]; then
    echo "ralph-github-app: token mint failed (HTTP $http_status): $body" >&2
    return 1
  fi

  token=$(printf '%s' "$body" | jq -r '.token // empty')
  if [[ -z "$token" ]]; then
    echo "ralph-github-app: response missing .token: $body" >&2
    return 1
  fi
  printf '%s' "$token"
}

# ralph_require_pr_reviewer_app_config
# Validates all four env vars are set and the key file is readable.
# Calls ralph_error + exit on failure.
ralph_require_pr_reviewer_app_config() {
  local missing=()
  [[ -z "${RALPH_PR_REVIEWER_APP_ID:-}" ]]          && missing+=("RALPH_PR_REVIEWER_APP_ID")
  [[ -z "${RALPH_PR_REVIEWER_INSTALLATION_ID:-}" ]] && missing+=("RALPH_PR_REVIEWER_INSTALLATION_ID")
  [[ -z "${RALPH_PR_REVIEWER_APP_SLUG:-}" ]]        && missing+=("RALPH_PR_REVIEWER_APP_SLUG")
  [[ -z "${RALPH_PR_REVIEWER_APP_PRIVATE_KEY:-}" ]] && missing+=("RALPH_PR_REVIEWER_APP_PRIVATE_KEY")
  if (( ${#missing[@]} > 0 )); then
    ralph_error "pr-reviewer requires GitHub App configuration. Missing: ${missing[*]}
Set these in .ralphrc:
  RALPH_PR_REVIEWER_APP_ID=<numeric app id>
  RALPH_PR_REVIEWER_INSTALLATION_ID=<numeric installation id>
  RALPH_PR_REVIEWER_APP_SLUG=<app slug, e.g. ralph-pr-reviewer>
  RALPH_PR_REVIEWER_APP_PRIVATE_KEY=~/.ralph/pr-reviewer.pem"
    exit 1
  fi
  # Expand ~ in key path if present
  RALPH_PR_REVIEWER_APP_PRIVATE_KEY="${RALPH_PR_REVIEWER_APP_PRIVATE_KEY/#\~/$HOME}"
  if [[ ! -r "$RALPH_PR_REVIEWER_APP_PRIVATE_KEY" ]]; then
    ralph_error "pr-reviewer private key not readable at: $RALPH_PR_REVIEWER_APP_PRIVATE_KEY"
    exit 1
  fi
}

# ralph_refresh_pr_reviewer_token
# Mints a fresh installation token and exports it as GH_TOKEN.
# Assumes ralph_require_pr_reviewer_app_config already ran.
ralph_refresh_pr_reviewer_token() {
  local token
  token=$(ralph_mint_installation_token \
    "$RALPH_PR_REVIEWER_APP_ID" \
    "$RALPH_PR_REVIEWER_INSTALLATION_ID" \
    "$RALPH_PR_REVIEWER_APP_PRIVATE_KEY") || return 1
  export GH_TOKEN="$token"
}
