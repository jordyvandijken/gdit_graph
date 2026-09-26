# Graph tab git commands (Phase 1 MVP: plan section I, first 4 rows;
# Phase 2: commit details/diff + checkout/reset/merge, plan section V.7-10;
# Phase 3: branch/tag/stash/remote management + push/fetch context, V.11-15;
# Phase 4: two-commit comparison, V.17;
# plan section I remainder: rebase, cherry-pick, fetch-ref, merge-base,
# reflog).
#
# Extends GitManager (plan's recommended Option 2) so the Source Control
# panel never loads graph queries. Same worker-thread contract as the
# base class: _run_git (serial mutation lane) / _run_git_read (concurrent
# read lane) -> git_worker.gd -> callback.call_deferred, parsed on the
# main thread, results delivered via signals. Never touch UI here.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/graph_manager.gd").
extends "res://addons/gdit_graph/git_manager.gd"

signal log_loaded(commits: Array)
signal branches_loaded(branches: Array)
signal tags_loaded(tags: Array)
signal head_loaded(hash: String)
signal commit_details_loaded(details: Dictionary)
signal commit_diff_loaded(result: Dictionary)
signal stashes_loaded(stashes: Array)
signal remotes_loaded(remotes: Array)
signal comparison_files_loaded(result: Dictionary)
signal comparison_diff_loaded(result: Dictionary)
signal reflog_loaded(entries: Array)
signal uncommitted_loaded(has_changes: bool, count: int)
# Emits [{ index, hash }] for the stashes whose hash the panel asked for.
signal stash_hashes_loaded(entries: Array)
signal merge_base_ready(rev_a: String, rev_b: String, base: String)

const GraphUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")
# GitRefs is NOT redeclared here: it is inherited from GitManager, which
# declares the same preload. GDScript rejects a member that shadows an
# inherited one ("The member "GitRefs" already exists in parent class").

# Structured log line: hash, parents, short hash, author, author email,
# date, subject, decorate refs. 0x1F separates fields, 0x1E separates
# records. Carries the same data as `git log --graph --decorate` without
# the ASCII art, so the lane layout is computed from parent links (see
# graph_utils.gd). The email field (Phase 4, avatar lookup) is appended
# before the refs field; parse_log accepts the old 7-field shape too.
const LOG_FORMAT = "%H%x1f%P%x1f%h%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D%x1e"
const LOG_DEFAULT_LIMIT = 200
# Commit details: metadata fields plus full body (%B) plus decorate refs,
# then the --name-status file list after the 0x1E record separator (see
# GraphUtils.parse_commit_details). Subject stays single-line; the body may
# span lines but never contains the 0x1E separator.
const DETAILS_FORMAT = "%H%x1f%h%x1f%an%x1f%ad%x1f%cn%x1f%cd%x1f%s%x1f%B%x1f%D%x1e"


# _join_output and _finish_git_op are inherited from git_manager.gd.


# Core graph data. Empty rev means --all; otherwise the rev (branch, tag,
# HEAD...) scopes the walk (used by the panel's branch filter). Order
# follows the upstream commit-order setting (date / author-date / topo).
func get_log(limit: int = LOG_DEFAULT_LIMIT, offset: int = 0, rev: String = "", order: String = "topo") -> void:
	if _shutdown:
		return
	var order_flag := "--topo-order"
	match String(order).strip_edges().to_lower():
		"date":
			order_flag = "--date-order"
		"author-date", "author_date":
			order_flag = "--author-date-order"
	var args := PackedStringArray([
		"log", order_flag, "--decorate=full", "--date=iso",
		"-n", str(maxi(limit, 1)), "--skip=%d" % maxi(offset, 0),
		"--pretty=format:" + LOG_FORMAT,
	])
	if rev == null or String(rev).is_empty():
		args.append("--all")
	else:
		args.append(String(rev))
	_run_git_read(args, Callable(self, "_on_log_result"))


func _on_log_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var text := _join_output(output)
	var commits: Array = []
	var code := exit_code
	if exit_code == 0:
		commits = GraphUtils.parse_log(text)
	elif "does not have any commits yet" in text:
		# Fresh `git init` repo: not a failure, just an empty graph.
		code = 0
	# Lanes are NOT assigned here: this is one page of a possibly paginated
	# log, and assign_lanes() must see the merged list. The panel re-runs it
	# over every commit it holds after appending (see _on_log_loaded).
	# Failures emit nothing, so a transient git lock hiccup never replaces a
	# good graph with "No commits yet."; the error arrives via
	# operation_complete instead.
	if code == 0:
		log_loaded.emit(commits)
	_emit_op_result("graph_log", code, output, {"count": commits.size()})


func get_branches(include_remote: bool = true) -> void:
	if _shutdown:
		return
	var args := PackedStringArray(["branch", "--no-color"])
	if include_remote:
		args.append("-a")
	_run_git_read(args, Callable(self, "_on_branches_result"))


func _on_branches_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_emit_list_result("graph_branches", exit_code, output, GitRefs.parse_branches, branches_loaded.emit)


func get_tags() -> void:
	if _shutdown:
		return
	_run_git_read(PackedStringArray(["tag", "-l"]), Callable(self, "_on_tags_result"))


func _on_tags_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_emit_list_result("graph_tags", exit_code, output, GitRefs.parse_tags, tags_loaded.emit)


# Current HEAD hash. The panel scrolls to it on load; empty when the repo
# has no commits yet (rev-parse fails) — not an error worth surfacing.
func get_head() -> void:
	if _shutdown:
		return
	_run_git_read(PackedStringArray(["rev-parse", "HEAD"]), Callable(self, "_on_head_result"))


func _on_head_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var hash_value := ""
	if exit_code == 0:
		hash_value = _join_output(output).strip_edges().split(" ")[0]
	head_loaded.emit(hash_value)
	# No "error" key on failure: an unborn HEAD (fresh repo) is normal and
	# the panel simply skips the HEAD ring / scroll-to-HEAD.
	operation_complete.emit({"action": "graph_head", "exit_code": exit_code, "hash": hash_value})


# Best common ancestor of two commits, for the Phase 4 comparison view's
# base line. Async (merge_base_ready) because it ran synchronously from the
# panel's click handler, spawning a process on the main thread. Empty when
# the revs are unrelated or unresolvable.
func get_merge_base(rev_a: String, rev_b: String) -> void:
	if _shutdown:
		return
	var a := String(rev_a).strip_edges()
	var b := String(rev_b).strip_edges()
	if a.is_empty() or b.is_empty():
		merge_base_ready.emit(a, b, "")
		return
	_run_git(
		PackedStringArray(["merge-base", a, b]),
		Callable(self, "_on_merge_base_result").bind(a, b)
	)


func _on_merge_base_result(exit_code: int, output: Array, a: String, b: String) -> void:
	if _shutdown:
		return
	var base := ""
	if exit_code == 0:
		var lines := GitRefs.split_lines(_join_output(output))
		if not lines.is_empty():
			base = String(lines[0]).split(" ")[0]
	merge_base_ready.emit(a, b, base)


# Batch stash-hash resolution for the panel's stash-node flags (perf): one
# `rev-parse --verify` process for every unknown stash instead of one
# synchronous shell-out per stash on the main thread.
# Emits stash_hashes_loaded([{ index, hash }]); failures emit an empty list
# so flags simply stay unresolved (same degradation as before).
func get_stash_hashes(indices: Array) -> void:
	if _shutdown:
		return
	var clean: Array = []
	for i in indices:
		var n := int(i)
		if n >= 0 and not clean.has(n):
			clean.append(n)
	if clean.is_empty():
		return
	clean.sort()
	var args := PackedStringArray(["rev-parse", "--verify"])
	for n in clean:
		args.append("stash@{%d}" % int(n))
	_run_git_read(args, Callable(self, "_on_stash_hashes_result").bind(clean))


func _on_stash_hashes_result(exit_code: int, output: Array, indices: Array) -> void:
	if _shutdown:
		return
	var entries: Array = []
	if exit_code == 0:
		var lines := GitRefs.split_lines(_join_output(output))
		for k in range(mini(indices.size(), lines.size())):
			var h := String(lines[k]).strip_edges().split(" ")[0]
			if not h.is_empty():
				entries.append({"index": int(indices[k]), "hash": h})
	stash_hashes_loaded.emit(entries)
	_emit_op_result("graph_stash_hashes", exit_code, output, {"count": entries.size()})


# Commit metadata + changed-file list for the details view (Phase 2).
# -m --first-parent keeps merge commits non-empty (files vs first parent);
# for regular commits the flags are a no-op.
func get_commit_details(commit_hash: String) -> void:
	if _shutdown:
		return
	var rev := String(commit_hash).strip_edges()
	if rev.is_empty():
		return
	_run_git_read(
		PackedStringArray([
			"-c", "core.quotePath=false", "show", "--name-status",
			"--first-parent", "-m", "--format=" + DETAILS_FORMAT, rev, "--",
		]),
		Callable(self, "_on_commit_details_result").bind(rev)
	)


func _on_commit_details_result(exit_code: int, output: Array, rev: String) -> void:
	if _shutdown:
		return
	var text := _join_output(output)
	var details: Dictionary = {}
	var code := exit_code
	if exit_code == 0:
		details = GraphUtils.parse_commit_details(text)
		if String(details.get("hash", "")).is_empty():
			code = 1
	if details.is_empty():
		details = {"hash": rev, "files": []}
	commit_details_loaded.emit(details)
	var result := {"action": "graph_details", "exit_code": code, "hash": rev}
	if code != 0:
		result["error"] = text.strip_edges()
	operation_complete.emit(result)


# Unified diff of one file at one commit for the inline diff viewer.
# --format= drops the commit header so the output is pure diff;
# --no-ext-diff avoids external diff drivers stalling the worker thread.
func get_commit_diff(commit_hash: String, path: String) -> void:
	if _shutdown:
		return
	var rev := String(commit_hash).strip_edges()
	var target := String(path).strip_edges()
	if rev.is_empty() or target.is_empty():
		return
	_run_git_read(
		PackedStringArray([
			"-c", "core.quotePath=false", "show", "--format=", "--no-ext-diff",
			"--first-parent", "-m", rev, "--", target,
		]),
		Callable(self, "_on_commit_diff_result").bind(rev, target)
	)


func _on_commit_diff_result(exit_code: int, output: Array, rev: String, target: String) -> void:
	if _shutdown:
		return
	var shaped := GraphUtils.truncate_diff(_join_output(output))
	commit_diff_loaded.emit({
		"hash": rev,
		"path": target,
		"diff": String(shaped["text"]),
		"truncated": bool(shaped["truncated"]),
	})
	var result := {"action": "graph_diff", "exit_code": exit_code, "hash": rev, "path": target}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)


# Merge a branch, tag, or commit hash into the current branch.
# --no-edit accepts the default merge message without launching an editor,
# which would stall the worker thread in a headless editor process.
func merge_ref(ref: String) -> void:
	if _shutdown:
		return
	var target := String(ref).strip_edges()
	if target.is_empty():
		return
	_run_git(
		PackedStringArray(["merge", "--no-edit", target]),
		Callable(self, "_on_merge_result").bind(target)
	)


func _on_merge_result(exit_code: int, output: Array, target: String) -> void:
	if _shutdown:
		return
	var result := {"action": "graph_merge", "exit_code": exit_code, "ref": target}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)


# Move the current branch tip to a commit. Mode is validated (never passed
# raw) so a hostile ref name cannot inject extra flags: only soft/mixed/hard
# reach the command line, anything else falls back to mixed.
func reset_ref(commit_hash: String, mode: String = "mixed") -> void:
	if _shutdown:
		return
	var rev := String(commit_hash).strip_edges()
	if rev.is_empty():
		return
	var flag := "--mixed"
	match String(mode).strip_edges().to_lower():
		"soft":
			flag = "--soft"
		"hard":
			flag = "--hard"
		_:
			flag = "--mixed"
	_run_git(
		PackedStringArray(["reset", flag, rev]),
		Callable(self, "_on_reset_result").bind(rev, flag.trim_prefix("--"))
	)


func _on_reset_result(exit_code: int, output: Array, rev: String, mode_name: String) -> void:
	if _shutdown:
		return
	var result := {"action": "graph_reset", "exit_code": exit_code, "hash": rev, "mode": mode_name}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)


# Rebase the current branch onto a branch, tag, or commit hash. Rewrites
# history, so the panel confirms first. A conflict leaves the repo mid-rebase
# (git refuses to continue silently); the failure surfaces via
# operation_complete and the user resolves with git CLI
# (`git rebase --abort` / `--continue`), same as a conflicted merge.
func rebase_ref(ref: String) -> void:
	if _shutdown:
		return
	var target := String(ref).strip_edges()
	if target.is_empty():
		return
	_run_git(
		PackedStringArray(["rebase", target]),
		Callable(self, "_on_rebase_result").bind(target)
	)


func _on_rebase_result(exit_code: int, output: Array, target: String) -> void:
	if _shutdown:
		return
	_emit_op_result("graph_rebase", exit_code, output, {"ref": target})


# Apply one commit onto the current branch. Conflicts behave like rebase:
# the failure surfaces via operation_complete for CLI resolution
# (`git cherry-pick --abort` / `--continue`).
func cherry_pick(commit_hash: String) -> void:
	if _shutdown:
		return
	var rev := String(commit_hash).strip_edges()
	if rev.is_empty():
		return
	_run_git(
		PackedStringArray(["cherry-pick", rev]),
		Callable(self, "_on_cherry_pick_result").bind(rev)
	)


func _on_cherry_pick_result(exit_code: int, output: Array, rev: String) -> void:
	if _shutdown:
		return
	_emit_op_result("graph_cherry_pick", exit_code, output, {"hash": rev})


# Phase 3 shared result shape: {"action", "exit_code", ...extra} plus
# "error" on failure. Delegates to the base _finish_git_op without the
# status refresh: graph ops never touch the side-panel status, the graph
# panel reloads explicitly after mutations.
func _emit_op_result(action: String, exit_code: int, output: Array, extra: Dictionary = {}) -> void:
	_finish_git_op(action, exit_code, output, extra, false)


# Shared tail for the LIST queries (DRY): parse the joined output only on
# success, publish the typed signal, then report
# {"action", "exit_code", "count"} via _emit_op_result. `parse` is a static
# parse helper and `emit` a Signal.emit, so every caller is one line:
#   _emit_list_result("graph_tags", code, out, GitRefs.parse_tags, tags_loaded.emit)
func _emit_list_result(action: String, exit_code: int, output: Array, parse: Callable, emit: Callable) -> void:
	var items = []
	if exit_code == 0:
		items = parse.call(_join_output(output))
	emit.call(items)
	_emit_op_result(action, exit_code, output, {"count": items.size()})


# Stash list for the overflow menu (Phase 3). Empty output (no stashes) is
# exit 0 with no lines — not an error.
func get_stashes() -> void:
	if _shutdown:
		return
	_run_git_read(PackedStringArray(["stash", "list"]), Callable(self, "_on_stashes_result"))


func _on_stashes_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_emit_list_result("graph_stashes", exit_code, output, GraphUtils.parse_stashes, stashes_loaded.emit)


# Remote list for fetch/push targets (Phase 3). No remotes is exit 0 with
# no lines — the panel disables remote actions instead of erroring.
func get_remotes() -> void:
	if _shutdown:
		return
	_run_git_read(PackedStringArray(["remote", "-v"]), Callable(self, "_on_remotes_result"))


func _on_remotes_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_emit_list_result("graph_remotes", exit_code, output, GraphUtils.parse_remotes, remotes_loaded.emit)


# Reflog for the overflow menu (recovery: commits only in reflogs, plan
# section I). --format carries the full hash plus the reflog subject; the
# panel caps display, so no -n limit is applied here.
func get_reflog() -> void:
	if _shutdown:
		return
	_run_git_read(
		PackedStringArray(["reflog", "--format=%H %gs"]),
		Callable(self, "_on_reflog_result")
	)


func _on_reflog_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_emit_list_result("graph_reflog", exit_code, output, GraphUtils.parse_reflog, reflog_loaded.emit)


# Worktree dirtiness for the "Uncommitted Changes (*)" table row. Same
# porcelain query as the side panel; only the changed-path count matters,
# so untracked files (-uall) are included. Failures emit nothing, so a
# transient git lock hiccup never wipes a good row.
func get_uncommitted_count() -> void:
	if _shutdown:
		return
	_run_git_read(
		PackedStringArray(["-c", "core.quotePath=false", "status", "--porcelain", "-uall"]),
		Callable(self, "_on_uncommitted_result")
	)


func _on_uncommitted_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var count := 0
	if exit_code == 0:
		count = GitRefs.split_lines(_join_output(output)).size()
		uncommitted_loaded.emit(count > 0, count)
	_emit_op_result("graph_uncommitted", exit_code, output, {"count": count})


# Guard for user-typed ref names: non-empty only. Content rules
# (characters, "..") are validated in the dialog; git is the final
# arbiter and its error surfaces via operation_complete.
func _clean_ref_name(raw_name: String) -> String:
	return String(raw_name).strip_edges()


func create_branch(branch_name: String, target: String) -> void:
	if _shutdown:
		return
	var ref_name := _clean_ref_name(branch_name)
	var start := String(target).strip_edges()
	if ref_name.is_empty() or start.is_empty():
		return
	_run_git(
		PackedStringArray(["branch", ref_name, start]),
		Callable(self, "_on_branch_op_result").bind("graph_branch_create", {"name": ref_name, "target": start})
	)


# Safe delete (-d) refuses unmerged branches; force (-D) overrides.
# Deleting the checked-out branch fails in git — surfaced as an error.
func delete_branch(branch_name: String, force: bool = false) -> void:
	if _shutdown:
		return
	var ref_name := _clean_ref_name(branch_name)
	if ref_name.is_empty():
		return
	var flag := "-D" if force else "-d"
	_run_git(
		PackedStringArray(["branch", flag, ref_name]),
		Callable(self, "_on_branch_op_result").bind("graph_branch_delete", {"name": ref_name, "force": force})
	)


func rename_branch(old_name: String, new_name: String) -> void:
	if _shutdown:
		return
	var from_name := _clean_ref_name(old_name)
	var to_name := _clean_ref_name(new_name)
	if from_name.is_empty() or to_name.is_empty():
		return
	_run_git(
		PackedStringArray(["branch", "-m", from_name, to_name]),
		Callable(self, "_on_branch_op_result").bind("graph_branch_rename", {"old": from_name, "new": to_name})
	)


func _on_branch_op_result(exit_code: int, output: Array, action: String, extra: Dictionary) -> void:
	if _shutdown:
		return
	_emit_op_result(action, exit_code, output, extra)


func stash_push(message: String) -> void:
	if _shutdown:
		return
	var args := PackedStringArray(["stash", "push"])
	var note := String(message).strip_edges()
	if not note.is_empty():
		args.append("-m")
		args.append(note)
	_run_git(args, Callable(self, "_on_stash_op_result").bind("graph_stash_push", {}))


func stash_apply(index: int) -> void:
	if _shutdown:
		return
	var ref := GraphUtils.stash_ref(index)
	_run_git(
		PackedStringArray(["stash", "apply", ref]),
		Callable(self, "_on_stash_op_result").bind("graph_stash_apply", {"ref": ref})
	)


func stash_pop(index: int) -> void:
	if _shutdown:
		return
	var ref := GraphUtils.stash_ref(index)
	_run_git(
		PackedStringArray(["stash", "pop", ref]),
		Callable(self, "_on_stash_op_result").bind("graph_stash_pop", {"ref": ref})
	)


func stash_drop(index: int) -> void:
	if _shutdown:
		return
	var ref := GraphUtils.stash_ref(index)
	_run_git(
		PackedStringArray(["stash", "drop", ref]),
		Callable(self, "_on_stash_op_result").bind("graph_stash_drop", {"ref": ref})
	)


func _on_stash_op_result(exit_code: int, output: Array, action: String, extra: Dictionary) -> void:
	if _shutdown:
		return
	_emit_op_result(action, exit_code, output, extra)


# Annotated tags carry a message (tag name when blank); otherwise
# lightweight. Target is a commit hash from the graph selection.
func create_tag(tag_name: String, target: String, annotated: bool, message: String = "") -> void:
	if _shutdown:
		return
	var ref_name := _clean_ref_name(tag_name)
	var start := String(target).strip_edges()
	if ref_name.is_empty() or start.is_empty():
		return
	var args := PackedStringArray(["tag"])
	if annotated:
		var note := String(message).strip_edges()
		args.append("-a")
		args.append(ref_name)
		args.append(start)
		args.append("-m")
		args.append(note if not note.is_empty() else ref_name)
	else:
		args.append(ref_name)
		args.append(start)
	_run_git(
		args,
		Callable(self, "_on_tag_op_result").bind("graph_tag_create", {"name": ref_name, "target": start, "annotated": annotated})
	)


func delete_tag(tag_name: String) -> void:
	if _shutdown:
		return
	var ref_name := _clean_ref_name(tag_name)
	if ref_name.is_empty():
		return
	_run_git(
		PackedStringArray(["tag", "-d", ref_name]),
		Callable(self, "_on_tag_op_result").bind("graph_tag_delete", {"name": ref_name})
	)


func _on_tag_op_result(exit_code: int, output: Array, action: String, extra: Dictionary) -> void:
	if _shutdown:
		return
	_emit_op_result(action, exit_code, output, extra)


# Push one ref to one remote (branch/tag). Pull of a specific branch stays
# on the base pull(); the panel guards both with has_remote().
func push_ref(ref: String, remote: String) -> void:
	if _shutdown:
		return
	var target := String(ref).strip_edges()
	var dest := String(remote).strip_edges()
	if target.is_empty() or dest.is_empty():
		return
	_run_git(
		PackedStringArray(["push", dest, target]),
		Callable(self, "_on_push_ref_result").bind(target, dest)
	)


func _on_push_ref_result(exit_code: int, output: Array, target: String, dest: String) -> void:
	if _shutdown:
		return
	_emit_op_result("graph_push", exit_code, output, {"ref": target, "remote": dest})


# Fetch one remote, optionally pruning stale remote-tracking branches.
func fetch_remote(remote: String, prune: bool = false) -> void:
	if _shutdown:
		return
	var dest := String(remote).strip_edges()
	if dest.is_empty():
		return
	var args := PackedStringArray(["fetch"])
	if prune:
		args.append("--prune")
	args.append(dest)
	_run_git(
		args,
		Callable(self, "_on_fetch_remote_result").bind(dest, prune)
	)


func _on_fetch_remote_result(exit_code: int, output: Array, dest: String, prune: bool) -> void:
	if _shutdown:
		return
	_emit_op_result("graph_fetch", exit_code, output, {"remote": dest, "prune": prune})


# Fetch one ref (usually the current branch) from one remote. Unlike
# fetch_remote (whole remote), this updates only the requested ref.
func fetch_ref(remote: String, ref: String) -> void:
	if _shutdown:
		return
	var dest := String(remote).strip_edges()
	var target := String(ref).strip_edges()
	if dest.is_empty() or target.is_empty():
		return
	_run_git(
		PackedStringArray(["fetch", dest, target]),
		Callable(self, "_on_fetch_ref_result").bind(dest, target)
	)


func _on_fetch_ref_result(exit_code: int, output: Array, dest: String, target: String) -> void:
	if _shutdown:
		return
	_emit_op_result("graph_fetch_ref", exit_code, output, {"remote": dest, "ref": target})


# Phase 4: two-commit comparison (plan section V.17). File list between A
# and B for the comparison view. Direction matters for renames/statuses,
# so A/B are passed through in order, oldest-first by convention.
func get_comparison_files(hash_a: String, hash_b: String) -> void:
	if _shutdown:
		return
	var rev_a := String(hash_a).strip_edges()
	var rev_b := String(hash_b).strip_edges()
	if rev_a.is_empty() or rev_b.is_empty():
		return
	_run_git_read(
		PackedStringArray([
			"-c", "core.quotePath=false", "diff", "--name-status",
			"--no-ext-diff", rev_a, rev_b, "--",
		]),
		Callable(self, "_on_comparison_files_result").bind(rev_a, rev_b)
	)


func _on_comparison_files_result(exit_code: int, output: Array, rev_a: String, rev_b: String) -> void:
	if _shutdown:
		return
	var files: Array = []
	if exit_code == 0:
		files = GraphUtils.parse_diff_name_status(_join_output(output))
	comparison_files_loaded.emit({"a": rev_a, "b": rev_b, "files": files})
	var result := {"action": "graph_compare_files", "exit_code": exit_code, "a": rev_a, "b": rev_b, "count": files.size()}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)


# Phase 4: unified diff of one path between A and B. Same viewer path as
# single-commit diffs (truncate + binary handling live in the widget).
func get_comparison_diff(hash_a: String, hash_b: String, path: String) -> void:
	if _shutdown:
		return
	var rev_a := String(hash_a).strip_edges()
	var rev_b := String(hash_b).strip_edges()
	var target := String(path).strip_edges()
	if rev_a.is_empty() or rev_b.is_empty() or target.is_empty():
		return
	_run_git_read(
		PackedStringArray([
			"-c", "core.quotePath=false", "diff", "--no-ext-diff",
			rev_a, rev_b, "--", target,
		]),
		Callable(self, "_on_comparison_diff_result").bind(rev_a, rev_b, target)
	)


func _on_comparison_diff_result(exit_code: int, output: Array, rev_a: String, rev_b: String, target: String) -> void:
	if _shutdown:
		return
	var shaped := GraphUtils.truncate_diff(_join_output(output))
	comparison_diff_loaded.emit({
		"a": rev_a,
		"b": rev_b,
		"path": target,
		"diff": String(shaped["text"]),
		"truncated": bool(shaped["truncated"]),
	})
	var result := {"action": "graph_compare_diff", "exit_code": exit_code, "a": rev_a, "b": rev_b, "path": target}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)
