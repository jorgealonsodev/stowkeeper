# Design: Phase 2 — Off-site Vault & Hardening

## Technical Approach

Extend the Phase 1 single-repo pipeline into a dual-repo loop: `backup-runner.sh` iterates over `REPOS=("nas" "b2")`, authenticating and backing up to each sequentially. Add Vault AppRole authentication (with env-file fallback), msmtp email for failure alerts, and a maintenance host systemd unit for weekly prune/check on B2. The existing lib/ modular pattern makes this a natural extension — new `stowkeeper-email.sh` and `stowkeeper-vault.sh` libs slot in cleanly.

## Architecture Decisions

### Decision: Sequential repo iteration

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Parallel repos | Faster, but doubles CPU/RAM/network | Rejected — resource contention on single-host |
| Sequential loop | Simpler, single resource stream | ✅ Chosen |

Sequential avoids double restic processes, swap pressure, and NAS+B2 bandwidth competition. Network is the bottleneck; ordering doesn't matter.

### Decision: Vault AppRole with env-file fallback

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Vault-only | Vault is SPOF | Rejected — backup must not depend on Vault uptime |
| Env-file only | Simpler, but passphrases on disk | Phase 1 approach, insufficient for B2 |
| Vault primary + env-file fallback | Resilient, passphrases off-disk when possible | ✅ Chosen |

`vault_authenticate()` tries Vault first. If Vault is unreachable (exit ≠ 0, timeout 10s), fall back to `RESTIC_PASSWORD_FILE_${repo}` from `pilot.conf`. Log which path was taken. This preserves backup availability while progressively moving secrets off-disk.

### Decision: Per-repo lock files

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Single lock (/var/lock/stowkeeper-backup.lock) | Prevents any concurrency, simple | ✅ Chosen for Phase 2 |
| Per-repo lock | Allows NAS+B2 parallel | Rejected — contradicts sequential decision |

Same single lock file covers the entire run (both repos). The lock protects the host's I/O, not individual repos.

### Decision: B2 Application Key permissions

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Full access key | Can delete, simpler | Rejected — ransomware risk |
| writeFiles-only key | Cannot delete or list buckets | ✅ Chosen for backup clients |
| Separate maintenance key | deleteFiles for prune | ✅ Chosen for maintenance host |

Backup clients use a write-only key (no `deleteFiles`, no `listBuckets`). The maintenance host holds a separate key with `deleteFiles` for `forget --prune`, used only during the weekly window.

### Decision: msmtp for email notifications

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Postfix/sendmail | Heavy, daemon process | Rejected |
| Python smtp lib | Extra dependency | Rejected |
| msmtp | Lightweight, relay-only, no daemon | ✅ Chosen |

msmtp is a single binary send-only relay. Fits the Bash wrapper architecture — pipe email to `msmtp -t`.

## Data Flow

```
systemd timer ──▶ backup-runner.sh
                   1. acquire_lock
                   2. REPOS=("nas" "b2")
                   3. for repo in "${REPOS[@]}"; do
                      ├── vault_authenticate($repo)
                      │     ├── OK → export passphrase to RESTIC_PASSWORD_FILE (tmpfile 600)
                      │     └── FAIL → fall back to RESTIC_PASSWORD_FILE_${repo} from conf
                      ├── export RESTIC_REPOSITORY=${RESTIC_REPOSITORY_${repo}}
                      ├── restic backup --host $HOSTNAME --tag $job …
                      ├── emit metrics (label: repo=$repo)
                      ├── on failure → send_alert (Telegram + email)
                      └── cleanup temp password file
                   4. release_lock

maintenance host (weekly Sun 03:00):
  stowkeeper-maintenance.service
    → vault_authenticate(b2) with elevated role
    → restic forget --prune (B2)
    → restic check (B2)
    → emit check metrics (repo=b2-secondary)
    → send_alert on failure (Telegram + email)
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `src/backup-runner.sh` | Modify | Dual-repo loop, `maintenance` subcommand, per-repo metrics |
| `src/lib/stowkeeper-vault.sh` | Create | `vault_authenticate(repo_name)`: AppRole login → KV read → temp file |
| `src/lib/stowkeeper-email.sh` | Create | `send_email(subject, body)`: msmtp wrapper with rate limiting |
| `src/lib/stowkeeper-notify.sh` | Modify | `send_alert()` now also calls `send_email()` for failure type |
| `src/configs/pilot.conf` | Modify | Add B2 repo vars, Vault config, SMTP config |
| `src/configs/maintenance.conf` | Create | Separate config with elevated B2 key and Vault role |
| `src/systemd/stowkeeper-maintenance.service` | Create | Weekly maintenance: forget --prune + check on B2 |
| `src/systemd/stowkeeper-maintenance.timer` | Create | OnCalendar=Sun *-*-* 03:00:00, Persistent=true |

## Interfaces / Contracts

### New config keys in `pilot.conf`

```bash
# Dual-repo configuration
REPOS=("nas" "b2")
RESTIC_REPOSITORY_nas="sftp:user@nas.local:/backups/stowkeeper"
RESTIC_REPOSITORY_b2="s3:https://s3.us-west-000.backblazeb2.com/stowkeeper-b2"
RESTIC_PASSWORD_FILE_nas="/opt/stowkeeper/conf/.restic-password-nas"
RESTIC_PASSWORD_FILE_b2="/opt/stowkeeper/conf/.restic-password-b2"

# B2 Application Key (write-only, no delete)
AWS_ACCESS_KEY_ID=""        # B2 keyID
AWS_SECRET_ACCESS_KEY=""     # B2 key

# Vault AppRole
VAULT_ADDR="https://vault.local:8200"
VAULT_ROLE_ID_stowkeeper_nas=""
VAULT_ROLE_ID_stowkeeper_b2=""
VAULT_SECRET_ID_stowkeeper_nas=""
VAULT_SECRET_ID_stowkeeper_b2=""

# SMTP (msmtp)
SMTP_HOST="" SMTP_PORT="587" SMTP_USER="" SMTP_PASS=""
SMTP_FROM="stowkeeper@example.com" SMTP_TO="ops@example.com"
SMTP_RATE_LIMIT=10  # max emails per hour
```

### `vault_authenticate(repo_name)` contract

Returns 0 on success, sets `RESTIC_PASSWORD_FILE` to a temp file (mode 600) containing the passphrase. On failure, returns non-zero — caller falls back to env-file. Temp file cleaned up in EXIT trap.

### Exit codes (unchanged)

Same as Phase 1: 0 success, 1 restic error, 3 config error, 4 auth error, 75 lock contention. New: `maintenance` subcommand uses same codes.

## Testing Strategy

| Layer | Target | Approach |
|-------|--------|----------|
| Unit | `vault_authenticate`, `send_email`, dual-repo loop | ShellCheck + bats; mock `vault` binary, mock `msmtp` |
| Unit | Per-repo metrics emission | Assert `repo` label differs between `nas-primary` and `b2-secondary` |
| Integration | Full cycle vs local SFTP + B2 mock | Two-restic-repo init, backup, check |
| Integration | Vault AppRole login flow | Docker Vault dev server, verify TTL and temp-file perms |
| E2E | Maintenance host cycle | `backup-runner.sh maintenance` against B2 with elevated key |

## Migration / Rollout

1. Deploy `stowkeeper-vault.sh`, `stowkeeper-email.sh`, and updated `backup-runner.sh`
2. Add B2 repo vars to `pilot.conf` — set `REPOS=("nas")` initially (NAS-only)
3. Validate Vault AppRole works: `backup-runner.sh backup --job config` with Vault auth
4. Flip `REPOS=("nas" "b2")` — dual-repo mode active
5. Deploy `maintenance.conf` + systemd units on maintenance host only
6. Rollback: set `REPOS=("nas")` in `pilot.conf` to revert to single-repo

## Open Questions

- [ ] Confirm Vault KV v2 mount path (`secret/` vs `stowkeeper/`)
- [ ] Decide B2 Object Lock retention mode: governance vs compliance
- [ ] Verify msmtp is available on the target OS or needs packaging