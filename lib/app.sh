#!/usr/bin/env bash
# Application deployment: clone, bundle, database, assets, deploy script

deploy_app() {
  header "Deploying ${REPO_NAME}"

  info "Cloning repository..."
  pct exec "${CTID}" -- bash -c "set -e
    export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH
    export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0
    if [[ ! -d ${APP_DIR} ]]; then
      git clone ${REPO_URL} ${APP_DIR}
    fi
  "
  success "Repository cloned"

  run_with_status "Installing gems" \
    pct exec "${CTID}" -- bash -c "set -e
      export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH
      export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0
      cd ${APP_DIR}
      gem install bundler --no-document -q
      bundle config set --local deployment true
      bundle config set --local without 'development test'
      bundle install --quiet
    "

  info "Setting up database..."
  pct exec "${CTID}" -- bash -c "set -e
    export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH
    export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0
    cd ${APP_DIR}
    if [[ -n \"${RAILS_MASTER_KEY:-}\" ]]; then
      echo \"${RAILS_MASTER_KEY}\" > config/master.key
      chmod 600 config/master.key
    elif [[ ! -f config/master.key ]]; then
      EDITOR='echo' rails credentials:edit 2>/dev/null || true
    fi
    RAILS_ENV=production bundle exec rails db:prepare 2>&1 | tail -3
  "
  success "Database ready"

  run_with_status "Precompiling assets" \
    pct exec "${CTID}" -- bash -c "set -e
      export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH
      export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0
      cd ${APP_DIR}
      RAILS_ENV=production bundle exec rails assets:precompile >/dev/null 2>&1
    "

  pct exec "${CTID}" -- mkdir -p "${APP_DIR}/storage" "${APP_DIR}/tmp/pids" "${APP_DIR}/tmp/sockets" "${APP_DIR}/log"
  success "App deployed to ${APP_DIR}"
}

create_deploy_script() {
  header "Creating Deploy Script"

  pct exec "${CTID}" -- bash -c "mkdir -p ${APP_DIR}/bin && cat > ${APP_DIR}/bin/deploy << 'DEPLOY_EOF'
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
}
