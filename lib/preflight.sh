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
    info "Generating ed25519 SSH key..."
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' -C "proxmox@$(hostname)" -q
    success "SSH key generated"
  fi

  # Show public key and verify it's on GitHub
  local pubkey
  if [[ -f /root/.ssh/id_ed25519.pub ]]; then
    pubkey=$(cat /root/.ssh/id_ed25519.pub)
  else
    pubkey=$(cat /root/.ssh/id_rsa.pub)
  fi

  echo ""
  echo -e "${YELLOW}${BOLD}── SSH Public Key ──${NC}"
  echo -e "Add this to GitHub (${CYAN}https://github.com/settings/keys${NC}) if not already added:"
  echo ""
  echo "${pubkey}"
  echo ""

  # Test GitHub SSH access
  info "Testing GitHub SSH access..."
  local ssh_output
  ssh_output=$(ssh -T git@github.com -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 2>&1 || true)
  if echo "${ssh_output}" | grep -qi "success"; then
    success "GitHub SSH access confirmed"
  else
    warn "GitHub SSH access failed."
    echo -e "  1. Copy the public key above"
    echo -e "  2. Add it at ${CYAN}https://github.com/settings/keys${NC}"
    echo -e "  3. Click ${BOLD}New SSH key${NC}, paste, and save"
    echo ""
    read -rp "$(echo -e "${BOLD}Press Enter once you've added the key (or Ctrl+C to cancel)...${NC}")" _
    # Re-test
    local ssh_output
  ssh_output=$(ssh -T git@github.com -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 2>&1 || true)
  if echo "${ssh_output}" | grep -qi "success"; then
      success "GitHub SSH access confirmed"
    else
      error "Still can't authenticate with GitHub. Check the key was added correctly."
    fi
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
  status=$(echo "${body}" | grep -o '"status" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
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
