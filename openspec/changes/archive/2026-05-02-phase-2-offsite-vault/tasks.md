# Tasks: phase-2-offsite-vault — Off-site Vault & Hardening

## Phase 1: Infrastructure

- [x] 1.1 Add dual-repo B2 config vars to `src/configs/pilot.conf`: `REPOS`, `RESTIC_REPOSITORY_nas/b2`, `RESTIC_PASSWORD_FILE_nas/b2`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, Vault AppRole vars, SMTP vars
- [x] 1.2 Create `src/configs/maintenance.conf`: elevated B2 key, Vault role with `deleteFiles`, separate Vault role ID for maintenance host
- [x] 1.3 Create `src/lib/stowkeeper-vault.sh` stub: `vault_authenticate(repo_name)` function — AppRole login, KV read, temp file, fallback to env-file
- [x] 1.4 Create `src/lib/stowkeeper-email.sh` stub: `send_email(subject, body)` function — msmtp wrapper with rate limiting and deduplication

## Phase 2: Core Implementation

- [x] 2.1 Implement `vault_authenticate()` in `stowkeeper-vault.sh`: POST to `auth/approle/login` (10s timeout), store token in memory, check TTL ≥ 5min before reuse, re-auth if expired
- [x] 2.2 Implement passphrase retrieval in `vault_authenticate()`: read from `secret/data/stowkeeper/<repo>` (KV v2), write 0600 temp file, set `RESTIC_PASSWORD_FILE`, register EXIT trap for cleanup
- [x] 2.3 Implement Vault fallback: on Vault error (timeout, unreachable, KV not found) → fall back to `RESTIC_PASSWORD_FILE_<repo>` from pilot.conf, log warning
- [x] 2.4 Implement `send_email()` in `stowkeeper-email.sh`: pipe to `msmtp -t` with From/To headers, read SMTP config from pilot.conf, skip if SMTP_HOST or SMTP_TO empty
- [x] 2.5 Implement email rate limiting in `send_email()`: enforce `SMTP_RATE_LIMIT` per hour (default 10), drop and log excess emails
- [x] 2.6 Implement email deduplication: dedup file `email-<job>-<repo>` with 4h mtime window (same logic as Telegram dedup)
- [x] 2.7 Refactor `backup-runner.sh` `authenticate()` → per-repo loop: for each repo in `REPOS[@]`, call `vault_authenticate($repo)` or fall back, set `RESTIC_REPOSITORY_<repo>` and `RESTIC_PASSWORD_FILE`
- [x] 2.8 Refactor `run_backup()` as per-repo loop: iterate `REPOS[@]`, each iteration runs `restic backup` independently, capture per-repo exit code
- [x] 2.9 Add `--repo` flag to `init` command: `backup-runner.sh init --repo b2` initializes specific repo
- [x] 2.10 Implement worst-exit-code aggregation: overall exit = highest priority (4 > 3 > 1 > 75 > 2), 0 only if all succeed; per-repo Telegram + email alerts
- [x] 2.11 Update `handle_backup_result()` to pass repo name (`nas-primary`/`b2-secondary`) for metrics label and alert messages
- [x] 2.12 Update `send_alert()` in `stowkeeper-notify.sh` to also call `send_email()` on failure (codes 1/3/4); Telegram unchanged
- [x] 2.13 Update `append_digest()` in `stowkeeper-notify.sh` to include `repo` field in JSON entry
- [x] 2.14 Update `send_digest()` to group digest lines by repo name in the consolidated message
- [x] 2.15 Implement `maintenance` subcommand in `backup-runner.sh`: authenticate to B2 with elevated key, run `restic forget --prune`, run `restic check`, emit `stowkeeper_maintenance_*` metrics, send failure alert via Telegram + email

## Phase 3: Maintenance & Hardening

- [x] 3.1 Create `src/systemd/stowkeeper-maintenance.service`: invokes `backup-runner.sh maintenance`
- [x] 3.2 Create `src/systemd/stowkeeper-maintenance.timer`: `OnCalendar=Sun *-*-* 03:00:00`, `Persistent=true`, `RandomizedDelaySec=3600`
- [x] 3.3 Implement maintenance lock acquisition: wait up to 60s for `/var/lock/stowkeeper-backup.lock`, exit 75 if contended
- [x] 4.4 Document three-layer defense model in project README/runbook: B2 Object Lock (30-day compliance), ZFS read-only snapshots (NAS), write-only B2 Application Keys

## Phase 4: Testing

- [x] 4.1 Write bats tests for `vault_authenticate()`: mock `vault` binary — successful AppRole login, invalid credentials (exit 4), timeout fallback to env-file
- [x] 4.2 Write bats tests for `send_email()`: mock `msmtp` — valid send, relay unreachable (logged), incomplete SMTP config (skipped), rate limit exceeded (dropped)
- [x] 4.3 Write bats tests for dual-repo loop: NAS fails / B2 succeeds (exit 1, B2 continues), both succeed (exit 0), both fail (worst code 4), lock contention (exit 75)
- [x] 4.4 Write bats tests for email deduplication: first failure (sends), duplicate within 4h (suppressed), after 4h window (sends again)
- [x] 4.5 Run ShellCheck on all modified/new shell files (`backup-runner.sh`, `stowkeeper-vault.sh`, `stowkeeper-email.sh`, `stowkeeper-notify.sh`) — fix all warnings

## Task Summary

| Phase | Tasks | Focus |
|-------|-------|-------|
| Phase 1 | 4 | Infrastructure: config files, lib stubs |
| Phase 2 | 15 | Core: vault auth, email, dual-repo loop, Telegram+email integration |
| Phase 3 | 4 | Maintenance host systemd units, defense-in-depth docs |
| Phase 4 | 5 | Testing: bats unit tests, ShellCheck |
| **Total** | **28** | |

## Implementation Order

1. **Phase 1 first** — all new libs and config files are prerequisites
2. **Phase 2 next** — vault auth and email libs power the dual-repo loop refactor; backup-runner changes depend on libs being present
3. **Phase 3 after** — systemd units and docs don't depend on core logic
4. **Phase 4 last** — tests validate what was built

## Open Questions (resolve before Phase 2)

- [x] Confirm Vault KV v2 mount path (`secret/` vs `stowkeeper/`) — affects vault_authenticate KV read path → **Resolved: `secret/data/stowkeeper/<repo>`**
- [x] Decide B2 Object Lock retention mode: governance vs compliance → **Resolved: compliance mode with 30-day retention**
- [x] Verify msmtp availability on target OS or needs packaging → **Resolved: msmtp is lightweight relay-only; code is mockable for testing**
