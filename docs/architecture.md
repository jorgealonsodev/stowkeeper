# Stowkeeper Architecture

This document describes the architecture of Stowkeeper, an end-to-end encrypted backup system for Linux servers and workstations. It is intended for new team members onboarding to the project.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Design Principles](#2-design-principles)
3. [Component Architecture](#3-component-architecture)
4. [Data Flow](#4-data-flow)
5. [Repository Topology](#5-repository-topology)
6. [Security Architecture](#6-security-architecture)
7. [Retention and Rotation](#7-retention-and-rotation)
8. [Observability](#8-observability)
9. [Deployment Models](#9-deployment-models)
10. [Failure Modes and Recovery](#10-failure-modes-and-recovery)
11. [Technology Choices](#11-technology-choices)

---

## 1. System Overview

Stowkeeper is a reproducible, code-driven backup pipeline that maintains two fully independent Restic repositories for every host: a local NAS repository and a remote Backblaze B2 repository. Every backup is encrypted client-side with AES-256 before any data leaves the host.

### What Problem It Solves

Traditional backup solutions often suffer from one or more of these failures:

- **Single point of failure** — one repository, one storage medium, one location.
- **Silent corruption** — backups run for months without ever being verified or restored.
- **Ransomware vulnerability** — a compromised client can delete or encrypt its own backups.
- **Operational blindness** — no metrics, no alerting, no digest of daily health.

Stowkeeper addresses all four by enforcing the 3-2-1 rule, running automated integrity checks, hardening repositories against deletion, and exporting Prometheus metrics with Alertmanager rules.

### High-Level Diagram

```
                       +----------------------+
                       |   Vault (secrets)    |
                       |   AppRole auth       |
                       +----------+-----------+
                                  |
                                  | short-TTL token
                                  |
    +----------+  +----------+    |    +----------+
    | Server A |  | Server B |    |    |  WS X    |
    |(Restic)  |  |(Restic)  |<---+    |(Restic)  |
    +----+-----+  +----+-----+         +----+-----+
         |             |                    |
         | SFTP        |                    | HTTPS (S3)
         v             v                    v
    +--------------------+          +------------------+
    |   NAS (ZFS)        |          |  Backblaze B2    |
    |   Primary repo     |          |  Secondary repo  |
    |   + ZFS snapshots  |          |  + Object Lock   |
    +--------------------+          +------------------+

         +-------------------------------------------+
         | backup-runner.sh -> Telegram + email       |
         |                -> Prometheus metrics       |
         +-------------------------------------------+
```

### Key Stats

- **Source language**: Bash (with Go migration path documented)
- **Backup engine**: Restic 0.17+
- **Orchestration**: systemd timers (7 timer/service pairs)
- **Deployment**: Ansible role `backup_client` (23 files)
- **Lines of code**: ~1,700 LOC across `src/backup-runner.sh` and `src/lib/*.sh`
- **Test coverage**: 85 test cases via BATS + ShellCheck

---

## 2. Design Principles

### The 3-2-1 Rule

Stowkeeper is built around the industry-standard 3-2-1 backup rule:

- **3 copies** of data: production, NAS backup, B2 backup.
- **2 different media**: local NAS (SFTP over LAN) and cloud object storage (HTTPS/S3).
- **1 off-site**: Backblaze B2 in a different geographic region.

### Client-Side Encryption

Encryption happens on the client before any data is transmitted. The NAS operator and Backblaze have zero access to plaintext content. Restic uses AES-256-CTR with Poly1305 authentication, and derives the key from a passphrase via scrypt.

### Independent Repositories, Not a Replica

The two repositories are completely independent. Each host runs `restic backup` twice — once per repo. This is a deliberate architectural choice. If the primary repo were replicated to the secondary via `rclone sync`, a ransomware infection or silent corruption on the primary would propagate to the secondary. With independent repos, each is a separate line of defense.

### Defense in Depth

Security is layered:

1. **B2 Object Lock** (30-day compliance retention) — prevents deletion of objects younger than 30 days, even with compromised credentials.
2. **ZFS read-only snapshots** on the NAS — daily snapshots of the Restic repository, retained 30 days.
3. **Write-only B2 application keys** on backup clients — clients can write but cannot delete or list buckets.
4. **Separate maintenance host** — destructive operations (`forget --prune`) run on an isolated host with time-bounded elevated credentials.

---

## 3. Component Architecture

### 3.1 backup-runner.sh — Central Orchestrator

File: `src/backup-runner.sh` (771 LOC)

This is the single entry point for every Restic operation on a backup host. It is a monolithic Bash script that centralizes authentication, locking, metrics capture, and notification logic. All systemd services invoke it; operators invoke it manually for restores.

#### Subcommands

| Subcommand | Purpose | Typical Invocation |
|---|---|---|
| `init` | Initialize Restic repository (`restic init`) | `backup-runner.sh init --repo nas` |
| `backup` | Run backup with lock, metrics, and alerts | `backup-runner.sh backup --job files` |
| `restore` | Restore snapshot to target path | `backup-runner.sh restore --snapshot abc123 --target /tmp/restore` |
| `snapshots` | List snapshots for a host | `backup-runner.sh snapshots --host server-a` |
| `check` | Verify repository integrity | `backup-runner.sh check [--with-prune] [--read-data]` |
| `digest` | Aggregate and send daily success digest | `backup-runner.sh digest` |
| `maintenance` | Weekly B2 forget+prune + check | `backup-runner.sh maintenance --with-prune` |

#### Dual-Repo Loop

The core execution pattern for `backup` and `check` is a sequential loop over `REPOS=("nas" "b2")`:

```
systemd timer -> backup-runner.sh backup --job files
    |
    v
acquire_lock (flock --timeout 60)
    |
    v
for repo in "${REPOS[@]}"; do
    configure_repo($repo)     # export RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE
    authenticate_repo($repo)  # Vault AppRole -> temp file, or env-file fallback
    run_backup($job)          # restic backup --host $HOSTNAME --tag $job
    track_backup_duration
    is_slow_backup? -> warning alert if >2x median
    handle_backup_result      # metrics + digest queue or alert
    _vault_cleanup_tempfile   # clear passphrase between repos
aggregate_exit_code
exit $OVERALL_EXIT_CODE
```

Exit codes are prioritized: `4` (auth) > `3` (config) > `1` (Restic error) > `75` (lock contention). If one repo fails, the other continues. The worst exit code is returned.

#### Lock Mechanism

`acquire_lock()` uses `flock` on a file descriptor opened against `/var/lock/stowkeeper-backup.lock` with a 60-second timeout. `flock` is kernel-managed and auto-releases on process death (even `SIGKILL`), preventing zombie locks. Exit code 75 signals contention to systemd, which may retry via timer configuration.

### 3.2 Library Modules

All libraries live in `src/lib/` and are sourced by `backup-runner.sh` and `stowkeeper-restore-test.sh`.

#### stowkeeper-metrics.sh

File: `src/lib/stowkeeper-metrics.sh` (288 LOC)

Prometheus metrics writer for the node_exporter textfile collector. Auto-detects the collector directory (`/var/lib/prometheus/node-exporter`, `/var/lib/node_exporter/textfile_collector`, or `/opt/prometheus/textfile`). Writes atomically via temp file + rename to prevent partial reads.

Functions:

- `emit_backup_metrics(host, job, repo, status, duration, size, files_new, last_success_ts)`
- `emit_check_metrics(repo, last_success_ts)`
- `emit_deep_check_metrics(repo, timestamp)` — monthly `--read-data-subset` verification
- `emit_repo_size_metrics(repo, size_bytes)` — for growth anomaly alerting
- `emit_restore_test_metrics(repo, success, files_checked, files_matched)`
- `emit_maintenance_metrics(repo, status, last_success_ts)`
- `track_backup_duration(duration)` — logs to rolling 30-entry history file
- `is_slow_backup(duration)` — returns true if current duration exceeds 2x historical median
- `read_deep_check_counter()` / `write_deep_check_counter(value)` — rotating 0-9 counter for monthly deep checks

#### stowkeeper-notify.sh

File: `src/lib/stowkeeper-notify.sh` (253 LOC)

Telegram notification library with deduplication and daily digest queue.

Functions:

- `send_telegram_message(text)` — POST to Telegram Bot API with Markdown parsing
- `send_alert(job, repo, type, message)` — deduplicated alert (4-hour window per job+type). On `failure`, also calls `send_email()`.
- `append_digest(job, repo, timestamp, duration, size)` — appends JSON line to `DIGEST_DIR/YYYY-MM-DD.json`
- `send_digest()` — reads all pending digest files, groups by repo, sends consolidated Telegram message at 08:00, deletes on success

Deduplication uses mtime of files in `/var/lib/stowkeeper/dedup/`. The 4-hour window prevents alert fatigue during sustained failures.

#### stowkeeper-email.sh

File: `src/lib/stowkeeper-email.sh` (214 LOC)

msmtp wrapper for email alerts. Email is used only for failures (not success digests), as a secondary channel and archival record.

Functions:

- `send_email(subject, body, [job], [repo])` — builds RFC-compliant message, invokes `msmtp -t`
- `_email_check_rate_limit()` — sliding window: max 10 emails per hour (configurable via `SMTP_RATE_LIMIT`)
- `_email_should_dedup(job, repo)` — 4-hour dedup window, independent of Telegram dedup
- `_email_record_send()` — appends timestamp to rate-limit log, trims to last 100 entries

Email is intentionally skipped if `SMTP_HOST` or `SMTP_TO` is unset, allowing deployments without email infrastructure.

#### stowkeeper-vault.sh

File: `src/lib/stowkeeper-vault.sh` (201 LOC)

HashiCorp Vault AppRole authentication with KV v2 passphrase retrieval and env-file fallback.

Functions:

- `vault_authenticate(repo_name)` — AppRole login (`/v1/auth/approle/login`), retrieves passphrase from `/v1/secret/data/stowkeeper/${repo}`, writes to temp file (mode 0600), sets `RESTIC_PASSWORD_FILE`. In-memory token cache with TTL awareness (reuses token if valid for >5 minutes). On any Vault failure, falls back to `RESTIC_PASSWORD_FILE_${repo}` from `pilot.conf`.
- `vault_cleanup()` — removes all tracked temp files; registered as EXIT trap
- `_vault_fallback(repo, password_file)` — sets env-file path and logs warning

Token caching is critical for dual-repo mode: without it, the second repo authentication would require a second Vault login, doubling latency and failure surface.

#### stowkeeper-restore-test.sh

File: `src/lib/stowkeeper-restore-test.sh` (238 LOC)

Standalone quarterly restore test. Sources the same libraries as `backup-runner.sh` but operates independently via its own systemd timer.

Flow:

1. Authenticate to repo (Vault or fallback)
2. Fetch latest snapshot ID (`restic snapshots --latest 1 --json`)
3. Disk space pre-flight (needs 2x repo size)
4. Restore snapshot to `/var/lib/stowkeeper/restore-test/`
5. Sample 20 random files (configurable via `SAMPLE_SIZE`)
6. Compare `sha256sum` of restored files against originals
7. Emit `stowkeeper_restore_test_success{files_checked,files_matched}` metrics
8. Send Telegram + email alert on failure; send Telegram success message on pass
9. `rm -rf` restore directory (trapped on EXIT)

### 3.3 systemd Timers — Scheduling

All timers live in `src/systemd/` and are deployed to `/etc/systemd/system/`.

| Timer | Schedule | Purpose | Service File |
|---|---|---|---|
| `stowkeeper-backup-db.timer` | `OnCalendar=hourly`, `RandomizedDelaySec=300` | Database dumps (PostgreSQL, MySQL) | `stowkeeper-backup-db.service` |
| `stowkeeper-backup-config.timer` | `OnCalendar=*-*-* 02:00:00`, `Persistent=true` | `/etc` and system configs | `stowkeeper-backup-config.service` |
| `stowkeeper-backup-files.timer` | `OnCalendar=*-*-* 03:00:00`, `RandomizedDelaySec=1800`, `Persistent=true` | General file system volumes | `stowkeeper-backup-files.service` |
| `stowkeeper-check.timer` | `OnCalendar=Sun *-*-* 04:00:00`, `Persistent=true` | Weekly integrity check (`restic check`) | `stowkeeper-check.service` |
| `stowkeeper-digest.timer` | `OnCalendar=*-*-* 08:00:00`, `Persistent=true` | Daily success digest aggregation | `stowkeeper-digest.service` |
| `stowkeeper-restore-test.timer` | `OnCalendar=*-01,04,07,10-01 05:00:00`, `Persistent=false` | Quarterly restore test | `stowkeeper-restore-test.service` |
| `stowkeeper-maintenance.timer` | `OnCalendar=Sun *-*-* 03:00:00`, `RandomizedDelaySec=3600`, `Persistent=true` | Weekly B2 forget+prune + check | `stowkeeper-maintenance.service` |

All services are `Type=oneshot` and source their environment from `EnvironmentFile=/opt/stowkeeper/conf/pilot.conf` (or `maintenance.conf` for the maintenance host). `Persistent=true` ensures catch-up execution if the system was powered off during the scheduled window. `RandomizedDelaySec` prevents I/O storms when multiple hosts share a NAS or network segment.

### 3.4 Ansible Role — Deployment Topology

File: `roles/backup_client/` (23 files)

The `backup_client` role replaces manual `install.sh` with idempotent, declarative deployment. It is the only supported method for multi-host fleets.

Task flow (`roles/backup_client/tasks/main.yml`):

```
1. validate.yml       — Assert required variables (repos, checksum, paths)
2. install_deps.yml   — Install curl, msmtp, jq, sqlite3, etc.
3. directories.yml    — Create /opt/stowkeeper, /var/lib/stowkeeper, etc.
4. install_restic.yml — Download from internal mirror with SHA256 verification
5. deploy_scripts.yml — Copy backup-runner.sh and lib/*.sh (static, unchanged)
6. deploy_configs.yml — Template pilot.conf.j2 and excludes.txt.j2 from host_vars
7. deploy_systemd.yml — Copy service/timer units, daemon-reload, enable timers
8. verify.yml         — Assert restic binary exists, timers are active
```

Key design decisions:

- **Only `pilot.conf` is templated** — all scripts are copied as-is. Systemd units reference `EnvironmentFile`, so per-host variance is expressed through the env file, not through templated services.
- **Secrets in `host_vars/` encrypted with ansible-vault** — Vault AppRole credentials are never plaintext in the repository.
- **Conditional timer enablement** — `stowkeeper-backup-db.timer` is enabled only when `stowkeeper_db_type` is defined.
- **Restic distributed from internal mirror** — no internet dependency during deployment. Checksum verification is mandatory; role fails if the mirror is unreachable or the checksum does not match.

---

## 4. Data Flow

### 4.1 Backup Flow

```
+---------------+     +---------------------+     +------------------+
| systemd timer | --> | backup-runner.sh    | --> | acquire_lock     |
+---------------+     |   backup --job X    |     +------------------+
                      +---------------------+              |
                              |                            v
                              v                     +-------------+
                     +----------------+             | pilot.conf  |
                     | for repo in    |             +-------------+
                     |   REPOS        |
                     +----------------+
                              |
              +---------------+---------------+
              |                               |
              v                               v
    +-------------------+           +-------------------+
    | configure_repo    |           | authenticate_repo |
    | (RESTIC_REPOSITORY|           | (Vault AppRole    |
    |  RESTIC_PASSWORD) |           |  or env-file)     |
    +-------------------+           +-------------------+
              |                               |
              v                               v
    +-------------------+           +-------------------+
    | restic backup     |           | restic backup     |
    | --host $HOSTNAME  |           | --host $HOSTNAME  |
    | --tag $job        |           | --tag $job        |
    +-------------------+           +-------------------+
              |                               |
              v                               v
    +-------------------+           +-------------------+
    | emit_backup_metrics|          | emit_backup_metrics|
    | append_digest      |          | append_digest      |
    +-------------------+           +-------------------+
              |                               |
              +---------------+---------------+
                              v
                     +----------------+
                     | aggregate_exit |
                     | release_lock   |
                     +----------------+
                              |
                              v
                     +----------------+
                     | exit code to   |
                     | systemd        |
                     +----------------+
```

The flow is sequential: NAS first, then B2. Each repo gets its own Vault authentication (with token caching for the second repo), its own metrics emission, and its own alert on failure. If NAS fails, B2 still runs.

### 4.2 Restore Flow

```
operator -> backup-runner.sh restore --snapshot <id> --target /tmp/restore
    |
    v
acquire_lock
load_config
configure_repo(REPOS[0])   # restores from primary repo by default
authenticate_repo(REPOS[0])
restic restore <id> --target /tmp/restore
send_alert (Telegram + email on failure)
release_lock
```

Restores are operator-initiated, not timer-driven. The default repo is `REPOS[0]` (typically NAS). For B2 restores, operators can temporarily override `REPOS` or run Restic directly with B2 credentials.

### 4.3 Notification Flow

```
backup result
    |
    +-- SUCCESS --> append_digest() --> /var/lib/stowkeeper/digest/YYYY-MM-DD.json
    |                    |
    |                    v
    |              stowkeeper-digest.timer (08:00)
    |                    |
    |                    v
    |              send_digest() --> Telegram (consolidated daily message)
    |
    +-- FAILURE --> should_dedup()? (4h window)
    |                    |
    |              NO --> send_telegram_message()
    |              NO --> send_email() (msmtp)
    |              YES -> skip (prevent alert fatigue)
    |
    +-- WARNING --> should_dedup()? (4h window)
                         |
                   NO --> send_telegram_message() only (no email)
```

Success notifications are batched into a single daily digest. Failure notifications are immediate, deduplicated, and sent via both Telegram and email. Warnings (e.g., slow backup) are Telegram-only.

### 4.4 Metrics Flow

```
backup-runner.sh
    |
    v
emit_backup_metrics() / emit_check_metrics()
    |
    v
write_metrics_file() -> /var/lib/prometheus/node-exporter/stowkeeper.prom
    |
    v
node_exporter (textfile collector)
    |
    v
Prometheus scrape
    |
    v
Alertmanager rules evaluation
    |
    +-- StaleBackup   (backup >30h old)  --> Telegram + email
    +-- StaleCheck    (check >10d old)   --> Telegram + email
    +-- GrowthAnomaly (repo >50% in 7d)  --> Telegram + email
```

Metrics are written atomically (temp file + rename) to prevent Prometheus from reading a partially written file. The `_merge_metrics()` helper in `stowkeeper-metrics.sh` preserves existing metric families when updating a subset, ensuring the `.prom` file always contains the full set.

---

## 5. Repository Topology

### Why Two Independent Repositories

A common pattern in backup architecture is to maintain one primary repository and replicate it to a secondary site. Stowkeeper explicitly rejects this pattern.

**If we used replication (e.g., `rclone sync`):**

- Ransomware encrypts the NAS repository.
- Replication job copies encrypted/corrupted data to B2.
- Both repositories are compromised.

**With independent repositories:**

- Ransomware encrypts the NAS repository.
- B2 repository remains intact because it is a separate Restic repo with separate keys, written independently.
- Recovery is possible from B2.

The tradeoff is double upload bandwidth. However, Restic's deduplication and incremental backup mean that after the initial seed, daily backups upload only changed blocks — typically a small fraction of total data volume.

### Repository Naming

Display names are normalized in `backup-runner.sh` line 29:

```bash
declare -A REPO_DISPLAY=([nas]="nas-primary" [b2]="b2-secondary")
```

All metrics, alerts, and digest entries use these display names as the `repo` label. This ensures consistency across Prometheus, Telegram, and email even if the internal alias changes.

---

## 6. Security Architecture

### Encryption

Restic handles all cryptography. Each repository is initialized with a passphrase that encrypts the master key. The encryption uses:

- **Algorithm**: AES-256-CTR with Poly1305 MAC (authenticated encryption)
- **Key derivation**: scrypt (memory-hard KDF)
- **Location**: client-side, before any network transmission

### Key Management

Each repository has two keys:

1. **Operational key** — per-host, stored in Vault KV v2 and injected via AppRole
2. **Emergency master key** — printed on paper, stored in a physical safe; not in any digital system

Passphrase requirements:

- Minimum 40 characters
- Generated with `openssl rand -base64 30`
- One passphrase per repository (NAS and B2 do not share passphrases)

### Append-Only Model

Backup clients use a B2 Application Key with `writeFiles` permission only — no `deleteFiles`, no `listBuckets`. This means a compromised backup client cannot:

- Delete snapshots
- Prune old data
- List other buckets

The `restic forget --prune` operation requires `deleteFiles`, which is only available on the **maintenance host**. The maintenance host:

- Runs `backup-runner.sh maintenance --with-prune` weekly
- Uses a separate `maintenance.conf` with elevated B2 credentials
- Is isolated from backup clients
- Only has elevated credentials during the maintenance window

### Defense Layers Summary

| Layer | Mechanism | Scope | Protects Against |
|---|---|---|---|
| 1 | B2 Object Lock (30-day compliance) | B2 repo | Deletion of objects < 30 days old |
| 2 | ZFS read-only snapshots | NAS repo | Filesystem-level immutability |
| 3 | Write-only B2 application keys | B2 access | Compromised client cannot delete data |
| 4 | Client-side encryption | All data | NAS/B2 operators cannot read content |
| 5 | Separate maintenance host | Prune operations | Elevated credentials isolated from clients |

### Threat Matrix

| Threat | Layer 1 | Layer 2 | Layer 3 | Layer 4 | Layer 5 |
|---|---|---|---|---|---|
| Ransomware deletes backups | Yes | Yes | Yes | — | Yes |
| Insider deletes snapshots | Yes | Yes | Yes | — | Yes |
| Compromised backup client | — | — | Yes | — | Yes |
| Accidental `restic forget` | Yes | Yes | Yes | — | Yes |
| Man-in-the-middle on upload | — | — | — | Yes | — |
| Cloud provider reads data | — | — | — | Yes | — |

---

## 7. Retention and Rotation

### GFS Policy

Stowkeeper applies a Grandfather-Father-Son (GFS) retention policy via `restic forget`:

```bash
RETENTION_POLICY="--keep-last 3
--keep-hourly 24
--keep-daily 14
--keep-weekly 8
--keep-monthly 12
--keep-yearly 5"
```

This produces, in steady state, approximately 60-65 snapshots per host. With Restic's deduplication, total repository size is typically 1.3x to 1.8x the size of the source data.

### Forget/Prune Cycle

- **Daily** (`backup-runner.sh digest`): `restic forget` without `--prune`. Marks snapshots for deletion but does not reclaim space. Fast.
- **Weekly** (`backup-runner.sh maintenance --with-prune`): `restic forget --prune` on B2. Reclaims space by repacking index and data files. Slow and I/O intensive.

The NAS repo is pruned less frequently (typically monthly) because local storage is cheaper and ZFS snapshots provide additional protection against accidental pruning.

### Deep Integrity Verification

Monthly, during the first week of the month, `backup-runner.sh check` evaluates whether to run a deep check:

```
day <= 7 AND counter == month % 10 ?
    YES -> restic check --read-data-subset=N0%
           emit_deep_check_metrics
           counter = (counter + 1) % 10
    NO  -> restic check (metadata only)
```

The 0-9 counter rotates through 10% subsets, covering 100% of repository data every 10 months without overwhelming network or disk I/O.

---

## 8. Observability

### Metrics Pipeline

All metrics are written to a `.prom` file consumed by node_exporter's textfile collector:

```
backup-runner.sh -> stowkeeper-metrics.sh -> /var/lib/prometheus/node-exporter/stowkeeper.prom
                                                      |
                                                      v
                                            node_exporter --collector.textfile.directory
                                                      |
                                                      v
                                            Prometheus (scrape every 15s)
                                                      |
                                                      v
                                            Alertmanager (rules evaluation)
```

### Metric Reference

| Metric | Type | Labels | Description |
|---|---|---|---|
| `stowkeeper_backup_last_success_timestamp` | gauge | `host`, `job`, `repo` | Unix timestamp of last successful backup |
| `stowkeeper_backup_duration_seconds` | gauge | `host`, `job`, `repo` | Wall-clock duration of last backup |
| `stowkeeper_backup_size_bytes` | gauge | `host`, `job`, `repo` | Size of last backup snapshot |
| `stowkeeper_backup_files_new` | gauge | `host`, `job`, `repo` | New files in last backup |
| `stowkeeper_backup_status` | gauge | `host`, `job`, `repo` | 1 = success, 0 = failure |
| `stowkeeper_check_last_success_timestamp` | gauge | `repo` | Last successful `restic check` |
| `stowkeeper_check_deep_success_timestamp` | gauge | `repo` | Last successful deep check |
| `stowkeeper_maintenance_status` | gauge | `repo` | Maintenance operation status |
| `stowkeeper_maintenance_last_success_timestamp` | gauge | `repo` | Last successful maintenance |
| `stowkeeper_repo_size_bytes` | gauge | `repo` | Total repository size |
| `stowkeeper_restore_test_success` | gauge | `repo` | 1 = pass, 0 = fail |
| `stowkeeper_restore_test_files_checked` | gauge | `repo` | Files sampled |
| `stowkeeper_restore_test_files_matched` | gauge | `repo` | Files with matching sha256sum |

### Alerting Rules

File: `monitoring/alertmanager/rules.yml`

| Alert | Expression | Severity | Channels |
|---|---|---|---|
| **StaleBackup** | `time() - backup_last_success_timestamp > 108000` (30h) | warning | Telegram |
| **StaleCheck** | `time() - check_last_success_timestamp > 864000` (10d) | warning | Telegram |
| **GrowthAnomaly** | `repo_size` grew >50% week-over-week | critical | Telegram + email |

Alerts fire after a 5-minute `for` period (15 minutes for GrowthAnomaly) to avoid flapping on transient issues.

### Dashboard

A starter Grafana dashboard is provided at `monitoring/grafana/stowkeeper-dashboard.json` with panels for:

- Backup success rate per repo
- Backup duration trends
- Repository size over time
- Check age (time since last check)
- Restore test results

---

## 9. Deployment Models

### Single Host (Manual)

For a single server or workstation:

```bash
git clone https://github.com/<org>/stowkeeper.git /opt/stowkeeper
cd /opt/stowkeeper
sudo bash install.sh
sudo cp src/configs/pilot.conf /opt/stowkeeper/conf/pilot.conf
sudo vim /opt/stowkeeper/conf/pilot.conf
sudo cp src/systemd/stowkeeper-*.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now stowkeeper-backup-files.timer
```

### Multi-Host (Ansible)

For fleets of servers and workstations:

```bash
vim inventory/hosts
vim inventory/host_vars/<host>.yml
ansible-vault encrypt_string --name 'vault_telegram_bot_token' 'your-token'
ansible-playbook playbooks/deploy-backup.yml
```

The role supports per-host variance through `host_vars/`:

- `stowkeeper_repos`: `["nas"]` or `["nas", "b2"]`
- `stowkeeper_db_type`: `"postgresql"`, `"mysql"`, or `""`
- `stowkeeper_backup_paths_files`: list of paths to back up
- Vault AppRole credentials (ansible-vault encrypted)

### Maintenance Host

The maintenance host is a dedicated VM (or physical machine) that runs only `stowkeeper-maintenance.timer`. It:

- Uses `src/configs/maintenance.conf` with elevated B2 credentials
- Runs `backup-runner.sh maintenance --with-prune` weekly
- Is isolated from backup clients (separate credentials, separate config)
- Should not run backup jobs — its sole purpose is prune and check on B2

---

## 10. Failure Modes and Recovery

### Component Failure Matrix

| Component | Failure Mode | Impact | Detection | Recovery |
|---|---|---|---|---|
| **backup-runner.sh** | Lock contention (exit 75) | Backup skipped for this cycle | systemd journal + metric absent >30h | Automatic retry on next timer fire |
| **backup-runner.sh** | Config error (exit 3) | Backup aborted | Immediate Telegram alert | Fix `pilot.conf`, re-run manually |
| **backup-runner.sh** | Auth error (exit 4) | One repo skipped | Immediate Telegram + email alert | Check Vault status or password file |
| **NAS** | Unreachable | NAS backup fails, B2 continues | Alert on NAS failure | Restore from B2; repair NAS |
| **Backblaze B2** | API outage | B2 backup fails, NAS continues | Alert on B2 failure | Restore from NAS; wait for B2 recovery |
| **Vault** | Unreachable | Falls back to env-file password | Warning logged to journal | Fix Vault; fallback keeps backups running |
| **systemd timer** | Disabled or missed | No backups | StaleBackup alert after 30h | `systemctl enable --now` the timer |
| **Restic repo** | Silent corruption | Data unrecoverable | `restic check` fails monthly | Restore from other repo; re-initialize |
| **Maintenance host** | Missed window | B2 repo grows unbounded | GrowthAnomaly alert | Run maintenance manually |
| **Telegram bot** | API error | No real-time alerts | Email still fires; digest queue grows | Check bot token; email is fallback |
| **msmtp/SMTP** | Relay failure | No email alerts | Telegram still fires | Check SMTP credentials |

### Restore Procedures

**Single file or directory:**

```bash
backup-runner.sh restore --snapshot abc123 --target /tmp/restore --path /etc/nginx/nginx.conf
```

**Full server recovery (bare metal):**

1. Boot from live ISO or rescue environment
2. Install Restic and restore the latest snapshot to a temp mount
3. Verify critical files with `sha256sum`
4. Partition, format, and copy data to new disk
5. Re-install bootloader, reconfigure network, reboot

**Database recovery:**

```bash
# Restore dump to temp directory
backup-runner.sh restore --snapshot abc123 --target /tmp/restore --path db-myapp.sql
# Verify, then apply to database
pg_restore -d myapp /tmp/restore/db-myapp.sql
```

Runbooks for specific scenarios are maintained separately from this architecture document.

---

## 11. Technology Choices

### Why Restic over BorgBackup

| Criterion | Restic | BorgBackup |
|---|---|---|
| Backend support | Native S3, B2, Azure, SFTP, REST, local | SFTP only (requires `rclone` for cloud) |
| Deployment | Single static binary (Go) | Python + C extension + dependencies |
| Multi-client repo | Safe concurrent writes | Risk of corruption under concurrency |
| Compression | Moderate (zstd) | Superior (lz4/zstd) |
| Network performance | Better on high-latency links | Better on low-latency LAN |

BorgBackup offers better compression and LAN performance, but Restic's native multi-backend support and multi-client safety are decisive for this architecture. The ability to write directly to Backblaze B2 without `rclone` simplifies deployment and reduces moving parts.

### Why Bash (with a Go Migration Path)

**Current rationale:**

- Bash is universally available on Linux systems without additional runtime installation.
- The initial scope (single host, single repo) fit comfortably in a monolithic script.
- Systemd integration, file operations, and process orchestration are natural in shell.
- ShellCheck and BATS provide adequate static analysis and test coverage for the current complexity.

**Migration path:**

If the system grows beyond its current scope — for example, adding a configuration API, a TUI, or complex concurrency — the wrapper will be rewritten in Go. This is documented as a roadmap item. Go was chosen as the future language because Restic itself is Go, enabling shared libraries and consistent deployment artifacts.

### Why systemd over cron

| Feature | systemd timers | cron |
|---|---|---|
| Logging | Native journald integration | Syslog only, no structured logs |
| Catch-up on boot | `Persistent=true` | No built-in support |
| Dependency management | `After=network.target`, etc. | Manual ordering with sleep hacks |
| Randomization | `RandomizedDelaySec` | Requires external tooling |
| Failure handling | `OnFailure=` unit triggers | No native notification |
| Status inspection | `systemctl list-timers` | `crontab -l` only |

systemd timers provide observability and reliability features that cron cannot match, particularly `Persistent=true` for laptops and workstations that are not powered on 24/7.

### Why Backblaze B2 over AWS S3

| Criterion | Backblaze B2 | AWS S3 |
|---|---|---|
| Storage cost | ~$6/TB/month | ~$23/TB/month |
| Egress cost | Free up to 3x stored/month | $0.09/GB |
| API | S3-compatible | Native S3 |
| Object Lock | Compliance mode supported | Compliance mode supported |
| Minimum retention | None | None |

AWS S3 offers richer ecosystem integration and cross-region replication, but for a backup-only use case with occasional restores, Backblaze B2 is 3-4x cheaper with equivalent durability (11 nines). Wasabi was evaluated but rejected due to its 90-day minimum retention policy, which penalizes frequent rotation.

---

## Appendix A: File Reference

| File | Purpose |
|---|---|
| `src/backup-runner.sh` | Central orchestrator (771 LOC) |
| `src/lib/stowkeeper-metrics.sh` | Prometheus metrics library (288 LOC) |
| `src/lib/stowkeeper-notify.sh` | Telegram alerts and digest queue (253 LOC) |
| `src/lib/stowkeeper-email.sh` | msmtp email wrapper with rate limiting (214 LOC) |
| `src/lib/stowkeeper-vault.sh` | Vault AppRole auth with fallback (201 LOC) |
| `src/lib/stowkeeper-restore-test.sh` | Quarterly restore test (238 LOC) |
| `src/configs/pilot.conf` | Host configuration template |
| `src/configs/maintenance.conf` | Elevated maintenance host config |
| `src/systemd/stowkeeper-*.timer` | 7 systemd timer definitions |
| `src/systemd/stowkeeper-*.service` | 7 corresponding service definitions |
| `roles/backup_client/` | Ansible role for multi-host deployment |
| `monitoring/alertmanager/rules.yml` | Prometheus alerting rules |
| `monitoring/grafana/stowkeeper-dashboard.json` | Starter Grafana dashboard |
| `RDP-Stowkeeper.md` | Project decision record (original, in Spanish) |

---

## Appendix B: Glossary

| Term | Definition |
|---|---|
| **3-2-1 rule** | Three copies of data, on two different media, with one off-site. |
| **Append-only** | Repository mode where new data can be written but old data cannot be deleted. |
| **Deep check** | `restic check --read-data-subset`, which reads and verifies a percentage of actual data blocks. |
| **Digest** | Daily consolidated notification of all successful backups, sent at 08:00. |
| **GFS** | Grandfather-Father-Son retention policy: keep hourly, daily, weekly, monthly, and yearly snapshots. |
| **Object Lock** | Backblaze B2 feature that enforces retention periods, preventing deletion even with valid credentials. |
| **RPO** | Recovery Point Objective — maximum acceptable data loss window. |
| **RTO** | Recovery Time Objective — maximum acceptable downtime for restoration. |
