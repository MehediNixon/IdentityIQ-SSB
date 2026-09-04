# PAM Integration (IdentityIQ)

This guide outlines a practical pattern to integrate **SailPoint IdentityIQ** with a **Privileged Access Management (PAM)** platform (for example: CyberArk, Delinea/Thycotic, BeyondTrust, or a custom PAM API).

## 1) Integration objectives

A PAM integration with IdentityIQ typically supports:

- Discovery and certification of privileged accounts.
- Access request and approval for privileged entitlements.
- Automated provisioning/deprovisioning of privileged access.
- Password rotation and checkout workflow orchestration via PAM.
- Segregation-of-duties (SoD) controls for elevated privileges.

## 2) Reference architecture

Use IdentityIQ as the governance control plane and PAM as the privileged credential control plane:

1. **IdentityIQ** requests/approves access and writes account or entitlement changes.
2. **Connector/Integration Layer** calls PAM APIs (REST/SOAP) or uses a file/event bridge.
3. **PAM** creates updates safes/vaults/accounts/groups and enforces session/password controls.
4. **Reconciliation** aggregates PAM state back into IdentityIQ for continuous governance.

## 3) Implementation checklist

### A. Model the PAM application in IdentityIQ

- Create an Application object for the PAM endpoint.
- Define account schema and entitlement schema (vaults, safes, platforms, roles).
- Mark privileged entitlements as managed attributes for certification/reporting.

### B. Build aggregation and correlation

- Configure account aggregation from PAM.
- Configure entitlement aggregation for privileged groups/roles.
- Set identity correlation rules for service/privileged IDs.

### C. Enable provisioning

- Implement Create/Modify/Disable operations through the PAM API.
- Map IdentityIQ provisioning plans to PAM operations (add user to safe, revoke role, rotate).
- Handle approval-required, break-glass, and emergency access flags.

### D. Establish governance controls

- Add PAM entitlements to Access Request workflows.
- Define approval policy (owner + manager + security officer where required).
- Schedule privileged access certifications and policy checks.

### E. Add operational controls

- Implement retries/idempotency for connector failures.
- Add auditing fields (ticket/reference IDs, approver metadata).
- Monitor failed events and reconciliation drift.

## 4) Minimum data model recommendations

For privileged accounts, track at least:

- `nativeIdentity` / PAM account identifier
- `system` / target platform
- `entitlements` / safe-role mapping
- `owner` / accountable identity
- `riskLevel` / privileged classification
- `lastRotated` / credential hygiene timestamp
- `emergencyAccess` / break-glass indicator

## 5) Common workflow touchpoints in this repository

The following assets in this repository can be adapted for PAM access governance orchestration:

- `LCM-Build-Identity-Approvers.xml` for approval routing patterns.
- `Approval-Assignment-Rule.xml` for custom approver assignment logic.
- `Certification-Manager.xml` for certification process extension.
- `Password-Validation-Rule.xml` for password policy/validation logic where applicable.

## 6) Testing strategy

1. **Aggregation tests**: Validate privileged accounts and entitlements import correctly.
2. **Provisioning tests**: Validate create/add/remove/disable operations end-to-end.
3. **Approval tests**: Validate multi-step approvals and fallback approvers.
4. **Certification tests**: Validate campaign scope includes privileged accounts.
5. **Failure tests**: Validate rollback/manual work item creation on API failures.

## 7) Go-live readiness checklist

- [ ] Non-production and production PAM endpoints configured.
- [ ] Least-privilege integration account with credential rotation.
- [ ] Connector timeout/retry settings validated.
- [ ] Access request + certification + policy controls validated.
- [ ] Operational runbook and alerting in place.

---

If you want, this can be extended into a **vendor-specific implementation guide** (CyberArk, Delinea, BeyondTrust) with field-level mappings and sample provisioning rule stubs.
