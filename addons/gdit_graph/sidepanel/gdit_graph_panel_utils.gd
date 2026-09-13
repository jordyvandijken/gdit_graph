# Source Control side-panel helpers.
#
# Pure data functions for the sidepanel dock panel: file-row display (name /
# directory split, status letter), status-list splitting (staged
# vs unstaged), context-menu targets, discard path safety, the
# commit-message history ring, and branch-switcher helpers (branch-name
# sanitize, ref-name filtering). Helpers shared with the graph tab live at
# the plugin root: branch/tag list parsing and branch-name validation in
# git_refs.gd, status-letter colors in file_status.gd. No git calls and no
# UI here, so this file needs no @tool annotation to be usable from @tool
# scripts that preload it.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/gdit_graph_panel_utils.gd").
extends RefCounted


static func split_display_path(path: String) -> PackedStringArray:
	var dir := path.get_base_dir()
	if dir == "." or dir.is_empty():
		dir = ""
	return PackedStringArray([path.get_file(), dir])


static func status_display(code: String) -> String:
	if code == "?":
		return "U"
	return code


# Split a `git status --porcelain` file list into staged and unstaged rows:
# untracked (`?`) rows are unstaged; otherwise the index (left) code decides
# staged and the worktree (right) code decides unstaged (a row can be both).
static func split_status_files(files: Array) -> Dictionary:
	var staged: Array = []
	var unstaged: Array = []
	for f in files:
		var s: String = f["status"]
		var first: String = s.left(1)
		var second: String = s.right(1)
		if first == "?":
			unstaged.append(f)
		else:
			var is_staged: bool = first != " "
			var is_unstaged: bool = second != " "
			if is_staged:
				staged.append(f)
			if is_unstaged and not is_staged:
				unstaged.append(f)
			elif is_unstaged and is_staged:
				unstaged.append(f)
	return {"staged": staged, "unstaged": unstaged}


# If the right-clicked row is part of a multi-selection, act on the whole
# selection (like VSCode); otherwise act on the hovered row alone.
static func menu_targets(hovered: String, selected: PackedStringArray) -> PackedStringArray:
	if selected.size() > 1 and hovered in selected:
		return selected
	return PackedStringArray([hovered])


# Discarding an untracked file deletes it from disk, so as a safety net only
# plain repo-relative paths are accepted (never absolute paths or `..`).
static func is_safe_repo_relative(path: String) -> bool:
	if path.is_empty() or path.is_absolute_path() or path.begins_with("~"):
		return false
	for part in path.split("/"):
		if part == "..":
			return false
	return true


static func is_untracked(path: String, unstaged_files: Array) -> bool:
	for f in unstaged_files:
		if String(f.get("path", "")) == path:
			return String(f.get("status", "")).strip_edges() == "??"
	return false


# Commit-message history ring: newest first, de-duplicated, capped at
# max_size. Returns the updated history.
static func remember_message(history: PackedStringArray, msg: String, max_size: int) -> PackedStringArray:
	var cleaned := msg.strip_edges()
	if cleaned.is_empty():
		return history
	history.erase(cleaned)
	history.insert(0, cleaned)
	while history.size() > max_size:
		history.resize(max_size)
	return history


# Substring filter over switcher entries (case-insensitive, matches the
# display name). An empty query matches everything.
static func filter_ref_names(items: Array, query: String) -> Array:
	var q := String(query).strip_edges().to_lower()
	if q.is_empty():
		return items.duplicate()
	var hits: Array = []
	for item in items:
		var info: Dictionary = item
		var label := String(info.get("display", info.get("name", "")))
		if q in label.to_lower():
			hits.append(item)
	return hits


static func local_branch_exists(branches: Array, branch_name: String) -> bool:
	for b in branches:
		var info: Dictionary = b
		if not bool(info.get("remote", false)) and String(info.get("name", "")) == branch_name:
			return true
	return false


# Turn free typing into a branch-name candidate: surrounding whitespace is
# trimmed and every whitespace run becomes a single dash ("my new branch"
# -> "my-new-branch"). Anything still illegal (see validate_branch_name in
# git_refs.gd) is reported, never silently mangled.
static func sanitize_branch_name(raw: String) -> String:
	var candidate := String(raw).strip_edges()
	if candidate.is_empty():
		return ""
	var ws := RegEx.new()
	if ws.compile("\\s+") == OK:
		candidate = ws.sub(candidate, "-", true)
	return candidate


# Local name for a remote-tracking ref: "origin/feature/x" -> "feature/x".
static func remote_tracking_local_name(remote_short: String) -> String:
	var cleaned := String(remote_short).strip_edges()
	var slash := cleaned.find("/")
	if slash == -1:
		return cleaned
	return cleaned.substr(slash + 1)
