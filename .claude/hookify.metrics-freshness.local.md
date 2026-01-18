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
   - Suggest validating metrics (see below)
   - Ask if they want to update the date or proceed anyway
3. If the date is current (within 30 days), proceed without interruption

The validation date format is: `*Metrics last validated: YYYY-MM-DD (from Lambda CloudWatch logs)*`

## How to Validate Metrics

1. Run E2E tests: `make test-e2e`
2. Check Lambda CloudWatch logs for actual timing:
   ```bash
   aws logs filter-log-events \
     --log-group-name "/aws/lambda/ephemeral-env-deploy-worker" \
     --filter-pattern "[TIMING]" \
     --start-time $(($(date +%s) - 600))000 \
     --query 'events[*].message' --output text
   ```
3. Look for `[TIMING] === Deploy Summary` entries showing:
   - `total`: End-to-end deployment time
   - `run_ssm_start_environment`: SSM bootstrap time
   - `wait_for_instance`: EC2 ready time
   - `launch_instance`: EC2 launch time
4. Update README Performance section if metrics differ significantly
