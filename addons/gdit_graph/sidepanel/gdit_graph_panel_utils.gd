# Source Control side-panel helpers.
#
# Pure data functions for the sidepanel dock panel: file-row display (name /
# directory split, status letter and color), status-list splitting (staged
# vs unstaged), context-menu targets, discard path safety, and the
# commit-message history ring. No git calls and no UI here, so this file
# needs no @tool annotation to be usable from @tool scripts that preload it.
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


static func status_color(code: String) -> Color:
	match code:
		"M":
			return Color(0.9, 0.7, 0.1)
		"A":
			return Color(0.2, 0.8, 0.2)
		"U", "?":
			return Color(0.55, 0.6, 0.55)
		"D":
			return Color(0.9, 0.2, 0.2)
		"R", "C":
			return Color(0.2, 0.5, 0.9)
	return Color.WHITE


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
