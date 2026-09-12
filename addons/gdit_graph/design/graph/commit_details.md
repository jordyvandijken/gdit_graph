# Git Graph tab — commit details + context actions (Phase 2)

Inline panel of the "Git Graph" main-screen tab. Clicking a graph row
opens it between that row and the next: the renderer reserves a gap and
keeps drawing the branch lanes through it on the left, while the detail
card fills the remaining columns. The panel auto-sizes to the loaded
content, stays open until another commit is clicked, and scrolls with
the rows. Clicking the open row again closes it (× button or Escape
work too). Right-clicking a row selects it AND opens the context menu
(right-clicking the open row keeps it open).

## Files

| File | Role |
|---|---|
| `workpanel/graph_inline_detail.gd` | Inline wrapper (child of the renderer canvas): transparent lane gutter + detail card with title and close button. Embeds `commit_details.gd` and re-emits its signals; `desired_height()` auto-sizes to content |
| `workpanel/commit_details.gd` | Details view (pure view, no git): subject/meta/message header, file Tree (path + status letter), inline diff, Open File / Copy Path buttons. Emits `file_selected`, `open_file_requested`, `copy_path_requested`; the panel performs git + status |
| `workpanel/commit_diff.gd` | Inline unified-diff renderer (RichTextLabel): dim headers, green `+`, red `-`, cyan `@@`; 2000-line cap; truncation note comes from the manager text |
| `workpanel/branch_menu.gd` | Commit-scoped PopupMenu: checkout commit/branch, merge into current, reset-to-here submenu (soft/mixed/hard), copy hash/subject. Emits `*_requested` signals; the panel performs the git work and confirmations |
| `workpanel/graph_manager.gd` (+ Phase 2) | `get_commit_details`, `get_commit_diff`, `checkout_ref`, `merge_ref`, `reset_ref` (+ `commit_details_loaded`, `commit_diff_loaded` signals, `graph_details/graph_diff/graph_checkout/graph_merge/graph_reset` actions) |
| `workpanel/graph_utils.gd` (+ Phase 2) | `parse_commit_details`, `parse_name_status_line`, `truncate_diff`, `is_binary_diff`, `message_to_bbcode` |
| `workpanel/graph_renderer.gd` (+ Phase 2) | `commit_context_requested` on right-click (also selects the row so details follow) |

## Data flow

1. Row click → panel `show_commit(row)` (instant header) + `get_commit_details(hash)`
2. `commit_details_loaded` → `show_details()` (files, full message) → auto-selects first file → `file_selected(path)`
3. `file_selected` → `get_commit_diff(hash, path)` → `commit_diff_loaded` → `diff_view.set_diff()`
4. Stale guards: details replies are ignored when their hash != selected hash; diff replies when hash+path != selection
5. Details/diff loads never touch the busy flag (no toolbar flicker); only checkout/merge/reset set busy

## Git commands

- Details: `git show --name-status --first-parent -m --format=<9×0x1F fields><0x1E> <rev> --`
  (`-m --first-parent` keeps merge commits non-empty; same separator scheme as the log)
- Diff: `git show --format= --no-ext-diff --first-parent -m <rev> -- <path>`
  (empty format = pure diff; `--no-ext-diff` keeps external drivers off the worker thread; capped at 100k chars)
- `git checkout <ref>` (git refuses when worktree changes would be overwritten — surfaces as an error, nothing lost)
- `git merge --no-edit <ref>` (`--no-edit` avoids launching an editor on the worker thread)
- `git reset --<soft|mixed|hard> <hash>` (mode validated, never passed raw)

## Safety rules

- Hard reset asks via ConfirmationDialog (soft/mixed keep the worktree, no confirm)
- Checkout/merge/reset reload open script tabs + rescan the filesystem (mirrors the side panel)
- File rows store full repo-relative paths as Tree metadata, never parsed back from display text
- "Open File" opens the worktree state (may differ from the diff for old commits)
- Commit-message URLs become clickable links (`OS.shell_open`); `[` is escaped to `[lb]` before BBCode parsing

## Deliberate Phase 2 limits (later phases)

- Menu is commit-scoped: no create/delete/rename branch, no tags, no stash, no remotes (Phase 3)
- Two-commit comparison, find widget, settings, keyboard shortcuts, review tracking, markdown/emoji (Phase 4 — see `phase4.md`)
