# Rows 2–3 — Commit box (`CommitBox`)

- Message field (`CommitMessage`, `TextEdit`, 64px): placeholder names the
  current branch; `Ctrl+Enter` commits (`_on_commit_message_gui_input`),
  `Ctrl+Down` cycles through previous commit messages
  (`_recall_history_step`).
- `CommitRow`: full-width accent **Commit** button (label shows the staged
  count; disabled when nothing is staged) + **▾** options menu
  (`CommitOptionsMenu`): Commit (0), Commit & Push (1), Commit &
  Stage (2), Commit (Amend) (3) — the spec's `Commit, Commit(Amend), Commit
  and Push, Commit and Stage`.
- Last-message recall also lives in the ⋯ git actions menu (`Recall last
  commit message`, disabled while history is empty); committing resets the
  recall position.
- Commit & Stage stages everything first, then commits from
  `_pending_commit_after_stage` once the stage op lands
  (`_on_operation_complete`); Commit & Push chains `_push_after_commit()`.
