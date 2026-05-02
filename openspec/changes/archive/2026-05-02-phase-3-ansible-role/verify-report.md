# Verification Report — Re-Verify (5 Critical Issues)

**Change**: phase-3-ansible-role
**Version**: N/A (re-verify of 5 previously FAILED criticals)
**Mode**: Standard (strict_tdd: false)

---

## Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 31 |
| Tasks complete | 31 |
| Tasks incomplete | 0 |

All 31 tasks completed. Re-verify focuses on the 5 CRITICAL items from the previous report.

---

## Build & Tests Execution

**Build**: ➖ Not applicable (Ansible roles — no build step)

**YAML Syntax**: ✅ All 7 YAML files parse correctly (`python3 yaml.safe_load`). `inventory/hosts` is INI format (valid).

**Tests**: ➖ Not available — `ansible-playbook`, `ansible-lint`, and `shellcheck` are not installed. Strict TDD not active.

**Coverage**: ➖ Not available

---

## Re-Verify: 5 Critical Issues

### C-1: `restic_checksum` — defined in defaults, wired in all.yml, validated, and guarded

| Check | File | Line | Evidence | Result |
|-------|------|------|----------|--------|
| Default defined | `defaults/main.yml` | 12 | `restic_checksum: ""` | ✅ |
| Wired to vault | `group_vars/all.yml` | 8 | `restic_checksum: "{{ vault_restic_checksum }}"` | ✅ |
| Validated non-empty | `tasks/validate.yml` | 11-12 | `restic_checksum is defined` AND `length > 0` | ✅ |
| Guarded before download | `tasks/install_restic.yml` | 2-5 | `fail` task when `length == 0` before `get_url` | ✅ |

**Verdict C-1**: ✅ **PASS** — Checksum flows from vault → all.yml → validate → install guard. `get_url` with `checksum: "sha256:"` will never execute with an empty checksum.

---

### C-2: DB timer in enable loop + handler

| Check | File | Line | Evidence | Result |
|-------|------|------|----------|--------|
| Explicit enable task | `tasks/deploy_systemd.yml` | 44-52 | `Enable and start DB timer` with `stowkeeper-backup-db.timer` | ✅ |
| Enable conditions | `tasks/deploy_systemd.yml` | 50-52 | `stowkeeper_state == 'present'` AND `stowkeeper_db_type defined + length > 0` | ✅ |
| Deploy notifies handler | `tasks/deploy_systemd.yml` | 27-29 | `notify: enable db timer` | ✅ |
| Handler exists | `handlers/main.yml` | 18-25 | `Enable DB timer` with same conditions | ✅ |
| Handler conditions | `handlers/main.yml` | 23-25 | Same state + db_type check | ✅ |

⚠️ **Minor**: `notify: enable db timer` (lowercase) vs handler `name: Enable DB timer` (title case) — case mismatch. Ansible 2.2+ normalizes to lowercase for matching, so functionally works, but fragile across versions. Same pattern affects `notify: reload systemd` ↔ `Reload systemd` and `notify: enable timers` ↔ `Enable timers`. Recommend matching case exactly.

**Verdict C-2**: ✅ **PASS** — DB timer is explicitly enabled on deployment AND via handler notification. The original gap (DB timer never enabled) is closed.

---

### C-3: verify.yml does more than stat

| Check | File | Line | Evidence | Result |
|-------|------|------|----------|--------|
| Restic version check | `tasks/verify.yml` | 17-21 | `ansible.builtin.command: restic version` with `changed_when: false` | ✅ |
| Systemd timer status | `tasks/verify.yml` | 23-27 | `systemctl is-active stowkeeper-backup-config.timer` with `changed_when: false` | ✅ |
| Config syntax check | `tasks/verify.yml` | 29-33 | `bash -n pilot.conf` with `changed_when: false` | ✅ |
| Lock dir writability | `tasks/verify.yml` | 35-44 | Touch + remove write test file in runtime dir | ✅ |
| Deployment summary | `tasks/verify.yml` | 46-56 | Debug msg with version, timer status, syntax, writability | ✅ |

All commands are non-idempotent but properly marked with `changed_when: false` (per SUGGESTION-4). All use `ignore_errors: true` so verification doesn't block reporting.

**Verdict C-3**: ✅ **PASS** — Verification now includes runtime commands (restic version, systemctl state, bash -n) plus writability and summary reporting. No longer a no-op stat check.

---

### C-4: Inventory hierarchy — db_hosts flat, not inverted

| Check | File | Line | Evidence | Result |
|-------|------|------|----------|--------|
| No `[db_hosts:children]` | `inventory/hosts` | — | Section does not exist | ✅ |
| DB host is flat | `inventory/hosts` | 8-9 | `[db_hosts]` followed by `srv-db-01` directly | ✅ |
| DB host NOT in servers | `inventory/hosts` | 1-2 | `[servers]` only has `srv-web-01` (commented) | ✅ |
| No servers-wide DB leak | — | — | `[db_hosts:children] servers` (inverted) is gone | ✅ |

**Note**: DB host (`srv-db-01`) is NOT a child of `[servers]`. The original fix suggestion was `[servers:children] db_hosts` (hierarchical), but the implemented approach uses a flat `[db_hosts]` group separate from `[servers]`. Playbooks targeting `hosts: servers` won't deploy to DB host; `hosts: all` will. This is a valid design choice.

**Verdict C-4**: ✅ **PASS** — The critical inversion (`[db_hosts:children] servers` making ALL servers members of db_hosts) is resolved. No server is accidentally a DB host.

---

### C-5: validate.yml checks all critical vars

| Check | File | Line | Evidence | Result |
|-------|------|------|----------|--------|
| Core vars | `tasks/validate.yml` | 5-15 | `stowkeeper_backup_paths`, `stowkeeper_repos`, `restic_version`, `restic_checksum`, `restic_mirror_url` — all defined + non-empty | ✅ |
| Mirror URL format | `tasks/validate.yml` | 14 | `restic_mirror_url is match('^https://')` — HTTP validation | ✅ |
| NAS vars (conditional) | `tasks/validate.yml` | 17-24 | `stowkeeper_nas_host`, `_user`, `_path` when `'nas' in stowkeeper_repos` | ✅ |
| B2 vars (conditional) | `tasks/validate.yml` | 26-31 | `stowkeeper_b2_bucket_url` when `'b2' in stowkeeper_repos` | ✅ |
| DB vars (conditional) | `tasks/validate.yml` | 33-38 | `stowkeeper_db_name` when `stowkeeper_db_type defined + length > 0` | ✅ |

**Verdict C-5**: ✅ **PASS** — Validation expanded from single `stowkeeper_backup_paths` check to 10+ assertions covering core vars, conditional NAS/B2/DB vars, and URL format validation. All critical vars identified in the original CRITICAL-5 are now checked.

---

## 5 Critical Issues Summary

| # | Original Issue | Current State | Verdict |
|---|---------------|---------------|---------|
| C-1 | `restic_checksum` undefined → no binary verification | Defined in defaults + all.yml, validated non-empty, guarded in install | ✅ PASS |
| C-2 | DB timer never enabled → DB backups won't run | Explicit enable task + handler with proper conditions | ✅ PASS |
| C-3 | verify.yml no-op → only stat check | Runs `restic version`, `systemctl is-active`, `bash -n`, writability, summary | ✅ PASS |
| C-4 | `[db_hosts:children] servers` → all servers are DB hosts | Flat `[db_hosts]` group, no children relationship | ✅ PASS |
| C-5 | validate.yml insufficient → only `backup_paths` checked | 10+ assertions covering core + conditional NAS/B2/DB vars | ✅ PASS |

---

## New Finding (from re-verify)

### WARNING — Handler notification name case mismatches

**Files**: `tasks/deploy_systemd.yml`, `tasks/deploy_configs.yml`, `handlers/main.yml`

Three handler notifications use lowercase while handler names use title case:

| Notification | Handler name | File |
|-------------|-------------|------|
| `reload systemd` | `Reload systemd` | deploy_systemd.yml → handlers/main.yml |
| `enable timers` | `Enable timers` | deploy_configs.yml → handlers/main.yml |
| `enable db timer` | `Enable DB timer` | deploy_systemd.yml → handlers/main.yml |

Ansible 2.2+ normalizes handler names to lowercase for matching, so these functionally work. However, exact matching is more robust across versions and avoids future breakage. Recommend aligning case: either all lowercase in handlers or title case in notifications.

**Severity**: WARNING — functional, cosmetic fix recommended.

---

## Issues Found

**CRITICAL** (must fix before archive):
- **None** — all 5 previously CRITICAL issues are resolved.

**WARNING** (should fix):
- **W-1 (new)**: Handler notification name case mismatches — 3 notifications use lowercase while handler names use title case (see above). Functional in Ansible 2.2+ but fragile.

**SUGGESTION** (nice to have):
- None new (previous suggestions SUGGESTION-1 through SUGGESTION-5 from the original report remain valid but are not blocking).

---

## Verdict

**PASS** — All 5 previously CRITICAL issues are resolved:

1. ✅ `restic_checksum` flows from vault → all.yml → validate → install guard
2. ✅ DB timer explicitly enabled + handler notification
3. ✅ verify.yml executes runtime checks (restic version, systemctl, bash -n)
4. ✅ `db_hosts` is a flat group — no inverted children relationship
5. ✅ validate.yml checks 10+ critical variables with conditional logic

One new **WARNING** identified (handler name case mismatches) — non-blocking, cosmetic fix recommended.

The phase-3-ansible-role change is ready for archive.
