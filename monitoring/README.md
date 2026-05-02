# Stowkeeper Monitoring

Prometheus textfile-collector metrics and Alertmanager rules for the Stowkeeper backup system.

## Metrics Reference

All metrics are written to the node_exporter textfile collector directory (`/var/lib/prometheus/node-exporter/stowkeeper.prom` by default).

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `stowkeeper_backup_last_success_timestamp` | gauge | `host`, `job`, `repo` | Unix timestamp of the last successful backup |
| `stowkeeper_backup_duration_seconds` | gauge | `host`, `job`, `repo` | Wall-clock duration of the last backup run |
| `stowkeeper_backup_size_bytes` | gauge | `host`, `job`, `repo` | Size of the last backup snapshot in bytes |
| `stowkeeper_backup_files_new` | gauge | `host`, `job`, `repo` | Number of new files in the last backup |
| `stowkeeper_backup_status` | gauge | `host`, `job`, `repo` | 1 for success, 0 for failure |
| `stowkeeper_check_last_success_timestamp` | gauge | `repo` | Unix timestamp of the last successful restic check |
| `stowkeeper_check_deep_success_timestamp` | gauge | `repo` | Unix timestamp of the last successful deep check (`--read-data-subset`) |
| `stowkeeper_maintenance_status` | gauge | `repo` | 1 for success, 0 for failure |
| `stowkeeper_maintenance_last_success_timestamp` | gauge | `repo` | Unix timestamp of the last successful maintenance run |
| `stowkeeper_repo_size_bytes` | gauge | `repo` | Total repository size in bytes (from `restic stats latest`) |
| `stowkeeper_restore_test_success` | gauge | `repo` | 1 if the last restore test passed, 0 if failed |
| `stowkeeper_restore_test_files_checked` | gauge | `repo` | Number of files sampled during the restore test |
| `stowkeeper_restore_test_files_matched` | gauge | `repo` | Number of sampled files with matching sha256sums |

## Alert Thresholds

| Alert | Expression | Severity | Channel | Threshold |
|-------|------------|----------|---------|-----------|
| **StaleBackup** | `time() - stowkeeper_backup_last_success_timestamp > 108000` | warning | telegram | > 30 hours |
| **StaleCheck** | `time() - stowkeeper_check_last_success_timestamp > 864000` | warning | telegram | > 10 days |
| **GrowthAnomaly** | `(repo_size - repo_size offset 7d) / repo_size offset 7d > 0.5` | critical | telegram,email | > 50% growth in 7 days |

## Files

- `alertmanager/rules.yml` — Prometheus alerting rules
- `grafana/stowkeeper-dashboard.json` — Grafana dashboard template

## Counter File

The deep-check rotation counter is stored at `/var/lib/stowkeeper/check-read-data-month`. It contains a single digit `0-9` and is updated atomically via temp+rename.
