<!--
  README.md — Stowkeeper
  Replace placeholder URLs (GitHub org/repo, shields, etc.) after pushing to remote.
-->

<p align="center">
  <img src="stowkeeperv2-min.png" alt="Stowkeeper" width="200" />
</p>

<h1 align="center">Stowkeeper</h1>

<p align="center">
  <strong>End-to-end encrypted backup system with smart rotation,<br>integrity verification, and multi-channel notifications.</strong>
</p>

<p align="center">
  <a href="#"><img src="https://img.shields.io/badge/version-1.0-blue" alt="Version" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License" /></a>
  <a href="#"><img src="https://img.shields.io/badge/shellcheck-clean-brightgreen" alt="ShellCheck" /></a>
  <a href="#"><img src="https://img.shields.io/badge/specs-100%25-brightgreen" alt="Spec coverage" /></a>
</p>

---

## Table of Contents

- [Description](#description)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Configuration](#configuration)
- [Commands Reference](#commands-reference)
- [Monitoring](#monitoring)
- [Security Model](#security-model)
- [Project Structure](#project-structure)
- [Testing](#testing)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Description

Stowkeeper is a **reproducible, code-driven backup pipeline** designed for Linux servers and
workstations. It follows the **3-2-1 backup rule** — three copies, two different media, one
off-site — by maintaining two fully independent Restic repositories: a local NAS (SFTP) and
Backblaze B2 (S3-compatible object storage).

Every backup is **encrypted client-side** with AES-256 before it leaves the host, so neither
the NAS operator nor the cloud provider can read your data. Repositories are hardened against
ransomware with append-only keys, Object Lock, and ZFS snapshots.

Stowkeeper is **not a SaaS**. It is a set of Bash scripts, systemd timers, and Ansible roles
that run on your own infrastructure. You control the keys, the schedule, and the retention
policy.

**Who is this for?** Sysadmins, DevOps engineers, and SREs who need a reliable, auditable
backup pipeline for Linux fleets (physical servers, VMs, workstations) without vendor lock-in.

---

## Features

- **End-to-end encryption** — AES-256-CTR + Poly1305 via Restic; encryption happens on
  the client before any data leaves the host
- **Dual independent repositories** — local NAS (SFTP) + cloud (Backblaze B2); no shared
  failure domain
- **Vault-backed secrets** — HashiCorp Vault AppRole auth with automatic passphrase
  retrieval and env-file fallback for resilience
- **Ransomware hardening** — append-only B2 keys, Object Lock (30-day compliance), and
  ZFS read-only snapshots on NAS
- **Smart scheduling** — systemd timers with `RandomizedDelaySec`, `Persistent=true`
  catch-up, and staggered execution to avoid I/O storms
- **Prometheus observability** — per-repo metrics exported via node_exporter textfile
  collector; Alertmanager rules for stale backups, missed checks, and abnormal growth
- **Multi-channel notifications** — Telegram for all alerts + daily success digest;
  email (msmtp) for failure alerts with deduplication and rate limiting
- **GFS retention** — Grandfather-Father-Son policy (`restic forget`) with daily mark +
  weekly prune
- **Deep integrity checks** — monthly rotating `restic check --read-data-subset=10%`
  covering 100% of data every 10 months
- **Automated restore testing** — quarterly full restore to temp dir with sha256sum
  comparison; alerts on mismatch
- **Ansible role** — one-command deployment to entire fleets; `host_vars` for per-host
  backup paths, DB types, and exclusions

---

## Architecture

```
                      ┌──────────────────────┐
                      │   Vault (secrets)    │
                      └──────────┬───────────┘
                                 │ AppRole
                                 │
   ┌──────────┐  ┌──────────┐    │   ┌──────────┐
   │ Server A │  │ Server B │    │   │  WS X    │
   │ (Restic) │  │ (Restic) │ ◄──┘   │ (Restic) │
   └────┬─────┘  └────┬─────┘        └────┬─────┘
        │ SFTP        │                    │ HTTPS (S3)
        ▼             ▼                    ▼
    ┌────────────────────┐         ┌──────────────────┐
    │   NAS (ZFS)        │         │  Backblaze B2    │
    │   Primary repo     │         │  Secondary repo  │
    │   + ZFS snapshots  │         │  + Object Lock   │
    └────────────────────┘         └──────────────────┘

        ┌───────────────────────────────────────────┐
        │ backup-runner.sh → Telegram + email        │
        │                  → Prometheus metrics      │
        └───────────────────────────────────────────┘
```

**Key design decisions:**
- **Two independent repos, not a replica** — prevents corruption propagation
- **Sequential dual-repo backup** — one repo at a time to avoid resource contention
- **Separate maintenance host** — destructive operations (`forget --prune`) run on an
  isolated host with time-bounded elevated credentials
- **Monolithic Bash wrapper** — single entry point (`backup-runner.sh`) centralizes auth,
  locking, metrics, and notifications

---

## Prerequisites

### On each backup host

| Dependency | Minimum Version | Purpose |
|-----------|----------------|---------|
| Bash | 4.3+ | Required for associative arrays and `local -n` |
| Restic | 0.17+ | Backup engine |
| systemd | 245+ | Timer orchestration |
| curl | any | Vault API and Telegram API calls |
| msmtp | 1.8+ | Email relay (optional; only for email alerts) |
| OpenSSH client | any | SFTP connectivity to NAS |

### Optional infrastructure

| Component | Purpose |
|-----------|---------|
| HashiCorp Vault | Secrets management (passphrases via AppRole) |
| Prometheus + node_exporter | Metrics collection |
| Alertmanager | Alert routing |
| Ansible 2.12+ | Multi-host deployment (control node only) |

---

## Installation

### Option A — Manual (single host)

```bash
# 1. Clone the repository
git clone https://github.com/<org>/stowkeeper.git /opt/stowkeeper

# 2. Run the installer (creates directories + permissions)
cd /opt/stowkeeper
sudo bash install.sh

# 3. Edit your host configuration
sudo cp src/configs/pilot.conf /opt/stowkeeper/conf/pilot.conf
sudo vim /opt/stowkeeper/conf/pilot.conf

# 4. Deploy systemd units
sudo cp src/systemd/stowkeeper-*.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now stowkeeper-backup-config.timer
sudo systemctl enable --now stowkeeper-backup-files.timer
sudo systemctl enable --now stowkeeper-check.timer
sudo systemctl enable --now stowkeeper-digest.timer
```

### Option B — Ansible (multi-host)

```bash
# 1. Edit your inventory
vim inventory/hosts
vim inventory/host_vars/<your-host>.yml

# 2. Encrypt secrets with ansible-vault
ansible-vault encrypt_string --name 'vault_telegram_bot_token' 'your-token'

# 3. Deploy
ansible-playbook playbooks/deploy-backup.yml
```

See [`roles/backup_client/README.md`](roles/backup_client/README.md) for all role variables.

---

## Quick Start

```bash
# Initialize repositories (NAS and B2)
backup-runner.sh init --repo nas
backup-runner.sh init --repo b2

# Run a file backup against both repos
backup-runner.sh backup --job files

# Check repository integrity
backup-runner.sh check

# List snapshots
backup-runner.sh snapshots

# Restore a specific snapshot
backup-runner.sh restore --snapshot abc123 --target /tmp/restore

# Send daily success digest
backup-runner.sh digest
```

---

## Usage

### Backup types

| Job | What it backs up | Typical schedule |
|-----|-----------------|------------------|
| `files` | Paths from `backup-paths.conf` | Daily 03:00 |
| `config` | `/etc` and system configs | Daily 02:00 |
| `db` | PostgreSQL / MySQL / SQLite dumps | Hourly |

```bash
# Database backup with PostgreSQL
# Set DB_TYPE=postgresql DB_NAME=myapp in pilot.conf
backup-runner.sh backup --job db
```

### Dual-repo mode

When `REPOS=("nas" "b2")` is set, every backup runs sequentially against both
repositories. If one repo fails, the other continues — a single repo failure
does not block the other.

```bash
# Set in pilot.conf:
REPOS=("nas" "b2")
```

### Deep integrity check

```bash
# Manual deep check (reads 10% of data)
backup-runner.sh check --read-data
```

The `--read-data` flag triggers automatically once per month via the systemd timer,
rotating a 0–9 counter to cover 100% of the repository over 10 months.

### Restore test

```bash
# Manual restore test
/opt/stowkeeper/bin/stowkeeper-restore-test.sh
```

Runs automatically every quarter (first Sunday of Jan/Apr/Jul/Oct at 05:00).
Restores the latest snapshot to a temp directory, samples 20 random files,
compares sha256sums, and reports results via Telegram + email.

---

## Configuration

All configuration lives in `/opt/stowkeeper/conf/pilot.conf`. Here are the
essential variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `REPOS` | Yes | Array of repos: `("nas")` or `("nas" "b2")` |
| `RESTIC_REPOSITORY_nas` | If nas in REPOS | SFTP path: `sftp:user@nas-host:/backup/stowkeeper` |
| `RESTIC_PASSWORD_FILE_nas` | Yes | Path to NAS passphrase file |
| `RESTIC_REPOSITORY_b2` | If b2 in REPOS | S3 URL: `s3:s3.us-west-004.backblazeb2.com/bucket-name` |
| `B2_ACCOUNT_ID` | If b2 in REPOS | Backblaze B2 application key ID |
| `B2_ACCOUNT_KEY` | If b2 in REPOS | Backblaze B2 application key (write-only) |
| `VAULT_ADDR` | No | Vault server URL (e.g., `https://vault.internal:8200`) |
| `VAULT_ROLE_ID` | No | Vault AppRole role_id |
| `VAULT_SECRET_ID` | No | Vault AppRole secret_id |
| `TELEGRAM_BOT_TOKEN` | No | Telegram bot token for notifications |
| `TELEGRAM_CHAT_ID` | No | Telegram chat ID for alerts |
| `DB_TYPE` | No | `postgresql`, `mysql`, or empty |
| `DB_NAME` | If DB_TYPE set | Database name to dump |
| `RETENTION_POLICY` | No | Flags for `restic forget` (defaults to GFS policy) |
| `SMTP_HOST` | No | SMTP relay for email alerts |

See [`src/configs/pilot.conf`](src/configs/pilot.conf) for a fully annotated template.

---

## Commands Reference

```
backup-runner.sh <command> [options]

Commands:
  init         [--repo <nas|b2>]       Initialize Restic repository
  backup       --job <db|files|config>  Run backup with lock, metrics, and alerts
  restore      --snapshot <id>          Restore snapshot to target path
               --target <path>
               [--path <subpath>]
  snapshots    [--host <hostname>]     List snapshots
  check        [--with-prune]          Verify repository integrity
               [--read-data]            (optionally prune first, optionally read data)
  digest                               Aggregate and send success notifications
  maintenance  [--with-prune]          Weekly B2 forget+prune + check (maintenance host only)
```

---

## Monitoring

### Prometheus metrics

Written to the node_exporter textfile collector directory (auto-detected):

| Metric | Labels | Description |
|--------|--------|-------------|
| `stowkeeper_backup_last_success_timestamp` | `{repo}` | Unix timestamp of last successful backup |
| `stowkeeper_backup_duration_seconds` | `{repo}` | Duration of last backup |
| `stowkeeper_backup_size_bytes` | `{repo}` | Size of last backup |
| `stowkeeper_backup_files_new` | `{repo}` | New files in last backup |
| `stowkeeper_check_last_success_timestamp` | `{repo}` | Last successful check |
| `stowkeeper_check_deep_success_timestamp` | `{repo}` | Last successful deep check |
| `stowkeeper_maintenance_status` | `{repo}` | Maintenance operation status |
| `stowkeeper_repo_size_bytes` | `{repo}` | Total repository size |
| `stowkeeper_restore_test_success` | `{repo}` | Restore test result (1=pass, 0=fail) |

### Alertmanager rules

Defined in [`monitoring/alertmanager/rules.yml`](monitoring/alertmanager/rules.yml):

- **StaleBackup** — last backup > 30 hours (critical)
- **StaleCheck** — last check > 10 days (warning)
- **GrowthAnomaly** — repo grew > 50% in one week (warning)

Alerts route to Telegram + email channels configured in Alertmanager.

### Grafana dashboard

A starter dashboard template is available at
[`monitoring/grafana/stowkeeper-dashboard.json`](monitoring/grafana/stowkeeper-dashboard.json).

---

## Security Model

### Defense in depth

| Layer | Mechanism | Scope | Protects against |
|-------|-----------|-------|-----------------|
| 1 | B2 Object Lock (30-day compliance) | B2 repo | Deletion of objects < 30 days old |
| 2 | ZFS read-only snapshots | NAS repo | Filesystem-level immutability |
| 3 | Write-only B2 application keys | B2 access | Compromised client cannot delete data |

### Key separation

- **Backup clients** use a B2 key with `writeFiles` only — no delete, no list
- **Maintenance host** holds a separate elevated key with `deleteFiles`, used only
  during the weekly maintenance window
- **Vault AppRole** credentials have a short TTL (1 hour) and are host-specific

### Threat matrix

| Threat | Layer 1 | Layer 2 | Layer 3 |
|--------|:-------:|:-------:|:-------:|
| Ransomware deletes backups | Yes | Yes | Yes |
| Insider deletes snapshots | Yes | Yes | Yes |
| Compromised backup client | — | — | Yes |
| Accidental `restic forget` | Yes | Yes | Yes |

---

## Project Structure

```
stowkeeper/
├── src/
│   ├── backup-runner.sh              # Central wrapper (771 LOC)
│   ├── lib/
│   │   ├── stowkeeper-metrics.sh     # Prometheus + deep check metrics (288 LOC)
│   │   ├── stowkeeper-notify.sh      # Telegram + digest (253 LOC)
│   │   ├── stowkeeper-email.sh       # msmtp + rate limit (214 LOC)
│   │   ├── stowkeeper-restore-test.sh# Quarterly restore test (238 LOC)
│   │   └── stowkeeper-vault.sh       # Vault AppRole auth (201 LOC)
│   ├── configs/
│   │   ├── pilot.conf                # Host configuration template
│   │   └── maintenance.conf          # Elevated maintenance host config
│   └── systemd/                      # 7 timer/service pairs
├── roles/backup_client/              # Ansible role (23 files)
├── playbooks/deploy-backup.yml       # Main playbook
├── inventory/                        # Example inventory + host_vars
├── monitoring/
│   ├── alertmanager/rules.yml        # Prometheus alerting rules
│   ├── grafana/dashboard.json        # Starter dashboard
│   └── README.md                     # Metrics reference
├── tests/
│   ├── backup-runner.bats            # Phase 1 unit tests (114 LOC)
│   └── phase2.bats                   # Phase 2 unit + stub tests (818 LOC)
├── install.sh                        # Manual installer
├── openspec/                         # Spec-driven development artifacts
│   ├── specs/                        # 16 spec domains
│   └── changes/archive/              # 4 archived phases
└── RDP-Stowkeeper.md                 # Project decision record
```

---

## Testing

```bash
# Run unit tests (requires bats)
bats tests/backup-runner.bats
bats tests/phase2.bats

# Lint all scripts (requires shellcheck)
shellcheck -x src/backup-runner.sh src/lib/*.sh install.sh
```

The test suite covers 85 test cases across core behaviors: lock management,
metrics emission, deduplication, config validation, notification routing,
Vault auth, email rate limiting, and dual-repo loops. Integration tests
require a real Restic binary and are documented as skipped stubs.

---

## Roadmap

- [x] Phase 1 — Core backup pipeline (NAS, wrapper, timers, Telegram)
- [x] Phase 2 — Off-site + Vault (B2, AppRole auth, append-only, email, maintenance)
- [x] Phase 3 — Ansible multi-host deployment
- [x] Phase 4 — Observability (Alertmanager, deep check, restore testing, Grafana)
- [ ] Third offline copy (LTO tape / rotational disk) for legal retention > 5 years
- [ ] Go rewrite of `backup-runner.sh` for improved robustness
- [ ] `resticprofile` evaluation as a declarative configuration layer

Track progress in [GitHub Issues](https://github.com/<org>/stowkeeper/issues).

---

## Contributing

Contributions are welcome. Please follow these steps:

1. **Fork** the repository
2. **Create a worktree** off `main` (this project uses main + worktrees, not git flow)
3. Make your changes, following the existing code style and ShellCheck conventions
4. Add tests for new functionality
5. Run `bash -n` and `shellcheck` on all modified `.sh` files
6. Submit a **Pull Request** with a clear description and linked issue

### Commit conventions

This project follows [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` — new feature
- `fix:` — bug fix
- `docs:` — documentation
- `refactor:` — code restructuring

### Spec-driven development

All substantial changes go through the [SDD workflow](openspec/):
1. **Proposal** → defines intent, scope, and approach
2. **Design** → architecture decisions and sequence diagrams
3. **Specs** → Given/When/Then scenarios with RFC 2119 keywords
4. **Tasks** → implementation checklist
5. **Apply** → code changes
6. **Verify** → spec compliance validation
7. **Archive** → delta sync to main specs

---

## License

[MIT](LICENSE) © 2026 Stowkeeper

---

## Acknowledgments

- [Restic](https://restic.net/) — the backup engine that makes this possible
- [Backblaze B2](https://www.backblaze.com/b2/) — affordable S3-compatible storage
- [HashiCorp Vault](https://www.vaultproject.io/) — secrets management
- The **3-2-1 backup rule**, originally formulated by Peter Krogh
- All [contributors](https://github.com/<org>/stowkeeper/graphs/contributors)

---

<p align="center">
  <sub>Built for people who care about their data.</sub>
</p>
