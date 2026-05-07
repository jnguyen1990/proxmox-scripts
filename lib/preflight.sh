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

  # Capture both body and headers so we can read X-OAuth-Scopes for classic
  # PATs (fine-grained PATs don't include this header — for those we test
  # write access directly with a no-op repo edit instead).
  local response_file
  response_file=$(mktemp)
  local http_code
  http_code=$(curl -s -o /dev/null -D "${response_file}" -w "%{http_code}" \
    -H "Authorization: token ${GH_PAT}" \
    "https://api.github.com/user")

  if [[ "${http_code}" != "200" ]]; then
    rm -f "${response_file}"
    error "GitHub token validation failed (HTTP ${http_code}). Check GH_PAT (expired? wrong scopes? for fine-grained, ensure the token has access to ${GITHUB_USER:-your-user}/${REPO_NAME:-your-repo})."
  fi

  local scopes
  scopes=$(grep -i '^x-oauth-scopes:' "${response_file}" | sed 's/^[^:]*: *//' | tr -d '\r\n' || true)
  rm -f "${response_file}"

  if [[ -n "${scopes}" ]]; then
    # Classic PAT: scopes header is present. Require repo + workflow.
    if ! echo "${scopes}" | grep -q '\brepo\b'; then
      error "GitHub PAT is missing 'repo' scope (got: ${scopes}). Mint a new classic PAT at https://github.com/settings/tokens with 'repo' + 'workflow'."
    fi
    if ! echo "${scopes}" | grep -q '\bworkflow\b'; then
      error "GitHub PAT is missing 'workflow' scope (got: ${scopes}). Required to push .github/workflows/deploy.yml. Mint a new PAT with 'repo' + 'workflow'."
    fi
    success "GitHub token valid (scopes: ${scopes})"
  else
    # Fine-grained PAT: header absent. Test write access directly by hitting
    # the target repo's contents endpoint — must succeed (200 if the file
    # exists, 404 if not). 401/403 means the token can't write.
    info "Fine-grained PAT detected — verifying write access to ${GITHUB_USER}/${REPO_NAME}..."
    local write_code
    write_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: token ${GH_PAT}" \
      "https://api.github.com/repos/${GITHUB_USER}/${REPO_NAME}")
    if [[ "${write_code}" == "404" ]]; then
      error "Fine-grained PAT cannot see repo ${GITHUB_USER}/${REPO_NAME}. In the token's settings, grant access to this repo with 'Contents: write' + 'Actions: write' + 'Secrets: write' permissions."
    elif [[ "${write_code}" != "200" ]]; then
      error "Fine-grained PAT validation failed against ${GITHUB_USER}/${REPO_NAME} (HTTP ${write_code}). Required permissions: 'Contents: write', 'Actions: write', 'Secrets: write'."
    fi
    success "GitHub token valid (fine-grained, scoped to ${GITHUB_USER}/${REPO_NAME})"
  fi
}

preflight_check_secret_encryption() {
  # PyNaCl is needed by lib/github-actions.sh to seal-box-encrypt repo
  # secrets before pushing them via the API. If it isn't there, the script
  # used to soft-warn and continue — leaving GH Actions broken on the
  # follow-up deploy. Auto-install instead so the deploy is one-shot.
  if [[ -z "${GH_PAT:-}" ]]; then
    return 0
  fi

  if python3 -c "from nacl.public import PublicKey, SealedBox" 2>/dev/null; then
    success "PyNaCl available for GitHub secret encryption"
    return 0
  fi

  if command -v gh &>/dev/null; then
    success "gh CLI available for GitHub secret encryption"
    return 0
  fi

  info "Installing python3-pip + PyNaCl for GitHub secret encryption..."
  if apt-get install -y -qq python3-pip >/dev/null 2>&1 && \
     pip3 install --quiet --break-system-packages pynacl >/dev/null 2>&1; then
    success "PyNaCl installed"
  else
    warn "Failed to auto-install PyNaCl. Install it manually with: pip3 install --break-system-packages pynacl"
    warn "Alternatively, install gh CLI: apt install gh"
    warn "Without one of these, GitHub Actions secrets will be printed instead of pushed."
  fi
}

run_preflight() {
  header "Preflight Checks"
  preflight_check_proxmox
  preflight_check_ssh_key
  preflight_check_cloudflare
  preflight_check_github
  preflight_check_secret_encryption
  success "All preflight checks passed"
}
