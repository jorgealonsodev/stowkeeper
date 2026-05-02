# Design: Phase 4 — Observability & Integrity Verification

## Technical Approach

Extend the existing textfile-collector metrics pipeline with three capabilities: (1) Alertmanager rules that fire on stale timestamps and anomalous growth, (2) a deep-verification mode inside `backup-runner.sh check` that runs `restic check --read-data-subset` monthly with a rotating subset counter, and (3) a standalone `stowkeeper-restore-test.sh` script that quarterly restores from the latest snapshot and validates sha256sums against originals. All new alerts and test results flow through the existing `send_alert` → Telegram + `send_email` → msmtp pipeline.

## Architecture Decisions

### Decision: Deep-check integrated into existing `check` command

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Inline in `check` subcommand | Reuses existing lock, config, auth, loop; single timer | ✅ Chosen |
| Separate `deep-check` subcommand | Cleaner separation; needs new timer + auth boilerplate | Rejected |

Adding a `--read-data-subset` path inside `run_check()` avoids duplicating the multi-repo loop, auth, lock, and metric emission. The `check-read-data-month` counter file gates the deep path.

### Decision: Restore-test as a separate script

| Option | Tradeoff | Decision |
|--------|----------|----------|
| `src/lib/stowkeeper-restore-test.sh` | Independent lifecycle; sources shared libs | ✅ Chosen |
| Subcommand in `backup-runner.sh` | Bloats the runner; very different flow | Rejected |

The restore-test flow (download → sample → compare → report → cleanup) is orthogonal to backup operations. A standalone script sourced by its own systemd unit keeps concerns separated.

### Decision: Alertmanager rules in `monitoring/` not `src/`

| Option | Tradeoff | Decision |
|--------|----------|----------|
| `monitoring/alertmanager/rules.yml` | Follows Prometheus convention; deployable by Ansible | ✅ Chosen |
| `src/alerts/` alongside runner | Couples deployment to app source | Rejected |

Alertmanager rules are configuration, not application code. The `monitoring/` directory mirrors Prometheus convention and aligns with the Ansible-based deployment model.

### Decision: Counter file tracks next subset slot

The `$RUNTIME_DIR/check-read-data-month` counter stores an integer 0–9 representing the **next subset to verify**. Logic: on first check where `day ≤ 7`, if counter matches `month_num % 10`, run `--read-data-subset=${counter}0%` then increment counter mod 10. This ensures each 10% pack group is verified exactly once over a 10-month cycle.

## Data Flow

```
┌─────────────────────────────────────────────────────────┐
│ Alertmanager Pipeline                                   │
│                                                         │
│  .prom file ──→ node_exporter ──→ Prometheus ──→ AM     │
│       │                                         │      │
│       │                        ┌────────────────┘      │
│       │                        ▼                       │
│  StaleBackup >30h?   Telegram + Email (send_alert)    │
│  StaleCheck  >10d?   Telegram + Email                  │
│  GrowthAnomaly>50%?  Telegram + Email                  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ Deep Verification (monthly, inside `check`)          │
│                                                       │
│  systemd timer (weekly) → backup-runner.sh check     │
│       │                                               │
│       ▼                                               │
│  day ≤ 7 AND counter == month%10?                    │
│    YES → restic check --read-data-subset=N0%         │
│           emit stowkeeper_check_deep_success_ts      │
│           counter = (counter + 1) % 10               │
│    NO  → restic check (fast, metadata only)           │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ Restore Test (quarterly)                              │
│                                                       │
│  systemd timer → stowkeeper-restore-test.sh          │
│       │                                               │
│       ▼                                               │
│  restic snapshots --latest 1 → snapshot_id           │
│       │                                               │
│       ▼                                               │
│  restic restore → /var/lib/stowkeeper/restore-test/  │
│       │                                               │
│       ▼                                               │
│  Sample 20 random files → sha256sum vs originals     │
│       │                                               │
│       ▼                                               │
│  emit stowkeeper_restore_test_success{files_checked,  │
│       files_matched} + send_alert with results        │
│       │                                               │
│       ▼                                               │
│  rm -rf restore-test/                                 │
└─────────────────────────────────────────────────────┘
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `monitoring/alertmanager/rules.yml` | Create | Alertmanager rules: StaleBackup (>30h), StaleCheck (>10d), GrowthAnomaly (>50% WoW) |
| `src/backup-runner.sh` | Modify | Add deep-check counter logic inside `run_check()`; add `emit_deep_check_metrics()` |
| `src/lib/stowkeeper-metrics.sh` | Modify | Add `emit_deep_check_metrics()` and `emit_restore_test_metrics()` functions |
| `src/lib/stowkeeper-restore-test.sh` | Create | Standalone script: snapshot lookup, restore, sample, sha256sum compare, report |
| `src/systemd/stowkeeper-restore-test.service` | Create | Oneshot service running restore-test.sh |
| `src/systemd/stowkeeper-restore-test.timer` | Create | Quarterly timer (Sun Jan/Apr/Jul/Oct 1st 05:00) |
| `monitoring/README.md` | Create | Metrics reference: all metric names, labels, types, thresholds |
| `monitoring/grafana/stowkeeper-dashboard.json` | Create | Grafana dashboard JSON with backup status, repo size, check age, restore test panels |

## Interfaces / Contracts

### New Metric: `stowkeeper_check_deep_success_timestamp`

```
# HELP stowkeeper_check_deep_success_timestamp Unix timestamp of last successful deep check (--read-data-subset)
# TYPE stowkeeper_check_deep_success_timestamp gauge
stowkeeper_check_deep_success_timestamp{repo="nas-primary"} 1746230400
```

### New Metric: `stowkeeper_restore_test_success`

```
# HELP stowkeeper_restore_test_success 1 if last restore test passed, 0 if failed
# TYPE stowkeeper_restore_test_success gauge
stowkeeper_restore_test_success{repo="nas-primary"} 1
stowkeeper_restore_test_files_checked{repo="nas-primary"} 20
stowkeeper_restore_test_files_matched{repo="nas-primary"} 20
```

### New Metric: `stowkeeper_repo_size_bytes` (for growth alerting)

```
# HELP stowkeeper_repo_size_bytes Total repository size in bytes (from restic stats)
# TYPE stowkeeper_repo_size_bytes gauge
stowkeeper_repo_size_bytes{repo="nas-primary"} 45678901234
```

### Counter File Format: `$RUNTIME_DIR/check-read-data-month`

Single integer 0–9, no newline. Read/written atomically via temp+rename pattern (matching `write_metrics_file` convention).

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Unit | Counter logic (day ≤ 7, slot match, increment) | Bash script with mocked `date`; verify counter file updates |
| Unit | `emit_deep_check_metrics` output format | Source lib, call function, assert .prom content |
| Unit | Restore-test sha256sum comparison | Create temp tree, snapshot, restore, compare with forced mismatch |
| Integration | Deep-check end-to-end with test restic repo | Run `backup-runner.sh check` with counter set to trigger deep path |
| Integration | Alertmanager rule validation | `amtool check-config` on committed rules.yml |
| Integration | Restore-test timer activation | `systemd-analyze verify` on service/timer units |

## Migration / Rollout

1. Create `monitoring/` directory structure and Alertmanager rules
2. Deploy `check-read-data-month` counter initialized to 0 in `/var/lib/stowkeeper/`
3. Deploy updated `backup-runner.sh` and `stowkeeper-metrics.sh`
4. Deploy `stowkeeper-restore-test.sh` and systemd units; **keep timer disabled** initially
5. Run manual restore-test to validate; then enable timer
6. Add Alertmanager rules to Prometheus config and reload
7. Rollback: disable new timers, remove AM rules, git revert runner and metrics scripts, delete counter file

## Open Questions

- [ ] Confirm quarterly schedule (Jan/Apr/Jul/Oct first Sunday 05:00) with operations team
- [ ] Decide: should restore-test sample size (20) be configurable via env var?