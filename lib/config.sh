#!/usr/bin/env bash
# Configuration loading: file-based or interactive prompts

SECRETS_FILE="/root/.proxmox-deploy-secrets"

_read_value() {
  local label="$1"
  read -rp "$(echo -e "${BOLD}${label}${NC}: ")" _read_result
  if [[ -z "${_read_result}" ]]; then
    error "${label} is required"
  fi
}

# Offer to save tokens/IDs for future deploys
_maybe_save_secrets() {
  local has_new_secrets=false

  # Check if there are secrets that aren't already saved
  if [[ -n "${CF_API_TOKEN:-}" || -n "${GH_PAT:-}" || -n "${TS_AUTHKEY:-}" || -n "${INTER_APP_SECRET:-}" ]]; then
    if [[ -f "${SECRETS_FILE}" ]]; then
      # shellcheck source=/dev/null
      local _existing_cf _existing_gh _existing_ts _existing_ias
      _existing_cf=$(grep -c "CF_API_TOKEN" "${SECRETS_FILE}" 2>/dev/null || echo 0)
      _existing_gh=$(grep -c "GH_PAT" "${SECRETS_FILE}" 2>/dev/null || echo 0)
      _existing_ts=$(grep -c "TS_AUTHKEY" "${SECRETS_FILE}" 2>/dev/null || echo 0)
      _existing_ias=$(grep -c "INTER_APP_SECRET" "${SECRETS_FILE}" 2>/dev/null || echo 0)
      [[ -n "${CF_API_TOKEN:-}" && "${_existing_cf}" == "0" ]] && has_new_secrets=true
      [[ -n "${GH_PAT:-}" && "${_existing_gh}" == "0" ]] && has_new_secrets=true
      [[ -n "${TS_AUTHKEY:-}" && "${_existing_ts}" == "0" ]] && has_new_secrets=true
      [[ -n "${INTER_APP_SECRET:-}" && "${_existing_ias}" == "0" ]] && has_new_secrets=true
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

  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    cat >> "${SECRETS_FILE}" << EOF

# Tailscale
TS_AUTHKEY="${TS_AUTHKEY}"
EOF
  fi

  if [[ -n "${INTER_APP_SECRET:-}" ]]; then
    cat >> "${SECRETS_FILE}" << EOF

# Inter-app shared bearer token (personal_app_client gem)
INTER_APP_SECRET="${INTER_APP_SECRET}"
EOF
  fi

  if [[ -n "${RAILS_MASTER_KEY:-}" && -n "${REPO_NAME:-}" ]]; then
    local _app_key_var="RAILS_MASTER_KEY_$(echo "${REPO_NAME}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
    cat >> "${SECRETS_FILE}" << EOF

# Rails master key for ${REPO_NAME}
${_app_key_var}="${RAILS_MASTER_KEY}"
EOF
  fi

  chmod 600 "${SECRETS_FILE}"
}

# Resolve INTER_APP_SECRET via SECRETS_FILE → prompt → openssl-generate.
# Idempotent: a saved value short-circuits with a "(saved)" line. Called
# by both load_config (deploy) and repair so the secret gets populated
# regardless of which entrypoint runs.
ensure_inter_app_secret() {
  if [[ -n "${INTER_APP_SECRET:-}" ]]; then
    info "Inter-app secret: (saved) ****${INTER_APP_SECRET: -4}"
    return 0
  fi
  echo ""
  info "Shared bearer token for app-to-app HTTP calls (personal_app_client gem)."
  info "Same value across all apps. Press Enter to auto-generate."
  read -rp "$(echo -e "${BOLD}Inter-app secret${NC} (or Enter to generate): ")" INTER_APP_SECRET
  if [[ -z "${INTER_APP_SECRET}" ]]; then
    INTER_APP_SECRET=$(openssl rand -hex 32)
    info "Generated inter-app secret: ****${INTER_APP_SECRET: -4}"
  fi
  _maybe_save_secrets
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
    if [[ -z "${REPO_NAME}" ]]; then error "Repo name is required"; fi
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

  ensure_inter_app_secret

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

    # ── Rails Master Key (per-app) ──
    # Check for app-specific key first, then generic fallback
    local _app_key_var="RAILS_MASTER_KEY_$(echo "${REPO_NAME}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
    if [[ -n "${!_app_key_var:-}" ]]; then
      RAILS_MASTER_KEY="${!_app_key_var}"
    fi
    if [[ -z "${RAILS_MASTER_KEY:-}" ]]; then
      echo ""
      info "Find this in your app's config/master.key file"
      read -rp "$(echo -e "${BOLD}Rails master key for ${REPO_NAME}${NC} (or Enter to skip): ")" RAILS_MASTER_KEY
    else
      info "Rails master key for ${REPO_NAME}: (saved) ****${RAILS_MASTER_KEY: -4}"
    fi

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
      if [[ -n "${CF_API_TOKEN:-}" ]]; then
        info "Cloudflare API token: (saved) ****${CF_API_TOKEN: -4}"
      else
        _read_value "Cloudflare API token"; CF_API_TOKEN="${_read_result}"
      fi
      if [[ -n "${CF_ACCOUNT_ID:-}" ]]; then
        info "Cloudflare Account ID: (saved) ****${CF_ACCOUNT_ID: -4}"
      else
        _read_value "Cloudflare Account ID"; CF_ACCOUNT_ID="${_read_result}"
      fi
      if [[ -n "${CF_ZONE_ID:-}" ]]; then
        info "Cloudflare Zone ID: (saved) ****${CF_ZONE_ID: -4}"
      else
        _read_value "Cloudflare Zone ID"; CF_ZONE_ID="${_read_result}"
      fi
      if [[ -n "${CF_DOMAIN:-}" ]]; then
        info "Domain: ${CF_DOMAIN}"
      else
        _read_value "Domain (e.g. example.com)"; CF_DOMAIN="${_read_result}"
      fi

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
      if [[ -n "${GH_PAT:-}" ]]; then
        info "GitHub token: (saved) ****${GH_PAT: -4}"
      else
        _read_value "GitHub personal access token"; GH_PAT="${_read_result}"
      fi
    fi

    # ── Tailscale (for SSH access + GitHub Actions deploys) ──
    echo ""
    if [[ -n "${TS_AUTHKEY:-}" ]]; then
      info "Tailscale auth key loaded from ${SECRETS_FILE}"
      read -rp "$(echo -e "${BOLD}Set up Tailscale for SSH access?${NC} [Y/n]: ")" _ts
      _ts="${_ts:-y}"
    else
      read -rp "$(echo -e "${BOLD}Set up Tailscale for SSH access?${NC} [y/N]: ")" _ts
    fi
    if [[ "${_ts,,}" == "y" ]]; then
      if [[ -n "${TS_AUTHKEY:-}" ]]; then
        info "Tailscale auth key: (saved) ****${TS_AUTHKEY: -4}"
      else
        info "Get a reusable auth key from: https://login.tailscale.com/admin/settings/keys"
        _read_value "Tailscale auth key"; TS_AUTHKEY="${_read_result}"
      fi
    fi

    # ── Offer to save secrets ──
    _maybe_save_secrets
  fi
}

validate_config() {
  if [[ -z "${REPO_NAME:-}" ]]; then error "REPO_NAME is required"; fi
  if [[ -z "${GITHUB_USER:-}" ]]; then error "GITHUB_USER is required"; fi

  echo ""
  info "App: ${REPO_NAME}"
  info "Repo: ${REPO_URL}"
  info "Port: ${APP_PORT}"
  info "Specs: ${LXC_CORES} core(s), ${LXC_RAM}MB RAM, ${LXC_DISK}GB disk"
  info "Storage: ${STORAGE}"
  [[ -n "${CF_API_TOKEN:-}" ]] && info "Cloudflare: ${CF_SUBDOMAIN:-${REPO_NAME}}.${CF_DOMAIN}"
  [[ -n "${TS_AUTHKEY:-}" ]] && info "Tailscale: enabled"
  [[ -n "${GH_PAT:-}" ]] && info "GitHub Actions: enabled"
  echo ""

  # Only prompt for confirmation in interactive mode
  if [[ ! -f "${SCRIPT_DIR}/deploy.conf" ]]; then
    read -rp "$(echo -e "${BOLD}Proceed? [Y/n]${NC} ")" CONFIRM
    if [[ "${CONFIRM,,}" == "n" ]]; then exit 0; fi
  fi
}
