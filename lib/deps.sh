#!/usr/bin/env bash
# System dependency installation inside LXC container

install_system_deps() {
  header "Installing System Dependencies"

  info "Updating package lists..."
  pct exec "${CTID}" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq' >/dev/null 2>&1

  run_with_status "Installing build tools & libraries" \
    pct exec "${CTID}" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq build-essential libsqlite3-dev libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev ca-certificates >/dev/null 2>&1'

  run_with_status "Installing git, curl, wget" \
    pct exec "${CTID}" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq git curl wget >/dev/null 2>&1'

  run_with_status "Installing nginx, SSH, sudo" \
    pct exec "${CTID}" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq nginx sudo openssh-server >/dev/null 2>&1'
}
