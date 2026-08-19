# Phase 2C-27E Production Rollout Runbook

Phase name: Production Rollout Runbook / Meeting-Ready Summary

Date: 2026-05-26

## Meeting-Ready Summary

- Current status: production canonical reads remain disabled and production behavior remains blocked by default.
- The rollout stack now has canonical recovery, snapshot diagnostics, media recovery validation, normalized parity diagnostics, replay/backfill validation, hosted staging proof, candidate gating, overlay inspection, controlled activation modeling, rollout readiness, cohort control-plane diagnostics, operator approval gates, and dry-run packaging.
- Hosted staging has proven parity replay repair, candidate qualification, overlay construction, and controlled activation without requiring production canonical reads.
- Limited production readiness is diagnostic-only: it can identify a future org/property/session cohort, but it does not activate that cohort.
- The first production cohort must be single org, single property, and preferably single session.
- Operator approval is explicit, scope-bound, freshness-aware, and blocked by unresolved rollout issues.
- Rollback and fallback posture remains local-first: active source returns to local and local/iCloud fallback is retained.
- Key risks are parent mismatch, missing remote children, remote-newer conflict, low parity/replay confidence, missing fallback, stale approval, or accidental production-wide enablement.
- Next recommended phase: perform a meeting review of the dry-run package for one candidate cohort, then decide whether to add a non-activating production allowlist record workflow.
- Intentionally not enabled: production canonical reads, production-wide remote reads, production candidate activation, production overlay activation, destructive local overwrite, export/seal/sync/media/iCloud behavior changes, RLS changes, and data deletion.

## Current Rollout Posture

The canonical-read transition is ready for operator review and dry-run discussion, not production activation. The system has strong diagnostics and staged proof, but production canonical reads remain disabled. Production rollout posture is limited to report generation, readiness checks, explicit allowlist modeling, operator approval modeling, and dry-run decision packaging.

Production behavior is blocked by default. Any future production movement must remain single-cohort, explicitly scoped, reversible, and gated by evidence.

## What Is Proven

- Local-first canonical recovery and session snapshot foundations exist.
- Media recovery diagnostics and retrieval validation are available.
- Normalized parity diagnostics identify parent, child-row, and freshness gaps.
- Replay/backfill validation has been exercised without production mutation.
- Hosted staging proved convergence paths for replay repair, candidate qualification, overlay construction, and controlled activation.
- Canonical candidate gating requires explicit allowlists, parity confidence, replay confidence, local fallback, and production-wide disabled posture.
- Overlay consumption is diagnostic/test-only and retains local active source.
- Comparison UX identifies candidate matches, incomplete candidates, divergent candidates, and remote-newer/local-newer cases.
- Controlled activation modeling includes selected-session scope and rollback metadata.
- Rollout readiness, production allowlist readiness, cohort control-plane diagnostics, operator approval workflow, and production rollout dry-run packaging now exist.

## What Remains Blocked

- Production canonical reads.
- Production-wide remote reads.
- Production candidate activation.
- Production overlay activation.
- Property-cohort or broad activation.
- Any production data mutation from the rollout workflow.
- Any destructive local overwrite or fallback removal.
- Any export, seal, sync, media, or iCloud behavior change.
- Any RLS loosening or schema/security relaxation.

## Safety Gates

Before any future limited production cohort is considered, all gates must pass:

- Single org/property/session scope is selected.
- Org, property, and session allowlists are complete.
- Parent org and parent property consistency are verified.
- Parity confidence meets threshold.
- Replay/backfill confidence meets threshold.
- Candidate is allowed and local fallback is available.
- Overlay is built and verified in diagnostic-only mode.
- Overlay comparison matches local.
- Activation readiness is selected-session only.
- Rollback is validated.
- Operator approval is current, explicit, and scope-bound.
- Production-wide canonical reads are disabled.
- No unresolved rollout blockers remain.

## First Production Cohort Checklist

- Single org only.
- Single property only.
- Single session only for the first cohort.
- Parity verified.
- Replay/backfill verified.
- Candidate allowlist complete.
- Overlay verified.
- Overlay comparison matches local.
- Rollback tested.
- Local/iCloud fallback retained.
- Operator approved.
- Approval timestamp recorded.
- Approval not stale or expired.
- Production-wide canonical reads disabled.
- Dry-run report copied into the operator rollout record.

## Operator Approval Process

1. Generate the production rollout dry-run package.
2. Confirm selected org/property/session scope.
3. Review parity, replay/backfill, candidate, overlay, activation readiness, rollback, and fallback evidence.
4. Confirm production-wide canonical reads are disabled.
5. Check do-not-proceed conditions.
6. Request operator review.
7. Approve production cohort readiness only if every safety gate passes.
8. Record approval timestamp, approved scope, and expiration or freshness expectation.
9. Treat rejected, expired, or stale approvals as blocking.

Approval is diagnostic state only. Approval does not enable production canonical reads, activate candidates, switch global reads, write state, or remove fallback.

## Dry-Run Process

1. Use Local Health action: `Generate Production Rollout Dry Run`.
2. Confirm the dry-run state:
   - `dry_run_blocked`: resolve blockers before review.
   - `dry_run_ready_for_operator_review`: evidence is positive, operator approval is still required.
   - `dry_run_ready_for_single_session_allowlist`: approval and evidence are present for single-session allowlist readiness only.
3. Review selected org/property/session.
4. Review readiness summary and blockers.
5. Review required operator actions.
6. Review rollback and fallback plans.
7. Confirm production-wide disabled status.
8. Confirm the report states that no changes were performed.

The dry run must not enable production reads, activate a candidate, build a production overlay unless it is already diagnostic-only, write local state, or write remote state.

## Rollback And Fallback Plan

- Active source returns to local.
- Local/iCloud fallback remains retained.
- No destructive local overwrite is allowed.
- No local files are discarded.
- No production data is mutated.
- No export, seal, sync, media, or iCloud behavior changes are part of rollback.
- Production-wide canonical reads remain disabled as the kill-switch posture.
- If any validation fails, operator action is to keep or return active source to local and stop the cohort.

## Do-Not-Proceed Conditions

Do not proceed to production cohort approval or future allowlist activation if any of the following are present:

- Parent org mismatch.
- Parent property mismatch.
- Missing remote children.
- Remote-newer conflict.
- Local-newer conflict without explicit resolution.
- Low parity confidence.
- Low replay/backfill confidence.
- Candidate unavailable or blocked.
- Overlay unavailable, blocked, incomplete, or divergent.
- Rollback unavailable or untested.
- Missing local/iCloud fallback.
- Operator approval rejected.
- Operator approval expired or stale.
- Production-wide canonical reads enabled.
- Any unresolved rollout blocker.

## Monitoring And Validation Checklist

- Capture the dry-run report before the meeting.
- Capture the Local Health canonical rollout report.
- Verify selected org/property/session IDs.
- Verify parity and replay/backfill confidence values.
- Verify overlay comparison result is candidate matches local.
- Verify activation readiness remains selected-session only.
- Verify rollback source is local.
- Verify active source is local before and after dry run.
- Verify local/iCloud fallback is available.
- Verify production-wide disabled confirmation is true.
- Verify approval state, approved scope, timestamp, and freshness.
- Verify no production writes, reads, overlay activation, or candidate activation occurred.
- Verify export/seal/sync/media/iCloud behavior remains unchanged.

## Next Recommended Phase

Recommended next phase: Production Allowlist Record Design, still non-activating.

That phase should define how a single org/property/session allowlist decision would be recorded, reviewed, expired, and audited without enabling production canonical reads. Activation should remain out of scope until a later explicit phase.

## Explicit Non-Activation Confirmation

This runbook is documentation only. It does not change canonical-read behavior, enable production canonical reads, activate production candidates, mutate production data, change export/seal/sync/media/iCloud behavior, loosen RLS, delete data, or commit changes.
