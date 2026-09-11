# Row 1 — Header bar (`HeaderBar`)

`[Source Control title] [Pull] [Fetch] [Push] [Refresh] [⋯]`

- Title (`HeaderTitle`, expanding label): `Source Control`. Spec row 1 says
  `Changes (label)`; resolved in favor of the mock — see `overview.md`.
- **Pull** (`pull_button`): `_on_pull()` — refuses early with "no git remote
  configured" via the synchronous `has_remote()` check, disables the remote
  buttons, then `git_manager.pull()`.
- **Fetch** (`fetch_button`): `_on_fetch()` — same remote guard, then
  `git_manager.fetch()`.
- **Push** (`push_button`): `_on_push()` — same no-remote guard and
  disable-during-op pattern as Pull/Fetch.
- **Refresh** (`RefreshButton`): `_on_refresh()` → `_check_git()` +
  `refresh_status()`.
- **⋯ More git actions** (`git_actions_button` + `GitActionsMenu`): the
  spec's `contextmenu(button)(all git action)` — Pull (0), Fetch (1),
  Push (2), Stage All (3), Unstage All (4), Recall last commit message (5,
  disabled while history is empty), Sign off `--signoff` (6, check item),
  Debug log (7, check item), Edit .gitignore (8). Handled by
  `_on_git_action_selected()`, which delegates to the same handlers as the
  dedicated buttons; check states and the recall availability are synced on
  every popup in `_on_git_actions()`. The menu connects `id_pressed` (not
  `index_pressed`): separators shift item positions, so matching on position
  would misroute every item below a separator.
- **Debug log** lives only in the ⋯ menu (check item, extra beyond the
  spec): shows/hides the collapsible debug log (`LogBox`, ring buffer of
  the last 200 lines) via `_on_log_toggle()`.

Remote buttons (Pull/Fetch/Push) disable during pull/fetch/push via
`_set_remote_enabled()` and re-enable in `_on_operation_complete()`.
