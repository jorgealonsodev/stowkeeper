# Tasks: Phase 3 — Ansible Role & Multi-Host Rollout

## Phase 1: Infrastructure

- [x] 1.1 Create `ansible/roles/backup_client/tasks/` directory structure (main.yml, validate.yml, deps.yml, dirs.yml, restic.yml, scripts.yml, templates.yml, systemd.yml, verify.yml)
- [x] 1.2 Create `ansible/roles/backup_client/handlers/main.yml` with `daemon-reload` and `restart-timers` handlers
- [x] 1.3 Create `ansible/roles/backup_client/defaults/main.yml` with all default variables (install paths, restic version, mirror URL, etc.)
- [x] 1.4 Create `ansible/roles/backup_client/vars/main.yml` with role-internal variables
- [x] 1.5 Create `ansible/roles/backup_client/meta/main.yml` with role metadata and Galaxy dependencies
- [x] 1.6 Create `ansible/ansible.cfg` with connection settings, inventory path, roles_path
- [x] 1.7 Create `ansible/inventory/hosts.yml` with groups: `servers`, `workstations`, `db_hosts` (subgroup of servers)
- [x] 1.8 Create `ansible/group_vars/all.yml` with mirror URL and restic version defaults
- [x] 1.9 Create `ansible/group_vars/servers.yml` and `ansible/group_vars/workstations.yml` with group-specific overrides
- [x] 1.10 Create `ansible/playbooks/deploy.yml` targeting servers and workstations groups

## Phase 2: Core Implementation

- [x] 2.1 Create `ansible/roles/backup_client/tasks/validate.yml` — fail if required vars (repos, repo URLs, checksum) are undefined
- [x] 2.2 Create `ansible/roles/backup_client/tasks/deps.yml` — ensure Python3, ssh,acl installed
- [x] 2.3 Create `ansible/roles/backup_client/tasks/dirs.yml` — create `/opt/stowkeeper/{conf,lib}`, `/var/lib/stowkeeper`, `/var/log/stowkeeper`
- [x] 2.4 Create `ansible/roles/backup_client/tasks/restic.yml` — download restic from mirror with SHA256 checksum, idempotent via `creates`
- [x] 2.5 Create `ansible/roles/backup_client/files/` — copy `backup-runner.sh` and all `src/lib/stowkeeper-*.sh` to `/opt/stowkeeper/` (mode 0755)
- [x] 2.6 Create `ansible/roles/backup_client/templates/pilot.conf.j2` — render valid bash config from host_vars (REPOS array, per-repo RESTIC_REPOSITORY_*, DB_TYPE, BACKUP_PATHS_*, VAULT_ADDR, vault credentials)
- [x] 2.7 Create `ansible/roles/backup_client/templates/excludes.txt.j2` — render exclude patterns one per line (empty if undefined)
- [x] 2.8 Create `ansible/roles/backup_client/files/systemd/` — copy all unit files EXCEPT maintenance units (backup-config/files/db services+timers, check, digest)
- [x] 2.9 Create `ansible/roles/backup_client/tasks/systemd.yml` — copy units to `/etc/systemd/system/`, daemon-reload, enable timers conditionally (`when: stowkeeper_db_type` for db timer)
- [x] 2.10 Create `ansible/roles/backup_client/tasks/verify.yml` — run `restic version` and `systemctl is-active` checks, fail if binary missing or timers not active
- [x] 2.11 Create `ansible/roles/backup_client/tasks/main.yml` — import all subtasks in order: validate, deps, dirs, restic, scripts, templates, systemd, verify
- [x] 2.12 Create `ansible/host_vars/<example-host>.yml` — example host with all required vars (vault credentials shown as placeholder comments)
- [x] 2.13 Add `stowkeeper_state=absent` support: stop/disable timers, remove files, uninstall restic (repos untouched)

## Phase 3: Verification

- [x] 3.1 Run `ansible-playbook --syntax-check deploy.yml` to validate playbook syntax
- [x] 3.2 Run `ansible-lint deploy.yml` to check for Ansible best-practices violations
- [x] 3.3 Run `ansible-playbook deploy.yml --check --diff` in check mode to validate template rendering without executing
- [x] 3.4 Verify `pilot.conf.j2` produces valid bash by shellchecking a rendered test output
- [x] 3.5 Verify idempotency: run deploy twice, second run should report zero changes

## Phase 4: Documentation

- [x] 4.1 Write `ansible/roles/backup_client/README.md` with role usage, required variables, vault encryption instructions
- [x] 4.2 Document `ansible/inventory/` example with two server examples and one workstation example