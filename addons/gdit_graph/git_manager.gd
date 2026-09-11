extends RefCounted
class_name GitManager

signal status_changed(files: Array)
signal operation_complete(result: Dictionary)
signal commit_complete(hash: String)

var _thread: Thread
var _repo_path: String = ""
var _is_refreshing: bool = false
var _shutdown: bool = false


func _init(path: String = "") -> void:
	_repo_path = path


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
	var output: Array = []
	var full_args: Array = ["-C", _repo_path]
	full_args.append_array(args)

	var exit_code: int = OS.execute("git", full_args, output, true)
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
	# OS.execute delivers stdout as a single array element containing every
	# line, so join the chunks and split into individual porcelain entries.
	var text: String = ""
	for chunk in output:
		text += String(chunk)
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
	operation_complete.emit({"action": "stage", "path": path, "exit_code": exit_code})
	refresh_status()


func stage_files(paths: PackedStringArray) -> void:
	if paths.is_empty() or _shutdown:
		return
	var args := PackedStringArray(["add", "--"])
	args.append_array(paths)
	_run_git(args, Callable(self, "_on_stage_files_result"))


func _on_stage_files_result(exit_code: int, _output: Array) -> void:
	if _shutdown:
		return
	operation_complete.emit({"action": "stage", "exit_code": exit_code})
	refresh_status()


func unstage_file(path: String) -> void:
	_run_git(
		PackedStringArray(["restore", "--staged", path]),
		Callable(self, "_on_unstage_result").bind(path)
	)


func _on_unstage_result(exit_code: int, output: Array, path: String) -> void:
	if _shutdown:
		return
	operation_complete.emit({"action": "unstage", "path": path, "exit_code": exit_code})
	refresh_status()


func unstage_files(paths: PackedStringArray) -> void:
	if paths.is_empty() or _shutdown:
		return
	var args := PackedStringArray(["restore", "--staged", "--"])
	args.append_array(paths)
	_run_git(args, Callable(self, "_on_unstage_files_result"))


func _on_unstage_files_result(exit_code: int, _output: Array) -> void:
	if _shutdown:
		return
	operation_complete.emit({"action": "unstage", "exit_code": exit_code})
	refresh_status()


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
	var result := {"action": "revert", "exit_code": exit_code}
	if exit_code != 0:
		result["error"] = "\n".join(output)
	operation_complete.emit(result)
	refresh_status()


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
	var result := {"action": "clean", "exit_code": exit_code}
	if exit_code != 0:
		result["error"] = "\n".join(output)
	operation_complete.emit(result)
	refresh_status()


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
	var result := {"action": "commit", "exit_code": exit_code}
	if exit_code == 0:
		for line in output:
			if String(line).begins_with("["):
				result["hash"] = String(line).strip_edges()
		commit_complete.emit(result.get("hash", ""))
	else:
		result["error"] = "\n".join(output)
	operation_complete.emit(result)
	refresh_status()


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
	var result := {"action": "pull", "exit_code": exit_code}
	if exit_code != 0:
		result["error"] = "\n".join(output)
	operation_complete.emit(result)
	refresh_status()


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
	var result := {"action": "fetch", "exit_code": exit_code}
	if exit_code != 0:
		result["error"] = "\n".join(output)
	operation_complete.emit(result)
	refresh_status()


func _on_push_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var result := {"action": "push", "exit_code": exit_code}
	if exit_code != 0:
		result["error"] = "\n".join(output)
	operation_complete.emit(result)
	refresh_status()


func has_remote() -> bool:
	var output: Array = []
	var exit_code: int = OS.execute(
		"git",
		["-C", _repo_path, "remote"],
		output,
		true
	)
	if exit_code != 0:
		return false
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
	var result := {"action": "init", "exit_code": exit_code}
	if exit_code != 0:
		result["error"] = "\n".join(output)
	operation_complete.emit(result)


func get_branch() -> String:
	var output: Array = []
	var exit_code: int = OS.execute(
		"git",
		["-C", _repo_path, "rev-parse", "--abbrev-ref", "HEAD"],
		output,
		true
	)
	if exit_code == 0 and output.size() > 0:
		return String(output[0]).strip_edges()
	return "unknown"


func is_repo() -> bool:
	var output: Array = []
	var exit_code: int = OS.execute(
		"git",
		["-C", _repo_path, "rev-parse", "--is-inside-work-tree"],
		output,
		true
	)
	return exit_code == 0


func is_git_available() -> bool:
	var output: Array = []
	var exit_code: int = OS.execute("git", ["--version"], output, true)
	return exit_code == 0
