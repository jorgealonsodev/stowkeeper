#!/usr/bin/env bash
# Stowkeeper Notification Library
# Telegram alerts with deduplication and success digest queue.
# Phase 2: Added email notifications on failure (codes 1, 3, 4).

set -euo pipefail

# Default directories; override via env vars
DIGEST_DIR="${DIGEST_DIR:-/var/lib/stowkeeper/digest}"
DEDUP_DIR="${DEDUP_DIR:-/var/lib/stowkeeper/dedup}"

# Portable file modification time (seconds since epoch)
file_mtime() {
  local f="$1"
  local mtime
  mtime=$(stat -c %Y "${f}" 2>/dev/null) && { echo "${mtime}"; return 0; }
  mtime=$(perl -e 'print((stat($ARGV[0]))[9])' "${f}" 2>/dev/null) && { echo "${mtime}"; return 0; }
  mtime=$(date -r "${f}" +%s 2>/dev/null) && { echo "${mtime}"; return 0; }
  echo "0"
}

# Portable timestamp formatting from Unix epoch
format_timestamp() {
  local ts="$1"
  local fmt="${2:-%Y-%m-%d %H:%M:%S}"
  local out
  out=$(date -d "@${ts}" "+${fmt}" 2>/dev/null) && { echo "${out}"; return 0; }
  if command -v perl >/dev/null 2>&1; then
    out=$(perl -MPOSIX -e 'print strftime($ARGV[1], localtime($ARGV[0]))' "${ts}" "${fmt}" 2>/dev/null) && { echo "${out}"; return 0; }
  fi
  echo "${ts}"
}

# Ensure directories exist
ensure_dirs() {
  if [[ ! -d "${DIGEST_DIR}" ]]; then
    mkdir -p "${DIGEST_DIR}" || {
      echo "Failed to create digest directory: ${DIGEST_DIR}" >&2
      return 1
    }
  fi
  if [[ ! -d "${DEDUP_DIR}" ]]; then
    mkdir -p "${DEDUP_DIR}" || {
      echo "Failed to create dedup directory: ${DEDUP_DIR}" >&2
      return 1
    }
  fi
}

# Send a Telegram message
# Usage: send_telegram_message <text>
send_telegram_message() {
  local text="$1"

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "Telegram not configured; skipping notification" >&2
    return 0
  fi

  local response
  response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${text}" \
    -d "parse_mode=Markdown" 2>/dev/null) || {
    echo "Telegram API unreachable; message logged to journald" >&2
    logger -t STOWKEEPER "Telegram notification failed: ${text}"
    return 0
  }

  if echo "${response}" | grep -q '"ok":false'; then
    echo "Telegram API error: ${response}" >&2
    logger -t STOWKEEPER "Telegram API error: ${response}"
    return 1
  fi
}

# Check if an alert should be deduplicated (4-hour window)
# Usage: should_dedup <job> <type>
# Returns 0 if dedup applies (do NOT send), 1 otherwise
should_dedup() {
  local job="$1"
  local type="$2"
  local dedup_file="${DEDUP_DIR}/${type}-${job}"

  if [[ ! -f "${dedup_file}" ]]; then
    return 1
  fi

  local mtime now
  mtime=$(file_mtime "${dedup_file}")
  now=$(date +%s)

  if (( now - mtime < 14400 )); then
    return 0
  fi

  return 1
}

# Update dedup timestamp
# Usage: update_dedup <job> <type>
update_dedup() {
  local job="$1"
  local type="$2"
  local dedup_file="${DEDUP_DIR}/${type}-${job}"

  touch "${dedup_file}"
}

# Send a failure or warning alert with deduplication.
# On failure (type=failure), also sends email via send_email().
# Usage: send_alert <job> <repo> <type> <message>
# type: failure | warning
send_alert() {
  local job="$1"
  local repo="$2"
  local alert_type="$3"
  local message="$4"

  # Prepend repo name prominently when a repo is provided
  if [[ -n "${repo}" && "${message}" != "[${repo}]"* ]]; then
    message="[${repo}] ${message}"
  fi

  ensure_dirs

  if should_dedup "${job}" "${alert_type}"; then
    echo "Alert deduplicated for ${job}/${alert_type} (within 4h window)" >&2
    return 0
  fi

  send_telegram_message "🚨 *Stowkeeper ${alert_type}*
${message}"
  update_dedup "${job}" "${alert_type}"

  # Send email on failure conditions (codes 1, 3, 4 are represented by failure type)
  # The caller uses "failure" type for exit codes 1, 3, 4.
  if [[ "${alert_type}" == "failure" ]]; then
    if type send_email &>/dev/null; then
      local email_subject="Stowkeeper ${alert_type}: ${job} on ${repo}"
      send_email "${email_subject}" "${message}" "${job}" "${repo}"
    fi
  fi
}

# Append a success entry to the daily digest queue
# Usage: append_digest <job> <repo> <timestamp> <duration> <size>
append_digest() {
  local job="$1"
  local repo="$2"
  local timestamp="$3"
  local duration="$4"
  local size="$5"

  ensure_dirs

  local digest_file
  digest_file="${DIGEST_DIR}/$(date +%Y-%m-%d).json"

  local entry
  entry="{\"job\":\"${job}\",\"repo\":\"${repo}\",\"timestamp\":${timestamp},\"duration\":${duration},\"size\":${size}}"

  printf '%s\n' "${entry}" >> "${digest_file}"
}

# Send the daily digest and remove the file
# Processes all pending digest files, skipping any older than 7 days.
# Groups digest lines by repo name in the consolidated message.
# Usage: send_digest
send_digest() {
  ensure_dirs

  shopt -s nullglob
  local files=("${DIGEST_DIR}"/*.json)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 || ! -f "${files[0]}" ]]; then
    echo "No digest entries to send; skipping" >&2
    return 0
  fi

  local now_ts max_age
  now_ts=$(date +%s)
  max_age=$((7 * 86400))

  local sent_count=0
  local failed_count=0

  for digest_file in "${files[@]}"; do
    [[ -f "${digest_file}" ]] || continue

    local mtime
    mtime=$(file_mtime "${digest_file}")
    if (( now_ts - mtime > max_age )); then
      echo "Digest ${digest_file} is older than 7 days; skipping and removing" >&2
      rm -f "${digest_file}"
      continue
    fi

    local filename file_date
    filename=$(basename "${digest_file}")
    file_date="${filename%.json}"

    local message
    message="📋 *Stowkeeper Daily Digest* — ${file_date}\n"

    # Group entries by repo using associative arrays (bash 4+)
    declare -A repo_entries
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
      local job repo ts dur sz
      job=$(echo "${line}" | sed -n 's/.*"job":"\([^"]*\)".*/\1/p')
      repo=$(echo "${line}" | sed -n 's/.*"repo":"\([^"]*\)".*/\1/p')
      ts=$(echo "${line}" | sed -n 's/.*"timestamp":\([0-9]*\).*/\1/p')
      dur=$(echo "${line}" | sed -n 's/.*"duration":\([0-9]*\).*/\1/p')
      sz=$(echo "${line}" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')

      if [[ -z "${repo}" ]]; then
        repo="unknown"
      fi

      local entry_line
      entry_line="• ${job} at $(format_timestamp "${ts}" '%H:%M') — ${dur}s, ${sz} bytes"
      local sep=""
      if [[ -n "${repo_entries[${repo}]:-}" ]]; then
        sep=$'\n'
      fi
      repo_entries["${repo}"]="${repo_entries[${repo}]:-}${sep}${entry_line}"
    done < "${digest_file}"

    # Build grouped message
    local repo_name
    for repo_name in "${!repo_entries[@]}"; do
      message="${message}\n*${repo_name}:*\n${repo_entries[${repo_name}]}"
    done

    if send_telegram_message "${message}"; then
      rm -f "${digest_file}"
      sent_count=$((sent_count + 1))
    else
      echo "Digest delivery failed for ${digest_file}; retaining for retry" >&2
      logger -t STOWKEEPER "Digest delivery failed; retaining ${digest_file}"
      failed_count=$((failed_count + 1))
    fi

    # Clean up associative array for next iteration
    unset repo_entries
  done

  if [[ ${failed_count} -gt 0 ]]; then
    return 1
  fi
}
