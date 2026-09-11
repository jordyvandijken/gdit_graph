# Rows 6–7 — Changes (`ChangesHeader`, `UnstagedTree`)

Header: `[▾/▸ toggle] [Changes title] [Stage All] [count badge]`.

- **Stage All** (`stage_all_button`, the spec's row-6 button):
  `_on_stage_all()` → `git add`; disabled when nothing is unstaged.
- Count badge (`changes_badge`, pill): number of unstaged files.
- Rows (same 3-column format as staged): icon + file name | muted directory
  | right-aligned status letter showing the **worktree** code (` M` → `M`);
  `??` displays as `U`.
- Empty state (`changes_empty_label`): `No changes` replaces the tree when
  the list is empty (spec row 7).
- Interactions: double-click stages (`_on_stage`); hover paints **Stage** /
  **Discard** pills (`_changes_overlay`); right-click menu (`changes_menu`):
  Open File, Stage Changes, Discard Changes.
- Discard (`_ask_discard_changes` → `discard_dialog` → tracked
  `git restore --source=HEAD --staged --worktree`, untracked `git clean -fd`):
  untracked deletes only accept safe repo-relative paths
  (`_is_safe_repo_relative`); open editor tabs are reloaded and rescanned
  afterwards (`_reload_editor_after_disk_change`).
