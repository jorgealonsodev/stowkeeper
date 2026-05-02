# Proposal: Phase 2 — Off-site Vault & Hardening

## Intent

Add off-site resilience, secret management, and ransomware hardening to the Phase 1 pipeline by introducing a Backblaze B2 secondary repository, HashiCorp Vault AppRole authentication, append-only key policies, and email notification fallback.

## Scope

### In Scope
- Dual-target backup (NAS + B2) in `backup-runner.sh`
- Vault AppRole auth with TTL-based passphrase injection
- B2 append-only Application Keys + dedicated maintenance host for pruning
- msmtp email notifications as secondary channel (failures only)
- New systemd maintenance timer/service
- Vault AppRole wrappers and policy files

### Out of Scope
- Ansible role deployment (Phase 3)
- B2 Object Lock bucket configuration (infrastructure)
- ZFS snapshot management (already operational)
- Resticprofile or Go migration (RDP Section 9, deferred)

## Capabilities

### New Capabilities
- `b2-secondary-repo`: Backblaze B2 off-site repository via S3-compatible API
- `vault-auth`: HashiCorp Vault AppRole authentication and passphrase injection
- `append-only-hardening`: Write-only B2 keys and maintenance-host prune/check
- `email-notifications`: msmtp-based email as secondary notification channel
- `maintenance-scheduling`: systemd timer for weekly maintenance operations

### Modified Capabilities
- `backup-runner`: Add dual-repo loop, Vault auth flow, `--maintenance` flag
- `telegram-notifications`: Failure alerts now route to both Telegram and email

## Approach

Extend `backup-runner.sh` to iterate over configured repositories (NAS + B2), executing the same job against each. Add a `--maintenance` flag that enables destructive operations (`forget --prune`) on the maintenance host.

Replace `RESTIC_PASSWORD_FILE` with Vault AppRole: each host authenticates to Vault, retrieves a short-TTL token, reads its repo passphrase from KV v2, and exports it to `RESTIC_PASSWORD` (never written to disk).

B2 uses the `s3:` backend with host-dedicated credentials. Application Keys are write-only (no delete/list). Pruning runs from an isolated maintenance VM with elevated keys during a weekly window.

Add `src/lib/stowkeeper-email.sh` as an msmtp wrapper. Failure alerts trigger both Telegram and email; success digest stays Telegram-only.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `src/backup-runner.sh` | Modified | Dual-repo loop, Vault auth, maintenance flag |
| `src/configs/pilot.conf` | Modified | B2 repo, Vault endpoint, email relay config |
| `src/lib/stowkeeper-notify.sh` | Modified | Failure alerts invoke email channel |
| `src/lib/stowkeeper-email.sh` | New | msmtp wrapper for email notifications |
| `src/systemd/stowkeeper-maintenance.*` | New | Weekly maintenance timer and service |
| `src/vault/` | New | AppRole login, KV read, policy HCL templates |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Vault downtime blocks backups | Med | Fallback to local password file; manual unlock documented |
| B2 egress costs spike on restore | Low | Prometheus alert; prefer NAS primary for restore |
| Dual-repo doubles backup runtime | Med | Sequential execution; network is the bottleneck |
| Maintenance host compromise | Low | Isolated VM; elevated credentials valid only during window |

## Rollback Plan

1. Disable B2 repo in `pilot.conf` (`B2_REPOSITORY=""`) to revert to NAS-only.
2. Comment out Vault config to restore `RESTIC_PASSWORD_FILE` auth.
3. Stop and disable `stowkeeper-maintenance.timer`.
4. Revert `backup-runner.sh` to the Phase 1 version from git.

## Dependencies

- Running HashiCorp Vault instance with KV v2 mounted
- Backblaze B2 bucket and S3-compatible endpoint
- msmtp installed with relay credentials
- Dedicated maintenance host (VM) with elevated B2 key

## Success Criteria

- [ ] Backup jobs write to both NAS and B2 repos independently
- [ ] Passphrases are retrieved from Vault at runtime, never persisted to disk
- [ ] B2 Application Key has write but no delete permissions
- [ ] Failure alerts reach both Telegram and email within 60 seconds
- [ ] `restic forget --prune` succeeds on maintenance host during weekly window
- [ ] Prometheus metrics distinguish `nas-primary` and `b2-secondary` repos
