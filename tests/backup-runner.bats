#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2030,SC2031
# Stowkeeper backup-runner tests

setup() {
  # shellcheck disable=SC2155
  export TMPDIR="$(mktemp -d /tmp/stowkeeper-test-XXXXXX)"
  export LOCK_FILE="${TMPDIR}/stowkeeper-backup.lock"
  export CONFIG_FILE="${TMPDIR}/pilot.conf"
  export METRICS_FILE="${TMPDIR}/stowkeeper.prom"
  export DIGEST_DIR="${TMPDIR}/digest"
  export DEDUP_DIR="${TMPDIR}/dedup"
  export TELEGRAM_BOT_TOKEN="test-token"
  export TELEGRAM_CHAT_ID="test-chat"
  export RESTIC_REPOSITORY="sftp:test@nas.local:/backups"
  export RESTIC_PASSWORD_FILE="${TMPDIR}/.restic-password"

  mkdir -p "${DIGEST_DIR}" "${DEDUP_DIR}"
  echo "testpass" > "${RESTIC_PASSWORD_FILE}"

  # Write a minimal valid config
  cat > "${CONFIG_FILE}" <<EOF
RESTIC_REPOSITORY="${RESTIC_REPOSITORY}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
BACKUP_PATHS_DB=("/var/lib/postgresql/dumps")
BACKUP_PATHS_FILES=("/home")
BACKUP_PATHS_CONFIG=("/etc")
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
EOF

  # Source libs and script under test
  load "../src/lib/stowkeeper-metrics.sh"
  load "../src/lib/stowkeeper-notify.sh"
  load "../src/backup-runner.sh"
}

teardown() {
  rm -rf "${TMPDIR}"
}

@test "lock acquisition succeeds when lock is free" {
  export LOCK_TIMEOUT=1
  acquire_lock
  [[ -n "${LOCK_FD}" ]]
}

@test "lock contention returns exit 75" {
  export LOCK_TIMEOUT=1
  # Hold the lock in a background subshell
  (
    exec 200>"${LOCK_FILE}"
    flock 200
    sleep 2
  ) &
  local pid=$!
  sleep 0.2

  run acquire_lock
  [ "$status" -eq 75 ]

  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}

@test "metrics are written atomically" {
  local metrics="# HELP test_metric test\n# TYPE test_metric gauge\ntest_metric 42"
  write_metrics_file "${metrics}"

  [ -f "${METRICS_FILE}" ]
  grep -q "test_metric 42" "${METRICS_FILE}"
}

@test "dedup suppresses alerts within 4 hours" {
  touch "${DEDUP_DIR}/failure-db"
  # mtime is now, so should dedup
  run should_dedup "db" "failure"
  [ "$status" -eq 0 ]
}

@test "dedup allows alerts after 4 hours" {
  touch -d "5 hours ago" "${DEDUP_DIR}/failure-files"
  run should_dedup "files" "failure"
  [ "$status" -eq 1 ]
}

@test "config loading fails with exit 3 on missing keys" {
  echo 'RESTIC_REPOSITORY="test"' > "${CONFIG_FILE}"
  run load_config
  [ "$status" -eq 3 ]
}

@test "config loading succeeds with valid config" {
  run load_config
  [ "$status" -eq 0 ]
  [ "${RESTIC_REPOSITORY}" = "sftp:test@nas.local:/backups" ]
}

@test "success appends to digest queue" {
  append_digest "db" "nas-primary" 1234567890 120 1048576
  [ -f "${DIGEST_DIR}/$(date +%Y-%m-%d).json" ]
  grep -q '"job":"db"' "${DIGEST_DIR}/$(date +%Y-%m-%d).json"
}

@test "authenticate_repo fails with exit 4 on missing password file" {
  rm -f "${RESTIC_PASSWORD_FILE}"
  run authenticate_repo "nas"
  [ "$status" -eq 4 ]
}

@test "authenticate_repo succeeds when password file exists" {
  run authenticate_repo "nas"
  [ "$status" -eq 0 ]
}
