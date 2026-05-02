# Stowkeeper

Multi-repository backup system with NAS primary + Backblaze B2 off-site secondary, HashiCorp Vault integration, Telegram and email notifications, and append-only hardening.

## Architecture

```
┌─────────────┐     ┌─────────────────┐     ┌──────────────┐
│ systemd     │────▶│ backup-runner.sh│────▶│ NAS (SFTP)   │
│ timers      │     │                 │     └──────────────┘
└─────────────┘     │  • Vault auth   │
                    │  • Dual-repo    │     ┌──────────────┐
                    │  • Metrics      │────▶│ B2 (S3)      │
                    │  • Alerts       │     └──────────────┘
                    └─────────────────┘
```

## Quick Start

1. Copy `src/configs/pilot.conf` to `/opt/stowkeeper/conf/pilot.conf`
2. Set `REPOS=("nas" "b2")` for dual-repo mode, or `REPOS=("nas")` for NAS-only
3. Configure per-repo credentials and paths
4. Install systemd units from `src/systemd/` and enable timers
5. Run `backup-runner.sh init` to initialize repositories

## Commands

```bash
backup-runner.sh init [--repo nas|b2]   # Initialize repo(s)
backup-runner.sh backup --job <db|files|config>
backup-runner.sh check                  # Forget --prune + check
backup-runner.sh maintenance            # Weekly B2 maintenance
backup-runner.sh restore --snapshot <id> --target <path>
backup-runner.sh snapshots
backup-runner.sh digest                 # Send daily success digest
```

## Defense-in-Depth Model

Stowkeeper implements a three-layer defense model to protect backup data against ransomware, operator error, and unauthorized deletion:

### Layer 1: B2 Object Lock (30-Day Compliance)

The Backblaze B2 bucket is configured with **Object Lock in compliance mode** with a minimum 30-day retention period. Objects under retention **cannot be deleted or overwritten by any key**, including the maintenance elevated key, until the retention period expires. This ensures that even if an attacker gains access to the maintenance host, snapshots younger than 30 days remain immutable.

- **Scope**: B2 repository only
- **Limitation**: Does not prevent new snapshot creation; only prevents deletion/overwriting of existing objects
- **Configuration**: Enabled at bucket creation; retention policy set via B2 console or API

### Layer 2: ZFS Read-Only Snapshots (NAS)

The NAS primary repository resides on a ZFS dataset with periodic read-only snapshots. These snapshots are **immutable at the filesystem level** and cannot be modified or deleted without explicit administrative action on the NAS itself.

- **Scope**: NAS primary repository
- **Limitation**: Protects only the NAS copy; does not extend to B2
- **Configuration**: Managed independently on the NAS host via `zfs snapshot` and snapshot retention policies

### Layer 3: Write-Only B2 Application Keys

Backup clients use a **write-only B2 Application Key** with `writeFiles` permission only — no `deleteFiles`, no `listBuckets`, no `listFiles`. This means a compromised backup client can write new snapshots but **cannot delete, prune, or list existing data**.

The maintenance host holds a **separate elevated key** with `deleteFiles` and `listFiles` permissions, used only during the weekly maintenance window (`stowkeeper-maintenance.timer`). This key **must not be present on backup clients**.

- **Scope**: B2 repository access control
- **Limitation**: Does not protect against data corruption at write time; restic's encryption and checksums handle integrity
- **Rotation**: Elevated keys should be rotated immediately if the maintenance host is compromised

### Combined Effect

| Threat | Layer 1 | Layer 2 | Layer 3 |
|--------|---------|---------|---------|
| Ransomware deletes backups | Blocked (30d retention) | Blocked (read-only ZFS) | Blocked (no delete permission) |
| Insider deletes snapshots | Blocked (30d retention) | Admin-only | Blocked (no delete permission) |
| Compromised maintenance host | Blocked for <30d objects | N/A | N/A (elevated key is expected) |
| Accidental `restic forget` | Blocked (30d retention) | Blocked (read-only ZFS) | Blocked (write-only key) |

## Vault Integration

Restic passphrases are retrieved from HashiCorp Vault KV v2 at runtime using AppRole authentication. If Vault is unreachable, the system falls back to local password files (`RESTIC_PASSWORD_FILE_<repo>`) without failing the backup.

- Vault path: `secret/data/stowkeeper/<repo>`
- Temp file: created with mode `0600`, cleaned up on exit
- Timeout: 10 seconds for Vault API calls

## Maintenance Host

The weekly maintenance timer (`stowkeeper-maintenance.timer`) runs on an isolated host:

- **When**: Sunday 03:00 (with `Persistent=true` for catch-up)
- **What**: `restic forget --prune` + `restic check` on B2
- **Lock**: Shares the same flock as backups to prevent concurrency
- **Credentials**: Separate `maintenance.conf` with elevated B2 key

## Monitoring

Prometheus textfile metrics are written to the node_exporter collector directory:

- `stowkeeper_backup_status{repo="nas-primary"}`
- `stowkeeper_backup_last_success_timestamp{repo="b2-secondary"}`
- `stowkeeper_maintenance_status{repo="b2-secondary"}`
- `stowkeeper_check_last_success_timestamp{repo="..."}`

## Notifications

- **Telegram**: All alerts (failure, warning) and daily success digests
- **Email (msmtp)**: Failure alerts only (codes 1, 3, 4); success digests are Telegram-only
- **Deduplication**: 4-hour window per job+repo
- **Rate limiting**: Max 10 emails/hour (configurable via `SMTP_RATE_LIMIT`)

## File Layout

```
/opt/stowkeeper/
├── backup-runner.sh
├── lib/
│   ├── stowkeeper-metrics.sh
│   ├── stowkeeper-notify.sh
│   ├── stowkeeper-vault.sh
│   └── stowkeeper-email.sh
└── conf/
    ├── pilot.conf
    └── maintenance.conf
```

## License

MIT
