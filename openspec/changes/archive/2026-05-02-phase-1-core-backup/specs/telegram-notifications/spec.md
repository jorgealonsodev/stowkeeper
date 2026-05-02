# Telegram Notifications Specification

## Purpose

Bot-based notifications for backup success digests, failure alerts, and warnings via Telegram, with deduplication to prevent alert fatigue.

## Requirements

### Requirement: Success Digest

The system MUST accumulate successful backup results in `/var/lib/stowkeeper/digest/<date>.json` and send a consolidated daily digest at 08:00 via the `stowkeeper-digest` timer. Each success entry SHALL include job name, timestamp, duration, and size.

#### Scenario: Success appended to digest queue

- GIVEN a backup job completes successfully
- WHEN the result is processed
- THEN the job result SHALL be appended to `digest/<date>.json`
- AND no immediate Telegram message SHALL be sent

#### Scenario: Digest delivery

- GIVEN at least one success entry exists for today
- WHEN the digest timer fires at 08:00
- THEN a consolidated message SHALL be sent to the configured Telegram chat
- AND the digest file SHALL be removed after successful delivery

#### Scenario: Digest delivery failure

- GIVEN the Telegram API is unreachable at 08:00
- WHEN the digest send attempt fails
- THEN the error SHALL be logged to journald with tag STOWKEEPER
- AND the digest file SHALL be retained for retry on next run

### Requirement: Failure Alerts

The system MUST send an immediate Telegram alert when a backup job fails. The alert SHALL include job name, timestamp, exit code, and the last 10 lines of stderr from Restic output.

#### Scenario: Immediate failure alert

- GIVEN a backup job exits with a non-zero code
- WHEN the failure is detected
- THEN an immediate Telegram alert SHALL be sent with job name, exit code, and stderr excerpt

#### Scenario: Telegram API unreachable during failure

- GIVEN the Telegram API is unreachable when sending a failure alert
- WHEN the API call fails
- THEN the alert SHALL be logged to journald with tag STOWKEEPER
- AND the system SHALL NOT block or retry within the same execution

### Requirement: Alert Deduplication

The system SHALL deduplicate failure and warning alerts using a 4-hour window per alert type and job. Deduplication files SHALL be stored in `/var/lib/stowkeeper/dedup/` with mtime-based comparison.

#### Scenario: First failure for a job

- GIVEN no recent failure alert exists for this job
- WHEN the job fails
- THEN an alert SHALL be sent
- AND a dedup timestamp file SHALL be created at `dedup/failure-<job>`

#### Scenario: Duplicate failure within 4 hours

- GIVEN a dedup file for `failure-<job>` exists with mtime less than 4 hours ago
- WHEN the same job fails again
- THEN no alert SHALL be sent (suppressed by dedup)

#### Scenario: Failure after 4-hour window expired

- GIVEN a dedup file for `failure-<job>` exists with mtime ≥ 4 hours ago
- WHEN the same job fails again
- THEN an alert SHALL be sent
- AND the dedup file mtime SHALL be updated

### Requirement: Warning Notifications

The system SHOULD send warning notifications for degraded conditions (e.g., backup duration exceeding 2× the historical median). Warnings SHALL use the same deduplication mechanism as failures.

#### Scenario: Slow backup warning

- GIVEN a backup completes successfully but exceeds 2× the median duration
- WHEN the result is processed
- THEN a warning SHALL be sent via Telegram (no email in Phase 1)
- AND dedup logic SHALL prevent repeated warnings within 4 hours