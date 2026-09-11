# Graph tab git commands (Phase 1 MVP: plan section I, first 4 rows).
#
# Extends GitManager (plan's recommended Option 2) so the Source Control
# panel never loads graph queries. Same worker-thread contract as the
# base class: _run_git -> _execute_git -> callback.call_deferred, parsed
# on the main thread, results delivered via signals. Never touch UI here.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/graph_manager.gd").
extends "res://addons/gdit_graph/git_manager.gd"

signal log_loaded(commits: Array)
signal branches_loaded(branches: Array)
signal tags_loaded(tags: Array)
signal refs_loaded(refs: Array)
signal head_loaded(hash: String)

const GraphUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")

# Structured log line: hash, parents, short hash, author, date, subject,
# decorate refs. 0x1F separates fields, 0x1E separates records. Carries the
# same data as `git log --graph --decorate` without the ASCII art, so the
# lane layout is computed from parent links (see graph_utils.gd).
const LOG_FORMAT = "%H%x1f%P%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%D%x1e"
const REFS_FORMAT = "%(refname)%1f%(objectname:short)%1f%(objectname)%1f%(HEAD)"
const LOG_DEFAULT_LIMIT = 200


func _join_output(output: Array) -> String:
	var text := ""
	for chunk in output:
		text += String(chunk)
	return text


# Core graph data. Empty rev means --all; otherwise the rev (branch, tag,
# HEAD...) scopes the walk (used by the panel's branch filter).
func get_log(limit: int = LOG_DEFAULT_LIMIT, offset: int = 0, rev: String = "") -> void:
	if _shutdown:
		return
	var args := PackedStringArray([
		"log", "--topo-order", "--decorate=full", "--date=iso",
		"-n", str(maxi(limit, 1)), "--skip=%d" % maxi(offset, 0),
		"--pretty=format:" + LOG_FORMAT,
	])
	if rev == null or String(rev).is_empty():
		args.append("--all")
	else:
		args.append(String(rev))
	_run_git(args, Callable(self, "_on_log_result"))


func _on_log_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var text := _join_output(output)
	var commits: Array = []
	var code := exit_code
	if exit_code == 0:
		commits = GraphUtils.parse_log(text)
		GraphUtils.assign_lanes(commits)
	elif "does not have any commits yet" in text:
		# Fresh `git init` repo: not a failure, just an empty graph.
		code = 0
	log_loaded.emit(commits)
	var result := {"action": "graph_log", "exit_code": code, "count": commits.size()}
	if code != 0:
		result["error"] = text.strip_edges()
	operation_complete.emit(result)


func get_branches(include_remote: bool = true) -> void:
	if _shutdown:
		return
	var args := PackedStringArray(["branch", "--no-color"])
	if include_remote:
		args.append("-a")
	_run_git(args, Callable(self, "_on_branches_result"))


func _on_branches_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var branches: Array = []
	if exit_code == 0:
		branches = GraphUtils.parse_branches(_join_output(output))
	branches_loaded.emit(branches)
	var result := {"action": "graph_branches", "exit_code": exit_code, "count": branches.size()}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)


func get_tags() -> void:
	if _shutdown:
		return
	_run_git(PackedStringArray(["tag", "-l"]), Callable(self, "_on_tags_result"))


func _on_tags_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var tags: Array = []
	if exit_code == 0:
		tags = GraphUtils.parse_tags(_join_output(output))
	tags_loaded.emit(tags)
	var result := {"action": "graph_tags", "exit_code": exit_code, "count": tags.size()}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)


# All refs (heads, remotes, tags) with the commit each points at. Used to
# anchor branch/tag labels to commits.
func get_refs() -> void:
	if _shutdown:
		return
	_run_git(
		PackedStringArray(["for-each-ref", "--format", REFS_FORMAT]),
		Callable(self, "_on_refs_result")
	)


func _on_refs_result(exit_code: int, output: Array) -> void:
	if _shutdown:
		return
	var refs: Array = []
	if exit_code == 0:
		refs = GraphUtils.parse_refs(_join_output(output))
	refs_loaded.emit(refs)
	var result := {"action": "graph_refs", "exit_code": exit_code, "count": refs.size()}
	if exit_code != 0:
		result["error"] = _join_output(output).strip_edges()
	operation_complete.emit(result)


# Current HEAD hash. The panel scrolls to it on load; empty when the repo
# has no commits yet (rev-parse fails) — not an error worth surfacing.
func get_head() -> void:
	if _shutdown:
		return
	_run_git(PackedStringArray(["rev-parse", "HEAD"]), Callable(self, "_on_head_result"))


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
