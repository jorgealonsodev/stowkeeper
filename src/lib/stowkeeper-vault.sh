#!/usr/bin/env bash
# Stowkeeper Vault Authentication Library
# HashiCorp Vault AppRole authentication with KV v2 passphrase retrieval.
# Falls back to local RESTIC_PASSWORD_FILE_<repo> when Vault is unreachable.

set -euo pipefail

# In-memory Vault token cache
_VAULT_TOKEN=""
_VAULT_TOKEN_EXPIRY=0
_VAULT_TEMP_PASSWORD_FILE=""

# Array to track multiple temporary passphrase files (one per repo iteration)
_VAULT_TEMP_FILES=()

# Flag to ensure EXIT trap is registered only once per process
_VAULT_TRAP_REGISTERED=false

# Cleanup handler for the current temporary passphrase file
_vault_cleanup_tempfile() {
  if [[ -n "${_VAULT_TEMP_PASSWORD_FILE:-}" && -f "${_VAULT_TEMP_PASSWORD_FILE}" ]]; then
    rm -f "${_VAULT_TEMP_PASSWORD_FILE}"
  fi
  _VAULT_TEMP_PASSWORD_FILE=""
}

# Idempotent vault cleanup — safe to call multiple times.
# Removes all tracked temp files and resets state.
vault_cleanup() {
  local file
  for file in "${_VAULT_TEMP_FILES[@]}"; do
    if [[ -n "${file}" && -f "${file}" ]]; then
      rm -f "${file}"
    fi
  done
  _vault_cleanup_tempfile
  _VAULT_TEMP_FILES=()
}

# Register cleanup on EXIT (idempotent — safe to call multiple times).
# Saves any existing EXIT trap with trap -p and chains it after vault_cleanup.
_vault_register_cleanup() {
  if [[ "${_VAULT_TRAP_REGISTERED}" == "true" ]]; then
    return 0
  fi

  local existing_trap=""
  existing_trap=$(trap -p EXIT | sed "s/^trap -- '\(.*\)' EXIT$/\1/")

  if [[ -n "${existing_trap}" && "${existing_trap}" != "vault_cleanup" && "${existing_trap}" != *"vault_cleanup"* ]]; then
    # shellcheck disable=SC2064
    trap "vault_cleanup; ${existing_trap}" EXIT
  else
    trap 'vault_cleanup' EXIT
  fi

  _VAULT_TRAP_REGISTERED=true
}

# Authenticate to Vault using AppRole and retrieve the Restic passphrase.
# Usage: vault_authenticate <repo_name>
# Returns: 0 on success (RESTIC_PASSWORD_FILE set to temp file or env-file)
#          non-zero on failure (caller should fall back to env-file)
#
# On success, sets RESTIC_PASSWORD_FILE to a temp file (mode 0600) containing
# the passphrase. On failure, falls back to RESTIC_PASSWORD_FILE_${repo} from
# pilot.conf and logs a warning. Temp file cleanup is handled automatically
# via the EXIT trap registered on first successful Vault authentication.
vault_authenticate() {
  local repo="$1"
  local vault_addr="${VAULT_ADDR:-}"
  local role_id_var="VAULT_ROLE_ID_stowkeeper_${repo}"
  local secret_id_var="VAULT_SECRET_ID_stowkeeper_${repo}"
  local role_id="${!role_id_var:-}"
  local secret_id="${!secret_id_var:-}"
  local password_file_var="RESTIC_PASSWORD_FILE_${repo}"
  local fallback_password_file="${!password_file_var:-${RESTIC_PASSWORD_FILE:-}}"

  # If Vault is not configured, use fallback immediately
  if [[ -z "${vault_addr}" || -z "${role_id}" || -z "${secret_id}" ]]; then
    if [[ -n "${fallback_password_file}" && -f "${fallback_password_file}" ]]; then
      export RESTIC_PASSWORD_FILE="${fallback_password_file}"
      logger -t STOWKEEPER "Vault not configured for repo ${repo}; using env-file fallback"
      return 0
    else
      echo "Vault not configured and fallback password file missing for repo ${repo}" >&2
      logger -t STOWKEEPER "Vault not configured and fallback password file missing for repo ${repo}"
      return 4
    fi
  fi

  # Check if cached token is still valid (TTL >= 5 minutes)
  local now
  now=$(date +%s)
  if [[ -n "${_VAULT_TOKEN:-}" && ${_VAULT_TOKEN_EXPIRY} -gt $((now + 300)) ]]; then
    logger -t STOWKEEPER "Vault token cache valid for repo ${repo}; reusing"
  else
    # Attempt AppRole login with 10-second timeout
    local login_response
    login_response=$(
      curl -s -S --max-time 10 -X POST \
        "${vault_addr}/v1/auth/approle/login" \
        -d "{\"role_id\":\"${role_id}\",\"secret_id\":\"${secret_id}\"}" \
        -H "Content-Type: application/json" 2>&1
    ) || {
      local curl_exit=$?
      echo "Vault login request failed (curl exit ${curl_exit}) for repo ${repo}" >&2
      logger -t STOWKEEPER "Vault login request failed (curl exit ${curl_exit}) for repo ${repo}; falling back to env-file"
      _vault_fallback "${repo}" "${fallback_password_file}"
      return $?
    }

    # Check for errors in the response
    if echo "${login_response}" | grep -q '"errors"'; then
      echo "Vault AppRole login failed for repo ${repo}: ${login_response}" >&2
      logger -t STOWKEEPER "Vault AppRole login failed for repo ${repo}; falling back to env-file"
      _vault_fallback "${repo}" "${fallback_password_file}"
      return $?
    fi

    # Extract token and lease_duration
    local token lease_duration
    token=$(echo "${login_response}" | sed -n 's/.*"client_token":"\([^"]*\)".*/\1/p' | head -1 || true)
    lease_duration=$(echo "${login_response}" | sed -n 's/.*"lease_duration":\([0-9]*\).*/\1/p' | head -1 || true)
    lease_duration="${lease_duration:-3600}"

    if [[ -z "${token}" ]]; then
      echo "Vault login response missing client_token for repo ${repo}" >&2
      logger -t STOWKEEPER "Vault login response missing client_token for repo ${repo}; falling back to env-file"
      _vault_fallback "${repo}" "${fallback_password_file}"
      return $?
    fi

    _VAULT_TOKEN="${token}"
    now=$(date +%s)
    _VAULT_TOKEN_EXPIRY=$((now + lease_duration))
    logger -t STOWKEEPER "Vault AppRole login succeeded for repo ${repo}; token TTL=${lease_duration}s"
  fi

  # Retrieve passphrase from KV v2
  local kv_response
  kv_response=$(
    curl -s -S --max-time 10 -X GET \
      "${vault_addr}/v1/secret/data/stowkeeper/${repo}" \
      -H "X-Vault-Token: ${_VAULT_TOKEN}" \
      -H "Content-Type: application/json" 2>&1
  ) || {
    local curl_exit=$?
    echo "Vault KV read failed (curl exit ${curl_exit}) for repo ${repo}" >&2
    logger -t STOWKEEPER "Vault KV read failed (curl exit ${curl_exit}) for repo ${repo}; falling back to env-file"
    _vault_fallback "${repo}" "${fallback_password_file}"
    return $?
  }

  # Check for KV errors (404 or permission denied)
  if echo "${kv_response}" | grep -q '"errors"'; then
    echo "Vault KV path not found or permission denied for repo ${repo}: ${kv_response}" >&2
    logger -t STOWKEEPER "Vault KV path not found for repo ${repo}; falling back to env-file"
    _vault_fallback "${repo}" "${fallback_password_file}"
    return $?
  fi

  # Extract passphrase from KV v2 response (.data.data.passphrase)
  local passphrase
  passphrase=$(echo "${kv_response}" | sed -n 's/.*"passphrase":"\([^"]*\)".*/\1/p' | head -1 || true)

  if [[ -z "${passphrase}" ]]; then
    echo "Vault KV response missing passphrase for repo ${repo}" >&2
    logger -t STOWKEEPER "Vault KV response missing passphrase for repo ${repo}; falling back to env-file"
    _vault_fallback "${repo}" "${fallback_password_file}"
    return $?
  fi

  # Write passphrase to temp file with mode 0600
  _vault_cleanup_tempfile
  _VAULT_TEMP_PASSWORD_FILE=$(mktemp /tmp/stowkeeper-vault-pass-XXXXXX)
  chmod 600 "${_VAULT_TEMP_PASSWORD_FILE}"
  printf '%s' "${passphrase}" > "${_VAULT_TEMP_PASSWORD_FILE}"
  export RESTIC_PASSWORD_FILE="${_VAULT_TEMP_PASSWORD_FILE}"
  _VAULT_TEMP_FILES+=("${_VAULT_TEMP_PASSWORD_FILE}")
  _vault_register_cleanup

  logger -t STOWKEEPER "Vault passphrase retrieved successfully for repo ${repo}"
  return 0
}

# Internal: fall back to local password file
_vault_fallback() {
  local repo="$1"
  local fallback_password_file="$2"

  if [[ -n "${fallback_password_file}" && -f "${fallback_password_file}" ]]; then
    export RESTIC_PASSWORD_FILE="${fallback_password_file}"
    logger -t STOWKEEPER "Vault fallback active for repo ${repo}; using ${fallback_password_file}"
    return 0
  else
    echo "Vault fallback failed: no password file available for repo ${repo}" >&2
    logger -t STOWKEEPER "Vault fallback failed: no password file available for repo ${repo}"
    return 4
  fi
}
