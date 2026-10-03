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


# Locate a helper binary on PATH without spawning a process. Spawning a
# missing binary makes the engine log "Could not create child process"
# as an editor error, so every CLI call resolves first and skips the
# spawn when nothing is found. Returns the full path or "".
# Windows honors PATHEXT (gh.exe, gh.bat, ...) the way CreateProcess
# does; entries with a directory separator are checked directly.
func find_cli_binary(program: String) -> String:
	var name := String(program).strip_edges()
	if name.is_empty():
		return ""
	if "/" in name or "\\" in name:
		return name if FileAccess.file_exists(name) else ""
	var path_env := String(OS.get_environment("PATH"))
	if path_env.is_empty():
		return ""
	var candidates := PackedStringArray([name])
	if OS.has_feature("windows"):
		for ext in String(OS.get_environment("PATHEXT")).split(";", false):
			var clean := String(ext).strip_edges().to_lower()
			if not clean.is_empty() and not name.to_lower().ends_with(clean):
				candidates.append(name + clean)
	var sep := ";" if OS.has_feature("windows") else ":"
	for dir in path_env.split(sep, false):
		var base := String(dir).strip_edges()
		if base.is_empty():
			continue
		for candidate in candidates:
			var full := base + "/" + String(candidate)
			if FileAccess.file_exists(full):
				return full
	return ""


# Run a non-git helper CLI (e.g. `gh`, `glab`) with the given arguments.
# Returns the same {"exit_code", "output"} shape as run_git. No repo
# scoping: host CLIs manage their own auth and target selection, so the
# working copy is irrelevant. A missing binary reports exit_code -1 with
# empty output — callers treat that as "not installed". The binary is
# resolved via find_cli_binary first, so a missing CLI never reaches
# OS.execute and never logs engine spawn noise.
func run_cli(program: String, args: PackedStringArray) -> Dictionary:
	var output: Array = []
	var binary := find_cli_binary(program)
	if binary.is_empty():
		return {"exit_code": -1, "output": output}
	var full_args: Array = []
	full_args.append_array(args)
	var exit_code: int = OS.execute(binary, full_args, output, true)
	return {"exit_code": exit_code, "output": output}


# Cache-only read: never spawns a process, so it is safe on the main thread
# (and returns false before the first probe has run).
func available_cached() -> bool:
	return available == 1
