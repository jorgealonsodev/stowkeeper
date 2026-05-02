# Deep Verification Specification

## Purpose

Monthly deep integrity verification using `restic check --read-data-subset` with a rotating subset counter, ensuring full repository data is verified over a 10-month cycle.

## Requirements

### Requirement: Monthly Rotation Logic

The system MUST maintain a counter file at `$RUNTIME_DIR/check-read-data-month` storing an integer 0–9 representing the next subset to verify. On the first check run where the current day ≤ 7, if the counter equals `month_number % 10`, the system SHALL execute `restic check --read-data-subset=${counter}0%` and increment the counter modulo 10.

#### Scenario: Deep check triggers on matching month

- GIVEN the counter value is 3 and the current month is March (month 3)
- WHEN a check runs and the current day ≤ 7
- THEN `restic check --read-data-subset=30%` SHALL be executed
- AND the counter SHALL be incremented to 4

#### Scenario: Regular check when month does not match

- GIVEN the counter value is 5 and the current month is March (month 3)
- WHEN a check runs and the current day ≤ 7
- THEN a regular `restic check` SHALL run (no `--read-data-subset`)

#### Scenario: Deep check only triggers in first week

- GIVEN the counter matches the current month modulo 10
- WHEN a check runs on day 15
- THEN a regular `restic check` SHALL run (deep check is skipped)

### Requirement: Counter Persistence

The counter file MUST be written atomically using the temp+rename pattern consistent with `write_metrics_file`. The counter SHALL persist across reboots and process restarts.

#### Scenario: Atomic counter update

- GIVEN a deep check completes successfully
- WHEN the incremented counter is written
- THEN the file SHALL be written to a temp path first then renamed
- AND at no point SHALL an empty or partial counter file be readable

#### Scenario: Counter corruption fallback

- GIVEN the counter file contains a non-integer or a value outside 0–9
- WHEN the system reads the counter
- THEN the counter SHALL be reset to 0
- AND a regular `restic check` SHALL run instead of a deep check
- AND a warning SHALL be logged to journald

### Requirement: Deep Check Metric Emission

Upon successful deep check completion per repo, the system MUST emit `stowkeeper_check_deep_success_timestamp{repo}` set to the current Unix timestamp. On failure, this metric MUST NOT be updated.

#### Scenario: Deep check metric on success

- GIVEN `restic check --read-data-subset` completes with exit code 0
- WHEN metrics are written
- THEN `stowkeeper_check_deep_success_timestamp{repo}` SHALL be set to the current timestamp

#### Scenario: Deep check metric preserved on failure

- GIVEN `restic check --read-data-subset` exits non-zero
- WHEN metrics are written
- THEN `stowkeeper_check_deep_success_timestamp{repo}` SHALL NOT be updated
- AND the failure SHALL be reported through the notification pipeline