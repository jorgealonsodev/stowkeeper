# Stowkeeper Documentation

Welcome to the Stowkeeper documentation. Stowkeeper is an end-to-end
encrypted backup system with smart rotation, integrity verification, and
multi-channel notifications for Linux servers and workstations.

## Getting started

- [README](../README.md) — Project overview, quick start, and feature list
- [Deployment Guide](deployment.md) — How to deploy Stowkeeper to a single
  host or an entire fleet
- [Architecture](architecture.md) — System design, component overview, and
  design decisions
- [Operations Runbook](operations.md) — Day-to-day operations, restore
  procedures, and troubleshooting

## Reference

- [Ansible Role](../roles/backup_client/README.md) — Role variables and usage
- [Inventory Guide](../inventory/README.md) — Host grouping and variable
  precedence
- [Metrics Reference](../monitoring/README.md) — Prometheus metrics and alert
  thresholds

## Design

- [Project Decision Record (RDP)](../RDP-Stowkeeper.md) — Original
  architectural decisions and rationale
- [Specs](../openspec/specs/) — 16 spec domains with Given/When/Then scenarios
- [Archived Changes](../openspec/changes/archive/) — Completed SDD phases

## Contributing

- [Contributing Guide](../CONTRIBUTING.md) — Workflow, code style, and PR
  process

## Links

- [Restic Documentation](https://restic.readthedocs.io/) — Backup engine
- [Backblaze B2](https://www.backblaze.com/b2/) — Object storage
- [HashiCorp Vault](https://developer.hashicorp.com/vault/docs/auth/approle) —
  AppRole authentication
