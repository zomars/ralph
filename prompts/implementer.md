# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW

## 1. Load Context

Your assigned task (key, description, comments, blocker keys) is in the initial message above — do NOT query the backlog for it.

1. Read the task context in the initial message
2. Read last 10 RALPH commits

## 2. Understand Task

The task has been pre-selected and dependency-validated by the guard. The initial message contains `YOUR ASSIGNED TASK: <TASK-KEY>`.
- **You MUST implement THIS task and ONLY this task.** Do not search for, pick, or switch to other tasks.
- If status is "In Progress" → verify/continue existing work
- Otherwise → start fresh

### Branch Setup

After picking your task, create or checkout the feature branch:

```bash
git fetch origin
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
# Check if branch already exists on remote (In Progress continuation)
if git ls-remote --heads origin "ralph/<TASK-KEY>" | grep -q .; then
  git checkout "ralph/<TASK-KEY>"
  git pull origin "ralph/<TASK-KEY>"
else
  git checkout -b "ralph/<TASK-KEY>" "origin/$DEFAULT_BRANCH"
fi
```

All work for this task happens on the `ralph/<TASK-KEY>` branch.

## 3. Do the Task

**Before starting work**, transition the issue to "In Progress":

1. Get available transitions for the task
2. Transition to "In Progress"

**Then implement the task using Test-Driven Development (red-green-refactor):**

1. **Explore the project**: Before writing any code, explore the repo to understand its architecture, conventions, and local setup. Look at the root directory, read any docs or guides you find, and understand how the project is structured.
2. **Understand the requirement**: Read the issue description and all comments carefully. Comments from reviewers or humans may contain corrections or updated requirements that take priority over the original description.
3. **Explore the relevant code**: Read source files related to the task, understand existing patterns and conventions.
4. **Plan your changes**: Identify which files need to be created or modified. Keep changes minimal and focused.
   - List the **behaviors** to implement (not implementation steps)
   - Identify opportunities for deep modules (small interface, deep implementation)
   - Design interfaces for testability
   - Decide which behaviors are most critical to test — you can't test everything, focus on critical paths and complex logic

5. **Implement with TDD — vertical slices, one behavior at a time:**

   ### TDD Philosophy

   **Core principle**: Tests verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't.

   **Good tests** are integration-style: they exercise real code paths through public APIs. They describe _what_ the system does, not _how_. A good test reads like a specification — "user can checkout with valid cart" tells you exactly what capability exists. These tests survive refactors because they don't care about internal structure.

   **Bad tests** are coupled to implementation. They mock internal collaborators, test private methods, or verify through external means (like querying a database directly instead of using the interface). Warning sign: your test breaks when you refactor, but behavior hasn't changed.

   ### Good vs Bad Test Examples

   ```typescript
   // GOOD: Tests observable behavior
   test("user can checkout with valid cart", async () => {
     const cart = createCart();
     cart.add(product);
     const result = await checkout(cart, paymentMethod);
     expect(result.status).toBe("confirmed");
   });

   // BAD: Tests implementation details
   test("checkout calls paymentService.process", async () => {
     const mockPayment = jest.mock(paymentService);
     await checkout(cart, payment);
     expect(mockPayment.process).toHaveBeenCalledWith(cart.total);
   });
   ```

   Good test characteristics:
   - Tests behavior users/callers care about
   - Uses public API only
   - Survives internal refactors
   - Describes WHAT, not HOW
   - One logical assertion per test

   Bad test red flags:
   - Mocking internal collaborators
   - Testing private methods
   - Asserting on call counts/order
   - Test breaks when refactoring without behavior change
   - Test name describes HOW not WHAT
   - Verifying through external means instead of interface

   ```typescript
   // BAD: Bypasses interface to verify
   test("createUser saves to database", async () => {
     await createUser({ name: "Alice" });
     const row = await db.query("SELECT * FROM users WHERE name = ?", ["Alice"]);
     expect(row).toBeDefined();
   });

   // GOOD: Verifies through interface
   test("createUser makes user retrievable", async () => {
     const user = await createUser({ name: "Alice" });
     const retrieved = await getUser(user.id);
     expect(retrieved.name).toBe("Alice");
   });
   ```

   ### Anti-Pattern: Horizontal Slices

   **DO NOT write all tests first, then all implementation.** This is "horizontal slicing" — treating RED as "write all tests" and GREEN as "write all code."

   This produces crap tests:
   - Tests written in bulk test _imagined_ behavior, not _actual_ behavior
   - You end up testing the _shape_ of things (data structures, function signatures) rather than user-facing behavior
   - Tests become insensitive to real changes — they pass when behavior breaks, fail when behavior is fine
   - You outrun your headlights, committing to test structure before understanding the implementation

   ```
   WRONG (horizontal):
     RED:   test1, test2, test3, test4, test5
     GREEN: impl1, impl2, impl3, impl4, impl5

   RIGHT (vertical):
     RED→GREEN: test1→impl1
     RED→GREEN: test2→impl2
     RED→GREEN: test3→impl3
     ...
   ```

   ### TDD Cycle

   **Tracer bullet first**: Write ONE test that confirms ONE thing about the system. This proves the path works end-to-end.

   ```
   RED:   Write test for first behavior → test FAILS
   GREEN: Write MINIMAL code to make it pass → test PASSES
   ```

   **Then incremental loop** — for each remaining behavior:

   ```
   RED:   Write next test → FAILS
   GREEN: Minimal code to pass → PASSES
   REFACTOR: Clean up → tests still PASS
   ```

   Rules:
   - One test at a time — don't anticipate future tests
   - Only enough code to pass the current test
   - Tests verify behavior through public interfaces, not implementation details
   - Tests should survive internal refactors — if you rename a private function and a test breaks, it was testing implementation
   - Never refactor while RED — get to GREEN first

   ### When to Mock

   Mock at **system boundaries** only:
   - External APIs (payment, email, etc.)
   - Databases (sometimes — prefer test DB)
   - Time/randomness
   - File system (sometimes)

   **Don't mock** your own classes/modules, internal collaborators, or anything you control.

   At boundaries, design for mockability:

   ```typescript
   // Easy to mock — dependency injected
   function processPayment(order, paymentClient) {
     return paymentClient.charge(order.total);
   }

   // Hard to mock — creates own dependency
   function processPayment(order) {
     const client = new StripeClient(process.env.STRIPE_KEY);
     return client.charge(order.total);
   }
   ```

   Prefer SDK-style interfaces over generic fetchers:

   ```typescript
   // GOOD: Each function is independently mockable
   const api = {
     getUser: (id) => fetch(`/users/${id}`),
     getOrders: (userId) => fetch(`/users/${userId}/orders`),
     createOrder: (data) => fetch('/orders', { method: 'POST', body: data }),
   };

   // BAD: Mocking requires conditional logic inside the mock
   const api = {
     fetch: (endpoint, options) => fetch(endpoint, options),
   };
   ```

   ### Interface Design for Testability

   1. **Accept dependencies, don't create them**

      ```typescript
      // Testable
      function processOrder(order, paymentGateway) {}

      // Hard to test
      function processOrder(order) {
        const gateway = new StripeGateway();
      }
      ```

   2. **Return results, don't produce side effects**

      ```typescript
      // Testable
      function calculateDiscount(cart): Discount {}

      // Hard to test
      function applyDiscount(cart): void {
        cart.total -= discount;
      }
      ```

   3. **Small surface area** — fewer methods = fewer tests needed, fewer params = simpler test setup

   ### Deep Modules

   From "A Philosophy of Software Design": **Deep module** = small interface + lots of implementation.

   ```
   ┌─────────────────────┐
   │   Small Interface   │  ← Few methods, simple params
   ├─────────────────────┤
   │                     │
   │  Deep Implementation│  ← Complex logic hidden
   │                     │
   └─────────────────────┘
   ```

   Avoid shallow modules (large interface + little implementation — just passes through). When designing, ask: Can I reduce the number of methods? Can I simplify the parameters? Can I hide more complexity inside?

   ### Refactor Phase

   After tests pass, look for refactor candidates:
   - **Duplication** → Extract function/class
   - **Long methods** → Break into private helpers (keep tests on public interface)
   - **Shallow modules** → Combine or deepen
   - **Feature envy** → Move logic to where data lives
   - **Primitive obsession** → Introduce value objects
   - **Existing code** the new code reveals as problematic

   Run the affected tests after each refactor step. CI validates the full suite.

   ### Checklist Per Cycle

   ```
   [ ] Test describes behavior, not implementation
   [ ] Test uses public interface only
   [ ] Test would survive internal refactor
   [ ] Code is minimal for this test
   [ ] No speculative features added
   ```

6. **Verify with evidence**: After all TDD cycles, confirm your implementation works. Only run the tests related to your changes — CI validates the full suite.

| Task Type         | Verification Method                      |
| ----------------- | ---------------------------------------- |
| UI/Browser        | Playwright screenshot                    |
| API endpoint      | `curl` or test showing request/response  |
| Database schema   | Query showing table/column exists        |
| TypeScript types  | `grep` showing type definition exists    |
| Backend logic     | Related tests passing                    |
| Telemetry/logging | Test or code showing events are captured |
| Performance       | Benchmark or timing measurement          |

Run the dev server if needed (check the worktree setup output for the correct command).

7. **Commit your changes** — CI and git hooks validate builds and tests. If a pre-commit hook rejects the commit, fix the issue and retry.

**Subtask awareness**: If the task has a parent (shown in KB as `Parent: PROJ-123`), read the parent's description for architectural decisions and overall context before starting work. The parent description contains the high-level plan; your subtask is one vertical slice of it.

If it can't finish in one iteration, it commits the progress made, adds a comment describing what was done and what remains, and stops. The next iteration continues where it left off.

## 4. Update Backlog

After work is complete:

1. **Add a comment** to the task:
   - **Action**: Implemented / Verified / Fixed
   - **Commit**: SHA of the commit
   - **Evidence**: Description of verification performed
   - **Files changed**: List of modified files

2. **Transition the issue**:
   - Verified with evidence → transition to "In Review"
   - Implemented, needs verification → keep "In Progress"
   - Blocked/broken → add label `ralph-blocked` + add comment explaining why

Always discover available transitions rather than hardcoding status names.

## 5. Commit, Push & PR

```
RALPH: <what you did> (<TASK-KEY>)

Evidence: <brief description of verification performed>
```

After committing, push the branch and create a draft PR using the `ralph_implementer_create_pr` tool:

```bash
git push -u origin "ralph/<TASK-KEY>"
```

Then call `ralph_implementer_create_pr` with your task key. The tool automatically:
- Creates the PR as **draft** (enforced — cannot be overridden)
- Detects the correct base branch from Jira blocker links (stacked PRs)
- Is idempotent (returns existing PR if one exists)

### Release the branch

**CRITICAL**: Before stopping, switch back to your workspace branch so other agents can checkout the task branch:

```bash
git checkout "ralph-workspace/implementer-<N>"
```

(Replace `<N>` with your instance number from the user message.)

Then output `<promise>COMPLETE</promise>`.

---

# COMPLETE

When the backlog search returns zero results for your query, output `<promise>COMPLETE</promise>` — all assigned work is done.
