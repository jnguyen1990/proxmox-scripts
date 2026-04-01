# Proxmox Rails App Deployer

One-command LXC container creation and Rails app deployment for Proxmox VE.

## Quick Start

SSH into your Proxmox host and run:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/rails-app.sh)"
```

The script will prompt you for:

| Prompt | Default | Description |
|--------|---------|-------------|
| Repo name | *(required)* | GitHub repo name (e.g. `hub`, `budgeter`) |
| Port | `3000` | Internal app port (nginx proxies 80 to this) |
| RAM | `1024` MB | Container memory |
| Disk | `4` GB | Container disk size |
| CPU cores | `1` | Container CPU cores |
| Storage pool | `local-lvm` | Proxmox storage pool |

## What It Does

1. Creates a Debian 12 LXC container on your Proxmox host
2. Installs Ruby 3.3.11, nginx, and system dependencies
3. Clones your repo from `github.com/jnguyen1990/{repo}`
4. Runs `bundle install`, `db:migrate`, and `assets:precompile`
5. Creates a systemd service for Puma
6. Configures nginx as a reverse proxy (port 80 → app)
7. Creates a `deploy` user with an SSH key for GitHub Actions
8. Prints everything you need to set up auto-deploy

## Prerequisites

- Proxmox VE host with `pct` available
- SSH key on the Proxmox host that has access to your GitHub repos (`/root/.ssh/id_ed25519` or `/root/.ssh/id_rsa`)

## After Deployment

The script prints a summary like this:

```
App:         budgeter
Container:   101
IP:          192.168.1.50
URL:         http://192.168.1.50
SSH:         ssh deploy@192.168.1.50
Redeploy:    ssh deploy@192.168.1.50 '/opt/budgeter/bin/deploy'
```

It also prints a **deploy private key**. Save this for GitHub Actions.

## Setting Up Auto-Deploy

1. Go to your GitHub repo → Settings → Secrets and variables → Actions
2. Add these repository secrets:

| Secret | Value |
|--------|-------|
| `DEPLOY_HOST` | Container IP address |
| `DEPLOY_USER` | `deploy` |
| `DEPLOY_SSH_KEY` | The private key printed by the script |

3. Add this workflow to your repo at `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: ${{ secrets.DEPLOY_USER }}
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: /opt/<your-app-name>/bin/deploy
```

Now every push to `main` automatically deploys.

## Manual Redeploy

```bash
ssh deploy@<container-ip> '/opt/<app-name>/bin/deploy'
```

## Managing the Container

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

Run the script once per app. Each gets its own LXC container:

```bash
# First run - deploy hub
bash rails-app.sh
# Enter: hub

# Second run - deploy budgeter
bash rails-app.sh
# Enter: budgeter
```

## Loading Existing Data

For the budgeter app, if you have an existing `budgeter.db` from the Flask version:

```bash
scp budgeter.db deploy@<container-ip>:/tmp/
ssh deploy@<container-ip>
cd /opt/budgeter
LEGACY_DB=/tmp/budgeter.db RAILS_ENV=production bundle exec rails db:import_legacy
```
