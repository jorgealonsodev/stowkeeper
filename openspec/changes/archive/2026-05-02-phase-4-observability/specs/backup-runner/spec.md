# Delta for Backup Runner

## ADDED Requirements

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