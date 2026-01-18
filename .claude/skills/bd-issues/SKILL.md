---
name: bd-issues
description: This skill should be used when the user asks to "create an issue", "add a task", "track a bug", "show issues", "list tasks", "close an issue", "manage dependencies", "check what's blocked", or mentions "bd", "beads", or issue tracking. Provides guidance for using the bd CLI issue tracker.
---

# bd Issue Tracking

bd ("beads") is a lightweight CLI issue tracker with first-class dependency support. Issues are stored locally in `.beads/` and can sync via git.

## When to Use bd vs TodoWrite

| Use bd | Use TodoWrite |
|--------|---------------|
| Multi-session work | Single-session tasks |
| Work with dependencies | Simple checklists |
| Strategic/discovered work | Execution tracking |
| Needs persistence | Ephemeral progress |

**Rule:** When in doubt, prefer bd—persistence you don't need beats lost context.

## Issue Structure

Every issue in this repository should include a **Testing** section:

```markdown
## Testing
- Run E2E tests: `make test-e2e`
- [Additional verification steps specific to the issue]
```

## Core Commands

### Creating Issues

```bash
# Basic issue
bd create --title="Fix login bug" --type=bug --priority=2

# With description
bd create --title="Add dark mode" --type=feature --priority=2 \
  --description="$(cat << 'EOF'
Implement dark mode toggle in settings.

## Requirements
- Toggle in settings page
- Persist preference

## Testing
- Run E2E tests: `make test-e2e`
EOF
)"

# From stdin for complex descriptions
cat << 'EOF' | bd create --title="Complex feature" --body-file -
Description with multiple sections...

## Testing
- Run E2E tests: `make test-e2e`
EOF
```

**Priority values:** 0-4 or P0-P4 (0=critical, 4=backlog). Default is P2. Do NOT use "high"/"medium"/"low".

**Issue types:** `task`, `bug`, `feature`, `epic`, `chore`

### Finding Work

```bash
bd ready                    # Issues ready to work (no blockers)
bd list                     # Open issues
bd list --all               # All issues including closed
bd list --status=in_progress # Active work
bd show <id>                # Issue details with dependencies
bd status                   # Project overview stats
```

### Updating Issues

```bash
bd update <id> --status=in_progress  # Claim work
bd update <id> --assignee=username   # Assign
bd update <id> --description="..."   # Update description
bd update <id> --body-file -         # Update from stdin
bd close <id>                        # Mark complete
bd close <id1> <id2> <id3>          # Close multiple at once
```

### Dependencies

```bash
bd dep add <issue> <depends-on>  # issue depends on depends-on
bd dep rm <issue> <depends-on>   # Remove dependency
bd blocked                       # Show all blocked issues
bd graph                         # Visualize dependency graph
```

### Analysis

```bash
bd status                   # Overview with counts
bd list --all --json | jq   # JSON for custom analysis
bd stale                    # Issues not updated recently
```

## Workflows

### Starting Work

```bash
bd ready                              # Find available work
bd show <id>                          # Review details
bd update <id> --status=in_progress   # Claim it
```

### Completing Work

```bash
bd close <id>           # Mark complete
bd sync --flush-only    # Export to JSONL (if using git sync)
```

### Creating Dependent Work

```bash
bd create --title="Implement feature" --type=feature
# Returns: ephemeral-environments-xxx

bd create --title="Write tests" --type=task
# Returns: ephemeral-environments-yyy

bd dep add ephemeral-environments-yyy ephemeral-environments-xxx
# Tests depend on feature (feature blocks tests)
```

### Breaking Down Epics

```bash
# Create parent epic
bd create --title="User authentication" --type=epic

# Create child tasks with parent
bd create --title="Login form" --type=task --parent=<epic-id>
bd create --title="Session management" --type=task --parent=<epic-id>
bd create --title="Logout flow" --type=task --parent=<epic-id>
```

## Best Practices

1. **Always include Testing section** in issue descriptions for this repo
2. **Use meaningful titles** - action-oriented, specific
3. **Set appropriate priority** - P0 for critical, P2 for normal, P4 for backlog
4. **Link dependencies** - helps surface what's blocked
5. **Close issues promptly** - keeps `bd ready` useful
6. **Use `--body-file -`** for multi-line descriptions to preserve formatting

## Additional Resources

### Reference Files

For detailed command reference and advanced usage:
- **`references/commands.md`** - Complete command reference with all flags
