# AGENTS.md

## Project Overview

This is a Godot 4.7 **editor plugin** project (not a game). It provides a
version-control panel for the Godot editor — a combination of the
"normal commit" workflow from VSCode's Source Control panel and the
visual commit graph from the Git Graph VSCode extension. The result is
a Godot dock panel that stages, commits, and pushes files with the
same ease as VSCode, plus a visible commit-graph indicator.

Two editor plugins live here:

- **`addons/godot_ai/`** — MCP server plugin that bridges AI assistants
  (Claude Code, Codex, OpenCode, etc.) to the Godot editor via
  WebSocket. Main plugin.
- **`addons/gdit_graph/`** — The version-control panel ("Gdit Graph"):
  the commit panel described above, plus branch/status indicators and
  full git integration for staging, viewing changes, and committing
  files.

## Key Architecture

### godot_ai plugin lifecycle
Plugin entry is `addons/godot_ai/plugin.gd` (extends `EditorPlugin`). The startup sequence is:
1. `_init()` — checks Godot version compatibility, builds `ServerLifecycleManager`
2. `_enter_tree()` — update barrier verification, then continues to `_continue_enter_tree_after_update_barrier()`
3. `_release_normal_startup()` — the sole release point for normal work and server lifecycle

**Handlers are lazily loaded** (see #736 in `plugin.gd`). The dispatcher registers handler script paths via `register_lazy_handler`, and they are `load()`ed at first dispatch — NOT preloaded into the compile closure. This avoids ~119 scripts being parsed/compiled on every editor boot.

### Autoload
`_mcp_game_helper` (`res://addons/godot_ai/runtime/game_helper.gd`) is registered as an autoload in `project.godot`. It runs in the game process (not editor) and handles screenshot capture, eval, and input simulation via the debugger channel.

### Plugin structure
- `@tool` scripts extend `EditorPlugin` and run in the editor
- `.gd` files have companion `.gd.uid` files (Godot's UID system)
- `addons/godot_ai/clients/` contains per-client configs (Claude Code, Codex, OpenCode, etc.)
- `addons/godot_ai/handlers/` contains ~40 handler scripts for MCP commands

## Important Conventions

- **GDScript files must NOT use `class_name`** for internal scripts (#253) — they'd pollute the project-wide global scope and cause hard-errors if a user defines the same class name.
- **Typed fields on `@tool` plugin scripts are dangerous** (#242/#244/#245) — Godot can reparse a long-lived script while its old field storage and new type shape disagree, causing crashes. Entry-load fields stay untyped.
- **EOL is LF** (enforced by `.gitattributes`: `* text=auto eol=lf`)
- **Charset is UTF-8** (`.editorconfig`)
- **Godot 4.7+ required** — plugin refuses to load on older versions

## Setup Requirements

- **Godot 4.7+** (4.x line)
- **uv** is required to install the Python MCP server. Install via:
  ```powershell
  powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
  ```
- Enable plugins via **Project > Project Settings > Plugins**

## OpenCode Client Specifics

OpenCode stores MCP servers under `mcp.<name>` (not `mcpServers`), uses `type: "remote"` for HTTP servers, and merges both `opencode.json` and `opencode.jsonc` (later file wins per key). The `OPENCODE_CONFIG` env var overrides the default config path.

Config path templates:
- Unix: `~/.config/opencode/opencode.json`
- Windows: `$HOME/.config/opencode/opencode.json`

## Version Control Plugin Note

`project.godot` references `version_control/plugin.cfg` but the `addons/version_control/` directory does not exist in this repo. The git integration is provided by `addons/gdit_graph/` (plugin name "Gdit Graph"). If `version_control` is needed, it may be a separate plugin or the `gdit_graph` plugin may need to be registered under that name.

**gdit_graph empty-state:** the panel gates all commit/stage UI on `GitManager.is_repo()`. When the project is not a git repo, only an **Init Git** button is shown (in its own row above the status message); git missing hides even that. `init_repo()` runs `git init`, then the panel re-checks and reveals the full UI. `refresh_status()` is never called when not a repo.

**gdit_graph remotes:** Pull/Fetch/Push buttons live in the header toolbar (all repo-gated). `_on_pull`/`_on_fetch`/`_on_push` refuse early with "no git remote configured" via the synchronous `has_remote()` (`git remote`) check; remote buttons disable during the op and re-enable in `_on_operation_complete`. All git work follows the existing worker-thread + `operation_complete` signal pattern — never touch UI from the thread.

**gdit_graph .gitignore:** edited through an in-panel `PopupPanel` (`res://.gitignore` via `FileAccess` on the globalized path; created empty if missing). Saving refreshes status since ignore rules change the file lists.

**gdit_graph dirty badge:** `_on_status_changed` renames the dock panel to `Version Control (*)` when staged or unstaged files exist, back to `Version Control` when clean. The base name must stay in sync with `plugin.gd` (`panel.name = "Version Control"`).

**gdit_graph layout:** the panel follows the row-by-row spec in `addons/gdit_graph/design/sidepanel/` (visual mock at `design/Sidepanel.png`): "Source Control" header with Pull / Fetch / Push / Refresh toolbar + ⋯ all-git-actions menu (remotes, stage/unstage all, recall last message, sign-off and debug-log toggles, .gitignore), commit message field (Ctrl+Enter to commit, Ctrl+Down for history) with full-width accent Commit button and a ▾ options menu (Commit, Commit (Amend), Commit & Push, Commit & Stage), collapsible Staged Changes section first (Unstage All + count badge, "No staged changes" empty state), an HSeparator, then Changes (Stage All + count badge, "No changes" empty state). File rows show icon + file name, muted directory, and a right-aligned status letter (`?` displays as `U`); full repo-relative paths are stored as row metadata, never parsed back from display text. A wrapping status/error row sits above the status bar; only the branch lives in the status bar. Clicking the branch label opens the branch switcher popup (search branches/tags, create-and-checkout with spaces auto-dashed and other illegal chars warned, create-from-source, detach HEAD — see `addons/gdit_graph/design/sidepanel/branches.md`). Push moved to the header toolbar, .gitignore editing to the ⋯ menu, and Init Git to its own empty-state row.

## Git Graph Tab Plan

The Git Graph VSCode extension features are documented in `docs/git-graph-tab-plan.md`. This covers adding a visual commit graph tab next to "Asset Store", with: graph rendering, branch/tag/stash/remote management, commit details/diff, comparison view, find widget, code review, and all configurable settings. The plan specifies 25+ new `GitManager` commands, file structure, implementation phases, and rendering approach.

## Godot Editor Plugin Patterns

- Plugins use `add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)` to add dock panels
- `get_undo_redo()` is passed to handlers that need undo/redo support
- `EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)` can disable a plugin
- Plugin reload is done via `PluginReload.reload_enabled_plugin.call_deferred()` — never on the same frame
