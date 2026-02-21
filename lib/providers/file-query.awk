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

BEGIN {
  task_count = 0
  total_tasks = 0
  current_task_id = ""
  current_status = ""
  current_labels = ""
  current_description = ""
  in_task = 0
  file_initialized = 0

  # Parse query into conditions array
  parse_query(query)
}

# Start of new task (H2 heading with task ID)
/^## [A-Z]+-[0-9]+:/ {
  # Evaluate previous task if any
  if (in_task) {
    evaluate_task()
  }

  # Extract task ID from heading
  current_task_id = $0
  sub(/^## /, "", current_task_id)
  sub(/:.*$/, "", current_task_id)
  current_status = ""
  current_labels = ""
  current_description = ""
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

# End of file - evaluate last task
END {
  if (in_task) {
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
