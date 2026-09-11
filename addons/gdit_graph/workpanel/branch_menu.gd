# Commit context menu (Phase 2: plan sections II row 5, V.8-9).
#
# Right-click menu for graph rows: checkout / merge / reset-to-here plus
# copy actions. Branch/tag/stash management beyond this is Phase 3, so the
# menu stays commit-scoped; new actions slot in as extra ids + signals.
#
# Usage: the panel connects to the signals once, then calls
# popup_for_commit(commit, current_branch) on right-click. The panel (not
# this menu) performs the git work and the destructive confirmations.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/branch_menu.gd").
@tool
extends PopupMenu

signal checkout_requested(ref)
signal merge_requested(ref)
signal reset_requested(commit_hash, mode)
signal copy_hash_requested(commit_hash)
signal copy_message_requested(message)

const ID_CHECKOUT_COMMIT = 0
const ID_MERGE_COMMIT = 1
const ID_RESET_SOFT = 2
const ID_RESET_MIXED = 3
const ID_RESET_HARD = 4
const ID_CHECKOUT_BRANCH_BASE = 100
const ID_COPY_HASH = 200
const ID_COPY_MESSAGE = 201

const MAX_BRANCH_ITEMS = 8

var _commit = {}
var _branch_refs = []
var _reset_submenu = null


func _ready() -> void:
	id_pressed.connect(_on_id_pressed)
	_reset_submenu = PopupMenu.new()
	_reset_submenu.name = "ResetSubmenu"
	_reset_submenu.id_pressed.connect(_on_id_pressed)
	add_child(_reset_submenu)


func popup_for_commit(commit: Dictionary, current_branch: String) -> void:
	_commit = commit
	clear()
	_reset_submenu.clear()
	var short_hash := String(commit.get("short", String(commit.get("hash", ""))))
	var refs: Dictionary = commit.get("refs", {})
	var branches: Array = refs.get("branches", [])
	var current := String(refs.get("current", ""))
	if current.is_empty() and not String(current_branch).is_empty() and String(current_branch) != "-":
		current = String(current_branch)

	add_item("Checkout commit %s (detached)" % short_hash, ID_CHECKOUT_COMMIT)
	# Branches pointing at this commit get direct checkout entries. Refs are
	# kept in a parallel array: item positions shift with separators, so
	# ids (not positions) route the callback (see _on_id_pressed).
	_branch_refs = []
	var listed := 0
	for branch_name in branches:
		if listed >= MAX_BRANCH_ITEMS:
			break
		var label := String(branch_name)
		if label.is_empty() or label == current:
			continue
		_branch_refs.append(label)
		add_item("Checkout branch '%s'" % label, ID_CHECKOUT_BRANCH_BASE + listed)
		listed += 1
	if listed == 0 and not branches.is_empty():
		add_item("Checkout branch (already on '%s')" % current, -1)
		set_item_disabled(item_count - 1, true)
	add_separator()
	add_item("Merge %s into '%s'" % [short_hash, current if not current.is_empty() else "current branch"], ID_MERGE_COMMIT)
	_reset_submenu.add_item("Soft (keep index + worktree)", ID_RESET_SOFT)
	_reset_submenu.add_item("Mixed (keep worktree, default)", ID_RESET_MIXED)
	_reset_submenu.add_item("Hard (discard all changes!)", ID_RESET_HARD)
	add_submenu_item("Reset '%s' to here" % (current if not current.is_empty() else "current branch"), _reset_submenu.name)
	add_separator()
	add_item("Copy commit hash", ID_COPY_HASH)
	add_item("Copy subject", ID_COPY_MESSAGE)
	# Screen-space cursor position (viewport coords would misplace the popup
	# in the embedded editor).
	position = DisplayServer.mouse_get_position()
	popup()


func _on_id_pressed(id: int) -> void:
	var hash_value := String(_commit.get("hash", ""))
	match id:
		ID_CHECKOUT_COMMIT:
			if not hash_value.is_empty():
				checkout_requested.emit(hash_value)
		ID_MERGE_COMMIT:
			if not hash_value.is_empty():
				merge_requested.emit(hash_value)
		ID_RESET_SOFT:
			if not hash_value.is_empty():
				reset_requested.emit(hash_value, "soft")
		ID_RESET_MIXED:
			if not hash_value.is_empty():
				reset_requested.emit(hash_value, "mixed")
		ID_RESET_HARD:
			if not hash_value.is_empty():
				reset_requested.emit(hash_value, "hard")
		ID_COPY_HASH:
			if not hash_value.is_empty():
				copy_hash_requested.emit(hash_value)
		ID_COPY_MESSAGE:
			copy_message_requested.emit(String(_commit.get("subject", "")))
		_:
			if id >= ID_CHECKOUT_BRANCH_BASE and id < ID_COPY_HASH:
				var branch_idx := id - ID_CHECKOUT_BRANCH_BASE
				if branch_idx >= 0 and branch_idx < _branch_refs.size():
					checkout_requested.emit(String(_branch_refs[branch_idx]))
