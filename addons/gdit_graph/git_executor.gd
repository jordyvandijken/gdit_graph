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


# True when a `git` binary answers. The panels gate their UI on this.
func is_git_available() -> bool:
	var output: Array = []
	var exit_code: int = OS.execute("git", ["--version"], output, true)
	return exit_code == 0
