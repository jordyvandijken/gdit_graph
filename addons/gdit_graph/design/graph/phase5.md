# Git Graph tab — Phase 5 polish

Column visibility toggles, resizable lanes, graph style options,
accessibility mode, hide/show context retention, tab icon theming, custom
branch glob patterns, and pull-request provider integration (plan items
25–32). No new git commands: PR links derive locally from the cached
remote URLs, and the open-PR list uses the provider REST API over a panel
`HTTPRequest` (browser-first, works offline for everything except the list
itself).

## Files

| File | Role |
|---|---|
| `workpanel/settings_dialog.gd` (+ Phase 5) | New keys: `show_hash`, `show_refs`, `lane_width`, `line_style`, `node_shape`, `color_scheme`, `accessibility_mode`, `tab_icon_theme`, `branch_glob`, `pr_provider`, `pr_remote`. New sections: Columns, Layout, Graph style, Accessibility, Branch filter, Tab icon, Pull requests. Dialog body lives in a `ScrollContainer` (400×420) since the form outgrew a fixed box; `read_settings` resolves `DialogScroll/DialogBox` with a `DialogBox` fallback |
| `workpanel/graph_renderer.gd` (+ Phase 5) | Column gates (`show_hash`, `show_refs`), `lane_width` var (replaces `const LANE_W`; `ROW_H` stays const — the only externally referenced constant), `line_style` / `node_shape` / `color_scheme` rendering, `accessibility_mode` outlines + text tags, gutter-edge drag resize (`lane_width_changed` signal, `CURSOR_HSIZE` hover, grip affordance) |
| `workpanel/graph_panel.gd` (+ Phase 5) | Glob field in the filter row, `_save_context` / `_restore_context` (+ `_consume_saved_context_after_load` for the reload-while-hidden path), PR overflow submenu + background fetch (`pr_http`), `_on_lane_width_changed` persistence, `_apply_settings` fans out to glob sync + filter rebuild + PR resolve/fetch |
| `workpanel/graph_utils.gd` (+ Phase 5) | `match_glob` / `match_any_glob` / `glob_to_regex`, `file_status_word`, `branch_color_for`, `parse_remote_url` (+ `_shape_remote_info`), `pr_list_url` / `pr_new_url` / `pr_api_url`, `parse_pr_entry` |
| `workpanel/commit_details.gd` (+ Phase 5) | `_accessibility_mode`: file rows append `[Status word]` and tooltips spell the status out; review dimming preserved |
| `plugin.gd` (+ Phase 5) | `_get_plugin_icon` recolors the white SVG glyph per `gdit_graph/tab_icon_theme` (`default` / `accent` / `branch` / `mono`); `branch` uses the synchronous `get_branch()` + `branch_color_for` |
| `workpanel/export_config.gd` | `EXPORT_VERSION` 2 (import stays version-tolerant; `apply_settings` backfills new keys) |

## Data flow

1. Columns/styles: settings ⚙ → rebuilt dialog → `confirmed` → `read_settings` → `save_settings` (ProjectSettings) → `_apply_settings` (renderer + details + glob/filter + avatars + PR) — same Phase 4 path, wider payload
2. Resize: drag gutter edge → renderer `set_lane_width` live → release emits `lane_width_changed` → panel clamps + `save_settings` (survives restart, no dialog needed)
3. Globs: keystroke in filter-row field → `_settings["branch_glob"]` saved → `_rebuild_branch_filter` (previous selection kept when still listed, else fall back to All + clear `_current_rev`)
4. Context: tab hide → `_save_context` (scroll, selection hash, details hash/path, collapse, rev, filter index, find, compare, stash nav) → tab show → restore in place, or `refresh()` + `_consume_saved_context_after_load` reselects/scrolls once the page lands (HEAD jump suppressed on restore)
5. PRs: `refresh()` → `graph_remotes` → `_resolve_pr_info` → `_maybe_fetch_prs` (github/gitlab/bitbucket REST, 15–20 max) → overflow "Pull requests" submenu lists cached entries; list/new/copy actions are pure `OS.shell_open` / clipboard URL builds, no network
6. Icon: editor queries `_get_plugin_icon` → theme color → SVG fill swap → `Image.load_svg_from_string` → `ImageTexture`; stock icon on any failure

## Git commands

None new. PR pages are URL builds from the Phase 3 remote cache:

- List: `<web>/pulls` (github), `<web>/-/merge_requests` (gitlab), `<web>/pull-requests/` (bitbucket)
- New: `<web>/compare/<base>...<head>?expand=1` (github), `<web>/-/merge_requests/new?merge_request[source_branch]=<head>` (gitlab), `<web>/pull-requests/new?source=<head>` (bitbucket)
- API: `api.github.com/repos/<path>/pulls?state=open`, `https://<host>/api/v4/projects/<encoded-path>/merge_requests?state=opened`, `api.bitbucket.org/2.0/repositories/<path>/pullrequests?state=OPEN`

## Safety rules

- Renderer hover only toggles the resize grip redraw on state change (no per-motion full redraws beyond the drag itself)
- Overflow id space: PR entries live at `OV_PR_BASE + i` (`i < OV_PR_CAP`); the remote-prune fallthrough is bounded above by `OV_PR_OPEN` so the ranges never collide
- PR fetch never touches the busy flag or the worker thread (like avatars); failures clear to an empty list with a disabled "No open PRs found" note, never an error popup
- Context restore never emits `commit_selected` (no details churn); comparison re-open reuses `_open_compare` so its stale guards keep working
- Icon recolor replaces only the white glyph fills (`#FFF` variants); carriers keep theirs. Any load/parse failure returns the stock icon
- Glob `[...]` passthrough keeps regex classes working; a bad pattern falls back to literal equality (never hides everything by accident)

## Deliberate Phase 5 limits

- No column reorder and no per-column pixel widths beyond the lane gutter (subject/author/date share the remaining row width, trimmed to fit as before)
- No GPG signature display and no PR write actions (merge/approve stay in the browser)
- No stored API tokens: the open-PR list covers public endpoints; private repos still get one-click list/new/copy links
- Tab icon applies when the editor (re)queries it — there is no editor API to force-refresh a main-screen icon live
