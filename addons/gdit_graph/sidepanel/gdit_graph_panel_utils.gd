# Source Control side-panel helpers.
#
# Pure data functions for the sidepanel dock panel: file-row display (name /
# directory split, status letter and color), status-list splitting (staged
# vs unstaged), context-menu targets, discard path safety, the
# commit-message history ring, and branch-switcher helpers (branch/tag list
# parsing, branch-name sanitize/validate). No git calls and no UI here, so
# this file needs no @tool annotation to be usable from @tool scripts that
# preload it.
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


# Parse `git branch --no-color -a` output into
# [{ name, display, current, remote, detached }]. Symlink lines
# ("remotes/origin/HEAD -> origin/main") carry no commit and are skipped; a
# detached HEAD shows as "* (HEAD detached at ...)". Remote-tracking names
# keep the full "remotes/..." form in `name` while `display` drops the
# "remotes/" prefix for the switcher rows.
static func parse_branch_list(text: String) -> Array:
	var branches: Array = []
	for raw_line in String(text).split("\n"):
		var entry := String(raw_line).trim_suffix("\r").strip_edges()
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
static func parse_tag_list(text: String) -> Array:
	var tags: Array = []
	for raw_line in String(text).split("\n"):
		var tag_name := String(raw_line).trim_suffix("\r").strip_edges()
		if not tag_name.is_empty():
			tags.append({"name": tag_name})
	return tags


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
# -> "my-new-branch"). Anything still illegal (see validate_branch_name)
# is reported, never silently mangled.
static func sanitize_branch_name(raw: String) -> String:
	var candidate := String(raw).strip_edges()
	if candidate.is_empty():
		return ""
	var ws := RegEx.new()
	if ws.compile("\\s+") == OK:
		candidate = ws.sub(candidate, "-", true)
	return candidate


# Validate a (sanitized) branch name. Returns {"ok": bool, "reason": String};
# reason is "" when ok, otherwise a short human sentence for the switcher
# hint. Same check-ref-format subset as the graph tab validator; git itself
# is the final arbiter and its errors surface through operation_complete.
static func validate_branch_name(branch_name: String) -> Dictionary:
	var candidate := String(branch_name)
	if candidate.strip_edges().is_empty():
		return {"ok": false, "reason": "Type a branch name to create it."}
	if candidate != candidate.strip_edges():
		return {"ok": false, "reason": "Branch names cannot start or end with whitespace."}
	for bad in ["~", "^", ":", "?", "*", "[", "\\", "..", "@{"]:
		if bad in candidate:
			return {"ok": false, "reason": "Branch names cannot contain \"%s\"." % bad}
	if candidate.begins_with("-") or candidate.begins_with(".") or candidate.begins_with("/"):
		return {"ok": false, "reason": "Branch names cannot start with \"-\", \".\" or \"/\"."}
	if candidate.ends_with("/") or candidate.ends_with(".lock"):
		return {"ok": false, "reason": "Branch names cannot end with \"/\" or \".lock\"."}
	return {"ok": true, "reason": ""}


# Local name for a remote-tracking ref: "origin/feature/x" -> "feature/x".
static func remote_tracking_local_name(remote_short: String) -> String:
	var cleaned := String(remote_short).strip_edges()
	var slash := cleaned.find("/")
	if slash == -1:
		return cleaned
	return cleaned.substr(slash + 1)
