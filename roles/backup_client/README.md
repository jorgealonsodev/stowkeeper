# Stowkeeper Backup Client — Ansible Role

Deploys the Stowkeeper backup pipeline to Linux hosts.

## Requirements

- Ansible 2.12+
- Target: Ubuntu 22.04/24.04 or Debian 12
- Internal Restic mirror with SHA256 checksums

## Variables

### Required

| Variable | Description |
|----------|-------------|
| `stowkeeper_backup_paths` | List of paths to back up |
| `stowkeeper_nas_host` | NAS SFTP hostname |
| `stowkeeper_nas_user` | NAS SFTP user |
| `stowkeeper_nas_path` | NAS repository path |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `stowkeeper_repos` | `["nas"]` | Repos to use: nas, b2 |
| `stowkeeper_db_type` | `""` | postgresql, mysql, or empty |
| `stowkeeper_notification_level` | `full` | full or failures_only |

## Example Playbook

```yaml
- hosts: servers
  become: yes
  roles:
    - backup_client
```

## Example Host Vars

```yaml
stowkeeper_backup_paths:
  - /etc
  - /var/www
  - /home
stowkeeper_db_type: postgresql
stowkeeper_db_name: myapp
```

## Notes

- Maintenance timer is NOT deployed by this role (separate maintenance host)
- Secrets must be Ansible-vault encrypted in host_vars
- Restic is downloaded from internal mirror only (never internet)
