# Proposal: Phase 4 — Observability & Integrity Verification

## Intent

Close the observability gap in the Stowkeeper backup pipeline by adding Prometheus-based alerting, deep data integrity verification, automated restore testing, and dashboard documentation. This prevents silent backup degradation from becoming data loss.

## Scope

### In Scope
- Prometheus Alertmanager rules (backup >30h stale, check >10d stale, repo growth >50%/week)
- Deep verification: monthly `restic check --read-data-subset=10%` rotating across 10 months
- Automated restore testing: quarterly restore to temp dir with sha256sum subset validation
- Prometheus metrics documentation and optional Grafana dashboard JSON
- Notification wiring for new alerts via existing Telegram + email pipeline

### Out of Scope
- PagerDuty/OpsGenie integration (circuit breaker deferred per RDP §3.9)
- Real-time log aggregation (Loki/ELK)
- Third-party SaaS backup monitoring
- Go rewrite of wrapper

## Capabilities

### New Capabilities
- `prometheus-alerting-rules`: Alertmanager YAML rules for staleness and growth alerts
- `deep-verification`: Monthly rotating `--read-data-subset=10%` with persistent subset tracking
- `automated-restore-testing`: Quarterly restore + sha256sum comparison and result notification

### Modified Capabilities
- `prometheus-metrics`: Add `stowkeeper_repo_size_bytes{repo}` metric for growth alerting
- `systemd-scheduling`: New timers for deep-check (monthly) and restore-test (quarterly)
- `backup-runner`: New `deep-check` and `restore-test` subcommands

## Approach

Alertmanager rules read textfile metrics from node_exporter. Deep verification uses a persistent counter (`/var/lib/stowkeeper/deep-check-month`) to rotate the 10% subset monthly. Restore testing selects the latest snapshot, restores to a temp directory, samples files for sha256sum comparison against originals, and reports match rate. All new alerts route through the existing `send_alert` pipeline.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `src/backup-runner.sh` | Modified | New `deep-check` and `restore-test` subcommands |
| `src/lib/stowkeeper-metrics.sh` | Modified | Add `stowkeeper_repo_size_bytes` metric |
| `src/systemd/` | New | `stowkeeper-deep-check.timer/service`, `stowkeeper-restore-test.timer/service` |
| `src/alerts/` | New | Alertmanager rules YAML (`stowkeeper-alerts.yml`) |
| `docs/` | New | Metrics reference + Grafana dashboard JSON |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Deep check I/O/bandwidth load on large repos | Med | Run during low-traffic window; subset limits read to 10% |
| Restore test exhausts temp disk | Med | Pre-flight disk check; skip if <2× repo size free |
| Alertmanager syntax error silences alerts | Low | Validate rules with `amtool check-config` |
| False positive repo growth during bulk imports | Med | Growth alert uses 7-day average, not single spike |

## Rollback Plan

1. Disable new systemd timers (`systemctl disable --now stowkeeper-deep-check.timer stowkeeper-restore-test.timer`)
2. Remove Alertmanager rules from Prometheus config and reload
3. Revert `backup-runner.sh` and `stowkeeper-metrics.sh` via git checkout
4. Remove new counter/state files in `/var/lib/stowkeeper/`

## Dependencies

- Prometheus + Alertmanager running (reads textfile metrics from Phase 1)
- Existing Telegram bot + msmtp email pipeline (Phase 2)

## Success Criteria

- [ ] Simulated stale backup (>30h) triggers Alertmanager rule and delivers Telegram + email alert
- [ ] Simulated stale check (>10d) triggers Alertmanager rule and delivers alert
- [ ] Monthly `deep-check` completes, updates `stowkeeper_check_last_success_timestamp`, and rotates subset counter
- [ ] Quarterly `restore-test` completes with sha256sum match report and notifies results
- [ ] `amtool check-config` passes on committed Alertmanager rules
