# Design: Phase 1 — Core Backup Pipeline

## Technical Approach

Single Bash wrapper (`backup-runner.sh`) invoked by systemd timers, orchestrating: lock → auth → backup → metrics → notify. Sole entry point for any Restic invocation on the pilot host.

## Architecture Decisions

### Wrapper architecture

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Monolithic script | Simple, single file | ✅ Chosen — Phase 1 |
| Modular lib/ + main | Testable, more files | Phase 2 if complexity grows |

Greenfield with one host; monolithic under 400 LOC is easier to deploy. Extract to `lib/` when Ansible rolls out.

### Lockfile mechanism

| Option | Tradeoff | Decision |
|--------|----------|----------|
| `flock` on fd | Kernel-managed, auto-release on crash | ✅ Chosen |
| PID file + stale check | Race conditions | Rejected |

`flock` releases on process death (even SIGKILL). 60s timeout; exit 75 signals contention to systemd.

### Vault auth (Phase 1)

| Option | Tradeoff | Decision |
|--------|----------|----------|
| `RESTIC_PASSWORD` env var | No Vault dependency | ✅ Chosen (stub) |
| `--password-file` | Safer (not in /proc) | ✅ Fallback |
| AppRole → Vault | Production-grade | Phase 2 |

Pipeline validation must not depend on Vault. `authenticate()` is an explicit stub point.

### Notification deduplication

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Timestamp file per job+type | Simple, survives restart | ✅ Chosen |
| `alertmanager` | Overkill for one host | Phase 4 |

`/var/lib/stowkeeper/dedup/` with mtime-based 4h window per alert-type+job.

### Metric naming

`stowkeeper_*` prefix — node_exporter textfile collector merges all `.prom` files; unique prefix prevents collision.

## Sequence Diagrams

### Backup Execution

```
systemd timer ──▶ backup-runner.sh
                  1. acquire_lock (flock --timeout 60)
                     ├─ timeout → exit 75, warn notification
                  2. load_config (pilot.conf)
                  3. authenticate (env/file stub)
                  4. run_backup (restic backup + args)
                     ├─ capture: exit_code, duration, size, new_files
                  5. write_prometheus_metrics (.prom)
                  6. send_notification
                     ├─ success → append digest queue
                     ├─ failure → immediate Telegram alert (dedup 4h)
                  7. release_lock (exit trap)
                  └──▶ journald (tag=STOWKEEPER)
```

### Restore

```
operator ──▶ backup-runner.sh restore --snapshot <id> --target /tmp/restore
             1. acquire_lock
             2. authenticate
             3. restic snapshots --host <host>
             4. restic restore <id> --target <path>
             5. notify result
```

### Notification Pipeline

```
result ──┬─ SUCCESS ──▶ append to digest/<date>.json
          │                  └─ timer 08:00 ──▶ send_digest() ──▶ Telegram
          ├─ FAILURE ──▶ check dedup/failure-<job>
          │                  ├─ mtime < 4h ──▶ skip
          │                  └─ mtime ≥ 4h ──▶ send_alert() ──▶ Telegram + touch
          └─ WARNING ──▶ same dedup logic, Telegram only
```

## File Changes

| File | Action | Purpose |
|------|--------|---------|
| `src/backup-runner.sh` | Create | Central wrapper |
| `src/configs/pilot.conf` | Create | Host config (paths, exclusions, repo, job defs) |
| `src/systemd/stowkeeper-backup-db.{service,timer}` | Create | Hourly DB dump, RandomizedDelaySec=300 |
| `src/systemd/stowkeeper-backup-files.{service,timer}` | Create | Daily 03:00, Persistent=true |
| `src/systemd/stowkeeper-backup-config.{service,timer}` | Create | Daily 02:00, Persistent=true |
| `src/systemd/stowkeeper-digest.{service,timer}` | Create | Daily 08:00 success digest |
| `src/systemd/stowkeeper-check.{service,timer}` | Create | Weekly Sun 04:00 |

## Directory Layout (Pilot Host)

```
/opt/stowkeeper/
├── backup-runner.sh          # Main wrapper (755)
└── conf/pilot.conf           # Host config (shell-sourceable)
/var/lib/stowkeeper/
├── digest/                   # Success digest queue
└── dedup/                    # Alert dedup timestamps
/var/lib/prometheus/node-exporter/
└── stowkeeper.prom           # Metrics (atomically written)
/var/lock/
└── stowkeeper-backup.lock    # flock lockfile
```

## Contracts

### Exit codes

| 0 | 1 | 3 | 4 | 75 |
|---|---|---|---|----|
| Success | Restic error | Config error | Auth error | Lock contention / timeout |

### Prometheus metrics

`stowkeeper_backup_{last_success_timestamp,duration_seconds,size_bytes,files_new,status}` with labels `{host,job,repo}`. Written atomically to `.prom` via temp file + rename.

### pilot.conf keys

`RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, `BACKUP_PATHS_DB/FILES/CONFIG` (arrays), `EXCLUDE_FILE`, `RETENTION_POLICY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.

## Testing Strategy

| Layer | Target | Approach |
|-------|--------|----------|
| Unit | lock, metrics, notify, dedup | ShellCheck + `bats`; mock restic with stub |
| Integration | Full cycle vs local SFTP repo | Docker SFTP container |
| E2E | Timer fire → backup → metrics → digest | Manual on pilot; Alertmanager in Phase 4 |

## Rollback

Greenfield — no migration. Stop/disable timers, remove script and config. NAS repo stays intact.

## Open Questions

- [ ] Confirm Telegram bot token and chat ID provisioning
- [ ] DB dump strategy: `pg_dump` per-database vs `pg_basebackup`
- [ ] Confirm node_exporter textfile directory path (distro-dependent)