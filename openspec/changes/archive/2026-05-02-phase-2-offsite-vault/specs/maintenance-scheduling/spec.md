# Maintenance Scheduling Specification

## Purpose

Schedule and execute weekly destructive maintenance operations (forget, prune, check) on the B2 repository from an isolated maintenance host, with lock protection to prevent concurrent maintenance and backup operations.

## Requirements

### Requirement: Maintenance Timer

The system SHALL provide a systemd timer `stowkeeper-maintenance.timer` that triggers weekly on Sunday at 03:00. The companion service `stowkeeper-maintenance.service` SHALL invoke `backup-runner.sh maintenance`. The timer SHALL use `Persistent=true` to catch up on missed runs after downtime.

#### Scenario: Weekly maintenance triggers

- GIVEN the timer is enabled and active
- WHEN Sunday 03:00 arrives
- THEN `backup-runner.sh maintenance` SHALL be invoked

#### Scenario: Maintenance catches up after downtime

- GIVEN the system was powered off on Sunday 03:00
- WHEN the system boots later
- THEN the missed maintenance window SHALL execute (Persistent=true)

### Requirement: B2 Forget and Prune

The maintenance subcommand SHALL execute `restic forget` with the configured retention policy and `--prune` flag against the B2 repository. The maintenance host SHALL use an elevated B2 Application Key with `deleteFiles` and `listFiles` permissions, configured in a separate `maintenance.conf`.

#### Scenario: Successful prune cycle

- GIVEN the maintenance timer fires and B2 is reachable
- WHEN `restic forget --prune` runs with elevated credentials
- THEN expired snapshots SHALL be removed per the retention policy
- AND prune SHALL reclaim space on B2

#### Scenario: Prune fails on B2

- GIVEN `restic forget --prune` encounters an error on B2
- WHEN the maintenance run completes with a non-zero exit code
- THEN a failure alert SHALL be sent via Telegram and email
- AND maintenance metrics SHALL reflect failure

### Requirement: Post-Prune Check

After a successful prune, the system SHALL run `restic check` against B2 to verify repository integrity. If the check fails, a failure alert MUST be sent immediately.

#### Scenario: Check succeeds after prune

- GIVEN `restic forget --prune` completes successfully
- WHEN `restic check` runs against B2
- THEN `stowkeeper_check_last_success_timestamp{repo=b2-secondary}` SHALL be updated
- AND maintenance metrics SHALL be emitted

#### Scenario: Check fails after prune

- GIVEN `restic check` reports errors after prune
- WHEN the check completes with failures
- THEN a failure alert SHALL be sent with high priority
- AND the check metric SHALL NOT be updated

### Requirement: Maintenance Lock

The maintenance subcommand MUST acquire the same lock file (`/var/lock/stowkeeper-backup.lock`) as backup operations. If the lock is held by a backup job, maintenance SHALL wait up to 60 seconds. If the lock cannot be acquired, maintenance SHALL exit with code 75 (lock contention) and alert.

#### Scenario: Maintenance acquires lock

- GIVEN no backup job is running
- WHEN the maintenance timer fires
- THEN the lock SHALL be acquired and maintenance SHALL proceed

#### Scenario: Maintenance lock contention with backup

- GIVEN a backup job currently holds the lock
- WHEN the maintenance timer fires and waits 60 seconds
- THEN if the lock is released, maintenance SHALL proceed
- AND if the lock is NOT released within 60 seconds, maintenance SHALL exit with code 75

#### Scenario: Maintenance preventing concurrent backup

- GIVEN maintenance holds the lock
- WHEN a backup timer fires
- THEN the backup SHALL wait for the lock (same contention behavior)
- AND no concurrent backup+maintenance SHALL occur

### Requirement: Maintenance Metrics

The maintenance run SHALL emit Prometheus metrics: `stowkeeper_maintenance_last_success_timestamp{repo=b2-secondary}` on success, and `stowkeeper_maintenance_status{repo=b2-secondary}` set to 1 (success) or 0 (failure).

#### Scenario: Maintenance metrics on success

- GIVEN maintenance (forget+prune+check) completes successfully
- WHEN metrics are written
- THEN `stowkeeper_maintenance_last_success_timestamp{repo=b2-secondary}` SHALL be set
- AND `stowkeeper_maintenance_status{repo=b2-secondary}` SHALL be 1

#### Scenario: Maintenance metrics on failure

- GIVEN maintenance fails at any step
- WHEN metrics are written
- THEN `stowkeeper_maintenance_status{repo=b2-secondary}` SHALL be 0
- AND `stowkeeper_maintenance_last_success_timestamp` SHALL NOT be updated