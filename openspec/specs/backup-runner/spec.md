# Backup Runner Specification

## Purpose

Central wrapper script that orchestrates lock acquisition, authentication, backup execution, metrics capture, and restoration for all Restic operations on the pilot host.

## Requirements

### Requirement: Backup Execution

The system MUST iterate over `REPOS` array sequentially, setting per-repo environment variables (`RESTIC_REPOSITORY_<repo>`, `RESTIC_PASSWORD_FILE_<repo>` or Vault temp file). For each repo, it MUST execute `restic backup` with paths and exclusions defined in `pilot.conf`. For database jobs, the system SHALL dump the database to a temporary directory, back it up to each configured repo via Restic, and remove the dump after completion. For databases exceeding 100 GB, the system MAY pipe the dump directly to `restic backup --stdin` to avoid doubling storage; stdin mode runs per repo.

#### Scenario: Successful file backup

- GIVEN a valid repository and lock acquired
- WHEN `backup-runner.sh backup --job files` is invoked
- THEN Restic SHALL back up paths to each configured repo
- AND exit code 0 SHALL be returned on success for all repos

#### Scenario: Database dump and backup

- GIVEN a database job is configured
- WHEN `backup-runner.sh backup --job db` is invoked
- THEN the system SHALL create a database dump in a temp directory
- AND back up the dump to each configured repo via Restic
- AND remove the dump file after successful backup

#### Scenario: Stdin backup for large databases

- GIVEN a database is configured for stdin backup mode
- WHEN the job runs
- THEN the system SHALL pipe the dump directly to `restic backup --stdin`
- AND no intermediate dump file SHALL remain on disk

### Requirement: Multi-Repository Isolation

Failure of one repo MUST NOT prevent backup to other repos. Each repo iteration SHALL capture its own exit code. The overall exit code SHALL reflect the worst result (priority: 4 > 3 > 1 > 75 > 2; 0 only if all succeed).

#### Scenario: NAS fails, B2 succeeds

- GIVEN NAS is unreachable but B2 is available
- WHEN the dual-repo loop completes
- THEN B2 SHALL succeed with `repo=b2-secondary` metrics
- AND overall exit code SHALL be 1 (NAS error)

#### Scenario: Both repos succeed

- GIVEN both NAS and B2 are accessible
- WHEN the dual-repo loop completes
- THEN both SHALL back up successfully and exit 0

#### Scenario: Both repos fail

- GIVEN both NAS and B2 encounter errors
- WHEN the loop completes
- THEN both failures SHALL be reported independently
- AND overall exit code SHALL reflect the most severe

### Requirement: Lockfile Concurrency Control

The system MUST acquire an exclusive lock via `flock` on `/var/lock/stowkeeper-backup.lock` before any Restic operation. The lock timeout SHALL be 60 seconds. The lock MUST be released on any process exit (including SIGKILL) via fd-based flock held until process termination.

#### Scenario: Lock acquired successfully

- GIVEN no other backup is running
- WHEN `backup-runner.sh` starts
- THEN the lock SHALL be acquired immediately
- AND the job SHALL proceed

#### Scenario: Lock contention

- GIVEN another backup holds the lock
- WHEN the lock cannot be acquired within 60 seconds
- THEN the system SHALL exit with code 75
- AND a warning notification SHALL be emitted

### Requirement: Error Handling and Exit Codes

The system SHALL use the following exit codes per repository:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Restic error |
| 2 | Lock timeout |
| 3 | Config error |
| 4 | Auth error |
| 75 | Lock contention |

The overall exit code SHALL be the highest-priority non-zero code across all repos (priority: 4 > 3 > 1 > 75 > 2), or 0 only if all repos succeed. On Restic failure per repo, the system MUST capture stderr and pass it to the notification pipeline.

#### Scenario: Restic failure on one repo

- GIVEN NAS restic fails but B2 succeeds
- WHEN the wrapper aggregates exit codes
- THEN overall exit code SHALL be 1

#### Scenario: Missing configuration file

- GIVEN `pilot.conf` is absent or unreadable
- WHEN `backup-runner.sh` starts
- THEN the system SHALL exit with code 3
- AND log the missing file path to journald

#### Scenario: Auth error on one repo

- GIVEN Vault fallback fails for B2
- WHEN B2 authentication fails
- THEN exit code 4 for B2; NAS SHALL continue unaffected

### Requirement: Restoration

The system MUST support listing snapshots and restoring files. `backup-runner.sh restore` SHALL accept `--snapshot` and `--target` arguments. Selective restore (specific paths) SHALL be supported via an optional `--path` flag.

#### Scenario: List snapshots for host

- GIVEN the repository is accessible
- WHEN `backup-runner.sh snapshots --host <hostname>` is invoked
- THEN the system SHALL list all snapshots for that host with date, ID, and size

#### Scenario: Full restore

- GIVEN a valid snapshot ID and a writable target path
- WHEN `backup-runner.sh restore --snapshot <id> --target /tmp/restore` is invoked
- THEN the system SHALL restore the full snapshot to the target path

#### Scenario: Selective restore

- GIVEN a valid snapshot ID
- WHEN `backup-runner.sh restore --snapshot <id> --target /tmp/restore --path /etc/nginx`
- THEN only the specified path and its contents SHALL be restored

### Requirement: Configuration

The system SHALL read configuration from `/opt/stowkeeper/conf/pilot.conf`, which MUST be shell-sourceable. Required keys: `REPOS` (array), per-repo `RESTIC_REPOSITORY_<repo>` and `RESTIC_PASSWORD_FILE_<repo>` (or `RESTIC_REPOSITORY` / `RESTIC_PASSWORD_FILE` for backward-compatible single-repo config), `BACKUP_PATHS_DB`, `BACKUP_PATHS_FILES`, `BACKUP_PATHS_CONFIG` (arrays), `EXCLUDE_FILE`, `RETENTION_POLICY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `VAULT_ADDR`, per-repo `VAULT_ROLE_ID_stowkeeper_<repo>` and `VAULT_SECRET_ID_stowkeeper_<repo>`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`, `SMTP_TO`, `SMTP_RATE_LIMIT`.

#### Scenario: Valid configuration loads

- GIVEN `pilot.conf` contains all required keys with valid values
- WHEN `backup-runner.sh` sources the file
- THEN `REPOS` SHALL iterate over configured repos
- AND all variables SHALL be available for the backup pipeline

#### Scenario: Single-repo fallback

- GIVEN `REPOS=("nas")` in `pilot.conf`
- WHEN `backup-runner.sh` sources the file
- THEN only the NAS repo SHALL be targeted (backward-compatible)

### Requirement: Deep Check Support

The `check` subcommand MUST accept a `--read-data` flag that triggers deep verification using `restic check --read-data-subset`. When invoked with `--read-data`, the system SHALL use the persistent rotation counter at `$RUNTIME_DIR/check-read-data-month` to determine the current subset, execute the deep check, and increment the counter on success. Without `--read-data`, the check subcommand SHALL perform a regular `restic check` (metadata-only).

#### Scenario: Deep check invoked with --read-data

- GIVEN the rotation counter is valid and matches the current month modulo 10
- WHEN `backup-runner.sh check --read-data` is invoked
- THEN `restic check --read-data-subset=N0%` SHALL be executed for each repo
- AND the counter SHALL be incremented modulo 10 upon success

#### Scenario: Regular check without --read-data

- GIVEN no `--read-data` flag is provided
- WHEN `backup-runner.sh check` is invoked
- THEN `restic check` (metadata-only) SHALL be executed for each repo

#### Scenario: Deep check counter file management

- GIVEN a deep check completes successfully for a repo
- WHEN the counter is updated
- THEN the counter file SHALL be written atomically (temp + rename pattern)
- AND the previous counter value SHALL be preserved if the write fails

#### Scenario: Deep check result handling per repo

- GIVEN a deep check runs against a specific repo
- WHEN the deep check succeeds
- THEN `stowkeeper_check_deep_success_timestamp{repo}` SHALL be emitted
- WHEN the deep check fails
- THEN `stowkeeper_check_deep_success_timestamp` SHALL NOT be updated for that repo
- AND the failure SHALL be reported through the notification pipeline

#### Scenario: Deep check failure does not block other repos

- GIVEN deep check fails for one repo and succeeds for another
- WHEN the multi-repo loop completes
- THEN the successful repo SHALL have its deep-check metric emitted
- AND the failed repo SHALL have its metric preserved and error reported
- AND overall exit code SHALL reflect the worst result per existing priority rules
