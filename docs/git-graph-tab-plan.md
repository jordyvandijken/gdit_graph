# Git Graph Tab Plan

## Context

The current `addons/gdit_graph/` plugin implements the **"Source Control"** dock panel (VSCode's SCM panel equivalent) — staging, committing, pushing, pulling, branch display, .gitignore editing. The **Git Graph VSCode extension** (`mhutchie/git-graph`, 15M+ installs) provides a separate visual commit graph view. This plan covers adding that graph view as a **new tab** in the Godot editor, positioned next to the built-in "Asset Store" tab.

---

## I. New Git Manager Commands Required

The current `git_manager.gd` has ~14 commands. The graph tab needs these **additional** `GitManager` methods (all worker-thread via `_run_git`):

| Command | Git CLI | Purpose |
|---|---|---|
| `get_log(limit, offset)` | `git log --oneline --graph --all --decorate -n <limit> --skip <offset>` | Core graph data |
| `get_branches(include_remote)` | `git branch -a` or `git branch -r` | Branch list |
| `get_tags()` | `git tag -l` | Tag list |
| `get_stashes()` | `git stash list` | Stash list |
| `get_remotes()` | `git remote -v` | Remote URLs |
| `get_commit_details(hash)` | `git show --stat --format=fuller <hash>` | Commit metadata + file stats |
| `get_commit_diff(hash, path)` | `git show <hash> -- <path>` | File diff |
| `get_refs()` | `git for-each-ref --format=...` | All refs (heads, tags, remotes) |
| `checkout_ref(ref)` | `git checkout <ref>` or `git switch <ref>` | Switch branch/tag |
| `create_branch(name, target)` | `git branch <name> <target>` | Create branch |
| `delete_branch(name)` | `git branch -d <name>` | Delete branch |
| `rename_branch(old, new)` | `git branch -m <old> <new>` | Rename branch |
| `merge_ref(ref)` | `git merge <ref>` | Merge |
| `rebase_ref(ref)` | `git rebase <ref>` | Rebase |
| `cherry_pick(hash)` | `git cherry-pick <hash>` | Cherry-pick |
| `reset_ref(hash, mode)` | `git reset --<mode> <hash>` | Reset (soft/mixed/hard) |
| `stash_push(msg)` | `git stash push -m <msg>` | Stash |
| `stash_pop(index)` | `git stash pop <index>` | Pop stash |
| `stash_drop(index)` | `git stash drop <index>` | Drop stash |
| `create_tag(name, target, annotated)` | `git tag -a <name> <target> -m ""` | Create tag |
| `delete_tag(name)` | `git tag -d <name>` | Delete tag |
| `push_ref(ref, remote)` | `git push <remote> <ref>` | Push specific ref |
| `fetch_ref(remote, ref)` | `git fetch <remote> <ref>` | Fetch specific ref |
| `get_merge_base(a, b)` | `git merge-base <a> <b>` | For comparison |
| `get_reflog()` | `git reflog` | Reflog for commits only in reflogs |

All new methods follow the existing worker-thread pattern: `_run_git` → `_execute_git` → `callback.call_deferred`. New signals: `log_loaded(nodes)`, `branches_loaded(branches)`, `tags_loaded(tags)`, etc.

---

## II. Graph Tab UI Layout

| Row | UI Element | Description |
|---|---|---|
| 1 | **Toolbar bar** | Title ("Git Graph"), Fetch button, Refresh button, Find widget button (Ctrl+F), Settings button, Branch filter dropdown, Show/hide toggles (branches/tags/stashes/remotes), Column visibility toggles (Date/Author/Commit), Tab icon color theme selector |
| 2 | **Commit Graph** | Custom 2D canvas or Tree-based visualization rendering commit nodes as vertices connected by lines, colored by branch. Each node shows abbreviated hash, message, author, date. Branch labels and tag labels anchored to commits. Uncommitted changes shown as a special node. |
| 3 | **Commit Details Panel** (expandable) | Clicking a commit opens this: list of changed files with status (A/M/D/R/U), file diff viewer, commit message, author, date, hash. "Open File" and "Copy Path" actions. HTTP link click support. |
| 4 | **Commit Comparison View** | Ctrl/Cmd+click two commits to compare. Shows diff between them. |
| 5 | **Right-click Context Menu** | Branch actions (create, checkout, delete, rename, reset, merge, rebase, pull, push, fetch), Commit actions (cherry-pick, revert, checkout, reset), Tag actions (add, delete, push), Stash actions (apply, pop, drop), Copy hash/name |
| 6 | **Status/Error Bar** | Operation status messages, branch indicator |
| 7 | **Keyboard Shortcuts** | Ctrl+F: Find, Ctrl+H: Scroll to HEAD, Ctrl+R: Refresh, Ctrl+S / Ctrl+Shift+S: Navigate stashes, Up/Down: Navigate commit details, Enter: Submit dialog, Escape: Close |

---

## III. Feature Breakdown

### A. Git Graph View (Core)

- **Commit rendering**: Parse `git log --oneline --graph --all --decorate` output into node/edge data
- **Branch rendering**: Parse `git branch -a` to get branch names and their tip commits; draw colored lines from branch tips
- **Tag rendering**: Parse `git tag -l` to anchor tag labels
- **Remote tracking**: Parse `git branch -r` for remote branches; option to show/hide
- **Stash rendering**: Parse `git stash list` for stash nodes
- **Uncommitted changes node**: Special node derived from `git status --porcelain`
- **Color coding**: Each branch gets a distinct color; commits inherit branch color; merge commits distinguished
- **Muted commits**: Commits not ancestors of HEAD shown in muted color
- **Merge commit visual**: Different styling for merge commits
- **Hover tooltip**: Shows branches/tags/stashes containing the commit
- **Load more**: Pagination via `--skip` / configurable initial load count
- **Auto-scroll to HEAD**: On load, scroll to current branch tip
- **Resize columns**: Width adjustable for each column
- **Show/hide columns**: Date, Author, Commit message toggle-able
- **Graph style config**: Line style, node shape, color scheme

### B. Commit Details View

- **File list**: Parse `git show --stat` for changed files
- **Diff view**: Parse `git show <hash> -- <path>` for file-level diffs (inline, not side-by-side given Godot's limitations)
- **Open file**: Navigate to file in Godot editor
- **Copy path**: Copy file path to clipboard
- **HTTP links**: Open URLs in default browser
- **Code review tracking**: Bold files needing review; track reviewed state (persist in project settings)

### C. Commit Comparison View

- **Two-commit selection**: Ctrl/Cmd+click to select two commits
- **Diff between commits**: Parse `git diff <commit1> <commit2> -- <path>`
- **File tree**: Show all changed files between the two commits
- **Open file / Copy path**: Same as commit details

### D. Branch Management

- **List branches**: Local + remote with current branch indicator
- **Checkout**: Switch to branch/tag
- **Create**: New branch from selected commit or current HEAD
- **Delete**: Safe delete (refuse if current branch)
- **Rename**: Rename local branch
- **Merge**: Merge branch into current
- **Rebase**: Rebase onto branch
- **Pull/Push**: Fetch/pull/push from branch context
- **Reset**: Soft/mixed/hard reset to commit
- **Filter dropdown**: Show all / select branches / custom glob patterns

### E. Tag Management

- **List tags**: `git tag -l`
- **Create annotated tag**: From selected commit
- **Delete tag**: Local + remote push option
- **Push tag**: `git push origin <tag>`

### F. Stash Management

- **List stashes**: `git stash list`
- **Apply/Pop**: Apply or pop a stash
- **Drop**: Remove a stash
- **Stash creation**: `git stash push -m <msg>`

### G. Remote Management

- **List remotes**: `git remote -v`
- **Add/Remove/Edit**: Repository settings widget
- **Fetch/Prune**: Fetch from remote with prune option
- **Fetch and prune tags**: Clean stale tags

### H. Find Widget

- **Search**: Commit message, author, hash, branch/tag names
- **Navigate**: Jump to matching commit in graph

### I. Settings / Configuration

- **Graph style**: Line style, branch colors, node appearance
- **Date format**: Customizable date display format
- **Date type**: Author date vs commit date
- **Commit order**: Standard, topological, etc.
- **Initial load count**: Number of commits loaded on open
- **Load more automatically**: Auto-load when scrolled to bottom
- **Show remote branches/heads/tags/stashes**: Toggle visibility
- **Only follow first parent**: `--first-parent` option
- **Include reflog commits**: Show commits only in reflogs
- **Show uncommitted changes**: Toggle uncommitted node
- **Show untracked files**: In uncommitted changes
- **Avatar fetching**: Commit author avatars (could use GitHub API)
- **Mailmap support**: Respect `.mailmap` files
- **Markdown rendering**: In commit messages and tag details
- **Emoji shortcodes**: Auto-replace common emoji shortcodes
- **Signature status**: Show GPG signature status
- **Retain context when hidden**: Performance optimization
- **Tab icon color theme**: Color of tab icon
- **Integrated terminal shell**: Path to shell for terminal operations
- **Enhanced accessibility**: A|M|D|R|U indicators for color-blind users
- **Custom branch glob patterns**: User-defined branch filters
- **Custom pull request providers**: PR creation integration
- **Export repository configuration**: Commit config file to repo
- **Context menu actions visibility**: Customize which actions appear
- **Default column visibility**: Configurable Date/Author/Commit defaults
- **File encoding**: Character set for diff retrieval
- **Source code provider integration location**: Where "View Git Graph" action appears

### J. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Ctrl/CMD+F | Open Find Widget |
| Ctrl/CMD+H | Scroll to HEAD |
| Ctrl/CMD+R | Refresh |
| Ctrl/CMD+S | Scroll to next stash |
| Ctrl/CMD+Shift+S | Scroll to previous stash |
| Up/Down (in details) | Navigate to adjacent commit |
| Ctrl/CMD+Up/Down | Navigate to parent/child on same branch |
| Enter | Submit dialog |
| Escape | Close dialog/menu |

---

## IV. Architecture Plan

### Files to Add

```
addons/gdit_graph/
├── graph/                          # New graph tab subsystem
│   ├── graph_manager.gd            # Extends GitManager: log/branch/tag/stash/remote commands
│   ├── graph_node.gd               # Commit node data structure
│   ├── graph_renderer.gd           # 2D canvas rendering of the commit graph
│   ├── graph_panel.gd              # The dock panel (extends Control, the new tab)
│   ├── graph_plugin.gd             # EditorPlugin that registers the new tab
│   ├── commit_details.gd           # Commit details view panel
│   ├── commit_diff.gd              # Diff rendering for a single file
│   ├── comparison_view.gd          # Two-commit comparison view
│   ├── branch_menu.gd              # Branch context menu + management
│   ├── tag_manager.gd              # Tag listing/creation/deletion
│   ├── stash_manager.gd            # Stash listing/apply/pop/drop
│   ├── remote_manager.gd           # Remote listing/add/remove/fetch
│   ├── find_widget.gd              # Commit search widget
│   ├── settings_dialog.gd          # Graph configuration dialog
│   ├── code_review.gd              # Code review tracking
│   ├── graph_theme.gd              # Color/style configuration
│   └── graph_utils.gd              # Shared utilities (parse log output, etc.)
├── design/
│   ├── graph/                      # New design docs
│   │   ├── graph.md                # Overview spec
│   │   ├── graph_node.md           # Node rendering spec
│   │   ├── commit_details.md       # Details view spec
│   │   ├── branch_menu.md          # Branch actions spec
│   │   ├── settings.md             # Settings spec
│   │   └── renderer.md             # Rendering engine spec
│   └── (existing docs remain)
└── (existing files remain unchanged)
```

### Plugin Registration

**Option A**: Extend existing `gdit_graph/plugin.gd` — add a second dock panel via `add_control_to_dock()` at a different slot or the same slot with a different panel.

**Option B**: New `addons/gdit_graph_graph/plugin.gd` — separate `EditorPlugin` that adds the graph tab alongside the existing "Version Control" panel.

The dock panel name must be `"Git Graph"`. Use `add_control_to_dock(DOCK_SLOT_RIGHT_BL, panel)` to match the existing panel's dock area. The panel sits next to the built-in "Asset Store" tab in the Godot editor dock region.

### GitManager Extension

Two approaches:
1. **Extend `git_manager.gd`** directly — add all new methods to the existing class
2. **Create `graph_manager.gd`** that extends `GitManager` — cleaner separation, only loads graph-specific commands when the tab is open

**Recommended**: Option 2, since it avoids loading unnecessary git commands when only the Source Control panel is used.

### Graph Rendering Approach

Godot 4.7 `CanvasItem` / `Control` based custom rendering:

- **Option 1**: `Control` with manual `_draw()` calls for nodes and edges — lightweight, most control, recommended
- **Option 2**: `GraphEdit` node (Godot's built-in visual graph node) — designed for node graphs, may not fit commit graph semantics perfectly
- **Option 3**: `Tree` with custom drawing — limited for visual graph layout

**Recommended**: Custom `Control` subclass with `_draw()`, caching rendered graph to a `Texture2D` when possible to avoid re-rendering every frame.

### Thread Safety

All git operations must stay on worker threads via the existing `GitManager._run_git()` pattern. UI updates arrive through signals (`status_changed`, `operation_complete`, and new signals like `log_loaded`). **Never touch UI from the worker thread.**

---

## V. Implementation Priority

### Phase 1 — Core Graph (MVP)

1. `graph_manager.gd`: `get_log`, `get_branches`, `get_tags`, `get_refs`
2. `graph_renderer.gd`: Basic commit node rendering with `_draw()`, branch lines, color coding
3. `graph_panel.gd`: Dock panel with graph canvas, branch filter dropdown, refresh button, toolbar
4. Basic click-to-select, hover tooltip
5. Scroll to HEAD on load
6. `graph_plugin.gd`: Register as new dock tab

### Phase 2 — Commit Details & Actions

7. `commit_details.gd`: File list, diff view, open file
8. Right-click context menu on commits
9. `checkout`, `reset`, `merge` actions
10. `commit_diff.gd`: File-level diff rendering

### Phase 3 — Branch/Tag/Stash/Remote Management

11. Branch create/delete/rename/checkout
12. Tag create/delete
13. Stash list/apply/pop/drop
14. Remote list/fetch/prune
15. Pull/Push from graph context

### Phase 4 — Advanced Features

16. Find widget (Ctrl+F search)
17. Commit comparison view (Ctrl+click)
18. Code review tracking
19. Settings dialog (all configurable options)
20. Keyboard shortcuts
21. Load more commits pagination
22. Avatar fetching
23. Markdown/Emoji rendering in commit messages
24. Export repository configuration

### Phase 5 — Polish

25. Column visibility toggles
26. Resizable columns
27. Graph style options
28. Accessibility features
29. Retain context when hidden
30. Tab icon color theming
31. Custom branch glob patterns
32. Pull request provider integration

---

## VI. What Currently Exists vs What's Missing

| Feature | Current `gdit_graph` | Git Graph Tab Needs |
|---|---|---|
| `git log` | ✗ | **NEW** |
| Branch visualization | ✗ (just branch name) | **NEW** |
| Tag visualization | ✗ | **NEW** |
| Stash visualization | ✗ | **NEW** |
| Remote visualization | ✗ (just has_remote check) | **NEW** |
| Commit graph rendering | ✗ | **NEW** |
| Commit details/diff | ✗ | **NEW** |
| Branch operations | ✗ | **NEW** |
| Tag operations | ✗ | **NEW** |
| Stash operations | ✗ | **NEW** |
| Cherry-pick | ✓ | Implemented (`cherry_pick` + context menu) |
| Rebase | ✓ | Implemented (`rebase_ref` + context menu, confirm first) |
| Reset | ✗ | **NEW** |
| Find/search commits | ✗ | **NEW** |
| Code review | ✗ | **NEW** |
| Pull/Push | ✓ | Already exists |
| Fetch | ✓ | Already exists |
| Stage/Commit/Unstage | ✓ | Already exists |
| Discard | ✓ | Already exists |
| .gitignore | ✓ | Already exists |
| Branch name display | ✓ (label only) | Already exists |
| Refresh | ✓ | Already exists |

---

## VII. Key Technical Considerations

- **All git operations** must stay on worker threads via `GitManager._run_git()` pattern — never touch UI from worker thread
- **Graph rendering** must handle potentially thousands of commits; implement viewport culling and lazy rendering
- **Godot's `_draw()`** is immediate-mode; cache rendered graph to a `Texture2D` when possible to avoid re-rendering every frame
- **Dock panel** must use `add_control_to_dock()` with the correct slot constant; the panel name should be `"Git Graph"` to match VSCode
- **Settings persistence**: Use `ProjectSettings` or a `.tres` resource for graph configuration
- **Code review persistence**: Store review state in `user://` or project settings
- **Diff rendering**: Godot doesn't have a built-in diff viewer; implement unified diff parsing and inline rendering in a `TextEdit` or custom `Control`
- **Commit graph data**: Parse `git log --oneline --graph --all --decorate` text output into structured node/edge data; this is the most complex parsing task in the entire plan
- **Performance**: For large repos, implement commit count limits and lazy loading; consider `git rev-list --count` to know total commit count before loading
- **Godot 4.7 compatibility**: All code must target Godot 4.7+ APIs; no Godot 3.x compatibility code
