#!/usr/bin/awk -f
# file-query.awk — Parse markdown PRD and count tasks matching query
#
# Usage: awk -v query="status:to-do label:needs-tests" -f file-query.awk prd.md
#
# Query syntax:
#   status:val1,val2       — status IN list
#   !status:val1,val2      — status NOT in list
#   label:val              — has label
#   !label:val             — doesn't have label
#   description:empty      — description is empty or TODO
#   !description:empty     — description not empty
#   !blocked               — exclude tasks with unresolved depends-on

BEGIN {
  task_count = 0
  total_tasks = 0
  current_task_id = ""
  current_status = ""
  current_labels = ""
  current_description = ""
  current_depends_on = ""
  in_task = 0
  file_initialized = 0

  # Parse query into conditions array
  parse_query(query)
}

# Start of new task (H2 heading with task ID)
/^## [A-Z]+-[0-9]+:/ {
  # Store previous task if any
  if (in_task) {
    store_task()
  }

  # Extract task ID from heading
  current_task_id = $0
  sub(/^## /, "", current_task_id)
  sub(/:.*$/, "", current_task_id)
  current_status = ""
  current_labels = ""
  current_description = ""
  current_depends_on = ""
  in_task = 1
  total_tasks++
  next
}

# Status comment
/<!-- status:/ {
  current_status = $0
  sub(/.*<!-- status: */, "", current_status)
  sub(/ *-->.*$/, "", current_status)
  next
}

# Labels comment
/<!-- labels:/ {
  current_labels = $0
  sub(/.*<!-- labels: */, "", current_labels)
  sub(/ *-->.*$/, "", current_labels)
  # Remove all spaces to handle "label1, label2" format
  gsub(/ /, "", current_labels)
  current_labels = "," current_labels ","
  next
}

# Priority comment (not used in query currently, but parse for completeness)
/<!-- priority:/ {
  next
}

# Depends-on comment (e.g., <!-- depends-on: TASK-001, TASK-002 -->)
/<!-- depends-on:/ {
  current_depends_on = $0
  sub(/.*<!-- depends-on: */, "", current_depends_on)
  sub(/ *-->.*$/, "", current_depends_on)
  gsub(/ /, "", current_depends_on)
  current_depends_on = "," current_depends_on ","
  next
}

# Check for initialization marker
/<!-- ralph:initialized -->/ {
  file_initialized = 1
  next
}

# Collect description content (non-empty lines that aren't comments or headings)
in_task && !/^##/ && !/^<!--/ && !/^---/ && NF > 0 {
  if (current_description == "") {
    current_description = $0
  } else {
    current_description = current_description "\n" $0
  }
}

# End of file - store last task, then evaluate all
END {
  if (in_task) {
    store_task()
  }

  # Now evaluate all tasks (two-pass: statuses are known, dependencies can be resolved)
  for (t = 1; t <= total_tasks; t++) {
    # Set current_* from stored arrays for evaluate_task
    current_task_id = task_ids[t]
    current_status = task_statuses[t]
    current_labels = task_labels[t]
    current_description = task_descriptions[t]
    current_depends_on = task_depends[t]
    evaluate_task()
  }

  # Special case: if file needs initialization and query contains file:needs-init, return 1
  if ((total_tasks == 0 || file_initialized == 0) && task_count == 0) {
    for (i = 1; i <= cond_count; i++) {
      # Check direct condition or within OR group
      if (conditions[i] == "file:needs-init") {
        print 1
        exit
      }
      if (substr(conditions[i], 1, 3) == "OR:" && index(conditions[i], "file:needs-init") > 0) {
        print 1
        exit
      }
    }
  }

  print task_count
}

# ─── Helper Functions ──────────────────────────────────────────────────

function trim(s) {
  gsub(/^ +| +$/, "", s)
  return s
}

function store_task() {
  task_ids[total_tasks] = current_task_id
  task_statuses[total_tasks] = current_status
  task_labels[total_tasks] = current_labels
  task_descriptions[total_tasks] = current_description
  task_depends[total_tasks] = current_depends_on
  # Build lookup: task_id -> status
  task_status_map[current_task_id] = current_status
}

function parse_query(q,    i, in_group, group, rest, ch, word) {
  # Handle OR groups: (cond1 OR cond2)
  # Parse query into conditions array
  rest = q
  while (rest != "") {
    # Skip leading spaces
    sub(/^ +/, "", rest)
    if (rest == "") break

    # Check for OR group
    if (substr(rest, 1, 1) == "(") {
      # Find matching closing paren
      in_group = 1
      group = ""
      i = 2
      while (i <= length(rest) && in_group > 0) {
        ch = substr(rest, i, 1)
        if (ch == "(") in_group++
        if (ch == ")") in_group--
        if (in_group > 0) group = group ch
        i++
      }
      # Store OR group
      conditions[++cond_count] = "OR:" group
      rest = substr(rest, i)
    } else {
      # Extract single condition (up to next space or paren)
      word = ""
      i = 1
      while (i <= length(rest)) {
        ch = substr(rest, i, 1)
        if (ch == " " || ch == "(") break
        word = word ch
        i++
      }
      if (word != "") {
        conditions[++cond_count] = word
      }
      rest = substr(rest, i)
    }
  }
}

function evaluate_task(    i, cond, matches) {
  matches = 1  # Assume match unless a condition fails

  for (i = 1; i <= cond_count; i++) {
    cond = conditions[i]

    # OR group
    if (substr(cond, 1, 3) == "OR:") {
      cond = substr(cond, 4)
      if (evaluate_or_group(cond)) {
        continue  # OR group passes
      } else {
        matches = 0
        break
      }
    }
    # Negated condition
    else if (substr(cond, 1, 1) == "!") {
      cond = substr(cond, 2)
      if (cond == "blocked") {
        # !blocked — exclude tasks whose dependencies are not all done
        if (!check_blocked()) {
          continue  # Not blocked, passes
        } else {
          matches = 0
          break
        }
      }
      if (!evaluate_condition(cond)) {
        continue  # Negation passes
      } else {
        matches = 0
        break
      }
    }
    # Positive condition
    else {
      if (evaluate_condition(cond)) {
        continue  # Condition passes
      } else {
        matches = 0
        break
      }
    }
  }

  if (matches) {
    task_count++
  }
}

# Returns 1 if the current task is blocked (has depends-on with non-done deps)
function check_blocked(    deps, i, n, dep_id, dep_status) {
  if (current_depends_on == "" || current_depends_on == ",,") {
    return 0  # No dependencies
  }
  # Strip leading/trailing commas, split by comma
  dep_list = current_depends_on
  gsub(/^,|,$/, "", dep_list)
  n = split(dep_list, deps, ",")
  for (i = 1; i <= n; i++) {
    dep_id = trim(deps[i])
    if (dep_id == "") continue
    dep_status = task_status_map[dep_id]
    if (dep_status != "done") {
      return 1  # Blocked by a non-done dependency
    }
  }
  return 0  # All dependencies are done
}

function evaluate_or_group(group,    parts, i, n) {
  # Split by " OR " and evaluate each part
  n = split(group, parts, / OR /)
  for (i = 1; i <= n; i++) {
    if (evaluate_condition(trim(parts[i]))) {
      return 1  # At least one condition matches
    }
  }
  return 0  # No conditions matched
}

function evaluate_condition(cond,    key, value, values, i, n, val) {
  # Split condition into key:value
  if (index(cond, ":") == 0) {
    return 0  # Invalid condition
  }

  key = substr(cond, 1, index(cond, ":")-1)
  value = substr(cond, index(cond, ":")+1)

  # File condition (special meta-condition)
  if (key == "file") {
    if (value == "needs-init") {
      # File needs init if: no tasks exist OR tasks exist but no init marker
      return total_tasks == 0 || (total_tasks > 0 && file_initialized == 0)
    }
    return 0
  }

  # Status condition
  if (key == "status") {
    # Split comma-separated values
    n = split(value, values, ",")
    for (i = 1; i <= n; i++) {
      val = trim(values[i])
      if (current_status == val) {
        return 1
      }
    }
    return 0
  }

  # Label condition
  if (key == "label") {
    # Handle comma-separated labels for negation (e.g., !label:a,b,c)
    # If any of the labels exist, return true (which will be negated)
    n = split(value, values, ",")
    for (i = 1; i <= n; i++) {
      val = trim(values[i])
      if (index(current_labels, "," val ",") > 0) {
        return 1
      }
    }
    return 0
  }

  # Description condition
  if (key == "description") {
    if (value == "empty") {
      return current_description == "" || current_description ~ /TODO/
    }
    return 0
  }

  return 0
}
