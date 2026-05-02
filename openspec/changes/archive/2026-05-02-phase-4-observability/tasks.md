# Tasks: Phase 4 — Observability & Integrity Verification

## Phase 1: Infrastructure

- [x] 1.1 Create `monitoring/alertmanager/rules.yml` — Prometheus Alertmanager rules: `StaleBackup` (>30h), `StaleCheck` (>10d), `GrowthAnomaly` (>50% WoW) with severity/channel labels and summary/description annotations
- [x] 1.2 Create `monitoring/grafana/` directory (for dashboard JSON later)
- [x] 1.3 Initialize counter file `$RUNTIME_DIR/check-read-data-month` with value `0` (atomically via temp+rename) — placeholder for deep-check rotation; actual increment logic implemented in backup-runner.sh

## Phase 2: Core Implementation

- [x] 2.1 Modify `src/lib/stowkeeper-metrics.sh` — add `emit_deep_check_metrics()`, `emit_restore_test_metrics()`, and `emit_repo_size_metrics()` functions; update counter file read/write to handle the check-read-data-month file
- [x] 2.2 Modify `src/backup-runner.sh check` subcommand — implement deep-check gate: on day ≤ 7, read `$RUNTIME_DIR/check-read-data-month`, if `counter == month_num % 10` run `restic check --read-data-subset=${counter}0%`, emit deep-check metric on success, increment counter mod 10 atomically; add `--read-data` flag handling
- [x] 2.3 Modify `src/backup-runner.sh run_check()` — integrate deep-check path inside the existing per-repo loop; handle `restic check --read-data-subset` fallback to regular `restic check` when conditions not met
- [x] 2.4 Modify `src/backup-runner.sh run_backup()` — after successful backup, emit `stowkeeper_repo_size_bytes{repo}` via `restic stats latest --json`
- [x] 2.5 Create `src/lib/stowkeeper-restore-test.sh` — standalone restore-test script: snapshot lookup (`restic snapshots --latest 1`), restore to `/var/lib/stowkeeper/restore-test/`, sample 20 random files, sha256sum compare vs originals, emit restore-test metrics, send alert on failure, cleanup temp dir
- [x] 2.6 Validate Alertmanager rules: run `amtool check-config monitoring/alertmanager/rules.yml` (install amtool via `apt install alertmanager` or use Docker)

## Phase 3: Systemd Units

- [x] 3.1 Create `src/systemd/stowkeeper-restore-test.service` — oneshot service running `stowkeeper-restore-test.sh` with `Type=oneshot`, correct `User=stowkeeper`, `EnvironmentFile=/opt/stowkeeper/conf/pilot.conf`, `RuntimeDirectory=stowkeeper`
- [x] 3.2 Create `src/systemd/stowkeeper-restore-test.timer` — quarterly timer: `OnCalendar=*-01,04,07,10-01 05:00` with `Persistent=false`, `Unit=stowkeeper-restore-test.service`
- [x] 3.3 Verify timer and service units: run `systemd-analyze verify` on both files; check `OnCalendar` syntax is valid

## Phase 4: Documentation & Validation

- [x] 4.1 Create `monitoring/README.md` — metrics reference: all metric names, labels, types, descriptions, and Prometheus scrape thresholds for each new metric (`stowkeeper_check_deep_success_timestamp`, `stowkeeper_restore_test_success`, `stowkeeper_restore_test_files_checked`, `stowkeeper_restore_test_files_matched`, `stowkeeper_repo_size_bytes`)
- [x] 4.2 Create `monitoring/grafana/stowkeeper-dashboard.json` — Grafana dashboard with panels: backup status (last success, age), repository size (current, growth %), check age (last check, deep check timestamp), restore test status (success, files checked/matched), and alert state indicators
- [x] 4.3 Run `shellcheck` on all new and modified shell scripts (`stowkeeper-restore-test.sh`, `backup-runner.sh`, `stowkeeper-metrics.sh`) — fix all warnings
- [x] 4.4 Run `amtool check-config` on committed `monitoring/alertmanager/rules.yml` — verify YAML syntax and rule validity
- [x] 4.5 Verify counter file atomicity: confirm `check-read-data-month` uses temp+rename pattern (same as `write_metrics_file`)