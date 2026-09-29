#!/usr/bin/env bash
# Adds this repo's AI agent setup (Claude Code settings, plugins, MCP servers,
# plugin-install hook) to a project.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Yuzhouboat/ai-data-agent-example/main/install.sh) [--local] [project-dir]
#   ./install.sh [--local] [project-dir]        # from a clone of this repo
#
# project-dir defaults to the git repo you're in (or the current directory).
#
# Claude Code only reads its config from fixed places in the project, so the
# kit is merged into those files rather than dropped in a folder of its own.
# Existing settings are kept; keys the kit also sets are overwritten (and
# listed). Re-running updates the project to the latest kit.
#
# Default (shared): merges into .claude/settings.json and .mcp.json, copies
#   .claude/hooks/install-plugins.py and adds ignore rules to .gitignore — for
#   you to commit, so everyone who clones the project gets it.
# --local: merges into .claude/settings.local.json instead (plugins install at
#   local scope), and hides every file it writes through this clone's
#   .git/info/exclude — nothing shows in `git status`, nothing to commit. For
#   repos you use but don't want to add this to. Only this clone has it.
set -euo pipefail

BRANCH="${AI_KIT_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/Yuzhouboat/ai-data-agent-example/$BRANCH"
KIT_FILES=(.claude/settings.json .claude/hooks/install-plugins.py .mcp.json)

mode=shared
while [ $# -gt 0 ]; do
    case "$1" in
        --local) mode=local ;;
        -h|--help)
            echo "Usage: install.sh [--local] [project-dir]"
            echo "  (default)  merge the AI settings into the project's shared files, for committing"
            echo "  --local    merge into settings.local.json and hide it via .git/info/exclude"
            echo "project-dir defaults to the git repo you're in."
            exit 0 ;;
        -*) echo "Unknown option: $1 (usage: install.sh [--local] [project-dir])"; exit 1 ;;
        *) break ;;
    esac
    shift
done

if [ $# -gt 0 ]; then
    PROJECT="$1"
else
    PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
PROJECT="$(cd "$PROJECT" && pwd -P)"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required."; exit 1; }

# Kit files: from this clone if we're running from one, else GitHub.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
if [ -n "$HERE" ] && [ "$HERE" = "$PROJECT" ]; then
    echo "$PROJECT is the kit itself — pass the project to install into."
    exit 1
fi
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
for f in "${KIT_FILES[@]}"; do
    mkdir -p "$SRC/$(dirname "$f")"
    if [ -n "$HERE" ] && [ -f "$HERE/.claude/hooks/install-plugins.py" ]; then
        cp "$HERE/$f" "$SRC/$f"
    else
        curl -fsSL "$RAW_BASE/$f" -o "$SRC/$f"
    fi
done

echo "Installing AI settings into $PROJECT$([ "$mode" = local ] && echo ' (local only)')"
echo

python3 - "$SRC" "$PROJECT" "$mode" <<'PY'
import json
import shutil
import subprocess
import sys
from pathlib import Path

src, project, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
HOOK = ".claude/hooks/install-plugins.py"
IGNORES = [".claude/settings.local.json", ".playwright-mcp/"]


def git(*args):
    return subprocess.run(["git", "-C", str(project), *args], capture_output=True, text=True)


def tracked(rel):
    return git("ls-files", "--error-unmatch", "--", rel).returncode == 0


def load(path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except ValueError as e:
        sys.exit(f"{path} isn't valid JSON ({e}) — fix it and re-run.")


def commands(entry):
    return {h.get("command") for h in entry.get("hooks", [])} if isinstance(entry, dict) else set()


def merge(dst, new, changed, path=""):
    """Deep-merge new into dst. Lists are unioned; a hook group replaces any
    existing group running the same command, so re-installs don't duplicate it."""
    for k, v in new.items():
        key = f"{path}.{k}" if path else k
        cur = dst.get(k)
        if isinstance(v, dict) and isinstance(cur, dict):
            merge(cur, v, changed, key)
        elif isinstance(v, list) and isinstance(cur, list):
            for item in v:
                if item in cur:
                    continue
                cmds = commands(item)
                if cmds:
                    cur[:] = [c for c in cur if not (commands(c) & cmds)]
                cur.append(item)
        else:
            if k in dst and cur != v:
                changed.append(key)
            dst[k] = v


def merge_json(rel_dst, new):
    path = project / rel_dst
    data = load(path)
    changed = []
    merge(data, new, changed)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"  merged   {rel_dst}")
    for key in changed:
        print(f"           (overwrote {key})")


def copy(rel):
    dst = project / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src / rel, dst)
    print(f"  copied   {rel}")


def append_lines(path, header, lines):
    existing = path.read_text().splitlines() if path.exists() else []
    todo = [line for line in lines if line not in existing]
    if not todo:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        if existing and existing[-1].strip():
            f.write("\n")
        f.write(f"# {header}\n" + "".join(f"{line}\n" for line in todo))
    print(f"  added to {path}: {' '.join(todo)}")


settings = load(src / ".claude/settings.json")
servers = load(src / ".mcp.json").get("mcpServers", {})

if mode == "shared":
    merge_json(".claude/settings.json", settings)
    copy(HOOK)
    merge_json(".mcp.json", {"mcpServers": servers})
    append_lines(project / ".gitignore", "AI agent settings", IGNORES)
    if git("rev-parse", "--is-inside-work-tree").returncode == 0:
        print("\nCommit it so everyone who clones the project gets it:")
        print(f"  git -C '{project}' add .claude .mcp.json .gitignore && git -C '{project}' commit -m 'Add AI agent settings'")
    sys.exit(0)

# --- local ---------------------------------------------------------------------
if git("rev-parse", "--is-inside-work-tree").returncode != 0:
    sys.exit(f"--local needs a git repo (it hides files via .git/info/exclude).\n{project} isn't one — run without --local instead.")
if tracked(HOOK) and (project / HOOK).read_bytes() != (src / HOOK).read_bytes():
    sys.exit(f"This repo already tracks a different {HOOK}; a local install would clash with it.")

hidden = list(IGNORES)
merge_json(".claude/settings.local.json", settings)
if not tracked(HOOK):
    copy(HOOK)
    hidden.append(HOOK)

if not tracked(".mcp.json"):
    merge_json(".mcp.json", {"mcpServers": servers})
    hidden.append(".mcp.json")
else:
    # The repo's own .mcp.json can't change without showing in git status, so
    # register the servers in this clone's local scope (~/.claude.json) instead.
    for name, cfg in servers.items():
        cmd = ["claude", "mcp", "add-json", "--scope", "local", name, json.dumps(cfg)]
        if shutil.which("claude"):
            subprocess.run(["claude", "mcp", "remove", "--scope", "local", name], cwd=project, capture_output=True)
            r = subprocess.run(cmd, cwd=project, capture_output=True, text=True)
            ok = r.returncode == 0
        else:
            ok = False
        if ok:
            print(f"  added MCP server '{name}' at local scope (repo tracks its own .mcp.json)")
        else:
            print(f"  !! couldn't add MCP server '{name}'; run in {project}:\n     {' '.join(cmd[:-1])} '{cmd[-1]}'")

exclude = Path(git("rev-parse", "--path-format=absolute", "--git-path", "info/exclude").stdout.strip())
append_lines(exclude, "AI agent settings, installed locally (not part of this repo)", ["/" + p for p in hidden])

print("\nLocal install done — nothing to commit; git status stays clean.")
print("To uninstall: remove the kit's keys from .claude/settings.local.json, delete the")
print(f"hidden files above, and their lines from {exclude}.")
PY

echo
echo "Next: set the credentials listed in the kit's README (MySQL, AWS, GitHub, MLflow),"
echo "then run \`claude\` in $PROJECT — the SessionStart hook installs the plugins;"
echo "/reload-plugins loads them."
