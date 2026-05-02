# Prometheus Metrics Specification

## Purpose

Export backup operational metrics via Prometheus textfile collector format for node_exporter scraping, providing observability into backup health, timing, and data volume.

## Requirements

### Requirement: Atomic Metric Write

The system MUST write metrics to a `.prom` file atomically (temp file + rename) to prevent partial reads by node_exporter. The target path SHALL be `/var/lib/prometheus/node-exporter/stowkeeper.prom`.

#### Scenario: Atomic metric write on success

- GIVEN a backup job completes
- WHEN metrics are written
- THEN a temp file SHALL be created with the new content
- AND the temp file SHALL be renamed to `stowkeeper.prom`
- AND at no point SHALL a partial or empty `.prom` file be visible to node_exporter

#### Scenario: Metric write on failure

- GIVEN a backup job fails
- WHEN metrics are written
- THEN `stowkeeper_backup_status` SHALL be set to 0
- AND `stowkeeper_backup_last_success_timestamp` SHALL retain its previous value (not overwritten on failure)

### Requirement: Backup Metrics

The system SHALL expose the following metrics with labels `{host, job, repo}`:

| Metric | Type | Description |
|--------|------|-------------|
| `stowkeeper_backup_last_success_timestamp` | gauge | Unix timestamp of last successful backup |
| `stowkeeper_backup_duration_seconds` | gauge | Wall-clock duration of last backup run |
| `stowkeeper_backup_size_bytes` | gauge | Size of last backup snapshot in bytes |
| `stowkeeper_backup_files_new` | gauge | Number of new files in last backup |
| `stowkeeper_backup_status` | gauge | 1 for success, 0 for failure |

#### Scenario: Metrics after successful backup

- GIVEN a backup job completes with exit code 0
- WHEN metrics are written
- THEN `stowkeeper_backup_last_success_timestamp{host,job,repo}` SHALL be set to current Unix timestamp
- AND `stowkeeper_backup_status{host,job,repo}` SHALL be 1
- AND `stowkeeper_backup_duration_seconds{host,job,repo}` SHALL reflect elapsed seconds
- AND `stowkeeper_backup_size_bytes{host,job,repo}` SHALL reflect snapshot size

#### Scenario: Metrics after failed backup

- GIVEN a backup job exits non-zero
- WHEN metrics are written
- THEN `stowkeeper_backup_status{host,job,repo}` SHALL be 0
- AND `stowkeeper_backup_last_success_timestamp` SHALL NOT be updated
- AND `stowkeeper_backup_duration_seconds` SHALL reflect elapsed seconds until failure

### Requirement: Metric Naming Convention

All metrics MUST use the `stowkeeper_` prefix. Labels MUST include `host` (hostname), `job` (db|files|config), and `repo` (nas-primary) to distinguish metrics across multiple dimensions.

#### Scenario: Metric collision prevention

- GIVEN node_exporter collects `.prom` files from multiple sources
- WHEN stowkeeper metrics are loaded
- THEN the `stowkeeper_` prefix SHALL prevent collision with existing node_exporter metrics
- AND all metrics SHALL be scrapable without conflicts

### Requirement: Check Metrics

The system SHALL expose `stowkeeper_check_last_success_timestamp{repo}` after successful `restic check` execution.

#### Scenario: Check metric after weekly verification

- GIVEN `restic check` completes successfully
- WHEN check metrics are written
- THEN `stowkeeper_check_last_success_timestamp{repo}` SHALL be updated to current Unix timestamp

#### Scenario: Check metric after failed verification

- GIVEN `restic check` fails
- WHEN check metrics are written
- THEN `stowkeeper_check_last_success_timestamp` SHALL NOT be updated