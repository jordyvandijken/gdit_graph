extends RefCounted

# No class_name (repo convention, AGENTS.md #253): a global class name here
# would collide with a user script of the same name. Load via
# preload("res://addons/gdit_graph/git_manager.gd") - graph_manager.gd does
# exactly that with `extends "res://addons/gdit_graph/git_manager.gd"`.

signal status_changed(files: Array)
signal operation_complete(result: Dictionary)
# The repo/branch/remote snapshot changed on the worker. Panels re-run their
# environment gate (_check_git) instead of polling is_repo()/get_branch()
# from the main thread, which used to spawn a git process per call.
signal env_changed()

# DIP: git execution goes through this abstraction (any RefCounted with
# run_git(repo_path, args) -> {exit_code, output}, run_cli(program, args)
# for host CLIs, and is_git_available()), never OS.execute directly, so
# tests can inject a fake executor and the backend can be swapped without
# touching this file. Default is the OS-backed executor (see
# git_executor.gd).
const GitExecutorScript = preload("res://addons/gdit_graph/git_executor.gd")
const GitRefs = preload("res://addons/gdit_graph/git_refs.gd")
const GitWorker = preload("res://addons/gdit_graph/git_worker.gd")

# get_branch() sentinel for a repo that exists but has no HEAD yet (a fresh
# `git init`): `rev-parse --abbrev-ref HEAD` fails there.
const UNBORN_BRANCH := "unknown"

# Ops after which the cached repo/branch/remote snapshot can be stale. Every
# other op leaves HEAD and the remote list alone, so it skips the refresh.
const ENV_CHANGING_ACTIONS := [
	"init", "pull", "fetch", "push", "push_upstream",
	"checkout", "checkout_track", "detach", "branch_create_checkout",
	"graph_stash_push", "graph_stash_pop", "graph_stash_apply",
	"remote_add", "remote_set_url", "remote_remove",
]

var _is_refreshing: bool = false
var _shutdown: bool = false
var _executor = null
var _repo_path: String = ""

# The serial command worker (git_worker.gd): one long-lived thread behind a
# FIFO queue, so git work never runs on the main thread and the caller never
# blocks. Normally injected by the plugin (one worker shared by both
# managers); lazily created otherwise. It lives in its own script so a
# reparse of THIS file cannot swap the thread's Mutex/Semaphore out from
# under the running loop.
var _worker = null
# True when this manager built the worker itself and must therefore stop it.
# An injected (shared) worker is stopped by its owner.
var _owns_worker: bool = false

# --- Cached environment snapshot (is_repo / branch / has_remote) ------------
# These used to be synchronous OS.execute calls made from the panels'
# main-thread code paths (up to three per refresh, plus more per menu open).
# They are now resolved on the worker and read from this cache.
var _is_repo_cached: bool = false
var _branch_cached: String = UNBORN_BRANCH
var _has_remote_cached: bool = false
var _env_known: bool = false
var _env_pending: int = 0

# Original push output stashed while a no-upstream retry is in flight, so
# the panel can still report it if the retry cannot run (no remote left).
var _push_retry_error: String = ""


func _init(path: String = "", executor = null) -> void:
	_repo_path = path
	if executor != null:
		_executor = executor
	if not _repo_path.is_empty():
		refresh_env()


func set_executor(executor) -> void:
	_executor = executor
	if _worker != null and _worker.has_method("set_executor"):
		_worker.set_executor(executor)


# Share one worker between the side panel's and the graph tab's manager (the
# plugin's composition root does this). Commands from both panels then run
# strictly in arrival order on a single thread.
#
# Inject the worker BEFORE set_repo_path(): that call refreshes the env
# snapshot, which enqueues work, so a manager that has not been given a
# worker yet would build a throwaway one. Any such worker is stopped here
# rather than orphaned with a live thread and a half-drained queue.
func set_worker(worker) -> void:
	if _worker != null and _owns_worker and _worker != worker and _worker.has_method("stop") and _worker.has_method("enqueue"):
		_worker.stop()
	_worker = worker
	_owns_worker = false
	if worker != null:
		worker.set_repo_path(_repo_path)
		if _executor != null:
			worker.set_executor(_executor)


func _get_worker():
	# Rebuild when the pointer is Nil OR holds something that cannot queue
	# work. The second case is real: an in-place reparse of this file in a
	# live editor keeps the OLD member values with the NEW method bodies, and
	# this member used to hold a Thread. Calling enqueue() on that would
	# throw; treating it as absent is correct and cheap. The replaced worker
	# is left alone (it may still be draining commands someone else owns).
	if _worker == null or not _worker.has_method("enqueue"):
		_worker = GitWorker.new()
		_owns_worker = true
		_worker.set_repo_path(_repo_path)
		if _executor != null:
			_worker.set_executor(_executor)
	return _worker


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
func _finish_git_op(action: String, exit_code: int, output: Array, extra: Dictionary = {}, do_refresh: bool = true) -> Dictionary:
	var result := {"action": action, "exit_code": exit_code}
	for key in extra:
		result[key] = extra[key]
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)
	if do_refresh:
		refresh_status()
	# Ops that move HEAD or touch the remote list invalidate the cached
	# repo/branch/remote snapshot the panels read.
	if exit_code == 0 and ENV_CHANGING_ACTIONS.has(action):
		refresh_env()
	return result


func set_repo_path(path: String) -> void:
	_repo_path = path
	if _worker != null and _worker.has_method("set_repo_path"):
		_worker.set_repo_path(path)
	# A different work tree means a different repo/branch/remote answer.
	_env_known = false
	refresh_env()


func get_repo_path() -> String:
	return _repo_path


# Stop this manager's commands. The worker itself is owned by whoever
# injected it (the plugin shares one between both managers), so a manager
# that did not create it only detaches.
func shutdown() -> void:
	_shutdown = true
	if _worker != null and _owns_worker and _worker.has_method("enqueue") and _worker.has_method("stop"):
		_worker.stop()
	_worker = null


# Enqueue a git command for the worker. Never blocks the caller: the worker
# runs it in FIFO order and defers the callback to the main thread.
func _run_git(args: PackedStringArray, callback: Callable) -> void:
	if _shutdown:
		return
	_get_worker().enqueue(args, callback)


# Enqueue a READ-ONLY git command (log, status, list queries, details,
# diffs). The worker runs these on their own threads, so a refresh pays the
# slowest query instead of the sum, while mutations keep the strict arrival
# order of _run_git (parallel `git add`/`commit` pairs would collide on
# index.lock). Callers must only route queries here: a write issued on this
# lane could interleave with another write.
func _run_git_read(args: PackedStringArray, callback: Callable) -> void:
	if _shutdown:
		return
	_get_worker().enqueue_read(args, callback)


# Enqueue a host-CLI command (`gh`, `glab`) on the serial lane, so repo
# creation never interleaves with an in-flight git mutation.
func _run_cli(program: String, args: PackedStringArray, callback: Callable) -> void:
	if _shutdown:
		return
	_get_worker().enqueue_cli(program, args, callback)


# Enqueue a READ-ONLY host-CLI command (auth probes) on its own thread.
func _run_cli_read(program: String, args: PackedStringArray, callback: Callable) -> void:
	if _shutdown:
		return
	_get_worker().enqueue_cli_read(program, args, callback)


# --- Cached environment ----------------------------------------------------
# Resolve the repo/branch/remote snapshot on the worker and publish it ONCE
# all three answers are in (they are three separate git calls, and they can
# land in any order - publishing per-call would hand the panels a half-updated
# snapshot). The panels read the cache (is_repo / get_branch / has_remote) and
# re-run their gate on env_changed.
func refresh_env() -> void:
	if _shutdown or _repo_path.strip_edges().is_empty():
		return
	# Coalesce: a refresh requested while one is in flight reuses it rather
	# than queueing a second copy of the same three commands.
	if _env_pending > 0:
		return
	_env_pending = 3
	_run_git(
		PackedStringArray(["rev-parse", "--is-inside-work-tree"]),
		Callable(self, "_on_env_repo_result")
	)
	_run_git(
		PackedStringArray(["rev-parse", "--abbrev-ref", "HEAD"]),
		Callable(self, "_on_env_branch_result")
	)
	_run_git(
		PackedStringArray(["remote"]),
		Callable(self, "_on_env_remote_result")
	)


func _on_env_repo_result(exit_code: int, output: Array) -> void:
	var lines := GitRefs.split_lines(_join_output(output))
	_is_repo_cached = exit_code == 0 and not lines.is_empty() and String(lines[0]).strip_edges() == "true"
	_env_done()


func _on_env_branch_result(exit_code: int, output: Array) -> void:
	var lines := GitRefs.split_lines(_join_output(output))
	# A repo with no commits fails here: report it as unborn, not "unknown
	# because something went wrong" - the panels label it "(no commits yet)".
	_branch_cached = String(lines[0]).strip_edges() if exit_code == 0 and not lines.is_empty() else UNBORN_BRANCH
	_env_done()


func _on_env_remote_result(exit_code: int, output: Array) -> void:
	_has_remote_cached = exit_code == 0 and not GitRefs.split_lines(_join_output(output)).is_empty()
	_env_done()


func _env_done() -> void:
	_env_pending = maxi(_env_pending - 1, 0)
	if _env_pending > 0:
		return
	_env_known = true
	env_changed.emit()


func refresh_status() -> void:
	if _is_refreshing or _shutdown:
		return
	_is_refreshing = true
	# Read-only: concurrent lane (see _run_git_read).
	_run_git_read(
		PackedStringArray(["-c", "core.quotePath=false", "status", "--porcelain", "-uall"]),
		Callable(self, "_on_status_result")
	)


func _on_status_result(exit_code: int, output: Array) -> void:
	_is_refreshing = false
	if _shutdown:
		return
	var text: String = _join_output(output)
	if exit_code != 0:
		operation_complete.emit({"action": "status", "exit_code": exit_code, "error": text.strip_edges()})
		status_changed.emit([])
		return
	var files: Array = []
	# The executor delivers stdout as chunks holding every line, so join
	# them and split into individual porcelain entries.
	for line in GitRefs.split_lines(text):
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
	# `git commit` prints "[branch abc1234] subject" on success. The panels
	# learn the new commit from the status refresh (and the graph tab re-reads
	# the log), so the line is not parsed into a hash here: it used to be
	# emitted as result["hash"] holding the whole decorated line, which no
	# consumer could use.
	_finish_git_op("commit", exit_code, output)


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
	# A branch with commits but no upstream makes bare `git push` fail with
	# "the current branch ... has no upstream branch". Instead of surfacing
	# that fatal error, transparently retry with the upstream set — the
	# user just pressed Push, so setting up tracking is the obvious intent.
	if exit_code != 0 and _is_no_upstream_error(_join_output(output)):
		_push_retry_error = _join_output(output)
		_run_git(
			PackedStringArray(["remote"]),
			Callable(self, "_on_push_retry_remote_result")
		)
		return
	_finish_git_op("push", exit_code, output)


func _is_no_upstream_error(text: String) -> bool:
	return "no upstream branch" in text.to_lower()


func _on_push_retry_remote_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var names: PackedStringArray = PackedStringArray()
	for line in GitRefs.split_lines(_join_output(output)):
		var cleaned := String(line).strip_edges()
		if not cleaned.is_empty():
			names.append(cleaned)
	# Prefer "origin" when several remotes exist; otherwise take the first.
	var remote_name := ""
	if "origin" in names:
		remote_name = "origin"
	elif not names.is_empty():
		remote_name = String(names[0])
	if remote_name.is_empty():
		# Remote vanished between the push and the retry: report the
		# original push failure, not the empty remote list.
		var result := {"action": "push", "exit_code": -1, "error": _push_retry_error.strip_edges()}
		_push_retry_error = ""
		operation_complete.emit(result)
		refresh_status()
		return
	# Push HEAD (the current branch, whatever it is named) and record the
	# remote branch as upstream, so the next bare push just works.
	_run_git(
		PackedStringArray(["push", "-u", remote_name, "HEAD"]),
		Callable(self, "_on_push_retry_result").bind(remote_name)
	)


func _on_push_retry_result(exit_code: int, output: Array, remote_name: String) -> void:
	if _shutdown:
		return
	_push_retry_error = ""
	# Same "push" action tag, so panels need no new branch: success reads
	# as a normal push, with an "upstream_set" flag for a friendlier note.
	# A missing remote repo is flagged for the create-and-push recovery
	# flow instead of surfacing the raw host error (see below).
	var extra := {"upstream_set": exit_code == 0, "remote": remote_name}
	if exit_code != 0 and _is_repo_not_found_error(_join_output(output)):
		extra["repo_not_found"] = true
	_finish_git_op("push", exit_code, output, extra)


# True when a push failed because the remote repository does not exist
# server-side (GitHub/Bitbucket: "remote: Repository not found."; GitLab:
# "remote: The project you were looking for could not be found").
# Auth failures and rejected pushes fail differently and are NOT matched,
# so they keep surfacing verbatim.
func _is_repo_not_found_error(text: String) -> bool:
	var lowered := text.to_lower()
	if "repository not found" in lowered:
		return true
	return "could not be found" in lowered and "project" in lowered


# First-party helper CLI per host, for creating a missing remote repo.
# Bitbucket and custom hosts have none, so the panel falls back to
# browser guidance there. Auth stays in the user's own CLI config — the
# plugin never sees or stores tokens.
func _host_cli_program(host: String) -> String:
	match String(host).strip_edges().to_lower():
		"github":
			return "gh"
		"gitlab":
			return "glab"
	return ""


# Probe the host CLI: installed on PATH, and authed? Results arrive as
# {action: "host_cli_check", host, available, authed} — the panel routes
# on those flags, not on the error text. No status refresh: probing
# changes nothing in the worktree.
func check_host_cli(host: String) -> void:
	if _shutdown:
		return
	var clean := String(host).strip_edges().to_lower()
	var program := _host_cli_program(clean)
	if program.is_empty():
		operation_complete.emit({"action": "host_cli_check", "exit_code": 0, "host": clean, "available": false, "authed": false})
		return
	_run_cli_read(program, PackedStringArray(["--version"]), Callable(self, "_on_host_cli_version_result").bind(clean, program))


func _on_host_cli_version_result(exit_code: int, output: Array, host: String, program: String) -> void:
	if _shutdown:
		return
	if exit_code != 0:
		# Binary missing (or broken): report unavailable without a second
		# probe. Output is empty here, so the panel must route on the
		# available flag, not on result["error"].
		_finish_git_op("host_cli_check", exit_code, output, {"host": host, "available": false, "authed": false}, false)
		return
	_run_cli_read(program, PackedStringArray(["auth", "status"]), Callable(self, "_on_host_cli_auth_result").bind(host))


func _on_host_cli_auth_result(exit_code: int, output: Array, host: String) -> void:
	if _shutdown:
		return
	_finish_git_op("host_cli_check", exit_code, output, {"host": host, "available": true, "authed": exit_code == 0}, false)


# Create owner/repo on the host via its CLI. Reports
# {action: "host_repo_create", host, owner, repo, private}. Creation never
# pushes by itself: the panel auto-retries the pending push afterwards,
# so the push result keeps flowing through the normal pipeline.
# Visibility defaults to private — the least surprising choice for a repo
# whose absence may itself be a typo worth double-checking.
func create_host_repo(host: String, owner: String, repo: String, is_private: bool = true) -> void:
	if _shutdown:
		return
	var clean_host := String(host).strip_edges().to_lower()
	var program := _host_cli_program(clean_host)
	var clean_owner := String(owner).strip_edges()
	var clean_repo := String(repo).strip_edges()
	if program.is_empty() or clean_owner.is_empty() or clean_repo.is_empty():
		operation_complete.emit({"action": "host_repo_create", "exit_code": -1, "error": "Missing host, owner, or repo for creation", "host": clean_host, "owner": clean_owner, "repo": clean_repo})
		return
	var args := PackedStringArray(["repo", "create", "%s/%s" % [clean_owner, clean_repo]])
	if clean_host == "gitlab":
		# glab uses single-dash visibility flags (-p/-P), unlike gh.
		args.append("-p" if is_private else "-P")
	else:
		args.append("--private" if is_private else "--public")
	_run_cli(program, args, Callable(self, "_on_host_repo_create_result").bind(clean_host, clean_owner, clean_repo, is_private))


func _on_host_repo_create_result(exit_code: int, output: Array, host: String, owner: String, repo: String, is_private: bool) -> void:
	if _shutdown:
		return
	_finish_git_op("host_repo_create", exit_code, output, {"host": host, "owner": owner, "repo": repo, "private": is_private})


# First push to a newly added remote: sets the upstream so later bare
# `git push` / `git pull` calls work. Branch is the local branch name
# (panels read it from get_branch()).
func push_upstream(remote: String, branch: String) -> void:
	if _shutdown:
		return
	var remote_name := String(remote).strip_edges()
	var branch_name := String(branch).strip_edges()
	if remote_name.is_empty() or branch_name.is_empty():
		operation_complete.emit({"action": "push_upstream", "exit_code": -1, "error": "Missing remote or branch for push"})
		return
	_run_git(
		PackedStringArray(["push", "-u", remote_name, branch_name]),
		Callable(self, "_on_push_upstream_result").bind(remote_name)
	)


func _on_push_upstream_result(exit_code: int, output: Array, remote_name: String) -> void:
	if _shutdown:
		return
	# Same missing-repo flag as the bare-push retry path, so Add & Push to
	# a stale URL gets the same create-and-push recovery.
	var extra := {"remote": remote_name}
	if exit_code != 0 and _is_repo_not_found_error(_join_output(output)):
		extra["repo_not_found"] = true
	_finish_git_op("push_upstream", exit_code, output, extra)


# Read-only remote list for the remotes dialog. Results arrive via
# operation_complete carrying the raw text ({action: "remote_list", ...});
# panels parse it (see remote_url_utils.parse_remote_verbose) so this base
# class stays free of parsing helpers. No status refresh: listing never
# changes the worktree.
func list_remotes() -> void:
	if _shutdown:
		return
	# Read-only: concurrent lane (see _run_git_read).
	_run_git_read(
		PackedStringArray(["remote", "-v"]),
		Callable(self, "_on_remotes_list_result")
	)


func _on_remotes_list_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	_finish_git_op("remote_list", exit_code, output, {"text": _join_output(output)}, false)


# Register a new remote. Fails with "already exists" when the name is
# taken — the panel then offers to update that remote's URL instead.
func add_remote(remote: String, url: String) -> void:
	if _shutdown:
		return
	var remote_name := String(remote).strip_edges()
	var remote_url := String(url).strip_edges()
	if remote_name.is_empty() or remote_url.is_empty():
		operation_complete.emit({"action": "remote_add", "exit_code": -1, "error": "Missing remote name or URL"})
		return
	_run_git(
		PackedStringArray(["remote", "add", remote_name, remote_url]),
		Callable(self, "_on_remote_add_result").bind(remote_name)
	)


func _on_remote_add_result(exit_code: int, output: Array, remote_name: String) -> void:
	if _shutdown:
		return
	_finish_git_op("remote_add", exit_code, output, {"remote": remote_name})


# Point an existing remote at a new URL.
func set_remote_url(remote: String, url: String) -> void:
	if _shutdown:
		return
	var remote_name := String(remote).strip_edges()
	var remote_url := String(url).strip_edges()
	if remote_name.is_empty() or remote_url.is_empty():
		operation_complete.emit({"action": "remote_set_url", "exit_code": -1, "error": "Missing remote name or URL"})
		return
	_run_git(
		PackedStringArray(["remote", "set-url", remote_name, remote_url]),
		Callable(self, "_on_remote_set_url_result").bind(remote_name)
	)


func _on_remote_set_url_result(exit_code: int, output: Array, remote_name: String) -> void:
	if _shutdown:
		return
	_finish_git_op("remote_set_url", exit_code, output, {"remote": remote_name})


# Remove a remote. The local branches and commits stay untouched.
func remove_remote(remote: String) -> void:
	if _shutdown:
		return
	var remote_name := String(remote).strip_edges()
	if remote_name.is_empty():
		operation_complete.emit({"action": "remote_remove", "exit_code": -1, "error": "Missing remote name"})
		return
	_run_git(
		PackedStringArray(["remote", "remove", remote_name]),
		Callable(self, "_on_remote_remove_result").bind(remote_name)
	)


func _on_remote_remove_result(exit_code: int, output: Array, remote_name: String) -> void:
	if _shutdown:
		return
	_finish_git_op("remote_remove", exit_code, output, {"remote": remote_name})


# True when the repo has at least one remote. Cached: resolved on the worker
# by refresh_env() and re-resolved after any remote-touching op, so calling
# this from a click handler costs nothing.
func has_remote() -> bool:
	if not _env_known:
		refresh_env()
	return _has_remote_cached


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


# Branch switcher (sidepanel) queries. List results arrive via
# operation_complete carrying the raw text ({action, exit_code, text}); the
# panel parses them with GitRefs (plugin root) so this base class stays
# free of panel parsing helpers. Same worker-thread contract as
# refresh_status: never touch UI here, results are deferred to the main
# thread.
func list_branches() -> void:
	if _shutdown:
		return
	# Read-only: concurrent lane (see _run_git_read).
	_run_git_read(
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
	# Read-only: concurrent lane (see _run_git_read).
	_run_git_read(
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


# True when the path is inside a git work tree. Cached like has_remote(): the
# first call before the snapshot lands schedules a worker refresh, and
# panels re-check on env_changed.
func is_repo() -> bool:
	if not _env_known:
		refresh_env()
	return _is_repo_cached


# False until the first env snapshot has landed. Panels use it to avoid
# briefly painting "Not a Git repository" on startup.
func env_ready() -> bool:
	return _env_known


# Current branch, or UNBORN_BRANCH for a repo with no commits yet. Cached.
func get_branch() -> String:
	if not _env_known:
		refresh_env()
	return _branch_cached


# Memoized in the executor, so the first call probes `git --version` once and
# every later call (including the panels' per-refresh gate) is a cache read.
func is_git_available() -> bool:
	return bool(_get_executor().is_git_available())
