# Status bar (`StatusBar`, extra row beyond the spec)

`[branch] [status text] [spacer] [Init Git*] [Push] [.gitignore]`

- `BranchLabel`: current branch (`get_branch()`); `-` when not a repo.
- `StatusLabel`: `Ready` / op progress (`Pulling...`, `Fetching...`,
  `Pushing...`, `Discarding...`) / green success / red error.
- `InitButton` (**Init Git**): the only control visible when the project is
  not a repo (hidden entirely when git is missing); runs `init_repo()`, then
  re-checks and reveals the panel.
- `PushButton`: `_on_push()` — same no-remote guard and disable-during-op
  pattern as the header Pull/Fetch buttons.
- `IgnoreButton` (`.gitignore`): opens the in-panel `PopupPanel` editor for
  `res://.gitignore` (created empty if missing); saving refreshes status.
- Pull lives in the header (row 1); Push stays here, so both remotes remain
  one click away without opening the ⋯ menu.
