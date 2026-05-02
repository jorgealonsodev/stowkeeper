# Delta for Systemd Scheduling

## ADDED Requirements

### Requirement: Quarterly Restore Test Timer

The system SHALL provide `stowkeeper-restore-test.timer` that activates on the first Sunday of each quarter (January, April, July, October) at 05:00. The companion oneshot service `stowkeeper-restore-test.service` SHALL invoke the restore-test script.

#### Scenario: Restore test timer fires on schedule

- GIVEN the timer is enabled
- WHEN the first Sunday of a quarter arrives at 05:00
- THEN `stowkeeper-restore-test.service` SHALL be activated
- AND the restore-test script SHALL execute

#### Scenario: Missed quarter run does not auto-catch-up

- GIVEN the system was powered off during the scheduled window
- WHEN the system boots after the window has passed
- THEN the missed quarter run SHALL NOT execute (no Persistent=true)

#### Scenario: Restore test timer unit validation

- GIVEN the service and timer units are installed
- WHEN `systemd-analyze verify` is run on both units
- THEN no validation errors SHALL be reported