#!/usr/bin/env bash
set -Eeuo pipefail

############################
# Config — edit these first
############################

APP_NAME="myapp"
APP_USER="deploy"
APP_GROUP="deploy"

REPO_SSH_URL="git@github.com:YOUR_USER/YOUR_REPO.git"
REPO_BRANCH="main"

APP_DIR="/opt/${APP_NAME}"
SRC_DIR="${APP_DIR}/repo"
BIN_DIR="${APP_DIR}/bin"
STATE_DIR="/var/lib/${APP_NAME}"

SSH_KEY_PATH="/home/${APP_USER}/.ssh/${APP_NAME}_deploy_key"
KNOWN_HOSTS_PATH="/home/${APP_USER}/.ssh/known_hosts"

# Optional custom deploy hook inside repo
# If present and executable, script will run it after dependency install.
REPO_DEPLOY_HOOK="deploy.sh"

############################
# Helpers
############################

log() {
  echo -e "\n[+] $*\n"
}

warn() {
  echo -e "\n[!] $*\n"
}

fail() {
  echo -e "\n[x] $*\n" >&2
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root: sudo $0"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

############################
# Core setup
############################

need_root

export DEBIAN_FRONTEND=noninteractive

log "Installing base packages"
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  git \
  openssh-client \
  jq \
  unzip \
  zip \
  rsync \
  build-essential \
  software-properties-common \
  apt-transport-https \
  gnupg \
  lsb-release \
  python3 \
  python3-pip \
  python3-venv \
  python3-dev \
  pipx

if ! command_exists node; then
  log "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  log "Creating user ${APP_USER}"
  useradd -m -s /bin/bash "${APP_USER}"
fi

mkdir -p "${APP_DIR}" "${BIN_DIR}" "${STATE_DIR}"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" "${BIN_DIR}" "${STATE_DIR}" || true

log "Preparing SSH deploy key"
install -d -m 700 -o "${APP_USER}" -g "${APP_GROUP}" "/home/${APP_USER}/.ssh"

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  sudo -u "${APP_USER}" ssh-keygen \
    -t ed25519 \
    -C "${APP_NAME}-deploy@$(hostname)" \
    -N "" \
    -f "${SSH_KEY_PATH}"
else
  warn "SSH key already exists: ${SSH_KEY_PATH}"
fi

touch "${KNOWN_HOSTS_PATH}"
chown "${APP_USER}:${APP_GROUP}" "${KNOWN_HOSTS_PATH}"
chmod 600 "${KNOWN_HOSTS_PATH}"

log "Adding github.com to known_hosts"
sudo -u "${APP_USER}" ssh-keyscan -H github.com >> "${KNOWN_HOSTS_PATH}" 2>/dev/null || true

PUBKEY="$(cat "${SSH_KEY_PATH}.pub")"

cat <<EOF

============================================================
DEPLOY PUBLIC KEY (add this to your Git repo as deploy key)
============================================================

${PUBKEY}

GitHub:
Repo -> Settings -> Deploy keys -> Add deploy key
- Allow read access is enough for pull-only autodeploy
- Allow write only if you know you need it

After adding the key, re-run this script if clone fails.
============================================================

EOF

cat > "${APP_DIR}/deploy.env" <<EOF
APP_NAME="${APP_NAME}"
APP_USER="${APP_USER}"
APP_GROUP="${APP_GROUP}"
REPO_SSH_URL="${REPO_SSH_URL}"
REPO_BRANCH="${REPO_BRANCH}"
APP_DIR="${APP_DIR}"
SRC_DIR="${SRC_DIR}"
BIN_DIR="${BIN_DIR}"
STATE_DIR="${STATE_DIR}"
SSH_KEY_PATH="${SSH_KEY_PATH}"
KNOWN_HOSTS_PATH="${KNOWN_HOSTS_PATH}"
REPO_DEPLOY_HOOK="${REPO_DEPLOY_HOOK}"
EOF

chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/deploy.env"
chmod 600 "${APP_DIR}/deploy.env"

log "Writing deploy runner"

cat > "${BIN_DIR}/deploy-update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/myapp/deploy.env

export HOME="/home/${APP_USER}"
export GIT_SSH_COMMAND="ssh -i ${SSH_KEY_PATH} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS_PATH}"

mkdir -p "${APP_DIR}" "${STATE_DIR}"

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "[+] Cloning repository"
  git clone --branch "${REPO_BRANCH}" "${REPO_SSH_URL}" "${SRC_DIR}"
else
  echo "[+] Updating repository"
  git -C "${SRC_DIR}" fetch origin
  git -C "${SRC_DIR}" checkout "${REPO_BRANCH}"
  git -C "${SRC_DIR}" reset --hard "origin/${REPO_BRANCH}"
fi

cd "${SRC_DIR}"

echo "[+] Detecting dependency managers"

if [[ -f "requirements.txt" ]]; then
  echo "[+] Installing Python deps from requirements.txt"
  python3 -m venv "${APP_DIR}/venv"
  source "${APP_DIR}/venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  pip install -r requirements.txt
fi

if [[ -f "pyproject.toml" ]]; then
  echo "[+] Found pyproject.toml"
  python3 -m venv "${APP_DIR}/venv"
  source "${APP_DIR}/venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  if grep -qi "poetry" pyproject.toml; then
    python -m pip install --upgrade poetry
    poetry config virtualenvs.create false
    poetry install --no-interaction
  else
    pip install .
  fi
fi

if [[ -f "package-lock.json" ]]; then
  echo "[+] Installing Node deps with npm ci"
  npm install -g npm@latest
  npm ci
elif [[ -f "package.json" ]]; then
  echo "[+] Installing Node deps with npm install"
  npm install -g npm@latest
  npm install
fi

if [[ -f "pnpm-lock.yaml" ]]; then
  echo "[+] Installing pnpm and dependencies"
  npm install -g pnpm
  pnpm install --frozen-lockfile || pnpm install
fi

if [[ -f "yarn.lock" ]]; then
  echo "[+] Installing yarn dependencies"
  npm install -g yarn
  yarn install --frozen-lockfile || yarn install
fi

if [[ -f "Cargo.toml" ]]; then
  echo "[+] Rust project detected"
  if ! command -v cargo >/dev/null 2>&1; then
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    source "${HOME}/.cargo/env"
  fi
  cargo build --release || true
fi

if [[ -f "go.mod" ]]; then
  echo "[+] Go project detected"
  if ! command -v go >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y golang-go
  fi
  go mod download
  go build ./... || true
fi

if [[ -f "Makefile" ]]; then
  echo "[+] Running make if useful"
  make || true
fi

if [[ -x "./${REPO_DEPLOY_HOOK}" ]]; then
  echo "[+] Running repo deploy hook: ${REPO_DEPLOY_HOOK}"
  "./${REPO_DEPLOY_HOOK}"
elif [[ -f "./${REPO_DEPLOY_HOOK}" ]]; then
  echo "[+] deploy hook exists but is not executable, running with bash"
  bash "./${REPO_DEPLOY_HOOK}"
else
  echo "[i] No deploy hook found, dependency sync complete"
fi

echo "[+] Deployment update completed"
EOF

sed -i "s|/opt/myapp|${APP_DIR}|g" "${BIN_DIR}/deploy-update.sh"
chmod +x "${BIN_DIR}/deploy-update.sh"
chown "${APP_USER}:${APP_GROUP}" "${BIN_DIR}/deploy-update.sh"

log "Attempting initial deploy/update"
set +e
sudo -u "${APP_USER}" bash "${BIN_DIR}/deploy-update.sh"
DEPLOY_RC=$?
set -e

if [[ "${DEPLOY_RC}" -ne 0 ]]; then
  warn "Initial clone/update failed."
  warn "Most likely the deploy key is not added to the repository yet."
  warn "After adding the key, run:"
  echo "sudo -u ${APP_USER} bash ${BIN_DIR}/deploy-update.sh"
fi

log "Writing systemd units"

cat > "/etc/systemd/system/${APP_NAME}-autodeploy.service" <<EOF
[Unit]
Description=${APP_NAME} autodeploy runner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${SRC_DIR}
Environment=HOME=/home/${APP_USER}
ExecStart=${BIN_DIR}/deploy-update.sh
Nice=10
EOF

cat > "/etc/systemd/system/${APP_NAME}-autodeploy.path" <<EOF
[Unit]
Description=Watch ${SRC_DIR} for autodeploy trigger

[Path]
PathChanged=${SRC_DIR}/.git/FETCH_HEAD
PathChanged=${SRC_DIR}/package.json
PathChanged=${SRC_DIR}/requirements.txt
PathChanged=${SRC_DIR}/pyproject.toml
Unit=${APP_NAME}-autodeploy.service

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${APP_NAME}-autodeploy.path"

log "Writing periodic git pull timer"

cat > "/etc/systemd/system/${APP_NAME}-git-pull.service" <<EOF
[Unit]
Description=Periodic git pull for ${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${SRC_DIR}
Environment=HOME=/home/${APP_USER}
ExecStart=/bin/bash -lc 'source ${APP_DIR}/deploy.env && export GIT_SSH_COMMAND="ssh -i ${SSH_KEY_PATH} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS_PATH}" && if [ -d "${SRC_DIR}/.git" ]; then git -C "${SRC_DIR}" fetch origin; fi'
EOF

cat > "/etc/systemd/system/${APP_NAME}-git-pull.timer" <<EOF
[Unit]
Description=Run periodic git fetch for ${APP_NAME}

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=${APP_NAME}-git-pull.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${APP_NAME}-git-pull.timer"

cat <<EOF

============================================================
DONE
============================================================

App name:        ${APP_NAME}
App user:        ${APP_USER}
Repo dir:        ${SRC_DIR}
Deploy key:      ${SSH_KEY_PATH}
Public key:      ${SSH_KEY_PATH}.pub

Useful commands:
- Show public key:
  cat ${SSH_KEY_PATH}.pub

- Run deploy manually:
  sudo -u ${APP_USER} bash ${BIN_DIR}/deploy-update.sh

- Check autodeploy path:
  systemctl status ${APP_NAME}-autodeploy.path

- Check periodic fetch timer:
  systemctl status ${APP_NAME}-git-pull.timer

- Check logs:
  journalctl -u ${APP_NAME}-autodeploy.service -n 200 --no-pager
  journalctl -u ${APP_NAME}-git-pull.service -n 200 --no-pager

What you still need:
1. Add the printed public key to the Git repository deploy keys
2. Re-run manual deploy if initial clone failed
3. If your repo needs app-specific start/restart logic, put it in:
   ${REPO_DEPLOY_HOOK}

============================================================

EOF
