# NAS Primary Repository Specification

## Purpose

Initialize and manage the primary Restic backup repository on NAS via SFTP, providing the storage target for all pilot host backups.

## Requirements

### Requirement: Repository Initialization

The system MUST initialize a Restic repository on the NAS accessible via SFTP before any backup operations. The repository URL SHALL use the `sftp:` scheme with the configured NAS host and path. The repository MUST be encrypted with AES-256 using the passphrase from `RESTIC_PASSWORD_FILE`.

#### Scenario: First-time repository init

- GIVEN the NAS is reachable via SFTP
- AND no Restic repository exists at the target path
- WHEN `backup-runner.sh init` is invoked
- THEN the system SHALL create a new encrypted Restic repository
- AND exit with code 0

#### Scenario: Repository already exists

- GIVEN a Restic repository already exists at the target path
- WHEN `backup-runner.sh init` is invoked
- THEN the system SHALL skip initialization and report success
- AND exit with code 0

### Requirement: SFTP Connectivity

The system MUST verify SFTP connectivity to the NAS before attempting backup. The pilot host SHALL use SSH key-based authentication for passwordless access. Connection failure MUST prevent backup execution and emit a failure notification.

#### Scenario: NAS unreachable

- GIVEN the NAS SFTP server is unreachable
- WHEN a backup job is triggered
- THEN the system SHALL exit with code 1 (Restic error)
- AND a failure notification SHALL be emitted via Telegram

#### Scenario: SFTP authentication failure

- GIVEN the SSH key is missing or invalid
- WHEN a backup job is triggered
- THEN the system SHALL exit with code 4 (auth error)
- AND stderr SHALL include the authentication error detail

### Requirement: Repository Access Configuration

The system SHALL read `RESTIC_REPOSITORY` from `pilot.conf` to determine the SFTP repository URL. The passphrase MUST be provided via `RESTIC_PASSWORD_FILE` environment variable or `--password-file` flag.

#### Scenario: Missing repository configuration

- GIVEN `RESTIC_REPOSITORY` is not set in `pilot.conf`
- WHEN a backup job is triggered
- THEN the system SHALL exit with code 3 (config error)
- AND log the missing configuration key