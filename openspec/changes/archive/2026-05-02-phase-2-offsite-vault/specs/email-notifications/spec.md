# Email Notifications Specification

## Purpose

Provide msmtp-based email as a secondary notification channel for backup failures, complementing Telegram. Email alerts fire only on failure conditions — success digests remain Telegram-only.

## Requirements

### Requirement: Failure Email Alerts

The system MUST send an email alert when a backup fails with exit code 1 (restic error), 3 (config error), or 4 (auth error). The email SHALL include job name, repo name, timestamp, exit code, and the last 10 lines of stderr. Email alerts SHALL be sent via `msmtp` to the configured relay.

#### Scenario: Failure triggers both Telegram and email

- GIVEN a backup job exits with code 1, 3, or 4
- WHEN the failure is detected
- THEN a Telegram alert SHALL be sent (existing behavior)
- AND an email SHALL be sent with the same failure details
- AND the email SHALL include the repo name

#### Scenario: msmtp relay unreachable

- GIVEN the SMTP relay is unreachable when sending an email
- WHEN `msmtp` fails to deliver
- THEN the email failure SHALL be logged to journald
- AND the Telegram alert SHALL still be sent (email is secondary)

### Requirement: msmtp Configuration

The system SHALL read SMTP configuration from `pilot.conf`: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`, `SMTP_TO`. The `send_email(subject, body)` function in `stowkeeper-email.sh` SHALL pipe the message to `msmtp -t` with proper headers.

#### Scenario: Valid SMTP configuration

- GIVEN all SMTP keys are set in `pilot.conf`
- WHEN `send_email` is called
- THEN msmtp SHALL authenticate to the relay and deliver the message

#### Scenario: Incomplete SMTP configuration

- GIVEN `SMTP_HOST` or `SMTP_TO` is empty
- WHEN `send_email` is called
- THEN the system SHALL skip email sending and log a warning
- AND the Telegram channel SHALL still operate normally

### Requirement: Email Deduplication

Email alerts SHALL use the same 4-hour deduplication window as Telegram, stored in `/var/lib/stowkeeper/dedup/email-<job>-<repo>`. An email SHALL NOT be sent if a dedup file for the same job and repo exists with mtime less than 4 hours ago.

#### Scenario: First failure for a job/repo combination

- GIVEN no recent email dedup file exists for this job+repo
- WHEN a failure occurs
- THEN an email SHALL be sent
- AND a dedup file `email-<job>-<repo>` SHALL be created

#### Scenario: Duplicate failure within 4 hours

- GIVEN an email dedup file exists with mtime < 4 hours
- WHEN the same job+repo fails again
- THEN no email SHALL be sent (suppressed by dedup)

#### Scenario: Failure after 4-hour window expired

- GIVEN an email dedup file exists with mtime ≥ 4 hours
- WHEN the same job+repo fails again
- THEN an email SHALL be sent
- AND the dedup file mtime SHALL be updated

### Requirement: Email Rate Limiting

The system SHALL enforce a maximum of `SMTP_RATE_LIMIT` emails per hour (default: 10). If the rate limit is reached, subsequent emails within the hour SHALL be dropped and logged.

#### Scenario: Rate limit not exceeded

- GIVEN fewer than 10 emails have been sent in the current hour
- WHEN a new failure email is triggered
- THEN the email SHALL be sent normally

#### Scenario: Rate limit exceeded

- GIVEN 10 emails have already been sent in the current hour
- WHEN a new failure email is triggered
- THEN the email SHALL be dropped
- AND the drop SHALL be logged to journald

### Requirement: Success Digest Exclusion

Success digests SHALL remain Telegram-only. Email MUST NOT be sent for successful backup completions, only for failures (codes 1, 3, 4).

#### Scenario: Successful backup does not trigger email

- GIVEN a backup job completes successfully
- WHEN the result is processed
- THEN no email SHALL be sent
- AND only the Telegram digest queue SHALL be updated