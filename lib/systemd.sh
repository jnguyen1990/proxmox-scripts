#!/usr/bin/env bash
# Systemd service creation from template
#
# Layout (since 2026-07-06):
#   /etc/systemd/system/{app}.service            — secret-free unit (also managed
#                                                  in each app repo at deploy/{app}.service;
#                                                  bin/deploy re-installs it on every deploy)
#   /etc/systemd/system/{app}.service.d/secrets.conf — RAILS_MASTER_KEY + INTER_APP_SECRET
#                                                  (never in the repo; written once here)

setup_systemd() {
  header "Creating Systemd Service"

  local service_content secrets_content
  service_content=$(render_template "${SCRIPT_DIR}/templates/systemd.service.tmpl")
  secrets_content=$(render_template "${SCRIPT_DIR}/templates/systemd.secrets.tmpl")

  pct exec "${CTID}" -- bash -c "mkdir -p /etc/systemd/system/${REPO_NAME}.service.d
cat > /etc/systemd/system/${REPO_NAME}.service.d/secrets.conf << 'SECRETS_EOF'
${secrets_content}
SECRETS_EOF
chmod 600 /etc/systemd/system/${REPO_NAME}.service.d/secrets.conf

cat > /etc/systemd/system/${REPO_NAME}.service << 'SERVICE_EOF'
${service_content}
SERVICE_EOF

systemctl daemon-reload
systemctl enable ${REPO_NAME}
systemctl start ${REPO_NAME}"
  success "Service ${REPO_NAME} created and started (secrets in service.d/secrets.conf)"

  write_oauth_dropin && pct exec "${CTID}" -- bash -c "systemctl daemon-reload && systemctl restart ${REPO_NAME}"
}

# /etc/systemd/system/{app}.service.d/oauth.conf — MCP OAuth resource-server
# env (personal_app_client OauthResourceServer). Historically written once by
# a manual migration script during the 2026-06 OAuth rollout; upkeep's fresh
# container missed it and its claude.ai connector failed with an opaque
# authorization error (2026-08-28). All four values are mechanical, so
# provisioning writes them now. Skipped when Cloudflare isn't configured
# (no public hostname → no OAuth resource id).
write_oauth_dropin() {
  if [[ -z "${CF_DOMAIN:-}" ]]; then
    info "No CF_DOMAIN — skipping oauth.conf (MCP OAuth needs the public hostname)"
    return 1
  fi
  local mcp_host="${CF_SUBDOMAIN:-${REPO_NAME}}.${CF_DOMAIN}"
  pct exec "${CTID}" -- bash -c "mkdir -p /etc/systemd/system/${REPO_NAME}.service.d
cat > /etc/systemd/system/${REPO_NAME}.service.d/oauth.conf << 'OAUTH_EOF'
[Service]
Environment=MCP_OAUTH_ISSUER=https://base.${CF_DOMAIN}
Environment=MCP_OAUTH_JWKS_URL=https://base.${CF_DOMAIN}/oauth/discovery/keys
Environment=MCP_RESOURCE_URL=https://${mcp_host}/api/mcp
Environment=MCP_PR_METADATA_URL=https://${mcp_host}/.well-known/oauth-protected-resource
OAUTH_EOF
chmod 600 /etc/systemd/system/${REPO_NAME}.service.d/oauth.conf"
  success "oauth.conf written (MCP OAuth resource-server env for ${mcp_host})"
}
