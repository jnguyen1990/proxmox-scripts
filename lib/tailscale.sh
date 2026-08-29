#!/usr/bin/env bash
# Tailscale installation and setup in LXC container

ts_setup() {
  if [[ -z "${TS_AUTHKEY:-}" && -z "${TS_OAUTH_CLIENT_ID:-}" ]]; then
    return 0
  fi

  header "Setting Up Tailscale"

  # Check if already installed and connected
  TS_IP=$(pct exec "${CTID}" -- tailscale ip -4 2>/dev/null || true)
  if [[ -n "${TS_IP}" ]]; then
    success "Tailscale already connected: ${TS_IP} (${REPO_NAME})"
    return 0
  fi

  # Install tailscale if not present
  if ! pct exec "${CTID}" -- command -v tailscale &>/dev/null; then
    run_with_status "Installing Tailscale" \
      pct exec "${CTID}" -- bash -c 'set -e; curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1'
  fi

  # Join tailnet using authkey. accept-dns=true enables MagicDNS so apps
  # can reach each other via <hostname>.<tailnet>.ts.net (used by the
  # personal_app_client gem for inter-app HTTP).
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    info "Joining tailnet as '${REPO_NAME}'..."
    # Auth keys expire (1-90 days). A dead saved key used to fail the whole
    # phase (bit the upkeep provision 2026-08-28); now we prompt inline for a
    # fresh key and upsert it into the secrets file for the next deploy.
    if ! pct exec "${CTID}" -- tailscale up --authkey="${TS_AUTHKEY}" --hostname="${REPO_NAME}" --accept-dns=true; then
      warn "Saved TS_AUTHKEY was rejected (expired or revoked)."
      info "Create a new reusable key: https://login.tailscale.com/admin/settings/keys"
      read -rp "$(echo -e "${BOLD}New Tailscale auth key${NC} (or Enter to skip): ")" _new_ts_key
      if [[ -n "${_new_ts_key}" ]]; then
        TS_AUTHKEY="${_new_ts_key}"
        persist_secret "TS_AUTHKEY" "${TS_AUTHKEY}" "Tailscale reusable auth key (expires 1-90 days; re-prompted when dead)"
        pct exec "${CTID}" -- tailscale up --authkey="${TS_AUTHKEY}" --hostname="${REPO_NAME}" --accept-dns=true
      fi
    fi
  else
    info "Joining tailnet as '${REPO_NAME}'..."
    warn "No TS_AUTHKEY set. Tailscale installed but you need to join manually:"
    warn "  pct exec ${CTID} -- tailscale up --hostname=${REPO_NAME}"
    return 0
  fi

  TS_IP=$(pct exec "${CTID}" -- tailscale ip -4 2>/dev/null || true)

  if [[ -z "${TS_IP}" ]]; then
    warn "Could not get Tailscale IP. Check tailscale status."
    return 0
  fi

  success "Tailscale connected: ${TS_IP} (${REPO_NAME})"
}
