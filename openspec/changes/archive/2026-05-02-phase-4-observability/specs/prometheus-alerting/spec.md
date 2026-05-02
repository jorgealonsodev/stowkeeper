# Prometheus Alerting Specification

## Purpose

Alertmanager rules that detect stale backup operations and anomalous repository growth, routing alerts through the existing Telegram and email pipeline.

## Requirements

### Requirement: Stale Backup Alert

The system MUST define a Prometheus alerting rule that fires when `stowkeeper_backup_last_success_timestamp` has not been updated for more than 30 hours, indicating a missed or failed backup run.

#### Scenario: Backup staleness triggers alert

- GIVEN no successful backup has occurred in over 30 hours
- WHEN Prometheus evaluates the alert rule
- THEN an alert SHALL fire with `severity=warning` and `channel=telegram`
- AND annotations SHALL include a summary and description identifying the affected repo

#### Scenario: Backup within threshold

- GIVEN the last successful backup was within 30 hours
- WHEN Prometheus evaluates the alert rule
- THEN the alert SHALL NOT fire

### Requirement: Stale Check Alert

The system MUST define a Prometheus alerting rule that fires when `stowkeeper_check_last_success_timestamp` has not been updated for more than 10 days, indicating a missed integrity check.

#### Scenario: Check staleness triggers alert

- GIVEN no successful check has occurred in over 10 days
- WHEN Prometheus evaluates the alert rule
- THEN an alert SHALL fire with `severity=warning` and `channel=telegram`
- AND the alert SHALL include a `repo` label identifying the checked repository

#### Scenario: Check runs on schedule

- GIVEN the weekly check completes successfully and updates the timestamp
- WHEN Prometheus evaluates the alert rule
- THEN the alert SHALL resolve

### Requirement: Repository Growth Anomaly Alert

The system MUST define a Prometheus alerting rule that fires when `stowkeeper_repo_size_bytes` grows by more than 50% over a trailing 7-day period.

#### Scenario: Rapid growth triggers alert

- GIVEN repository size grows more than 50% in 7 days
- WHEN Prometheus evaluates the alert rule
- THEN an alert SHALL fire with `severity=critical` and `channels=telegram,email`
- AND annotations SHALL include current and previous size values

#### Scenario: Normal growth

- GIVEN repository size grows 50% or less over 7 days
- WHEN Prometheus evaluates the alert rule
- THEN the alert SHALL NOT fire

### Requirement: Alert Labels and Annotations

All stowkeeper alerting rules MUST include `severity` (warning|critical) and `stowkeeper_channel` (telegram|email) labels. Each rule MUST provide `summary` and `description` annotations.

#### Scenario: Alert metadata completeness

- GIVEN any stowkeeper alert fires
- WHEN the alert is delivered to Alertmanager
- THEN it SHALL contain `severity` and `stowkeeper_channel` labels
- AND `summary` and `description` annotations SHALL be populated