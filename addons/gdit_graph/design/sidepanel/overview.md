# Version Control side panel — overview

**This is a Godot editor plugin**, not a game. It combines the
"normal commit" workflow from VSCode's Source Control panel with
the visual commit graph from the Git Graph VSCode extension,
producing a Godot dock panel that stages, commits, and pushes
files with the same ease as VSCode.

The panel (`addons/gdit_graph/gdit_graph_panel.gd`, a root
`VBoxContainer`) implements the row-by-row spec below: one spec
line is one visible row, and a row can hold multiple controls.
Visual mock: `../Sidepanel.png`.

| Spec row | UI container | Doc |
|---|---|---|
| 1. `Changes (label), pull, fetch, refresh, contextmenu` | `HeaderBar` (+ `GitActionsMenu`) | `header.md` |
| 2. `git message (input field)` | `CommitBox` / `CommitMessage` | `commit.md` |
| 3. `commit (button), contextmenu (Commit, Amend, ...)` | `CommitBox` / `CommitRow` | `commit.md` |
| 4. `Staged Changes (label), Unstage all, [count]` | `StagedHeader` | `staged.md` |
| 5. `[listed items] OR No staged changes` | `StagedTree` / `StagedEmptyLabel` | `staged.md` |
| 6. `Changes (label), Stage all, [count]` | `ChangesHeader` | `changes.md` |
| 7. `[listed items] OR No changes` | `UnstagedTree` / `ChangesEmptyLabel` | `changes.md` |
| — (extra) bottom rows | `InitButton` + `StatusLabel` (wraps) + `StatusBar` (branch only) | `statusbar.md` |

## Resolved spec discrepancies

- Row 1 says `Changes (label)` for the header, but the mock
  (`../Sidepanel.png`) titles the header **Source Control**, and there is
  already a `Changes` section (row 6). The header keeps `Source Control` so
  the panel does not show two identical labels.
- The spec has no status bar; the implementation keeps one
  (branch, status/error message, Init Git — see `statusbar.md`).
- Extras beyond the spec: debug-log toggle + collapsible log, commit-message
  history (⋯ menu recall + `Ctrl+Down` in the message box), Amend (commit ▾
  menu) and Sign off (⋯ menu check item), hover pills, the discard flow,
  and the `.gitignore` editor. Each is documented in its section file.
- An `HSeparator` divides the staged and changes sections. The message and
  branch rows stay pinned at the bottom: both file trees expand to absorb
  spare vertical space.

## Global behaviors

- Repo gating: every row except the status bar's branch/status labels is
  hidden until `GitManager.is_repo()`; a non-repo shows only **Init Git**.
  When git itself is missing, even that is hidden.
- Dirty badge: the dock tab renames to `Version Control (*)` while staged or
  unstaged files exist, back to `Version Control` when clean.
- All git work runs on a worker thread via `GitManager`; UI updates arrive
  through the `status_changed` / `operation_complete` signals — never touch
  UI from the thread.
