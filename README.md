# autostart

Bootstrap script for a clean **Ubuntu 24.04** server that prepares a repo for pull-based autodeploy.

## What it does

The included script:

- installs base system packages
- installs Node.js if missing
- prepares a dedicated deploy user
- generates an **ed25519 deploy key** (the "openkey")
- prints the public key so you can add it to a Git repository
- clones the repository over SSH
- installs dependencies based on files found in the repo
- runs an optional repo-local `deploy.sh`
- creates `systemd` units for periodic fetch + autodeploy

This is a **pull-based autodeploy** approach:
- the server fetches changes from Git
- when updates are detected, the deploy runner refreshes dependencies and runs the deploy hook

## Files

- `bootstrap-autodeploy.sh` — main bootstrap script

## Supported dependency detection

The script detects and installs dependencies for common project types:

- Python: `requirements.txt`, `pyproject.toml`
- Node.js: `package.json`, `package-lock.json`
- pnpm: `pnpm-lock.yaml`
- yarn: `yarn.lock`
- Rust: `Cargo.toml`
- Go: `go.mod`
- generic build hint: `Makefile`

## Usage

### 1. Download and run on a clean Ubuntu 24 server

```bash
curl -fsSL https://raw.githubusercontent.com/avsamaev/autostart/main/bootstrap-autodeploy.sh -o bootstrap-autodeploy.sh
chmod +x bootstrap-autodeploy.sh
sudo ./bootstrap-autodeploy.sh
```

The script now asks interactively for:

- app name
- deploy user
- Git SSH repository URL
- branch
- deploy hook filename

It then prints the generated deploy public key and pauses so you can add it to the repository before clone starts.

### 2. Add the generated public key to your Git repository

GitHub path:

- Repo
- Settings
- Deploy keys
- Add deploy key

Read-only access is enough for pull-only deployment.

### 3. Re-run deploy after adding the key if the first clone failed

```bash
sudo -u deploy bash /opt/myapp/bin/deploy-update.sh
```

Adjust paths if you changed `APP_NAME` or `APP_USER`.

## systemd units created

The script creates:

- `${APP_NAME}-autodeploy.service`
- `${APP_NAME}-autodeploy.path`
- `${APP_NAME}-git-pull.service`
- `${APP_NAME}-git-pull.timer`

## Useful commands

Show generated public key:

```bash
cat /home/deploy/.ssh/myapp_deploy_key.pub
```

Manual deploy:

```bash
sudo -u deploy bash /opt/myapp/bin/deploy-update.sh
```

Check watcher:

```bash
systemctl status myapp-autodeploy.path
```

Check timer:

```bash
systemctl status myapp-git-pull.timer
```

Logs:

```bash
journalctl -u myapp-autodeploy.service -n 200 --no-pager
journalctl -u myapp-git-pull.service -n 200 --no-pager
```

## Notes

- The script is intentionally generic and may need a project-specific `deploy.sh` in the target repository.
- If your app needs process restarts, migrations, asset builds, or `nginx` reloads, put that logic into the repo’s `deploy.sh`.
- The bootstrap script uses SSH deploy keys rather than HTTPS tokens.

## Recommended next step

For real production use, create a repo-local `deploy.sh` that handles app-specific actions such as:

- DB migrations
- frontend build
- backend service restart
- worker restart
- cache warmup
- `nginx` reload
