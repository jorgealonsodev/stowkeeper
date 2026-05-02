# Ansible Backup Client Specification

## Purpose

Ansible role that deploys the Stowkeeper backup pipeline to target hosts — installing Restic with verified checksum, rendering host-specific configuration from Jinja2 templates, deploying scripts and systemd units, and conditionally enabling timers.

## Requirements

### Requirement: Role Idempotency

The role MUST be idempotent. A second converged run MUST report zero changes when all files, binaries, and timers already match the desired state. The role SHALL NOT restart services or reload systemd unless a file actually changed.

#### Scenario: Second run reports no changes

- GIVEN the role has already been applied to a host
- WHEN the playbook runs a second time
- THEN all tasks SHALL report "ok" or "unchanged"
- AND no services SHALL be restarted

#### Scenario: Config change triggers reload

- GIVEN the role is already applied
- WHEN `pilot.conf` template content changes
- THEN the role SHALL reload systemd and restart affected timers

### Requirement: Configuration Templating

The `pilot.conf.j2` template MUST produce valid bash that can be `source`d by `backup-runner.sh`. Variable mappings (e.g., `stowkeeper_repos` → `REPOS` array) SHALL match the contract in the design document. The role MUST fail during validation if any required variable is undefined.

#### Scenario: Template renders valid bash

- GIVEN all required host variables are defined
- WHEN the template is rendered
- THEN the output SHALL be a valid bash file parseable by `source`
- AND arrays like `REPOS=("nas" "b2")` SHALL be correctly formed

#### Scenario: Missing required variable

- GIVEN `stowkeeper_repos` or `stowkeeper_repo_nas` is undefined
- WHEN the role runs validation
- THEN the role SHALL fail before rendering any config
- AND the error message SHALL name the missing variable

### Requirement: Static File Deployment

The role MUST copy `backup-runner.sh`, all `stowkeeper-*.sh` libraries, and systemd service/timer unit files from `roles/backup_client/files/` to their target paths. Files SHALL be deployed with mode 0755 (scripts) and 0644 (configs, units).

#### Scenario: Scripts and units deployed

- GIVEN the role runs on a clean host
- WHEN file copy tasks complete
- THEN `/opt/stowkeeper/backup-runner.sh` and all libs SHALL exist with mode 0755
- AND systemd unit files SHALL exist in `/etc/systemd/system/` with mode 0644

### Requirement: Conditional Timer Enablement

All backup service/timer units SHALL be deployed to every host. However, `stowkeeper-backup-db.timer` MUST only be enabled when `stowkeeper_db_type` is defined and non-empty. `stowkeeper-maintenance.timer` MUST NOT be deployed by this role — it is a separate concern for the maintenance host.

#### Scenario: Database timer enabled on DB host

- GIVEN `stowkeeper_db_type` is set to "postgresql" in host_vars
- WHEN the role enables timers
- THEN `stowkeeper-backup-db.timer` SHALL be enabled and active

#### Scenario: Database timer not enabled on non-DB host

- GIVEN `stowkeeper_db_type` is undefined or empty
- WHEN the role enables timers
- THEN `stowkeeper-backup-db.timer` SHALL NOT be enabled
- AND the service file SHALL still exist on disk

#### Scenario: Maintenance timer never deployed

- GIVEN any host configuration
- WHEN the role runs
- THEN `stowkeeper-maintenance.timer` SHALL NOT be deployed or enabled

### Requirement: Post-Deployment Verification

After all tasks complete, the role MUST verify that: (1) the Restic binary is executable and returns the correct version, (2) all enabled timers are active per `systemctl is-active`.

#### Scenario: Verification passes

- GIVEN all deployment tasks succeeded
- WHEN verification tasks run
- THEN `restic version` SHALL output the pinned version
- AND `systemctl is-active stowkeeper-backup-files.timer` SHALL return "active"

#### Scenario: Verification detects failure

- GIVEN Restic binary is missing or corrupted
- WHEN verification tasks run
- THEN the role SHALL fail with a message indicating which verification step failed

### Requirement: Rollback Mode

The role MUST support `stowkeeper_state=absent` to stop timers, disable units, remove deployed files, and uninstall Restic. This mode SHALL leave Restic repositories on NAS and B2 intact (no destructive operations).

#### Scenario: Full rollback

- GIVEN the role has been applied to a host
- WHEN `stowkeeper_state=absent` is set
- THEN all timers SHALL be stopped and disabled
- AND deployed files SHALL be removed
- AND Restic repositories SHALL NOT be touched