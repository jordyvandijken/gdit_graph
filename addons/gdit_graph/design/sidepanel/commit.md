# Rows 2–3 — Commit box (`CommitBox`)

- Summary row: `CommitSummaryLabel` (`No staged changes` / `N file(s) ready
  to commit`) + history button `↺` recalling the last 20 messages
  (`CommitHistoryMenu`, `_on_commit_history_pressed/selected`).
- Message field (`CommitMessage`, `TextEdit`, 64px): placeholder names the
  current branch; `Ctrl+Enter` commits (`_on_commit_message_gui_input`).
- `CommitRow`: full-width accent **Commit** button (label shows the staged
  count; disabled when nothing is staged unless Amend is on) + **▾** options
  menu (`CommitOptionsMenu`): Commit (0), Commit & Push (1), Commit &
  Stage (2), Commit (Amend) (3) — the spec's `Commit, Commit(Amend), Commit
  and Push, Commit and Stage`.
- Flags row: **Amend** checkbox (allows a message-only amend;
  `_on_amend_toggled` refreshes the button state) and **Sign off** checkbox
  (`--signoff`).
- Commit & Stage stages everything first, then commits from
  `_pending_commit_after_stage` once the stage op lands
  (`_on_operation_complete`); Commit & Push chains `_push_after_commit()`.
