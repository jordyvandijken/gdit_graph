# Code review tracking (Phase 4: plan sections III.B, V.18).
#
# Pure state helpers: which files of a commit the user marked reviewed.
# Persisted in ProjectSettings under a single dict key (plan's "persist in
# project settings"), so the state travels with the project. No git calls,
# no UI — commit_details.gd renders the badges, graph_panel.gd wires the
# toggle signal.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/code_review.gd").
extends RefCounted

const REVIEWS_SETTING = "gdit_graph/code_reviews"


static func _load_all() -> Dictionary:
	if not ProjectSettings.has_setting(REVIEWS_SETTING):
		return {}
	var stored = ProjectSettings.get_setting(REVIEWS_SETTING, {})
	if stored is Dictionary:
		return (stored as Dictionary).duplicate(true)
	return {}


static func _save_all(all: Dictionary) -> void:
	ProjectSettings.set_setting(REVIEWS_SETTING, all)


static func _norm_hash(commit_hash: String) -> String:
	return String(commit_hash).strip_edges()


static func is_reviewed(commit_hash: String, path: String) -> bool:
	var key := _norm_hash(commit_hash)
	var target := String(path).strip_edges()
	if key.is_empty() or target.is_empty():
		return false
	var all := _load_all()
	if not all.has(key):
		return false
	var entry = all[key]
	if entry is Dictionary:
		return bool((entry as Dictionary).get(target, false))
	return false


static func set_reviewed(commit_hash: String, path: String, reviewed: bool) -> void:
	var key := _norm_hash(commit_hash)
	var target := String(path).strip_edges()
	if key.is_empty() or target.is_empty():
		return
	var all := _load_all()
	var entry: Dictionary = {}
	if all.has(key) and all[key] is Dictionary:
		entry = (all[key] as Dictionary).duplicate()
	if reviewed:
		entry[target] = true
	else:
		entry.erase(target)
	if entry.is_empty():
		all.erase(key)
	else:
		all[key] = entry
	_save_all(all)


static func reviewed_paths(commit_hash: String) -> Array:
	var key := _norm_hash(commit_hash)
	var out: Array = []
	if key.is_empty():
		return out
	var all := _load_all()
	if all.has(key) and all[key] is Dictionary:
		for path in (all[key] as Dictionary).keys():
			out.append(String(path))
	return out


# Files in `files` (name-status entries) not yet marked reviewed.
static func pending_paths(commit_hash: String, files: Array) -> Array:
	var done := {}
	for p in reviewed_paths(commit_hash):
		done[p] = true
	var pending: Array = []
	for f in files:
		var path := String((f as Dictionary).get("path", ""))
		if not path.is_empty() and not done.has(path):
			pending.append(path)
	return pending


static func pending_count(commit_hash: String, files: Array) -> int:
	return pending_paths(commit_hash, files).size()


static func clear_commit(commit_hash: String) -> void:
	var key := _norm_hash(commit_hash)
	if key.is_empty():
		return
	var all := _load_all()
	if all.has(key):
		all.erase(key)
		_save_all(all)
