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

  # Write the master key the operator supplied. Required when the repo ships
  # an encrypted config/credentials.yml.enc — without the matching key Rails
  # can't read secret_key_base in production and db:prepare crashes with
  # ActiveSupport::MessageEncryptor::InvalidMessage. Generating a fresh key
  # via `rails credentials:edit` (the old fallback) silently produces a key
  # that DOESN'T match credentials.yml.enc, so the app boots without secrets.
  local has_credentials
  has_credentials=$(pct exec "${CTID}" -- bash -c "[[ -f ${APP_DIR}/config/credentials.yml.enc ]] && echo yes || echo no")

  if [[ -n "${RAILS_MASTER_KEY:-}" ]]; then
    pct exec "${CTID}" -- bash -c "echo '${RAILS_MASTER_KEY}' > ${APP_DIR}/config/master.key && chown deploy:deploy ${APP_DIR}/config/master.key && chmod 600 ${APP_DIR}/config/master.key"
    success "Master key installed"
  elif [[ "${has_credentials}" == "yes" ]]; then
    error "Repo has config/credentials.yml.enc but RAILS_MASTER_KEY is not set in deploy.conf or env. Add it (the value of config/master.key from your local checkout) and re-run."
  else
    info "No credentials.yml.enc in repo — skipping master key setup"
  fi

  # Sanity-check that production database paths are configured. Rails 8
  # scaffolding ships with the production primary/cache/queue paths
  # commented out (originally for Docker volumes), which makes db:prepare
  # and later db:migrate fail with `ArgumentError: No database file
  # specified. Missing argument: database`.
  local prod_db_uncommented
  prod_db_uncommented=$(pct exec "${CTID}" -- bash -c "grep -A 30 '^production:' ${APP_DIR}/config/database.yml | grep -E '^[[:space:]]+database:[[:space:]]+[^#[:space:]]' | head -1 || true")
  if [[ -z "${prod_db_uncommented}" ]]; then
    warn "config/database.yml has no uncommented production database paths."
    warn "Rails 8 ships these commented out by default — db:migrate will fail."
    warn "Fix in your repo by setting (for SQLite):"
    warn "  production:"
    warn "    primary: { <<: *default, database: storage/production.sqlite3 }"
    warn "    cache:   { <<: *default, database: storage/production_cache.sqlite3, migrations_paths: db/cache_migrate }"
    warn "    queue:   { <<: *default, database: storage/production_queue.sqlite3, migrations_paths: db/queue_migrate }"
    error "Fix config/database.yml in the repo, push, then re-run deploy."
  fi

  # Run db:prepare and capture exit code. set -o pipefail so a failure in
  # the rake task isn't masked by the tail filter on its tail output.
  pct exec "${CTID}" -- bash -c "set -eo pipefail
    export PATH=/opt/rubies/ruby-${RUBY_VERSION}/bin:\$PATH
    export GEM_HOME=/opt/rubies/ruby-${RUBY_VERSION}/lib/ruby/gems/3.3.0
    cd ${APP_DIR}
    bundle exec rails solid_queue:install:migrations 2>/dev/null || true
    bundle exec rails solid_cache:install:migrations 2>/dev/null || true
    RAILS_ENV=production bundle exec rails db:prepare
  " || error "db:prepare failed. Common causes: RAILS_MASTER_KEY mismatched with credentials.yml.enc, missing production database paths, or schema errors. Check the trace above."
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
