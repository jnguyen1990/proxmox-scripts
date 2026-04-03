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

    # Tailscale OAuth for GitHub Actions runner to join tailnet
    if [[ -n "${TS_OAUTH_CLIENT_ID:-}" ]]; then
      _gh_set_secret_encrypted "TS_OAUTH_CLIENT_ID" "${TS_OAUTH_CLIENT_ID}" "${repo_pubkey}" "${repo_key_id}"
      _gh_set_secret_encrypted "TS_OAUTH_SECRET" "${TS_OAUTH_SECRET}" "${repo_pubkey}" "${repo_key_id}"
    fi

    success "GitHub Actions secrets set"
  elif command -v gh &>/dev/null; then
    # Fallback: use gh CLI if available
    info "Using gh CLI to set secrets..."
    echo "${deploy_host}" | gh secret set DEPLOY_HOST --repo "${GITHUB_USER}/${REPO_NAME}"
    echo "deploy" | gh secret set DEPLOY_USER --repo "${GITHUB_USER}/${REPO_NAME}"
    echo "${deploy_key}" | gh secret set DEPLOY_SSH_KEY --repo "${GITHUB_USER}/${REPO_NAME}"

    if [[ -n "${TS_OAUTH_CLIENT_ID:-}" ]]; then
      echo "${TS_OAUTH_CLIENT_ID}" | gh secret set TS_OAUTH_CLIENT_ID --repo "${GITHUB_USER}/${REPO_NAME}"
      echo "${TS_OAUTH_SECRET}" | gh secret set TS_OAUTH_SECRET --repo "${GITHUB_USER}/${REPO_NAME}"
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
  echo -e "${YELLOW}${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${YELLOW}${BOLD}  GitHub Actions Manual Setup Required${NC}"
  echo -e "${YELLOW}${BOLD}══════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BOLD}Step 1:${NC} Go to your repo's secrets page:"
  echo -e "  ${CYAN}https://github.com/${GITHUB_USER}/${REPO_NAME}/settings/secrets/actions${NC}"
  echo ""
  echo -e "${BOLD}Step 2:${NC} Click ${BOLD}\"New repository secret\"${NC} and add each of these:"
  echo ""
  echo -e "  Secret name:  ${GREEN}DEPLOY_HOST${NC}"
  echo -e "  Secret value: ${BOLD}${deploy_host}${NC}"
  echo ""
  echo -e "  Secret name:  ${GREEN}DEPLOY_USER${NC}"
  echo -e "  Secret value: ${BOLD}deploy${NC}"
  echo ""
  echo -e "  Secret name:  ${GREEN}DEPLOY_SSH_KEY${NC}"
  echo -e "  Secret value: ${BOLD}(copy the entire private key below, including BEGIN/END lines)${NC}"

  if [[ -n "${TS_OAUTH_CLIENT_ID:-}" ]]; then
    echo ""
    echo -e "  Secret name:  ${GREEN}TS_OAUTH_CLIENT_ID${NC}"
    echo -e "  Secret value: ${BOLD}${TS_OAUTH_CLIENT_ID}${NC}"
    echo ""
    echo -e "  Secret name:  ${GREEN}TS_OAUTH_SECRET${NC}"
    echo -e "  Secret value: ${BOLD}${TS_OAUTH_SECRET}${NC}"
  fi

  echo ""
  echo -e "${YELLOW}${BOLD}── Deploy Private Key (DEPLOY_SSH_KEY value) ──${NC}"
  echo -e "${RED}Copy everything between and including the BEGIN/END lines:${NC}"
  echo ""
  echo "${deploy_key}"
  echo ""
  echo -e "${BOLD}Step 3:${NC} Retrieve this key later if needed:"
  echo -e "  ${CYAN}pct exec ${CTID} -- cat /home/deploy/.ssh/id_ed25519${NC}"
  echo ""
  echo -e "${BOLD}Step 4:${NC} Push a commit to main or re-run the workflow at:"
  echo -e "  ${CYAN}https://github.com/${GITHUB_USER}/${REPO_NAME}/actions${NC}"
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

  # Use Tailscale IP if available, otherwise LXC IP
  local deploy_host="${TS_IP:-${LXC_IP}}"

  gh_set_secrets "${deploy_key}" "${deploy_host}"
  gh_push_workflow

  success "GitHub Actions auto-deploy configured"
}
