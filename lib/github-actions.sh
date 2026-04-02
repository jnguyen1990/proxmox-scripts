#!/usr/bin/env bash
# GitHub Actions workflow generation and secrets management

GH_API_BODY=""

gh_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local args=(-s -w "\n%{http_code}" -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json")
  if [[ -n "${data}" ]]; then
    args+=(-X "${method}" -d "${data}")
  else
    args+=(-X "${method}")
  fi

  local response
  response=$(curl "${args[@]}" "https://api.github.com${endpoint}")

  local http_code
  http_code=$(echo "${response}" | tail -1)
  GH_API_BODY=$(echo "${response}" | sed '$d')

  if ! [[ "${http_code}" =~ ^[0-9]+$ ]] || [[ "${http_code}" -lt 200 ]] || [[ "${http_code}" -ge 300 ]]; then
    warn "GitHub API error (HTTP ${http_code}): ${GH_API_BODY}"
    return 1
  fi
  return 0
}

gh_set_secrets() {
  local deploy_key="$1"
  local deploy_host="$2"

  info "Setting GitHub Actions secrets on ${GITHUB_USER}/${REPO_NAME}..."

  # Get the repo's public key for secret encryption
  if ! gh_api GET "/repos/${GITHUB_USER}/${REPO_NAME}/actions/secrets/public-key"; then
    warn "Could not get repo public key. Falling back to printing secrets."
    gh_print_secrets "${deploy_key}" "${deploy_host}"
    return 0
  fi

  local repo_pubkey
  repo_pubkey=$(echo "${GH_API_BODY}" | grep -o '"key" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  local repo_key_id
  repo_key_id=$(echo "${GH_API_BODY}" | grep -o '"key_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  if [[ -z "${repo_pubkey}" || -z "${repo_key_id}" ]]; then
    warn "Could not parse repo public key. Falling back to printing secrets."
    gh_print_secrets "${deploy_key}" "${deploy_host}"
    return 0
  fi

  # Check if Python + PyNaCl is available for encryption
  if python3 -c "from nacl.public import PublicKey, SealedBox" 2>/dev/null; then
    _gh_set_secret_encrypted "DEPLOY_HOST" "${deploy_host}" "${repo_pubkey}" "${repo_key_id}"
    _gh_set_secret_encrypted "DEPLOY_USER" "deploy" "${repo_pubkey}" "${repo_key_id}"
    _gh_set_secret_encrypted "DEPLOY_SSH_KEY" "${deploy_key}" "${repo_pubkey}" "${repo_key_id}"

    # Cloudflare Access secrets if applicable
    if [[ -n "${CF_ACCESS_CLIENT_ID:-}" ]]; then
      _gh_set_secret_encrypted "CF_ACCESS_CLIENT_ID" "${CF_ACCESS_CLIENT_ID}" "${repo_pubkey}" "${repo_key_id}"
      _gh_set_secret_encrypted "CF_ACCESS_CLIENT_SECRET" "${CF_ACCESS_CLIENT_SECRET}" "${repo_pubkey}" "${repo_key_id}"
    fi

    success "GitHub Actions secrets set"
  elif command -v gh &>/dev/null; then
    # Fallback: use gh CLI if available
    info "Using gh CLI to set secrets..."
    echo "${deploy_host}" | gh secret set DEPLOY_HOST --repo "${GITHUB_USER}/${REPO_NAME}"
    echo "deploy" | gh secret set DEPLOY_USER --repo "${GITHUB_USER}/${REPO_NAME}"
    echo "${deploy_key}" | gh secret set DEPLOY_SSH_KEY --repo "${GITHUB_USER}/${REPO_NAME}"

    if [[ -n "${CF_ACCESS_CLIENT_ID:-}" ]]; then
      echo "${CF_ACCESS_CLIENT_ID}" | gh secret set CF_ACCESS_CLIENT_ID --repo "${GITHUB_USER}/${REPO_NAME}"
      echo "${CF_ACCESS_CLIENT_SECRET}" | gh secret set CF_ACCESS_CLIENT_SECRET --repo "${GITHUB_USER}/${REPO_NAME}"
    fi

    success "GitHub Actions secrets set via gh CLI"
  else
    warn "Neither PyNaCl nor gh CLI available for secret encryption."
    gh_print_secrets "${deploy_key}" "${deploy_host}"
  fi
}

_gh_set_secret_encrypted() {
  local name="$1"
  local value="$2"
  local pubkey="$3"
  local key_id="$4"

  local encrypted
  encrypted=$(python3 -c "
import base64
from nacl.public import PublicKey, SealedBox
public_key = PublicKey(base64.b64decode('${pubkey}'))
sealed_box = SealedBox(public_key)
encrypted = sealed_box.encrypt('''${value}'''.encode('utf-8'))
print(base64.b64encode(encrypted).decode('utf-8'))
")

  if gh_api PUT "/repos/${GITHUB_USER}/${REPO_NAME}/actions/secrets/${name}" \
    "{\"encrypted_value\":\"${encrypted}\",\"key_id\":\"${key_id}\"}"; then
    info "  Set secret: ${name}"
  else
    warn "  Failed to set secret: ${name}"
  fi
}

gh_print_secrets() {
  local deploy_key="$1"
  local deploy_host="$2"

  echo ""
  echo -e "${YELLOW}${BOLD}── GitHub Actions Setup (Manual) ──${NC}"
  echo -e "Add these secrets to your GitHub repo (${GITHUB_USER}/${REPO_NAME}):"
  echo -e "  ${BOLD}DEPLOY_HOST${NC}     = ${deploy_host}"
  echo -e "  ${BOLD}DEPLOY_USER${NC}     = deploy"
  echo -e "  ${BOLD}DEPLOY_SSH_KEY${NC}  = (the private key below)"

  if [[ -n "${CF_ACCESS_CLIENT_ID:-}" ]]; then
    echo -e "  ${BOLD}CF_ACCESS_CLIENT_ID${NC}     = ${CF_ACCESS_CLIENT_ID}"
    echo -e "  ${BOLD}CF_ACCESS_CLIENT_SECRET${NC} = ${CF_ACCESS_CLIENT_SECRET}"
  fi

  echo ""
  echo -e "${YELLOW}${BOLD}── Deploy Private Key ──${NC}"
  echo -e "${RED}Save this now - it won't be shown again!${NC}"
  echo ""
  echo "${deploy_key}"
  echo ""
}

gh_push_workflow() {
  info "Pushing GitHub Actions workflow to ${GITHUB_USER}/${REPO_NAME}..."

  local workflow_content
  workflow_content=$(render_template_conditional "${SCRIPT_DIR}/templates/deploy.yml.tmpl")

  local encoded
  encoded=$(echo "${workflow_content}" | base64 | tr -d '\n')

  # Check if file already exists
  gh_api GET "/repos/${GITHUB_USER}/${REPO_NAME}/contents/.github/workflows/deploy.yml" || true
  local sha
  sha=$(echo "${GH_API_BODY}" | grep -o '"sha" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  local data
  if [[ -n "${sha}" ]]; then
    data="{\"message\":\"Update auto-deploy workflow\",\"content\":\"${encoded}\",\"sha\":\"${sha}\"}"
  else
    data="{\"message\":\"Add auto-deploy workflow\",\"content\":\"${encoded}\"}"
  fi

  if gh_api PUT "/repos/${GITHUB_USER}/${REPO_NAME}/contents/.github/workflows/deploy.yml" "${data}"; then
    success "GitHub Actions workflow pushed"
  else
    warn "Failed to push workflow. You can add it manually."
    echo ""
    echo "${workflow_content}"
  fi
}

gh_setup() {
  if [[ -z "${GH_PAT:-}" ]]; then
    return 0
  fi

  header "Setting Up GitHub Actions Auto-Deploy"

  local deploy_key
  deploy_key=$(get_deploy_private_key)
  local deploy_host="${LXC_IP}"

  # If Cloudflare is enabled, use the tunnel hostname
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    deploy_host="${CF_SUBDOMAIN:-${REPO_NAME}}.${CF_DOMAIN}"
  fi

  gh_set_secrets "${deploy_key}" "${deploy_host}"
  gh_push_workflow

  success "GitHub Actions auto-deploy configured"
}
