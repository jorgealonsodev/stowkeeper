#!/usr/bin/env bash
# Stowkeeper Restore Test
# Quarterly integrity verification: restore latest snapshot, sample files,
# compare sha256sums against originals, emit metrics, notify on failure.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR="${SCRIPT_DIR}"
CONFIG_FILE="${CONFIG_FILE:-/opt/stowkeeper/conf/pilot.conf}"

# Source shared libraries
# shellcheck source=src/lib/stowkeeper-metrics.sh
source "${LIB_DIR}/stowkeeper-metrics.sh"
# shellcheck source=src/lib/stowkeeper-notify.sh
source "${LIB_DIR}/stowkeeper-notify.sh"
# shellcheck source=src/lib/stowkeeper-vault.sh
source "${LIB_DIR}/stowkeeper-vault.sh"
# shellcheck source=src/lib/stowkeeper-email.sh
source "${LIB_DIR}/stowkeeper-email.sh"

# Repo display-name mapping
declare -A REPO_DISPLAY=([nas]="nas-primary" [b2]="b2-secondary")

REPO="${1:-nas}"
RESTORE_DIR="${RESTORE_DIR:-/var/lib/stowkeeper/restore-test}"
SAMPLE_SIZE="${SAMPLE_SIZE:-20}"

usage() {
  cat <<EOF
Stowkeeper Restore Test

Usage:
  stowkeeper-restore-test.sh [repo]

Options:
  repo    Repository alias (nas|b2). Default: nas

Environment:
  RESTORE_DIR   Temp directory for restore. Default: /var/lib/stowkeeper/restore-test
  SAMPLE_SIZE   Number of files to sample. Default: 20
EOF
}

if [[ "${REPO}" == "--help" || "${REPO}" == "-h" ]]; then
  usage
  exit 0
fi

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}" >&2
    logger -t STOWKEEPER "Config file not found: ${CONFIG_FILE}"
    exit 3
  fi

  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  if [[ -z "${REPOS:-}" ]]; then
    REPOS=("nas")
  fi

  export DIGEST_DIR="${DIGEST_DIR:-/var/lib/stowkeeper/digest}"
  export DEDUP_DIR="${DEDUP_DIR:-/var/lib/stowkeeper/dedup}"
  export TELEGRAM_BOT_TOKEN
  export TELEGRAM_CHAT_ID
}

configure_repo() {
  local repo="$1"
  local repo_var="RESTIC_REPOSITORY_${repo}"
  local password_var="RESTIC_PASSWORD_FILE_${repo}"

  if [[ -n "${!repo_var:-}" ]]; then
    export RESTIC_REPOSITORY="${!repo_var}"
  fi
  if [[ -n "${!password_var:-}" ]]; then
    export RESTIC_PASSWORD_FILE="${!password_var}"
  fi

  if [[ "${RESTIC_REPOSITORY}" == s3:* || "${RESTIC_REPOSITORY}" == b2:* ]]; then
    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
  fi
}

authenticate_repo() {
  local repo="$1"

  if ! vault_authenticate "${repo}"; then
    local password_var="RESTIC_PASSWORD_FILE_${repo}"
    local fallback_password_file="${!password_var:-${RESTIC_PASSWORD_FILE:-}}"

    if [[ -n "${fallback_password_file}" && -f "${fallback_password_file}" ]]; then
      export RESTIC_PASSWORD_FILE="${fallback_password_file}"
      logger -t STOWKEEPER "Using env-file fallback for repo ${repo}"
    else
      echo "Password file not found for repo ${repo}: ${fallback_password_file:-}" >&2
      logger -t STOWKEEPER "Password file not found for repo ${repo}"
      return 4
    fi
  fi
}

# Parse a JSON field from restic JSON output (no external deps)
_json_field() {
  local json="$1"
  local field="$2"
  # Match "field":123 or "field":"value"
  echo "${json}" | sed -n "s/.*\"${field}\":\\([0-9]*\\).*/\\1/p" | head -1
}

cleanup() {
  if [[ -d "${RESTORE_DIR}" ]]; then
    rm -rf "${RESTORE_DIR}"
  fi
}

trap cleanup EXIT

main() {
  load_config

  local display_repo="${REPO_DISPLAY[$REPO]:-$REPO}"

  configure_repo "${REPO}"
  if ! authenticate_repo "${REPO}"; then
    emit_restore_test_metrics "${display_repo}" 0 0 0
    send_alert "restore-test" "${display_repo}" "failure" "Restore test auth failed for *${display_repo}*"
    exit 4
  fi

  # Get latest snapshot info
  local snapshot_json snapshot_id
  snapshot_json=$(restic snapshots --latest 1 --json 2>/dev/null || true)
  if [[ -z "${snapshot_json}" || "${snapshot_json}" == "[]" ]]; then
    emit_restore_test_metrics "${display_repo}" 0 0 0
    send_alert "restore-test" "${display_repo}" "failure" "No snapshots available for restore test on *${display_repo}*"
    exit 1
  fi

  snapshot_id=$(_json_field "${snapshot_json}" "id")
  if [[ -z "${snapshot_id}" ]]; then
    emit_restore_test_metrics "${display_repo}" 0 0 0
    send_alert "restore-test" "${display_repo}" "failure" "Could not parse snapshot ID from restic output"
    exit 1
  fi

  # Disk space pre-flight
  local repo_size available needed
  repo_size=$(restic stats latest --json 2>/dev/null | sed -n 's/.*"total_size":\([0-9]*\).*/\1/p' | head -1 || true)
  repo_size="${repo_size:-0}"

  if [[ "${repo_size}" -gt 0 ]]; then
    needed=$(( repo_size * 2 ))
    available=$(df -B1 "${RESTORE_DIR%/*}" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "${available}" && "${available}" -lt "${needed}" ]]; then
      send_alert "restore-test" "${display_repo}" "warning" "Insufficient disk space for restore test on *${display_repo}*: ${available} bytes available, need ${needed} bytes (2× repo size)"
      exit 1
    fi
  fi

  mkdir -p "${RESTORE_DIR}"

  # Restore latest snapshot
  if ! restic restore "${snapshot_id}" --target "${RESTORE_DIR}"; then
    emit_restore_test_metrics "${display_repo}" 0 0 0
    send_alert "restore-test" "${display_repo}" "failure" "Restore failed for snapshot ${snapshot_id} on *${display_repo}*"
    exit 1
  fi

  # Find all regular files under restore dir
  local all_files=()
  while IFS= read -r -d '' f; do
    all_files+=("${f}")
  done < <(find "${RESTORE_DIR}" -type f -print0 2>/dev/null)

  local total_restored=${#all_files[@]}
  if [[ "${total_restored}" -eq 0 ]]; then
    emit_restore_test_metrics "${display_repo}" 0 0 0
    send_alert "restore-test" "${display_repo}" "failure" "No files found in restored snapshot ${snapshot_id} on *${display_repo}*"
    exit 1
  fi

  # Sample files
  local sample_count="${SAMPLE_SIZE}"
  if [[ "${total_restored}" -lt "${sample_count}" ]]; then
    sample_count="${total_restored}"
  fi

  local sampled_files=()
  if command -v shuf >/dev/null 2>&1; then
    mapfile -t sampled_files < <(printf '%s\0' "${all_files[@]}" | shuf -z -n "${sample_count}" | tr '\0' '\n')
  else
    mapfile -t sampled_files < <(printf '%s\0' "${all_files[@]}" | sort -z -R | head -z -n "${sample_count}" | tr '\0' '\n')
  fi

  local matched=0
  local mismatched_details=()
  local f original sum_restored sum_original
  for f in "${sampled_files[@]}"; do
    original="${f#${RESTORE_DIR}}"
    if [[ ! -f "${original}" ]]; then
      mismatched_details+=("Missing original: ${original}")
      continue
    fi
    sum_restored=$(sha256sum "${f}" | awk '{print $1}')
    sum_original=$(sha256sum "${original}" | awk '{print $1}')
    if [[ "${sum_restored}" == "${sum_original}" ]]; then
      matched=$((matched + 1))
    else
      mismatched_details+=("Mismatch: ${original}")
    fi
  done

  local success=0
  if [[ "${matched}" -eq "${sample_count}" ]]; then
    success=1
  fi

  emit_restore_test_metrics "${display_repo}" "${success}" "${sample_count}" "${matched}"

  if [[ "${success}" -eq 0 ]]; then
    local details
    details=$(printf '%s; ' "${mismatched_details[@]}")
    send_alert "restore-test" "${display_repo}" "failure" "Restore test failed on *${display_repo}*: ${matched}/${sample_count} files matched. Details: ${details}"
    logger -t STOWKEEPER "Restore test failed on ${display_repo}: ${matched}/${sample_count} files matched"
    exit 1
  fi

  send_alert "restore-test" "${display_repo}" "success" "Restore test passed on *${display_repo}*: ${matched}/${sample_count} files matched"
  logger -t STOWKEEPER "Restore test passed on ${display_repo}: ${matched}/${sample_count} files matched"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
