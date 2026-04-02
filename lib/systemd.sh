#!/usr/bin/env bash
# Systemd service creation from template

setup_systemd() {
  header "Creating Systemd Service"

  local service_content
  service_content=$(render_template "${SCRIPT_DIR}/templates/systemd.service.tmpl")

  pct exec "${CTID}" -- bash -c "cat > /etc/systemd/system/${REPO_NAME}.service << 'SERVICE_EOF'
${service_content}
SERVICE_EOF

systemctl daemon-reload
systemctl enable ${REPO_NAME}
systemctl start ${REPO_NAME}"
  success "Service ${REPO_NAME} created and started"
}
