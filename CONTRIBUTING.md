# Contributing to Stowkeeper

Thanks for your interest in contributing. This document explains how to set up
your environment, make changes, and submit them for review.

## Development workflow

This project uses **main + worktrees** — not git flow. All work happens off
`main` in isolated worktrees.

```bash
# Clone and create a worktree for your change
git clone <repo-url> stowkeeper
cd stowkeeper
git worktree add ../stowkeeper-my-feature main
cd ../stowkeeper-my-feature
```

## Making changes

### Spec-Driven Development

All substantial changes go through the SDD workflow:

1. **Proposal** — define intent, scope, and approach
2. **Design** — architecture decisions and sequence diagrams
3. **Specs** — Given/When/Then scenarios with RFC 2119 keywords
4. **Tasks** — implementation checklist
5. **Apply** — code changes
6. **Verify** — spec compliance validation
7. **Archive** — delta sync to main specs

See `openspec/` for existing specs and archived changes.

### Code style

- All Bash scripts must pass `shellcheck -x`
- Run `bash -n` on every `.sh` file before committing
- Use `#!/usr/bin/env bash`, `set -euo pipefail`
- Quote all variable expansions
- Use `$(...)` instead of backticks
- Prefer `[[ ... ]]` over `[ ... ]` for conditionals
- Document functions with a header comment describing parameters and return
  values

### Commit conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add multi-host Ansible deployment
fix: prevent exit 4 from killing dual-repo loop
docs: add operations runbook
refactor: extract Vault auth into dedicated library
```

### Testing

```bash
# Unit tests (requires bats)
bats tests/backup-runner.bats
bats tests/phase2.bats

# Static analysis (requires shellcheck)
shellcheck -x src/backup-runner.sh src/lib/*.sh install.sh

# Syntax check
bash -n src/backup-runner.sh
bash -n src/lib/*.sh
```

Integration tests require a real Restic binary, NAS access, and B2 credentials.
They are documented as skipped stubs in the test files.

## Pull requests

1. Create your worktree off `main`
2. Make your changes following the conventions above
3. Run tests and linting
4. Submit a PR with a clear description
5. Reference any related issues

All PRs must pass ShellCheck and `bash -n` checks before merging.

## Reporting bugs

Open an issue with:

- Host OS and version
- Bash version (`bash --version`)
- Restic version (`restic version`)
- Relevant log output from `journalctl -u stowkeeper-*`
- Steps to reproduce

## Questions

Use [GitHub Discussions](https://github.com/<org>/stowkeeper/discussions) for
questions and general conversation.
