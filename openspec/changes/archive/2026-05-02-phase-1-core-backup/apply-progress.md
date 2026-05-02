# Apply Progress: phase-1-core-backup

## Change
phase-1-core-backup — Core Backup Pipeline

## Mode
Standard (strict_tdd: false, bats not installed)

## Completed Tasks

### Phase 1: Infrastructure & Directory Layout (6/6)
- [x] 1.1 Create `/var/lib/stowkeeper/digest/` directory for success digest queue
- [x] 1.2 Create `/var/lib/stowkeeper/dedup/` directory for alert deduplication timestamps
- [x] 1.3 Create `/var/lock/stowkeeper-backup.lock` lockfile (flock managed)
- [x] 1.4 Create `/var/lib/prometheus/node-exporter/stowkeeper.prom` placeholder
- [x] 1.5 Create `/opt/stowkeeper/conf/` directory for pilot configuration
- [x] 1.6 Create `/opt/stowkeeper/` directory for backup-runner.sh placement

### Phase 2: Core Implementation (16/16)
- [x] 2.1 Create `src/configs/pilot.conf`
- [x] 2.2 Create `src/backup-runner.sh`
- [x] 2.3 Implement `load_config()`
- [x] 2.4 Implement `authenticate()` stub
- [x] 2.5 Implement `run_backup()`
- [x] 2.6 Implement `run_backup() stdin mode`
- [x] 2.7 Implement `list_snapshots()`
- [x] 2.8 Implement `restore_snapshot()`
- [x] 2.9 Implement `init_repo()`
- [x] 2.10 Create `src/lib/stowkeeper-metrics.sh`
- [x] 2.11 Emit backup metrics
- [x] 2.12 Emit check metrics
- [x] 2.13 Create `src/lib/stowkeeper-notify.sh`
- [x] 2.14 Implement dedup logic
- [x] 2.15 Implement success digest accumulation
- [x] 2.16 Implement `send_digest()`

### Phase 3: Systemd Timer Units (10/10)
- [x] 3.1 stowkeeper-backup-db.service
- [x] 3.2 stowkeeper-backup-db.timer
- [x] 3.3 stowkeeper-backup-files.service
- [x] 3.4 stowkeeper-backup-files.timer
- [x] 3.5 stowkeeper-backup-config.service
- [x] 3.6 stowkeeper-backup-config.timer
- [x] 3.7 stowkeeper-digest.service
- [x] 3.8 stowkeeper-digest.timer
- [x] 3.9 stowkeeper-check.service
- [x] 3.10 stowkeeper-check.timer

### Phase 4: Testing (7/7)
- [x] 4.1 Write bats tests — lock acquisition
- [x] 4.2 Write bats tests — metrics atomic write
- [x] 4.3 Write bats tests — dedup logic
- [x] 4.4 Write bats tests — config loading
- [x] 4.5 Write bats tests — notify stub
- [x] 4.6 Run ShellCheck — all files pass
- [x] 4.7 Verify spec scenario mapping (40 scenarios mapped)

## Files Created

| File | Lines | Purpose |
|------|-------|---------|
| `src/backup-runner.sh` | 459 | Central wrapper script |
| `src/lib/stowkeeper-metrics.sh` | 81 | Prometheus metrics library |
| `src/lib/stowkeeper-notify.sh` | 160 | Telegram notifications library |
| `src/configs/pilot.conf` | 38 | Host configuration template |
| `install.sh` | 51 | Runtime directory installer |
| `tests/backup-runner.bats` | 115 | Bats test suite |
| `src/systemd/stowkeeper-backup-db.service` | 10 | DB backup service |
| `src/systemd/stowkeeper-backup-db.timer` | 10 | DB backup timer (hourly) |
| `src/systemd/stowkeeper-backup-files.service` | 10 | Files backup service |
| `src/systemd/stowkeeper-backup-files.timer` | 11 | Files backup timer (daily 03:00) |
| `src/systemd/stowkeeper-backup-config.service` | 10 | Config backup service |
| `src/systemd/stowkeeper-backup-config.timer` | 10 | Config backup timer (daily 02:00) |
| `src/systemd/stowkeeper-digest.service` | 10 | Digest service |
| `src/systemd/stowkeeper-digest.timer` | 10 | Digest timer (daily 08:00) |
| `src/systemd/stowkeeper-check.service` | 10 | Check service |
| `src/systemd/stowkeeper-check.timer` | 10 | Check timer (weekly Sun 04:00) |

**Total: ~1005 lines**

## Verification Summary

### ShellCheck
- All `.sh` files pass `shellcheck -x` with zero warnings/errors.
- `tests/backup-runner.bats` passes with `shellcheck shell=bash disable=SC2030,SC2031`.

### Bats
- `bats` not installed on host; tests written but not executed.
- Tests can be run after `apt-get install bats`.

### Syntax
- All Bash files pass `bash -n` syntax check.

## Deviations from Design

1. **SSH pre-check**: The spec requires exit code 4 for SFTP authentication failure. The current implementation treats SSH/SFTP failures as Restic errors (exit 1). Pre-checking SSH connectivity is not implemented in Phase 1; can be added in Phase 2.

2. **DB timer Persistent**: The spec says "only the most recent missed DB backup SHALL run". The hourly DB timer does NOT use `Persistent=true`, so missed backups are skipped entirely rather than running just the latest missed one. A custom catch-up script would be needed for exact compliance.

3. **Email notifications**: Phase 1 uses Telegram only, as specified. Email via `msmtp` is reserved for Phase 2.

## Risks

- **bats not installed**: Unit tests are written but cannot be executed in this environment.
- **No restic binary**: Integration tests against a real Restic repository are not possible.
- **SSH pre-check gap**: SFTP auth failures return exit 1 instead of exit 4 per spec.
- **DB timer catch-up**: Missed hourly DB backups are not automatically replayed.

## Post-Verification Fixes (5 issues resolved)

- [x] **Fix 1 — Retention Policy**: Added `run_forget()` to `backup-runner.sh` that runs `restic forget` with `RETENTION_POLICY` from `pilot.conf`. Daily forget (no prune) runs in `digest` command; weekly forget with `--prune` runs in `check` command before `restic check`.
- [x] **Fix 2 — Slow Backup Warning**: Added `track_backup_duration()` and `is_slow_backup()` to `stowkeeper-metrics.sh`. After each backup, duration is tracked (last 30 entries). If current duration > 2× median, a warning alert is sent via `send_alert()`.
- [x] **Fix 3 — METRICS_FILE Auto-Detection**: `stowkeeper-metrics.sh` now auto-detects node_exporter textfile collector directory (`/var/lib/prometheus/node-exporter/`, `/var/lib/node_exporter/textfile_collector/`, `/opt/prometheus/textfile/`). `install.sh` updated to detect/create the correct metrics directory.
- [x] **Fix 4 — Digest Date-Locking**: `send_digest()` now globs all `*.json` files in `DIGEST_DIR`, sends each one, and removes after successful delivery. Files older than 7 days are skipped and removed.
- [x] **Fix 5 — Exit Code 2 Cleanup**: Removed exit code 2 from the design doc's exit codes table; updated `backup-runner.sh` usage to clarify exit 75 covers both lock timeout and contention.

## Next Recommended Phase
verify

## Skill Resolution
- sdd-apply (standard mode)
- No TDD module loaded (strict_tdd: false)
