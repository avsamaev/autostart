# Autostart Project Standard

This document is the canonical instruction set for creating repositories that will be deployed by `autostart`.

Use this file as the project creation instruction when bootstrapping new git projects.

## Goal

A repository should be deployable by `autostart` without project-specific special cases in the bootstrap.

## Required contract

The repository should own:
- runtime configuration
- systemd service definition
- start script
- deploy hook
- dependency signals

`autostart` should own:
- clone/pull
- minimal bootstrap
- repo analysis
- system package installation derived from repo contents
- dependency installation
- service installation/restart

## Recommended files

- `deploy.sh`
- `start_server.sh`
- `deploy/runtime.env.example`
- `deploy/systemd/<app-name>.service`
- `deploy/README-SERVER.md`

## Runtime expectations

- port and service config should come from the repo
- secrets and DB connection strings should live in repo-owned runtime env templates
- MySQL should default to localhost-only access

## Python expectations

- create venv on server
- repair broken venvs automatically
- use `venv/bin/python -m pip`
- do not rely on committed virtualenvs

## Git expectations

- deploy from a normal branch like `main`
- avoid branch-specific deploy logic
- tolerate stale git locks with retry
- do not fetch/reset in the repo hook itself

## Service expectations

- systemd service should be repo-provided
- service should restart after successful deploy
- service should run from repo root

## Version visibility

The deployment should print:
- bootstrap version
- repo commit
- repo branch
- repo remote

This helps validate that the expected release was deployed.

## Creation checklist

- [ ] repo contains `deploy.sh`
- [ ] repo contains `start_server.sh`
- [ ] repo contains `deploy/systemd/<app>.service`
- [ ] repo contains `deploy/runtime.env.example`
- [ ] repo documents runtime ENV in a table
- [ ] repo can start from repo path
- [ ] repo does not depend on a prebuilt venv
- [ ] repo does not own git sync in `deploy.sh`
