#!/usr/bin/env bash
# Application deployment: clone, bundle, database, assets, deploy script

deploy_app() {
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
