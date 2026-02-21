# Project Requirements Document

This file defines tasks for Ralph to work on. Each task is an H2 heading with metadata in HTML comments.

---

## USER-001: Setup authentication system
<!-- status: to-do -->
<!-- labels: needs-planning, enhancement -->
<!-- priority: high -->

TODO

---

## USER-002: Add user profile page
<!-- status: in-progress -->
<!-- labels: enhancement -->
<!-- priority: medium -->

### User Story
As a user, I want to view and edit my profile information so that I can keep my account details up to date.

### Acceptance Criteria
- [ ] Display user's name, email, and avatar
- [ ] Allow editing of name and email
- [ ] Upload new avatar image
- [ ] Show confirmation after save
- [ ] Validate email format

### Technical Notes
- Use React for the UI
- Store avatar in S3
- Update user record via PUT /api/users/:id

### Comments
<!-- comment-2024-02-20-10:30:00 -->
**planner**: Added acceptance criteria and technical approach.
<!-- /comment -->

<!-- comment-2024-02-20-14:15:00 -->
**implementer**: Started implementation. Created ProfilePage component and API endpoint.
<!-- /comment -->

---

## USER-003: Implement dark mode
<!-- status: in-review -->
<!-- labels: enhancement -->
<!-- priority: low -->

### User Story
As a user, I want to toggle between light and dark themes so that I can use the app comfortably in different lighting conditions.

### Acceptance Criteria
- [x] Add theme toggle button in header
- [x] Persist theme preference in localStorage
- [x] Apply theme colors consistently across all pages
- [x] Add smooth transition when switching themes

### Implementation
Used CSS variables for theme colors. Toggle button in header dispatches theme change action. Added ThemeProvider context to wrap the app.

### Comments
<!-- comment-2024-02-19-16:00:00 -->
**implementer**: Completed implementation. Ready for review.
<!-- /comment -->

---

## USER-004: Fix login form validation
<!-- status: done -->
<!-- labels: bug, documented -->
<!-- priority: high -->

### Description
Login form was not properly validating email format, allowing invalid emails to be submitted.

### Solution
Added email validation regex to LoginForm component. Shows error message when email format is invalid.

### Comments
<!-- comment-2024-02-18-09:00:00 -->
**implementer**: Fixed validation issue. Added tests.
<!-- /comment -->

<!-- comment-2024-02-18-11:30:00 -->
**reviewer**: LGTM. Merged to main.
<!-- /comment -->

<!-- comment-2024-02-18-15:00:00 -->
**documenter**: Updated README with login validation behavior.
<!-- /comment -->

---

## USER-005: Refactor database queries
<!-- status: to-do -->
<!-- labels: tech-debt -->
<!-- priority: medium -->

### Background
Several API endpoints have complex raw SQL queries that are hard to maintain and test. Need to refactor to use query builder or ORM.

### Affected Files
- `api/users.js`
- `api/posts.js`
- `api/comments.js`

### Approach
Migrate to using Prisma ORM for type safety and better query composition.

---

## USER-006: Add unit tests for auth service
<!-- status: to-do -->
<!-- labels: needs-tests -->
<!-- priority: high -->

### Description
The auth service (src/services/auth.js) needs comprehensive unit tests covering:
- Login flow
- Token generation
- Token validation
- Password hashing
- Error cases

Target: 90% code coverage for auth service.

---
