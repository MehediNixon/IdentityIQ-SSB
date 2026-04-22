# SoD Workflow (IdentityIQ SSB)

This document describes the **Segregation of Duties (SoD)** path used during access requests in this repository.

## Primary workflow path

1. A request is launched from an LCM workflow (for example, `Workflow/LCM-Provisioning.xml`).
2. IdentityIQ evaluates policy violations through the violation review subprocess.
3. If a policy violation is found and `policyScheme` is `interactive`, the requester is presented with a violation review step.
4. The requester can:
   - proceed and acknowledge the risk,
   - remediate by removing violating items, or
   - cancel the request.
5. The request continues only after violation handling is complete.

## Core SoD assets in this repository

- **Violation review subprocess**: `Workflow/Identity-Request-Violation-Review.xml`
  - Executes policy checks (`checkPolicyViolations`).
  - Iteratively resets plan state while remediation decisions are made.
  - Captures decision (`ignore`, `remediate`, `cancel`) and comments.
- **Policy impact analysis workflow**: `Policy-Impact-Analysis.xml`
  - Supports proactive evaluation of violations and policy impact.
- **SoD policy definitions**:
  - `Policy/Role-SOD.xml`
  - `Policy/Entitlement-SOD.xml`

## Operational notes

- Keep SoD policies narrow and deterministic to reduce false positives.
- Use `requireViolationReviewComments=true` in higher-control environments.
- Prefer `interactive` policy scheme when business users should resolve issues in-line.

## Suggested validation steps

1. Submit a role request that should violate `Policy/Role-SOD.xml`.
2. Confirm `Identity Request Violation Review` is invoked.
3. Validate all three decision paths:
   - **ignore**: request continues with comments,
   - **remediate**: violating items are removed and recalculated,
   - **cancel**: request exits with no provisioning.

