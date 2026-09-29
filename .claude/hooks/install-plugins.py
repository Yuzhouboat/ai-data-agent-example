#!/usr/bin/env python3
"""SessionStart hook: install any plugin enabled in project settings that isn't installed yet,
and update the ones that are.

Claude Code doesn't auto-install plugins from external sources listed in a repo's
.claude/settings.json, so on a fresh machine this does it. Newly installed or updated
plugins load after /reload-plugins or a restart.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

project_dir = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def load_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


# Plugins enabled in settings.local.json (a local-only install of this kit) are installed
# at local scope, so nothing gets written to the shared settings.json.
enabled = {}
scope_of = {}
marketplaces = {}
for scope, name in (("project", "settings.json"), ("local", "settings.local.json")):
    s = load_json(project_dir / ".claude" / name)
    for plugin, on in (s.get("enabledPlugins") or {}).items():
        enabled[plugin] = on
        scope_of[plugin] = scope
    marketplaces.update(s.get("extraKnownMarketplaces") or {})

wanted = [p for p, on in enabled.items() if on is True and not p.endswith(("@synced", "@builtin"))]

installed = load_json(config_dir / "plugins" / "installed_plugins.json").get("plugins", {})


def is_installed(plugin):
    for entry in installed.get(plugin, []):
        if entry.get("scope") == "user":
            return True
        path = entry.get("projectPath")
        if path and Path(path).resolve() == project_dir:
            return True
    return False


missing = [p for p in wanted if not is_installed(p)]
present = [p for p in wanted if p not in missing]
if not wanted:
    sys.exit(0)


def run(*args):
    r = subprocess.run(["claude", "plugin", *args], cwd=project_dir, capture_output=True, text=True, timeout=240)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


known = load_json(config_dir / "plugins" / "known_marketplaces.json")
ok, failed = [], []
for plugin in missing:
    market = plugin.split("@", 1)[1] if "@" in plugin else None
    source = (marketplaces.get(market) or {}).get("source") or {}
    if market and market not in known and source.get("source") == "github":
        args = ["marketplace", "add", source["repo"], "--scope", scope_of[plugin]]
        if source.get("sparsePaths"):
            args += ["--sparse", *source["sparsePaths"]]
        run(*args)
        known[market] = True
    success, output = run("install", plugin, "--scope", scope_of[plugin])
    if success:
        ok.append(plugin)
    else:
        failed.append(f"{plugin}: {output.splitlines()[-1] if output else 'unknown error'}")

# Refresh each marketplace once so updates see its latest catalog.
for market in {p.split("@", 1)[1] for p in present if "@" in p}:
    run("marketplace", "update", market)

updated = []
for plugin in present:
    success, output = run("update", plugin, "--scope", scope_of[plugin], "--json")
    try:
        result = json.loads(output.splitlines()[0])
    except (IndexError, ValueError):
        result = {}
    if success and result.get("updateOutcome") == "up_to_date":
        continue
    if success:
        updated.append(f"{plugin} ({result.get('oldVersion')} -> {result.get('newVersion')})")
    else:
        failed.append(f"{plugin} update: {result.get('message') or (output.splitlines()[-1] if output else 'unknown error')}")

parts = []
if ok:
    parts.append(f"Installed plugins: {', '.join(ok)}. Run /reload-plugins to load them.")
if updated:
    parts.append(f"Updated plugins: {', '.join(updated)}. Run /reload-plugins to load them.")
if failed:
    parts.append("Plugin problems: " + "; ".join(failed))
if parts:
    print(json.dumps({"systemMessage": " ".join(parts)}))
