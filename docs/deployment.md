---
layout: default
title: Deployment Guide
---

# Stowkeeper Deployment Guide

This document provides step-by-step instructions for deploying Stowkeeper — an end-to-end encrypted backup pipeline with dual-repository support (local NAS and Backblaze B2) — to production Linux hosts.

---

## Table of Contents

1. [Overview](#overview)
2. [Pre-deployment Checklist](#pre-deployment-checklist)
3. [Manual Deployment (Single Host)](#manual-deployment-single-host)
4. [Ansible Deployment (Multi-Host)](#ansible-deployment-multi-host)
5. [Post-deployment Verification](#post-deployment-verification)
6. [Maintenance Host Setup](#maintenance-host-setup)
7. [Vault Setup](#vault-setup)
8. [Backblaze B2 Setup](#backblaze-b2-setup)
9. [Troubleshooting Common Issues](#troubleshooting-common-issues)

---

## Overview

This guide covers two deployment paths:

- **Manual deployment** for a single host (workstation or standalone server)
- **Ansible deployment** for fleets of servers and workstations

Both paths result in a fully configured backup client that:

- Backs up files, configuration, and optionally databases to a local NAS via SFTP
- Replicates backups to Backblaze B2 for off-site protection
- Reports status via Telegram and email
- Exposes Prometheus metrics for monitoring
- Runs on systemd timers with automatic catch-up if the host was offline

### Prerequisites Summary

Before beginning, ensure you have:

- A Linux host running Ubuntu 22.04/24.04 or Debian 12
- A NAS accessible via SFTP with a ZFS dataset for backups
- A Backblaze B2 account with a bucket and application keys
- HashiCorp Vault (optional but recommended) for secret management
- A Telegram bot for notifications
- An SMTP relay for email alerts (optional)
- Ansible 2.12+ on your control node (for multi-host deployment only)

---

## Pre-deployment Checklist

Complete all items below before running any installation commands.

### 1. NAS Available and Configured

- NAS reachable from all backup hosts via SFTP
- A dedicated ZFS dataset created for Stowkeeper repositories
- SFTP user created with write access to the backup path
- SSH host keys accepted (or `host_key_checking = false` in `ansible.cfg`)

### 2. Backblaze B2 Bucket Created

- B2 account active at https://www.backblaze.com/b2/
- Bucket created with Object Lock enabled (30-day compliance mode)
- Two application keys created:
  - **Write-only key** for backup clients (no delete, no list)
  - **Elevated key** for maintenance host (deleteFiles + listFiles)

See [Backblaze B2 Setup](#backblaze-b2-setup) for detailed steps.

### 3. HashiCorp Vault Configured

- Vault server running and reachable from all hosts
- KV v2 secrets engine mounted at a path for Stowkeeper
- AppRole auth method enabled
- Policies created for backup clients and maintenance host
- Passphrases stored for each repository

See [Vault Setup](#vault-setup) for detailed steps.

### 4. SMTP Relay Available

- An SMTP relay host that accepts authentication (port 587)
- Credentials for the relay
- A sender address and recipient ops address

If you do not configure SMTP, email alerts will be skipped. Telegram alerts will still work.

### 5. Telegram Bot Created

- A Telegram bot created via @BotFather
- The bot token copied for configuration
- A chat ID identified (use @userinfobot or the Telegram API)

### 6. Restic Binary Available

- Restic 0.17+ installed on all target hosts, **or**
- An internal mirror with SHA256 checksums (Ansible deployment only)

---

## Manual Deployment (Single Host)

Use this path for a single workstation or server where Ansible is not available or not desired.

### Step 1: Clone the Repository

```bash
git clone https://github.com/<org>/stowkeeper.git /opt/stowkeeper
cd /opt/stowkeeper
```

### Step 2: Run the Installer

```bash
sudo bash install.sh
```

The installer performs the following actions:

- Creates `/opt/stowkeeper/`, `/opt/stowkeeper/conf/`, and `/opt/stowkeeper/lib/`
- Creates `/var/lib/stowkeeper/digest` and `/var/lib/stowkeeper/dedup`
- Detects or creates the Prometheus node_exporter textfile collector directory
- Copies `backup-runner.sh` and library scripts to `/opt/stowkeeper/`
- Copies `src/configs/pilot.conf` to `/opt/stowkeeper/conf/pilot.conf` if absent
- Sets permissions (scripts executable, config readable only by root)

### Step 3: Generate and Store Repository Passphrases

Each Restic repository requires a strong passphrase. Generate one per repository:

```bash
# For NAS repository
openssl rand -base64 32 | sudo tee /opt/stowkeeper/conf/.restic-password-nas
sudo chmod 600 /opt/stowkeeper/conf/.restic-password-nas

# For B2 repository (if using dual-repo mode)
openssl rand -base64 32 | sudo tee /opt/stowkeeper/conf/.restic-password-b2
sudo chmod 600 /opt/stowkeeper/conf/.restic-password-b2
```

Store these passphrases in Vault or your password manager. **You cannot recover a repository without its passphrase.**

### Step 4: Edit `pilot.conf`

Open `/opt/stowkeeper/conf/pilot.conf` and set all required values.

Key variables to configure:

```bash
# Repository mode
REPOS=("nas" "b2")

# NAS repository
RESTIC_REPOSITORY_nas="sftp:backup@nas.local:/backups/stowkeeper/$(hostname)"
RESTIC_PASSWORD_FILE_nas="/opt/stowkeeper/conf/.restic-password-nas"

# B2 repository
RESTIC_REPOSITORY_b2="s3:https://s3.us-west-000.backblazeb2.com/stowkeeper-b2/$(hostname)"
RESTIC_PASSWORD_FILE_b2="/opt/stowkeeper/conf/.restic-password-b2"

# Backup paths
BACKUP_PATHS_FILES=("/home" "/var/www")
BACKUP_PATHS_CONFIG=("/etc")

# B2 credentials (write-only key)
AWS_ACCESS_KEY_ID="your-b2-key-id"
AWS_SECRET_ACCESS_KEY="your-b2-application-key"

# Telegram notifications
TELEGRAM_BOT_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"

# Vault (optional but recommended)
VAULT_ADDR="https://vault.local:8200"
VAULT_ROLE_ID_stowkeeper_nas="your-role-id"
VAULT_SECRET_ID_stowkeeper_nas="your-secret-id"
VAULT_ROLE_ID_stowkeeper_b2="your-role-id"
VAULT_SECRET_ID_stowkeeper_b2="your-secret-id"

# SMTP (optional)
SMTP_HOST="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="stowkeeper@example.com"
SMTP_PASS="your-smtp-password"
SMTP_FROM="stowkeeper@example.com"
SMTP_TO="ops@example.com"
```

See `src/configs/pilot.conf` for the fully annotated template with all available options.

### Step 5: Create Exclusions File (Optional)

```bash
sudo tee /opt/stowkeeper/conf/excludes.txt << 'EOF'
*.log
*.tmp
.cache/
node_modules/
EOF
```

Set the path in `pilot.conf`:

```bash
EXCLUDE_FILE="/opt/stowkeeper/conf/excludes.txt"
```

### Step 6: Initialize Repositories

```bash
cd /opt/stowkeeper
sudo ./backup-runner.sh init --repo nas
sudo ./backup-runner.sh init --repo b2
```

If initialization succeeds, you will see confirmation that the repository was created.

### Step 7: Deploy Systemd Units

Copy the timer and service files:

```bash
sudo cp src/systemd/stowkeeper-*.service src/systemd/stowkeeper-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

Enable and start the timers:

```bash
# Configuration backup (daily at 02:00)
sudo systemctl enable --now stowkeeper-backup-config.timer

# File backup (daily at 03:00 with 30-minute random delay)
sudo systemctl enable --now stowkeeper-backup-files.timer

# Database backup (hourly, only if DB_TYPE is set)
sudo systemctl enable --now stowkeeper-backup-db.timer

# Weekly integrity check (Sunday at 04:00)
sudo systemctl enable --now stowkeeper-check.timer

# Daily success digest
sudo systemctl enable --now stowkeeper-digest.timer

# Quarterly restore test (first Sunday of Jan/Apr/Jul/Oct at 05:00)
sudo systemctl enable --now stowkeeper-restore-test.timer
```

**Do not** enable `stowkeeper-maintenance.timer` on backup clients. That timer is for the maintenance host only.

### Step 8: Run a Test Backup

```bash
sudo /opt/stowkeeper/backup-runner.sh backup --job config
sudo /opt/stowkeeper/backup-runner.sh backup --job files
```

Verify the snapshots exist:

```bash
sudo /opt/stowkeeper/backup-runner.sh snapshots
```

---

## Ansible Deployment (Multi-Host)

Use this path to deploy Stowkeeper to multiple servers and workstations from a single control node.

### Step 1: Prepare the Control Node

Install Ansible 2.12+ and clone the repository:

```bash
git clone https://github.com/<org>/stowkeeper.git
cd stowkeeper
```

Verify `ansible.cfg` exists. The default configuration is:

```ini
[defaults]
inventory = inventory/hosts
roles_path = roles
host_key_checking = false
stdout_callback = yaml
```

### Step 2: Define Your Inventory

Edit `inventory/hosts` and uncomment or add your hosts under the appropriate groups:

```ini
[servers]
srv-web-01 ansible_host=10.0.0.10
srv-app-01 ansible_host=10.0.0.11

[workstations]
ws-dev-01 ansible_host=10.0.1.10

[db_hosts]
srv-db-01 ansible_host=10.0.0.20 stowkeeper_db_type=postgresql

[all:vars]
ansible_user=deploy
```

- `servers` — Production servers with dual-repo (NAS + B2)
- `workstations` — Developer workstations (NAS only, no DB)
- `db_hosts` — Subset of servers with database backups enabled

### Step 3: Create Per-Host Variables

For each host, create `inventory/host_vars/<hostname>.yml`.

Example for a web server (`inventory/host_vars/srv-web-01.yml`):

```yaml
---
stowkeeper_backup_paths:
  - /etc
  - /var/www
  - /home
stowkeeper_exclude_patterns:
  - "*.log"
  - "*.tmp"
  - ".cache/"
stowkeeper_db_type: ""
```

Example for a database server (`inventory/host_vars/srv-db-01.yml`):

```yaml
---
stowkeeper_backup_paths:
  - /etc
  - /var/lib/postgresql
  - /home
stowkeeper_db_type: postgresql
stowkeeper_db_name: myapp
stowkeeper_db_user: postgres
```

See `roles/backup_client/README.md` for the full list of role variables.

### Step 4: Encrypt Secrets with Ansible Vault

All secrets must be encrypted. Use `ansible-vault encrypt_string` or encrypt the entire `host_vars` file.

Encrypt individual strings (recommended for mixed vars + secrets):

```bash
ansible-vault encrypt_string --name 'vault_telegram_bot_token' 'your-bot-token'
ansible-vault encrypt_string --name 'vault_telegram_chat_id' 'your-chat-id'
ansible-vault encrypt_string --name 'vault_stowkeeper_b2_app_key' 'your-b2-key'
ansible-vault encrypt_string --name 'vault_stowkeeper_smtp_pass' 'your-smtp-password'
ansible-vault encrypt_string --name 'vault_stowkeeper_role_id' 'your-vault-role-id'
ansible-vault encrypt_string --name 'vault_stowkeeper_secret_id' 'your-vault-secret-id'
```

Paste the encrypted output into the corresponding `host_vars/<hostname>.yml` file.

Alternatively, encrypt the entire file:

```bash
ansible-vault encrypt inventory/host_vars/srv-web-01.yml
```

### Step 5: Run the Playbook

The main playbook is `playbooks/deploy-backup.yml`:

```yaml
---
- name: Deploy Stowkeeper backup pipeline
  hosts: all
  become: yes
  roles:
    - backup_client
```

Run it:

```bash
ansible-playbook playbooks/deploy-backup.yml
```

To limit to a specific group or host:

```bash
ansible-playbook playbooks/deploy-backup.yml --limit servers
ansible-playbook playbooks/deploy-backup.yml --limit srv-web-01
```

If your vault password is in a file:

```bash
ansible-playbook playbooks/deploy-backup.yml --vault-password-file ~/.vault_pass
```

### Step 6: Initialize Repositories on Each Host

The Ansible role installs the software and configuration but does **not** initialize Restic repositories. You must do this manually on each host (or via an ad-hoc Ansible command):

```bash
ansible servers -b -a "/opt/stowkeeper/backup-runner.sh init --repo nas"
ansible servers -b -a "/opt/stowkeeper/backup-runner.sh init --repo b2"
```

### Step 7: Verify Timers Are Enabled

The role deploys and enables timers automatically. Verify on a target host:

```bash
ssh srv-web-01 sudo systemctl list-timers --all | grep stowkeeper
```

---

## Post-deployment Verification

After deployment, confirm the pipeline is operational using the following checks.

### 1. Check Systemd Timers

On the target host:

```bash
sudo systemctl list-timers --all | grep stowkeeper
```

Expected output shows timers for `backup-config`, `backup-files`, `backup-db`, `check`, `digest`, and `restore-test` in a `waiting` or `elapsed` state.

### 2. Check Logs for Recent Runs

```bash
sudo journalctl -u stowkeeper-backup-files.service --since "24 hours ago"
sudo journalctl -u stowkeeper-backup-config.service --since "24 hours ago"
```

Look for lines indicating backup completion and success metrics.

### 3. Verify Snapshots Exist

```bash
sudo /opt/stowkeeper/backup-runner.sh snapshots
```

You should see at least one snapshot per repository for each job type (config, files, db).

### 4. Check Prometheus Metrics

```bash
cat /var/lib/prometheus/node-exporter/stowkeeper.prom
```

Expected metrics include:

```
stowkeeper_backup_last_success_timestamp{repo="nas"} 1714600000
stowkeeper_backup_duration_seconds{repo="nas"} 45.2
stowkeeper_backup_size_bytes{repo="nas"} 123456789
stowkeeper_backup_files_new{repo="nas"} 42
stowkeeper_check_last_success_timestamp{repo="nas"} 1714600000
```

### 5. Test Notifications

Trigger a manual digest to verify Telegram connectivity:

```bash
sudo /opt/stowkeeper/backup-runner.sh digest
```

You should receive a Telegram message summarizing recent backup activity.

To test email alerts, temporarily misconfigure a repository path and run a backup. Correct the configuration immediately after confirming the alert email arrives.

### 6. Verify Repository Integrity

Run a manual check:

```bash
sudo /opt/stowkeeper/backup-runner.sh check
```

For a deep check (reads 10% of data):

```bash
sudo /opt/stowkeeper/backup-runner.sh check --read-data
```

### 7. Verify Dual-Repo Behavior

If both NAS and B2 are configured, confirm that backups are written to both repositories and that a failure in one does not block the other:

```bash
# Temporarily make B2 unreachable (e.g., block outbound HTTPS)
sudo iptables -A OUTPUT -p tcp --dport 443 -j DROP
sudo /opt/stowkeeper/backup-runner.sh backup --job config
# NAS backup should succeed; B2 backup should fail and alert
sudo iptables -D OUTPUT -p tcp --dport 443 -j DROP
```

---

## Maintenance Host Setup

The maintenance host is a separate, isolated host responsible for running `restic forget --prune` on the B2 repository. This is a **security boundary**: the elevated B2 key with `deleteFiles` permission must never reside on backup clients.

### Requirements

- A dedicated host or VM with no other function
- Network access to Backblaze B2 (HTTPS outbound)
- Restic 0.17+ installed
- No backup timers installed (only maintenance and check timers)

### Step 1: Install Stowkeeper on the Maintenance Host

```bash
git clone https://github.com/<org>/stowkeeper.git /opt/stowkeeper
cd /opt/stowkeeper
sudo bash install.sh
```

### Step 2: Configure `maintenance.conf`

Copy the maintenance template:

```bash
sudo cp src/configs/maintenance.conf /opt/stowkeeper/conf/maintenance.conf
sudo chmod 600 /opt/stowkeeper/conf/maintenance.conf
sudo vim /opt/stowkeeper/conf/maintenance.conf
```

Set the following:

```bash
RESTIC_REPOSITORY_b2="s3:https://s3.us-west-000.backblazeb2.com/stowkeeper-b2"
RESTIC_PASSWORD_FILE_b2="/opt/stowkeeper/conf/.restic-password-b2"

# Elevated B2 key (deleteFiles + listFiles)
AWS_ACCESS_KEY_ID="your-maintenance-key-id"
AWS_SECRET_ACCESS_KEY="your-maintenance-application-key"

# Vault (use a separate AppRole with restricted policy)
VAULT_ADDR="https://vault.local:8200"
VAULT_ROLE_ID_stowkeeper_b2="maintenance-role-id"
VAULT_SECRET_ID_stowkeeper_b2="maintenance-secret-id"

# Notifications
TELEGRAM_BOT_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"

SMTP_HOST="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="stowkeeper@example.com"
SMTP_PASS="your-smtp-password"
SMTP_FROM="stowkeeper@example.com"
SMTP_TO="ops@example.com"
```

See `src/configs/maintenance.conf` for the full annotated template.

### Step 3: Deploy Maintenance Timer Only

Copy only the maintenance timer and service:

```bash
sudo cp src/systemd/stowkeeper-maintenance.service src/systemd/stowkeeper-maintenance.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now stowkeeper-maintenance.timer
```

The maintenance timer runs weekly on Sundays at 03:00 with a 1-hour randomized delay:

```
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
RandomizedDelaySec=3600
```

### Step 4: Verify Maintenance Run

After the first scheduled run (or trigger manually):

```bash
sudo systemctl start stowkeeper-maintenance.service
sudo journalctl -u stowkeeper-maintenance.service
```

Check that old snapshots were pruned according to the retention policy:

```bash
sudo RESTIC_REPOSITORY="s3:https://s3.us-west-000.backblazeb2.com/stowkeeper-b2" \
  RESTIC_PASSWORD_FILE="/opt/stowkeeper/conf/.restic-password-b2" \
  AWS_ACCESS_KEY_ID="your-maintenance-key-id" \
  AWS_SECRET_ACCESS_KEY="your-maintenance-application-key" \
  restic snapshots
```

### Security Notes

- The maintenance host must not have `stowkeeper-backup-*` timers or services
- Rotate the elevated B2 key immediately if the maintenance host is compromised
- The maintenance host should be on a restricted network segment with outbound HTTPS only
- Vault AppRole for the maintenance host should use a separate policy with read-only access to the KV path

---

## Vault Setup

HashiCorp Vault is optional but strongly recommended for managing repository passphrases and B2 keys. Without Vault, credentials are stored in environment files on disk.

### Step 1: Enable KV v2 Secrets Engine

```bash
vault secrets enable -path=stowkeeper kv-v2
```

### Step 2: Store Repository Passphrases

```bash
vault kv put stowkeeper/repos/nas passphrase="$(openssl rand -base64 32)"
vault kv put stowkeeper/repos/b2 passphrase="$(openssl rand -base64 32)"
```

### Step 3: Create Policies

Policy for backup clients (`stowkeeper-client-policy.hcl`):

```hcl
path "stowkeeper/data/repos/nas" {
  capabilities = ["read"]
}

path "stowkeeper/data/repos/b2" {
  capabilities = ["read"]
}
```

Policy for maintenance host (`stowkeeper-maintenance-policy.hcl`):

```hcl
path "stowkeeper/data/repos/b2" {
  capabilities = ["read"]
}
```

Apply policies:

```bash
vault policy write stowkeeper-client stowkeeper-client-policy.hcl
vault policy write stowkeeper-maintenance stowkeeper-maintenance-policy.hcl
```

### Step 4: Create AppRoles

```bash
# Enable AppRole if not already enabled
vault auth enable approle

# Backup client AppRole
vault write auth/approle/role/stowkeeper-client \
  token_policies="stowkeeper-client" \
  token_ttl=1h \
  token_max_ttl=4h

# Maintenance host AppRole
vault write auth/approle/role/stowkeeper-maintenance \
  token_policies="stowkeeper-maintenance" \
  token_ttl=1h \
  token_max_ttl=4h
```

### Step 5: Retrieve Role IDs and Secret IDs

```bash
# Backup client
vault read auth/approle/role/stowkeeper-client/role-id
vault write -f auth/approle/role/stowkeeper-client/secret-id

# Maintenance host
vault read auth/approle/role/stowkeeper-maintenance/role-id
vault write -f auth/approle/role/stowkeeper-maintenance/secret-id
```

### Step 6: Configure `pilot.conf` with Vault Credentials

For each host, set the AppRole credentials in `pilot.conf`:

```bash
VAULT_ADDR="https://vault.local:8200"
VAULT_ROLE_ID_stowkeeper_nas="backup-client-role-id"
VAULT_SECRET_ID_stowkeeper_nas="backup-client-secret-id"
VAULT_ROLE_ID_stowkeeper_b2="backup-client-role-id"
VAULT_SECRET_ID_stowkeeper_b2="backup-client-secret-id"
```

When Vault is available, `backup-runner.sh` will retrieve the passphrase at runtime and fall back to `RESTIC_PASSWORD_FILE` if Vault is unreachable.

---

## Backblaze B2 Setup

### Step 1: Create a Bucket

1. Log in to the Backblaze B2 web console
2. Navigate to **Buckets** and click **Create a Bucket**
3. Name the bucket (e.g., `stowkeeper-b2`)
4. Set **File Lock** to **Enabled**
5. Set **Default Retention** to **30 days** in **Compliance** mode
6. Click **Create Bucket**

Object Lock in compliance mode prevents deletion or modification of objects for 30 days, protecting against ransomware and accidental `restic forget`.

### Step 2: Create Application Keys

#### Write-Only Key (Backup Clients)

1. Go to **App Keys** and click **Create Application Key**
2. Name it `stowkeeper-backup-clients`
3. Select **Allow access to:** your bucket only
4. Set **Type of Access** to **Write Only**
5. Click **Create Application Key**
6. Copy the **keyID** and **applicationKey** immediately — the key is shown only once

This key can upload files but cannot delete, list, or read metadata. It is safe to distribute to all backup clients.

#### Elevated Key (Maintenance Host)

1. Create a second application key named `stowkeeper-maintenance`
2. Select **Allow access to:** your bucket only
3. Set **Type of Access** to **Read and Write**
4. Click **Create Application Key**
5. Copy the **keyID** and **applicationKey**

This key has `deleteFiles` permission and is required for `restic forget --prune`. Store it only on the maintenance host.

### Step 3: Configure B2 in Stowkeeper

In `pilot.conf` or `maintenance.conf`, set:

```bash
RESTIC_REPOSITORY_b2="s3:https://s3.us-west-000.backblazeb2.com/stowkeeper-b2"
AWS_ACCESS_KEY_ID="your-key-id"
AWS_SECRET_ACCESS_KEY="your-application-key"
```

Replace `us-west-000` with your bucket's actual region endpoint.

### Step 4: Verify B2 Connectivity

```bash
export AWS_ACCESS_KEY_ID="your-key-id"
export AWS_SECRET_ACCESS_KEY="your-application-key"
restic -r s3:https://s3.us-west-000.backblazeb2.com/stowkeeper-b2 snapshots
```

You should see an empty repository or existing snapshots.

---

## Troubleshooting Common Issues

### Backup fails with "repository does not exist"

**Cause:** Repository was never initialized.

**Fix:**

```bash
sudo /opt/stowkeeper/backup-runner.sh init --repo nas
sudo /opt/stowkeeper/backup-runner.sh init --repo b2
```

### Backup fails with "wrong password"

**Cause:** The passphrase does not match the one used during `init`.

**Fix:**

1. Verify the passphrase in `RESTIC_PASSWORD_FILE_nas` or `RESTIC_PASSWORD_FILE_b2`
2. If using Vault, check that the KV path and key name are correct
3. If the passphrase is lost, the repository is unrecoverable

### Telegram alerts not received

**Cause:** Invalid bot token or chat ID.

**Fix:**

```bash
# Test directly with curl
curl -s -X POST "https://api.telegram.org/bot<token>/sendMessage" \
  -d "chat_id=<chat_id>" \
  -d "text=Test from Stowkeeper"
```

If this fails, regenerate the token via @BotFather and verify the chat ID.

### Email alerts not sent

**Cause:** SMTP misconfiguration or msmtp not installed.

**Fix:**

1. Verify `msmtp` is installed: `which msmtp`
2. Test msmtp manually with the credentials from `pilot.conf`
3. Check firewall rules for outbound SMTP (port 587)
4. Review `/var/log/mail.log` for bounces

### Prometheus metrics missing

**Cause:** node_exporter textfile collector directory not found or not writable.

**Fix:**

```bash
# Check the detected metrics directory
grep METRICS_FILE /opt/stowkeeper/conf/pilot.conf

# Verify it exists and is writable by root
ls -ld /var/lib/prometheus/node-exporter

# Check node_exporter is configured with --collector.textfile.directory
cat /etc/default/prometheus-node-exporter | grep textfile
```

### systemd timer not firing

**Cause:** Timer not enabled or host was off during the scheduled window without `Persistent=true`.

**Fix:**

```bash
# Verify timer is enabled
sudo systemctl is-enabled stowkeeper-backup-files.timer

# If not enabled:
sudo systemctl enable --now stowkeeper-backup-files.timer

# Check timer status
sudo systemctl status stowkeeper-backup-files.timer

# Manually trigger to test
sudo systemctl start stowkeeper-backup-files.service
```

### B2 backup fails with "403 Forbidden"

**Cause:** Incorrect application key or key lacks write permission.

**Fix:**

1. Verify the key ID and secret in `pilot.conf`
2. In the B2 console, confirm the key has access to the correct bucket
3. If using a write-only key, confirm it was created with **Write Only** access
4. Check the bucket endpoint region matches the URL in `RESTIC_REPOSITORY_b2`

### Maintenance `forget --prune` fails with "403 Forbidden"

**Cause:** The maintenance host is using the write-only backup client key instead of the elevated key.

**Fix:**

1. Verify `AWS_ACCESS_KEY_ID` in `maintenance.conf` matches the elevated key
2. Confirm the elevated key has **Read and Write** access in the B2 console
3. Restart the maintenance service after correcting the key

### Lock file stale after a crash

**Cause:** `backup-runner.sh` uses `flock` for concurrency control. If the host crashes during a backup, the lock file may appear stale.

**Fix:**

```bash
# Check if a process holds the lock
sudo lsof /var/lock/stowkeeper-backup.lock

# If no process holds it, remove the lock file
sudo rm -f /var/lock/stowkeeper-backup.lock
```

The script will recreate the lock file on the next run.

### ZFS snapshot on NAS not created

**Cause:** ZFS snapshot commands are external to Stowkeeper and must be configured on the NAS itself.

**Fix:**

Set up a snapshot schedule on the NAS for the backup dataset:

```bash
# Example: hourly snapshots, keep 24
zfs snapshot tank/backups/stowkeeper@hourly-$(date +%Y%m%d-%H%M)
zfs list -t snapshot tank/backups/stowkeeper | tail -n +2 | sort | head -n -24 | awk '{print $1}' | xargs -n1 zfs destroy
```

Consider using `zfs-auto-snapshot` or your NAS vendor's snapshot tooling.

---

## Quick Reference: File Locations

| File | Purpose |
|------|---------|
| `/opt/stowkeeper/backup-runner.sh` | Main entry point for all operations |
| `/opt/stowkeeper/conf/pilot.conf` | Host configuration (manual deployments) |
| `/opt/stowkeeper/conf/maintenance.conf` | Maintenance host configuration |
| `/opt/stowkeeper/conf/.restic-password-nas` | NAS repository passphrase |
| `/opt/stowkeeper/conf/.restic-password-b2` | B2 repository passphrase |
| `/var/lib/stowkeeper/digest` | Daily digest notification queue |
| `/var/lib/stowkeeper/dedup` | Deduplication state for alerts |
| `/var/lib/prometheus/node-exporter/stowkeeper.prom` | Prometheus metrics textfile |
| `/etc/systemd/system/stowkeeper-*.timer` | systemd timer units |
| `/etc/systemd/system/stowkeeper-*.service` | systemd service units |
| `src/configs/pilot.conf` | Annotated configuration template |
| `src/configs/maintenance.conf` | Annotated maintenance template |
| `playbooks/deploy-backup.yml` | Ansible deployment playbook |
| `roles/backup_client/` | Ansible role for backup clients |
| `inventory/hosts` | Ansible inventory file |
| `inventory/host_vars/` | Per-host Ansible variables |

---

## Support

For issues not covered in this guide:

1. Check the logs: `sudo journalctl -u stowkeeper-backup-files.service`
2. Review the README: `README.md`
3. Inspect the configuration: `src/configs/pilot.conf`
4. Open an issue in the project repository

---

*Last updated: 2026-05-02*
