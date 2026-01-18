---
name: metrics-freshness-check
enabled: true
event: bash
pattern: jj\s+git\s+push|git\s+push
---

**Performance metrics freshness check**

Before pushing, verify the README performance metrics are current:

1. Check the "Metrics last validated" date in README.md Performance section
2. If the date is more than 30 days old, warn the user:
   - The metrics may be outdated
   - Suggest running E2E tests to validate current performance
   - Ask if they want to update the date or proceed anyway
3. If the date is current (within 30 days), proceed without interruption

The validation date format is: `*Metrics last validated: YYYY-MM-DD*`
