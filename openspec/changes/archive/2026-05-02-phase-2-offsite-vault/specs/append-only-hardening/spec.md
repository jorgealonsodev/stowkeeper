# Append-Only Hardening Specification

## Purpose

Defend the off-site backup repository against ransomware and unauthorized deletion by enforcing write-only access on backup clients, restricting destructive operations to a sealed maintenance host, and enabling B2 Object Lock retention.

## Requirements

### Requirement: Write-Only Application Key

The B2 Application Key used by backup clients MUST have `writeFiles` permission only — no `deleteFiles`, no `listBuckets`, no `listFiles`. The key SHALL be stored as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in `pilot.conf`.

#### Scenario: Backup client cannot delete snapshots

- GIVEN a backup client authenticates with the write-only B2 key
- WHEN `restic forget --prune` is attempted from the backup client
- THEN B2 SHALL reject the delete operation
- AND the command SHALL fail with a permissions error

#### Scenario: Backup client can write data

- GIVEN a backup client authenticates with the write-only B2 key
- WHEN `restic backup` is executed
- THEN the backup SHALL succeed normally
- AND data SHALL be written to B2

### Requirement: Maintenance Host Elevated Key

The maintenance host SHALL hold a separate B2 Application Key with `deleteFiles` and `listFiles` permissions. This key MUST be used ONLY during the weekly maintenance window and MUST NOT be present on any backup client.

#### Scenario: Maintenance host performs prune

- GIVEN the maintenance timer fires on Sunday 03:00
- WHEN `restic forget --prune` runs on the maintenance host with the elevated key
- THEN expired snapshots SHALL be removed from B2
- AND prune SHALL complete successfully

#### Scenario: Elevated key rotation

- GIVEN the elevated key needs rotation
- WHEN a new key is created in B2 and `maintenance.conf` is updated
- THEN the old key SHALL be revoked in B2 immediately
- AND the maintenance service SHALL be restarted

### Requirement: B2 Object Lock Retention

The B2 bucket SHALL be configured with Object Lock in compliance mode with a 30-day minimum retention period. Objects under retention MUST NOT be deleted or overwritten by any key, including the maintenance elevated key, until the retention period expires.

#### Scenario: Object Lock prevents immediate deletion

- GIVEN a snapshot was uploaded within the last 30 days
- WHEN any credentials attempt to delete the snapshot object
- THEN B2 SHALL reject the deletion with an Object Lock error
- AND the object SHALL remain intact

#### Scenario: Object Lock expires after retention period

- GIVEN a snapshot was uploaded more than 30 days ago
- WHEN the maintenance host runs `forget --prune` after Object Lock expires
- THEN the snapshot MAY be pruned normally

### Requirement: Defense-in-Depth Documentation

The system SHALL document a three-layer defense model: (1) B2 Object Lock prevents deletion within 30 days, (2) ZFS read-only snapshots on the NAS provide local immutable copies, (3) write-only Application Keys prevent accidental or malicious deletion from backup clients. This documentation MUST be included in the project README or runbook.

#### Scenario: Defense layers are documented and verifiable

- GIVEN the project README or runbook
- WHEN an operator reviews the security documentation
- THEN all three defense layers SHALL be described with their scope and limitations