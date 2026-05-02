# Stowkeeper Operations Runbook

This document is the on-call reference for the Stowkeeper backup system. It assumes familiarity with Restic, systemd, and basic Linux system administration. All paths reference the default installation at `/opt/stowkeeper`.

---

## 1. Daily Operations

### 1.1 Verify systemd timers are active

Check that all timers are loaded and have a next trigger time:

```bash
systemctl list-timers --all 'stowkeeper-*'
```

Expected output should show the following timers with future `NEXT` timestamps:

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `stowkeeper-backup-config.timer` | Daily at 02:00 | Backs up `/etc` and system configs |
| `stowkeeper-backup-files.timer` | Daily at 03:00 (+ up to 30 min random delay) | Backs up file paths from `backup-paths.conf` |
| `stowkeeper-backup-db.timer` | Hourly (+ up to 5 min random delay) | Backs up PostgreSQL / MySQL dumps |
| `stowkeeper-check.timer` | Sundays at 04:00 | Runs `restic check` on each repo |
| `stowkeeper-digest.timer` | Daily at 08:00 | Sends daily success digest to Telegram |
| `stowkeeper-maintenance.timer` | Sundays at 03:00 (+ up to 60 min random delay) | Runs forget+prune on B2 (maintenance host only) |
| `stowkeeper-restore-test.timer` | First day of Jan/Apr/Jul/Oct at 05:00 | Quarterly restore test |

If a timer is missing or failed, reload and restart it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now stowkeeper-backup-files.timer
```

### 1.2 Read the daily digest

The digest is sent to the configured Telegram chat at 08:00 daily. It aggregates the results of all backup jobs from the past 24 hours. If you do not receive the digest by 09:00, investigate immediately.

Check the digest queue directory on the host:

```bash
ls -la /var/lib/stowkeeper/digest/
```

Stale files in this directory indicate the digest service is failing to run or send messages.

### 1.3 Check the most recent backup logs

```bash
journalctl -u stowkeeper-backup-files.service --since today
journalctl -u stowkeeper-backup-config.service --since today
journalctl -u stowkeeper-backup-db.service --since today
```

Look for lines tagged with `STOWKEEPER` in the system journal:

```bash
journalctl -t STOWKEEPER --since today
```

### 1.4 Verify Prometheus metrics are current

The metrics file is written to the node_exporter textfile collector directory:

```bash
cat /var/lib/prometheus/node-exporter/stowkeeper.prom
```

Confirm that `stowkeeper_backup_last_success_timestamp` has a Unix timestamp within the last 24 hours for each repository (`nas-primary`, `b2-secondary`).

---

## 2. Understanding Notifications

Alerts are routed through Alertmanager to Telegram (all alerts) and email (critical alerts only).

### 2.1 StaleBackup

- **Severity**: warning
- **Channel**: Telegram
- **Expression**: `time() - stowkeeper_backup_last_success_timestamp > 108000` (30 hours)
- **Meaning**: No successful backup has been recorded for a repository in over 30 hours.
- **Response**:
  1. Check the service logs for the relevant backup job (`journalctl -u stowkeeper-backup-files.service`).
  2. Verify network connectivity to the repository (SFTP to NAS, or HTTPS to B2).
  3. Check for lock contention: `flock -n /var/lock/stowkeeper-backup.lock echo "lock free"`.
  4. If the backup is simply delayed by `RandomizedDelaySec`, confirm the timer is still pending with `systemctl list-timers`.

### 2.2 StaleCheck

- **Severity**: warning
- **Channel**: Telegram
- **Expression**: `time() - stowkeeper_check_last_success_timestamp > 864000` (10 days)
- **Meaning**: `restic check` has not completed successfully in over 10 days.
- **Response**:
  1. Check `journalctl -u stowkeeper-check.service` for errors.
  2. Run a manual check: `backup-runner.sh check`.
  3. If the repository is very large, the check may have timed out. Verify the service has adequate CPU and memory.

### 2.3 GrowthAnomaly

- **Severity**: critical
- **Channel**: Telegram + email
- **Expression**: Repository grew by more than 50% in the last 7 days.
- **Meaning**: Abnormal data growth, possible ransomware encryption, or a new large data source was added without an exclusion rule.
- **Response**:
  1. Log into the host and review recent backup logs for unexpectedly large file counts or sizes.
  2. Check disk usage on the source paths: `du -sh /home /var/www /etc`.
  3. If the growth is legitimate, update `EXCLUDE_FILE` and document the change. If the growth is suspicious, treat it as a potential security incident.
  4. The alert will auto-resolve once the 7-day comparison window stabilizes.

---

## 3. Restore Procedures

All restores require the repository passphrase. If Vault is unavailable, the wrapper falls back to the password files defined in `pilot.conf` (`RESTIC_PASSWORD_FILE_nas`, `RESTIC_PASSWORD_FILE_b2`).

### 3.1 Selective File Restore (single file or directory)

Use this when a user needs a specific file or directory recovered without overwriting the entire system.

1. Identify the snapshot containing the data:

```bash
/opt/stowkeeper/bin/backup-runner.sh snapshots
```

2. Restore to a temporary directory using `--path` to filter:

```bash
/opt/stowkeeper/bin/backup-runner.sh restore \
  --snapshot abc123def \
  --target /tmp/restore \
  --path "/home/user/documents/project"
```

3. Validate the restored content:

```bash
ls -la /tmp/restore/home/user/documents/project
sha256sum /tmp/restore/home/user/documents/project/important-file.txt
```

4. Copy the validated file(s) to the final destination. Do **not** use `mv` from `/tmp/restore` directly; preserve ownership and permissions with `rsync -a` or `cp -a`.

5. Clean up:

```bash
rm -rf /tmp/restore
```

### 3.2 Full Host Restore (bare-metal recovery)

Use this when rebuilding a server from scratch or recovering from total disk failure.

1. Install the base OS, Stowkeeper dependencies (Restic, Bash 4.3+, curl), and copy `pilot.conf` and password files from a secure secondary location.

2. Identify the latest snapshot for this host:

```bash
export RESTIC_REPOSITORY="sftp:user@nas.local:/backups/stowkeeper"
export RESTIC_PASSWORD_FILE="/opt/stowkeeper/conf/.restic-password-nas"
restic snapshots --host $(hostname)
```

3. Restore the entire snapshot to a temporary mount point first to inspect:

```bash
mkdir -p /mnt/recovery
restic restore latest --target /mnt/recovery
```

4. If you are restoring to the same host layout, use `rsync` to overlay the data while preserving existing system files:

```bash
rsync -aHAX --delete --exclude={"/dev","/proc","/sys","/tmp","/run","/mnt","/media","/lost+found"} \
  /mnt/recovery/ /
```

5. Reboot and verify services. If the host uses database dumps, restore the latest DB dump after the file restore (see section 3.3).

6. Document the RTO (recovery time objective) achieved and any issues encountered.

### 3.3 Database Restore (PostgreSQL and MySQL)

Database backups are performed hourly by dumping to a flat file and backing it up with Restic. The database dumps are stored under the paths defined in `BACKUP_PATHS_DB` (default `/var/lib/postgresql/dumps`).

1. Find the latest snapshot containing the DB dump:

```bash
/opt/stowkeeper/bin/backup-runner.sh snapshots
```

2. Restore the dump directory to a temporary location:

```bash
/opt/stowkeeper/bin/backup-runner.sh restore \
  --snapshot abc123def \
  --target /tmp/db-restore \
  --path "/var/lib/postgresql/dumps"
```

3. For **PostgreSQL**, stop the database and restore with `pg_restore` or `psql`:

```bash
sudo systemctl stop postgresql
sudo -u postgres pg_restore -d myapp /tmp/db-restore/var/lib/postgresql/dumps/myapp-$(date +%Y%m%d-%H%M%S).sql
sudo systemctl start postgresql
```

4. For **MySQL**, stop the database and restore with `mysql`:

```bash
sudo systemctl stop mysql
sudo mysql myapp < /tmp/db-restore/var/lib/mysql/dumps/myapp-$(date +%Y%m%d-%H%M%S).sql
sudo systemctl start mysql
```

5. Verify connectivity and data integrity before declaring the restore complete.

---

## 4. Quarterly Restore Test

The automated restore test runs on the first day of January, April, July, and October at 05:00 via `stowkeeper-restore-test.timer`.

### 4.1 What the test does

1. Authenticates to the chosen repository (default `nas`).
2. Retrieves the latest snapshot ID.
3. Checks available disk space (requires 2x the repository size in bytes).
4. Restores the latest snapshot to `/var/lib/stowkeeper/restore-test`.
5. Collects all regular files from the restored tree.
6. Randomly samples 20 files (or fewer if the snapshot is small).
7. Compares `sha256sum` of each restored file against the original on disk.
8. Emits Prometheus metrics and sends a Telegram alert on failure or success.

### 4.2 How to interpret results

Check the metrics:

```bash
grep stowkeeper_restore_test /var/lib/prometheus/node-exporter/stowkeeper.prom
```

- `stowkeeper_restore_test_success{repo="nas-primary"} 1` — test passed.
- `stowkeeper_restore_test_success{repo="nas-primary"} 0` — test failed. Investigate immediately.
- `stowkeeper_restore_test_files_checked` — should be 20 (or equal to total files if fewer than 20).
- `stowkeeper_restore_test_files_matched` — must equal `files_checked` for a pass.

To run the test manually:

```bash
sudo /opt/stowkeeper/bin/stowkeeper-restore-test.sh nas
sudo /opt/stowkeeper/bin/stowkeeper-restore-test.sh b2
```

The script cleans up the restore directory automatically on exit. If disk space is insufficient, the script aborts before restoring and sends a warning alert.

---

## 5. Weekly Maintenance

### 5.1 Schedule

- **Timer**: `stowkeeper-maintenance.timer`
- **When**: Sundays at 03:00 with a randomized delay up to 60 minutes
- **Where**: Dedicated maintenance host only
- **What**: `restic forget --prune` + `restic check` on the B2 repository

The maintenance host holds a separate elevated B2 key with `deleteFiles` permission. Backup clients use write-only keys and cannot prune.

### 5.2 What to check after maintenance

1. Verify the maintenance metric:

```bash
grep stowkeeper_maintenance /var/lib/prometheus/node-exporter/stowkeeper.prom
```

- `stowkeeper_maintenance_status{repo="b2-secondary"} 1` — success.
- `stowkeeper_maintenance_status{repo="b2-secondary"} 0` — failure.

2. Check the maintenance timestamp:

```bash
grep stowkeeper_maintenance_last_success_timestamp /var/lib/prometheus/node-exporter/stowkeeper.prom
```

The timestamp should be from the most recent Sunday.

3. Review logs:

```bash
journalctl -u stowkeeper-maintenance.service --since "last sunday"
```

### 5.3 Retention policy

The default GFS (Grandfather-Father-Son) policy is configured in `pilot.conf`:

```bash
RETENTION_POLICY="--keep-last 3 --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 5"
```

Do not change this on the backup client. Retention changes must be applied on the maintenance host and documented.

---

## 6. Deep Integrity Checks

### 6.1 Schedule and rotation

The deep check reads actual data from the repository to detect silent corruption. It runs monthly on the first Sunday of the month during the `stowkeeper-check.service` window.

- **Mechanism**: `restic check --read-data-subset=N0%` where N is a rotating counter from 0 to 9.
- **Coverage**: 10% of pack files per month, covering 100% of the repository every 10 months.
- **Counter file**: `/var/lib/stowkeeper/check-read-data-month`

The counter is incremented atomically after each deep check. Do not edit this file manually unless you understand the rotation schedule.

### 6.2 How to verify deep check status

Check the deep-check timestamp metric:

```bash
grep stowkeeper_check_deep_success_timestamp /var/lib/prometheus/node-exporter/stowkeeper.prom
```

This timestamp should never be older than approximately 40 days (monthly schedule plus variance).

To trigger a manual deep check for the current subset:

```bash
/opt/stowkeeper/bin/backup-runner.sh check --read-data
```

To run a full read-data check (not recommended during production hours on large repos):

```bash
restic check --read-data
```

---

## 7. Troubleshooting

### 7.1 Backup failing

#### NAS unreachable (SFTP timeout or connection refused)

1. Test connectivity from the backup host:

```bash
ssh -p 22 -o ConnectTimeout=10 user@nas.local echo ok
```

2. If SSH succeeds but Restic fails, check the SFTP subsystem on the NAS:

```bash
ssh user@nas.local sftp-server -V
```

3. Verify the `RESTIC_REPOSITORY_nas` path exists and is writable.

#### B2 authentication failure

1. Confirm the application key ID and secret are set:

```bash
grep -E "AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY" /opt/stowkeeper/conf/pilot.conf
```

2. Test with `rclone` or `aws s3 ls` using the same credentials.

3. Check if the key is expired or revoked in the Backblaze console.

4. Backup clients use a **write-only key**. If you need to run `check` or `restore`, you may need a key with broader permissions.

#### Lock contention

The wrapper uses `flock` on `/var/lock/stowkeeper-backup.lock` with a 60-second timeout. If a previous backup process crashed without releasing the lock:

```bash
sudo fuser /var/lock/stowkeeper-backup.lock
sudo rm -f /var/lock/stowkeeper-backup.lock
```

Then retry the backup.

### 7.2 Notifications not arriving

#### Telegram

1. Verify the bot token and chat ID are set in `pilot.conf`:

```bash
grep -E "TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID" /opt/stowkeeper/conf/pilot.conf
```

2. Test the Telegram API directly:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>" -d "text=Stowkeeper test message"
```

3. Check the deduplication directory for stuck state:

```bash
ls -la /var/lib/stowkeeper/dedup/
```

#### Email (msmtp relay)

1. Verify msmtp is configured and the relay is reachable:

```bash
echo "Test" | msmtp -d ops@example.com
```

2. Check rate-limiting counters in `/var/lib/stowkeeper/dedup/`.

3. Review `SMTP_HOST`, `SMTP_PORT`, and credentials in `pilot.conf`.

### 7.3 Metrics missing from Prometheus

1. Confirm the metrics file exists and is readable by node_exporter:

```bash
ls -la /var/lib/prometheus/node-exporter/stowkeeper.prom
```

2. Check that node_exporter is configured to read from the textfile collector directory. The metric filename must end in `.prom`.

3. Verify the Stowkeeper process has permission to write to that directory:

```bash
sudo -u stowkeeper touch /var/lib/prometheus/node-exporter/stowkeeper.prom
```

4. If the file is present but Prometheus does not show the metrics, check the node_exporter logs for scrape errors.

### 7.4 High disk usage on temp dir

The restore test uses `/var/lib/stowkeeper/restore-test` and requires 2x the repository size. Database dumps are also written to temporary locations before backup.

1. Check disk usage:

```bash
df -h /var/lib/stowkeeper
du -sh /var/lib/stowkeeper/restore-test
```

2. If the restore test is consuming too much space, you can temporarily skip it by disabling the timer, but **do not leave it disabled**:

```bash
sudo systemctl stop stowkeeper-restore-test.timer
```

3. For database dumps, ensure `BACKUP_PATHS_DB` points to a partition with adequate space, or reduce dump retention outside of Stowkeeper.

---

## 8. Emergency Procedures

### 8.1 Vault is down

Stowkeeper authenticates to HashiCorp Vault to retrieve repository passphrases. If Vault is unreachable, the wrapper automatically falls back to the local password files defined in `pilot.conf`:

- `RESTIC_PASSWORD_FILE_nas`
- `RESTIC_PASSWORD_FILE_b2`

**Action**:
1. Confirm the fallback password files exist and are readable.
2. Run a manual backup to verify functionality:

```bash
/opt/stowkeeper/bin/backup-runner.sh backup --job config
```

3. Restore Vault service as a priority. While the fallback works, passphrase rotation and audit logging depend on Vault.

### 8.2 NAS failure

If the primary NAS repository becomes unavailable:

1. Verify the failure is not transient (network issue, SSH daemon restart).
2. Switch operations to the B2 repository immediately. All backup, restore, and check operations can target B2:

```bash
/opt/stowkeeper/bin/backup-runner.sh snapshots
RESTIC_REPOSITORY="${RESTIC_REPOSITORY_b2}" RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE_b2}" restic snapshots
```

3. Restores should use B2 until the NAS is repaired or replaced.
4. When the NAS is restored, reinitialize the repository if necessary and resume dual-repo backups. Do not copy B2 data back to the NAS using `restic copy`; reinitialize and let the next backup runs repopulate the NAS repo naturally.

### 8.3 Complete loss of primary repo

If the NAS repository is destroyed or corrupted beyond recovery:

1. Ensure B2 backups are healthy:

```bash
RESTIC_REPOSITORY="${RESTIC_REPOSITORY_b2}" RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE_b2}" restic check
```

2. Reinitialize the NAS repository (only if you are certain it is lost):

```bash
/opt/stowkeeper/bin/backup-runner.sh init --repo nas
```

3. Resume backups. The next `backup-runner.sh backup` run will create a new snapshot chain on the NAS. B2 retains the historical chain.

4. Update ZFS snapshot schedules and NAS hardening to prevent recurrence.

---

## 9. Monitoring Dashboard

The Grafana dashboard template is located at `monitoring/grafana/stowkeeper-dashboard.json`. Import it into your Grafana instance and set the data source to your Prometheus server.

### 9.1 Dashboard panels

| Panel | Query | Interpretation |
|-------|-------|----------------|
| **Last Backup Age** | `time() - stowkeeper_backup_last_success_timestamp` | Green < 25h, Yellow > 25h, Red > 30h. Red means the StaleBackup alert is firing. |
| **Repository Size** | `stowkeeper_repo_size_bytes` | Track growth trends. A sudden spike triggers GrowthAnomaly. |
| **Last Check Age** | `time() - stowkeeper_check_last_success_timestamp` | Green < 7d, Yellow > 8d, Red > 10d. Red means StaleCheck is firing. |
| **Last Deep Check** | `time() - stowkeeper_check_deep_success_timestamp` | Should be < 40 days. If this goes red, monthly deep integrity checks are failing. |
| **Restore Test Status** | `stowkeeper_restore_test_success` | Green = 1 (pass), Red = 0 (fail). A red status is a critical signal that backups may be corrupt. |
| **Restore Test Files Checked** | `stowkeeper_restore_test_files_checked` | Usually 20. A low number may indicate a nearly empty snapshot. |
| **Restore Test Files Matched** | `stowkeeper_restore_test_files_matched` | Must equal Files Checked. A mismatch indicates data corruption or a changed source file. |
| **Alert State** | `ALERTS{alertstate="firing"}` | Lists all currently firing alerts. Use this as your first stop during an incident. |

### 9.2 Typical on-call workflow

1. Open the Grafana dashboard.
2. Check the **Alert State** panel for any firing alerts.
3. If StaleBackup is firing, open **Last Backup Age** to identify which repo is behind.
4. If Restore Test Status is red, treat it as a potential data integrity incident and begin a manual restore test immediately.
5. Use **Repository Size** to validate GrowthAnomaly alerts before dismissing them.

---

## Quick Reference Commands

```bash
# List snapshots
/opt/stowkeeper/bin/backup-runner.sh snapshots

# Manual backup
/opt/stowkeeper/bin/backup-runner.sh backup --job files

# Manual check
/opt/stowkeeper/bin/backup-runner.sh check

# Manual deep check
/opt/stowkeeper/bin/backup-runner.sh check --read-data

# Restore a single path
/opt/stowkeeper/bin/backup-runner.sh restore --snapshot <id> --target /tmp/restore --path "/home/user/data"

# Maintenance (maintenance host only)
/opt/stowkeeper/bin/backup-runner.sh maintenance --with-prune

# Restore test
/opt/stowkeeper/bin/stowkeeper-restore-test.sh nas

# View all timers
systemctl list-timers --all 'stowkeeper-*'

# View Stowkeeper logs
journalctl -t STOWKEEPER --since today

# View metrics
cat /var/lib/prometheus/node-exporter/stowkeeper.prom
```
