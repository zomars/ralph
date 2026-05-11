#!/bin/zsh
# test-traverse-blockers.sh — Regression tests for _traverse_blockers.
#
# Sources lib/ralph-pick-helpers.sh directly and stubs provider functions
# to simulate blocker chains. Exercises the open-subtasks guard that prevents
# the chain walk from picking a parent whose subtasks should be picked instead.
#
# Usage: zsh tests/test-traverse-blockers.sh

set -e

RALPH_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"

# ─── Minimal test harness ────────────────────────────────────────────────────

_pass=0
_fail=0
_test_name=""

test_case() { _test_name="$1"; }

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-$_test_name}"
  if [[ "$actual" == "$expected" ]]; then
    _pass=$((_pass + 1))
    echo "  PASS: $msg"
  else
    _fail=$((_fail + 1))
    echo "  FAIL: $msg"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

test_summary() {
  echo ""
  echo "Results: $_pass passed, $_fail failed"
  (( _fail > 0 )) && exit 1
  exit 0
}

ralph_log() { : ; }  # silence logs

source "$RALPH_HOME/lib/ralph-pick-helpers.sh"

# ─── Fixtures ────────────────────────────────────────────────────────────────

_fixture_dir="/tmp/ralph-test-traverse-$$"
mkdir -p "$_fixture_dir"

_subtask() {
  # Args: $1=key, $2=status_category_key (new|indeterminate|done)
  echo "{\"key\":\"$1\",\"fields\":{\"status\":{\"statusCategory\":{\"key\":\"$2\"}}}}"
}

_write_issue() {
  # Args: $1=key, $2=subtasks_json (default "[]"), $3=blocker_keys (space-separated, default "")
  local key="$1" subtasks="${2:-[]}" blockers="${3:-}"
  local links="[]"
  if [[ -n "$blockers" ]]; then
    local items=()
    for bk in ${=blockers}; do
      items+=("{\"type\":{\"inward\":\"is blocked by\"},\"inwardIssue\":{\"key\":\"$bk\"}}")
    done
    links="[$(IFS=,; echo "${items[*]}")]"
  fi
  local f="$_fixture_dir/$key.json"
  echo "{\"key\":\"$key\",\"fields\":{\"summary\":\"$key\",\"subtasks\":$subtasks,\"issuelinks\":$links}}" > "$f"
  echo "$f"
}

# ─── Provider stubs (configured per-test via assoc arrays) ──────────────────

typeset -gA _ISSUE_FILE     # key → fixture file path
typeset -gA _BLOCKERS       # key → space-separated blocker keys (unresolved)
typeset -gA _MATCHES_QUERY  # key → "1" if the agent query would match it

provider_get_unresolved_blocker_keys() {
  local file="$1"
  local key
  key=$(jq -r '.key' "$file")
  echo "${_BLOCKERS[$key]:-}"
}

provider_check_blockers() {
  # Returns 0 (unblocked) when the issue has no unresolved blockers.
  local file="$1"
  local key
  key=$(jq -r '.key' "$file")
  [[ -z "${_BLOCKERS[$key]:-}" ]]
}

provider_fetch_tasks() {
  # Parse "AND key = \"FOO\"" out of the JQL to look up the fixture.
  local jql="$1"
  local key="${jql##*key = \"}"
  key="${key%%\"*}"
  if [[ "${_MATCHES_QUERY[$key]:-0}" == "1" && -n "${_ISSUE_FILE[$key]:-}" ]]; then
    jq -n --slurpfile i "${_ISSUE_FILE[$key]}" '{issues: $i}'
  else
    echo '{"issues":[]}'
  fi
}

_reset_world() {
  _ISSUE_FILE=()
  _BLOCKERS=()
  _MATCHES_QUERY=()
}

_register() {
  # Args: $1=key, $2=fixture file, $3=blocker_keys (optional), $4=matches_query (1/0, default 1)
  _ISSUE_FILE[$1]="$2"
  _BLOCKERS[$1]="${3:-}"
  _MATCHES_QUERY[$1]="${4:-1}"
}

_picked_key() {
  # Args: $1 = dest file path; echoes the key written by _traverse_blockers, or NONE
  if [[ -s "$1" ]]; then
    jq -r '.key' "$1"
  else
    echo "NONE"
  fi
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo "=== _traverse_blockers ==="

# Scenario reproduces PRODUCT-818: subtasks chained in reverse, traversal walks
# from a blocked subtask up to a parent whose own subtasks are still open.
# With skip_with_open_subtasks=true, the parent must NOT be picked.
test_case "skips parent with open subtasks reached via blocker chain"
_reset_world
sub_open=$(_subtask SUB-A new)
parent_file=$(_write_issue PARENT "[$sub_open]")           # PARENT has 1 open subtask, no blockers
leaf_file=$(_write_issue LEAF "[]" "PARENT")               # LEAF blocked by PARENT
_register PARENT "$parent_file" "" 1
_register LEAF   "$leaf_file"   "PARENT" 1
dest=$(mktemp)
: > "$dest"
_traverse_blockers "$leaf_file" "done" "stub query" "LEAF" "true" "$dest" || true
assert_eq "$(_picked_key "$dest")" "NONE" "open-subtasks parent is skipped"
rm -f "$dest"

test_case "picks parent reached via blocker chain when subtasks are all done"
_reset_world
sub_done=$(_subtask SUB-B done)
parent_file=$(_write_issue PARENT "[$sub_done]")
leaf_file=$(_write_issue LEAF "[]" "PARENT")
_register PARENT "$parent_file" "" 1
_register LEAF   "$leaf_file"   "PARENT" 1
dest=$(mktemp)
: > "$dest"
_traverse_blockers "$leaf_file" "done" "stub query" "LEAF" "true" "$dest"
assert_eq "$(_picked_key "$dest")" "PARENT" "all-done parent is picked"
rm -f "$dest"

test_case "guard disabled (skip_with_open_subtasks=false) still picks parent"
_reset_world
sub_open=$(_subtask SUB-C new)
parent_file=$(_write_issue PARENT "[$sub_open]")
leaf_file=$(_write_issue LEAF "[]" "PARENT")
_register PARENT "$parent_file" "" 1
_register LEAF   "$leaf_file"   "PARENT" 1
dest=$(mktemp)
: > "$dest"
_traverse_blockers "$leaf_file" "done" "stub query" "LEAF" "false" "$dest"
assert_eq "$(_picked_key "$dest")" "PARENT" "guard disabled honors old behavior"
rm -f "$dest"

# Recursive case: LEAF → MID → PARENT. Guard fires only on PARENT (which has
# open subtasks); MID is a normal blocker with no subtasks and should be picked.
test_case "recurses through chain and picks first eligible non-parent"
_reset_world
sub_open=$(_subtask SUB-D new)
parent_file=$(_write_issue PARENT "[$sub_open]")
mid_file=$(_write_issue MID "[]" "PARENT")                # MID has no subtasks, blocked by PARENT
leaf_file=$(_write_issue LEAF "[]" "MID")                 # LEAF blocked by MID
_register PARENT "$parent_file" "" 1
_register MID    "$mid_file"    "PARENT" 1
_register LEAF   "$leaf_file"   "MID" 1
dest=$(mktemp)
: > "$dest"
_traverse_blockers "$leaf_file" "done" "stub query" "LEAF" "true" "$dest" || true
# PARENT is rejected by the guard (open subtasks). Recursion returns 1 to MID,
# which is itself unblocked-by-the-guard (no subtasks) and gets picked.
assert_eq "$(_picked_key "$dest")" "MID" "MID is picked when PARENT is guarded off"
rm -f "$dest"

# Cycle detection: A blocked by B, B blocked by A. Should terminate with no pick.
test_case "cycle in blocker chain terminates without crash"
_reset_world
a_file=$(_write_issue ISSUE-A "[]" "ISSUE-B")
b_file=$(_write_issue ISSUE-B "[]" "ISSUE-A")
_register ISSUE-A "$a_file" "ISSUE-B" 1
_register ISSUE-B "$b_file" "ISSUE-A" 1
dest=$(mktemp)
: > "$dest"
# ISSUE-A is the starting point already in the visited set, so traversal will
# fetch ISSUE-B (which is blocked by A — already visited — and has no other
# candidates), then fall through.
_traverse_blockers "$a_file" "done" "stub query" "ISSUE-A" "true" "$dest" || true
# Without cycle detection this would recurse infinitely. With it, we get a pick
# of ISSUE-B because B has no unvisited blockers and matches the query.
assert_eq "$(_picked_key "$dest")" "ISSUE-B" "cycle terminates and picks the other side"
rm -f "$dest"

echo ""
echo "=== _open_subtasks_of ==="

test_case "counts only non-done subtasks"
mixed=$(_write_issue X "[$(_subtask S1 new), $(_subtask S2 done), $(_subtask S3 indeterminate)]")
assert_eq "$(_open_subtasks_of "$mixed")" "2" "open subtasks counted"

test_case "returns 0 when subtasks field absent"
no_sub_file="$_fixture_dir/no-sub.json"
echo '{"key":"NS","fields":{"summary":"x"}}' > "$no_sub_file"
assert_eq "$(_open_subtasks_of "$no_sub_file")" "0" "missing field → 0"

# ─── Cleanup & summary ───────────────────────────────────────────────────────

rm -rf "$_fixture_dir"
test_summary
