# Shared git ref parsing used by both panels.
#
# The side panel (branch switcher) and the graph tab (branch menus, filter,
# create/rename dialogs) parse the same `git branch` / `git tag` output and
# validate new branch names with the same rules. This file owns those
# helpers so the two panels cannot drift apart. Panel-specific parsing stays
# local: structured log / commit details / stash / remote / reflog lists in
# workpanel/graph_utils.gd, status-list splitting in
# sidepanel/gdit_graph_panel_utils.gd.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/git_refs.gd").
extends RefCounted


# Split the single stdout blob OS.execute delivers into individual lines
# ("\r" tolerant, skips blanks).
static func split_lines(text: String) -> PackedStringArray:
	var lines := PackedStringArray()
	for raw_line in text.split("\n"):
		var line: String = String(raw_line).trim_suffix("\r")
		if line.strip_edges().is_empty():
			continue
		lines.append(line)
	return lines


# Parse `git branch --no-color [-a]` output into
# [{ name, display, current, remote, detached }]. Symlink lines
# ("remotes/origin/HEAD -> origin/main") carry no commit and are skipped; a
# detached HEAD shows as "* (HEAD detached at ...)". Remote-tracking names
# keep the full "remotes/..." form in `name` while `display` drops the
# "remotes/" prefix for switcher rows.
static func parse_branches(text: String) -> Array:
	var branches: Array = []
	for line in split_lines(text):
		var entry := line.strip_edges()
		if entry.is_empty() or " -> " in entry:
			continue
		var current := entry.begins_with("*")
		if current:
			entry = entry.substr(1).strip_edges()
		var remote := entry.begins_with("remotes/")
		var display := entry
		if remote:
			display = entry.substr(len("remotes/"))
		branches.append({
			"name": entry,
			"display": display,
			"current": current,
			"remote": remote,
			"detached": entry.begins_with("(HEAD detached"),
		})
	return branches


# Parse `git tag -l` output into [{ name }].
static func parse_tags(text: String) -> Array:
	var tags: Array = []
	for line in split_lines(text):
		tags.append({"name": line.strip_edges()})
	return tags


# Validate a branch/tag name. Returns {"ok": bool, "reason": String};
# reason is "" when ok, otherwise a short human sentence for dialog hints.
# Pragmatic `git check-ref-format --branch` subset: non-empty, no
# whitespace, none of ~ ^ : ? * [ \ and no "..", "@{", leading "-" / "."
# / "/", trailing "/" or ".lock". Covers the mistakes users actually make;
# git itself is the final arbiter and its errors surface through
# operation_complete.
static func validate_branch_name(branch_name: String) -> Dictionary:
	var candidate := String(branch_name)
	if candidate.strip_edges().is_empty():
		return {"ok": false, "reason": "Type a branch name to create it."}
	if candidate != candidate.strip_edges():
		return {"ok": false, "reason": "Branch names cannot start or end with whitespace."}
	for bad in [" ", "\t", "~", "^", ":", "?", "*", "[", "\\", "..", "@{"]:
		if bad in candidate:
			return {"ok": false, "reason": "Branch names cannot contain \"%s\"." % bad}
	if candidate.begins_with("-") or candidate.begins_with(".") or candidate.begins_with("/"):
		return {"ok": false, "reason": "Branch names cannot start with \"-\", \".\" or \"/\"."}
	if candidate.ends_with("/") or candidate.ends_with(".lock"):
		return {"ok": false, "reason": "Branch names cannot end with \"/\" or \".lock\"."}
	return {"ok": true, "reason": ""}


# Boolean form of validate_branch_name for dialog OK-gates.
static func is_valid_ref_name(ref_name: String) -> bool:
	return bool(validate_branch_name(ref_name).get("ok", false))
