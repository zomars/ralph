# BACKLOG PROVIDER: FILE

You are connected to a local markdown file as the backlog provider. Tasks are defined as H2 sections in the PRD file with metadata in HTML comments.

## Tools

- **Read the PRD file**: Use the `Read` tool with the file path from `$RALPH_PRD_FILE` environment variable (defaults to `./prd.md`)
- **Update task metadata**: Use the `Edit` tool to modify HTML comments containing status, labels, or priority
- **Update task description**: Use the `Edit` tool to modify the markdown content under the task heading
- **Add comments**: Use the `Edit` tool to append a new comment block before the next task or HR separator

## Task Format

Each task is an H2 heading with a task ID prefix, followed by metadata in HTML comments, then markdown description.

```markdown
## USER-001: Feature Name
<!-- status: to-do -->
<!-- labels: enhancement, needs-planning -->
<!-- priority: high -->

Description content here...

### Acceptance Criteria
- [ ] Item 1
- [ ] Item 2

### Comments
<!-- comment-2024-02-20-15:30:00 -->
**planner**: Added acceptance criteria.
<!-- /comment -->
```

**Task ID**: H2 heading prefix (e.g., "USER-001"). Use this as `<TASK-KEY>` in commit messages.

**Status**: One of `to-do`, `in-progress`, `in-review`, `done` in `<!-- status: ... -->` comment immediately after heading.

**Labels**: Comma-separated list in `<!-- labels: ... -->` comment. Standard labels: `needs-planning`, `needs-tests`, `tech-debt`, `ralph-blocked`, `ralph-failed`, `needs-input`, `documented`.

**Priority**: One of `high`, `medium`, `low` in `<!-- priority: ... -->` comment (optional).

**Description**: All markdown content between the metadata comments and the next H2 heading or HR separator (`---`).

## Status Names

| Generic         | File Status    |
| --------------- | -------------- |
| Open/New        | "to-do"        |
| Working         | "in-progress"  |
| Review          | "in-review"    |
| Complete        | "done"         |

## Workflow

### 1. Find a Task

Use the `Read` tool to read the entire PRD file. Search for tasks matching your agent's criteria (status, labels, description state).

**If the PRD has no tasks yet** (i.e., it's just a requirements document with user stories, features, or technical specs), your job as the **planner** is to:
1. Read and understand the requirements/user stories
2. Create an initial set of properly formatted tasks at the end of the file
3. Each task should follow the format above with H2 heading, status, labels, and description
4. Start with `status: to-do` and add appropriate labels (`needs-planning` if more detail needed, or ready for implementation)

### 2. Update Task Status

Use the `Edit` tool to change the status comment:

```markdown
<!-- status: to-do -->
```

to:

```markdown
<!-- status: in-progress -->
```

### 3. Update Task Description

Use the `Edit` tool to replace the description content. You can use full markdown syntax including headings, lists, code blocks, and links.

### 4. Add/Remove Labels

Use the `Edit` tool to modify the labels comment:

```markdown
<!-- labels: enhancement, needs-planning -->
```

to:

```markdown
<!-- labels: enhancement, needs-tests -->
```

To add a label, append it to the comma-separated list. To remove, delete it from the list.

### 5. Add Comments

Use the `Edit` tool to add a new comment block at the end of the task description, before the next H2 or HR:

```markdown
### Comments
<!-- comment-2024-02-20-16:45:00 -->
**implementer**: Completed initial implementation. Added tests for core functionality.
<!-- /comment -->
```

Use ISO 8601 timestamp format in the comment ID. Use your agent role name (planner, implementer, reviewer, etc.) in bold as the comment author.

## Query Language

This provider uses a simple key-value query syntax (not JQL):

- `status:to-do,in-progress` — status IN list
- `!status:done` — status NOT in list
- `label:needs-tests` — has label
- `!label:tech-debt` — doesn't have label
- `description:empty` — description is empty or contains TODO
- `!description:empty` — description is not empty

Multiple conditions are combined with AND logic (all must match).

## Important Notes

- Always read the entire file first to find your task
- Make targeted edits using the `Edit` tool — don't rewrite the entire file
- Preserve exact formatting of metadata comments (spacing, case)
- When editing, ensure you capture the exact old_string including all whitespace
- Tasks are separated by H2 headings (`##`) or horizontal rules (`---`)
