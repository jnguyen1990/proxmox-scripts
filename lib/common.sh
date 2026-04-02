#!/usr/bin/env bash
# Common utilities: colors, logging, helpers

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() {
  echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $1${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}\n"
}
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

require_cmd() {
  command -v "$1" &>/dev/null || error "$1 is required but not found. $2"
}

render_template() {
  local template="$1"
  sed \
    -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
    -e "s|{{APP_PORT}}|${APP_PORT}|g" \
    -e "s|{{APP_DIR}}|${APP_DIR}|g" \
    -e "s|{{RUBY_VERSION}}|${RUBY_VERSION}|g" \
    -e "s|{{GITHUB_USER}}|${GITHUB_USER}|g" \
    -e "s|{{TUNNEL_ID}}|${TUNNEL_ID:-}|g" \
    -e "s|{{CF_DOMAIN}}|${CF_DOMAIN:-}|g" \
    -e "s|{{CF_SUBDOMAIN}}|${CF_SUBDOMAIN:-}|g" \
    -e "s|{{NGINX_LISTEN}}|${NGINX_LISTEN:-80}|g" \
    "${template}"
}

render_template_conditional() {
  local template="$1"
  local content
  content=$(render_template "${template}")

  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    # Keep CLOUDFLARE blocks, remove NO_CLOUDFLARE blocks
    content=$(echo "${content}" | sed '/{{#CLOUDFLARE}}/d; /{{\/CLOUDFLARE}}/d')
    content=$(echo "${content}" | sed '/{{#NO_CLOUDFLARE}}/,/{{\/NO_CLOUDFLARE}}/d')
  else
    # Remove CLOUDFLARE blocks, keep NO_CLOUDFLARE blocks
    content=$(echo "${content}" | sed '/{{#CLOUDFLARE}}/,/{{\/CLOUDFLARE}}/d')
    content=$(echo "${content}" | sed '/{{#NO_CLOUDFLARE}}/d; /{{\/NO_CLOUDFLARE}}/d')
  fi

  if [[ -n "${GH_PAT:-}" ]]; then
    content=$(echo "${content}" | sed '/{{#GITHUB_ACTIONS}}/d; /{{\/GITHUB_ACTIONS}}/d')
  else
    content=$(echo "${content}" | sed '/{{#GITHUB_ACTIONS}}/,/{{\/GITHUB_ACTIONS}}/d')
  fi

  echo "${content}"
}
