# Host Inventory Specification

## Purpose

Structure for organizing target hosts with per-host backup configuration, group membership, variable precedence, and encrypted secrets — ensuring each host receives the correct Stowkeeper configuration from the Ansible role.

## Requirements

### Requirement: Host Variable Files

Each target host MUST have a `host_vars/<hostname>.yml` file containing all Stowkeeper-specific variables. Required variables: `stowkeeper_repos`, per-repo `stowkeeper_repo_<name>`, per-repo `stowkeeper_vault_role_id_<name>` and `stowkeeper_vault_secret_id_<name>`. Optional variables: `stowkeeper_db_type`, `stowkeeper_backup_paths_db`, `stowkeeper_exclude_patterns`, `stowkeeper_notification_level`.

#### Scenario: Complete host vars file

- GIVEN `host_vars/web01.yml` defines all required variables plus `stowkeeper_db_type: postgresql`
- WHEN the Ansible role renders templates for `web01`
- THEN `pilot.conf` SHALL contain all mapped bash variables
- AND `DB_TYPE="postgresql"` SHALL appear in the output

#### Scenario: Incomplete host vars

- GIVEN `host_vars/web02.yml` is missing `stowkeeper_repo_nas`
- WHEN the role runs validation
- THEN the role SHALL fail with a message naming the missing variable

### Requirement: Group Membership

Hosts MUST belong to Ansible inventory groups: `servers` and `workstations` are disjoint. `db_hosts` is a subgroup of `servers`. The deploy playbook SHALL target `servers` and `workstations` separately for staged rollout.

#### Scenario: Server with database

- GIVEN `db01` belongs to both `servers` and `db_hosts`
- WHEN the playbook targets the `servers` group
- THEN `db01` SHALL receive the backup-client role
- AND `stowkeeper-backup-db.timer` SHALL be enabled (because `stowkeeper_db_type` is set)

#### Scenario: Workstation without database

- GIVEN `ws01` belongs to `workstations` only and has no `stowkeeper_db_type`
- WHEN the playbook targets the `workstations` group
- THEN `ws01` SHALL receive the backup-client role
- AND `stowkeeper-backup-db.timer` SHALL NOT be enabled

### Requirement: Variable Precedence

Default values from `defaults/main.yml` SHALL be overridden by `group_vars/all.yml`, which SHALL be overridden by `group_vars/<group>.yml`, which SHALL be overridden by `host_vars/<hostname>.yml`. This matches Ansible's standard precedence.

#### Scenario: Host var overrides group var

- GIVEN `group_vars/servers.yml` sets `stowkeeper_notification_level: full`
- AND `host_vars/db01.yml` sets `stowkeeper_notification_level: failures-only`
- WHEN the role renders `pilot.conf` for `db01`
- THEN notification level SHALL be "failures-only"

#### Scenario: Group var provides default

- GIVEN `group_vars/all.yml` sets `restic_version: "0.17.3"`
- AND no host overrides the version
- WHEN the role installs Restic on any host
- THEN Restic version 0.17.3 SHALL be deployed

### Requirement: Backup Paths

Each host MUST define `stowkeeper_backup_paths_config` and `stowkeeper_backup_paths_files` as arrays. Hosts with databases MUST also define `stowkeeper_backup_paths_db`. Paths SHALL be rendered into `pilot.conf` as bash arrays.

#### Scenario: Paths rendered as bash arrays

- GIVEN `stowkeeper_backup_paths_files: ["/home", "/var/www"]`
- WHEN `pilot.conf.j2` is rendered
- THEN the output SHALL contain `BACKUP_PATHS_FILES=("/home" "/var/www")`

### Requirement: Exclusion Patterns

A host MAY define `stowkeeper_exclude_patterns` as an array of glob patterns. These SHALL be rendered into `excludes.txt` via the `excludes.txt.j2` template. If undefined, an empty excludes file SHALL be created.

#### Scenario: Exclusion patterns rendered

- GIVEN `stowkeeper_exclude_patterns: ["*.tmp", "*.log", ".cache"]`
- WHEN `excludes.txt.j2` is rendered
- THEN the file SHALL contain one pattern per line

#### Scenario: No exclusion patterns

- GIVEN `stowkeeper_exclude_patterns` is undefined
- WHEN `excludes.txt.j2` is rendered
- THEN an empty file SHALL be created

### Requirement: Secrets Encryption

Vault AppRole credentials (`stowkeeper_vault_role_id_<repo>`, `stowkeeper_vault_secret_id_<repo>`) MUST be encrypted with Ansible Vault in `host_vars/<hostname>.yml`. These values SHALL NOT appear in plaintext in any file committed to the repository.

#### Scenario: Vault-encrypted credentials in host vars

- GIVEN `host_vars/db01.yml` contains Vault-encrypted role_id and secret_id
- WHEN `ansible-playbook` runs with `--ask-vault-pass`
- THEN the credentials SHALL be decrypted at render time
- AND the resulting `pilot.conf` on the target host SHALL contain the plaintext values (with mode 0600)

#### Scenario: Plaintext credentials rejected

- GIVEN a host_vars file contains plaintext AppRole credentials
- WHEN the playbook is executed
- THEN the playbook SHOULD still work but the repository MUST NOT be committed with plaintext secrets