# Delta for Telegram Notifications

## MODIFIED Requirements

### Requirement: Failure Alerts

The system MUST send an immediate Telegram alert when a backup job fails. The alert SHALL include job name, repo name, timestamp, exit code, and the last 10 lines of stderr from Restic output.

(Previously: Failure alerts included job name, timestamp, exit code, and stderr — without repo name)

#### Scenario: Immediate failure alert with repo name

- GIVEN a backup job exits with a non-zero code on a specific repo
- WHEN the failure is detected
- THEN an immediate Telegram alert SHALL be sent with job name, repo name (nas-primary or b2-secondary), exit code, and stderr excerpt

#### Scenario: Failure on both repos

- GIVEN a backup job fails on both NAS and B2
- WHEN both failures are detected
- THEN two separate Telegram alerts SHALL be sent, one per repo
- AND each alert SHALL include the respective repo name

#### Scenario: Telegram API unreachable during failure

- GIVEN the Telegram API is unreachable when sending a failure alert
- WHEN the API call fails
- THEN the alert SHALL be logged to journald with tag STOWKEEPER
- AND the system SHALL NOT block or retry within the same execution

### Requirement: Success Digest

The system MUST accumulate successful backup results in `/var/lib/stowkeeper/digest/<date>.json` and send a consolidated daily digest at 08:00 via the `stowkeeper-digest` timer. Each success entry SHALL include job name, repo name, timestamp, duration, and size.

(Previously: Success entries included job name, timestamp, duration, size — without repo name)

#### Scenario: Success appended to digest queue with repo name

- GIVEN a backup job completes successfully on a specific repo
- WHEN the result is processed
- THEN the job result SHALL be appended to `digest/<date>.json` with repo name
- AND no immediate Telegram message SHALL be sent

#### Scenario: Digest delivery includes per-repo stats

- GIVEN at least one success entry exists for today
- WHEN the digest timer fires at 08:00
- THEN a consolidated message SHALL be sent to the configured Telegram chat
- AND the message SHALL group results by repo (nas-primary, b2-secondary)
- AND the digest file SHALL be removed after successful delivery

#### Scenario: Digest delivery failure

- GIVEN the Telegram API is unreachable at 08:00
- WHEN the digest send attempt fails
- THEN the error SHALL be logged to journald with tag STOWKEEPER
- AND the digest file SHALL be retained for retry on next run