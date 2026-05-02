# Proposal: Phase 1 — Core Backup Pipeline

## Intent

Establish the foundational backup pipeline on a single pilot host against the primary NAS repository. Phase 1 validates the end-to-end flow (execution → notification → metrics) before scaling to multiple hosts and adding the off-site repository.

## Scope

### In Scope
- Initialize Restic repository on NAS (SFTP)
- Build `backup-runner.sh` wrapper (Vault auth stub, lockfile, metrics capture, notifications)
- Deploy systemd timers (hourly DB dumps, daily files/configs)
- Configure pilot host with paths, exclusions, and retention policy
- Telegram success digest (daily 08:00) and immediate failure alerts
- Prometheus textfile collector metrics (`backup_last_success_timestamp`, `backup_duration_seconds`, `backup_size_bytes`)

### Out of Scope
- Backblaze B2 secondary repository (Phase 2)
- HashiCorp Vault AppRole integration (Phase 2; passphrases via environment/file stub)
- Ansible role for multi-host rollout (Phase 3)
- Append-only hardening and `forget --prune` automation (Phase 2)
- Automated restore tests and deep integrity checks (Phase 4)
- Email fallback notifications

## Capabilities

### New Capabilities
- `backup-runner`: Central wrapper script that authenticates, locks, runs Restic, captures metrics, and notifies
- `nas-primary-repo`: SFTP-based primary repository initialization and backup target
- `systemd-scheduling`: Timer and path units for hourly DB and daily file/config backups
- `telegram-notifications`: Bot-based daily digest and immediate failure alerts with deduplication
- `prometheus-metrics`: Textfile collector metrics exported for scraping

### Modified Capabilities
- None (greenfield project)

## Approach

Single Bash wrapper (`backup-runner.sh`) invoked by systemd timers. The wrapper reads host-specific config (paths, exclusions, repo URL, passphrase), acquires a lockfile, executes `restic backup`, captures duration and size, writes Prometheus textfile metrics, and emits Telegram notifications via `curl`. Passphrases are injected via environment variables (Vault integration deferred to Phase 2).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `backup-runner.sh` | New | Central wrapper script |
| `systemd/` | New | Timer and service unit files |
| `host_vars/pilot/` | New | Pilot host configuration (paths, exclusions) |
| `/var/lib/prometheus/node-exporter/` | New | Textfile metric directory |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| NAS SFTP unavailable during backup | Medium | Wrapper exits with error; alert fires; no data loss (backup retries next interval) |
| Restic version mismatch | Low | Pin Restic version in config; validate binary checksum |
| Lockfile stale if wrapper crashes | Low | Use `flock` with timeout; alert on lock timeout |
| Telegram rate limiting | Low | Deduplicate alerts; batch digest once daily |

## Rollback Plan

1. Stop and disable systemd timers: `systemctl stop/disable`.
2. Remove wrapper script and config from pilot host.
3. Restic repository on NAS remains intact (no destructive ops in Phase 1).
4. Revert to any pre-existing manual backup process.

## Dependencies

- NAS accessible via SFTP with write permissions for pilot host
- Restic binary (≥0.16) available on pilot host
- Telegram bot token and group chat ID configured
- node_exporter with textfile collector enabled on pilot host

## Success Criteria

- [ ] Hourly DB dump backup completes successfully on pilot host
- [ ] Daily file/config backup completes successfully on pilot host
- [ ] Telegram daily digest received at 08:00 with summary of jobs
- [ ] Simulated failure triggers immediate Telegram alert within 60 seconds
- [ ] Prometheus metrics visible in textfile directory with correct labels
