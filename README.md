# Proxmox Rails App Deployer

Modular LXC container creation and Rails app deployment for Proxmox VE, with optional Cloudflare tunnel and GitHub Actions auto-deploy.

## Quick Start

### Option 1: One-liner (paste into Proxmox VE shell)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/deploy)"
```

Downloads the repo, prompts for config, and deploys.

### Option 2: Generate a custom script

```bash
git clone git@github.com:jnguyen1990/proxmox-scripts.git
cd proxmox-scripts
cp deploy.conf.example deploy.conf
vim deploy.conf  # fill in your values
./generate       # outputs dist/deploy-{repo-name}.sh
```

Then paste the generated script into Proxmox VE or transfer it.

### Option 3: Run from cloned repo on Proxmox

```bash
git clone git@github.com:jnguyen1990/proxmox-scripts.git /tmp/proxmox-scripts
cd /tmp/proxmox-scripts
cp deploy.conf.example deploy.conf
vim deploy.conf
./deploy
```

## Configuration

Copy `deploy.conf.example` to `deploy.conf`. Required and optional settings:

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

### Cloudflare Tunnel (optional)

Route traffic through Cloudflare's network instead of exposing ports directly.

| Setting | Description |
|---------|-------------|
| `CF_API_TOKEN` | Cloudflare API token (needs Tunnel Edit + DNS Edit) |
| `CF_ACCOUNT_ID` | Cloudflare account ID |
| `CF_ZONE_ID` | Zone ID for your domain |
| `CF_DOMAIN` | Base domain (e.g. `example.com`) |
| `CF_SUBDOMAIN` | Subdomain (defaults to `REPO_NAME`) |

### GitHub Actions Auto-Deploy (optional)

Automatically push a deploy workflow and set secrets on your repo.

| Setting | Description |
|---------|-------------|
| `GH_PAT` | GitHub personal access token with `repo` scope |

## What It Does

1. **Preflight** - Verifies Proxmox host, SSH keys, optional CF/GH tokens
2. **LXC Creation** - Creates a Debian 12 unprivileged container
3. **System Setup** - Installs Ruby, nginx, build tools
4. **App Deployment** - Clones repo, bundles, migrates, precompiles
5. **Deploy User** - Creates `deploy` user with SSH keys and sudoers
6. **Services** - Configures systemd + nginx reverse proxy
7. **Cloudflare** *(if configured)* - Creates tunnel via API, installs cloudflared daemon, sets up DNS
8. **GitHub Actions** *(if configured)* - Pushes workflow file, sets deployment secrets

## Project Structure

```
deploy                 # Main orchestrator
generate               # Builds single-file scripts from modules
deploy.conf.example    # Config template
lib/
  common.sh            # Colors, logging, template rendering
  config.sh            # Config loading + validation
  preflight.sh         # Pre-deployment checks
  lxc.sh               # LXC container lifecycle
  deps.sh              # System dependencies
  ruby.sh              # Ruby/chruby installation
  app.sh               # App cloning + deployment
  deploy-user.sh       # Deploy user setup
  systemd.sh           # Systemd service
  nginx.sh             # Nginx reverse proxy
  cloudflare.sh        # Cloudflare tunnel via API
  github-actions.sh    # GitHub Actions workflow + secrets
templates/
  systemd.service.tmpl # Puma unit file
  nginx.conf.tmpl      # Nginx site config
  cloudflared.yml.tmpl # cloudflared tunnel config
  deploy.yml.tmpl      # GitHub Actions workflow
rails-app.sh           # Legacy monolithic script (reference)
```

## Prerequisites

- Proxmox VE host with `pct` available
- SSH key on the Proxmox host for GitHub access (`/root/.ssh/id_ed25519` or `id_rsa`)
- *(Optional)* Cloudflare account with API token
- *(Optional)* GitHub PAT with `repo` scope

## After Deployment

```
App:         budgeter
Container:   101
IP:          192.168.1.50
URL:         https://budgeter.example.com  (or http://192.168.1.50)
SSH:         ssh deploy@192.168.1.50
Redeploy:    ssh deploy@192.168.1.50 '/opt/budgeter/bin/deploy'
```

## Manual Redeploy

```bash
ssh deploy@<container-ip> '/opt/<app-name>/bin/deploy'
```

## Managing Containers

```bash
# View logs
pct exec <ctid> -- journalctl -u <app-name> -f

# Restart the app
pct exec <ctid> -- systemctl restart <app-name>

# Shell into the container
pct enter <ctid>

# Stop/start container
pct stop <ctid>
pct start <ctid>
```

## Deploying Multiple Apps

Run the deploy once per app. Each gets its own LXC container:

```bash
# With config file - change REPO_NAME and re-run
./deploy

# With one-liner - prompted each time
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/deploy)"
```
