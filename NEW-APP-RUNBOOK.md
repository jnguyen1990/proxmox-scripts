# New App Runbook — repo to nightly-agent, end to end

> **Updated 2026-11-05.** Scaffolding now lives in `~/Repos/rails-app-template` — follow its README (full `rails new` skip-flag set, then `bin/apply`) instead of the Phase A commands below, and use its checklist for the steps outside this repo (base `config/apps.yml` and OAuth audience, the mini's script lists, design-system accent, gem README). The deploy workflow this repo pushes is now the CI-gated one (`workflow_run` on CI + `workflow_dispatch`), so the Phase E note about no manual trigger no longer applies. The `json ~> 2.9` pin did not reproduce on Rails 8.1.4.1.


The canonical step-by-step for standing up a new app in the constellation
(`<app>` = lowercase app name, e.g. `postings`). Distilled from the upkeep
(2026-08-28) and postings (2026-09-09/10) rounds — every ⚠️ below is a thing
that actually bit us. When Joe asks "give me all the steps for the new app",
this file is the answer.

Division of labor: **A–B are agent work** (Claude Code builds and pushes),
**C–G are Joe's** (PVE shell + dashboards + claude.ai), **H is the agent again**.

---

## Phase A — Build the app (agent, before any of this)

Scaffold per `~/Repos/rails-app-template` (its README is the how; procedures.md
§11 the why). Constellation checklist on top of the template:

- `rails new <app> --skip-kamal --skip-docker --skip-action-cable` — **never
  `--skip-bundle`** (skips importmap/solid_queue/solid_cache installers →
  prod crash-loop; upkeep). Strip thruster.
- Verify before first push (all bit upkeep, all pre-cleared in postings):
  - `.github/workflows/deploy.yml` = current template (has `git reset --hard
    origin/main` + tailnet healthcheck verify — old one silently no-op'd).
  - `db/queue_schema.rb` + `db/cache_schema.rb` + `bin/jobs` exist;
    `production.rb` wires solid_queue/solid_cache.
  - `deploy/<app>.service` has `SOLID_QUEUE_IN_PUMA=true`.
  - `config/database.yml` production sqlite paths uncommented.
  - `db/seeds.rb` starts with `return unless Rails.env.development?`.
  - Any must-exist-in-prod row (e.g. postings' General profile) ships as a
    **data migration**, not seeds — schema-loaded test DBs won't have it
    either, so models need a self-healing `ensure_*!`.
  - ⚠️ Fresh-scaffold gem check: `json` 3.0.x breaks ActiveSupport 8.1 cookie
    parsing (arity error on every 2nd request) — pin `json ~> 2.9` (postings).
- Design system (push design-system BEFORE the app): Radix scale @imports if
  new color, full `[data-app="<app>"]` block — **include
  `--accent-soft/--accent-soft-hover/--accent-text`**, not just accent-N
  (upkeep shipped without them and its nav tint fell back to indigo) — plus
  `apps-launcher.js` LOGO + APPS entry, and `public/icon.svg` + `icon.png`
  in the app.
- base: add `https://<app>.joenguyen.ca/api/mcp` to `McpOauth::DEFAULT_RESOURCES`
  (lib/mcp_oauth.rb) — ⚠️ tokens carry this list as `aud`; missing = opaque
  connector failure (budgeter, upkeep). Deploy base before Phase F.
- Housekeeping: `.claude/launch.json` (next free local port), context repo
  `bin/secrets-save` + `bin/secrets-install` APPS lists, per-app
  `semantic/apps/<app>.md`, CLAUDE.md filled in.
- Tests + `bin/rubocop -A` + `bin/brakeman --no-pager` +
  `bundle exec bundler-audit update && bundler-audit` all green.

## Phase B — Push (agent, with Joe's approval)

Order matters:

1. **design-system** → verify CDN picked it up:
   `curl -s https://design-system.joenguyen.ca/design-system.css | grep '<app>'`
2. **base** (audience list) → Deploy workflow green.
3. **context** repo.
4. **The app**: `gh repo create jnguyen1990/<app> --private --source=. --push`
   - ⚠️ gh token needs the `workflow` scope to push `.github/workflows/`
     (`gh auth refresh -s workflow` if refused — bit the mini on upkeep).
   - First **Deploy** workflow run fails: expected (no LXC/secrets yet).
     **CI** on main must be green.

## Phase C — Master key to 1Password (Joe, 5 min)

The key exists only on the build machine at `<app>/config/master.key` and is
gitignored. Before provisioning:

- With `op` signed in on the build machine: `~/Repos/context/bin/secrets-save`
  (check the APPS list includes the new app), **or**
- Manually: `ssh <build-machine> cat Repos/<app>/config/master.key | pbcopy`
  → 1Password → AI Access vault → new document named exactly `<app> master.key`.
- ⚠️ Never paste the key into chat (forced a rotation 2026-06-11).
- Later, run `bin/secrets-install` on the other machines to sync it down.

## Phase D — Provision (Joe, PVE shell, ~15 min)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/jnguyen1990/proxmox-scripts/main/bootstrap.sh)"
```

- Prompts: `REPO_NAME=<app>`, paste `RAILS_MASTER_KEY`; everything else comes
  from `/root/.proxmox-deploy-secrets` (CF, TS, GH_PAT, INTER_APP_SECRET) or
  defaults (port 3000, Ruby 3.3.11, 1 GB/4 GB/1 core).
- ⚠️ **Fine-grained GH_PAT needs `Workflows: write`** as a SEPARATE permission
  from `Contents: write` — Contents alone 403s pushing
  `.github/workflows/deploy.yml` and the script dies before setting the
  TS_OAUTH repo secrets (postings). Harmless for the file itself (the repo
  ships deploy.yml), but then set the secrets by hand:
  `grep TS_OAUTH /root/.proxmox-deploy-secrets` on PVE, then
  `gh secret set TS_OAUTH_CLIENT_ID -R jnguyen1990/<app>` (+ `_SECRET`)
  pasting the values.
- The script auto-writes `secrets.conf` **and `oauth.conf`** drop-ins, points
  cloudflared at 127.0.0.1, and sets DEPLOY_* repo secrets.
- **Record the CTID** in `context/semantic/apps.md`'s CTID map.
- Partial failure → re-run with `_ repair` appended (idempotent).

## Phase E — Verify auto-deploy (Joe or agent, 2 min)

```bash
gh run rerun $(gh run list -R jnguyen1990/<app> --workflow=Deploy --limit 1 --json databaseId --jq '.[0].databaseId') -R jnguyen1990/<app>
gh run watch -R jnguyen1990/<app> --exit-status
```

(⚠️ deploy.yml has no `workflow_dispatch` trigger — rerun the failed run or
push a commit.) Green now means verified: the workflow curls
`http://<app>.tail5ece07.ts.net:3000/up` for 60s. If green but the public URL
502s, the two historical culprits on the container:

```bash
pct exec <ctid> -- grep -n 'service:' /etc/cloudflared/config.yml   # must be 127.0.0.1, not localhost (::1 502)
pct exec <ctid> -- journalctl -u <app> -n 50 --no-pager             # Solid Queue crash-loop
```

## Phase F — Protect + connect (Joe, dashboards)

1. **Cloudflare Access — immediately, the app is public until this.**
   Zero Trust → Access → Applications → consolidated app → Edit →
   + Add public hostname → `<app>` / `joenguyen.ca` → Save.
   - ⚠️ Access apps cap at 5 domains. If refused: second `self_hosted` app
     with the same email-OTP policy (verify the email byte-for-byte —
     anti-enumeration means typos silently never get codes). **Never** a
     `*.joenguyen.ca` wildcard — it would OTP-gate design-system.joenguyen.ca
     and break the CDN CSS.
   - Verify: incognito → `https://<app>.joenguyen.ca` → OTP screen → app.
2. **Drop-in check** (upkeep's opaque-401): 
   `pct exec <ctid> -- ls /etc/systemd/system/<app>.service.d/`
   → expect `secrets.conf` + `oauth.conf`.
3. **mcp.conf API-key fallback** (manual by design, optional):
   ```bash
   pct exec <ctid> -- bash -lc 'printf "[Service]\nEnvironment=MCP_API_KEY=%s\n" "$(openssl rand -hex 24)" > /etc/systemd/system/<app>.service.d/mcp.conf && chmod 600 /etc/systemd/system/<app>.service.d/mcp.conf && systemctl daemon-reload && systemctl restart <app>'
   ```
4. **Connector**: claude.ai → Settings → Connectors → Add custom connector →
   `https://<app>.joenguyen.ca/api/mcp` — URL only, OAuth auto-discovers base
   (audience already deployed in Phase B). One Access OTP on first connect.
   - ⚠️ Tools are never callable in the session that added the connector —
     smoke-test in a **fresh chat**.

## Phase G — App config (Joe)

Prod starts empty (seeds are dev-only). Enter real config via the web UI or
the fresh MCP chat; for inter-app reporting set the app's base URL setting to
`http://base.tail5ece07.ts.net:3000`.

## Phase H — Close out (agent)

- Record CTID + go-live in `context/semantic/apps.md`, `apps/<app>.md`,
  history entry.
- Create any scheduled cloud routine the app depends on (e.g. postings'
  nightly sweep) — only after the connector is confirmed working.
- Kill review servers/mockups on the mini; `bin/secrets-install` on the
  laptop next time it's used.
