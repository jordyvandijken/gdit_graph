# Bottom rows (extra rows beyond the spec)

`[Init Git*]`
`[status / error message (wraps)]`
`[branch]`

- `InitButton` (**Init Git**, `size_flags_horizontal` expand): lives in its
  own empty-state row, never in the status bar. It is the only control
  visible when the project is not a repo (hidden entirely when git is
  missing, and hidden once the repo exists); runs `init_repo()`, then
  re-checks and reveals the panel (`_set_empty_visible()`).
- `StatusLabel`: `Ready` / op progress (`Pulling...`, `Fetching...`,
  `Pushing...`, `Discarding...`) / green success / red error. It sits in its
  own full-width row **above** the branch row with word-smart autowrap, so
  long error messages fold instead of clipping when the panel is narrow.
- `BranchLabel`: current branch (`get_branch()`); `-` when not a repo. It is
  now the only thing in the `StatusBar` — Push moved to the header (row 1)
  and `.gitignore` to the ⋯ menu, so both remotes stay one click away
  without opening the ⋯ menu while the bottom stays clean.
- `IgnoreButton` was removed: `.gitignore` editing lives in the ⋯ menu
  (`Edit .gitignore`) and the `PopupPanel` editor itself is unchanged
  (created empty if missing; saving refreshes status).
