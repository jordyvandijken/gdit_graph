# Git Graph

A version-control panel for the Godot editor. It combines a VSCode-style
Source Control commit workflow with a visual commit graph inspired by the
Git Graph VSCode extension.

The plugin provides a "Git" dock for staging, committing, and pushing files,
plus a "Git Graph" main-screen tab for browsing history, branches, tags,
stashes, diffs, and comparisons. It is written by jvd with AI assistance
and distributed under the MIT license.

## Features

- Source Control dock: staged and unstaged changes with counts, per-file
  stage, unstage, and discard actions, and commit with history, amend,
  commit-and-push, and commit-and-stage options.
- Commit message field with Ctrl+Enter to commit and Ctrl+Down for message
  history.
- Header toolbar with Pull, Fetch, Push, and Refresh, plus an actions menu
  for remotes, stage and unstage all, message recall, sign-off, debug log,
  and `.gitignore` editing.
- Branch switcher popup with search, create-and-checkout, create-from-source,
  and detach HEAD.
- Git Graph tab: commit lanes, commit details and diffs, cherry-pick, rebase,
  merge, reset, branch, tag, stash, reflog, find widget, comparison view,
  code reviews, pull-request links, avatars, and theming options.

## Requirements

- Godot 4.7 or newer in the 4.x line.
- The `git` command-line tool must be installed and available on PATH.
  The plugin shells out to `git` for every operation. When the open project
  is not a git repository, the panel shows an Init Git button instead of the
  commit UI. When `git` is missing, git features stay hidden.
- No other plugins or autoloads are required.

## Install

1. Download the asset and extract the `addons/` folder into your project
   folder, merging with any existing `addons/` folder.
2. Open Project > Project Settings > Plugins and enable "Git Graph".
3. Open a git-backed project to see the full panel. Use Init Git for a
   project that is not a repository yet.

## Notes

- Gravatar avatars are off by default and only fetch over the network when
  enabled in settings. Pull-request links open the provider website in a
  browser. No other network use is required.
- Settings are stored under `gdit_graph/*` in `project.godot`. All settings
  have built-in defaults, so a fresh install works without manual setup.

## License

[MIT](LICENSE)
