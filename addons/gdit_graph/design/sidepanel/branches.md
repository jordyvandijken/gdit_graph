# Branch switcher (`BranchPopup`)

Opened by clicking the branch label in the status bar (`statusbar.md`):
a floating picker to check out or create branches and tags without leaving
the side panel. Implementation: `sidepanel/branch_popup.gd` (the popup,
no git calls) + new `GitManager` ops + pure helpers in
`sidepanel/gdit_graph_panel_utils.gd`.

Popup layout (top to bottom):

- Search field (`BranchSearch`): one field filters the Local branches,
  Remote branches, and Tags sections below (case-insensitive substring).
  It doubles as the new-branch name: whatever is typed is the creation
  candidate.
- Hint row (`BranchHint`): inline create guidance —
  - empty search: idle hint ("Type to filter, or type a new branch name
    (spaces become dashes)."), creation disabled;
  - spaces typed: auto-dashed preview (`Create as "my-branch".`);
  - anything else illegal (`~ ^ : ? * [ \`, `..`, `@{`, leading
    `-`/`.`/`/`, trailing `/`/`.lock`): red reason, creation disabled —
    warned, never silently mangled;
  - name already exists locally: amber note pointing at the row to check
    out instead, creation disabled.
- `Create new branch`: `git checkout -b <sanitized>` (HEAD), then checks
  out the new branch in the same step.
- `Create new branch from...`: flips the popup into source-picking mode —
  same search and lists, new title (`Create "x" from...`), action buttons
  replaced by Back. Picking a row runs
  `git checkout -b <sanitized> <source>` for that branch/tag.
- `Checkout detached HEAD`: `git checkout --detach` (worktree kept, no
  branch moved).
- Sections with counts: Local branches, Remote branches (short
  `origin/main` form), Tags. The current ref shows `(current)` and is
  disabled. Each section caps at 50 rows (`+N more — keep typing...`).

Behavior notes:

- `GitManager.list_branches()` (`git branch --no-color -a`) and
  `list_tags()` (`git tag -l`) run on the worker thread; results arrive via
  `operation_complete` carrying raw text, parsed by `SidepanelUtils`
  (`parse_branch_list` / `parse_tag_list`). The popup opens once both land.
- Remote rows check out via `git checkout --track <remote>` so a local
  tracking branch is created; when the local branch already exists git
  fails ("already exists") and the panel falls back to a plain checkout.
- Checkout / create / detach rewrite the worktree, so success reloads open
  editor tabs (`_reload_editor_after_disk_change()`), updates the branch
  label (`_check_git()`), and refreshes status — same disk-change contract
  as pull/revert. Refusals (local changes would be overwritten) surface as
  red errors; nothing is lost.
