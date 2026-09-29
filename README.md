# ai-data-agent-example

Example project showing how to set up an AI coding agent ([Claude Code](https://claude.com/claude-code))
to work with data sources through MCP servers and plugins.

## Adding it to a project

`install.sh` copies this repo's AI setup into another project. Claude Code only reads config from fixed
places (`.claude/settings*.json`, `.mcp.json`), so the kit is **merged** into those files: the project's own
settings are kept, keys the kit also sets are overwritten (the installer lists them), and re-running it
updates the project to the latest kit.

**Shared with the repo** — commit it, and everyone who clones the project gets it:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yuzhouboat/ai-data-agent-example/main/install.sh)
git add .claude .mcp.json .gitignore && git commit -m "Add AI agent settings"
```
Merges into `.claude/settings.json` and `.mcp.json`, copies the plugin hook, and adds
`.claude/settings.local.json` and `.playwright-mcp/` to `.gitignore`.

**Local only** — for a repo you've cloned but don't want to add this to:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yuzhouboat/ai-data-agent-example/main/install.sh) --local
```
Merges the settings into `.claude/settings.local.json` (so plugins install at local scope), and hides every
file it writes through that clone's `.git/info/exclude` — nothing shows in `git status`. If the repo already
tracks its own `.mcp.json`, the MCP servers are added at local scope (`claude mcp add-json --scope local`)
instead of editing it.

Both forms take an optional project path (default: the git repo you're in), and work the same from a clone
of this repo: `./install.sh [--local] [project-dir]`. Then follow [Setup](#setup) from step 2 in that project.

## What's included

| File | Purpose |
|---|---|
| `install.sh` | Adds the files below to another project (shared or `--local`) — see above |
| `.mcp.json` | Project MCP server: MySQL via [`@toolbox-sdk/server`](https://www.npmjs.com/package/@toolbox-sdk/server) (`@latest`, so it updates on each session start) |
| `.claude/settings.json` | Enabled plugins (`aws-core`, `aws-data-analytics`, `mlflow-tracing`, `github`), the extra MLflow marketplace, MLflow tracing env (server URL + experiment), and the SessionStart hook |
| `.claude/hooks/install-plugins.py` | SessionStart hook that installs any enabled plugin missing on this machine and updates the installed ones (at local scope for plugins enabled in `settings.local.json`) |
| `.gitignore` | Keeps `.env*`, `settings.local.json`, CSV exports and Playwright MCP snapshots out of git |

With this setup the agent can:

- **MySQL** – query directly through the `mysql` MCP server.
- **AWS / Redshift** – run AWS API calls (including the Redshift Data API) through the `aws-mcp` server bundled with the AWS plugins.
- **GitHub** – manage issues, pull requests, code review and repo search through GitHub's official MCP server
  (`github` plugin, hosted at `https://api.githubcopilot.com/mcp/`).
- **MLflow** – trace agent sessions via the `mlflow-tracing` plugin to a self-hosted MLflow server
  (`https://mlflow.yliumono.click`, served through a Cloudflare Tunnel and protected by MLflow's basic-auth login).

## Setup

1. Install [Claude Code](https://claude.com/claude-code), Node.js (for `npx`) and [uv](https://docs.astral.sh/uv/) (for `uvx`).
2. Export the MySQL connection settings before starting Claude Code:

   ```bash
   export MYSQL_HOST=...
   export MYSQL_PORT=3306
   export MYSQL_DATABASE=...
   export MYSQL_USER=...
   export MYSQL_PASSWORD=...
   ```

3. Make AWS credentials available (e.g. `aws login`, a profile, or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`).
4. Traces go to `https://mlflow.yliumono.click` (experiment `yliu`, ID 2), which requires a login. Put it in
   the git-ignored `.claude/settings.local.json` (or export the same variables):

   ```json
   {
     "env": {
       "MLFLOW_TRACKING_USERNAME": "...",
       "MLFLOW_TRACKING_PASSWORD": "..."
     }
   }
   ```

5. Export a GitHub personal access token for the `github` plugin. A
   [fine-grained token](https://github.com/settings/personal-access-tokens) limited to the repos you need is safest:

   ```bash
   export GITHUB_PERSONAL_ACCESS_TOKEN=...
   ```

6. Run `claude` in this folder. On first start the hook installs the plugins; run `/reload-plugins` (or restart) to load them.
7. Approve the `mysql` MCP server when prompted.

## Keeping things up to date

- **MCP servers** pinned to `@latest` (`mysql`, `aws-mcp`) fetch the newest release each time a session starts.
- **Plugins** are updated by the SessionStart hook on each fresh start; updates load after `/reload-plugins` or the next restart.
- **The kit itself** (in projects it was installed into): re-run `install.sh` (with `--local` for local installs)
  after changing this repo; commit the result in shared projects.

## Notes

- Credentials are never stored in the repo; `.mcp.json` and the `github` plugin read them from environment variables.
- Personal overrides (including the MLflow login) go in `.claude/settings.local.json`, which is git-ignored.
- If traces don't show up, check the MLflow credentials: the server answers `401` without them.
- Playwright MCP snapshots and screenshots (`.playwright-mcp/`) can capture secrets from pages, so they are git-ignored.
