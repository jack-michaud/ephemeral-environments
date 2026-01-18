---
name: metrics-freshness-check
enabled: true
event: bash
pattern: jj\s+git\s+push|git\s+push
---

**Performance metrics validation reminder**

If this push includes changes to performance-critical code (Lambda, EC2/AMI, SSM scripts), validate the README performance metrics:

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
5. Update the "Metrics last validated" date
