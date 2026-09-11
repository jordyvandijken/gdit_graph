# Row 1 — Header bar (`HeaderBar`)

`[Source Control title] [Pull] [Fetch] [Refresh] [⋯] [≡]`

- Title (`HeaderTitle`, expanding label): `Source Control`. Spec row 1 says
  `Changes (label)`; resolved in favor of the mock — see `overview.md`.
- **Pull** (`pull_button`): `_on_pull()` — refuses early with "no git remote
  configured" via the synchronous `has_remote()` check, disables the remote
  buttons, then `git_manager.pull()`.
- **Fetch** (`fetch_button`): `_on_fetch()` — same remote guard, then
  `git_manager.fetch()`.
- **Refresh** (`RefreshButton`): `_on_refresh()` → `_check_git()` +
  `refresh_status()`.
- **⋯ More git actions** (`git_actions_button` + `GitActionsMenu`): the
  spec's `contextmenu(button)(all git action)` — Pull (0), Fetch (1),
  Push (2), Stage All (4), Unstage All (5), Edit .gitignore (7), handled by
  `_on_git_action_selected()`, which delegates to the same handlers as the
  dedicated buttons.
- **≡ Log toggle** (`log_toggle`, extra beyond the spec): shows/hides the
  collapsible debug log (`LogBox`, ring buffer of the last 200 lines).

Remote buttons (Pull/Fetch/Push) disable during pull/fetch/push via
`_set_remote_enabled()` and re-enable in `_on_operation_complete()`.
