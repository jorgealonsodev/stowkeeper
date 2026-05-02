# Restore Testing Specification

## Purpose

Quarterly automated restore verification that restores the latest snapshot, samples files, compares sha256 checksums against originals, and reports results through the metrics and notification pipeline.

## Requirements

### Requirement: Snapshot Restore to Temp Directory

The restore-test script MUST identify the latest snapshot via `restic snapshots --latest 1`, restore it to `/var/lib/stowkeeper/restore-test/`, and verify the restore completed successfully.

#### Scenario: Successful restore

- GIVEN the repository is accessible and contains at least one snapshot
- WHEN the restore-test script runs
- THEN the latest snapshot SHALL be restored to the temp directory

#### Scenario: No snapshots available

- GIVEN the repository contains no snapshots
- WHEN the restore-test script runs
- THEN the script SHALL exit with an error and emit a failure metric

### Requirement: File Integrity Sampling

The script MUST sample 20 random files from the restored data, compute sha256sums, and compare against the original files on the live filesystem.

#### Scenario: All sampled files match

- GIVEN 20 random files are sampled
- WHEN all sha256sums match between restored and original files
- THEN `stowkeeper_restore_test_success{repo}` SHALL be set to 1
- AND `stowkeeper_restore_test_files_checked{repo}` SHALL be 20
- AND `stowkeeper_restore_test_files_matched{repo}` SHALL be 20

#### Scenario: Some files mismatch

- GIVEN sha256sums are computed for 20 files
- WHEN 3 files have mismatching checksums
- THEN `stowkeeper_restore_test_success{repo}` SHALL be set to 0
- AND `stowkeeper_restore_test_files_checked{repo}` SHALL be 20
- AND `stowkeeper_restore_test_files_matched{repo}` SHALL be 17
- AND a failure notification SHALL be sent via the alert pipeline

### Requirement: Cleanup After Test

After the integrity check completes (success or failure), the script MUST remove the restore temp directory `/var/lib/stowkeeper/restore-test/`.

#### Scenario: Cleanup after successful test

- GIVEN the restore test has completed successfully
- WHEN cleanup runs
- THEN `/var/lib/stowkeeper/restore-test/` SHALL be fully removed

#### Scenario: Cleanup after failed test

- GIVEN the restore test failed mid-way
- WHEN cleanup runs
- THEN the temp directory SHALL still be removed
- AND no restored data SHALL remain on disk

### Requirement: Results Notification

The script MUST send a notification through the existing `send_alert` pipeline with the restore test results, including files checked, files matched, and overall pass/fail status.

#### Scenario: Success notification

- GIVEN all sampled files match
- WHEN the test completes
- THEN a summary notification SHALL be sent to Telegram with the pass status

#### Scenario: Failure notification

- GIVEN any files mismatch or an error occurs
- WHEN the test completes or fails
- THEN a failure notification SHALL be sent to Telegram and email

### Requirement: Disk Space Pre-flight Check

The script SHOULD verify available disk space is at least 2× the repository size before starting a restore, aborting with a warning if insufficient.

#### Scenario: Insufficient disk space

- GIVEN available disk space is less than 2× the repository size
- WHEN the restore-test script runs
- THEN the script SHALL abort before restoring
- AND a warning notification SHALL be sent
- AND the temp directory SHALL NOT be created

#### Scenario: Sufficient disk space

- GIVEN available disk space is at least 2× the repository size
- WHEN the restore-test script runs
- THEN the restore SHALL proceed normally