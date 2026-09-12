# Git Graph tab — Phase 4 advanced features

Find widget, two-commit comparison, code review tracking, settings dialog,
keyboard shortcuts, auto-load pagination, avatars, markdown/emoji bodies,
and repository config export. Load-more pagination itself shipped earlier
(`Load more` button + `--skip` paging); Phase 4 adds the configurable page
size and the auto-load-at-bottom toggle around it.

## Files

| File | Role |
|---|---|
| `workpanel/find_widget.gd` | Toolbar search field (pure view): query field + scope dropdown (All/Message/Author/Hash/Branch/Tag), match counter, prev/next buttons, always visible between the title and Fetch. Emits `search_changed`, `navigate_prev/next` (buttons and keyboard Enter/Shift+Enter); Escape clears the query. No close button; the panel filters via `GraphUtils.filter_commit_indices` |
| `workpanel/comparison_view.gd` | A↔B comparison section (pure view): header with swap/close, file Tree, shared `commit_diff.gd` renderer. Emits `file_selected`, `open_file_requested`, `copy_path_requested`, `swap_requested`, `closed` |
| `workpanel/code_review.gd` | Review-state store (RefCounted statics): per-commit per-file marks in `ProjectSettings` key `gdit_graph/code_reviews` |
| `workpanel/settings_dialog.gd` | Settings factory + persistence (RefCounted statics, `graph_dialogs.gd` pattern): `load_settings`, `save_settings`, `apply_settings`, `make_settings_dialog`, `read_settings`. Only options the panel implements are exposed |
| `workpanel/avatar_manager.gd` | Avatar helpers (RefCounted statics): deterministic color + initials (offline default), Gravatar URL builder, `user://gdit_graph_avatars` PNG cache |
| `workpanel/export_config.gd` | Config export/import (RefCounted statics): JSON payload `{app, version, settings, extra}` at the repo-root `.gdit_graph.json` |
| `workpanel/graph_manager.gd` (+ Phase 4) | `LOG_FORMAT` gains author email (`%ae`); `get_comparison_files` (`git diff --name-status A B`), `get_comparison_diff` (`git diff A B -- path`); synchronous `rev_parse` for stash navigation; `comparison_files_loaded` / `comparison_diff_loaded` signals, `graph_compare_files` / `graph_compare_diff` actions |
| `workpanel/graph_utils.gd` (+ Phase 4) | `parse_log` accepts the 8-field shape (legacy 7-field tolerated); `message_to_bbcode_full` (markdown + emoji toggles), `markdown_to_bbcode`, `replace_emoji_shortcodes`, `match_commit` / `filter_commit_indices`, `parse_diff_name_status`, `format_graph_date` (iso/short/relative) |
| `workpanel/graph_renderer.gd` (+ Phase 4) | Ctrl+click pairs rows (`commit_compare_requested`), find-hit highlight (`set_search_hits`), avatar discs (`apply_settings`, `set_avatar_texture`), programmatic `select_index`, author/date/column toggles |
| `workpanel/commit_details.gd` (+ Phase 4) | Review marks (✓ + dim, `Mark Reviewed` button, double-click toggle, `review_toggled` signal, `Files (n, m to review)` title), settings-driven message rendering (`apply_settings`) |
| `workpanel/graph_panel.gd` (+ Phase 4) | Toolbar search/Settings buttons, comparison section, `_unhandled_key_input` shortcuts, stash cycling, settings apply, avatar prefetch queue, export/import overflow items, auto-load on `scroll_ended` |

## Data flow

1. Find: keystroke → `search_changed` → panel filters loaded commits → renderer highlights + scrolls to first hit (selection untouched, no git); Enter/Shift+Enter jumps, selects, and loads details like a click
2. Compare: Ctrl+click → `commit_compare_requested(A, B)` → panel orders older-first → `get_comparison_files` → file list → auto-select first → `get_comparison_diff` → inline diff; swap re-opens reversed; stale guards on (a, b, path)
3. Review: double-click / button → `code_review` store → row re-mark + title counts → `review_toggled` → status line
4. Settings: toolbar ⚙ → rebuilt dialog → `confirmed` → `read_settings` → `save_settings` (ProjectSettings) → `apply_settings` (renderer + details + avatar refresh); page size applies to the next load
5. Stash keys: Ctrl+S walks the cached stash list, resolves `stash@{n}` via synchronous `rev_parse`, and reuses `_on_commit_selected` so the details stale-guard keeps working
6. Avatars: log load → cached PNGs applied instantly → optional Gravatar queue (20 max, sequential HTTPRequest) → saved to `user://` → texture pushed to renderer
7. Export: overflow menu → settings + `{branch_filter, details_collapsed}` → repo-root `.gdit_graph.json`; import reverses it and refreshes

## Git commands

- Compare files: `git diff --name-status --no-ext-diff <A> <B> --`
- Compare diff: `git diff --no-ext-diff <A> <B> -- <path>` (100k-char cap via `truncate_diff`, same as single-commit diffs)
- Stash resolve: `git rev-parse --verify stash@{n}` (synchronous, `get_branch` precedent)
- Log: same structured `--pretty=format:` walk plus `%ae` for avatar lookup

## Safety rules

- Find never touches git; comparison diff/file loads never touch the busy flag (like details/diff)
- Comparison pair ordered older-first; swap is an explicit re-open, never an in-place mutation
- Review state is per project settings, keyed by full commit hash + repo-relative path
- Gravatar fetching is opt-in (default off); generated avatars work fully offline
- Export file is plain JSON, never committed automatically — the user decides
- Keyboard shortcuts ignore echo, require panel visibility, and Up/Down only fires when the canvas owns focus

## Deliberate Phase 4 limits (Phase 5 — see `phase5.md`, shipped)

- Find searches the loaded pages only, not the full history (server-side `git log --grep` is future work)
- Column toggles, lane resize, graph styles, accessibility, context retention, icon theming, branch globs, PR links: Phase 5 (see `phase5.md`)
- No GPG signature display
- Avatars are initials + Gravatar only (no GitHub API)
