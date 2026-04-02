#!/usr/bin/env bash
# LXC container creation and lifecycle

lxc_next_id() {
  CTID=$(pvesh get /cluster/nextid)
  info "Using CTID: ${CTID}"
}

lxc_ensure_template() {
  local template_storage="local"
  TEMPLATE=$(pveam available --section system | grep "${DEBIAN_TEMPLATE}" | sort -t '-' -k 4 -V | tail -n1 | awk '{print $2}')

  if [[ -z "${TEMPLATE}" ]]; then
    error "Could not find Debian 12 template. Run: pveam update"
  fi

  if ! pveam list "${template_storage}" | grep -q "${TEMPLATE}"; then
    info "Downloading template: ${TEMPLATE}"
    pveam download "${template_storage}" "${TEMPLATE}"
  fi
  success "Template ready: ${TEMPLATE}"
}

lxc_create() {
  info "Creating container ${CTID}..."
  pct create "${CTID}" "local:vztmpl/${TEMPLATE}" \
    --hostname "${REPO_NAME}" \
    --memory "${LXC_RAM}" \
    --cores "${LXC_CORES}" \
    --rootfs "${STORAGE}:${LXC_DISK}" \
    --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
    --unprivileged 1 \
    --features "nesting=1" \
    --onboot 1 \
    --start 0

  success "Container ${CTID} created"
}

lxc_start() {
  info "Starting container..."
  pct start "${CTID}"
  sleep 5

  info "Waiting for network..."
  for i in {1..30}; do
    if pct exec "${CTID}" -- ping -c1 -W1 8.8.8.8 &>/dev/null; then
      break
    fi
    sleep 2
  done
  success "Network ready"

  LXC_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')
  info "Container IP: ${LXC_IP}"
}

lxc_push_ssh_keys() {
  header "Setting Up SSH Access"

  info "Copying host SSH keys into container for GitHub access..."
  pct exec "${CTID}" -- mkdir -p /root/.ssh
  pct exec "${CTID}" -- chmod 700 /root/.ssh

  if [[ -f /root/.ssh/id_ed25519 ]]; then
    pct push "${CTID}" /root/.ssh/id_ed25519 /root/.ssh/id_ed25519
    pct push "${CTID}" /root/.ssh/id_ed25519.pub /root/.ssh/id_ed25519.pub
    pct exec "${CTID}" -- chmod 600 /root/.ssh/id_ed25519
  elif [[ -f /root/.ssh/id_rsa ]]; then
    pct push "${CTID}" /root/.ssh/id_rsa /root/.ssh/id_rsa
    pct push "${CTID}" /root/.ssh/id_rsa.pub /root/.ssh/id_rsa.pub
    pct exec "${CTID}" -- chmod 600 /root/.ssh/id_rsa
  else
    warn "No SSH key found on host. You'll need to set up GitHub access manually."
  fi

  pct exec "${CTID}" -- bash -c 'ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null'
  success "SSH configured"
}
