#!/usr/bin/env bash

# ============================================================================
# Proxmox LXC Rails App Deployer
# Creates a Debian 12 LXC container and deploys a Rails app from GitHub
#
# Usage (from Proxmox VE shell):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/rails-app.sh)"
#
# Or locally:
#   bash rails-app.sh
# ============================================================================

set -euo pipefail

# ── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"; echo -e "${BLUE}${BOLD}  $1${NC}"; echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}\n"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Verify we're on a Proxmox host ──────────────────────────────────────────
if ! command -v pct &>/dev/null; then
  error "This script must be run on a Proxmox VE host (pct not found)"
fi

# ── Configuration ────────────────────────────────────────────────────────────
GITHUB_USER="jnguyen1990"
RUBY_VERSION="3.3.11"
DEBIAN_TEMPLATE="debian-12-standard"

header "Proxmox LXC Rails App Deployer"

# Repo name (required)
read -rp "$(echo -e "${BOLD}GitHub repo name${NC} (e.g. hub, budgeter): ")" REPO_NAME
[[ -z "$REPO_NAME" ]] && error "Repo name is required"

# Port (optional, default 3000)
read -rp "$(echo -e "${BOLD}App port${NC} [3000]: ")" APP_PORT
APP_PORT="${APP_PORT:-3000}"

# LXC specs
read -rp "$(echo -e "${BOLD}RAM (MB)${NC} [1024]: ")" LXC_RAM
LXC_RAM="${LXC_RAM:-1024}"

read -rp "$(echo -e "${BOLD}Disk (GB)${NC} [4]: ")" LXC_DISK
LXC_DISK="${LXC_DISK:-4}"

read -rp "$(echo -e "${BOLD}CPU cores${NC} [1]: ")" LXC_CORES
LXC_CORES="${LXC_CORES:-1}"

# Storage
read -rp "$(echo -e "${BOLD}Storage pool${NC} [local-lvm]: ")" STORAGE
STORAGE="${STORAGE:-local-lvm}"

APP_DIR="/opt/${REPO_NAME}"
REPO_URL="git@github.com:${GITHUB_USER}/${REPO_NAME}.git"

echo ""
info "App: ${REPO_NAME}"
info "Repo: ${REPO_URL}"
info "Port: ${APP_PORT}"
info "Specs: ${LXC_CORES} core(s), ${LXC_RAM}MB RAM, ${LXC_DISK}GB disk"
echo ""
read -rp "$(echo -e "${BOLD}Proceed? [Y/n]${NC} ")" CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && exit 0

# ── Find next available CTID ────────────────────────────────────────────────
header "Creating LXC Container"

CTID=$(pvesh get /cluster/nextid)
info "Using CTID: ${CTID}"

# ── Download template if needed ─────────────────────────────────────────────
TEMPLATE_STORAGE="local"
TEMPLATE=$(pveam available --section system | grep "${DEBIAN_TEMPLATE}" | sort -t '-' -k 4 -V | tail -n1 | awk '{print $2}')

if [[ -z "$TEMPLATE" ]]; then
  error "Could not find Debian 12 template. Run: pveam update"
fi

if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}"; then
  info "Downloading template: ${TEMPLATE}"
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
fi
success "Template ready: ${TEMPLATE}"

# ── Create container ────────────────────────────────────────────────────────
info "Creating container ${CTID}..."
pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
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

# ── Start container ─────────────────────────────────────────────────────────
info "Starting container..."
pct start "${CTID}"
sleep 5

# Wait for network
info "Waiting for network..."
for i in {1..30}; do
  if pct exec "${CTID}" -- ping -c1 -W1 8.8.8.8 &>/dev/null; then
    break
  fi
  sleep 2
done
success "Network ready"

# Get container IP
LXC_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')
info "Container IP: ${LXC_IP}"

# ── Copy SSH keys from host into container ──────────────────────────────────
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

# Add GitHub to known hosts
pct exec "${CTID}" -- bash -c 'ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null'
success "SSH configured"

# ── Install system dependencies ─────────────────────────────────────────────
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

# ── Install Ruby ────────────────────────────────────────────────────────────
header "Installing Ruby ${RUBY_VERSION}"

pct exec "${CTID}" -- bash -c "
  # Install ruby-install
  if ! command -v ruby-install &>/dev/null; then
    cd /tmp
    wget -q https://github.com/postmodern/ruby-install/releases/download/v0.9.4/ruby-install-0.9.4.tar.gz
    tar -xzf ruby-install-0.9.4.tar.gz
    cd ruby-install-0.9.4
    make install >/dev/null 2>&1
  fi

  # Install chruby
  if [[ ! -f /usr/local/share/chruby/chruby.sh ]]; then
    cd /tmp
    wget -q https://github.com/postmodern/chruby/releases/download/v0.3.9/chruby-0.3.9.tar.gz
    tar -xzf chruby-0.3.9.tar.gz
    cd chruby-0.3.9
    make install >/dev/null 2>&1
  fi

  # Install Ruby
  if [[ ! -d /opt/rubies/ruby-${RUBY_VERSION} ]]; then
    ruby-install --no-reinstall ruby ${RUBY_VERSION} -- --disable-install-doc 2>&1 | tail -5
  fi

  # Configure chruby for all users
  cat > /etc/profile.d/chruby.sh << 'CHRUBY_EOF'
source /usr/local/share/chruby/chruby.sh
source /usr/local/share/chruby/auto.sh
chruby ruby-${RUBY_VERSION}
CHRUBY_EOF

  # Also set for non-login shells (systemd, scripts)
  echo 'export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH' > /etc/profile.d/ruby-path.sh
  echo 'export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0' >> /etc/profile.d/ruby-path.sh
"
success "Ruby ${RUBY_VERSION} installed"

# ── Clone and deploy app ────────────────────────────────────────────────────
header "Deploying ${REPO_NAME}"

pct exec "${CTID}" -- bash -c "
  export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH
  export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0

  # Clone repo
  if [[ ! -d ${APP_DIR} ]]; then
    git clone ${REPO_URL} ${APP_DIR}
  fi
  cd ${APP_DIR}

  # Install bundler and gems
  gem install bundler --no-document -q
  bundle config set --local deployment true
  bundle config set --local without 'development test'
  bundle install --quiet

  # Generate master key if missing
  if [[ ! -f config/master.key ]]; then
    EDITOR='echo' rails credentials:edit 2>/dev/null || true
  fi

  # Database setup
  RAILS_ENV=production bundle exec rails db:prepare 2>&1 | tail -3

  # Asset precompilation
  RAILS_ENV=production bundle exec rails assets:precompile 2>&1 | tail -3

  # Create storage directory
  mkdir -p storage tmp/pids tmp/sockets log

  echo 'App deployed successfully'
"
success "App deployed to ${APP_DIR}"

# ── Create deploy user for GitHub Actions ───────────────────────────────────
header "Creating Deploy User"

pct exec "${CTID}" -- bash -c "
  # Create deploy user if it doesn't exist
  if ! id deploy &>/dev/null; then
    useradd -m -s /bin/bash deploy
  fi

  # Give deploy user access to the app directory
  chown -R deploy:deploy ${APP_DIR}

  # Allow deploy user to restart the app service without password
  echo 'deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ${REPO_NAME}, /usr/bin/systemctl reload ${REPO_NAME}, /usr/bin/systemctl status ${REPO_NAME}' > /etc/sudoers.d/${REPO_NAME}-deploy
  chmod 440 /etc/sudoers.d/${REPO_NAME}-deploy

  # Generate SSH key for deploy user (for GitHub Actions)
  if [[ ! -f /home/deploy/.ssh/id_ed25519 ]]; then
    mkdir -p /home/deploy/.ssh
    ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N '' -C 'deploy@${REPO_NAME}' -q
    cat /home/deploy/.ssh/id_ed25519.pub >> /home/deploy/.ssh/authorized_keys
    chmod 700 /home/deploy/.ssh
    chmod 600 /home/deploy/.ssh/authorized_keys /home/deploy/.ssh/id_ed25519
    chown -R deploy:deploy /home/deploy/.ssh
  fi

  # Copy GitHub SSH access to deploy user
  cp /root/.ssh/known_hosts /home/deploy/.ssh/known_hosts 2>/dev/null || true
  chown deploy:deploy /home/deploy/.ssh/known_hosts 2>/dev/null || true

  # Ensure SSH server is running
  systemctl enable ssh
  systemctl start ssh
"
success "Deploy user created"

# ── Create deploy script inside the app ─────────────────────────────────────
header "Creating Deploy Script"

pct exec "${CTID}" -- bash -c "cat > ${APP_DIR}/bin/deploy << 'DEPLOY_EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR=\"${APP_DIR}\"
APP_NAME=\"${REPO_NAME}\"

export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH
export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0
export RAILS_ENV=production

cd \"\${APP_DIR}\"

echo \"Pulling latest code...\"
git pull origin main

echo \"Installing dependencies...\"
bundle config set --local deployment true
bundle config set --local without 'development test'
bundle install --quiet

echo \"Running migrations...\"
bundle exec rails db:migrate

echo \"Precompiling assets...\"
bundle exec rails assets:precompile

echo \"Restarting app...\"
sudo systemctl restart \"\${APP_NAME}\"

echo \"Deploy complete!\"
systemctl status \"\${APP_NAME}\" --no-pager | head -5
DEPLOY_EOF
chmod +x ${APP_DIR}/bin/deploy
chown deploy:deploy ${APP_DIR}/bin/deploy"
success "Deploy script created at ${APP_DIR}/bin/deploy"

# ── Create systemd service ──────────────────────────────────────────────────
header "Creating Systemd Service"

pct exec "${CTID}" -- bash -c "cat > /etc/systemd/system/${REPO_NAME}.service << SERVICE_EOF
[Unit]
Description=${REPO_NAME} Rails App
After=network.target

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=${APP_DIR}
Environment=RAILS_ENV=production
Environment=PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:/usr/local/bin:/usr/bin:/bin
Environment=GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0
Environment=PORT=${APP_PORT}
Environment=RAILS_LOG_TO_STDOUT=1
Environment=SOLID_QUEUE_IN_PUMA=true
ExecStart=/opt/rubies/ruby-${RUBY_VERSION}/bin/bundle exec puma -C config/puma.rb
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable ${REPO_NAME}
systemctl start ${REPO_NAME}"
success "Service ${REPO_NAME} created and started"

# ── Configure Nginx reverse proxy ───────────────────────────────────────────
header "Configuring Nginx"

pct exec "${CTID}" -- bash -c "cat > /etc/nginx/sites-available/${REPO_NAME} << NGINX_EOF
upstream ${REPO_NAME}_app {
    server 127.0.0.1:${APP_PORT};
}

server {
    listen 80;
    server_name _;

    client_max_body_size 10M;

    location / {
        proxy_pass http://${REPO_NAME}_app;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_redirect off;
    }

    location /assets/ {
        root ${APP_DIR}/public;
        expires 1y;
        add_header Cache-Control public;
        gzip_static on;
    }
}
NGINX_EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/${REPO_NAME} /etc/nginx/sites-enabled/${REPO_NAME}
nginx -t 2>&1 && systemctl reload nginx"
success "Nginx configured"

# ── Print summary ───────────────────────────────────────────────────────────
DEPLOY_KEY=$(pct exec "${CTID}" -- cat /home/deploy/.ssh/id_ed25519)

header "Deployment Complete!"
echo -e "${GREEN}${BOLD}App:${NC}         ${REPO_NAME}"
echo -e "${GREEN}${BOLD}Container:${NC}   ${CTID}"
echo -e "${GREEN}${BOLD}IP:${NC}          ${LXC_IP}"
echo -e "${GREEN}${BOLD}URL:${NC}         http://${LXC_IP}"
echo -e "${GREEN}${BOLD}App Dir:${NC}     ${APP_DIR}"
echo -e "${GREEN}${BOLD}SSH:${NC}         ssh deploy@${LXC_IP}"
echo -e "${GREEN}${BOLD}Logs:${NC}        pct exec ${CTID} -- journalctl -u ${REPO_NAME} -f"
echo -e "${GREEN}${BOLD}Redeploy:${NC}    ssh deploy@${LXC_IP} '${APP_DIR}/bin/deploy'"

echo ""
echo -e "${YELLOW}${BOLD}── GitHub Actions Setup ──${NC}"
echo -e "Add these secrets to your GitHub repo (${GITHUB_USER}/${REPO_NAME}):"
echo -e "  ${BOLD}DEPLOY_HOST${NC}     = ${LXC_IP}"
echo -e "  ${BOLD}DEPLOY_USER${NC}     = deploy"
echo -e "  ${BOLD}DEPLOY_SSH_KEY${NC}  = (the private key below)"
echo ""
echo -e "${YELLOW}${BOLD}── Deploy Private Key (copy this to GitHub Secrets) ──${NC}"
echo -e "${RED}Save this now - it won't be shown again!${NC}"
echo ""
echo "${DEPLOY_KEY}"
echo ""
echo -e "${GREEN}${BOLD}Done! Your app is live at http://${LXC_IP}${NC}"
