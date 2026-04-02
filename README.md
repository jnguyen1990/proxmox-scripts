# Proxmox Rails App Deployer

Modular LXC container creation and Rails app deployment for Proxmox VE, with optional Cloudflare tunnel, Tailscale VPN, and GitHub Actions auto-deploy.

## Quick Start

SSH into your Proxmox host and run:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)"
```

The script prompts for everything. Tokens and keys are saved to `/root/.proxmox-deploy-secrets` so you only enter them once.

## What It Does

1. **Preflight** - Generates/checks SSH key, verifies GitHub access, validates tokens
2. **LXC Creation** - Creates Debian 12 unprivileged container with TUN device (for Tailscale)
3. **System Setup** - Installs Ruby, nginx, build tools (with progress spinners)
4. **App Deployment** - Clones repo, bundles, migrates, precompiles assets
5. **Deploy User** - Creates `deploy` user with SSH keys, sudoers, and GitHub access
6. **Services** - Configures systemd + nginx reverse proxy
7. **Cloudflare Tunnel** *(optional)* - Creates tunnel via API, installs cloudflared, sets up DNS
8. **Tailscale** *(optional)* - Installs Tailscale in container for SSH access from anywhere
9. **GitHub Actions** *(optional)* - Sets deployment secrets, pushes workflow for auto-deploy on push to main

## Configuration

All settings are prompted interactively. For repeated deploys, use `deploy.conf`:

| Setting | Default | Description |
|---------|---------|-------------|
| `REPO_NAME` | *(required)* | GitHub repo name (e.g. `hub`, `budgeter`) |
| `GITHUB_USER` | `jnguyen1990` | GitHub username |
| `APP_PORT` | `3000` | Internal app port |
| `RUBY_VERSION` | `3.3.11` | Ruby version to install |
| `LXC_RAM` | `1024` | Container RAM in MB |
| `LXC_DISK` | `4` | Container disk in GB |
| `LXC_CORES` | `1` | Container CPU cores |
| `STORAGE` | `local-lvm` | Proxmox storage pool |
| `RAILS_MASTER_KEY` | *(prompted)* | From `config/master.key` (saved per-app) |

### Cloudflare Tunnel (optional)

Routes web traffic through Cloudflare's network (e.g. `app.example.com`).

| Setting | Description |
|---------|-------------|
| `CF_API_TOKEN` | Cloudflare API token (needs Tunnel Edit + DNS Edit) |
| `CF_ACCOUNT_ID` | Cloudflare account ID |
| `CF_ZONE_ID` | Zone ID for your domain |
| `CF_DOMAIN` | Base domain (e.g. `example.com`) |
| `CF_SUBDOMAIN` | Subdomain (defaults to `REPO_NAME`) |

### Tailscale (optional)

Mesh VPN for SSH access to containers from anywhere. Used by GitHub Actions for auto-deploy.

| Setting | Description |
|---------|-------------|
| `TS_AUTHKEY` | Reusable auth key from https://login.tailscale.com/admin/settings/keys |

### GitHub Actions Auto-Deploy (optional)

Pushes a workflow and sets secrets on your repo. Requires Tailscale for SSH access.

| Setting | Description |
|---------|-------------|
| `GH_PAT` | GitHub personal access token with `repo` + `workflow` scope |

## Project Structure

```
deploy                 # Main orchestrator
bootstrap.sh           # One-liner bootstrap (clones repo + runs deploy)
generate               # Builds single-file paste-able scripts
deploy.conf.example    # Config template
lib/
  common.sh            # Colors, logging, spinners, template rendering
  config.sh            # Config loading, prompts, secrets management
  preflight.sh         # SSH key generation, GitHub access verification
  lxc.sh               # LXC container lifecycle + TUN device setup
  deps.sh              # System dependencies (with progress)
  ruby.sh              # ruby-install, chruby, Ruby compilation
  app.sh               # App cloning, bundling, database, assets
  deploy-user.sh       # Deploy user + SSH keys + GitHub access
  systemd.sh           # Systemd service from template
  nginx.sh             # Nginx reverse proxy from template
  cloudflare.sh        # Cloudflare tunnel via API
  tailscale.sh         # Tailscale VPN setup in container
  github-actions.sh    # GitHub Actions workflow + secrets
templates/
  systemd.service.tmpl # Puma unit file
  nginx.conf.tmpl      # Nginx site config
  cloudflared.yml.tmpl # cloudflared tunnel config
  deploy.yml.tmpl      # GitHub Actions workflow (Tailscale + SSH)
rails-app.sh           # Legacy monolithic script (reference)
```

## Prerequisites

- Proxmox VE host with `pct` and internet access
- SSH key on the Proxmox host added to GitHub
- *(Optional)* Cloudflare account with API token
- *(Optional)* Tailscale account with reusable auth key
- *(Optional)* GitHub PAT with `repo` + `workflow` scope

## After Deployment

```
App:         budgeter
Container:   107
LXC IP:      192.168.2.74
Tailscale:   100.118.249.29
URL:         https://budgeter.joenguyen.ca
SSH:         ssh deploy@100.118.249.29
Redeploy:    ssh deploy@100.118.249.29 '/opt/budgeter/bin/deploy'
```

## Managing Containers

```bash
pct exec <ctid> -- journalctl -u <app-name> -f    # View logs
pct exec <ctid> -- systemctl restart <app-name>    # Restart app
pct enter <ctid>                                    # Shell into container
pct stop <ctid> && pct destroy <ctid>              # Remove container
```

## Deploying Multiple Apps

Run the one-liner once per app. Tokens are saved and reused automatically:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)"
# Enter: hub (or whatever app)
# Everything else is pre-filled from saved secrets
```
