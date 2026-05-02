# Systemd Scheduling Specification

## Purpose

Timer and service unit definitions that schedule backup, integrity check, and digest notification jobs on the pilot host with proper persistence and randomization.

## Requirements

### Requirement: Database Backup Timer

The system SHALL provide a systemd timer unit `stowkeeper-backup-db.timer` that triggers hourly database dump backups. The companion service unit `stowkeeper-backup-db.service` SHALL invoke `backup-runner.sh backup --job db`. The timer SHALL apply `RandomizedDelaySec=300` to spread execution across a 5-minute window and avoid I/O storms.

#### Scenario: Hourly DB backup fires

- GIVEN the timer is enabled and active
- WHEN the hourly interval elapses
- THEN a DB dump backup SHALL be initiated
- AND execution SHALL be delayed by 0–300 seconds randomly

#### Scenario: DB timer catches up after downtime

- GIVEN the system was powered off for several hours
- WHEN the system boots and the timer activates
- THEN only the most recent missed DB backup SHALL run (not all missed intervals)

### Requirement: File Backup Timer

The system SHALL provide a systemd timer unit `stowkeeper-backup-files.timer` that triggers daily at 03:00 for file system backups. The timer SHALL use `Persistent=true` to catch up on missed runs after downtime. `RandomizedDelaySec=1800` SHALL add up to 30 minutes of jitter.

#### Scenario: File backup after downtime

- GIVEN the system was powered off at 03:00
- WHEN the system boots later that day
- THEN the missed file backup SHALL execute (Persistent=true)

### Requirement: Config Backup Timer

The system SHALL provide a systemd timer unit `stowkeeper-backup-config.timer` that triggers daily at 02:00 for `/etc` and configuration path backups. The timer SHALL use `Persistent=true`.

#### Scenario: Config backup runs daily

- GIVEN the timer is enabled
- WHEN 02:00 arrives
- THEN a config backup SHALL be initiated

### Requirement: Weekly Integrity Check

The system SHALL provide a systemd timer unit `stowkeeper-check.timer` that triggers weekly on Sunday at 04:00. The service unit SHALL invoke `backup-runner.sh check`, which runs `restic check` (structural verification without reading all data).

#### Scenario: Weekly check triggers

- GIVEN the timer is enabled
- WHEN Sunday 04:00 arrives
- THEN `restic check` SHALL be executed against the repository

#### Scenario: Check detects repository corruption

- GIVEN `restic check` reports errors
- WHEN the check completes
- THEN a failure alert SHALL be sent via Telegram (highest priority)

### Requirement: Digest Notification Timer

The system SHALL provide `stowkeeper-digest.timer` that triggers daily at 08:00, invoking `stowkeeper-digest.service` to send the consolidated success digest.

#### Scenario: Digest fires with successes

- GIVEN the timer is enabled and success entries exist in the digest queue
- WHEN 08:00 arrives
- THEN a consolidated success message SHALL be sent to Telegram

#### Scenario: Empty digest queue

- GIVEN no success entries exist for today
- WHEN 08:00 arrives
- THEN no notification SHALL be sent (silent skip)