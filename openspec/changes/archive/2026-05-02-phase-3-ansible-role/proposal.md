# Proposal: Phase 3 — Ansible Role & Multi-Host Rollout

## Intent

Replace manual per-host installation (`install.sh`) with an Ansible role that deploys the Stowkeeper backup pipeline to all servers and workstations. This scales Phase 1+2 validated code (dual-repo backup, Vault auth, notifications) from a single pilot host to the entire fleet with consistent configuration and verifiable binaries.

## Scope

### In Scope
- Ansible role `backup_client`: installs Restic, deploys `backup-runner.sh` + libs + configs, enables systemd timers, integrates Vault AppRole, registers host
- Per-host variables in `host_vars/` (backup paths, exclusions, DB type, notification prefs)
- Inventory structure grouping hosts by type: `servers`, `workstations`, `db_hosts`
- Checksum verification: Restic binary fetched from internal mirror with SHA256 validation
- Multi-host rollout to all Phase 1+2 targets

### Out of Scope
- Prometheus alerting rules (Phase 4)
- Automated restore testing (Phase 4)
- Quarterly DR exercise documentation (Phase 4)

## Capabilities

### New Capabilities
- `ansible-backup-client`: Ansible role that installs Restic, deploys wrapper/libs/configs, enables systemd timers, integrates Vault AppRole, and registers the host
- `host-inventory`: Per-host variable files (`host_vars/`) and inventory grouping by host type
- `binary-verification`: Restic binary fetched from internal mirror with SHA256 checksum validation before installation

### Modified Capabilities
- None (deployment automation does not change existing spec behavior)

## Approach

Ansible role using `ansible.builtin` modules. Restic is downloaded from an internal HTTP mirror via `get_url` with a `sha256:` checksum parameter. The role deploys `backup-runner.sh` and the four libs from `src/`, renders host-specific configs from Jinja2 templates, copies systemd units, runs `daemon-reload`, and enables timers. Host-specific overrides (paths, DB type, exclusions) live in `host_vars/<hostname>.yaml`. A `host_registration` task writes host metadata to a central registry file or API.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `ansible/roles/backup_client/` | New | Role tasks, templates, defaults, handlers |
| `ansible/inventory/` | New | Group variables and host grouping definitions |
| `ansible/host_vars/` | New | Per-host configuration overrides |
| `ansible/playbooks/deploy.yml` | New | Playbook that applies the role to target groups |
| `install.sh` | Unchanged | Kept for standalone/local installs; Ansible becomes primary |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|----------|
| Internal mirror unavailable | Med | Cache binary on control node; fail fast with clear error |
| Partial deployment leaves host misconfigured | Low | Idempotent role; `--check` mode for dry runs |
| Wrong `host_vars` applied to wrong host | Med | Inventory linting; limit playbook with `--limit` |
| systemd timer storm on simultaneous rollout | Low | `RandomizedDelaySec` already in timers; stagger rollout batches |

## Rollback Plan

1. Run the role with `backup_client_state=absent` (or equivalent cleanup task) to stop timers and remove files.
2. Manually stop and disable all `stowkeeper-*.timer` units on affected hosts.
3. Remove `/opt/stowkeeper/` and `/var/lib/stowkeeper/` if desired.
4. Restic repositories on NAS and B2 remain intact; no destructive operations are performed by the role.

## Dependencies

- Ansible control node with SSH key access to all target hosts
- Internal Restic binary mirror (HTTP/HTTPS) with published SHA256 checksums
- HashiCorp Vault operational with AppRole policies (Phase 2)
- NAS primary and B2 secondary repositories initialized (Phase 1+2)

## Success Criteria

- [ ] Ansible role deploys successfully to all target hosts without error
- [ ] Restic binary installed with verified SHA256 checksum on every host
- [ ] All systemd timers enabled and active (`systemctl is-active` returns `active`)
- [ ] Host-specific configuration (paths, exclusions, DB type) applied correctly per `host_vars`
- [ ] Vault AppRole authentication functional on all hosts (backup retrieves passphrase)
- [ ] First automated backup completes on each host within 24 hours of deployment
