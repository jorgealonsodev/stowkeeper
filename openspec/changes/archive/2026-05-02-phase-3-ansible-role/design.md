# Design: Phase 3 — Ansible Role & Multi-Host Rollout

## Technical Approach

The Ansible role `backup_client` replaces the manual `install.sh` with idempotent, declarative deployment. It copies static Bash scripts and libraries as-is, renders per-host configuration from Jinja2 templates, deploys systemd units conditionally based on host variables, and verifies the Restic binary via SHA256 checksum from an internal mirror. Secrets (Vault AppRole credentials) are Ansible-vault encrypted in `host_vars/`, never in plaintext. The role does NOT deploy maintenance units — those run on a separate host via a different playbook.

## Architecture Decisions

### Decision: Template vs Static Deployment

**Choice**: Only `pilot.conf` → Jinja2 template; all other files copied as-is.
**Alternatives**: Template systemd units; template all configs.
**Rationale**: The Bash scripts are identical across hosts. Systemd units reference `EnvironmentFile=/opt/stowkeeper/conf/pilot.conf` — per-host variance is already expressed through that env file. Templating the service files would add complexity with zero benefit. `maintenance.conf` is excluded entirely (maintenance host only).

### Decision: Secrets Management

**Choice**: Ansible-vault encrypted `host_vars/<host>.yml` with Vault AppRole credentials.
**Alternatives**: Plain vars; HashiCorp Vault lookups at runtime via `community.hashi_vault`.
**Rationale**: Per RDP 3.4 and 3.11, secrets are in Vault. The role needs AppRole role_id/secret_id to write into `pilot.conf`, but these credentials should not be plaintext in the repo. Ansible-vault encryption is simpler than adding a Vault collection dependency and keeps the deployment self-contained. Runtime Vault lookups (`stowkeeper-vault.sh`) remain unchanged.

### Decision: Restic Distribution

**Choice**: Download from internal mirror via `get_url` with `checksum: sha256:{{ restic_checksum }}`. Fail if mirror unreachable.
**Alternatives**: Download from GitHub releases; install from OS package manager.
**Rationale**: RDP 3.11 mandates distribution from internal mirror with verified checksum. No internet dependency during deployment. `get_url` provides built-in idempotency and checksum verification.

### Decision: Conditional Timer Deployment

**Choice**: Deploy all service/timer units, but only enable timers conditionally. `stowkeeper-backup-db.timer` enabled only when `stowkeeper_db_type` is defined.
**Alternatives**: Skip copying service files entirely for disabled features.
**Rationale**: Having all unit files present allows manual enablement without re-running the role. Conditional enablement via `when` keeps the task list simple while respecting host capabilities.

## Data Flow

```
Control Node                      Target Host
─────────────                     ────────────
ansible-playbook ──SSH──→  ┌──────────────────────────┐
                            │ 1. Validate + deps       │
                            │ 2. Create dirs            │
                            │ 3. Install restic (SHA256)│
                            │ 4. Copy scripts/libs      │
                            │ 5. Template pilot.conf    │
                            │ 6. Copy systemd units     │
                            │ 7. daemon-reload          │
                            │ 8. Enable timers          │
                            │ 9. Verify                 │
                            └──────────────────────────┘
                                     │
                            pilot.conf sourced
                            by backup-runner.sh
                                     │
                            ┌────────┴─────────┐
                            │  systemd timers    │
                            │  ┌─ backup-config  │
                            │  ├─ backup-files   │
                            │  ├─ backup-db ←───│── if stowkeeper_db_type
                            │  ├─ check          │
                            │  └─ digest         │
                            └────────────────────┘
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `ansible/roles/backup_client/tasks/main.yml` | Create | Main task list: validate, deps, dirs, binaries, configs, systemd, enable, verify |
| `ansible/roles/backup_client/templates/pilot.conf.j2` | Create | Jinja2 template producing valid bash from host_vars |
| `ansible/roles/backup_client/templates/excludes.txt.j2` | Create | Template for exclude patterns list |
| `ansible/roles/backup_client/files/` | Create | Static copies of `backup-runner.sh`, `stowkeeper-*.sh` libs |
| `ansible/roles/backup_client/files/systemd/` | Create | Static copies of service/timer unit files |
| `ansible/roles/backup_client/handlers/main.yml` | Create | `daemon-reload` + timer enable/start handler |
| `ansible/roles/backup_client/defaults/main.yml` | Create | Default vars (paths, restic version, mirror URL) |
| `ansible/roles/backup_client/vars/main.yml` | Create | Role-internal variables |
| `ansible/roles/backup_client/meta/main.yml` | Create | Role metadata and dependencies |
| `ansible/host_vars/<host>.yml` | Create | Per-host variables (backup paths, DB type, vault credentials) |
| `ansible/inventory/hosts.yml` | Create | Inventory grouping servers, workstations, db_hosts |
| `ansible/playbooks/deploy.yml` | Create | Playbook applying role to target groups |
| `ansible/group_vars/all.yml` | Create | Group-level defaults (mirror URL, restic version) |
| `ansible/group_vars/servers.yml` | Create | Server-specific overrides |
| `ansible/group_vars/workstations.yml` | Create | Workstation-specific overrides |

## Interfaces / Contracts

### pilot.conf.j2 Template Contract

The template MUST produce valid bash that can be `source`d. Key variable mappings:

```yaml
# host_vars/<host>.yml → pilot.conf
stowkeeper_repos: ["nas", "b2"]                    → REPOS=("nas" "b2")
stowkeeper_repo_nas: "sftp:user@nas:/backups/..."  → RESTIC_REPOSITORY_nas="..."
stowkeeper_repo_b2: "s3:https://s3.../bucket"     → RESTIC_REPOSITORY_b2="..."
stowkeeper_db_type: "postgresql"                   → DB_TYPE="postgresql"
stowkeeper_backup_paths_config: ["/etc"]           → BACKUP_PATHS_CONFIG=("/etc")
stowkeeper_backup_paths_files: ["/home", "/var/www"] → BACKUP_PATHS_FILES=("/home" "/var/www")
stowkeeper_backup_paths_db: ["/var/lib/pgsql/dumps"]   → BACKUP_PATHS_DB=("/var/lib/pgsql/dumps")
stowkeeper_exclude_patterns: ["*.tmp", "*.log"]    → EXCLUDE_FILE="/opt/stowkeeper/conf/excludes.txt"
stowkeeper_notification_level: "full"              → conditional Telegram/email
stowkeeper_vault_addr: "https://vault.local:8200"  → VAULT_ADDR="..."
stowkeeper_vault_role_id_nas: "{{ vault_nas_role }}" → VAULT_ROLE_ID_stowkeeper_nas="..." (vault-encrypted)
stowkeeper_vault_secret_id_nas: "{{ vault_nas_secret }}" → VAULT_SECRET_ID_stowkeeper_nas="..." (vault-encrypted)
```

### Ansible Role Default Variables

```yaml
# defaults/main.yml
stowkeeper_install_dir: /opt/stowkeeper
stowkeeper_conf_dir: /opt/stowkeeper/conf
stowkeeper_lib_dir: /opt/stowkeeper/lib
stowkeeper_var_dir: /var/lib/stowkeeper
stowkeeper_log_dir: /var/log/stowkeeper
stowkeeper_repos: ["nas"]
stowkeeper_db_type: ""
stowkeeper_notification_level: "full"
stowkeeper_metrics_dir: /var/lib/prometheus/node-exporter
restic_version: "0.17.3"
restic_mirror_base_url: "https://mirror.internal/restic"
restic_checksum: ""  # MUST be set in group_vars or host_vars
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Unit | Template output produces valid bash | `ansible-playbook --check` + `shellcheck` on rendered pilot.conf |
| Unit | Default variable merging | Assert tests in `tests/test_vars.yml` |
| Integration | Full role convergence on clean host | Molecule with Vagrant/SSH delegate |
| Integration | Idempotency (second run = no changes) | Molecule verify step |
| E2E | Backup runs after Ansible deploy | Deploy → trigger timer → verify snapshot in test repo |

## Migration / Rollout

No data migration required. The Ansible role replaces `install.sh` for new deployments. Existing pilot host can be re-converged with the role — `pilot.conf` will be templated (backed up first) and systemd units updated. Phased rollout: (1) servers group, (2) workstations, (3) verify all timers active. Use `--limit` for staging.

## Open Questions

- [ ] Confirm internal mirror URL and Restic version for `defaults/main.yml`
- [ ] Decide if `stowkeeper-maintenance.timer` should be a separate role (`maintenance_host`) or a conditional include in `backup_client`