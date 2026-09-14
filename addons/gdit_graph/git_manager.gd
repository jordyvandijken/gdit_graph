extends RefCounted
class_name GitManager

signal status_changed(files: Array)
signal operation_complete(result: Dictionary)
signal commit_complete(hash: String)

# DIP: git execution goes through this abstraction (any RefCounted with
# run_git(repo_path, args) -> {exit_code, output} and is_git_available()),
# never OS.execute directly, so tests can inject a fake executor and the
# backend can be swapped without touching this file. Default is the
# OS-backed executor (see git_executor.gd).
const GitExecutorScript = preload("res://addons/gdit_graph/git_executor.gd")

var _thread: Thread
var _repo_path: String = ""
var _is_refreshing: bool = false
var _shutdown: bool = false
var _executor = null


func _init(path: String = "", executor = null) -> void:
	_repo_path = path
	if executor != null:
		_executor = executor


func set_executor(executor) -> void:
	_executor = executor


func get_executor():
	return _get_executor()


func _get_executor():
	if _executor == null:
		_executor = GitExecutorScript.new()
	return _executor


# Join the stdout chunks git execution delivers into one blob.
func _join_output(output: Array) -> String:
	var text := ""
	for chunk in output:
		text += String(chunk)
	return text


# Shared tail for git-op callbacks (DRY): build the
# {"action", "exit_code", ...extra} result, attach the joined output as
# "error" on failure, emit operation_complete, and refresh status unless
# told otherwise. Returns the result for callers that need it.
func _finish_git_op(action: String, exit_code: int, output: Array, extra: Dictionary = {}, do_refresh: bool = true, include_error: bool = true) -> Dictionary:
	var result := {"action": action, "exit_code": exit_code}
	for key in extra:
		result[key] = extra[key]
	if include_error and exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)
	if do_refresh:
		refresh_status()
	return result


func set_repo_path(path: String) -> void:
	_repo_path = path


func get_repo_path() -> String:
	return _repo_path


func shutdown() -> void:
	_shutdown = true
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


func _run_git(args: PackedStringArray, callback: Callable) -> void:
	if _shutdown:
		return
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_execute_git.bind(args, callback))


func _execute_git(args: PackedStringArray, callback: Callable) -> void:
	var res: Dictionary = _get_executor().run_git(_repo_path, args)
	var exit_code: int = int(res.get("exit_code", 1))
	var output: Array = res.get("output", [])
	# _execute_git runs on a worker thread; UI-touching signal handlers must
	# run on the main thread, so defer the callback there.
	callback.call_deferred(exit_code, output)


func refresh_status() -> void:
	if _is_refreshing or _shutdown:
		return
	_is_refreshing = true
	_run_git(
		PackedStringArray(["-c", "core.quotePath=false", "status", "--porcelain", "-uall"]),
		Callable(self, "_on_status_result")
	)


func _on_status_result(exit_code: int, output: Array) -> void:
	_is_refreshing = false
	if _shutdown:
		return
	var files: Array = []
	if exit_code != 0:
		var err: String = ""
		for chunk in output:
			err += String(chunk)
		operation_complete.emit({"action": "status", "exit_code": exit_code, "error": err.strip_edges()})
		status_changed.emit(files)
		return
	# The executor delivers stdout as chunks holding every line, so join
	# them and split into individual porcelain entries.
	var text: String = _join_output(output)
	for raw_line in text.split("\n"):
		var line: String = String(raw_line).trim_suffix("\r")
		if line.strip_edges().is_empty():
			continue
		if line.length() < 4:
			continue
		var status: String = line.left(2)
		var path: String = line.substr(3).strip_edges()
		# Renames look like "old -> new": operate on the new path.
		if " -> " in path:
			var parts := path.split(" -> ")
			path = String(parts[parts.size() - 1]).strip_edges()
		# Defensive: strip surrounding quotes if quoting is enabled.
		if path.length() >= 2 and path.begins_with("\"") and path.ends_with("\""):
			path = path.substr(1, path.length() - 2)
		if path.is_empty():
			continue
		files.append({"path": path, "status": status})
	status_changed.emit(files)
	operation_complete.emit({"action": "status", "exit_code": exit_code})


func stage_file(path: String) -> void:
	_run_git(
		PackedStringArray(["add", path]),
		Callable(self, "_on_stage_result").bind(path)
	)


func _on_stage_result(exit_code: int, output: Array, path: String) -> void:
	if _shutdown:
		return
	_finish_git_op("stage", exit_code, output, {"path": path})


func stage_files(paths: PackedStringArray) -> void:
	if paths.is_empty() or _shutdown:
		return
	var args := PackedStringArray(["add", "--"])
	args.append_array(paths)
	_run_git(args, Callable(self, "_on_stage_files_result"))


func _on_stage_files_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("stage", exit_code, output)


func unstage_file(path: String) -> void:
	_run_git(
		PackedStringArray(["restore", "--staged", path]),
		Callable(self, "_on_unstage_result").bind(path)
	)


func _on_unstage_result(exit_code: int, output: Array, path: String) -> void:
	if _shutdown:
		return
	_finish_git_op("unstage", exit_code, output, {"path": path})


func unstage_files(paths: PackedStringArray) -> void:
	if paths.is_empty() or _shutdown:
		return
	var args := PackedStringArray(["restore", "--staged", "--"])
	args.append_array(paths)
	_run_git(args, Callable(self, "_on_unstage_files_result"))


func _on_unstage_files_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("unstage", exit_code, output)


# Discarding tracked changes must revert BOTH the working tree and the
# index: a file can have staged *and* unstaged changes at once (status
# `MM`), and `--worktree` alone would leave the staged half behind.
func revert_changes(paths: PackedStringArray) -> void:
	if paths.is_empty() or _shutdown:
		return
	var args := PackedStringArray(["restore", "--source=HEAD", "--staged", "--worktree", "--"])
	args.append_array(paths)
	_run_git(args, Callable(self, "_on_revert_result"))


func _on_revert_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("revert", exit_code, output)


# Discarding an untracked file means deleting it: there is nothing in HEAD
# to restore from. `git clean` only ever touches untracked paths, so tracked
# files passed here by mistake are left alone (the op fails instead).
func discard_untracked(paths: PackedStringArray) -> void:
	if paths.is_empty() or _shutdown:
		return
	var args := PackedStringArray(["clean", "-fd", "--"])
	args.append_array(paths)
	_run_git(args, Callable(self, "_on_clean_result"))


func _on_clean_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("clean", exit_code, output)


func commit(message: String, amend: bool = false, signoff: bool = false) -> void:
	if message.is_empty():
		operation_complete.emit({"action": "commit", "exit_code": -1, "error": "Empty commit message"})
		return
	var args := PackedStringArray(["commit", "-m", message])
	if amend:
		args.append("--amend")
	if signoff:
		args.append("--signoff")
	_run_git(
		args,
		Callable(self, "_on_commit_result")
	)


func _on_commit_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var extra := {}
	if exit_code == 0:
		for line in output:
			if String(line).begins_with("["):
				extra["hash"] = String(line).strip_edges()
		commit_complete.emit(String(extra.get("hash", "")))
	_finish_git_op("commit", exit_code, output, extra)


func pull() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["pull"]),
		Callable(self, "_on_pull_result")
	)


func _on_pull_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("pull", exit_code, output)


func push() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["push"]),
		Callable(self, "_on_push_result")
	)


func fetch() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["fetch"]),
		Callable(self, "_on_fetch_result")
	)


func _on_fetch_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("fetch", exit_code, output)


func _on_push_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("push", exit_code, output)


func has_remote() -> bool:
	var res: Dictionary = _get_executor().run_git(_repo_path, PackedStringArray(["remote"]))
	if int(res.get("exit_code", 1)) != 0:
		return false
	var output: Array = res.get("output", [])
	for line in output:
		if not String(line).strip_edges().is_empty():
			return true
	return false


func init_repo() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["init"]),
		Callable(self, "_on_init_result")
	)


func _on_init_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	# No status refresh: a fresh `init` has no commits to list, and the
	# panel re-checks the repo explicitly on this result.
	_finish_git_op("init", exit_code, output, {}, false)


func get_branch() -> String:
	var res: Dictionary = _get_executor().run_git(_repo_path, PackedStringArray(["rev-parse", "--abbrev-ref", "HEAD"]))
	var output: Array = res.get("output", [])
	if int(res.get("exit_code", 1)) == 0 and output.size() > 0:
		return String(output[0]).strip_edges()
	return "unknown"


# Branch switcher (sidepanel) queries. List results arrive via
# operation_complete carrying the raw text ({action, exit_code, text}); the
# panel parses them with GitRefs (plugin root) so this base class stays
# free of panel parsing helpers. Same worker-thread contract as
# refresh_status: never touch UI here, results are deferred to the main
# thread.
func list_branches() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["branch", "--no-color", "-a"]),
		Callable(self, "_on_branch_list_result")
	)


func _on_branch_list_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_emit_branch_text_result("branch_list", exit_code, output)


func list_tags() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["tag", "-l"]),
		Callable(self, "_on_tag_list_result")
	)


func _on_tag_list_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_emit_branch_text_result("tag_list", exit_code, output)


func _emit_branch_text_result(action: String, exit_code: int, output: Array) -> void:
	var text := _join_output(output)
	# No status refresh: branch/tag listings never change the worktree.
	_finish_git_op(action, exit_code, output, {"text": text}, false)


# Switch the worktree to a local branch or tag. Git refuses when local
# changes would be overwritten — that failure surfaces via
# operation_complete, nothing is lost.
func checkout_ref(ref: String) -> void:
	if _shutdown:
		return
	var target := String(ref).strip_edges()
	if target.is_empty():
		return
	_run_git(
		PackedStringArray(["checkout", target]),
		Callable(self, "_on_branch_checkout_result").bind(target, "checkout")
	)


# Check out a remote-tracking branch (e.g. "origin/main") as a new local
# tracking branch. Fails with "already exists" when the local branch is
# already there — the panel then falls back to a plain checkout.
func checkout_remote(remote_short: String) -> void:
	if _shutdown:
		return
	var target := String(remote_short).strip_edges()
	if target.is_empty():
		return
	_run_git(
		PackedStringArray(["checkout", "--track", target]),
		Callable(self, "_on_branch_checkout_result").bind(target, "checkout_track")
	)


# Detach HEAD at the current commit (keeps the worktree, moves no branch).
func checkout_detached() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["checkout", "--detach"]),
		Callable(self, "_on_branch_checkout_result").bind("HEAD", "detach")
	)


func _on_branch_checkout_result(exit_code: int, output: Array, target: String, action: String) -> void:
	if _shutdown:
		return
	_finish_git_op(action, exit_code, output, {"ref": target})


# Create a branch and switch to it in one step. An empty start point means
# HEAD. Used by the branch switcher's "Create new branch" actions.
func create_and_checkout_branch(branch_name: String, start_point: String = "") -> void:
	if _shutdown:
		return
	var ref_name := String(branch_name).strip_edges()
	if ref_name.is_empty():
		return
	var args := PackedStringArray(["checkout", "-b", ref_name])
	var start := String(start_point).strip_edges()
	if not start.is_empty():
		args.append(start)
	_run_git(
		args,
		Callable(self, "_on_create_branch_result").bind(ref_name, start)
	)


func _on_create_branch_result(exit_code: int, output: Array, ref_name: String, start: String) -> void:
	if _shutdown:
		return
	_finish_git_op("branch_create_checkout", exit_code, output, {"ref": ref_name, "start": start})


func is_repo() -> bool:
	var res: Dictionary = _get_executor().run_git(_repo_path, PackedStringArray(["rev-parse", "--is-inside-work-tree"]))
	return int(res.get("exit_code", 1)) == 0


func is_git_available() -> bool:
	return bool(_get_executor().is_git_available())
