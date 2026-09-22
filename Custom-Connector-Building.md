# Custom Connector Building (IdentityIQ)

This guide provides a practical, implementation-first workflow for building a **custom connector** for SailPoint IdentityIQ when an out-of-box application integration is not sufficient.

## 1) Decide if you really need a custom connector

Build a custom connector only when one of these is true:

- The target system has no supported connector.
- Required operations are not exposed by an existing connector (for example, custom entitlement model or non-standard lifecycle operations).
- You must use a proprietary API/protocol that cannot be integrated through standard provisioning rules.

If your requirement can be met by:

- an existing connector + provisioning/aggregation rules,
- file-based integration,
- JDBC,
- or Web Services connector extensions,

prefer that path first because it is lower maintenance.

## 2) Define the contract before coding

Document the connector contract in a short design note:

- **Connection model**: host/url, auth type, TLS/cert handling, timeout/retry.
- **Object model**: account schema, entitlement/group schema, key attributes.
- **Operations**:
  - Test connection
  - Aggregate accounts
  - Aggregate entitlements
  - Provision create/modify/disable/enable/delete
  - Password set/reset (if supported)
- **Error model**: transient vs permanent errors, retry-safe operations.
- **Performance targets**: aggregation window, page size, parallelism.

This document prevents rework when provisioning and aggregation semantics diverge.

## 3) Build in phases

### Phase A — Connectivity and read path

1. Implement and validate authentication.
2. Implement account aggregation with pagination.
3. Add checkpointing/incremental read where possible.
4. Normalize source attributes to stable IdentityIQ schema names.

### Phase B — Entitlements

1. Implement entitlement aggregation.
2. Preserve immutable external IDs.
3. Ensure display names are human-friendly but IDs remain authoritative.

### Phase C — Provisioning

1. Map provisioning plan operations to target API operations.
2. Ensure idempotency (safe re-run on retries).
3. Add operation-level logging with correlation IDs.

### Phase D — Hardening

1. Add rate limiting and backoff on 429/5xx or equivalent target errors.
2. Add circuit-breaker style protection for repeated failures.
3. Add metrics: success/failure counts, duration, records processed.

## 4) Connector implementation checklist

Use this checklist while coding:

- [ ] Strict input validation for required attributes.
- [ ] No credentials in logs.
- [ ] Configurable timeout, retry, and page size.
- [ ] Clear exception mapping (auth, permission, object-not-found, conflict, transient).
- [ ] Deterministic identity/account key mapping.
- [ ] Supports partial failure reporting for batch operations.
- [ ] Handles disabled/locked account states.
- [ ] Unit tests for mapper/translator logic.
- [ ] Integration test script against a non-production target.

## 5) Testing strategy

### Unit tests

Focus on:

- request/response translation,
- schema mapping,
- error mapping,
- idempotent plan handling.

### Integration tests

Test end-to-end scenarios:

1. Aggregate 10k+ accounts (or realistic scale).
2. Create account.
3. Update attributes.
4. Add/remove entitlements.
5. Disable and re-enable account.
6. Set/reset password.
7. Delete or deprovision account (if required by policy).

### Failure tests

Simulate:

- auth expiry,
- API throttling,
- network timeout,
- duplicate key conflicts,
- target-side partial outages.

## 6) Deployment and runtime operations

- Package the connector and any dependencies with deterministic versioning.
- Deploy to lower environment first and run smoke aggregation + provisioning tests.
- Roll out with feature flags or scoped pilot identities when possible.
- Keep a rollback package and runbook ready.
- Capture operational dashboards for:
  - aggregation latency,
  - provisioning success rate,
  - retry volume,
  - top failure causes.

## 7) Security and compliance guardrails

- Use least-privilege service accounts.
- Store secrets in approved secret management pattern.
- Encrypt all transport (TLS).
- Avoid storing sensitive data unless required.
- Ensure audit trail includes who requested and what changed.

## 8) Common mistakes to avoid

- Building custom connector logic when a rule extension would work.
- Treating display name as immutable ID.
- Missing incremental aggregation strategy.
- Ignoring target rate limits.
- Logging full payloads with secret values.
- No deterministic retry behavior.

## 9) Suggested delivery artifacts

For maintainability, deliver these with the connector:

1. `Connector-Design.md` (contract + assumptions)
2. `Connector-Config-Reference.md` (all config keys, defaults, examples)
3. `Connector-Runbook.md` (operations + troubleshooting)
4. `Connector-Test-Matrix.md` (scenario coverage)

---

If you want, the next step can be a **tailored blueprint** for your exact target system (API type, authentication method, and required provisioning operations).
