#!/usr/bin/env bash
# Nginx reverse proxy configuration from template

setup_nginx() {
  header "Configuring Nginx"

  # When Cloudflare tunnel is active, only listen on localhost
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    NGINX_LISTEN="127.0.0.1:80"
  else
    NGINX_LISTEN="80"
  fi

  local nginx_content
  nginx_content=$(render_template "${SCRIPT_DIR}/templates/nginx.conf.tmpl")

  pct exec "${CTID}" -- bash -c "cat > /etc/nginx/sites-available/${REPO_NAME} << 'NGINX_EOF'
${nginx_content}
NGINX_EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/${REPO_NAME} /etc/nginx/sites-enabled/${REPO_NAME}
nginx -t 2>&1 && systemctl reload nginx"
  success "Nginx configured"
}
