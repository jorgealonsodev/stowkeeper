# B2 Secondary Repository Specification

## Purpose

Manage the Backblaze B2 off-site repository as an independent backup target via S3-compatible API, providing geographic redundancy separate from the NAS primary.

## Requirements

### Requirement: B2 Repository Initialization

The system MUST initialize a Restic repository on B2 using the `s3:` backend scheme before any B2 backup operations. The repository URL SHALL use the format `s3:https://s3.us-west-000.backblazeb2.com/<bucket>`. The repository MUST be encrypted with its own passphrase (independent from the NAS passphrase).

#### Scenario: First-time B2 repository init

- GIVEN B2 credentials are configured and the bucket exists
- WHEN `backup-runner.sh init --repo b2` is invoked
- THEN the system SHALL create a new encrypted Restic repository on B2
- AND exit with code 0

#### Scenario: B2 repository already exists

- GIVEN a Restic repository exists at the B2 target path
- WHEN `backup-runner.sh init --repo b2` is invoked
- THEN the system SHALL skip initialization and exit with code 0

### Requirement: Independent B2 Backup

The system SHALL execute backup to B2 as an independent operation within the dual-repo loop. B2 backup MUST NOT depend on NAS backup success. The `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables SHALL be set per-invocation from `pilot.conf`.

#### Scenario: B2 backup succeeds independently

- GIVEN NAS backup failed but B2 is reachable
- WHEN the dual-repo loop executes
- THEN the B2 backup SHALL proceed and succeed independently
- AND metrics SHALL be emitted with `repo=b2-secondary`

#### Scenario: B2 credentials invalid

- GIVEN `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` is incorrect or expired
- WHEN B2 backup is attempted
- THEN the system SHALL exit with code 4 (auth error) for the b2 repo
- AND a failure alert SHALL include the repo name

### Requirement: B2-Specific Error Handling

The system MUST handle B2-specific failure modes distinctly: network timeouts (exit 1 with retry guidance), authentication failures (exit 4), and quota exceeded (exit 1 with quota detail in stderr).

#### Scenario: B2 network timeout

- GIVEN the B2 endpoint is unreachable or times out
- WHEN `restic backup` against B2 exceeds the connection timeout
- THEN the system SHALL catch the timeout and exit with code 1
- AND stderr SHALL include the timeout detail

#### Scenario: B2 quota exceeded

- GIVEN the B2 account storage quota is exceeded
- WHEN `restic backup` fails with a quota error
- THEN the system SHALL exit with code 1
- AND stderr SHALL include the quota-related error message

### Requirement: B2 Repository Verification

The system MUST support `restic check` against the B2 repository, executed during the weekly maintenance window. The check SHALL use the elevated maintenance key with list permissions.

#### Scenario: Weekly B2 check succeeds

- GIVEN the maintenance timer fires on Sunday 03:00
- WHEN `restic check` runs against B2 with maintenance credentials
- THEN the check SHALL verify repository integrity
- AND `stowkeeper_check_last_success_timestamp{repo=b2-secondary}` SHALL be updated

#### Scenario: B2 check detects corruption

- GIVEN `restic check` reports errors on B2
- WHEN the check completes with failures
- THEN a failure alert SHALL be sent via Telegram and email
- AND the check metric SHALL NOT be updated