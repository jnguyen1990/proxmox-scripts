#!/usr/bin/env bash
# System dependency installation inside LXC container

install_system_deps() {
  header "Installing System Dependencies"

  pct exec "${CTID}" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
      build-essential \
      libsqlite3-dev \
      libssl-dev \
      libreadline-dev \
      zlib1g-dev \
      libyaml-dev \
      libffi-dev \
      git \
      curl \
      wget \
      nginx \
      sudo \
      openssh-server \
      ca-certificates \
      >/dev/null 2>&1
  '
  success "System dependencies installed"
}
