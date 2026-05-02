# Archive Report — Phase 3: Ansible Role & Multi-Host Rollout

**Change**: phase-3-ansible-role
**Archived**: 2026-05-02
**Verdict**: PASS (0 criticals, 1 warning)

---

## Summary

Ansible role `backup_client` for deploying the Stowkeeper backup pipeline to target hosts. Replaces manual per-host `install.sh` with idempotent, declarative deployment — installing Restic with SHA256 checksum verification, rendering host-specific configs from Jinja2 templates, deploying scripts and systemd units, and conditionally enabling timers based on host capabilities.

## Specs Synced

| Domain | Action | Details |
|--------|--------|---------|
| `ansible-backup-client` | Created | New spec — role idempotency, config templating, static file deployment, conditional timers, post-deploy verification, rollback mode |
| `binary-verification` | Created | New spec — internal mirror download, SHA256 checksum validation, version pinning, checksum mandatory, idempotent binary deployment |
| `host-inventory` | Created | New spec — host variable files, group membership, variable precedence, backup paths, exclusion patterns, secrets encryption |

## Archive Contents

| Artifact | Size | Description |
|----------|------|-------------|
| `proposal.md` | 4.3 KB | Change intent, scope, approach, risks, success criteria |
| `design.md` | 9.0 KB | Architecture decisions, data flow, file changes, interfaces |
| `specs/` | 3 domains | Delta specs for ansible-backup-client, binary-verification, host-inventory |
| `tasks.md` | 4.0 KB | 31 tasks across 4 phases — all complete |
| `apply-progress.md` | 7.5 KB | Implementation progress, validation results, deviations |
| `verify-report.md` | 9.0 KB | Re-verify of 5 critical issues — all PASS |
| `archive-report.md` | This file | |

## Verification Results

- **31/31 tasks completed** (100%)
- **5 critical issues** re-verified: all PASS
  - C-1: `restic_checksum` flows from vault → all.yml → validate → install guard ✅
  - C-2: DB timer explicitly enabled + handler notification ✅
  - C-3: verify.yml executes runtime checks (restic version, systemctl, bash -n) ✅
  - C-4: `db_hosts` flat group — no inverted children relationship ✅
  - C-5: validate.yml checks 10+ critical variables with conditional logic ✅
- **W-1** (non-blocking): Handler notification name case mismatches (3 occurrences)
- **YAML validation**: All 19 YAML files valid

## Source of Truth Updated

The following new specs now reflect the new behavior:
- `openspec/specs/ansible-backup-client/spec.md`
- `openspec/specs/binary-verification/spec.md`
- `openspec/specs/host-inventory/spec.md`

## SDD Cycle Complete

This change has been fully planned, implemented, verified, and archived.
Ready for the next change.
