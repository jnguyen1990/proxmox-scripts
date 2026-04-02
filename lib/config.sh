#!/usr/bin/env bash
# Configuration loading: file-based or interactive prompts

SECRETS_FILE="/root/.proxmox-deploy-secrets"

# Prompt for a value only if the variable is empty
_prompt_if_empty() {
  local label="$1"
  local varname="$2"

  if [[ -n "${!varname:-}" ]]; then
    info "${label}: (saved) ****${!varname: -4}"
    return
  fi

  read -rp "$(echo -e "${BOLD}${label}${NC}: ")" "${varname}"
  [[ -z "${!varname}" ]] && error "${varname} is required"
}

# Offer to save tokens/IDs for future deploys
_maybe_save_secrets() {
  local has_new_secrets=false

  # Check if there are secrets that aren't already saved
  if [[ -n "${CF_API_TOKEN:-}" || -n "${GH_PAT:-}" ]]; then
    if [[ -f "${SECRETS_FILE}" ]]; then
      # shellcheck source=/dev/null
      local _existing_cf _existing_gh
      _existing_cf=$(grep -c "CF_API_TOKEN" "${SECRETS_FILE}" 2>/dev/null || echo 0)
      _existing_gh=$(grep -c "GH_PAT" "${SECRETS_FILE}" 2>/dev/null || echo 0)
      [[ -n "${CF_API_TOKEN:-}" && "${_existing_cf}" == "0" ]] && has_new_secrets=true
      [[ -n "${GH_PAT:-}" && "${_existing_gh}" == "0" ]] && has_new_secrets=true
    else
      has_new_secrets=true
    fi
  fi

  if [[ "${has_new_secrets}" == "true" ]]; then
    echo ""
    read -rp "$(echo -e "${BOLD}Save tokens to ${SECRETS_FILE} for future deploys?${NC} [Y/n]: ")" _save
    if [[ "${_save,,}" != "n" ]]; then
      _write_secrets_file
      success "Secrets saved to ${SECRETS_FILE}"
    fi
  fi
}

_write_secrets_file() {
  cat > "${SECRETS_FILE}" << EOF
# Proxmox deploy secrets - auto-generated
# Tokens and IDs reused across deploys
# chmod 600 - root-only access
EOF

  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    cat >> "${SECRETS_FILE}" << EOF

# Cloudflare
CF_API_TOKEN="${CF_API_TOKEN}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_DOMAIN="${CF_DOMAIN:-}"
EOF
  fi

  if [[ -n "${GH_PAT:-}" ]]; then
    cat >> "${SECRETS_FILE}" << EOF

# GitHub
GH_PAT="${GH_PAT}"
EOF
  fi

  chmod 600 "${SECRETS_FILE}"
}

load_config() {
  local config_file="${SCRIPT_DIR}/deploy.conf"

  # Source secrets file first (tokens, IDs that persist across deploys)
  if [[ -f "${SECRETS_FILE}" ]]; then
    info "Loading secrets from ${SECRETS_FILE}"
    # shellcheck source=/dev/null
    source "${SECRETS_FILE}"
  fi

  # Source config file if it exists (overrides secrets for non-secret values)
  if [[ -f "${config_file}" ]]; then
    info "Loading config from deploy.conf"
    # shellcheck source=/dev/null
    source "${config_file}"
  fi

  # Environment variables override both

  # Interactive prompts for missing required values
  if [[ -z "${REPO_NAME:-}" ]]; then
    read -rp "$(echo -e "${BOLD}GitHub repo name${NC} (e.g. hub, budgeter): ")" REPO_NAME
    [[ -z "${REPO_NAME}" ]] && error "Repo name is required"
  fi

  # Defaults for optional values
  GITHUB_USER="${GITHUB_USER:-jnguyen1990}"
  RUBY_VERSION="${RUBY_VERSION:-3.3.11}"
  DEBIAN_TEMPLATE="${DEBIAN_TEMPLATE:-debian-12-standard}"
  APP_PORT="${APP_PORT:-3000}"
  LXC_RAM="${LXC_RAM:-1024}"
  LXC_DISK="${LXC_DISK:-4}"
  LXC_CORES="${LXC_CORES:-1}"
  STORAGE="${STORAGE:-local-lvm}"

  # Derived values
  APP_DIR="/opt/${REPO_NAME}"
  REPO_URL="git@github.com:${GITHUB_USER}/${REPO_NAME}.git"

  # Interactive prompts for specs if not from config file
  if [[ ! -f "${config_file}" ]]; then
    read -rp "$(echo -e "${BOLD}App port${NC} [${APP_PORT}]: ")" _port
    APP_PORT="${_port:-${APP_PORT}}"

    read -rp "$(echo -e "${BOLD}RAM (MB)${NC} [${LXC_RAM}]: ")" _ram
    LXC_RAM="${_ram:-${LXC_RAM}}"

    read -rp "$(echo -e "${BOLD}Disk (GB)${NC} [${LXC_DISK}]: ")" _disk
    LXC_DISK="${_disk:-${LXC_DISK}}"

    read -rp "$(echo -e "${BOLD}CPU cores${NC} [${LXC_CORES}]: ")" _cores
    LXC_CORES="${_cores:-${LXC_CORES}}"

    read -rp "$(echo -e "${BOLD}Storage pool${NC} [${STORAGE}]: ")" _storage
    STORAGE="${_storage:-${STORAGE}}"

    # ── Cloudflare Tunnel ──
    echo ""
    if [[ -n "${CF_API_TOKEN:-}" ]]; then
      info "Cloudflare credentials loaded from ${SECRETS_FILE}"
      read -rp "$(echo -e "${BOLD}Set up Cloudflare Tunnel?${NC} [Y/n]: ")" _cf
      _cf="${_cf:-y}"
    else
      read -rp "$(echo -e "${BOLD}Set up Cloudflare Tunnel?${NC} [y/N]: ")" _cf
    fi
    if [[ "${_cf,,}" == "y" ]]; then
      _prompt_if_empty "Cloudflare API token" CF_API_TOKEN
      _prompt_if_empty "Cloudflare Account ID" CF_ACCOUNT_ID
      _prompt_if_empty "Cloudflare Zone ID" CF_ZONE_ID
      _prompt_if_empty "Domain (e.g. example.com)" CF_DOMAIN

      read -rp "$(echo -e "${BOLD}Subdomain${NC} [${REPO_NAME}]: ")" _sub
      CF_SUBDOMAIN="${_sub:-${REPO_NAME}}"
    fi

    # ── GitHub Actions ──
    echo ""
    if [[ -n "${GH_PAT:-}" ]]; then
      info "GitHub token loaded from ${SECRETS_FILE}"
      read -rp "$(echo -e "${BOLD}Set up GitHub Actions auto-deploy?${NC} [Y/n]: ")" _gh
      _gh="${_gh:-y}"
    else
      read -rp "$(echo -e "${BOLD}Set up GitHub Actions auto-deploy?${NC} [y/N]: ")" _gh
    fi
    if [[ "${_gh,,}" == "y" ]]; then
      _prompt_if_empty "GitHub personal access token" GH_PAT
    fi

    # ── Offer to save secrets ──
    _maybe_save_secrets
  fi
}

validate_config() {
  [[ -z "${REPO_NAME:-}" ]] && error "REPO_NAME is required"
  [[ -z "${GITHUB_USER:-}" ]] && error "GITHUB_USER is required"

  echo ""
  info "App: ${REPO_NAME}"
  info "Repo: ${REPO_URL}"
  info "Port: ${APP_PORT}"
  info "Specs: ${LXC_CORES} core(s), ${LXC_RAM}MB RAM, ${LXC_DISK}GB disk"
  info "Storage: ${STORAGE}"
  [[ -n "${CF_API_TOKEN:-}" ]] && info "Cloudflare: ${CF_SUBDOMAIN:-${REPO_NAME}}.${CF_DOMAIN}"
  [[ -n "${GH_PAT:-}" ]] && info "GitHub Actions: enabled"
  echo ""

  # Only prompt for confirmation in interactive mode
  if [[ ! -f "${SCRIPT_DIR}/deploy.conf" ]]; then
    read -rp "$(echo -e "${BOLD}Proceed? [Y/n]${NC} ")" CONFIRM
    [[ "${CONFIRM,,}" == "n" ]] && exit 0
  fi
}
