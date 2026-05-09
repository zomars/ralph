#!/bin/zsh
# test-pr-reviewer-filter.sh — unit tests for lib/pr-reviewer-filter.jq
#
# Asserts the gate correctly:
#   - excludes drafts
#   - excludes PRs with non-SUCCESS CI (PENDING, FAILURE, null)
#   - includes PRs with no prior bot review
#   - excludes PRs whose latest commit ≤ latest bot review
#   - includes PRs whose latest commit > latest bot review

set -e

RALPH_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
FILTER="$RALPH_HOME/lib/pr-reviewer-filter.jq"

_pass=0; _fail=0; _name=""
test_case() { _name="$1"; }
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    _pass=$((_pass + 1)); echo "  PASS: ${3:-$_name}"
  else
    _fail=$((_fail + 1)); echo "  FAIL: ${3:-$_name}"
    echo "    expected: $2"
    echo "    actual:   $1"
  fi
}

# Helper: build a single-node search response with given fields
mkpr() {
  local number="$1" isDraft="$2" ciState="$3" lastCommit="$4" reviewsJson="$5"
  cat <<EOF
{
  "data": {
    "search": {
      "nodes": [
        {
          "number": $number,
          "title": "test PR $number",
          "url": "https://github.com/foo/bar/pull/$number",
          "headRefName": "feat/x",
          "baseRefName": "main",
          "isDraft": $isDraft,
          "author": { "login": "human" },
          "latestReviews": { "nodes": $reviewsJson },
          "commits": {
            "nodes": [
              {
                "commit": {
                  "committedDate": "$lastCommit",
                  "statusCheckRollup": $ciState
                }
              }
            ]
          }
        }
      ]
    }
  }
}
EOF
}

run_filter() {
  jq --arg bot "ralph-bot" --arg owner "foo" --arg name "bar" -f "$FILTER"
}

# ── Test 1: green CI, no prior review, non-draft → INCLUDED ──────────────────
test_case "green CI + no prior review → included"
out=$(mkpr 1 false '{"state":"SUCCESS"}' "2026-01-01T00:00:00Z" '[]' | run_filter | jq 'length')
assert_eq "$out" "1"

# ── Test 2: draft → EXCLUDED ─────────────────────────────────────────────────
test_case "draft → excluded"
out=$(mkpr 2 true '{"state":"SUCCESS"}' "2026-01-01T00:00:00Z" '[]' | run_filter | jq 'length')
assert_eq "$out" "0"

# ── Test 3: CI PENDING → EXCLUDED ────────────────────────────────────────────
test_case "CI PENDING → excluded"
out=$(mkpr 3 false '{"state":"PENDING"}' "2026-01-01T00:00:00Z" '[]' | run_filter | jq 'length')
assert_eq "$out" "0"

# ── Test 4: CI FAILURE → EXCLUDED (fixer's job) ──────────────────────────────
test_case "CI FAILURE → excluded"
out=$(mkpr 4 false '{"state":"FAILURE"}' "2026-01-01T00:00:00Z" '[]' | run_filter | jq 'length')
assert_eq "$out" "0"

# ── Test 5: CI null (no checks configured) → EXCLUDED ────────────────────────
test_case "CI null → excluded"
out=$(mkpr 5 false 'null' "2026-01-01T00:00:00Z" '[]' | run_filter | jq 'length')
assert_eq "$out" "0"

# ── Test 6: bot already reviewed at this commit → EXCLUDED ──────────────────
test_case "bot already reviewed at latest commit → excluded"
out=$(mkpr 6 false '{"state":"SUCCESS"}' "2026-01-01T00:00:00Z" \
  '[{"author":{"login":"ralph-bot"},"submittedAt":"2026-01-01T01:00:00Z"}]' \
  | run_filter | jq 'length')
assert_eq "$out" "0"

# ── Test 7: bot reviewed older commit, new push → INCLUDED ───────────────────
test_case "new commit since bot's last review → included"
out=$(mkpr 7 false '{"state":"SUCCESS"}' "2026-01-02T00:00:00Z" \
  '[{"author":{"login":"ralph-bot"},"submittedAt":"2026-01-01T00:00:00Z"}]' \
  | run_filter | jq 'length')
assert_eq "$out" "1"

# ── Test 8: only OTHER user reviewed → INCLUDED ──────────────────────────────
test_case "only other user has reviewed → included"
out=$(mkpr 8 false '{"state":"SUCCESS"}' "2026-01-01T00:00:00Z" \
  '[{"author":{"login":"someone-else"},"submittedAt":"2026-01-01T05:00:00Z"}]' \
  | run_filter | jq 'length')
assert_eq "$out" "1"

# ── Test 9: emitted record contains botUser + owner + name ───────────────────
test_case "output record carries botUser/owner/name"
out=$(mkpr 9 false '{"state":"SUCCESS"}' "2026-01-01T00:00:00Z" '[]' \
  | run_filter | jq -r '.[0] | "\(.botUser)|\(.owner)|\(.name)|\(.number)"')
assert_eq "$out" "ralph-bot|foo|bar|9"

echo ""
echo "Results: $_pass passed, $_fail failed"
(( _fail > 0 )) && exit 1
exit 0
