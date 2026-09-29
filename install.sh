#!/usr/bin/env bash
# Adds this repo's AI agent setup (Claude Code settings, plugins, MCP servers,
# plugin-install hook) to a project — or takes it back out.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Yuzhouboat/ai-data-agent-example/main/install.sh) [--local | --uninstall] [project-dir]
#   ./install.sh [--local | --uninstall] [project-dir]        # from a clone of this repo
#
# project-dir defaults to the git repo you're in (or the current directory);
# it doesn't have to be a git repo.
#
# Claude Code only reads its config from fixed places in the project, so the
# kit is merged into those files rather than dropped in a folder of its own.
# Existing settings are kept; keys the kit also sets are overwritten (and
# listed). Re-running updates the project to the latest kit.
#
# Default (shared): merges into .claude/settings.json and .mcp.json, copies
#   .claude/hooks/install-plugins.py and, in a git repo, adds ignore rules to
#   .gitignore — for you to commit, so everyone who clones the project gets it.
# --local: merges into .claude/settings.local.json instead (plugins install at
#   local scope) and, in a git repo, hides every file it writes through
#   .git/info/exclude — nothing shows in `git status`, nothing to commit.
# --uninstall: undoes whichever install is there. Every change is recorded in
#   .claude/ai-kit.json at install time; uninstall uninstalls the kit's plugins
#   for this project, restores overwritten values, deletes what the kit
#   created and drops its ignore lines. Anything edited since is left alone
#   (and listed).
set -euo pipefail

BRANCH="${AI_KIT_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/Yuzhouboat/ai-data-agent-example/$BRANCH"
KIT_FILES=(.claude/settings.json .claude/hooks/install-plugins.py .mcp.json)
USAGE="Usage: install.sh [--local | --uninstall] [project-dir]"

mode=shared
while [ $# -gt 0 ]; do
    case "$1" in
        --local) mode=local ;;
        --uninstall) mode=uninstall ;;
        -h|--help)
            echo "$USAGE"
            echo "  (default)    merge the AI settings into the project's shared files, for committing"
            echo "  --local      merge into settings.local.json; in a git repo, hide it via .git/info/exclude"
            echo "  --uninstall  undo the install (either kind)"
            echo "project-dir defaults to the git repo you're in, else the current directory."
            exit 0 ;;
        -*) echo "Unknown option: $1 ($USAGE)"; exit 1 ;;
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

SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
if [ "$mode" != uninstall ]; then
    # Kit files: from this clone if we're running from one, else GitHub.
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
    if [ -n "$HERE" ] && [ "$HERE" = "$PROJECT" ]; then
        echo "$PROJECT is the kit itself — pass the project to install into."
        exit 1
    fi
    for f in "${KIT_FILES[@]}"; do
        mkdir -p "$SRC/$(dirname "$f")"
        if [ -n "$HERE" ] && [ -f "$HERE/.claude/hooks/install-plugins.py" ]; then
            cp "$HERE/$f" "$SRC/$f"
        else
            curl -fsSL "$RAW_BASE/$f" -o "$SRC/$f"
        fi
    done
fi

python3 - "$SRC" "$PROJECT" "$mode" <<'PY'
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

src, project, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
MANIFEST = ".claude/ai-kit.json"
HOOK = ".claude/hooks/install-plugins.py"
IGNORES = [".claude/settings.local.json", ".playwright-mcp/"]
HEADERS = {
    "gitignore": "# AI agent settings",
    "exclude": "# AI agent settings, installed locally (not part of this repo)",
}
MISSING = object()


# --- git ---------------------------------------------------------------------
def git(*args):
    try:
        return subprocess.run(["git", "-C", str(project), *args], capture_output=True, text=True)
    except FileNotFoundError:  # no git on this machine: treat as "not a repo"
        return subprocess.CompletedProcess(args, 1, "", "")


in_git = git("rev-parse", "--is-inside-work-tree").stdout.strip() == "true"
# project-dir may be a subfolder of the repo; exclude patterns are repo-relative.
prefix = git("rev-parse", "--show-prefix").stdout.strip() if in_git else ""


def tracked(rel):
    return in_git and git("ls-files", "--error-unmatch", "--", rel).returncode == 0


def ignore_file(kind):
    if kind == "gitignore":
        return project / ".gitignore"
    return Path(git("rev-parse", "--path-format=absolute", "--git-path", "info/exclude").stdout.strip())


# --- helpers -------------------------------------------------------------------
def load(path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except ValueError as e:
        sys.exit(f"{path} isn't valid JSON ({e}) — fix it and re-run.")


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def commands(entry):
    return {h.get("command") for h in entry.get("hooks", [])} if isinstance(entry, dict) else set()


def dotted(path):
    return ".".join(path)


def node(data, path):
    for k in path:
        if not isinstance(data, dict) or k not in data:
            return MISSING
        data = data[k]
    return data


def claude(*args):
    if not shutil.which("claude"):
        return False
    return subprocess.run(["claude", *args], cwd=project, capture_output=True, text=True).returncode == 0


# --- install -------------------------------------------------------------------
def merge(dst, new, rec, changed, path=()):
    """Deep-merge new into dst, recording in rec how to undo it. Lists are
    unioned; a hook group replaces any existing group running the same
    command, so re-installs don't duplicate it."""
    for k, v in new.items():
        p = [*path, k]
        cur = dst.get(k, MISSING)
        if isinstance(v, (dict, list)) and cur is MISSING:
            dst[k] = cur = type(v)()
            if p not in rec["containers"]:
                rec["containers"].append(p)
        if isinstance(v, dict) and isinstance(cur, dict):
            merge(cur, v, rec, changed, p)
            continue
        if isinstance(v, list) and isinstance(cur, list):
            for item in v:
                if item in cur:
                    continue
                cmds = commands(item)
                for old in [c for c in cur if cmds and commands(c) & cmds]:
                    cur.remove(old)
                    if [p, old] in rec["items"]:
                        rec["items"].remove([p, old])
                    else:
                        rec["removed"].append([p, old])
                cur.append(item)
                rec["items"].append([p, item])
            continue
        key = json.dumps(p)
        if key not in rec["keys"]:
            rec["keys"][key] = {"absent": True} if cur is MISSING else {"orig": cur}
        rec["keys"][key]["set"] = v
        if cur is not MISSING and cur != v:
            changed.append(dotted(p))
        dst[k] = v


def merge_json(rel, new):
    path = project / rel
    rec = manifest["json"].setdefault(
        rel, {"created": not path.exists(), "keys": {}, "containers": [], "items": [], "removed": []})
    if path.exists():
        rec.setdefault("text", path.read_text())  # to restore it byte for byte
    data = load(path)
    changed = []
    merge(data, new, rec, changed)
    save(path, data)
    print(f"  merged   {rel}")
    for key in changed:
        print(f"           (overwrote {key})")


def copy(rel):
    dst = project / rel
    rec = manifest["copied"].setdefault(rel, {})
    if "orig" not in rec and "created" not in rec:
        if dst.exists() and dst.read_bytes() != (src / rel).read_bytes():
            rec["orig"] = dst.read_text()
        else:
            rec["created"] = not dst.exists()
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src / rel, dst)
    rec["sha"] = sha(dst)
    print(f"  copied   {rel}")


def note_dirs(*rels):
    for rel in rels:
        if not (project / rel).exists() and rel not in manifest["dirs"]:
            manifest["dirs"].append(rel)


def add_lines(kind, lines):
    path = ignore_file(kind)
    rec = manifest["lines"].setdefault(kind, {"created": not path.exists(), "lines": []})
    existing = path.read_text().splitlines() if path.exists() else []
    todo = [line for line in lines if line not in existing]
    if not todo:
        return
    header = HEADERS[kind]
    if header not in existing:
        todo.insert(0, header)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        if existing and existing[-1].strip():
            f.write("\n")
        f.write("".join(f"{line}\n" for line in todo))
    rec["lines"] += [line for line in todo if line not in rec["lines"]]
    print(f"  added to {path}: {' '.join(line for line in todo if line != header)}")


def install():
    installed = manifest.get("mode")
    if installed and installed != mode:
        sys.exit(f"Already installed in {installed} mode — run install.sh --uninstall first to switch.")
    manifest["mode"] = mode
    print(f"Installing AI settings into {project}{' (local only)' if mode == 'local' else ''}")
    if not in_git:
        print("(not a git repo — nothing to hide from git or add to .gitignore)")
    print()

    settings_rel = ".claude/settings.json" if mode == "shared" else ".claude/settings.local.json"
    if mode == "local":
        if tracked(settings_rel):
            sys.exit(f"This repo tracks {settings_rel}, so a local install can't use it.")
        if tracked(HOOK) and (project / HOOK).read_bytes() != (src / HOOK).read_bytes():
            sys.exit(f"This repo already tracks a different {HOOK}; a local install would clash with it.")

    note_dirs(".claude", ".claude/hooks")
    settings = load(src / ".claude/settings.json")
    servers = load(src / ".mcp.json").get("mcpServers", {})
    merge_json(settings_rel, settings)
    if not tracked(HOOK):
        copy(HOOK)

    if mode == "local" and tracked(".mcp.json"):
        # The repo's own .mcp.json can't change without showing in git status,
        # so register the servers in this clone's local scope (~/.claude.json).
        for name, cfg in servers.items():
            claude("mcp", "remove", "--scope", "local", name)
            if claude("mcp", "add-json", "--scope", "local", name, json.dumps(cfg)):
                if name not in manifest["mcp_local"]:
                    manifest["mcp_local"].append(name)
                print(f"  added MCP server '{name}' at local scope (repo tracks its own .mcp.json)")
            else:
                print(f"  !! couldn't add MCP server '{name}'; run in {project}:\n"
                      f"     claude mcp add-json --scope local {name} '{json.dumps(cfg)}'")
    else:
        merge_json(".mcp.json", {"mcpServers": servers})

    save(project / MANIFEST, manifest)
    if in_git and mode == "shared":
        add_lines("gitignore", IGNORES)
    elif in_git:
        written = [settings_rel, MANIFEST, *manifest["copied"], *manifest["json"]]
        hidden = dict.fromkeys(["/" + prefix + p for p in [*IGNORES, *written]])
        add_lines("exclude", list(hidden))
    save(project / MANIFEST, manifest)  # again, now with the ignore lines

    print()
    if mode == "local":
        print("Local install done" + (" — nothing to commit; git status stays clean." if in_git else "."))
    elif in_git:
        print("Commit it so everyone who clones the project gets it:")
        print(f"  git -C '{project}' add .claude .mcp.json .gitignore && git -C '{project}' commit -m 'Add AI agent settings'")
    print("To undo: install.sh --uninstall" + (f" '{project}'" if Path.cwd() != project else ""))
    print()
    print("Next: set the credentials listed in the kit's README (MySQL, AWS, GitHub, MLflow),")
    print(f"then run `claude` in {project} — the SessionStart hook installs the plugins;")
    print("/reload-plugins loads them.")


# --- uninstall -----------------------------------------------------------------
def uninstall_plugins(rec, scope):
    """Uninstall the plugins the kit enabled, for this project only."""
    ours = [json.loads(k)[1] for k, r in rec["keys"].items()
            if json.loads(k)[0] == "enabledPlugins" and r.get("absent")]
    config = Path.home() / ".claude" / "plugins" / "installed_plugins.json"
    installed = load(config).get("plugins", {})
    for plugin in ours:
        here = [e for e in installed.get(plugin, [])
                if e.get("scope") == scope and Path(e.get("projectPath", "/nonexistent")).resolve() == project]
        if not here:
            continue
        if claude("plugin", "uninstall", plugin, "--scope", scope):
            print(f"  uninstalled plugin {plugin} ({scope} scope)")
        else:
            print(f"  !! couldn't uninstall plugin {plugin}; run: claude plugin uninstall {plugin} --scope {scope}")


def unmerge(rel, rec, kept):
    path = project / rel
    if not path.exists():
        return
    data = load(path)
    for key, r in rec["keys"].items():
        p = json.loads(key)
        parent = node(data, p[:-1])
        cur = parent.get(p[-1], MISSING) if isinstance(parent, dict) else MISSING
        if cur is MISSING:
            if not r.get("absent"):
                kept.append(f"{rel}: {dotted(p)} was removed since install; not restored")
            continue
        if cur != r["set"]:
            kept.append(f"{rel}: {dotted(p)} changed since install; left as is")
        elif r.get("absent"):
            del parent[p[-1]]
        else:
            parent[p[-1]] = r["orig"]
    for p, item in rec["items"]:
        lst = node(data, p)
        if isinstance(lst, list) and item in lst:
            lst.remove(item)
    for p, item in rec["removed"]:
        lst = node(data, p)
        if isinstance(lst, list) and item not in lst:
            lst.append(item)
    for p in sorted(rec["containers"], key=len, reverse=True):
        parent, c = node(data, p[:-1]), node(data, p)
        if isinstance(parent, dict) and c in ({}, []):
            del parent[p[-1]]
    if rec["created"] and data == {}:
        path.unlink()
        print(f"  removed  {rel}")
    else:
        if "text" in rec and json.loads(rec["text"]) == data:
            path.write_text(rec["text"])
        else:
            save(path, data)
        print(f"  restored {rel}")


def uncopy(rel, rec, kept):
    path = project / rel
    if not path.exists():
        return
    if sha(path) != rec["sha"]:
        kept.append(f"{rel} changed since install; left as is")
    elif "orig" in rec:
        path.write_text(rec["orig"])
        print(f"  restored {rel}")
    else:
        path.unlink()
        print(f"  removed  {rel}")


def remove_lines(kind, rec):
    path = ignore_file(kind) if in_git or kind == "gitignore" else None
    if not path or not path.exists():
        return
    lines = path.read_text().splitlines()
    for line in rec["lines"]:
        if line in lines:
            lines.remove(line)
    while lines and not lines[-1].strip():
        lines.pop()
    if rec["created"] and not lines:
        path.unlink()
        print(f"  removed  {path}")
    else:
        path.write_text("".join(f"{line}\n" for line in lines))
        print(f"  cleaned  {path}")


def uninstall():
    if not (project / MANIFEST).exists():
        sys.exit(f"No {MANIFEST} in {project} — nothing recorded to uninstall.")
    print(f"Uninstalling AI settings ({manifest['mode']} mode) from {project}\n")
    kept = []
    scope = "project" if manifest["mode"] == "shared" else "local"
    for rel, rec in manifest["json"].items():
        if rel.startswith(".claude/settings"):
            uninstall_plugins(rec, scope)
    for name in manifest["mcp_local"]:
        if claude("mcp", "remove", "--scope", "local", name):
            print(f"  removed MCP server '{name}' (local scope)")
    for rel, rec in manifest["json"].items():
        unmerge(rel, rec, kept)
    for rel, rec in manifest["copied"].items():
        uncopy(rel, rec, kept)
    for kind, rec in manifest["lines"].items():
        remove_lines(kind, rec)
    (project / MANIFEST).unlink()
    for rel in sorted(manifest["dirs"], key=len, reverse=True):
        d = project / rel
        if d.is_dir() and not any(d.iterdir()):
            d.rmdir()
    print("\nUninstalled.")
    if kept:
        print("Left alone (edited after install — tidy up by hand if you like):")
        for line in kept:
            print(f"  - {line}")
    if manifest["mode"] == "shared" and in_git:
        print("Commit the result to take it out for everyone.")


manifest = load(project / MANIFEST) or {}
for field, empty in (("json", {}), ("copied", {}), ("dirs", []), ("lines", {}), ("mcp_local", [])):
    manifest.setdefault(field, empty)
uninstall() if mode == "uninstall" else install()
PY
