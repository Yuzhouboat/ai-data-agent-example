# ai-data-agent-example

Example project showing how to set up an AI coding agent ([Claude Code](https://claude.com/claude-code))
to work with data sources through MCP servers and plugins.

## What's included

| File | Purpose |
|---|---|
| `.mcp.json` | Project MCP server: MySQL via [`@toolbox-sdk/server`](https://www.npmjs.com/package/@toolbox-sdk/server) (`@latest`, so it updates on each session start) |
| `.claude/settings.json` | Enabled plugins (`aws-core`, `aws-data-analytics`, `mlflow-tracing`), the extra MLflow marketplace, MLflow tracing env (server URL + experiment), and the SessionStart hook |
| `.claude/hooks/install-plugins.py` | SessionStart hook that installs any enabled plugin missing on this machine and updates the installed ones |
| `.gitignore` | Keeps `.env*`, `settings.local.json`, CSV exports and Playwright MCP snapshots out of git |

With this setup the agent can:

- **MySQL** – query directly through the `mysql` MCP server.
- **AWS / Redshift** – run AWS API calls (including the Redshift Data API) through the `aws-mcp` server bundled with the AWS plugins.
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

5. Run `claude` in this folder. On first start the hook installs the plugins; run `/reload-plugins` (or restart) to load them.
6. Approve the `mysql` MCP server when prompted.

## Keeping things up to date

- **MCP servers** pinned to `@latest` (`mysql`, `aws-mcp`) fetch the newest release each time a session starts.
- **Plugins** are updated by the SessionStart hook on each fresh start; updates load after `/reload-plugins` or the next restart.

## Notes

- Credentials are never stored in the repo; `.mcp.json` reads them from environment variables.
- Personal overrides (including the MLflow login) go in `.claude/settings.local.json`, which is git-ignored.
- If traces don't show up, check the MLflow credentials: the server answers `401` without them.
- Playwright MCP snapshots and screenshots (`.playwright-mcp/`) can capture secrets from pages, so they are git-ignored.
