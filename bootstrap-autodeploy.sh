#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-myapp}"
APP_USER="${APP_USER:-deploy}"
APP_GROUP="${APP_GROUP:-deploy}"
REPO_SSH_URL="${REPO_SSH_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DEPLOY_HOOK="${REPO_DEPLOY_HOOK:-deploy.sh}"
REPO_SERVICE_NAME="${REPO_SERVICE_NAME:-${APP_NAME}.service}"

APP_DIR="/opt/${APP_NAME}"
SRC_DIR="${APP_DIR}/repo"
BIN_DIR="${APP_DIR}/bin"
STATE_DIR="/var/lib/${APP_NAME}"
SSH_KEY_PATH="/home/${APP_USER}/.ssh/${APP_NAME}_deploy_key"
KNOWN_HOSTS_PATH="/home/${APP_USER}/.ssh/known_hosts"

C_RESET=""
C_GREEN=""
C_RED=""
C_YELLOW=""
C_BLUE=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
fi

BOOTSTRAP_VERSION="2026-04-02.1"

banner() {
  printf "
%b============================================================%b
" "$C_BLUE" "$C_RESET"
  printf "%bAutostart bootstrap version:%b %s
" "$C_GREEN" "$C_RESET" "$BOOTSTRAP_VERSION"
  printf "%bRepository:%b %s
" "$C_GREEN" "$C_RESET" "${REPO_SSH_URL:-unset}"
  printf "%bBranch:%b %s
" "$C_GREEN" "$C_RESET" "${REPO_BRANCH:-unset}"
  printf "%b============================================================%b

" "$C_BLUE" "$C_RESET"
}

log() {
  printf "\n%b[+] %s%b\n\n" "$C_GREEN" "$*" "$C_RESET"
}

warn() {
  printf "\n%b[!] %s%b\n\n" "$C_YELLOW" "$*" "$C_RESET"
}

fail() {
  printf "\n%b[x] %s%b\n\n" "$C_RED" "$*" "$C_RESET" >&2
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

prompt_if_empty() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="${!var_name:-}"
  if [[ -z "$current_value" ]]; then
    read -r -p "$prompt_text" current_value
    printf -v "$var_name" '%s' "$current_value"
  fi
}

countdown() {
  local seconds="$1"
  while [[ "$seconds" -gt 0 ]]; do
    printf '\r%b[!] Retrying in %02d seconds...%b' "$C_YELLOW" "$seconds" "$C_RESET"
    sleep 1
    seconds=$((seconds - 1))
  done
  printf '\r%40s\r' ''
}

normalize_repo_url() {
  local raw="$REPO_SSH_URL"
  raw="${raw#ssh://}"
  raw="${raw#git@github.com:}"
  raw="${raw#https://github.com/}"
  raw="${raw#http://github.com/}"
  raw="${raw#github.com/}"
  raw="${raw%/}"
  raw="${raw%.git}"

  if [[ "$raw" =~ ^([^/]+)/([^/]+)$ ]]; then
    local owner="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    if [[ "$REPO_SSH_URL" != "git@github.com:${owner}/${repo}.git" ]]; then
      warn "Repository URL normalized to SSH format for deploy keys."
    fi
    REPO_SSH_URL="git@github.com:${owner}/${repo}.git"
    log "Using repository SSH URL: ${REPO_SSH_URL}"
  fi
}

verify_repo_url() {
  if [[ ! "$REPO_SSH_URL" =~ ^git@github.com:[^/]+/[^/]+\.git$ ]]; then
    fail "Repository value must look like owner/repo, github.com/owner/repo, or git@github.com:owner/repo.git"
  fi
}

recompute_paths() {
  APP_DIR="/opt/${APP_NAME}"
  SRC_DIR="${APP_DIR}/repo"
  BIN_DIR="${APP_DIR}/bin"
  STATE_DIR="/var/lib/${APP_NAME}"
  SSH_KEY_PATH="/home/${APP_USER}/.ssh/${APP_NAME}_deploy_key"
  KNOWN_HOSTS_PATH="/home/${APP_USER}/.ssh/known_hosts"
}

collect_config() {
  echo
  echo "=== Autodeploy bootstrap configuration ==="
  prompt_if_empty APP_NAME "App name [myapp]: "
  [[ -z "$APP_NAME" ]] && APP_NAME="myapp"
  prompt_if_empty APP_USER "Deploy user [deploy]: "
  [[ -z "$APP_USER" ]] && APP_USER="deploy"
  APP_GROUP="$APP_USER"
  prompt_if_empty REPO_SSH_URL "Git repository (owner/repo or GitHub URL): "
  normalize_repo_url
  verify_repo_url
  prompt_if_empty REPO_BRANCH "Git branch [main]: "
  [[ -z "$REPO_BRANCH" ]] && REPO_BRANCH="main"
  prompt_if_empty REPO_DEPLOY_HOOK "Deploy hook inside repo [deploy.sh]: "
  [[ -z "$REPO_DEPLOY_HOOK" ]] && REPO_DEPLOY_HOOK="deploy.sh"
  recompute_paths

  echo
  printf "%bConfiguration summary:%b\n" "$C_BLUE" "$C_RESET"
  echo "  APP_NAME        = $APP_NAME"
  echo "  APP_USER        = $APP_USER"
  echo "  REPO_SSH_URL    = $REPO_SSH_URL"
  echo "  REPO_BRANCH     = $REPO_BRANCH"
  echo "  REPO_DEPLOY_HOOK= $REPO_DEPLOY_HOOK"
  echo
}

install_minimal_base() {
  log "Installing minimal bootstrap packages"
  apt-get update
  apt-get install -y ca-certificates curl git openssh-client jq rsync
}

ensure_node() {
  if ! command_exists node; then
    log "Installing Node.js 22 because the repo requires Node"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi
}

ensure_python() {
  apt-get install -y python3 python3-pip python3-venv
}

read_repo_system_packages() {
  local file="${SRC_DIR}/deploy/system-packages.txt"
  if [[ -f "$file" ]]; then
    grep -vE '^(\s*#|\s*$)' "$file" | tr '
' ' '
  fi
}

install_repo_system_packages() {
  local pkgs=()

  if [[ -f "${SRC_DIR}/backend/requirements.txt" || -f "${SRC_DIR}/requirements.txt" || -f "${SRC_DIR}/pyproject.toml" ]]; then
    pkgs+=(python3 python3-pip python3-venv)
  fi

  if [[ -f "${SRC_DIR}/package.json" || -f "${SRC_DIR}/backend/package.json" || -f "${SRC_DIR}/pnpm-lock.yaml" || -f "${SRC_DIR}/yarn.lock" ]]; then
    ensure_node
  fi

  if grep -Rqi "mysqlclient" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(build-essential pkg-config default-libmysqlclient-dev)
  fi

  if grep -Rqi "Pillow" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(libjpeg-dev zlib1g-dev)
  fi

  if grep -Rqi "pytesseract" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(tesseract-ocr)
  fi

  if grep -Rqi "SpeechRecognition" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(flac)
  fi

  if [[ -f "${SRC_DIR}/go.mod" ]]; then
    pkgs+=(golang-go)
  fi

  if [[ -f "${SRC_DIR}/Cargo.toml" ]]; then
    pkgs+=(build-essential pkg-config libssl-dev)
  fi

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    local unique_pkgs
    unique_pkgs=$(printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++')
    log "Installing repo-required system packages"
    apt-get install -y ${unique_pkgs}
  else
    log "No additional repo-required system packages detected"
  fi
}

ensure_working_venv() {
  local venv_path="$1"
  if [[ -d "$venv_path" ]]; then
    if [[ ! -x "$venv_path/bin/python" ]] || [[ ! -f "$venv_path/bin/pip" ]]; then
      warn "Broken virtualenv detected at ${venv_path}; recreating it"
      rm -rf "$venv_path"
    fi
  fi
  if [[ ! -d "$venv_path" ]]; then
    python3 -m venv "$venv_path"
  fi
}

clear_stale_git_lock() {
  local repo_dir="$1"
  local lock_file="${repo_dir}/.git/index.lock"

  if [[ ! -f "$lock_file" ]]; then
    return 0
  fi

  warn "Git index.lock detected at ${lock_file}"

  if command -v lsof >/dev/null 2>&1 && lsof "$lock_file" >/dev/null 2>&1; then
    warn "Lock file is still held by a running process"
    return 1
  fi

  warn "Removing stale git lock file"
  rm -f "$lock_file"
  return 0
}

git_sync_repo() {
  local attempt
  for attempt in 1 2; do
    if [[ ! -d "${SRC_DIR}/.git" ]]; then
      echo "[+] Cloning repository"
      git clone --branch "${REPO_BRANCH}" "${REPO_SSH_URL}" "${SRC_DIR}" && return 0
    else
      clear_stale_git_lock "${SRC_DIR}" || true
      echo "[+] Updating repository"
      if git -C "${SRC_DIR}" fetch origin         && git -C "${SRC_DIR}" checkout "${REPO_BRANCH}"         && git -C "${SRC_DIR}" reset --hard "origin/${REPO_BRANCH}"; then
        return 0
      fi
    fi

    if [[ -f "${SRC_DIR}/.git/index.lock" && "$attempt" -eq 1 ]]; then
      warn "Git lock prevented update. Waiting 60 seconds before retrying..."
      countdown 60
      clear_stale_git_lock "${SRC_DIR}" || true
      continue
    fi

    return 1
  done

  return 1
}

restart_repo_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q "^${REPO_SERVICE_NAME}"; then
      log "Restarting ${REPO_SERVICE_NAME}"
      systemctl restart "${REPO_SERVICE_NAME}" || systemctl start "${REPO_SERVICE_NAME}"
      systemctl --no-pager --full status "${REPO_SERVICE_NAME}" || true
    else
      warn "Service ${REPO_SERVICE_NAME} not installed yet; skipping restart"
    fi
  fi
}

install_repo_systemd_unit() {
  local default_unit_path="${SRC_DIR}/deploy/systemd/${APP_NAME}.service"
  local fallback_unit_path="${SRC_DIR}/deploy/systemd/content-orchestrator.service"
  local selected_unit=""

  if [[ -f "$default_unit_path" ]]; then
    selected_unit="$default_unit_path"
  elif [[ -f "$fallback_unit_path" ]]; then
    selected_unit="$fallback_unit_path"
  fi

  if [[ -z "$selected_unit" ]]; then
    fail "No repo-provided systemd service file found under deploy/systemd/; autostart requires a service template"
  fi

  log "Installing systemd unit from ${selected_unit}"
  sed \
    -e "s|/home/content/orchestrator|${SRC_DIR}|g" \
    -e "s|/opt/content-orchestrator/repo|${SRC_DIR}|g" \
    -e "s|User=content|User=${APP_USER}|g" \
    -e "s|Group=content|Group=${APP_GROUP}|g" \
    "$selected_unit" > "/etc/systemd/system/${APP_NAME}.service"

  if [[ -f "${SRC_DIR}/deploy/runtime.env" ]]; then
    log "Installing repo-provided runtime env file"
    install -d -m 755 /etc/${APP_NAME}
    cp "${SRC_DIR}/deploy/runtime.env" "/etc/${APP_NAME}/runtime.env"
    if ! grep -q '^EnvironmentFile=/etc/' "/etc/systemd/system/${APP_NAME}.service"; then
      python3 - <<PY2
from pathlib import Path
p = Path('/etc/systemd/system/${APP_NAME}.service')
text = p.read_text()
needle = '[Service]
'
replace = '[Service]
EnvironmentFile=-/etc/${APP_NAME}/runtime.env
'
if needle in text and 'EnvironmentFile=-/etc/${APP_NAME}/runtime.env' not in text:
    text = text.replace(needle, replace, 1)
p.write_text(text)
PY2
    fi
  fi

  systemctl daemon-reload
  systemctl enable "${APP_NAME}.service"
  systemctl restart "${APP_NAME}.service"
  systemctl --no-pager --full status "${APP_NAME}.service" || true
}

need_root
collect_config
banner
export DEBIAN_FRONTEND=noninteractive
install_minimal_base

if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  log "Creating user ${APP_USER}"
  useradd -m -s /bin/bash "${APP_USER}"
fi

mkdir -p "${APP_DIR}" "${BIN_DIR}" "${STATE_DIR}"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" "${BIN_DIR}" "${STATE_DIR}" || true

log "Preparing SSH deploy key"
install -d -m 700 -o "${APP_USER}" -g "${APP_GROUP}" "/home/${APP_USER}/.ssh"

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  sudo -u "${APP_USER}" ssh-keygen -t ed25519 -C "${APP_NAME}-deploy@$(hostname)" -N "" -f "${SSH_KEY_PATH}"
else
  warn "SSH key already exists: ${SSH_KEY_PATH}"
fi

touch "${KNOWN_HOSTS_PATH}"
chown "${APP_USER}:${APP_GROUP}" "${KNOWN_HOSTS_PATH}"
chmod 600 "${KNOWN_HOSTS_PATH}"

log "Adding github.com to known_hosts"
sudo -u "${APP_USER}" ssh-keyscan -H github.com >> "${KNOWN_HOSTS_PATH}" 2>/dev/null || true

PUBKEY="$(cat "${SSH_KEY_PATH}.pub")"

cat <<EOM

============================================================
DEPLOY PUBLIC KEY (add this to your Git repo as deploy key)
============================================================

${PUBKEY}

GitHub:
Repo -> Settings -> Deploy keys -> Add deploy key
- Allow read access is enough for pull-only autodeploy
- Allow write only if you know you need it

Repository configured for autodeploy:
${REPO_SSH_URL}

After adding the key, press Enter to continue.
If clone fails, fix the deploy key on GitHub and run this again.
============================================================

EOM

read -r -p "Press Enter after the deploy key has been added to the repository..." _

for attempt in 1 2; do
  if sudo -u "${APP_USER}" ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${KNOWN_HOSTS_PATH}" -i "${SSH_KEY_PATH}" -T git@github.com >/tmp/${APP_NAME}-ssh-check.log 2>&1; then
    log "SSH deploy key check passed"
    break
  fi

  if grep -qi "successfully authenticated\|Hi .*You've successfully authenticated" /tmp/${APP_NAME}-ssh-check.log 2>/dev/null; then
    log "SSH deploy key check passed"
    break
  fi

  warn "SSH deploy key is not ready yet for ${REPO_SSH_URL}."
  cat /tmp/${APP_NAME}-ssh-check.log || true

  if [[ "$attempt" -eq 1 ]]; then
    warn "Waiting 60 seconds before retrying GitHub SSH access..."
    countdown 60
  else
    fail "Deploy key still not accepted by GitHub after retry. Check that the deploy key was added to the correct repository and use the SSH repo URL."
  fi
done

cat > "${APP_DIR}/deploy.env" <<EOM
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
EOM

chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/deploy.env"
chmod 600 "${APP_DIR}/deploy.env"

cat > "${BIN_DIR}/deploy-update.sh" <<'EOM'
#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/myapp/deploy.env
export HOME="/home/${APP_USER}"
export GIT_SSH_COMMAND="ssh -i ${SSH_KEY_PATH} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS_PATH}"

C_RESET=""
C_GREEN=""
C_RED=""
C_YELLOW=""
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
fi

log() { printf "
%b[+] %s%b

" "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf "
%b[!] %s%b

" "$C_YELLOW" "$*" "$C_RESET"; }
fail() { printf "
%b[x] %s%b

" "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
countdown() { local s="$1"; while [[ "$s" -gt 0 ]]; do printf '
%b[!] Retrying in %02d seconds...%b' "$C_YELLOW" "$s" "$C_RESET"; sleep 1; s=$((s-1)); done; printf '
%40s
' ''; }
clear_stale_git_lock() {
  local lock_file="${SRC_DIR}/.git/index.lock"
  [[ -f "$lock_file" ]] || return 0
  if command -v lsof >/dev/null 2>&1 && lsof "$lock_file" >/dev/null 2>&1; then
    return 1
  fi
  rm -f "$lock_file"
}
git_sync_repo() {
  local attempt
  for attempt in 1 2 3; do
    if [[ ! -d "${SRC_DIR}/.git" ]]; then
      log "Cloning repository"
      git clone --branch "${REPO_BRANCH}" "${REPO_SSH_URL}" "${SRC_DIR}" && return 0
    else
      clear_stale_git_lock || true
      log "Updating repository"
      if git -C "${SRC_DIR}" fetch origin && git -C "${SRC_DIR}" checkout "${REPO_BRANCH}" && git -C "${SRC_DIR}" reset --hard "origin/${REPO_BRANCH}"; then
        return 0
      fi
    fi
    if [[ -f "${SRC_DIR}/.git/index.lock" && "$attempt" -lt 3 ]]; then
      warn "Git index.lock detected; retrying in 60 seconds"
      countdown 60
      clear_stale_git_lock || true
      continue
    fi
    return 1
  done
}
ensure_venv() {
  local venv_path="$1"
  if [[ -d "$venv_path" ]] && [[ ! -x "$venv_path/bin/python" || ! -x "$venv_path/bin/pip" ]]; then
    warn "Broken virtualenv detected at ${venv_path}; recreating it"
    rm -rf "$venv_path"
  fi
  [[ -d "$venv_path" ]] || python3 -m venv "$venv_path"
}
read_repo_system_packages() {
  local file="${SRC_DIR}/deploy/system-packages.txt"
  if [[ -f "$file" ]]; then
    grep -vE '^(\s*#|\s*$)' "$file" | tr '
' ' '
  fi
}
install_repo_system_packages() {
  local pkgs=()
  if [[ -f "${SRC_DIR}/backend/requirements.txt" || -f "${SRC_DIR}/requirements.txt" || -f "${SRC_DIR}/pyproject.toml" ]]; then
    pkgs+=(python3 python3-pip python3-venv)
  fi
  if [[ -f "${SRC_DIR}/package.json" || -f "${SRC_DIR}/backend/package.json" || -f "${SRC_DIR}/pnpm-lock.yaml" || -f "${SRC_DIR}/yarn.lock" ]]; then
    command -v node >/dev/null 2>&1 || { curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs; }
  fi
  if grep -Rqi "mysqlclient" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(build-essential pkg-config default-libmysqlclient-dev)
  fi
  if grep -Rqi "Pillow" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(libjpeg-dev zlib1g-dev)
  fi
  if grep -Rqi "pytesseract" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(tesseract-ocr)
  fi
  if grep -Rqi "SpeechRecognition" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(flac)
  fi
  if [[ -f "${SRC_DIR}/go.mod" ]]; then
    pkgs+=(golang-go)
  fi
  if [[ -f "${SRC_DIR}/Cargo.toml" ]]; then
    pkgs+=(build-essential pkg-config libssl-dev)
  fi
  local repo_pkgs
  repo_pkgs=$(read_repo_system_packages)
  if [[ -n "$repo_pkgs" ]]; then
    pkgs+=( $repo_pkgs )
  fi
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    local unique_pkgs
    unique_pkgs=$(printf '%s
' "${pkgs[@]}" | awk 'NF && !seen[$0]++')
    log "Installing repo-required system packages"
    apt-get install -y ${unique_pkgs}
  else
    log "No additional repo-required system packages detected"
  fi
}

mkdir -p "${APP_DIR}" "${STATE_DIR}"
git_sync_repo
cd "${SRC_DIR}"
printf "
%b[+] Deployed repo commit:%b %s

" "$C_GREEN" "$C_RESET" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -d "${SRC_DIR}/deploy/systemd" ]]; then
  printf "%b[+] Found repo systemd templates:%b %s

" "$C_GREEN" "$C_RESET" "$(find "${SRC_DIR}/deploy/systemd" -maxdepth 1 -type f 2>/dev/null | sed 's#^.*/##' | tr '
' ' ' | sed 's/ *$//')"
else
  warn "Repo systemd templates directory not found"
fi
printf "
%b[+] Deployed repo commit:%b %s

" "$C_GREEN" "$C_RESET" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [[ -f "requirements.txt" ]]; then
  ensure_venv "${APP_DIR}/venv"
  "${APP_DIR}/venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "${APP_DIR}/venv/bin/python" -m pip install -r requirements.txt
fi
if [[ -f "backend/requirements.txt" ]]; then
  ensure_venv "${SRC_DIR}/backend/.venv"
  "${SRC_DIR}/backend/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "${SRC_DIR}/backend/.venv/bin/python" -m pip install -r backend/requirements.txt
fi
if [[ -f "pyproject.toml" ]]; then
  ensure_venv "${APP_DIR}/venv"
  "${APP_DIR}/venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "${APP_DIR}/venv/bin/python" -m pip install .
fi
if [[ -f "package-lock.json" ]]; then
  npm ci
elif [[ -f "package.json" ]]; then
  npm install
fi
if [[ -f "pnpm-lock.yaml" ]]; then
  npm install -g pnpm
  pnpm install --frozen-lockfile || pnpm install
fi
if [[ -f "yarn.lock" ]]; then
  npm install -g yarn
  yarn install --frozen-lockfile || yarn install
fi
if [[ -x "./${REPO_DEPLOY_HOOK}" ]]; then
  "./${REPO_DEPLOY_HOOK}"
elif [[ -f "./${REPO_DEPLOY_HOOK}" ]]; then
  bash "./${REPO_DEPLOY_HOOK}"
else
  log "No deploy hook found"
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -q "^${REPO_SERVICE_NAME}"; then
    log "Restarting ${REPO_SERVICE_NAME} after successful deploy"
    systemctl restart "${REPO_SERVICE_NAME}" || systemctl start "${REPO_SERVICE_NAME}"
    systemctl --no-pager --full status "${REPO_SERVICE_NAME}" || true
  fi
fi
EOM
chmod +x "${BIN_DIR}/deploy-update.sh"
chown "${APP_USER}:${APP_GROUP}" "${BIN_DIR}/deploy-update.sh"

log "Cloning/updating repository first"
sudo -u "${APP_USER}" bash "${BIN_DIR}/deploy-update.sh"

install_repo_system_packages

if [[ -f "${SRC_DIR}/backend/requirements.txt" || -f "${SRC_DIR}/requirements.txt" || -f "${SRC_DIR}/pyproject.toml" ]]; then
  ensure_python
fi

log "Writing full deploy runner"
cat > "${BIN_DIR}/deploy-update.sh" <<'EOM'
#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/myapp/deploy.env
export HOME="/home/${APP_USER}"
export GIT_SSH_COMMAND="ssh -i ${SSH_KEY_PATH} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS_PATH}"

C_RESET=""
C_GREEN=""
C_RED=""
C_YELLOW=""
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
fi

log() { printf "
%b[+] %s%b

" "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf "
%b[!] %s%b

" "$C_YELLOW" "$*" "$C_RESET"; }
countdown() { local s="$1"; while [[ "$s" -gt 0 ]]; do printf '%b[!] Retrying in %02d seconds...%b' "$C_YELLOW" "$s" "$C_RESET"; sleep 1; s=$((s-1)); done; printf '%40s' ''; }
clear_stale_git_lock() {
  local lock_file="${SRC_DIR}/.git/index.lock"
  [[ -f "$lock_file" ]] || return 0
  if command -v lsof >/dev/null 2>&1 && lsof "$lock_file" >/dev/null 2>&1; then
    return 1
  fi
  rm -f "$lock_file"
}
git_sync_repo() {
  local attempt
  for attempt in 1 2 3; do
    if [[ ! -d "${SRC_DIR}/.git" ]]; then
      log "Cloning repository"
      git clone --branch "${REPO_BRANCH}" "${REPO_SSH_URL}" "${SRC_DIR}" && return 0
    else
      clear_stale_git_lock || true
      log "Updating repository"
      if git -C "${SRC_DIR}" fetch origin && git -C "${SRC_DIR}" checkout "${REPO_BRANCH}" && git -C "${SRC_DIR}" reset --hard "origin/${REPO_BRANCH}"; then
        return 0
      fi
    fi
    if [[ -f "${SRC_DIR}/.git/index.lock" && "$attempt" -lt 3 ]]; then
      warn "Git index.lock detected; retrying in 60 seconds"
      countdown 60
      clear_stale_git_lock || true
      continue
    fi
    return 1
  done
}
ensure_venv() {
  local venv_path="$1"
  if [[ -d "$venv_path" ]] && [[ ! -x "$venv_path/bin/python" || ! -x "$venv_path/bin/pip" ]]; then
    warn "Broken virtualenv detected at ${venv_path}; recreating it"
    rm -rf "$venv_path"
  fi
  [[ -d "$venv_path" ]] || python3 -m venv "$venv_path"
}
read_repo_system_packages() {
  local file="${SRC_DIR}/deploy/system-packages.txt"
  if [[ -f "$file" ]]; then
    grep -vE '^(\s*#|\s*$)' "$file" | tr '
' ' '
  fi
}
install_repo_system_packages() {
  local pkgs=()
  if [[ -f "${SRC_DIR}/backend/requirements.txt" || -f "${SRC_DIR}/requirements.txt" || -f "${SRC_DIR}/pyproject.toml" ]]; then
    pkgs+=(python3 python3-pip python3-venv)
  fi
  if [[ -f "${SRC_DIR}/package.json" || -f "${SRC_DIR}/backend/package.json" || -f "${SRC_DIR}/pnpm-lock.yaml" || -f "${SRC_DIR}/yarn.lock" ]]; then
    command -v node >/dev/null 2>&1 || { curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs; }
  fi
  if grep -Rqi "mysqlclient" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(build-essential pkg-config default-libmysqlclient-dev)
  fi
  if grep -Rqi "Pillow" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(libjpeg-dev zlib1g-dev)
  fi
  if grep -Rqi "pytesseract" "${SRC_DIR}"/backend/requirements.txt "${SRC_DIR}"/requirements.txt 2>/dev/null; then
    pkgs+=(tesseract-ocr)
  fi
  if grep -Rqi "SpeechRecognition" "${SRC_DIR}/backend/requirements.txt" "${SRC_DIR}/requirements.txt" 2>/dev/null; then
    pkgs+=(flac)
  fi
  if [[ -f "${SRC_DIR}/go.mod" ]]; then
    pkgs+=(golang-go)
  fi
  if [[ -f "${SRC_DIR}/Cargo.toml" ]]; then
    pkgs+=(build-essential pkg-config libssl-dev)
  fi
  local repo_pkgs
  repo_pkgs=$(read_repo_system_packages)
  if [[ -n "$repo_pkgs" ]]; then
    pkgs+=( $repo_pkgs )
  fi
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    local unique_pkgs
    unique_pkgs=$(printf '%s
' "${pkgs[@]}" | awk 'NF && !seen[$0]++')
    log "Installing repo-required system packages"
    apt-get install -y ${unique_pkgs}
  else
    log "No additional repo-required system packages detected"
  fi
}

mkdir -p "${APP_DIR}" "${STATE_DIR}"
git_sync_repo
cd "${SRC_DIR}"
printf "
%b[+] Deployed repo commit:%b %s

" "$C_GREEN" "$C_RESET" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -d "${SRC_DIR}/deploy/systemd" ]]; then
  printf "%b[+] Found repo systemd templates:%b %s

" "$C_GREEN" "$C_RESET" "$(find "${SRC_DIR}/deploy/systemd" -maxdepth 1 -type f 2>/dev/null | sed 's#^.*/##' | tr '
' ' ' | sed 's/ *$//')"
fi
install_repo_system_packages
if [[ -f "requirements.txt" ]]; then
  ensure_venv "${APP_DIR}/venv"
  "${APP_DIR}/venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "${APP_DIR}/venv/bin/python" -m pip install -r requirements.txt
fi
if [[ -f "backend/requirements.txt" ]]; then
  ensure_venv "${SRC_DIR}/backend/.venv"
  "${SRC_DIR}/backend/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "${SRC_DIR}/backend/.venv/bin/python" -m pip install -r backend/requirements.txt
fi
if [[ -f "pyproject.toml" ]]; then
  ensure_venv "${APP_DIR}/venv"
  "${APP_DIR}/venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "${APP_DIR}/venv/bin/python" -m pip install .
fi
if [[ -f "package-lock.json" ]]; then
  npm ci
elif [[ -f "package.json" ]]; then
  npm install
fi
if [[ -f "pnpm-lock.yaml" ]]; then
  npm install -g pnpm
  pnpm install --frozen-lockfile || pnpm install
fi
if [[ -f "yarn.lock" ]]; then
  npm install -g yarn
  yarn install --frozen-lockfile || yarn install
fi
if [[ -x "./${REPO_DEPLOY_HOOK}" ]]; then
  "./${REPO_DEPLOY_HOOK}"
elif [[ -f "./${REPO_DEPLOY_HOOK}" ]]; then
  bash "./${REPO_DEPLOY_HOOK}"
else
  log "No deploy hook found"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^${REPO_SERVICE_NAME}"; then
  log "Restarting ${REPO_SERVICE_NAME} after successful deploy"
  systemctl restart "${REPO_SERVICE_NAME}" || systemctl start "${REPO_SERVICE_NAME}"
  systemctl --no-pager --full status "${REPO_SERVICE_NAME}" || true
fi
EOM

sed -i "s|/opt/myapp|${APP_DIR}|g" "${BIN_DIR}/deploy-update.sh"
chmod +x "${BIN_DIR}/deploy-update.sh"
chown "${APP_USER}:${APP_GROUP}" "${BIN_DIR}/deploy-update.sh"

log "Running full deploy"
if sudo -u "${APP_USER}" bash "${BIN_DIR}/deploy-update.sh"; then
  install_repo_systemd_unit
  restart_repo_service
else
  fail "Full deploy failed"
fi

log "Writing autodeploy systemd units"
cat > "/etc/systemd/system/${APP_NAME}-autodeploy.service" <<EOM
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
EOM
cat > "/etc/systemd/system/${APP_NAME}-git-pull.service" <<EOM
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
EOM
cat > "/etc/systemd/system/${APP_NAME}-git-pull.timer" <<EOM
[Unit]
Description=Run periodic git fetch for ${APP_NAME}

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=${APP_NAME}-git-pull.service

[Install]
WantedBy=timers.target
EOM
cat > "/etc/systemd/system/${APP_NAME}-autodeploy.path" <<EOM
[Unit]
Description=Watch ${SRC_DIR} for autodeploy trigger

[Path]
PathChanged=${SRC_DIR}/.git/FETCH_HEAD
PathChanged=${SRC_DIR}/package.json
PathChanged=${SRC_DIR}/requirements.txt
PathChanged=${SRC_DIR}/backend/requirements.txt
PathChanged=${SRC_DIR}/pyproject.toml
Unit=${APP_NAME}-autodeploy.service

[Install]
WantedBy=multi-user.target
EOM
systemctl daemon-reload
systemctl enable --now "${APP_NAME}-autodeploy.path"
systemctl enable --now "${APP_NAME}-git-pull.timer"
log "Bootstrap completed"
