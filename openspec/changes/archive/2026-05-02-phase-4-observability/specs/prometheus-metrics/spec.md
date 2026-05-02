# Delta for Prometheus Metrics

## ADDED Requirements

### Requirement: Deep Check Metrics

The system SHALL expose `stowkeeper_check_deep_success_timestamp{repo}` after successful completion of `restic check --read-data-subset`. This metric MUST NOT be updated on deep check failure.

#### Scenario: Deep check metric after successful deep verification

- GIVEN `restic check --read-data-subset` completes with exit code 0 for a repo
- WHEN metrics are written
- THEN `stowkeeper_check_deep_success_timestamp{repo}` SHALL be set to the current Unix timestamp

#### Scenario: Deep check metric preserved on failure

- GIVEN `restic check --read-data-subset` exits non-zero for a repo
- WHEN metrics are written
- THEN `stowkeeper_check_deep_success_timestamp{repo}` SHALL NOT be updated

### Requirement: Restore Test Metrics

The system SHALL expose the following metrics after each restore test run:

| Metric | Type | Description |
|--------|------|-------------|
| `stowkeeper_restore_test_success{repo}` | gauge | 1 if last restore test passed, 0 if failed |
| `stowkeeper_restore_test_files_checked{repo}` | gauge | Number of files sampled during restore test |
| `stowkeeper_restore_test_files_matched{repo}` | gauge | Number of files with matching sha256sums |

#### Scenario: Restore test success metrics

- GIVEN a restore test completes with all sampled files matching
- WHEN metrics are written
- THEN `stowkeeper_restore_test_success{repo}` SHALL be 1
- AND `stowkeeper_restore_test_files_checked{repo}` SHALL equal the sample count
- AND `stowkeeper_restore_test_files_matched{repo}` SHALL equal the sample count

#### Scenario: Restore test partial mismatch metrics

- GIVEN a restore test completes with some checksum mismatches
- WHEN metrics are written
- THEN `stowkeeper_restore_test_success{repo}` SHALL be 0
- AND `stowkeeper_restore_test_files_checked{repo}` SHALL equal the total sampled
- AND `stowkeeper_restore_test_files_matched{repo}` SHALL equal the matching count

### Requirement: Repository Size Metric

The system SHALL expose `stowkeeper_repo_size_bytes{repo}` as a gauge metric representing the total repository size in bytes.

#### Scenario: Repo size metric emission on backup completion

- GIVEN a backup operation completes successfully
- WHEN metrics are written
- THEN `stowkeeper_repo_size_bytes{repo}` SHALL reflect the current repository size in bytes

#### Scenario: Repo size metric preserved on failure

- GIVEN a restic operation fails before computing repo size
- WHEN metrics are written
- THEN `stowkeeper_repo_size_bytes{repo}` SHALL retain its previous value