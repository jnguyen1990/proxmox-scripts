#!/usr/bin/env bash
# Cloudflare tunnel creation via API + cloudflared daemon in LXC

CF_API_BODY=""

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local args=(-s -w "\n%{http_code}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  if [[ -n "${data}" ]]; then
    args+=(-X "${method}" -d "${data}")
  else
    args+=(-X "${method}")
  fi

  local response
  response=$(curl "${args[@]}" "https://api.cloudflare.com/client/v4${endpoint}")

  local http_code
  http_code=$(echo "${response}" | tail -1)
  CF_API_BODY=$(echo "${response}" | sed '$d')

  if ! [[ "${http_code}" =~ ^[0-9]+$ ]] || [[ "${http_code}" -lt 200 ]] || [[ "${http_code}" -ge 300 ]]; then
    local errors
    errors=$(echo "${CF_API_BODY}" | grep -o '"message" *: *"[^"]*"' | head -3)
    error "Cloudflare API error (HTTP ${http_code}): ${errors:-${CF_API_BODY}}"
  fi
}

cf_create_tunnel() {
  info "Creating Cloudflare tunnel..."

  local tunnel_name="${REPO_NAME}-tunnel"

  # Check if tunnel already exists
  cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${tunnel_name}&is_deleted=false"
  local existing_id
  existing_id=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ -n "${existing_id}" ]]; then
    warn "Tunnel '${tunnel_name}' already exists (${existing_id}), deleting old tunnel..."
    cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${existing_id}"
    success "Old tunnel deleted"
  fi

  # Generate a random 32-byte secret
  TUNNEL_SECRET=$(openssl rand -base64 32)

  cf_api POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
    "{\"name\":\"${tunnel_name}\",\"tunnel_secret\":\"${TUNNEL_SECRET}\",\"config_src\":\"local\"}"

  TUNNEL_ID=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
  if [[ -z "${TUNNEL_ID}" ]]; then
    error "Failed to extract tunnel ID from response: ${CF_API_BODY}"
  fi

  success "Tunnel created: ${tunnel_name} (${TUNNEL_ID})"
}

cf_create_dns_route() {
  local subdomain="${CF_SUBDOMAIN:-${REPO_NAME}}"
  info "Creating DNS record: ${subdomain}.${CF_DOMAIN} -> tunnel..."

  # Check if record already exists
  cf_api GET "/zones/${CF_ZONE_ID}/dns_records?name=${subdomain}.${CF_DOMAIN}&type=CNAME"
  local count
  count=$(echo "${CF_API_BODY}" | grep -o '"count" *: *[0-9]*' | head -1 | sed 's/.*: *//' || true)

  if [[ "${count:-0}" -gt 0 ]]; then
    warn "DNS record for ${subdomain}.${CF_DOMAIN} already exists, updating..."
    local record_id
    record_id=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
    cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
      "{\"type\":\"CNAME\",\"name\":\"${subdomain}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}"
  else
    cf_api POST "/zones/${CF_ZONE_ID}/dns_records" \
      "{\"type\":\"CNAME\",\"name\":\"${subdomain}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}"
  fi

  success "DNS record created: ${subdomain}.${CF_DOMAIN}"
}

cf_install_cloudflared() {
  info "Installing cloudflared in container..."

  pct exec "${CTID}" -- bash -c 'set -e
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq
    apt-get install -y -qq cloudflared >/dev/null 2>&1
  '
  success "cloudflared installed"
}

cf_write_credentials() {
  info "Writing tunnel credentials..."

  local creds_json="{\"AccountTag\":\"${CF_ACCOUNT_ID}\",\"TunnelSecret\":\"${TUNNEL_SECRET}\",\"TunnelID\":\"${TUNNEL_ID}\"}"

  pct exec "${CTID}" -- bash -c "set -e
    mkdir -p /etc/cloudflared
    cat > /etc/cloudflared/${TUNNEL_ID}.json << 'CREDS_EOF'
${creds_json}
CREDS_EOF
    chmod 600 /etc/cloudflared/${TUNNEL_ID}.json
  "
  success "Tunnel credentials written"
}

cf_write_config() {
  info "Writing cloudflared config..."

  local config_content
  config_content=$(render_template "${SCRIPT_DIR}/templates/cloudflared.yml.tmpl")

  pct exec "${CTID}" -- bash -c "cat > /etc/cloudflared/config.yml << 'CF_CONFIG_EOF'
${config_content}
CF_CONFIG_EOF"
  success "cloudflared config written"
}

cf_enable_service() {
  info "Enabling cloudflared service..."

  pct exec "${CTID}" -- bash -c '
    cloudflared service install 2>/dev/null || true
    systemctl enable cloudflared
    systemctl restart cloudflared
  '
  success "cloudflared service running"
}

cf_api_optional() {
  # Like cf_api but warns instead of erroring on failure
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local args=(-s -w "\n%{http_code}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  if [[ -n "${data}" ]]; then
    args+=(-X "${method}" -d "${data}")
  else
    args+=(-X "${method}")
  fi

  local response
  response=$(curl "${args[@]}" "https://api.cloudflare.com/client/v4${endpoint}")

  local http_code
  http_code=$(echo "${response}" | tail -1)
  CF_API_BODY=$(echo "${response}" | sed '$d')

  if ! [[ "${http_code}" =~ ^[0-9]+$ ]] || [[ "${http_code}" -lt 200 ]] || [[ "${http_code}" -ge 300 ]]; then
    local errors
    errors=$(echo "${CF_API_BODY}" | grep -o '"message" *: *"[^"]*"' | head -3)
    warn "Cloudflare API error (HTTP ${http_code}): ${errors:-${CF_API_BODY}}"
    return 1
  fi
  return 0
}

cf_create_access_app() {
  # Only needed when GitHub Actions is also enabled
  if [[ -z "${GH_PAT:-}" ]]; then
    return 0
  fi

  # If service token credentials are already saved, skip Access setup
  if [[ -n "${CF_ACCESS_CLIENT_ID:-}" && -n "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
    info "Cloudflare Access service token loaded from secrets"
    return 0
  fi

  local subdomain="${CF_SUBDOMAIN:-${REPO_NAME}}"

  # ── Find or create Access application ──
  info "Setting up Cloudflare Access for SSH..."

  # Try to create Access application; handle conflict if it already exists
  local app_id=""

  if cf_api_optional POST "/accounts/${CF_ACCOUNT_ID}/access/apps" \
    "{\"name\":\"${REPO_NAME}-ssh\",\"domain\":\"${subdomain}.${CF_DOMAIN}\",\"type\":\"ssh\",\"session_duration\":\"24h\"}"; then
    app_id=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    success "Access app created"
  else
    # 409 = already exists. Delete it and recreate.
    info "Access app conflict, cleaning up existing app..."
    if cf_api_optional GET "/accounts/${CF_ACCOUNT_ID}/access/apps"; then
      # Find the app ID that owns our domain
      local all_apps="${CF_API_BODY}"
      # Extract IDs of all apps, check each one
      local ids
      ids=$(echo "${all_apps}" | grep -o '"id" *: *"[^"]*"' | cut -d'"' -f4 || true)
      for id in ${ids}; do
        if echo "${all_apps}" | grep -q "${subdomain}.${CF_DOMAIN}"; then
          # Try deleting this app
          if cf_api_optional DELETE "/accounts/${CF_ACCOUNT_ID}/access/apps/${id}"; then
            info "Deleted existing Access app ${id}"
          fi
        fi
      done
    fi
    # Retry creation
    if cf_api_optional POST "/accounts/${CF_ACCOUNT_ID}/access/apps" \
      "{\"name\":\"${REPO_NAME}-ssh\",\"domain\":\"${subdomain}.${CF_DOMAIN}\",\"type\":\"ssh\",\"session_duration\":\"24h\"}"; then
      app_id=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      success "Access app created"
    else
      warn "Could not create Access app after cleanup. Check CF dashboard manually."
      return 0
    fi
  fi

  if [[ -z "${app_id}" ]]; then
    warn "Failed to extract Access app ID."
    return 0
  fi

  # ── Find or create service token ──
  # Service tokens are shared across all apps, so check if one exists
  local token_id=""
  if cf_api_optional GET "/accounts/${CF_ACCOUNT_ID}/access/service_tokens"; then
    # Look for existing deploy token
    token_id=$(echo "${CF_API_BODY}" | grep -o "{[^}]*\"name\":\"proxmox-deploy\"[^}]*}" | grep -o '"client_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [[ -n "${token_id}" ]]; then
      CF_ACCESS_CLIENT_ID="${token_id}"
      info "Existing service token found (proxmox-deploy), but secret is not retrievable"
      warn "You need the CF_ACCESS_CLIENT_SECRET from when it was first created."
      warn "If lost, delete the 'proxmox-deploy' token in CF dashboard and re-run."
      return 0
    fi
  fi

  info "Creating service token for GitHub Actions deploys..."
  if ! cf_api_optional POST "/accounts/${CF_ACCOUNT_ID}/access/service_tokens" \
    "{\"name\":\"proxmox-deploy\"}"; then
    warn "Failed to create service token."
    return 0
  fi

  CF_ACCESS_CLIENT_ID=$(echo "${CF_API_BODY}" | grep -o '"client_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
  CF_ACCESS_CLIENT_SECRET=$(echo "${CF_API_BODY}" | grep -o '"client_secret" *: *"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ -z "${CF_ACCESS_CLIENT_ID:-}" || -z "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
    warn "Failed to extract service token credentials."
    return 0
  fi

  # Save to secrets file so we never need to create this again
  if [[ -f "${SECRETS_FILE:-}" ]]; then
    cat >> "${SECRETS_FILE}" << EOF

# Cloudflare Access (for GitHub Actions SSH proxy)
CF_ACCESS_CLIENT_ID="${CF_ACCESS_CLIENT_ID}"
CF_ACCESS_CLIENT_SECRET="${CF_ACCESS_CLIENT_SECRET}"
EOF
    info "Service token saved to ${SECRETS_FILE}"
  fi

  # ── Create policy allowing service token on this app ──
  cf_api_optional POST "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies" \
    "{\"name\":\"${REPO_NAME}-deploy-policy\",\"decision\":\"non_identity\",\"include\":[{\"service_token\":{\"token_id\":\"${CF_ACCESS_CLIENT_ID}\"}}]}" || true

  success "Cloudflare Access configured for GitHub Actions SSH"
}

cf_setup() {
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    return 0
  fi

  header "Setting Up Cloudflare Tunnel"

  CF_SUBDOMAIN="${CF_SUBDOMAIN:-${REPO_NAME}}"

  cf_create_tunnel
  cf_create_dns_route
  cf_install_cloudflared
  cf_write_credentials
  cf_write_config
  cf_enable_service
  cf_create_access_app

  success "Cloudflare tunnel active: https://${CF_SUBDOMAIN}.${CF_DOMAIN}"
}
