# Git Graph tab — overview (Phase 1 MVP + Phase 2 details/actions)

Top-row main-screen tab next to "Asset Store" (kanban_tasks pattern), named
**Git Graph**. Shows the commit history as a lane-based graph with
branch/tag chips, author/date text, click-to-select, hover tooltips, branch
filter, refresh/fetch, Load more pagination, and scroll-to-HEAD on load.
Clicking a row opens the expandable **Commit Details** section (files +
inline diff, open/copy actions); right-click offers checkout / merge /
reset-to-here / copy. "Version Control" (staging/commit UI) stays a
right-side dock panel; both surfaces are provided by the single `plugin.gd`
(one `plugin.cfg`).

## Files

| File | Role |
|---|---|
| `plugin.gd` | Registers the "Version Control" dock AND the "Git Graph" main screen (`_has_main_screen`, `_make_visible`, `_get_plugin_name/_get_plugin_icon`, same icon); owns both managers |
| `workpanel/graph_manager.gd` | Extends `GitManager`: `get_log`, `get_branches`, `get_tags`, `get_refs`, `get_head` (+ `log_loaded`, `branches_loaded`, `tags_loaded`, `refs_loaded`, `head_loaded` signals); Phase 2: `get_commit_details`, `get_commit_diff`, `checkout_ref`, `merge_ref`, `reset_ref` |
| `workpanel/graph_utils.gd` | Pure parsers + `assign_lanes` layout; no git, no UI. Phase 2: commit-details / name-status / diff helpers |
| `workpanel/graph_renderer.gd` | `Control` with manual `_draw()` (one row per commit). Phase 2: right-click `commit_context_requested` |
| `workpanel/graph_panel.gd` + `graph_panel.tscn` | Main-screen content: toolbar (mirrors the VSCode Git Graph toolbar), branch filter, scroll canvas, pager, status row. Phase 2: details section, context menu wiring, checkout/merge/reset actions |
| `workpanel/commit_details.gd` | Phase 2 details view (header, file list, diff host, open/copy) — see `commit_details.md` |
| `workpanel/commit_diff.gd` | Phase 2 inline diff renderer — see `commit_details.md` |
| `workpanel/branch_menu.gd` | Phase 2 commit context menu — see `commit_details.md` |

## Deliberate deviations from `docs/git-graph-tab-plan.md`

- **Main-screen tab, not a dock.** The plan's Option A put the graph in a
  dock; it now lives in the top row via `_has_main_screen` (kanban_tasks
  pattern), which suits a full-width graph better.

- **Structured log format, not `--graph` ASCII parsing.** `get_log` uses
  `--pretty=format:` with 0x1F/0x1E separators (same data: hash, parents,
  refs, subject, author, date); `assign_lanes` derives visual columns from
  parent links. Avoids fragile ASCII-art parsing.
- **Option A registration, single addon.** One `plugin.cfg`; the graph tab gets its own
  `GraphManager` instance so worker-thread state is never shared with the
  Source Control panel.
- **Find, settings, comparison are Phase 4.** See `phase4.md` for the
  find widget, comparison view, review tracking, settings, shortcuts,
  avatars, markdown/emoji, and config export.

## Global behaviors

- Repo gating: non-repos show a centered inline empty state ("Not a Git
  repository.", toolbar stays for Refresh); git init stays on the Source
  Control dock tab.
- All git work on the worker thread via `_run_git`; UI only via signals.
- New files use no `class_name`; `@tool` panel/renderer fields stay untyped.
