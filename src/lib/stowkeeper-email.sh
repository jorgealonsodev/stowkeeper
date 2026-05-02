#!/usr/bin/env bash
# Stowkeeper Email Notification Library
# msmtp wrapper with rate limiting, deduplication, and SMTP config reading.
# Email alerts fire ONLY on failure (codes 1, 3, 4). Success digests are
# Telegram-only per spec.

set -euo pipefail

# Default state directories
DEDUP_DIR="${DEDUP_DIR:-/var/lib/stowkeeper/dedup}"
RUNTIME_DIR="${RUNTIME_DIR:-/var/lib/stowkeeper}"

# Rate-limit tracking file
_EMAIL_RATE_LIMIT_FILE=""

# Portable file modification time (seconds since epoch)
file_mtime() {
  local f="$1"
  local mtime
  mtime=$(stat -c %Y "${f}" 2>/dev/null) && { echo "${mtime}"; return 0; }
  mtime=$(perl -e 'print((stat($ARGV[0]))[9])' "${f}" 2>/dev/null) && { echo "${mtime}"; return 0; }
  mtime=$(date -r "${f}" +%s 2>/dev/null) && { echo "${mtime}"; return 0; }
  echo "0"
}

# Portable "1 hour ago" epoch timestamp
hour_ago_epoch() {
  local ts
  ts=$(date -d "1 hour ago" +%s 2>/dev/null) && { echo "${ts}"; return 0; }
  echo $(( $(date +%s) - 3600 ))
}

# Initialize rate-limit file path
_email_init_rate_limit() {
  _EMAIL_RATE_LIMIT_FILE="${RUNTIME_DIR}/email-rate-limit.log"
}

# Ensure directories exist
_email_ensure_dirs() {
  if [[ ! -d "${DEDUP_DIR}" ]]; then
    mkdir -p "${DEDUP_DIR}" || {
      echo "Failed to create dedup directory: ${DEDUP_DIR}" >&2
      return 1
    }
  fi
  if [[ ! -d "${RUNTIME_DIR}" ]]; then
    mkdir -p "${RUNTIME_DIR}" || {
      echo "Failed to create runtime directory: ${RUNTIME_DIR}" >&2
      return 1
    }
  fi
}

# Check if email should be rate-limited
# Returns 0 if allowed, 1 if rate-limited
_email_check_rate_limit() {
  local limit="${SMTP_RATE_LIMIT:-10}"
  _email_init_rate_limit

  if [[ ! -f "${_EMAIL_RATE_LIMIT_FILE}" ]]; then
    return 0
  fi

  local window_start
  window_start=$(hour_ago_epoch)

  local count=0
  local line ts
  while IFS= read -r line || [[ -n "${line}" ]]; do
    ts="${line%%,*}"
    if [[ -n "${ts}" && "${ts}" =~ ^[0-9]+$ && "${ts}" -gt ${window_start} ]]; then
      count=$((count + 1))
    fi
  done < "${_EMAIL_RATE_LIMIT_FILE}"

  if [[ ${count} -ge ${limit} ]]; then
    return 1
  fi
  return 0
}

# Record an email send in the rate-limit log
_email_record_send() {
  _email_init_rate_limit
  local now
  now=$(date +%s)
  printf '%s,%s\n' "${now}" "sent" >> "${_EMAIL_RATE_LIMIT_FILE}"

  # Trim log to last 100 entries to prevent unbounded growth
  local line_count
  line_count=$(wc -l < "${_EMAIL_RATE_LIMIT_FILE}" 2>/dev/null || echo 0)
  if [[ "${line_count}" -gt 100 ]]; then
    tail -n 100 "${_EMAIL_RATE_LIMIT_FILE}" > "${_EMAIL_RATE_LIMIT_FILE}.tmp"
    mv -f "${_EMAIL_RATE_LIMIT_FILE}.tmp" "${_EMAIL_RATE_LIMIT_FILE}"
  fi
}

# Check if an email alert should be deduplicated (4-hour window)
# Usage: _email_should_dedup <job> <repo>
# Returns 0 if dedup applies (do NOT send), 1 otherwise
_email_should_dedup() {
  local job="$1"
  local repo="$2"
  local dedup_file="${DEDUP_DIR}/email-${job}-${repo}"

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

# Update email dedup timestamp
# Usage: _email_update_dedup <job> <repo>
_email_update_dedup() {
  local job="$1"
  local repo="$2"
  local dedup_file="${DEDUP_DIR}/email-${job}-${repo}"

  touch "${dedup_file}"
}

# Send an email via msmtp with rate limiting and deduplication.
# Usage: send_email <subject> <body> [job] [repo]
#   job: optional, for deduplication key
#   repo: optional, for deduplication key
#
# Skips sending if SMTP_HOST or SMTP_TO is empty.
# Skips if rate limit exceeded.
# Skips if dedup window active (when job and repo are provided).
# Returns 0 if sent or skipped gracefully, 1 on msmtp failure.
send_email() {
  local subject="$1"
  local body="$2"
  local job="${3:-}"
  local repo="${4:-}"

  _email_ensure_dirs

  # Skip if SMTP is not configured
  if [[ -z "${SMTP_HOST:-}" || -z "${SMTP_TO:-}" ]]; then
    echo "Email skipped: SMTP_HOST or SMTP_TO not configured" >&2
    return 0
  fi

  # Check rate limit
  if ! _email_check_rate_limit; then
    echo "Email rate limit exceeded (${SMTP_RATE_LIMIT:-10}/hour); dropping email for ${job:-unknown}/${repo:-unknown}" >&2
    logger -t STOWKEEPER "Email rate limit exceeded; dropping email for ${job:-unknown}/${repo:-unknown}"
    return 0
  fi

  # Check dedup (only if job and repo provided)
  if [[ -n "${job}" && -n "${repo}" ]]; then
    if _email_should_dedup "${job}" "${repo}"; then
      echo "Email deduplicated for ${job}/${repo} (within 4h window)" >&2
      return 0
    fi
  fi

  # Build the email message with proper headers
  local from="${SMTP_FROM:-stowkeeper@example.com}"
  local to="${SMTP_TO}"
  local msg
  msg=$(cat <<EOF
From: ${from}
To: ${to}
Subject: ${subject}
Content-Type: text/plain; charset=UTF-8

${body}
EOF
)

  # Attempt to send via msmtp
  local msmtp_cmd=(msmtp -t)
  if [[ -n "${SMTP_HOST}" ]]; then
    msmtp_cmd+=(--host="${SMTP_HOST}")
  fi
  if [[ -n "${SMTP_PORT:-}" ]]; then
    msmtp_cmd+=(--port="${SMTP_PORT}")
  fi
  if [[ -n "${SMTP_USER:-}" ]]; then
    msmtp_cmd+=(--user="${SMTP_USER}")
  fi
  if [[ -n "${SMTP_PASS:-}" ]]; then
    msmtp_cmd+=(--passwordeval="echo ${SMTP_PASS}")
  fi

  if ! printf '%s\n' "${msg}" | "${msmtp_cmd[@]}" >/dev/null 2>&1; then
    echo "msmtp failed to send email; logged to journald" >&2
    logger -t STOWKEEPER "msmtp failed to send email: subject=${subject}"
    return 1
  fi

  # Record successful send for rate limiting
  _email_record_send

  # Update dedup timestamp
  if [[ -n "${job}" && -n "${repo}" ]]; then
    _email_update_dedup "${job}" "${repo}"
  fi

  logger -t STOWKEEPER "Email sent: subject=${subject} to=${to}"
  return 0
}
