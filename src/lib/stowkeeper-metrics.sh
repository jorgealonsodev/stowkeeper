#!/usr/bin/env bash
# Stowkeeper Prometheus Metrics Library
# Writes metrics atomically to a .prom file for node_exporter textfile collector.

set -euo pipefail

# Auto-detect node_exporter textfile collector directory if METRICS_FILE not explicitly set
if [[ -z "${METRICS_FILE:-}" ]]; then
  for dir in /var/lib/prometheus/node-exporter /var/lib/node_exporter/textfile_collector /opt/prometheus/textfile; do
    if [[ -d "${dir}" ]]; then
      METRICS_FILE="${dir}/stowkeeper.prom"
      break
    fi
  done
  if [[ -z "${METRICS_FILE:-}" ]]; then
    METRICS_FILE="/var/lib/prometheus/node-exporter/stowkeeper.prom"
    echo "Warning: Could not auto-detect node_exporter textfile collector directory; falling back to ${METRICS_FILE}" >&2
    logger -t STOWKEEPER "Could not auto-detect node_exporter textfile collector directory; falling back to ${METRICS_FILE}"
  fi
fi

# Write metrics atomically using temp file + rename
# Usage: write_metrics_file <content>
write_metrics_file() {
  local content="$1"
  local tmpfile
  tmpfile="${METRICS_FILE}.tmp.$$"

  # Ensure parent directory exists
  local parent_dir
  parent_dir=$(dirname "${METRICS_FILE}")
  if [[ ! -d "${parent_dir}" ]]; then
    mkdir -p "${parent_dir}" || {
      echo "Failed to create metrics directory: ${parent_dir}" >&2
      return 1
    }
  fi

  printf '%s\n' "${content}" > "${tmpfile}"
  mv -f "${tmpfile}" "${METRICS_FILE}"
}

# Track backup duration for historical median calculation
# Usage: track_backup_duration <duration_seconds>
track_backup_duration() {
  local duration="$1"
  local runtime_dir="${RUNTIME_DIR:-/var/lib/stowkeeper}"
  local history_file="${runtime_dir}/backup-durations.log"

  mkdir -p "${runtime_dir}"

  local now
  now=$(date +%s)
  printf '%s,%s\n' "${now}" "${duration}" >> "${history_file}"

  # Trim to last 30 entries
  local line_count
  line_count=$(wc -l < "${history_file}" 2>/dev/null || echo 0)
  if [[ "${line_count}" -gt 30 ]]; then
    tail -n 30 "${history_file}" > "${history_file}.tmp"
    mv -f "${history_file}.tmp" "${history_file}"
  fi
}

# Check if current backup duration exceeds 2× historical median
# Usage: is_slow_backup <current_duration_seconds>
# Returns 0 if slow, 1 otherwise. Sets SLOW_BACKUP_THRESHOLD on success.
is_slow_backup() {
  local current_duration="$1"
  local runtime_dir="${RUNTIME_DIR:-/var/lib/stowkeeper}"
  local history_file="${runtime_dir}/backup-durations.log"

  SLOW_BACKUP_THRESHOLD=0

  if [[ ! -f "${history_file}" ]]; then
    return 1
  fi

  local durations=()
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    local dur="${line#*,}"
    if [[ -n "${dur}" && "${dur}" =~ ^[0-9]+$ ]]; then
      durations+=("${dur}")
    fi
  done < "${history_file}"

  local count=${#durations[@]}
  if [[ "${count}" -lt 2 ]]; then
    return 1
  fi

  # Bubble sort
  local i j tmp
  for ((i=0; i<count-1; i++)); do
    for ((j=0; j<count-1-i; j++)); do
      if [[ "${durations[j]}" -gt "${durations[j+1]}" ]]; then
        tmp="${durations[j]}"
        durations[j]="${durations[j+1]}"
        durations[j+1]="${tmp}"
      fi
    done
  done

  local median
  if (( count % 2 == 0 )); then
    local mid=$((count / 2))
    median=$(((durations[mid - 1] + durations[mid]) / 2))
  else
    median="${durations[$((count / 2))]}"
  fi

  local threshold=$((median * 2))
  # shellcheck disable=SC2034
  SLOW_BACKUP_THRESHOLD="${threshold}"

  if [[ "${current_duration}" -gt "${threshold}" ]]; then
    return 0
  fi
  return 1
}

# Emit backup metrics
# Usage: emit_backup_metrics <host> <job> <repo> <status> <duration> <size> <files_new> <last_success_ts>
emit_backup_metrics() {
  local host="$1"
  local job="$2"
  local repo="$3"
  local status="$4"
  local duration="$5"
  local size="$6"
  local files_new="$7"
  local last_success_ts="$8"

  local metrics
  metrics=$(cat <<EOF
# HELP stowkeeper_backup_last_success_timestamp Unix timestamp of last successful backup
# TYPE stowkeeper_backup_last_success_timestamp gauge
stowkeeper_backup_last_success_timestamp{host="${host}",job="${job}",repo="${repo}"} ${last_success_ts}
# HELP stowkeeper_backup_duration_seconds Wall-clock duration of last backup run
# TYPE stowkeeper_backup_duration_seconds gauge
stowkeeper_backup_duration_seconds{host="${host}",job="${job}",repo="${repo}"} ${duration}
# HELP stowkeeper_backup_size_bytes Size of last backup snapshot in bytes
# TYPE stowkeeper_backup_size_bytes gauge
stowkeeper_backup_size_bytes{host="${host}",job="${job}",repo="${repo}"} ${size}
# HELP stowkeeper_backup_files_new Number of new files in last backup
# TYPE stowkeeper_backup_files_new gauge
stowkeeper_backup_files_new{host="${host}",job="${job}",repo="${repo}"} ${files_new}
# HELP stowkeeper_backup_status 1 for success, 0 for failure
# TYPE stowkeeper_backup_status gauge
stowkeeper_backup_status{host="${host}",job="${job}",repo="${repo}"} ${status}
EOF
)

  write_metrics_file "${metrics}"
}

# Emit check metrics
# Usage: emit_check_metrics <repo> <last_success_ts>
emit_check_metrics() {
  local repo="$1"
  local last_success_ts="$2"

  local check_metric_lines
  check_metric_lines=$(cat <<EOF
# HELP stowkeeper_check_last_success_timestamp Unix timestamp of last successful restic check
# TYPE stowkeeper_check_last_success_timestamp gauge
stowkeeper_check_last_success_timestamp{repo="${repo}"} ${last_success_ts}
EOF
)

  local existing_metrics=""
  if [[ -f "${METRICS_FILE}" ]]; then
    existing_metrics=$(grep -v 'stowkeeper_check' "${METRICS_FILE}" 2>/dev/null || true)
  fi

  local combined_metrics
  if [[ -n "${existing_metrics}" ]]; then
    combined_metrics="${existing_metrics}"$'\n'"${check_metric_lines}"
  else
    combined_metrics="${check_metric_lines}"
  fi

  write_metrics_file "${combined_metrics}"
}

# Generic merge helper: replace lines matching a pattern with new metrics block
_merge_metrics() {
  local pattern="$1"
  local new_metrics="$2"
  local existing_metrics=""
  if [[ -f "${METRICS_FILE}" ]]; then
    existing_metrics=$(grep -v "${pattern}" "${METRICS_FILE}" 2>/dev/null || true)
  fi
  local combined_metrics
  if [[ -n "${existing_metrics}" ]]; then
    combined_metrics="${existing_metrics}"$'\n'"${new_metrics}"
  else
    combined_metrics="${new_metrics}"
  fi
  write_metrics_file "${combined_metrics}"
}

# Emit repository size metric
# Usage: emit_repo_size_metrics <repo> <size_bytes>
emit_repo_size_metrics() {
  local repo="$1"
  local size="$2"

  local metrics
  metrics=$(cat <<EOF
# HELP stowkeeper_repo_size_bytes Total repository size in bytes
# TYPE stowkeeper_repo_size_bytes gauge
stowkeeper_repo_size_bytes{repo="${repo}"} ${size}
EOF
)

  _merge_metrics 'stowkeeper_repo_size_bytes' "${metrics}"
}

# Emit deep check success metric
# Usage: emit_deep_check_metrics <repo> <timestamp>
emit_deep_check_metrics() {
  local repo="$1"
  local timestamp="$2"

  local metrics
  metrics=$(cat <<EOF
# HELP stowkeeper_check_deep_success_timestamp Unix timestamp of last successful deep check (--read-data-subset)
# TYPE stowkeeper_check_deep_success_timestamp gauge
stowkeeper_check_deep_success_timestamp{repo="${repo}"} ${timestamp}
EOF
)

  _merge_metrics 'stowkeeper_check_deep_success_timestamp' "${metrics}"
}

# Emit restore test metrics
# Usage: emit_restore_test_metrics <repo> <success> <files_checked> <files_matched>
emit_restore_test_metrics() {
  local repo="$1"
  local success="$2"
  local files_checked="$3"
  local files_matched="$4"

  local metrics
  metrics=$(cat <<EOF
# HELP stowkeeper_restore_test_success 1 if last restore test passed, 0 if failed
# TYPE stowkeeper_restore_test_success gauge
stowkeeper_restore_test_success{repo="${repo}"} ${success}
# HELP stowkeeper_restore_test_files_checked Number of files sampled during restore test
# TYPE stowkeeper_restore_test_files_checked gauge
stowkeeper_restore_test_files_checked{repo="${repo}"} ${files_checked}
# HELP stowkeeper_restore_test_files_matched Number of files with matching sha256sums
# TYPE stowkeeper_restore_test_files_matched gauge
stowkeeper_restore_test_files_matched{repo="${repo}"} ${files_matched}
EOF
)

  _merge_metrics 'stowkeeper_restore_test' "${metrics}"
}

# Read the deep-check rotation counter
# Returns: integer 0-9 on success, 255 if file missing or corrupted (skip deep check)
read_deep_check_counter() {
  local counter_file="${RUNTIME_DIR:-/var/lib/stowkeeper}/check-read-data-month"
  if [[ -f "${counter_file}" ]]; then
    local value
    value=$(cat "${counter_file}" 2>/dev/null || true)
    if [[ "${value}" =~ ^[0-9]$ ]]; then
      echo "${value}"
      return 0
    else
      logger -t STOWKEEPER "Counter file corrupted (${value}), skipping deep check this cycle"
    fi
  fi
  echo "255"  # Sentinel: never matches month%10 (0-9), so deep check is skipped
}

# Write the deep-check rotation counter atomically (temp + rename)
# Usage: write_deep_check_counter <value>
write_deep_check_counter() {
  local value="$1"
  local counter_file="${RUNTIME_DIR:-/var/lib/stowkeeper}/check-read-data-month"
  local tmpfile="${counter_file}.tmp.$$"
  printf '%s' "${value}" > "${tmpfile}"
  mv -f "${tmpfile}" "${counter_file}"
}
