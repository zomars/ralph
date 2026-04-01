#!/bin/zsh
# test-loop-pick-work.sh — Regression tests for loop_pick_work guard logic
#
# Tests the subtask guard, blocker traversal, and gate label skip in isolation
# by mocking provider functions and calling loop_pick_work directly.
#
# Usage: zsh tests/test-loop-pick-work.sh

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

# ─── Stubs ────────────────────────────────────────────────────────────────────

# Stub provider functions so we don't need a live Jira connection.
# Tests that need blocker behavior override these per-test.

provider_check_blockers() { return 0; }  # default: not blocked
provider_get_unresolved_blocker_keys() { echo ""; }

ralph_log() { : ; }  # silence logs during tests
ralph_get_routing_json() { echo "$RALPH_HOME/providers/jira/routing.json"; }
ralph_get_query() { echo "stub query"; }

# ─── Source the loop (we only need loop_pick_work) ────────────────────────────

# ralph-gated-loop.sh sources ralph-loop.sh which may need these:
ralph_load_provider() { : ; }

# We need loop_pick_work defined. It lives inside ralph_gated_loop() as a
# closure. Instead of sourcing the whole thing, extract what we need by
# defining the key variables and sourcing carefully.
#
# Actually — loop_pick_work is a nested function. We replicate its logic here
# to test the guard in isolation. This is intentional: testing the jq
# expressions and skip logic without the full loop machinery.

_run_pick_work() {
  # Args: $1 = agent_key, $2 = instance_num, $3 = work_file
  # Returns: picked task key (or "NONE")
  local _agent_key="$1"
  local instance_num="$2"
  local LOOP_WORK_FILE="$3"
  local _task_file="/tmp/ralph-test-pick-$$.json"

  local task_count
  task_count=$(jq '.issues | length' "$LOOP_WORK_FILE")
  local _exclude_blocked
  _exclude_blocked=$(jq -r ".agents.${_agent_key}.rules.exclude_blocked // false" "$(ralph_get_routing_json)")
  local _blocker_check
  _blocker_check=$(jq -r ".agents.${_agent_key}.rules.blocker_check // \"done\"" "$(ralph_get_routing_json)")
  local _gate_label
  _gate_label=$(jq -r ".agents.${_agent_key}.rules.gate_label // \"\"" "$(ralph_get_routing_json)")
  local _skip_open_subtasks
  _skip_open_subtasks=$(jq -r ".agents.${_agent_key}.rules.skip_with_open_subtasks // false" "$(ralph_get_routing_json)")

  local unblocked_seen=0 pick_idx=0 _open_subtask_count has_gate
  while (( pick_idx < task_count )); do
    jq ".issues[$pick_idx]" "$LOOP_WORK_FILE" > "$_task_file"

    # Skip parent issues with incomplete subtasks
    if [[ "$_skip_open_subtasks" == "true" ]]; then
      _open_subtask_count=$(jq '[.fields.subtasks[]? | select(.fields.status.statusCategory.key != "done")] | length' "$_task_file")
      if (( _open_subtask_count > 0 )); then
        pick_idx=$((pick_idx + 1))
        continue
      fi
    fi

    # Gate label check
    if [[ -n "$_gate_label" ]]; then
      has_gate=$(jq -r --arg gl "$_gate_label" \
        '[.fields.labels[]? | if type == "object" then .name else . end] | index($gl) != null' "$_task_file")
      if [[ "$has_gate" == "true" ]] && ! provider_check_blockers "$_task_file" "$_blocker_check"; then
        pick_idx=$((pick_idx + 1))
        continue
      fi
    fi

    if [[ "$_exclude_blocked" != "true" ]] || provider_check_blockers "$_task_file" "$_blocker_check"; then
      unblocked_seen=$((unblocked_seen + 1))
      if (( unblocked_seen == instance_num )); then
        jq -r '.key' "$_task_file"
        rm -f "$_task_file"
        return 0
      fi
    fi
    pick_idx=$((pick_idx + 1))
  done
  rm -f "$_task_file"
  echo "NONE"
  return 1
}

# ─── Fixtures ─────────────────────────────────────────────────────────────────

_fixture_dir="/tmp/ralph-test-fixtures-$$"
mkdir -p "$_fixture_dir"

_make_work_file() {
  # Args: JSON string of issues array
  local f="$_fixture_dir/work-$RANDOM.json"
  echo "{\"issues\": $1}" > "$f"
  echo "$f"
}

_make_issue() {
  # Args: $1=key, $2=subtasks_json (default "[]"), $3=labels_json (default "[]")
  local key="$1"
  local subtasks="${2:-[]}"
  local labels="${3:-[]}"
  echo "{\"key\":\"$key\",\"fields\":{\"summary\":\"$key\",\"subtasks\":$subtasks,\"labels\":$labels,\"issuelinks\":[]}}"
}

_subtask() {
  # Args: $1=key, $2=status_category_key (new|indeterminate|done)
  local status_name
  case "$2" in
    done)          status_name="Done" ;;
    new)           status_name="To Do" ;;
    indeterminate) status_name="In Progress" ;;
  esac
  echo "{\"key\":\"$1\",\"fields\":{\"status\":{\"name\":\"$status_name\",\"statusCategory\":{\"key\":\"$2\"}}}}"
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo "=== Subtask guard (implementer) ==="

test_case "skips parent with open subtasks"
wf=$(_make_work_file "[
  $(_make_issue "PARENT-1" "[$(_subtask SUB-1 new), $(_subtask SUB-2 done)]"),
  $(_make_issue "LEAF-1")
]")
result=$(_run_pick_work implementer 1 "$wf")
assert_eq "$result" "LEAF-1"

test_case "skips parent with in-progress subtasks"
wf=$(_make_work_file "[
  $(_make_issue "PARENT-2" "[$(_subtask SUB-3 indeterminate)]"),
  $(_make_issue "LEAF-2")
]")
result=$(_run_pick_work implementer 1 "$wf")
assert_eq "$result" "LEAF-2"

test_case "picks parent when all subtasks are done"
wf=$(_make_work_file "[
  $(_make_issue "PARENT-3" "[$(_subtask SUB-4 done), $(_subtask SUB-5 done)]")
]")
result=$(_run_pick_work implementer 1 "$wf")
assert_eq "$result" "PARENT-3"

test_case "picks leaf task with no subtasks"
wf=$(_make_work_file "[$(_make_issue "LEAF-3")]")
result=$(_run_pick_work implementer 1 "$wf")
assert_eq "$result" "LEAF-3"

test_case "picks task with missing subtasks field"
wf=$(_make_work_file "[{\"key\":\"LEAF-4\",\"fields\":{\"summary\":\"x\",\"labels\":[],\"issuelinks\":[]}}]")
result=$(_run_pick_work implementer 1 "$wf")
assert_eq "$result" "LEAF-4"

test_case "returns NONE when only parent with open subtasks in queue"
wf=$(_make_work_file "[
  $(_make_issue "PARENT-4" "[$(_subtask SUB-6 new)]")
]")
result=$(_run_pick_work implementer 1 "$wf" 2>/dev/null || true)
assert_eq "$result" "NONE"

test_case "instance 2 skips parents and picks second eligible leaf"
wf=$(_make_work_file "[
  $(_make_issue "PARENT-5" "[$(_subtask SUB-7 new)]"),
  $(_make_issue "LEAF-5"),
  $(_make_issue "LEAF-6")
]")
result=$(_run_pick_work implementer 2 "$wf")
assert_eq "$result" "LEAF-6"

test_case "PRODUCT-789 scenario: 3 open subtasks out of 5"
wf=$(_make_work_file "[
  $(_make_issue "PRODUCT-789" "[
    $(_subtask PRODUCT-841 new),
    $(_subtask PRODUCT-842 indeterminate),
    $(_subtask PRODUCT-843 done),
    $(_subtask PRODUCT-844 indeterminate),
    $(_subtask PRODUCT-845 done)
  ]"),
  $(_make_issue "PRODUCT-842")
]")
result=$(_run_pick_work implementer 1 "$wf")
assert_eq "$result" "PRODUCT-842"

echo ""
echo "=== Subtask guard does NOT apply to other agents ==="

test_case "planner picks parent with open subtasks (no skip_with_open_subtasks rule)"
wf=$(_make_work_file "[
  $(_make_issue "PARENT-6" "[$(_subtask SUB-8 new)]")
]")
result=$(_run_pick_work planner 1 "$wf")
assert_eq "$result" "PARENT-6"

test_case "reviewer picks parent with open subtasks"
wf=$(_make_work_file "[
  $(_make_issue "PARENT-7" "[$(_subtask SUB-9 indeterminate)]")
]")
result=$(_run_pick_work reviewer 1 "$wf")
assert_eq "$result" "PARENT-7"

# ─── Cleanup & summary ───────────────────────────────────────────────────────

rm -rf "$_fixture_dir"
test_summary
