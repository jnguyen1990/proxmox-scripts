#!/usr/bin/env bash
# Tailscale installation and setup in LXC container

ts_setup() {
  if [[ -z "${TS_AUTHKEY:-}" ]]; then
    return 0
  fi

  header "Setting Up Tailscale"

  run_with_status "Installing Tailscale" \
    pct exec "${CTID}" -- bash -c 'set -e; curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1'

  info "Joining tailnet as '${REPO_NAME}'..."
  pct exec "${CTID}" -- tailscale up --authkey="${TS_AUTHKEY}" --hostname="${REPO_NAME}" --accept-dns=false

  TS_IP=$(pct exec "${CTID}" -- tailscale ip -4)

  if [[ -z "${TS_IP}" ]]; then
    warn "Could not get Tailscale IP. Check tailscale status."
    return 0
  fi

  success "Tailscale connected: ${TS_IP} (${REPO_NAME})"
}
