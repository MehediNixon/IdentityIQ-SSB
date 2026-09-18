# Integration Testing: End-to-End Deployment Process (IdentityIQ SSB)

This runbook defines an end-to-end (E2E) integration test flow for validating IdentityIQ deployment packages built with SSB before promoting changes across environments.

## 1) Scope and Objective

Use this process to validate that a deployment package:
- builds successfully,
- deploys cleanly,
- imports expected configuration objects,
- runs key tasks/workflows without runtime errors,
- preserves baseline data and behavior,
- can be rolled back.

## 2) Test Environments

Use at least three environments:
- **DEV**: feature development and unit checks.
- **TEST/QA**: integration + E2E validation.
- **UAT/PRE-PROD**: business validation and release sign-off.

Production deployment should only happen after all checks pass in TEST/QA and UAT/PRE-PROD.

## 3) Entry Criteria

Before executing integration tests:
- `build.properties`, `<env>.target.properties`, `<env>.iiq.properties`, and `<env>.ignorefiles.properties` are configured for the target environment.
- All new/changed XML objects are version controlled.
- Java customizations (if any) compile in the package.
- Backup strategy is ready (database backup and deployed artifact snapshot).

## 4) Test Data and Baseline

Prepare:
- 3–5 representative identities (joiner, mover, leaver, privileged user, contractor).
- 2–3 connected applications (authoritative + managed target).
- baseline values for:
  - identity count,
  - account links for test users,
  - key task execution durations,
  - expected role and entitlement assignments.

## 5) Build and Package Validation

From repo root, execute:

```bash
./build.sh clean main
```

Expected result:
- build completes without compilation or Ant errors,
- expanded WAR content is generated in build output,
- custom classes are generated in build classes output.

Optional full deployment build:

```bash
./build.sh clean deploy
```

## 6) Deployment Validation (Environment-Level)

After deployment to TEST/QA:
1. Confirm application server startup is healthy.
2. Validate IdentityIQ login and basic navigation.
3. Verify critical objects are available:
   - applications,
   - rules,
   - workflows,
   - task definitions,
   - forms/quicklinks (if part of release).
4. Validate database connectivity and connector reachability.

## 7) End-to-End Integration Test Scenarios

Execute these scenarios in TEST/QA.

### Scenario A: Aggregation + Correlation
1. Run account aggregation for test applications.
2. Verify expected identities are correlated correctly.
3. Ensure no unexpected duplicate identity creation.

Pass criteria:
- aggregation succeeds,
- expected links are created,
- no high-severity errors in task results.

### Scenario B: Joiner Flow
1. Add a new user in authoritative source.
2. Trigger/execute aggregation and identity refresh.
3. Validate role assignment and downstream provisioning.

Pass criteria:
- new identity created,
- expected birthright access provisioned,
- workflow and provisioning events are auditable.

### Scenario C: Mover Flow
1. Update department/title/manager attributes.
2. Trigger identity refresh with event processing.
3. Verify access additions/removals based on policy.

Pass criteria:
- role transitions complete as designed,
- no orphan access remains.

### Scenario D: Leaver Flow
1. Mark user as terminated in authoritative source.
2. Execute refresh/provisioning process.
3. Validate disable/delete actions per policy.

Pass criteria:
- deprovisioning actions complete,
- access is removed/disabled according to control requirements.

### Scenario E: Access Request + Approval + Provisioning
1. Submit access request via LCM.
2. Complete approval chain.
3. Validate provisioning to target and completion notification.

Pass criteria:
- approval path is correct,
- provisioning succeeds,
- request closes in expected terminal state.

### Scenario F: Certification/Work Item Processing (if in release)
1. Launch certification campaign or test campaign.
2. Complete revoke/approve actions.
3. Verify remediation/provisioning integration.

Pass criteria:
- certification actions execute,
- remediation actions are reflected in managed systems.

## 8) Non-Functional Checks

- Review server/application logs for exceptions.
- Compare post-deployment performance against baseline (task duration, login responsiveness, aggregation throughput).
- Validate scheduled tasks are still running as expected.

## 9) Exit Criteria

Promote to next stage only if:
- all critical E2E scenarios pass,
- no Sev-1/Sev-2 defects are open,
- rollback steps have been dry-run successfully,
- release owner signs off test evidence.

## 10) Suggested Evidence Checklist

Capture and store:
- build and deployment logs,
- task result screenshots/export,
- provisioning transaction logs for each scenario,
- before/after identity/account state,
- defect tracker links (if any),
- formal sign-off record.

## 11) Rollback Validation

For every deployment rehearsal:
1. Restore previous artifact/state.
2. Restore database backup (if rollback requires DB revert).
3. Re-run smoke tests:
   - login,
   - aggregation,
   - one request/provision flow.

Rollback is successful when pre-release baseline behavior is restored.

## 12) Recommended CI/CD Gate Mapping

If this repository is wired to a pipeline, use these mandatory gates:
1. **Build Gate**: `./build.sh clean main`
2. **Deploy Gate (TEST/QA)**: package deploy success
3. **Integration Gate**: Scenarios A–E pass
4. **UAT Gate**: business validation sign-off
5. **Production Gate**: change advisory + rollback readiness verified

---

## Quick Execution Template

```text
Release ID:
Environment:
Build Command(s):
Deployment Window:
Executed By:

Scenario A (Aggregation + Correlation): PASS/FAIL
Scenario B (Joiner): PASS/FAIL
Scenario C (Mover): PASS/FAIL
Scenario D (Leaver): PASS/FAIL
Scenario E (Request + Approval + Provision): PASS/FAIL
Scenario F (Certification): PASS/FAIL/N/A

Open Defects:
Rollback Tested: YES/NO
Final Recommendation: GO/NO-GO
```
