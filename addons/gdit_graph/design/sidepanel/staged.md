# Rows 4–5 — Staged Changes (`StagedHeader`, `StagedTree`)

Header: `[▾/▸ toggle] [Staged Changes title] [Unstage All] [count badge]`.

- Collapse toggle (`staged_toggle`) flips `_staged_collapsed`;
  `_refresh_section_visibility()` hides the tree and the empty label together.
- **Unstage All** (`unstage_all_button`, the spec's row-4 button):
  `_on_unstage_all()` → `git restore --staged`; disabled when nothing is
  staged.
- Count badge (`staged_badge`, pill): number of staged files.
- Rows (`_make_file_tree`, 3 columns like the mock): icon + file name |
  muted directory | right-aligned status letter showing the **index** code
  (`AM` → `A`); `?` displays as `U`. The full repo-relative path is stored
  as row metadata, never parsed back from display text.
- Empty state (`staged_empty_label`): `No staged changes` replaces the tree
  when the list is empty (spec row 5).
- Interactions: double-click unstages (`_on_unstage`); hover paints an
  **Unstage** pill on an overlay child (`_staged_overlay`); right-click menu
  (`staged_menu`): Open File, Unstage Changes.
