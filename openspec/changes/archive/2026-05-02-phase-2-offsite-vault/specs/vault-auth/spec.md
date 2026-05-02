# Vault Auth Specification

## Purpose

Provide HashiCorp Vault AppRole-based authentication for Restic passphrases, injecting credentials at runtime without persisting them to disk, with automatic fallback to local password files when Vault is unreachable.

## Requirements

### Requirement: AppRole Authentication

The system MUST authenticate to Vault using AppRole (role_id + secret_id) to obtain a client token. The login request SHALL have a 10-second timeout. On success, the token and its TTL SHALL be stored in memory for the session.

#### Scenario: Successful AppRole login

- GIVEN `VAULT_ADDR`, `VAULT_ROLE_ID_stowkeeper_<repo>`, and `VAULT_SECRET_ID_stowkeeper_<repo>` are configured
- WHEN `vault_authenticate(repo_name)` is called
- THEN the system SHALL POST to `auth/approle/login` with role_id and secret_id
- AND receive a client token with TTL
- AND return exit code 0

#### Scenario: AppRole credentials invalid

- GIVEN the role_id or secret_id is incorrect or revoked
- WHEN `vault_authenticate(repo_name)` is called
- THEN the system SHALL return exit code 4 (auth error)
- AND log the Vault API error to journald

#### Scenario: Vault unreachable (timeout)

- GIVEN `VAULT_ADDR` is configured but the Vault server is unreachable
- WHEN `vault_authenticate(repo_name)` is called and the 10-second timeout expires
- THEN the system SHALL fall back to `RESTIC_PASSWORD_FILE_<repo>` from `pilot.conf`
- AND log a warning that Vault was unavailable

### Requirement: Passphrase Retrieval

After successful AppRole login, the system SHALL retrieve the Restic passphrase from Vault KV v2 at the path `secret/data/stowkeeper/<repo>`. The passphrase MUST be written to a temporary file (mode 0600) pointed to by `RESTIC_PASSWORD_FILE`.

#### Scenario: Passphrase retrieved from Vault

- GIVEN Vault authentication succeeded
- WHEN the system reads the passphrase from KV v2
- THEN the passphrase SHALL be written to a temp file with mode 0600
- AND `RESTIC_PASSWORD_FILE` SHALL point to this temp file
- AND the passphrase SHALL NOT appear in process argument lists

#### Scenario: KV path not found

- GIVEN Vault authentication succeeded but the KV path does not exist
- WHEN the system attempts to read `secret/data/stowkeeper/<repo>`
- THEN the system SHALL fall back to `RESTIC_PASSWORD_FILE_<repo>`
- AND log a warning that the Vault path was not found

### Requirement: Token Lifecycle

The system SHOULD check the token TTL before each repo iteration. If the remaining TTL is less than 5 minutes, the system SHALL re-authenticate. Unused tokens MUST NOT be revoked explicitly — natural expiration is sufficient.

#### Scenario: Token TTL sufficient for run

- GIVEN a Vault token with TTL > 5 minutes
- WHEN the backup loop begins a new repo iteration
- THEN the system SHALL use the existing token without re-authentication

#### Scenario: Token TTL near expiry

- GIVEN a Vault token with TTL ≤ 5 minutes
- WHEN the backup loop begins a new repo iteration
- THEN the system SHALL re-authenticate via AppRole before proceeding

### Requirement: Temp File Cleanup

The temporary passphrase file MUST be deleted on process exit (including SIGTERM, SIGKILL). Cleanup SHALL be registered via an EXIT trap. If Vault was NOT used (fallback path), no temp file SHALL exist.

#### Scenario: Normal cleanup after backup

- GIVEN Vault authentication created a temp file
- WHEN the backup process exits (success or failure)
- THEN the temp file SHALL be deleted by the EXIT trap
- AND no passphrase SHALL remain on disk

#### Scenario: Cleanup on unexpected termination

- GIVEN Vault authentication created a temp file
- WHEN the process receives SIGTERM
- THEN the EXIT trap SHALL delete the temp file