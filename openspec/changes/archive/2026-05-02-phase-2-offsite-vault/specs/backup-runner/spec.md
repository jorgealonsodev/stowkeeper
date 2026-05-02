# Delta for Backup Runner

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Backup Execution

The system MUST iterate over `REPOS=("nas" "b2")` sequentially, setting per-repo env vars (`RESTIC_REPOSITORY_<repo>`, `RESTIC_PASSWORD_FILE_<repo>` or Vault temp file). Database uploads and stdin handling remain unchanged per existing spec.

(Previously: Single-repo execution without loop or per-repo config)

#### Scenario: Successful file backup

- GIVEN a valid repository and lock acquired
- WHEN `backup-runner.sh backup --job files` is invoked
- THEN Restic SHALL back up paths to each configured repo
- AND exit code 0 SHALL be returned on success for all repos

#### Scenario: Database dump and backup

- GIVEN a database job is configured
- WHEN `backup-runner.sh backup --job db` is invoked
- THEN the system SHALL dump, back up to each repo, and remove the dump

#### Scenario: Stdin backup for large databases

- GIVEN a database is configured for stdin mode
- WHEN the job runs
- THEN the dump SHALL pipe directly to `restic backup --stdin`

### Requirement: Error Handling and Exit Codes

Exit codes per repo follow the existing table (0/1/3/4/75). The overall exit code SHALL be the highest-priority non-zero code across all repos (4 > 3 > 1 > 75 > 2), or 0 if all succeed.

(Previously: Single-repo exit codes without multi-repo aggregation)

#### Scenario: Restic failure on one repo

- GIVEN NAS restic fails but B2 succeeds
- WHEN the wrapper aggregates exit codes
- THEN overall exit code SHALL be 1

#### Scenario: Missing configuration file

- GIVEN `pilot.conf` is absent or unreadable
- WHEN `backup-runner.sh` starts
- THEN exit code 3 and log the missing path

#### Scenario: Auth error on one repo

- GIVEN Vault fallback fails for B2
- WHEN B2 authentication fails
- THEN exit code 4 for B2; NAS SHALL continue unaffected

### Requirement: Configuration

The system SHALL read `/opt/stowkeeper/conf/pilot.conf` (shell-sourceable). Required keys: `REPOS` (array), per-repo `RESTIC_REPOSITORY_<repo>`, per-repo `RESTIC_PASSWORD_FILE_<repo>`, `BACKUP_PATHS_*` (arrays), `EXCLUDE_FILE`, `RETENTION_POLICY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `VAULT_ADDR`, per-repo `VAULT_ROLE_ID_stowkeeper_<repo>`, per-repo `VAULT_SECRET_ID_stowkeeper_<repo>`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`, `SMTP_TO`, `SMTP_RATE_LIMIT`.

(Previously: Single-repo config without REPOS array, Vault vars, or SMTP vars)

#### Scenario: Valid configuration loads

- GIVEN `pilot.conf` contains all required keys
- WHEN `backup-runner.sh` sources the file
- THEN `REPOS` SHALL iterate over configured repos

#### Scenario: Single-repo fallback

- GIVEN `REPOS=("nas")` in `pilot.conf`
- WHEN `backup-runner.sh` sources the file
- THEN only the NAS repo SHALL be targeted (backward-compatible)