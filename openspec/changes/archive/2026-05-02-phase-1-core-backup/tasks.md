# Tasks: phase-1-core-backup — Core Backup Pipeline

## Phase 1: Infrastructure & Directory Layout

- [x] 1.1 Create `/var/lib/stowkeeper/digest/` directory for success digest queue
- [x] 1.2 Create `/var/lib/stowkeeper/dedup/` directory for alert deduplication timestamps
- [x] 1.3 Create `/var/lock/stowkeeper-backup.lock` lockfile (flock managed)
- [x] 1.4 Create `/var/lib/prometheus/node-exporter/stowkeeper.prom` placeholder
- [x] 1.5 Create `/opt/stowkeeper/conf/` directory for pilot configuration
- [x] 1.6 Create `/opt/stowkeeper/` directory for backup-runner.sh placement

## Phase 2: Core Implementation

- [x] 2.1 Create `src/configs/pilot.conf` — shell-sourceable config with RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, BACKUP_PATHS_DB/FILES/CONFIG, EXCLUDE_FILE, RETENTION_POLICY, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
- [x] 2.2 Create `src/backup-runner.sh` — main wrapper with lock acquisition via `flock --timeout 60 /var/lock/stowkeeper-backup.lock` (exit 75 on contention)
- [x] 2.3 Implement `load_config()` in backup-runner.sh — source pilot.conf, validate required keys, exit 3 on missing config
- [x] 2.4 Implement `authenticate()` stub in backup-runner.sh — read RESTIC_PASSWORD_FILE into env (Phase 2 will add Vault)
- [x] 2.5 Implement `run_backup()` in backup-runner.sh — `restic backup` with paths/exclusions from pilot.conf; dump DB to temp, backup, remove dump
- [x] 2.6 Implement `run_backup() stdin mode` — pipe large DB dumps via `restic backup --stdin` (no intermediate file)
- [x] 2.7 Implement `list_snapshots()` in backup-runner.sh — `restic snapshots --host <hostname>` for restore
- [x] 2.8 Implement `restore_snapshot()` in backup-runner.sh — `restic restore <id> --target <path>` with optional `--path` flag
- [x] 2.9 Implement `init_repo()` in backup-runner.sh — `restic init` on empty repo; skip if repo exists
- [x] 2.10 Create `src/lib/stowkeeper-metrics.sh` — write metrics atomically (temp file + rename) to stowkeeper.prom with labels {host,job,repo}
- [x] 2.11 Emit `stowkeeper_backup_{last_success_timestamp,duration_seconds,size_bytes,files_new,status}` metrics after each backup
- [x] 2.12 Emit `stowkeeper_check_last_success_timestamp{repo}` after `restic check`
- [x] 2.13 Create `src/lib/stowkeeper-notify.sh` — send Telegram alerts via bot API; append success to digest queue
- [x] 2.14 Implement dedup logic in notify — 4h window per alert-type+job using mtime on `/var/lib/stowkeeper/dedup/failure-<job>`
- [x] 2.15 Implement success digest accumulation in `digest/<date>.json` — job name, timestamp, duration, size
- [x] 2.16 Implement `send_digest()` — read `digest/<date>.json`, send consolidated 08:00 message, delete file after send

## Phase 3: Systemd Timer Units

- [x] 3.1 Create `src/systemd/stowkeeper-backup-db.service` — invokes `backup-runner.sh backup --job db`
- [x] 3.2 Create `src/systemd/stowkeeper-backup-db.timer` — hourly, RandomizedDelaySec=300
- [x] 3.3 Create `src/systemd/stowkeeper-backup-files.service` — invokes `backup-runner.sh backup --job files`
- [x] 3.4 Create `src/systemd/stowkeeper-backup-files.timer` — daily 03:00, Persistent=true, RandomizedDelaySec=1800
- [x] 3.5 Create `src/systemd/stowkeeper-backup-config.service` — invokes `backup-runner.sh backup --job config`
- [x] 3.6 Create `src/systemd/stowkeeper-backup-config.timer` — daily 02:00, Persistent=true
- [x] 3.7 Create `src/systemd/stowkeeper-digest.service` — invokes `send_digest()`
- [x] 3.8 Create `src/systemd/stowkeeper-digest.timer` — daily 08:00
- [x] 3.9 Create `src/systemd/stowkeeper-check.service` — invokes `backup-runner.sh check` (runs `restic check`)
- [x] 3.10 Create `src/systemd/stowkeeper-check.timer` — weekly Sunday 04:00

## Phase 4: Testing

- [x] 4.1 Write `tests/backup-runner.bats` — test lock acquisition (contention → exit 75)
- [x] 4.2 Write `tests/backup-runner.bats` — test metrics atomic write (temp + rename pattern)
- [x] 4.3 Write `tests/backup-runner.bats` — test dedup logic (4h window suppression)
- [x] 4.4 Write `tests/backup-runner.bats` — test config loading (exit 3 on missing keys)
- [x] 4.5 Write `tests/backup-runner.bats` — test notify stub (success → digest queue, failure → immediate alert)
- [x] 4.6 Run ShellCheck on `src/backup-runner.sh`, `src/lib/*.sh` — fix all SC warnings
- [x] 4.7 Verify all 38 spec scenarios map to at least one task above

(End of file - total 52 lines)
