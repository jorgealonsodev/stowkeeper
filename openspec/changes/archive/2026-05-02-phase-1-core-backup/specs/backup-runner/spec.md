# Backup Runner Specification

## Purpose

Central wrapper script that orchestrates lock acquisition, authentication, backup execution, metrics capture, and restoration for all Restic operations on the pilot host.

## Requirements

### Requirement: Backup Execution

The system MUST execute `restic backup` with paths and exclusions defined in `pilot.conf`. For database jobs, the system SHALL dump the database to a temporary directory, back it up via Restic, and remove the dump after completion. For databases exceeding 100 GB, the system MAY pipe the dump directly to `restic backup --stdin` to avoid doubling storage.

#### Scenario: Successful file backup

- GIVEN a valid repository and lock acquired
- WHEN `backup-runner.sh backup --job files` is invoked
- THEN Restic SHALL back up paths from `BACKUP_PATHS_FILES`
- AND exit code 0 SHALL be returned on success

#### Scenario: Database dump and backup

- GIVEN a database job is configured
- WHEN `backup-runner.sh backup --job db` is invoked
- THEN the system SHALL create a database dump in a temp directory
- AND back up the dump via Restic
- AND remove the dump file after successful backup

#### Scenario: Stdin backup for large databases

- GIVEN a database is configured for stdin backup mode
- WHEN the job runs
- THEN the system SHALL pipe the dump directly to `restic backup --stdin`
- AND no intermediate dump file SHALL remain on disk

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

The system SHALL use the following exit codes:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Restic error |
| 2 | Lock timeout |
| 3 | Config error |
| 4 | Auth error |
| 75 | Lock contention |

On Restic failure, the system MUST capture stderr and pass it to the notification pipeline.

#### Scenario: Restic command failure

- GIVEN the Restic backup command exits non-zero
- WHEN the wrapper captures the exit code
- THEN exit code 1 SHALL be returned
- AND the failure SHALL trigger an immediate Telegram alert with stderr content

#### Scenario: Missing configuration file

- GIVEN `pilot.conf` is absent or unreadable
- WHEN `backup-runner.sh` starts
- THEN the system SHALL exit with code 3
- AND log the missing file path to journald

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

The system SHALL read configuration from `/opt/stowkeeper/conf/pilot.conf`, which MUST be shell-sourceable. Required keys: `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, `BACKUP_PATHS_DB`, `BACKUP_PATHS_FILES`, `BACKUP_PATHS_CONFIG` (arrays), `EXCLUDE_FILE`, `RETENTION_POLICY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.

#### Scenario: Valid configuration loads

- GIVEN `pilot.conf` contains all required keys with valid values
- WHEN `backup-runner.sh` sources the file
- THEN all variables SHALL be available for the backup pipeline