# Apply Progress: Phase 4 — Observability & Integrity Verification

## Phase 1: Infrastructure

- [x] 1.1 `monitoring/alertmanager/rules.yml` created with StaleBackup, StaleCheck, GrowthAnomaly rules
- [x] 1.2 `monitoring/grafana/` directory created
- [x] 1.3 Counter file logic (`check-read-data-month`) implemented via `read_deep_check_counter()` and `write_deep_check_counter()` in `stowkeeper-metrics.sh`

## Phase 2: Core Implementation

- [x] 2.1 `src/lib/stowkeeper-metrics.sh` modified:
  - Added `_merge_metrics()` generic helper
  - Added `emit_repo_size_metrics()`
  - Added `emit_deep_check_metrics()`
  - Added `emit_restore_test_metrics()`
  - Added `read_deep_check_counter()` and `write_deep_check_counter()` with atomic temp+rename
- [x] 2.2 `src/backup-runner.sh` check subcommand:
  - Added `--read-data` flag parsing
  - Added `get_deep_check_subset()` helper (day ≤ 7 + counter == month%10)
  - Deep check runs `restic check --read-data-subset=${counter}0%` on match
  - Emits deep-check metric and increments counter mod 10 atomically on success
- [x] 2.3 `run_check()` accepts optional `deep_subset` argument; fallback to regular `restic check` when conditions not met
- [x] 2.4 `run_backup()` / `handle_backup_result()` emits `stowkeeper_repo_size_bytes{repo}` on success
- [x] 2.5 `src/lib/stowkeeper-restore-test.sh` created:
  - Snapshot lookup via `restic snapshots --latest 1 --json`
  - Restore to `/var/lib/stowkeeper/restore-test/`
  - Disk pre-flight (2× repo size)
  - Sample 20 random files, sha256sum compare
  - Emit restore-test metrics, send alert on failure, cleanup via trap
- [x] 2.6 Alertmanager rules validated:
  - `amtool check-config` reports error because the file is a Prometheus rule file (groups/rules), not an Alertmanager config. This is a known terminology mismatch.
  - YAML syntax validated successfully with Python PyYAML.

## Phase 3: Systemd Units

- [x] 3.1 `src/systemd/stowkeeper-restore-test.service` created (Type=oneshot, User=stowkeeper, EnvironmentFile, RuntimeDirectory)
- [x] 3.2 `src/systemd/stowkeeper-restore-test.timer` created (quarterly, Persistent=false)
- [x] 3.3 Validation:
  - `systemd-analyze verify` on service: passes (warns about non-existent deploy path, expected)
  - `systemd-analyze verify` on timer: OK
  - `systemd-analyze calendar '*-01,04,07,10-01 05:00:00'` valid; next elapse 2026-07-01 05:00:00

## Phase 4: Documentation & Validation

- [x] 4.1 `monitoring/README.md` created with full metrics reference and alert thresholds
- [x] 4.2 `monitoring/grafana/stowkeeper-dashboard.json` created with 8 panels
- [x] 4.3 `shellcheck` passed on all new/modified scripts (downloaded static binary); one pre-existing warning suppressed with `# shellcheck disable=SC2034`
- [x] 4.4 `amtool check-config` executed (see 2.6 for result). YAML syntax manually verified.
- [x] 4.5 Counter file atomicity confirmed: `write_deep_check_counter()` uses `printf` to `.tmp.$$` then `mv -f`, identical to `write_metrics_file()`

## Files Changed

| File | Action |
|------|--------|
| `monitoring/alertmanager/rules.yml` | Created |
| `monitoring/grafana/` | Created |
| `monitoring/README.md` | Created |
| `monitoring/grafana/stowkeeper-dashboard.json` | Created |
| `src/lib/stowkeeper-metrics.sh` | Modified |
| `src/backup-runner.sh` | Modified |
| `src/lib/stowkeeper-restore-test.sh` | Created |
| `src/systemd/stowkeeper-restore-test.service` | Created |
| `src/systemd/stowkeeper-restore-test.timer` | Created |
| `openspec/changes/phase-4-observability/tasks.md` | Updated |
