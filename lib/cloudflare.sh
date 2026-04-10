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
    errors=$(echo "${CF_API_BODY}" | grep -o '"message" *: *"[^"]*"' | head -3 || true)
    warn "Cloudflare API error (HTTP ${http_code}): ${errors:-${CF_API_BODY}}"
    return 1
  fi
  return 0
}

cf_create_tunnel() {
  info "Creating Cloudflare tunnel..."

  local tunnel_name="${REPO_NAME}-tunnel"

  # Check if tunnel already exists
  if cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${tunnel_name}&is_deleted=false"; then
    local existing_id
    existing_id=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)

    if [[ -n "${existing_id}" ]]; then
      warn "Tunnel '${tunnel_name}' already exists (${existing_id}), deleting old tunnel..."
      cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${existing_id}" || true
      success "Old tunnel deleted"
    fi
  fi

  # Generate a random 32-byte secret
  TUNNEL_SECRET=$(openssl rand -base64 32)

  if ! cf_api POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
    "{\"name\":\"${tunnel_name}\",\"tunnel_secret\":\"${TUNNEL_SECRET}\",\"config_src\":\"local\"}"; then
    error "Failed to create tunnel: ${CF_API_BODY}"
  fi

  TUNNEL_ID=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if [[ -z "${TUNNEL_ID}" ]]; then
    error "Failed to extract tunnel ID from response: ${CF_API_BODY}"
  fi

  success "Tunnel created: ${tunnel_name} (${TUNNEL_ID})"
}

cf_create_dns_route() {
  local subdomain="${CF_SUBDOMAIN:-${REPO_NAME}}"
  info "Creating DNS record: ${subdomain}.${CF_DOMAIN} -> tunnel..."

  # Check if record already exists
  if cf_api GET "/zones/${CF_ZONE_ID}/dns_records?name=${subdomain}.${CF_DOMAIN}&type=CNAME"; then
    local count
    count=$(echo "${CF_API_BODY}" | grep -o '"count" *: *[0-9]*' | head -1 | sed 's/.*: *//' || true)

    if [[ "${count:-0}" -gt 0 ]]; then
      warn "DNS record for ${subdomain}.${CF_DOMAIN} already exists, updating..."
      local record_id
      record_id=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
        "{\"type\":\"CNAME\",\"name\":\"${subdomain}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" || true
    else
      cf_api POST "/zones/${CF_ZONE_ID}/dns_records" \
        "{\"type\":\"CNAME\",\"name\":\"${subdomain}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" || true
    fi
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

cf_create_web_access_app() {
  # Protect the web app behind Cloudflare Access (self_hosted) with an email-OTP allow-list.
  # Opt-in via CF_ACCESS_ALLOWED_EMAILS (comma-separated). Unset = no protection, deploy proceeds.
  # Non-fatal: on any CF API failure this warns and returns 0 so deploys never break.
  # NOTE: this is NOT the same as the removed cf_create_access_app (type:ssh) which protected
  # cloudflared SSH deploys — that role is now Tailscale's. This creates a type:self_hosted
  # app in front of the browser-facing URL.
  if [[ -z "${CF_ACCESS_ALLOWED_EMAILS:-}" ]]; then
    return 0
  fi

  info "Setting up Cloudflare Access (email-OTP) for web app..."

  # ── Normalize the allow-list ──
  local -a emails=()
  local -a _raw_entries=()
  local _raw_entry
  local _old_ifs="${IFS}"
  IFS=','
  # shellcheck disable=SC2162
  read -ra _raw_entries <<< "${CF_ACCESS_ALLOWED_EMAILS}"
  IFS="${_old_ifs}"
  for _raw_entry in "${_raw_entries[@]}"; do
    # Trim whitespace
    _raw_entry="${_raw_entry#"${_raw_entry%%[![:space:]]*}"}"
    _raw_entry="${_raw_entry%"${_raw_entry##*[![:space:]]}"}"
    [[ -z "${_raw_entry}" ]] && continue
    # Sanity-check: only safe chars for JSON injection
    if [[ ! "${_raw_entry}" =~ ^[a-zA-Z0-9._+@-]+$ ]]; then
      warn "Skipping unsafe email entry: '${_raw_entry}'"
      continue
    fi
    emails+=("${_raw_entry}")
  done

  if [[ ${#emails[@]} -eq 0 ]]; then
    warn "CF_ACCESS_ALLOWED_EMAILS is empty after parsing; skipping Access setup"
    return 0
  fi

  # ── Build policy include JSON ──
  local include_json="["
  local _first=1
  local _email
  for _email in "${emails[@]}"; do
    if [[ ${_first} -eq 1 ]]; then
      _first=0
    else
      include_json+=","
    fi
    include_json+="{\"email\":{\"email\":\"${_email}\"}}"
  done
  include_json+="]"

  local subdomain="${CF_SUBDOMAIN:-${REPO_NAME}}"
  local fqdn="${subdomain}.${CF_DOMAIN}"

  # ── Look up existing Access app by domain (TODO: paginate if >200 apps ever) ──
  local app_id=""
  if cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps?per_page=200"; then
    app_id=$(echo "${CF_API_BODY}" \
      | grep -o "{[^{}]*\"domain\" *: *\"${fqdn}\"[^{}]*}" \
      | grep -o '"id" *: *"[^"]*"' \
      | head -1 | cut -d'"' -f4 || true)
  fi

  # ── Delete-then-recreate for clean policy state ──
  if [[ -n "${app_id}" ]]; then
    warn "Access app for ${fqdn} exists (${app_id}), deleting and recreating"
    cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}" || true
    app_id=""
  fi

  local app_payload
  app_payload="{\"name\":\"${REPO_NAME}\",\"domain\":\"${fqdn}\",\"type\":\"self_hosted\",\"session_duration\":\"24h\",\"auto_redirect_to_identity\":false,\"app_launcher_visible\":false,\"allowed_idps\":[]}"

  if ! cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps" "${app_payload}"; then
    warn "Could not create Cloudflare Access app for ${fqdn}."
    warn "If you saw HTTP 403, add 'Account > Access: Apps and Policies > Edit' to CF_API_TOKEN."
    return 0
  fi

  app_id=$(echo "${CF_API_BODY}" | grep -o '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if [[ -z "${app_id}" ]]; then
    warn "Created Access app but could not extract id from response"
    return 0
  fi
  success "Access app created: ${fqdn}"

  # ── Attach allow policy ──
  local policy_payload
  policy_payload="{\"name\":\"Allow listed emails\",\"decision\":\"allow\",\"precedence\":1,\"include\":${include_json}}"

  if ! cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies" "${policy_payload}"; then
    warn "Access app ${fqdn} exists WITHOUT a policy — it is currently blocking everyone."
    warn "Re-run the deploy, delete the app in the CF dashboard, or add a policy manually."
    return 0
  fi

  success "Access policy attached (${#emails[@]} allowed email(s))"
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
  cf_create_web_access_app

  success "Cloudflare tunnel active: https://${CF_SUBDOMAIN}.${CF_DOMAIN}"
}
