#!/usr/bin/env bash
# Stowkeeper install script
# Run as root to create runtime directories and set permissions.

set -euo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/stowkeeper}"
SKEL_DIR="${SKEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src}"

echo "Installing Stowkeeper to ${INSTALL_PREFIX} ..."

# Create directories
mkdir -p "${INSTALL_PREFIX}"
mkdir -p "${INSTALL_PREFIX}/conf"
mkdir -p "${INSTALL_PREFIX}/lib"
mkdir -p /var/lib/stowkeeper/digest
mkdir -p /var/lib/stowkeeper/dedup
# Detect/create metrics directory
METRICS_DIR=""
for dir in /var/lib/prometheus/node-exporter /var/lib/node_exporter/textfile_collector /opt/prometheus/textfile; do
  if [[ -d "${dir}" ]]; then
    METRICS_DIR="${dir}"
    break
  fi
done
if [[ -z "${METRICS_DIR}" ]]; then
  METRICS_DIR="/var/lib/prometheus/node-exporter"
fi
mkdir -p "${METRICS_DIR}"
mkdir -p /var/lock

# Copy files
cp "${SKEL_DIR}/backup-runner.sh" "${INSTALL_PREFIX}/backup-runner.sh"
cp "${SKEL_DIR}/lib/stowkeeper-metrics.sh" "${INSTALL_PREFIX}/lib/stowkeeper-metrics.sh"
cp "${SKEL_DIR}/lib/stowkeeper-notify.sh" "${INSTALL_PREFIX}/lib/stowkeeper-notify.sh"

# Config is copied only if absent
if [[ ! -f "${INSTALL_PREFIX}/conf/pilot.conf" ]]; then
  cp "${SKEL_DIR}/configs/pilot.conf" "${INSTALL_PREFIX}/conf/pilot.conf"
  echo "Config template copied to ${INSTALL_PREFIX}/conf/pilot.conf"
  echo "Please edit it and set your secrets."
fi

# Permissions
chmod 755 "${INSTALL_PREFIX}/backup-runner.sh"
chmod 755 "${INSTALL_PREFIX}/lib"/*.sh
chmod 600 "${INSTALL_PREFIX}/conf/pilot.conf" 2>/dev/null || true

# Create lockfile placeholder (flock will use it)
touch /var/lock/stowkeeper-backup.lock
chmod 644 /var/lock/stowkeeper-backup.lock

# Create metrics placeholder
touch "${METRICS_DIR}/stowkeeper.prom"
chmod 644 "${METRICS_DIR}/stowkeeper.prom"

echo "Stowkeeper installed successfully."
echo "Next steps:"
echo "  1. Edit ${INSTALL_PREFIX}/conf/pilot.conf"
echo "  2. Create ${INSTALL_PREFIX}/conf/.restic-password"
echo "  3. Copy systemd units from ${SKEL_DIR}/systemd/ to /etc/systemd/system/"
echo "  4. systemctl daemon-reload && systemctl enable --now stowkeeper-backup-db.timer"
