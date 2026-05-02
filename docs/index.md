# Stowkeeper Documentation

Welcome to the Stowkeeper documentation. Stowkeeper is an end-to-end
encrypted backup system with smart rotation, integrity verification, and
multi-channel notifications for Linux servers and workstations.

## Getting started

- [README](https://github.com/jorgealonsodev/stowkeeper/blob/main/README.md) — Project overview, quick start, and feature list
- [Deployment Guide](deployment.md) — How to deploy Stowkeeper to a single
  host or an entire fleet
- [Architecture](architecture.md) — System design, component overview, and
  design decisions
- [Operations Runbook](operations.md) — Day-to-day operations, restore
  procedures, and troubleshooting

## Reference

- [Ansible Role](https://github.com/jorgealonsodev/stowkeeper/blob/main/roles/backup_client/README.md) — Role variables and usage
- [Inventory Guide](https://github.com/jorgealonsodev/stowkeeper/blob/main/inventory/README.md) — Host grouping and variable
  precedence
- [Metrics Reference](https://github.com/jorgealonsodev/stowkeeper/blob/main/monitoring/README.md) — Prometheus metrics and alert
  thresholds

## Design

- [Project Decision Record (RDP)](https://github.com/jorgealonsodev/stowkeeper/blob/main/RDP-Stowkeeper.md) — Original
  architectural decisions and rationale
- [Specs](https://github.com/jorgealonsodev/stowkeeper/tree/main/openspec/specs/) — 16 spec domains with Given/When/Then scenarios
- [Archived Changes](https://github.com/jorgealonsodev/stowkeeper/tree/main/openspec/changes/archive/) — Completed SDD phases

## Contributing

- [Contributing Guide](https://github.com/jorgealonsodev/stowkeeper/blob/main/CONTRIBUTING.md) — Workflow, code style, and PR
  process

## Links

- [Restic Documentation](https://restic.readthedocs.io/) — Backup engine
- [Backblaze B2](https://www.backblaze.com/b2/) — Object storage
- [HashiCorp Vault](https://developer.hashicorp.com/vault/docs/auth/approle) —
  AppRole authentication
