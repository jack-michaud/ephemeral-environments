---
name: bd-close-commit-reminder
enabled: true
event: bash
pattern: bd\s+(close|set-state)
---

**Issue closed - commit reminder**

You just closed or changed state on an issue. Before moving on:

1. Check for uncommitted changes with `jj status`
2. If there are changes related to this issue, commit them now
3. Reference the issue ID in your commit message if applicable
