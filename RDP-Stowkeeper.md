# RDP — Project Stowkeeper

**Encrypted Backup System with Rotation and Notifications**

**Document:** Project Decision Record (RDP)
**Version:** 1.0
**Date:** May 2, 2026
**Status:** Approved for implementation

---

## 1. Executive summary

Design and implementation of an automated, end-to-end encrypted backup system with intelligent rotation, periodic integrity verification, and multi-channel notifications (Telegram + email). The system covers Linux servers (physical and virtual) and workstations, with local storage (NAS) and off-site remote replication.

The goal is to have a reproducible solution through code (IaC), with low operational cost, resistant to ransomware (thanks to append-only repositories), and with sufficient observability to detect failures before they become data loss.

---

## 2. Objectives and scope

### 2.1 Objectives

The system pursues three primary objectives. First, **guarantee recoverability** of critical data complying with the 3-2-1 rule (three copies, two different media, one off-site). Second, **minimize the exposure window** to data loss by maintaining a maximum RPO of 24 hours for general data and 1 hour for databases. Third, **proactively detect** any silent degradation of the repository through automatic integrity checks.

### 2.2 Target RPO and RTO

| Data category | RPO | RTO |
|---|---|---|
| Transactional databases | 1 hour | 2 hours |
| General filesystems | 24 hours | 4 hours |
| Configurations (`/etc`) | 24 hours | 1 hour |
| User data (workstations) | 24 hours | 8 hours |

### 2.3 Out of scope

Backups of third-party SaaS applications (Microsoft 365, Google Workspace), which require specific tools, as well as synchronous database replication in high availability, are out of scope for this project, as the latter is a complementary but distinct mechanism from backup.

---

## 3. Design decisions

This section documents the technical decisions made, with their justification and the alternatives discarded.

### 3.1 Backup engine: **Restic**

**Restic** is chosen over BorgBackup for the following reasons:

- **Native support for multiple backends**: S3, B2, Azure Blob, SFTP, REST, and local filesystem without needing additional tools like `rclone`. BorgBackup requires SSH or a dedicated Borg server, which limits flexibility for off-site storage in object storage.
- **Single binary in Go, no dependencies**: simplifies deployment on heterogeneous clients.
- **Multi-client repository**: multiple hosts can write to the same Restic repository with cross-deduplication, something that Borg only supports in a limited way and with corruption risk if there is concurrency.
- **Active ecosystem and mature documentation**.

BorgBackup offers slightly superior compression and better performance on low-latency networks, but the backend flexibility and multi-client deduplication of Restic weigh more in this project.

### 3.2 Repository topology: **two independent repositories**

**Two completely independent repositories** are maintained, not a replica of one to the other:

1. **Primary repository**: Local NAS accessible via SFTP/NFS on the LAN.
2. **Secondary repository**: Backblaze B2 (off-site object storage).

Each client runs two backups, one against each repository. This decision is deliberate: if the primary repository were replicated to the secondary (for example with `rclone sync`), corruption or ransomware encryption of the primary would propagate to the secondary. With two independent repositories, each one is an autonomous line of defense.

The additional cost (double upload of data) is compensated by Restic's deduplication, which in incremental backups reduces actual traffic to a small percentage of changes.

### 3.3 Off-site storage: **Backblaze B2**

**Backblaze B2** is chosen as the off-site destination for its price (≈6 USD/TB/month in storage, with no egress cost up to 3× the stored amount per month), its S3-compatible API, and its proven reliability. AWS S3 and Azure Blob offer similar functionality but at 3-4 times the cost for this use case. Wasabi would be a valid alternative but its minimum retention policy of 90 days penalizes frequent rotation.

### 3.4 Encryption: **AES-256 native to Restic with derived passphrase**

Encryption is entirely delegated to the Restic engine, which applies AES-256 in CTR mode with Poly1305 authentication and derives the key from a passphrase using scrypt. **Encryption occurs on the client before any transmission**, which means that the operator of the NAS or Backblaze never has access to the plaintext content.

#### Passphrase management

- Each repository has its own passphrase of **at least 40 random characters** generated with `openssl rand -base64 30`.
- Passphrases are stored in **HashiCorp Vault** (self-hosted instance) and injected into clients via AppRole with short TTL.
- There is a **printed paper copy** of each passphrase kept in a physical safe, as a last resort in case of total loss of Vault.
- Restic allows multiple keys per repository: one operational key per host and one emergency ("master") key kept only on paper are maintained.

### 3.5 Retention and rotation policy

A **GFS (Grandfather-Father-Son)** policy, slightly adapted, is applied, managed by `restic forget` with the following flags:

```
--keep-last 3
--keep-hourly 24
--keep-daily 14
--keep-weekly 8
--keep-monthly 12
--keep-yearly 5
```

This produces, in steady state, around 60-65 retained snapshots per host, which with Restic's deduplication typically amounts to between 1.3× and 1.8× the size of production data. The 5-year annual retention covers typical audit requirements; if the regulatory context (healthcare, financial) requires more, it will be adjusted per host.

The `restic forget` command is run with `--prune` only once per week (expensive operation), and on other days it only marks snapshots without freeing space.

### 3.6 Execution frequency

| Data type | Frequency | Mechanism |
|---|---|---|
| Databases (PostgreSQL, MySQL) | Every hour | systemd timer + pre-backup dump |
| `/etc` and configurations | Daily at 02:00 | systemd timer |
| General data volumes | Daily at 03:00 | systemd timer |
| Workstations | When connecting to corporate network, max 1×/day | systemd path unit |
| `restic check` verification | Weekly (Sunday 04:00) | systemd timer |
| Deep verification (`--read-data`) | Monthly | systemd timer |

**systemd timers** are chosen over cron because they offer better logging (journald), dependency management, deferred execution if the system was off (`Persistent=true`), and randomization to avoid I/O storms (`RandomizedDelaySec`).

### 3.7 Consistent database backup

Databases are not backed up by copying files from the datadir directly. Instead:

- **PostgreSQL**: `pg_dump` with custom format (`-Fc`) per database, plus weekly `pg_basebackup` for a complete binary copy with WAL.
- **MySQL/MariaDB**: `mariabackup` (consistent snapshot without blocking) or `mysqldump --single-transaction` for small databases.
- **SQLite**: `sqlite3 .backup` to guarantee consistency.

Dumps are written to a temporary directory, Restic backs them up, and they are deleted afterwards. For large volumes (>100 GB), the use of **stdin to Restic** (`pg_dump | restic backup --stdin`) is considered to avoid double storage.

### 3.8 Integrity verification

Verification operates at three levels:

1. **Daily**: `restic backup` itself validates the uploaded chunks.
2. **Weekly**: `restic check` (without `--read-data`) verifies the repository structure and index consistency. It is fast.
3. **Monthly**: `restic check --read-data-subset=10%` reads and verifies 10% of the data, rotating the subset each month, which covers 100% of the repository in 10 months without overloading the network.

Once per quarter an **automated real restoration test** is executed: a snapshot is restored to a temporary directory, a subset of files is compared with `sha256sum` against the originals, and the result is notified. A backup never verified by restoration is not a backup.

### 3.9 Notifications: **Telegram + email via wrapper script**

Notifications are managed with a **Bash wrapper script** (`backup-runner.sh`) that wraps each Restic execution, captures exit code, duration, size, and stderr, and emits the notification through the configured channels.

#### Channels

- **Telegram (primary channel)**: using a dedicated bot and a private operations group. Allows emojis, Markdown formatting, and quick response from mobile.
- **Email (secondary channel, fallback, and archive)**: via `msmtp` with authenticated relay to a corporate SMTP or to a service like Postmark/Amazon SES.

#### Notification policy

To avoid **alert fatigue**:

- **Successes**: only a consolidated daily summary at 08:00 is notified (not every job).
- **Failures**: immediate notification via Telegram **and** email.
- **Warnings** (e.g., backup that took >2× its median): notification via Telegram only.
- **Failed verifications**: highest priority alert, with ping to on-call operator.

The script implements **alert deduplication** (do not send the same alert more than once every 4 hours) and **circuit breaker** (if 5 jobs fail in a row, escalate to phone call via PagerDuty/OpsGenie).

### 3.10 Hardening against ransomware

- **Append-only on Backblaze B2**: the client uses an Application Key with `write` permissions but not `delete`. Rotation with `restic forget --prune` is executed from a separate management host with different credentials, which are only activated during the weekly maintenance window.
- **Object Lock** on B2 with 30-day retention on the bucket: even compromised credentials cannot delete objects during that period.
- **NAS repository on ZFS filesystem with snapshots**: the NAS takes a daily read-only ZFS snapshot of the Restic repository, retained for 30 days. This creates an additional layer of protection even if client credentials were compromised.

### 3.11 Deployment and configuration

System configuration is managed via **Ansible**:

- A `backup_client` role that installs Restic, deploys the wrapper, configures systemd timers, integrates with Vault, and registers the host.
- Per-host variables in `host_vars/` with the list of paths to back up and exceptions.
- The Restic binary is distributed from an internal mirror with its checksum verified, not downloaded from the internet on each execution.

---

## 4. Architecture

### 4.1 Logical diagram

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
         │             │                    │
         │ SFTP        │                    │ HTTPS
         ▼             ▼                    ▼
     ┌────────────────────┐         ┌──────────────────┐
     │   NAS (ZFS)        │         │  Backblaze B2    │
     │   Primary repo     │         │  Secondary repo  │
     │   + ZFS snapshots  │         │  + Object Lock   │
     └────────────────────┘         └──────────────────┘

         ┌───────────────────────────────────────────┐
         │ backup-runner.sh → Telegram + email        │
         └───────────────────────────────────────────┘
```

### 4.2 Components

The **`backup-runner.sh` wrapper** is the single entry point for any Restic execution. It centralizes authentication with Vault, lock handling (lockfile at `/var/lock/backup-runner.lock` to avoid overlaps), metric capture, notification logic, and structured logging in journald with tags to facilitate subsequent queries.

The **maintenance host** is a dedicated machine (can be a small VM) that weekly runs destructive operations (`forget --prune`) and integrity verification. It is isolated from clients and only has elevated-permission credentials during the maintenance window.

---

## 5. Operations

### 5.1 Restoration procedure

Documented in separate runbook, but at a high level:

1. Identify the desired snapshot: `restic snapshots --host <hostname>`.
2. Restore to temporary directory: `restic restore <id> --target /tmp/restore`.
3. Validate content before overwriting originals.
4. Move/copy to final destination.

Specific runbooks are maintained for concrete scenarios (database recovery, bare-metal recovery, selective file recovery).

### 5.2 Quarterly tests

Each quarter, the operations team performs a DR exercise where:

- A complete server is restored to an isolated environment from backups only.
- The actual RTO obtained is measured and compared against the target.
- Incidents are documented and documentation is updated.

### 5.3 Metrics and observability

The wrapper exports metrics to a Prometheus endpoint (`textfile collector` of node_exporter):

- `backup_last_success_timestamp{host, repo}`
- `backup_duration_seconds{host, repo}`
- `backup_size_bytes{host, repo}`
- `backup_files_new{host, repo}`
- `backup_check_last_success_timestamp{repo}`

Alerts are built on these metrics in Alertmanager: backup older than 30 hours, verification older than 10 days, abnormal repository growth (>50% in one week).

---

## 6. Estimated cost

For a reference volume of **2 TB of production data** with a typical deduplication factor of 1.5×:

| Item | Monthly cost |
|---|---|
| Backblaze B2 (3 TB stored) | ≈18 USD |
| B2 egress (assuming 1 partial restoration per quarter) | ≈3 USD average |
| NAS (amortization + electricity) | ≈25 USD |
| Postmark/SES (email) | <1 USD |
| Telegram | 0 USD |
| **Estimated total monthly** | **≈47 USD** |

The cost of personnel (operation, monitoring, quarterly tests) is the real dominant component and is estimated at 4-6 hours/month in steady state.

---

## 7. Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Loss of passphrase | Critical | Low | Vault + paper copy in safe |
| Compromise of client with write access to repo | High | Medium | Append-only key + Object Lock + ZFS snapshots |
| Silent repository corruption | High | Low | Monthly rotating `restic check --read-data` |
| NAS failure | Medium | Medium | Independent B2 repository covers the case |
| Backup never tested | Critical | — | Automated quarterly restorations |
| Uncontrolled B2 cost growth | Low | Medium | Prometheus alerts on repository size |

---

## 8. Implementation plan

Implementation is structured in four incremental phases. **Phase 1** (weeks 1-2) consists of deploying the primary repository on NAS, configuring the wrapper and timers on a pilot host, and validating the complete notification flow. **Phase 2** (weeks 3-4) adds the secondary repository in B2, integration with Vault, and append-only hardening. **Phase 3** (weeks 5-6) extends the Ansible role to the rest of servers and workstations. **Phase 4** (weeks 7-8) implements automatic verifications, restoration tests, and Prometheus alerts, closing the observability loop.

Each phase ends with an explicit checkpoint: the phase is not considered closed until the corresponding tests pass in the real environment.

---

## 9. Pending decisions

The following remain open for review in a next iteration: (a) the inclusion of a third copy on disconnected physical storage (LTO tape or rotational disk) for data subject to legal retention of more than 5 years; (b) the eventual migration of the Bash wrapper to a more robust Go binary if complexity grows; (c) the evaluation of `resticprofile` as a declarative configuration layer over Restic.

---

## 10. References

- Official Restic documentation: <https://restic.readthedocs.io>
- Backblaze B2 Object Lock: <https://www.backblaze.com/b2/docs/file_lock.html>
- HashiCorp Vault AppRole: <https://developer.hashicorp.com/vault/docs/auth/approle>
- 3-2-1 backup rule: standard industry practice, originally formulated by Peter Krogh.

---

*End of document.*
