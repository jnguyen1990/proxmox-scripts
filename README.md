# Proxmox Rails App Deployer

Modular LXC container creation and Rails app deployment for Proxmox VE, with optional Cloudflare tunnel, Tailscale VPN, and GitHub Actions auto-deploy.

## Commands

All commands are one-liners pasted into the Proxmox VE shell:

### Deploy a new app

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)"
```

Creates a new LXC container and deploys a Rails app end-to-end. Prompts for everything. Tokens and keys are saved to `/root/.proxmox-deploy-secrets` so you only enter them once.

### Repair a partial deploy

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)" _ repair
```

Checks an existing container for missing components and fixes them. Useful when `deploy` fails partway through. Checks: system deps, Ruby, app clone, gems, master key, database, deploy user, GitHub SSH access, deploy script, systemd service config, nginx, Cloudflare tunnel, Tailscale, and file ownership.

### Tear down containers

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)" _ teardown
```

Interactive removal of LXC containers and all connected services. Lists your containers, prompts for IDs, then deletes the Cloudflare tunnel + DNS records, logs out Tailscale, and destroys the container.

### Get GitHub Actions setup info

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)" _ setup-github
```

Prints the secrets, deploy key, and workflow file needed to set up auto-deploy for any container. Use this when the automated GitHub setup fails or you need to add a workflow manually.

## What Deploy Does

1. **Preflight** - Generates/checks SSH key, verifies GitHub access, validates tokens
2. **LXC Creation** - Creates Debian 12 unprivileged container with TUN device (for Tailscale)
3. **System Setup** - Installs Ruby, nginx, build tools (with progress spinners)
4. **App Deployment** - Clones repo, bundles, migrates, precompiles assets
5. **Deploy User** - Creates `deploy` user with SSH keys, sudoers, and GitHub access
6. **Services** - Configures systemd + nginx reverse proxy
7. **Cloudflare Tunnel** *(optional)* - Creates tunnel via API, installs cloudflared, sets up DNS
8. **Tailscale** *(optional)* - Installs Tailscale in container for SSH access from anywhere
9. **GitHub Actions** *(optional)* - Sets deployment secrets, pushes workflow for auto-deploy on push to main

## Post-Deploy Checklist — Protect the new app with Cloudflare Access

> **Warning:** after `deploy` finishes, the new app is live on `{app}.joenguyen.ca` via its Cloudflare tunnel and **publicly reachable with no authentication**. The tunnel is open by default. You must manually add the new hostname to the Cloudflare Access application before the app is protected. Do this immediately after deploy, before linking or announcing the app anywhere.

Cloudflare Access is **managed in the CF dashboard**, not by this script — one consolidated `self_hosted` Access application covers all personal apps (base, fitness, budgeter, …) using a single email-OTP allow-list policy. Adding a new app = adding one hostname to that existing application.

### Steps

1. Log into [Cloudflare Zero Trust](https://one.dash.cloudflare.com) → your account.
2. **Access → Applications** → open the consolidated personal-apps application (the one that already protects base/fitness/budgeter).
3. Click **Edit**.
4. Scroll to the **Public hostname** section → click **+ Add public hostname**.
5. Fill in:
   - **Subdomain:** `{new-app}` (e.g. `daily`, `self`)
   - **Domain:** `joenguyen.ca`
   - **Path:** leave blank
6. Click **Save**. The existing email allow-list policy on the application applies automatically to the new hostname.
7. **Verify:** open a fresh private/incognito browser window → `https://{new-app}.joenguyen.ca` → you should hit the Cloudflare Access email-OTP screen. Enter an allowed email, receive the code, confirm you land on the Rails app.

### Why this isn't automated

We intentionally do **not** manage Access via `proxmox-scripts`. An earlier version of `lib/cloudflare.sh` had a `cf_create_web_access_app` function that created Access apps via the CF API, but it used a delete-and-recreate idempotency pattern that would wipe any custom policies added in the dashboard. Since Access lives in the CF dashboard and rarely changes, manual management is the simpler and safer model. See `git log` around 2026-04-10 for the history.

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
deploy                 # Main orchestrator - full deploy from scratch
repair                 # Check & fix partial deploys
teardown               # Interactive container removal (CF + TS + LXC)
setup-github           # Print GitHub Actions setup info for a container
bootstrap.sh           # One-liner bootstrap (clones repo + runs command)
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
- SSH key on the Proxmox host added to GitHub (auto-generated if missing)
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
```

To remove containers cleanly (including Cloudflare tunnels, DNS records, and Tailscale nodes):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)" _ teardown
```

## Deploying Multiple Apps

Run the deploy once per app. Tokens are saved and reused automatically:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)"
# Enter: hub (or whatever app)
# Everything else is pre-filled from saved secrets
```

If a deploy fails partway, run repair instead of starting over:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)" _ repair
```
