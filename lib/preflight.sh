#!/usr/bin/env bash
# Pre-deployment checks

preflight_check_proxmox() {
  require_cmd pct "This script must be run on a Proxmox VE host."
}

preflight_check_ssh_key() {
  if [[ -f /root/.ssh/id_ed25519 ]]; then
    success "SSH key found: /root/.ssh/id_ed25519"
  elif [[ -f /root/.ssh/id_rsa ]]; then
    success "SSH key found: /root/.ssh/id_rsa"
  else
    warn "No SSH key found on this Proxmox host."
    info "Generate one with: ssh-keygen -t ed25519"
    info "Then add the public key to your GitHub account."
    read -rp "$(echo -e "${BOLD}Continue without SSH key? [y/N]${NC} ")" _continue
    if [[ "${_continue,,}" != "y" ]]; then exit 1; fi
  fi
}

preflight_check_cloudflare() {
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    return 0
  fi

  info "Validating Cloudflare API token..."
  local response
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify")

  local http_code
  http_code=$(echo "${response}" | tail -1)
  local body
  body=$(echo "${response}" | sed '$d')

  if [[ "${http_code}" != "200" ]]; then
    error "Cloudflare API token validation failed (HTTP ${http_code}). Check CF_API_TOKEN."
  fi

  local status
  status=$(echo "${body}" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [[ "${status}" != "active" ]]; then
    error "Cloudflare API token is not active (status: ${status})"
  fi

  success "Cloudflare API token valid"
}

preflight_check_github() {
  if [[ -z "${GH_PAT:-}" ]]; then
    return 0
  fi

  info "Validating GitHub token..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GH_PAT}" \
    "https://api.github.com/user")

  if [[ "${http_code}" != "200" ]]; then
    error "GitHub token validation failed (HTTP ${http_code}). Check GH_PAT."
  fi

  success "GitHub token valid"
}

run_preflight() {
  header "Preflight Checks"
  preflight_check_proxmox
  preflight_check_ssh_key
  preflight_check_cloudflare
  preflight_check_github
  success "All preflight checks passed"
}
