# Stowkeeper Inventory

## Groups

- `servers` — Production servers with dual-repo (NAS + B2)
- `workstations` — Developer workstations (NAS only, no DB)
- `db_hosts` — Subset of servers with database backups enabled

## Adding a Host

1. Add host to `inventory/hosts` under the appropriate group
2. Create `inventory/host_vars/<hostname>.yml` with:
   - `stowkeeper_backup_paths`: list of paths
   - `stowkeeper_db_type`: postgresql, mysql, or empty
3. Encrypt secrets with `ansible-vault encrypt host_vars/<hostname>.yml`

## Secrets

Secrets use the `vault_` prefix and must be encrypted:

- `vault_telegram_bot_token`
- `vault_telegram_chat_id`
- `vault_stowkeeper_role_id` / `vault_stowkeeper_secret_id` (Vault AppRole)
- `vault_stowkeeper_b2_app_key` (B2 application key)
- `vault_stowkeeper_smtp_pass` (SMTP password)

Encrypt with: `ansible-vault encrypt_string --name 'vault_telegram_bot_token' 'your-token'`
