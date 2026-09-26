# Git command executor abstraction (DIP Phase 1).
#
# GitManager depends on this contract instead of calling OS.execute
# directly, so the high-level git orchestration no longer depends on the
# low-level OS detail. The default implementation below shells out to the
# `git` binary; tests or alternative backends inject a different executor
# (any RefCounted with the same two methods) through
# GitManager.set_executor() without touching GitManager itself.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/git_executor.gd").
extends RefCounted

# -1 = not probed yet, 0 = no git on PATH, 1 = git answers. Probing spawns a
# process, and the panels ask on every refresh, so the answer is memoized for
# the session (a git install does not appear/disappear under a running
# editor). Set `available = -1` to force a re-probe.
var available = -1


# Run a git command scoped to a repo working copy. Returns
# {"exit_code": int, "output": Array}. `args` are the git arguments
# without the program name; ["-C", repo_path] is prepended here so
# callers never spell out the OS invocation. An empty repo_path runs git
# without -C (used for global queries like --version).
func run_git(repo_path: String, args: PackedStringArray) -> Dictionary:
	var output: Array = []
	var full_args: Array = []
	var repo := String(repo_path).strip_edges()
	if not repo.is_empty():
		full_args = ["-C", repo]
	full_args.append_array(args)
	var exit_code: int = OS.execute("git", full_args, output, true)
	return {"exit_code": exit_code, "output": output}


# True when a `git` binary answers. Memoized: the first call probes
# `git --version` once, every later call is a cache read.
func is_git_available() -> bool:
	if available < 0:
		var output: Array = []
		var exit_code: int = OS.execute("git", ["--version"], output, true)
		available = 1 if exit_code == 0 else 0
	return available == 1


# Cache-only read: never spawns a process, so it is safe on the main thread
# (and returns false before the first probe has run).
func available_cached() -> bool:
	return available == 1
