#!/usr/bin/env bash
# Stowkeeper Backup Runner
# Central wrapper for all Restic operations on the pilot host.
# Usage: backup-runner.sh <init|backup|restore|snapshots|check|digest|maintenance> [options]

set -euo pipefail

# Paths
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG_FILE="${CONFIG_FILE:-/opt/stowkeeper/conf/pilot.conf}"
LOCK_FILE="${LOCK_FILE:-/var/lock/stowkeeper-backup.lock}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-60}"
HOSTNAME=$(hostname)

# Runtime state
LOCK_FD=""
DB_DUMP_FILE=""
BACKUP_EXIT_CODE=0
BACKUP_DURATION=0
BACKUP_SIZE=0
BACKUP_FILES_NEW=0
BACKUP_STDERR_EXCERPT=""

# Per-repo tracking for dual-repo loop
OVERALL_EXIT_CODE=0

# Repo display-name mapping (spec requires nas-primary / b2-secondary)
declare -A REPO_DISPLAY=([nas]="nas-primary" [b2]="b2-secondary")

# Source libraries
# shellcheck source=src/lib/stowkeeper-metrics.sh
source "${LIB_DIR}/stowkeeper-metrics.sh"
# shellcheck source=src/lib/stowkeeper-notify.sh
source "${LIB_DIR}/stowkeeper-notify.sh"
# shellcheck source=src/lib/stowkeeper-vault.sh
source "${LIB_DIR}/stowkeeper-vault.sh"
# shellcheck source=src/lib/stowkeeper-email.sh
source "${LIB_DIR}/stowkeeper-email.sh"

usage() {
  cat <<EOF
Stowkeeper Backup Runner

Usage:
  backup-runner.sh init [--repo <nas|b2>]
  backup-runner.sh backup --job <db|files|config>
  backup-runner.sh restore --snapshot <id> --target <path> [--path <subpath>]
  backup-runner.sh snapshots [--host <hostname>]
  backup-runner.sh check [--with-prune] [--read-data]
  backup-runner.sh digest
  backup-runner.sh maintenance [--with-prune]

Exit codes:
  0   Success
  1   Restic error
  3   Config error
  4   Auth / passphrase error
  75  Lock contention / timeout (flock)
EOF
}

cleanup() {
  if [[ -n "${LOCK_FD}" ]]; then
    flock -u "${LOCK_FD}" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
  fi
  if [[ -n "${DB_DUMP_FILE:-}" && -f "${DB_DUMP_FILE}" ]]; then
    rm -f "${DB_DUMP_FILE}"
  fi
  # Clean up any Vault temporary passphrase files
  if type _vault_cleanup_tempfile &>/dev/null; then
    _vault_cleanup_tempfile
  fi
}

trap cleanup EXIT

# Exit 75 covers both lock timeout and contention
acquire_lock() {
  eval "exec {LOCK_FD}>${LOCK_FILE}"
  if ! flock --timeout "${LOCK_TIMEOUT}" "${LOCK_FD}"; then
    echo "Lock contention: could not acquire lock within ${LOCK_TIMEOUT}s" >&2
    logger -t STOWKEEPER "Lock contention on ${LOCK_FILE}"
    exit 75
  fi
}

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}" >&2
    logger -t STOWKEEPER "Config file not found: ${CONFIG_FILE}"
    exit 3
  fi

  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  # Default REPOS for backward compatibility (single-repo mode)
  if [[ -z "${REPOS:-}" ]]; then
    REPOS=("nas")
  fi

  # Export for library use
  export DIGEST_DIR="${DIGEST_DIR:-/var/lib/stowkeeper/digest}"
  export DEDUP_DIR="${DEDUP_DIR:-/var/lib/stowkeeper/dedup}"
  export TELEGRAM_BOT_TOKEN
  export TELEGRAM_CHAT_ID
}

# Configure per-repo environment variables
# Usage: configure_repo <repo_name>
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

  # Set B2 credentials for S3 backend
  if [[ "${RESTIC_REPOSITORY}" == s3:* || "${RESTIC_REPOSITORY}" == b2:* ]]; then
    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
  fi
}

# Authenticate for a specific repo using Vault or fallback
# Usage: authenticate_repo <repo_name>
authenticate_repo() {
  local repo="$1"

  # Attempt Vault authentication (falls back to env-file internally)
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

init_repo() {
  if restic snapshots >/dev/null 2>&1; then
    echo "Repository already initialized at ${RESTIC_REPOSITORY}"
    logger -t STOWKEEPER "Repository already initialized at ${RESTIC_REPOSITORY}"
    return 0
  fi

  echo "Initializing repository at ${RESTIC_REPOSITORY} ..."
  if ! restic init; then
    echo "Failed to initialize repository" >&2
    logger -t STOWKEEPER "Failed to initialize repository"
    return 1
  fi

  echo "Repository initialized successfully"
  logger -t STOWKEEPER "Repository initialized at ${RESTIC_REPOSITORY}"
}

run_backup() {
  local job="$1"
  local -n paths="BACKUP_PATHS_${job^^}"

  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "No paths configured for job: ${job}" >&2
    logger -t STOWKEEPER "No paths configured for job: ${job}"
    BACKUP_EXIT_CODE=3
    return
  fi

  local restic_args=()
  if [[ -n "${EXCLUDE_FILE:-}" && -f "${EXCLUDE_FILE}" ]]; then
    restic_args+=(--exclude-file "${EXCLUDE_FILE}")
  fi

  local start_time end_time logfile
  start_time=$(date +%s)
  logfile=$(mktemp /tmp/stowkeeper-backup-XXXXXX.log)

  # SFTP auth pre-check
  if [[ "${RESTIC_REPOSITORY}" == sftp:* ]]; then
    local sftp_conn="${RESTIC_REPOSITORY#sftp:}"
    sftp_conn="${sftp_conn#/}"
    sftp_conn="${sftp_conn#/}"
    local sftp_host="${sftp_conn#*@}"
    sftp_host="${sftp_host%%[:/]*}"
    if [[ -n "${sftp_host}" ]]; then
      if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${sftp_host}" true >/dev/null 2>&1; then
        echo "SFTP authentication/connection failed for ${sftp_host}" >&2
        logger -t STOWKEEPER "SFTP authentication/connection failed for ${sftp_host}"
        BACKUP_EXIT_CODE=4
        return
      fi
    fi
  fi

  if [[ "${job}" == "db" ]]; then
    run_db_backup "${logfile}" "${restic_args[@]+"${restic_args[@]}"}"
  else
    set +e
    restic backup --host "${HOSTNAME}" --tag "${job}" \
      "${paths[@]}" "${restic_args[@]+"${restic_args[@]}"}" \
      >"${logfile}" 2>&1
    BACKUP_EXIT_CODE=$?
    set -e
  fi

  end_time=$(date +%s)
  BACKUP_DURATION=$((end_time - start_time))

  if [[ ${BACKUP_EXIT_CODE} -eq 0 ]]; then
    BACKUP_FILES_NEW=$(grep '"message_type":"summary"' "${logfile}" 2>/dev/null | \
      sed -n 's/.*"files_new":\([0-9]*\).*/\1/p' | head -1 || true)
    BACKUP_FILES_NEW="${BACKUP_FILES_NEW:-0}"

    local size_raw
    size_raw=$(restic stats latest --json 2>/dev/null | \
      sed -n 's/.*"total_size":\([0-9]*\).*/\1/p' | head -1 || true)
    BACKUP_SIZE="${size_raw:-0}"
  fi

  if [[ -f "${logfile}" ]]; then
    BACKUP_STDERR_EXCERPT=$(tail -n 10 "${logfile}" 2>/dev/null || true)
  fi
  rm -f "${logfile}"
}

run_db_backup() {
  local logfile="$1"
  shift
  local restic_args=("$@")

  local db_type="${DB_TYPE:-postgresql}"
  local db_host="${DB_HOST:-localhost}"
  local db_user="${DB_USER:-postgres}"
  local db_name="${DB_NAME:-}"
  local use_stdin="${DB_USE_STDIN:-false}"

  if [[ "${use_stdin}" == "true" ]]; then
    set +e
    case "${db_type}" in
      postgresql)
        pg_dump -h "${db_host}" -U "${db_user}" -d "${db_name}" 2>/dev/null | \
          restic backup --stdin --stdin-filename "db-${db_name}.sql" \
            --host "${HOSTNAME}" --tag "db" >"${logfile}" 2>&1
        ;;
      mysql)
        mysqldump -h "${db_host}" -u "${db_user}" -p"${DB_PASSWORD:-}" "${db_name}" 2>/dev/null | \
          restic backup --stdin --stdin-filename "db-${db_name}.sql" \
            --host "${HOSTNAME}" --tag "db" >"${logfile}" 2>&1
        ;;
      *)
        echo "Unsupported DB type for stdin: ${db_type}" >&2
        BACKUP_EXIT_CODE=3
        return
        ;;
    esac
    BACKUP_EXIT_CODE=${PIPESTATUS[1]}
    set -e
  else
    DB_DUMP_FILE=$(mktemp /tmp/stowkeeper-db-XXXXXX.dump)

    case "${db_type}" in
      postgresql)
        pg_dump -h "${db_host}" -U "${db_user}" -d "${db_name}" -Fc \
          >"${DB_DUMP_FILE}" 2>/dev/null || {
          echo "Database dump failed" >&2
          logger -t STOWKEEPER "Database dump failed for ${db_name}"
          BACKUP_EXIT_CODE=1
          return
        }
        ;;
      mysql)
        mysqldump -h "${db_host}" -u "${db_user}" -p"${DB_PASSWORD:-}" "${db_name}" \
          >"${DB_DUMP_FILE}" 2>/dev/null || {
          echo "Database dump failed" >&2
          logger -t STOWKEEPER "Database dump failed for ${db_name}"
          BACKUP_EXIT_CODE=1
          return
        }
        ;;
      *)
        echo "Unsupported DB type: ${db_type}" >&2
        BACKUP_EXIT_CODE=3
        return
        ;;
    esac

    set +e
    restic backup --host "${HOSTNAME}" --tag "db" \
      "${DB_DUMP_FILE}" "${restic_args[@]+"${restic_args[@]}"}" \
      >"${logfile}" 2>&1
    BACKUP_EXIT_CODE=$?
    set -e
  fi
}

list_snapshots() {
  local host_filter="${1:-${HOSTNAME}}"
  restic snapshots --host "${host_filter}"
}

restore_snapshot() {
  local snapshot_id="$1"
  local target_path="$2"
  local path_filter="${3:-}"

  if [[ -z "${snapshot_id}" || -z "${target_path}" ]]; then
    echo "Missing required argument: --snapshot and --target" >&2
    exit 3
  fi

  local restic_args=(restore "${snapshot_id}" --target "${target_path}")
  if [[ -n "${path_filter}" ]]; then
    restic_args+=(--include "${path_filter}")
  fi

  restic "${restic_args[@]}"
}

run_check() {
  local deep_subset="${1:-}"
  if [[ -n "${deep_subset}" ]]; then
    restic check --read-data-subset="${deep_subset}"
  else
    restic check
  fi
}

# Determine whether deep-check conditions are met and return the subset string
# Returns: "N0%" if day ≤ 7 and counter matches month%10, otherwise empty string
get_deep_check_subset() {
  local day month counter
  day=$(date +%d)
  month=$(date +%m)
  month=${month#0}
  counter=$(read_deep_check_counter)

  if [[ "${day}" -le 7 && "${counter}" -eq $(( month % 10 )) ]]; then
    echo "${counter}0%"
  else
    echo ""
  fi
}

run_forget() {
  local prune_flag="${1:-}"

  if [[ -z "${RETENTION_POLICY:-}" ]]; then
    echo "RETENTION_POLICY not configured; skipping forget" >&2
    logger -t STOWKEEPER "RETENTION_POLICY not configured; skipping forget"
    return 0
  fi

  local retention_args=()
  read -r -a retention_args <<< "${RETENTION_POLICY}"

  local forget_args=(forget "${retention_args[@]}")
  if [[ "${prune_flag}" == "--prune" ]]; then
    forget_args+=("--prune")
  fi

  if ! restic "${forget_args[@]}"; then
    echo "restic forget failed" >&2
    logger -t STOWKEEPER "restic forget failed"
    return 1
  fi
}

# Determine the worst exit code across repos.
# Priority: 4 > 3 > 1 > 75 > 2 > 0
# Usage: aggregate_exit_code <current_aggregate> <repo_exit_code>
aggregate_exit_code() {
  local current="$1"
  local repo_exit="$2"

  if [[ ${repo_exit} -eq 0 ]]; then
    echo "${current}"
    return
  fi

  local priority_current priority_repo
  priority_current=$(exit_code_priority "${current}")
  priority_repo=$(exit_code_priority "${repo_exit}")

  if [[ ${priority_repo} -lt ${priority_current} ]]; then
    echo "${repo_exit}"
  else
    echo "${current}"
  fi
}

# Numeric priority for exit codes (lower = higher priority / more severe)
exit_code_priority() {
  local code="$1"
  case "${code}" in
    4) echo 1 ;;
    3) echo 2 ;;
    1) echo 3 ;;
    75) echo 4 ;;
    2) echo 5 ;;
    0) echo 6 ;;
    *) echo 7 ;;  # unknown codes are least severe
  esac
}

emit_result_metrics() {
  local job="$1"
  local repo="$2"
  local status="$3"
  local last_success_ts="$4"

  emit_backup_metrics "${HOSTNAME}" "${job}" "${repo}" \
    "${status}" "${BACKUP_DURATION}" "${BACKUP_SIZE}" \
    "${BACKUP_FILES_NEW}" "${last_success_ts}"
}

handle_backup_result() {
  local job="$1"
  local repo="$2"
  local display_repo="${REPO_DISPLAY[$repo]:-$repo}"

  if [[ ${BACKUP_EXIT_CODE} -eq 0 ]]; then
    local now
    now=$(date +%s)
    emit_result_metrics "${job}" "${display_repo}" 1 "${now}"
    emit_repo_size_metrics "${display_repo}" "${BACKUP_SIZE}"
    append_digest "${job}" "${display_repo}" "${now}" "${BACKUP_DURATION}" "${BACKUP_SIZE}"
    logger -t STOWKEEPER "Backup ${job} on ${repo} completed successfully in ${BACKUP_DURATION}s"
  else
    local last_ts=0
    if [[ -f "${METRICS_FILE}" ]]; then
      last_ts=$(grep "stowkeeper_backup_last_success_timestamp{.*job=\"${job}\".*repo=\"${display_repo}\"}" "${METRICS_FILE}" 2>/dev/null | \
        sed -n 's/.*} \([0-9]*\).*/\1/p' | head -1 || true)
      last_ts="${last_ts:-0}"
    fi
    emit_result_metrics "${job}" "${display_repo}" 0 "${last_ts}"

    local stderr_excerpt="${BACKUP_STDERR_EXCERPT:-}"
    if [[ -n "${stderr_excerpt}" ]]; then
      stderr_excerpt=$'\n'"Stderr (last 10 lines):${stderr_excerpt}"
    fi
    send_alert "${job}" "${display_repo}" "failure" "Backup failed: exit code ${BACKUP_EXIT_CODE}${stderr_excerpt}"
    logger -t STOWKEEPER "Backup ${job} on ${repo} failed with exit code ${BACKUP_EXIT_CODE}"
  fi
}

handle_check_result() {
  local exit_code="$1"
  local repo="$2"
  local display_repo="${REPO_DISPLAY[$repo]:-$repo}"

  if [[ ${exit_code} -eq 0 ]]; then
    local now
    now=$(date +%s)
    emit_check_metrics "${display_repo}" "${now}"
    logger -t STOWKEEPER "Repository check on ${repo} completed successfully"
  else
    local last_ts=0
    if [[ -f "${METRICS_FILE}" ]]; then
      last_ts=$(grep "stowkeeper_check_last_success_timestamp{.*repo=\"${display_repo}\"}" "${METRICS_FILE}" 2>/dev/null | \
        sed -n 's/.*} \([0-9]*\).*/\1/p' | head -1 || true)
      last_ts="${last_ts:-0}"
    fi
    emit_check_metrics "${display_repo}" "${last_ts}"
    send_alert "check" "${display_repo}" "failure" "Repository check failed: exit code ${exit_code}"
    logger -t STOWKEEPER "Repository check on ${repo} failed with exit code ${exit_code}"
  fi
}

# Run maintenance (forget --prune + check) on a single repo.
# Usage: run_maintenance <repo> [with_prune]
run_maintenance() {
  local repo="$1"
  local with_prune="${2:-false}"
  local display_repo="${REPO_DISPLAY[$repo]:-$repo}"
  local maintenance_exit=0

  configure_repo "${repo}"
  if ! authenticate_repo "${repo}"; then
    send_alert "maintenance" "${display_repo}" "failure" "Maintenance auth failed for *${display_repo}*"
    return 4
  fi

  set +e
  if [[ "${with_prune}" == "true" ]]; then
    run_forget --prune
    maintenance_exit=$?
  else
    maintenance_exit=0
  fi
  if [[ ${maintenance_exit} -eq 0 ]]; then
    run_check
    maintenance_exit=$?
  fi
  set -e

  if [[ ${maintenance_exit} -eq 0 ]]; then
    local now
    now=$(date +%s)
    emit_maintenance_metrics "${display_repo}" 1 "${now}"
    logger -t STOWKEEPER "Maintenance on ${repo} completed successfully"
  else
    emit_maintenance_metrics "${display_repo}" 0 0
    send_alert "maintenance" "${display_repo}" "failure" "Maintenance failed: exit code ${maintenance_exit}"
    logger -t STOWKEEPER "Maintenance on ${repo} failed with exit code ${maintenance_exit}"
  fi

  return ${maintenance_exit}
}

# Emit maintenance metrics
# Usage: emit_maintenance_metrics <repo> <status> <last_success_ts>
emit_maintenance_metrics() {
  local repo="$1"
  local status="$2"
  local last_success_ts="$3"

  local metrics
  metrics=$(cat <<EOF
# HELP stowkeeper_maintenance_status 1 for success, 0 for failure
# TYPE stowkeeper_maintenance_status gauge
stowkeeper_maintenance_status{repo="${repo}"} ${status}
# HELP stowkeeper_maintenance_last_success_timestamp Unix timestamp of last successful maintenance
# TYPE stowkeeper_maintenance_last_success_timestamp gauge
stowkeeper_maintenance_last_success_timestamp{repo="${repo}"} ${last_success_ts}
EOF
)

  # Merge with existing metrics, preserving backup and check metrics
  local existing_metrics=""
  if [[ -f "${METRICS_FILE}" ]]; then
    existing_metrics=$(grep -v 'stowkeeper_maintenance' "${METRICS_FILE}" 2>/dev/null || true)
  fi

  local combined_metrics
  if [[ -n "${existing_metrics}" ]]; then
    combined_metrics="${existing_metrics}"$'\n'"${metrics}"
  else
    combined_metrics="${metrics}"
  fi

  write_metrics_file "${combined_metrics}"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 3
  fi

  local cmd="$1"
  shift

  local job=""
  local snapshot_id=""
  local target_path=""
  local restore_path=""
  local snapshot_host=""
  local repo_flag=""
  local with_prune=false
  local read_data_flag=false

  # Parse command-specific arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job)
        job="$2"
        shift 2
        ;;
      --snapshot)
        snapshot_id="$2"
        shift 2
        ;;
      --target)
        target_path="$2"
        shift 2
        ;;
      --path)
        restore_path="$2"
        shift 2
        ;;
      --host)
        snapshot_host="$2"
        shift 2
        ;;
      --repo)
        repo_flag="$2"
        shift 2
        ;;
      --with-prune)
        with_prune=true
        shift
        ;;
      --read-data)
        read_data_flag=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 3
        ;;
    esac
  done

  case "${cmd}" in
    init)
      acquire_lock
      load_config
      if [[ -n "${repo_flag}" ]]; then
        configure_repo "${repo_flag}"
        authenticate_repo "${repo_flag}"
        init_repo
      else
        # Initialize all configured repos sequentially
        local repo
        for repo in "${REPOS[@]}"; do
          configure_repo "${repo}"
          authenticate_repo "${repo}"
          init_repo
        done
      fi
      ;;

    backup)
      if [[ -z "${job}" ]]; then
        echo "Missing required option: --job" >&2
        usage
        exit 3
      fi
      acquire_lock
      load_config
      OVERALL_EXIT_CODE=0
      local repo
      for repo in "${REPOS[@]}"; do
        local display_repo="${REPO_DISPLAY[$repo]:-$repo}"
        BACKUP_EXIT_CODE=0
        BACKUP_DURATION=0
        BACKUP_SIZE=0
        BACKUP_FILES_NEW=0
        BACKUP_STDERR_EXCERPT=""

        configure_repo "${repo}"
        if ! authenticate_repo "${repo}"; then
          BACKUP_EXIT_CODE=4
          handle_backup_result "${job}" "${repo}"
          OVERALL_EXIT_CODE=$(aggregate_exit_code "${OVERALL_EXIT_CODE}" 4)
          continue
        fi

        run_backup "${job}"
        track_backup_duration "${BACKUP_DURATION}"
        if is_slow_backup "${BACKUP_DURATION}"; then
          send_alert "${job}" "${display_repo}" "warning" "Backup slow: ${BACKUP_DURATION}s (>2× median of ${SLOW_BACKUP_THRESHOLD}s). Possible I/O degradation or unusual data volume."
        fi
        handle_backup_result "${job}" "${repo}"
        OVERALL_EXIT_CODE=$(aggregate_exit_code "${OVERALL_EXIT_CODE}" "${BACKUP_EXIT_CODE}")

        # Clean up Vault temp file between repos to avoid leakage
        _vault_cleanup_tempfile
      done
      exit "${OVERALL_EXIT_CODE}"
      ;;

    restore)
      if [[ -z "${snapshot_id}" || -z "${target_path}" ]]; then
        echo "Missing required option: --snapshot and --target" >&2
        usage
        exit 3
      fi
      acquire_lock
      load_config
      # Restore operates on the first/default repo for simplicity
      configure_repo "${REPOS[0]}"
      authenticate_repo "${REPOS[0]}"
      restore_snapshot "${snapshot_id}" "${target_path}" "${restore_path}"
      ;;

    snapshots)
      load_config
      configure_repo "${REPOS[0]}"
      authenticate_repo "${REPOS[0]}"
      list_snapshots "${snapshot_host}"
      ;;

    check)
      acquire_lock
      load_config
      OVERALL_EXIT_CODE=0
      local repo check_exit=0
      for repo in "${REPOS[@]}"; do
        configure_repo "${repo}"
        if ! authenticate_repo "${repo}"; then
          handle_check_result 4 "${repo}"
          OVERALL_EXIT_CODE=$(aggregate_exit_code "${OVERALL_EXIT_CODE}" 4)
          continue
        fi
        set +e
        if [[ "${with_prune}" == "true" ]]; then
          run_forget --prune
        fi
        local deep_subset=""
        if [[ "${read_data_flag}" == "true" ]]; then
          deep_subset=$(get_deep_check_subset)
        fi
        run_check "${deep_subset}"
        check_exit=$?
        if [[ ${check_exit} -eq 0 && -n "${deep_subset}" ]]; then
          local now
          now=$(date +%s)
          emit_deep_check_metrics "${REPO_DISPLAY[$repo]:-$repo}" "${now}"
          local new_counter=$(( ($(read_deep_check_counter) + 1) % 10 ))
          write_deep_check_counter "${new_counter}"
        fi
        set -e
        handle_check_result "${check_exit}" "${repo}"
        OVERALL_EXIT_CODE=$(aggregate_exit_code "${OVERALL_EXIT_CODE}" "${check_exit}")
        _vault_cleanup_tempfile
      done
      exit "${OVERALL_EXIT_CODE}"
      ;;

    digest)
      acquire_lock
      load_config
      # Digest runs forget (no prune) and sends queued success messages
      configure_repo "${REPOS[0]}"
      authenticate_repo "${REPOS[0]}"
      run_forget
      send_digest
      ;;

    maintenance)
      acquire_lock
      load_config
      local maintenance_repo="${MAINTENANCE_REPO:-b2}"
      run_maintenance "${maintenance_repo}" "${with_prune}"
      ;;

    --help|-h)
      usage
      exit 0
      ;;

    *)
      echo "Unknown command: ${cmd}" >&2
      usage
      exit 3
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
