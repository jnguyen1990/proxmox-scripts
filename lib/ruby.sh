#!/usr/bin/env bash
# Ruby installation: ruby-install, chruby, and Ruby version

install_ruby() {
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
}
