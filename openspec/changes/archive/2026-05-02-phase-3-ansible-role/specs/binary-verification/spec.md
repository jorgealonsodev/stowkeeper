# Binary Verification Specification

## Purpose

Ensure the Restic binary deployed to target hosts is authentic and untampered by validating its SHA256 checksum against a known-good value, fetched exclusively from an internal mirror — never from the public internet.

## Requirements

### Requirement: Internal Mirror Download

The Restic binary MUST be downloaded from `stowkeeper_restic_mirror_base_url` (defined in group_vars or defaults). The role MUST NOT fall back to public internet sources (e.g., GitHub releases) if the mirror is unreachable. Mirror failure SHALL cause the role to fail immediately.

#### Scenario: Successful mirror download

- GIVEN the internal mirror is reachable and hosts the pinned Restic version
- WHEN the download task executes
- THEN the binary SHALL be fetched from the mirror URL
- AND the task SHALL report success

#### Scenario: Mirror unreachable

- GIVEN the internal mirror is down or returns a network error
- WHEN the download task times out or fails
- THEN the role SHALL fail with an error message referencing the mirror URL
- AND no fallback to the public internet SHALL occur

### Requirement: SHA256 Checksum Validation

The download task MUST verify the binary's SHA256 checksum against `stowkeeper_restic_checksum`. If verification fails, the role MUST remove the downloaded binary and fail. If verification succeeds, the binary SHALL be installed to `stowkeeper_install_dir`.

#### Scenario: Checksum matches

- GIVEN `stowkeeper_restic_checksum` is set to a valid SHA256 hash
- WHEN the downloaded binary's checksum matches
- THEN the binary SHALL be installed to `/opt/stowkeeper/` with mode 0755
- AND the task SHALL report "changed" on first run

#### Scenario: Checksum mismatch

- GIVEN `stowkeeper_restic_checksum` is set but the downloaded binary is corrupted
- WHEN the checksum verification fails
- THEN the downloaded file SHALL be removed
- AND the role SHALL fail with a message indicating checksum mismatch

### Requirement: Version Pinning

`stowkeeper_restic_version` MUST be explicitly defined in group_vars or host_vars. The role MUST NOT default to "latest" or perform implicit version resolution. The download URL SHALL incorporate the pinned version.

#### Scenario: Explicitly pinned version

- GIVEN `stowkeeper_restic_version: "0.17.3"` is set in group_vars
- WHEN the download URL is constructed
- THEN it SHALL include "0.17.3" in the path or filename
- AND the binary installed SHALL report that version

#### Scenario: Missing version variable

- GIVEN `stowkeeper_restic_version` is undefined
- WHEN the role runs
- THEN the role SHALL fail before downloading
- AND the error message SHALL indicate the version is required

### Requirement: Checksum Mandatory

`stowkeeper_restic_checksum` MUST be defined and non-empty before the download task runs. An empty or undefined checksum SHALL cause the role to fail. This prevents deployment of an unverified binary.

#### Scenario: Valid checksum provided

- GIVEN `stowkeeper_restic_checksum` is a 64-character SHA256 hex string
- WHEN the role prepares to download
- THEN the download SHALL proceed with the checksum parameter

#### Scenario: Empty or missing checksum

- GIVEN `stowkeeper_restic_checksum` is empty or undefined
- WHEN the role runs validation
- THEN the role SHALL fail before attempting download
- AND the error message SHALL state that a checksum is required

### Requirement: Idempotent Binary Deployment

If the correct version of Restic is already installed and its checksum matches, the role SHALL NOT re-download. This ensures idempotent operation across repeated playbook runs.

#### Scenario: Binary already present and correct

- GIVEN Restic is installed at the target path with the correct version and checksum
- WHEN the role runs
- THEN the download task SHALL be skipped (ok/unchanged)
- AND no network request to the mirror SHALL be made

#### Scenario: Binary present but wrong version

- GIVEN a different Restic version is installed
- WHEN the role runs
- THEN the role SHALL download the correct version from the mirror
- AND replace the existing binary after checksum verification