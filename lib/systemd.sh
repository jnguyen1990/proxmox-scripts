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
}
