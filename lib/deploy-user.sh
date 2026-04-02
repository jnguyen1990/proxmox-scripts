#!/usr/bin/env bash
# Deploy user creation, SSH keypair, sudoers

create_deploy_user() {
  header "Creating Deploy User"

  pct exec "${CTID}" -- bash -c "set -e
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

    # Copy GitHub SSH key + known_hosts to deploy user so it can git pull
    if [[ -f /root/.ssh/id_ed25519 ]]; then
      cp /root/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519_github
      cp /root/.ssh/id_ed25519.pub /home/deploy/.ssh/id_ed25519_github.pub
      chmod 600 /home/deploy/.ssh/id_ed25519_github
      chown deploy:deploy /home/deploy/.ssh/id_ed25519_github*
      # Configure SSH to use this key for GitHub
      cat > /home/deploy/.ssh/config << 'SSHCFG'
Host github.com
  IdentityFile ~/.ssh/id_ed25519_github
  StrictHostKeyChecking accept-new
SSHCFG
      chown deploy:deploy /home/deploy/.ssh/config
      chmod 600 /home/deploy/.ssh/config
    elif [[ -f /root/.ssh/id_rsa ]]; then
      cp /root/.ssh/id_rsa /home/deploy/.ssh/id_rsa_github
      chmod 600 /home/deploy/.ssh/id_rsa_github
      chown deploy:deploy /home/deploy/.ssh/id_rsa_github
      cat > /home/deploy/.ssh/config << 'SSHCFG'
Host github.com
  IdentityFile ~/.ssh/id_rsa_github
  StrictHostKeyChecking accept-new
SSHCFG
      chown deploy:deploy /home/deploy/.ssh/config
      chmod 600 /home/deploy/.ssh/config
    fi
    cp /root/.ssh/known_hosts /home/deploy/.ssh/known_hosts 2>/dev/null || true
    chown deploy:deploy /home/deploy/.ssh/known_hosts 2>/dev/null || true

    # Ensure SSH server is running
    systemctl enable ssh
    systemctl start ssh
  "
  success "Deploy user created"
}

get_deploy_private_key() {
  pct exec "${CTID}" -- cat /home/deploy/.ssh/id_ed25519
}
