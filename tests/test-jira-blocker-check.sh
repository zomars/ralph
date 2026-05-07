#!/bin/zsh
# test-jira-blocker-check.sh — Regression tests for jira blocker check semantics
#
# The "no_needs_planning" mode should consider a blocker cleared once it has
# been planned (no needs-planning label). It must NOT also require the blocker
# to have reached statusCategory=Done — that conflated planning readiness with
# implementation completion and stalled the planner whenever predecessors were
# in code review.
#
# Usage: zsh tests/test-jira-blocker-check.sh

set -e

RALPH_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"

_pass=0
_fail=0

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass=$((_pass + 1)); echo "  PASS: $msg"
  else
    _fail=$((_fail + 1)); echo "  FAIL: $msg"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    _pass=$((_pass + 1)); echo "  PASS: $msg"
  else
    _fail=$((_fail + 1)); echo "  FAIL: $msg"
    echo "    expected NOT to contain: $needle"
    echo "    actual: $haystack"
  fi
}

# ─── curl stub ────────────────────────────────────────────────────────────────
# Capture the JSON body passed to curl so we can inspect the JQL.
CAPTURED_BODY_FILE=$(mktemp)

curl() {
  local body=""
  while (( $# )); do
    case "$1" in
      -d) body="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "$body" > "$CAPTURED_BODY_FILE"
  echo '{"issues":[]}'  # pretend Jira returned no matches
}

# Required env so the function doesn't error out
export JIRA_EMAIL="test@test"
export JIRA_API_TOKEN="x"
export JIRA_BASE_URL="https://example.invalid"

# ─── Source the provider ──────────────────────────────────────────────────────

source "$RALPH_HOME/lib/providers/jira.sh"

# ─── Fixture: an issue blocked by an "In Review" task without needs-planning ──

FIXTURE=$(mktemp)
cat > "$FIXTURE" <<'EOF'
{
  "key": "PRODUCT-906",
  "fields": {
    "issuelinks": [
      {
        "type": {"inward": "is blocked by"},
        "inwardIssue": {
          "key": "PRODUCT-907",
          "fields": {
            "issuetype": {"name": "Story"},
            "status": {"statusCategory": {"key": "indeterminate"}}
          }
        }
      }
    ]
  }
}
EOF

# ─── Tests ────────────────────────────────────────────────────────────────────

echo "Test: no_needs_planning JQL excludes statusCategory check"
provider_check_blockers "$FIXTURE" "no_needs_planning" >/dev/null || true
body=$(cat "$CAPTURED_BODY_FILE")
assert_contains "$body" 'labels = \"needs-planning\"' "JQL filters by needs-planning label"
assert_not_contains "$body" 'statusCategory' "JQL must not gate on statusCategory"

echo ""
echo "Test: provider_get_unresolved_blocker_keys uses same semantics"
> "$CAPTURED_BODY_FILE"
provider_get_unresolved_blocker_keys "$FIXTURE" "no_needs_planning" >/dev/null || true
body=$(cat "$CAPTURED_BODY_FILE")
assert_contains "$body" 'labels = \"needs-planning\"' "get_unresolved_blocker_keys filters by label"
assert_not_contains "$body" 'statusCategory' "get_unresolved_blocker_keys must not gate on status"

echo ""
echo "Test: an In-Review blocker without needs-planning label does not block"
# When Jira returns no matches, both functions should treat the blocker as cleared.
if provider_check_blockers "$FIXTURE" "no_needs_planning" >/dev/null 2>&1; then
  _pass=$((_pass + 1)); echo "  PASS: provider_check_blockers returns 0 (not blocked)"
else
  _fail=$((_fail + 1)); echo "  FAIL: provider_check_blockers returned non-zero (blocked)"
fi
result=$(provider_get_unresolved_blocker_keys "$FIXTURE" "no_needs_planning")
if [[ -z "$result" ]]; then
  _pass=$((_pass + 1)); echo "  PASS: get_unresolved_blocker_keys returns empty"
else
  _fail=$((_fail + 1)); echo "  FAIL: returned: $result"
fi

rm -f "$FIXTURE" "$CAPTURED_BODY_FILE"

echo ""
echo "Results: $_pass passed, $_fail failed"
(( _fail > 0 )) && exit 1
exit 0
