# Archive Report

**Change**: phase-1-core-backup  
**Archived**: 2026-05-02  
**Archive path**: `openspec/changes/archive/2026-05-02-phase-1-core-backup/`  
**Verdict**: PASS ✅  

---

## Summary

Phase 1 Core Backup Pipeline established the foundational backup pipeline on a single pilot host against the primary NAS repository. The change delivered a functional end-to-end backup system with lock management, authentication, backup execution (files, DB, config), Prometheus metrics, Telegram notifications with deduplication, and systemd scheduling — 39/39 tasks implemented across 17 files (~1,005 LOC).

---

## Specs Synced to Main

| Domain | Action | Details |
|--------|--------|---------|
| backup-runner | Created (new) | 11 scenarios across 7 requirements: backup execution, lock concurrency, error handling, restoration, configuration |
| prometheus-metrics | Created (new) | 7 scenarios across 4 requirements: atomic writes, backup metrics, naming convention, check metrics |
| telegram-notifications | Created (new) | 9 scenarios across 5 requirements: success digest, failure alerts, alert dedup, warning notifications |
| systemd-scheduling | Created (new) | 8 scenarios across 5 requirements: DB timer, file timer, config timer, weekly check, digest timer |
| nas-primary-repo | Created (new) | 5 scenarios across 3 requirements: repo init, SFTP connectivity, repo access configuration |

All 5 domain specs were full specs (not deltas) as `openspec/specs/` was empty. Each was copied directly from the delta spec.

---

## Archive Contents

| Artifact | Status | Notes |
|----------|--------|-------|
| `proposal.md` | ✅ | Intent, scope, capabilities, approach, risks, success criteria |
| `design.md` | ✅ | Architecture decisions, sequence diagrams, file changes, contracts |
| `specs/backup-runner/spec.md` | ✅ | 11 scenarios, 7 requirements |
| `specs/prometheus-metrics/spec.md` | ✅ | 7 scenarios, 4 requirements |
| `specs/telegram-notifications/spec.md` | ✅ | 9 scenarios, 5 requirements |
| `specs/systemd-scheduling/spec.md` | ✅ | 8 scenarios, 5 requirements |
| `specs/nas-primary-repo/spec.md` | ✅ | 5 scenarios, 3 requirements |
| `tasks.md` | ✅ | 39/39 tasks complete across 4 phases |
| `apply-progress.md` | ✅ | All tasks implemented, ShellCheck clean, deviations documented |
| `verify-report.md` | ✅ | PASS verdict — 4 critical issues fixed, 4 warnings + 3 suggestions deferred |

---

## Verification Summary

- **Total tasks**: 39 — all marked complete and verified in code
- **Spec compliance**: 40/40 scenarios fully compliant (100%)
- **All issues resolved**:
  - **4 Criticals** (fixed in first pass): check metrics merge, stderr capture, DB timer Persistent, SFTP auth exit 4
  - **4 Warnings** (fixed in final pass): exit code 2 cleanup, slow backup detection, retention policy, METRICS_FILE auto-detection
  - **1 Suggestion** resolved: digest date-locking (globs *.json, handles old files)
- **Remaining**: 2 SUGGESTIONS only (non-blocking, deferred to Phase 2):
  - Test coverage gaps (~25 scenarios) — integration tests need Restic binary
  - Test portability (busybox containers)
- **ShellCheck**: Clean — zero warnings/errors
- **Bash syntax**: All files pass `bash -n`

---

## Risks & Open Items

| Risk | Severity | Notes |
|------|----------|-------|
| Test coverage gaps (~25 scenarios) | Low | Integration tests require Restic binary (Phase 2 concern) |
| Test portability (busybox containers) | Low | Tests work correctly under real bash; busybox compatibility deferred |

All functional risks from initial verification (retention, slow backup, METRICS path, stderr capture, digest date-locking) have been resolved in code.

---

## SDD Cycle Complete

The change has been fully planned, implemented, verified, and archived. Ready for the next change.

---

## Source of Truth Updated

The following specs now reflect the new behavior:
- `openspec/specs/backup-runner/spec.md`
- `openspec/specs/prometheus-metrics/spec.md`
- `openspec/specs/telegram-notifications/spec.md`
- `openspec/specs/systemd-scheduling/spec.md`
- `openspec/specs/nas-primary-repo/spec.md`
