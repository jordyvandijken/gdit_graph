# Changelog

All notable changes to the Git Graph plugin are documented here.

## [Unreleased]

- Side panel no longer forces the dock taller: content lives in a scroll
  container with the status row pinned below it, file trees start
  collapsed until the first status lands, and long branch names truncate
  instead of widening the dock.

- Remotes dialog: Push (or Commit & Push) with no remote configured now
  offers to add one instead of erroring, with host presets for GitHub,
  GitLab, and Bitbucket (HTTPS/SSH URL builder plus custom URLs) and a
  "New repo on..." shortcut to the host's creation page. The `...` menu's
  new Remotes... entry lists, adds, re-points, and removes remotes, and
  Add & Push sets the upstream so later bare pushes work.
- Push self-heals a missing upstream: pressing Push on a branch that
  tracks nothing now pushes and records the upstream (preferring
  "origin") instead of failing with "the current branch has no upstream
  branch".
- Push recovers a missing remote repository: "Repository not found" now
  opens a create-and-push flow that parses the remote URL into host /
  owner / repo, offers one-click creation via `gh` (GitHub) or `glab`
  (GitLab) when installed and authed (private by default), and otherwise
  guides through the host's new-repo page with a "Push again" retry. The
  pending push auto-retries after creation.

## [1.0.0]

- Source Control dock with staged and unstaged changes, per-file stage,
  unstage, and discard, commit message history, amend, commit-and-push,
  and commit-and-stage options.
- Header toolbar with Pull, Fetch, Push, Refresh, and an all-actions menu
  including remotes, `.gitignore` editing, sign-off, and debug log.
- Branch switcher popup with search, create-and-checkout,
  create-from-source, and detach HEAD.
- Git Graph main-screen tab with commit lanes, details, diffs,
  cherry-pick, rebase, merge, reset, branch, tag, stash, reflog, find,
  comparison view, code reviews, pull-request links, avatars, and theming.
- Empty-state Init Git flow for projects that are not repositories yet.
