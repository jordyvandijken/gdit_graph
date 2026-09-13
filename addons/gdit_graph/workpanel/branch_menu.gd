# Commit context menu (Phase 2: plan sections II row 5, V.8-9;
# Phase 3: branch/tag actions, V.11-12;
# plan section I remainder: cherry-pick + rebase entries).
#
# Right-click menu for graph rows: checkout / merge / cherry-pick / rebase /
# reset-to-here plus copy actions, and (Phase 3) create-branch/tag entries
# plus one submenu per attached local branch (checkout, rename, delete, push to remote).
# Stash/remote management lives in the panel overflow menu; only the
# commit-scoped pieces are here. New actions slot in as extra ids +
# signals.
#
# Usage: the panel connects to the signals once, then calls
# popup_for_commit(commit, current_branch, all_branches, remotes) on
# right-click. The panel (not this menu) performs the git work and the
# destructive confirmations.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/branch_menu.gd").
@tool
extends PopupMenu

signal checkout_requested(ref)
signal merge_requested(ref)
signal reset_requested(commit_hash, mode)
signal cherry_pick_requested(commit_hash)
signal rebase_requested(commit_hash)
signal copy_hash_requested(commit_hash)
signal copy_message_requested(message)
signal create_branch_requested(commit_hash)
signal create_tag_requested(commit_hash)
signal branch_rename_requested(old_name)
signal branch_delete_requested(branch_name)
signal branch_push_requested(branch_name, remote)

const ID_CHECKOUT_COMMIT = 0
const ID_MERGE_COMMIT = 1
const ID_RESET_SOFT = 2
const ID_RESET_MIXED = 3
const ID_RESET_HARD = 4
const ID_CHERRY_PICK = 5
const ID_REBASE = 6
const ID_CREATE_BRANCH = 10
const ID_CREATE_TAG = 11
const ID_CHECKOUT_BRANCH_BASE = 100
const ID_COPY_HASH = 200
const ID_COPY_MESSAGE = 201
# Per-branch submenu ids: SUB_ID_BASE + slot * SUB_SLOT_SIZE + action.
# Actions 0-2 are checkout/rename/delete; 3+ push to remotes[slot][action-3].
const SUB_ID_BASE = 1000
const SUB_SLOT_SIZE = 20
const SUB_CHECKOUT = 0
const SUB_RENAME = 1
const SUB_DELETE = 2
const SUB_PUSH_BASE = 3
const SUB_MAX_PUSH = 5

const MAX_BRANCH_ITEMS = 8
const MAX_BRANCH_SUBMENUS = 3

var _commit = {}
var _branch_refs = []
var _branch_slots = []
var _reset_submenu = null
var _branch_submenus = []


func _ready() -> void:
	id_pressed.connect(_on_id_pressed)
	_reset_submenu = PopupMenu.new()
	_reset_submenu.name = "ResetSubmenu"
	_reset_submenu.id_pressed.connect(_on_id_pressed)
	add_child(_reset_submenu)
	# Pooled per-branch submenus, reused across popups (slots reassigned in
	# popup_for_commit). A fixed pool avoids creating/freeing nodes on
	# every right-click.
	for slot in range(MAX_BRANCH_SUBMENUS):
		var sub := PopupMenu.new()
		sub.name = "BranchSubmenu%d" % slot
		sub.id_pressed.connect(_on_id_pressed)
		add_child(sub)
		_branch_submenus.append(sub)


# all_branches comes from GitRefs.parse_branches (carries the remote
# flag); remotes from parse_remotes (push targets). Both default empty so
# older callers keep working (branch submenus are then skipped).
func popup_for_commit(commit: Dictionary, current_branch: String, all_branches: Array = [], remotes: Array = []) -> void:
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
	add_item("Create branch at this commit...", ID_CREATE_BRANCH)
	add_item("Create tag at this commit...", ID_CREATE_TAG)
	add_separator()
	add_item("Merge %s into '%s'" % [short_hash, current if not current.is_empty() else "current branch"], ID_MERGE_COMMIT)
	add_item("Cherry-pick %s onto '%s'" % [short_hash, current if not current.is_empty() else "current branch"], ID_CHERRY_PICK)
	add_item("Rebase '%s' onto %s" % [current if not current.is_empty() else "current branch", short_hash], ID_REBASE)
	_reset_submenu.add_item("Soft (keep index + worktree)", ID_RESET_SOFT)
	_reset_submenu.add_item("Mixed (keep worktree, default)", ID_RESET_MIXED)
	_reset_submenu.add_item("Hard (discard all changes!)", ID_RESET_HARD)
	add_submenu_item("Reset '%s' to here" % (current if not current.is_empty() else "current branch"), _reset_submenu.name)
	_add_branch_submenus(branches, all_branches, remotes)
	add_separator()
	add_item("Copy commit hash", ID_COPY_HASH)
	add_item("Copy subject", ID_COPY_MESSAGE)
	# Screen-space cursor position (viewport coords would misplace the popup
	# in the embedded editor).
	position = DisplayServer.mouse_get_position()
	popup()


# One submenu per attached LOCAL branch (remote-tracking branches are
# checkout-only via the flat entries above). Branches beyond the pool get
# a disabled overflow note instead of silently vanishing.
func _add_branch_submenus(branches: Array, all_branches: Array, remotes: Array) -> void:
	_branch_slots = []
	for sub in _branch_submenus:
		(sub as PopupMenu).clear()
	var remote_names: Array = []
	for r in remotes:
		var info: Dictionary = r
		var remote_name := String(info.get("name", ""))
		if not remote_name.is_empty() and remote_names.size() < SUB_MAX_PUSH:
			remote_names.append(remote_name)
	var slot := 0
	var skipped := 0
	for branch_name in branches:
		var label := String(branch_name)
		if label.is_empty() or _is_remote_branch(label, all_branches):
			continue
		if slot >= MAX_BRANCH_SUBMENUS:
			skipped += 1
			continue
		_branch_slots.append({"name": label, "remotes": remote_names.duplicate()})
		var sub: PopupMenu = _branch_submenus[slot]
		var base := SUB_ID_BASE + slot * SUB_SLOT_SIZE
		sub.add_item("Checkout '%s'" % label, base + SUB_CHECKOUT)
		sub.add_item("Rename...", base + SUB_RENAME)
		sub.add_item("Delete...", base + SUB_DELETE)
		if remote_names.is_empty():
			sub.add_item("Push (no git remote configured)", base + SUB_PUSH_BASE)
			sub.set_item_disabled(sub.item_count - 1, true)
		else:
			for ri in range(remote_names.size()):
				sub.add_item("Push to '%s'" % String(remote_names[ri]), base + SUB_PUSH_BASE + ri)
		add_submenu_item("Branch '%s'" % label, sub.name)
		slot += 1
	if skipped > 0:
		add_item("(+%d more branches — open their tip commit)" % skipped, -1)
		set_item_disabled(item_count - 1, true)


# all_branches entries look like "main" (local) or "remotes/origin/main".
# Refs arrive shortened ("origin/main"), so both shapes are matched. Names
# missing from the list default to local (git errors clearly if wrong).
func _is_remote_branch(label: String, all_branches: Array) -> bool:
	for b in all_branches:
		var info: Dictionary = b
		var entry := String(info.get("name", ""))
		if entry == label or entry == "remotes/" + label:
			return bool(info.get("remote", false))
	return false


func _on_id_pressed(id: int) -> void:
	var hash_value := String(_commit.get("hash", ""))
	match id:
		ID_CHECKOUT_COMMIT:
			if not hash_value.is_empty():
				checkout_requested.emit(hash_value)
		ID_MERGE_COMMIT:
			if not hash_value.is_empty():
				merge_requested.emit(hash_value)
		ID_CHERRY_PICK:
			if not hash_value.is_empty():
				cherry_pick_requested.emit(hash_value)
		ID_REBASE:
			if not hash_value.is_empty():
				rebase_requested.emit(hash_value)
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
		ID_CREATE_BRANCH:
			if not hash_value.is_empty():
				create_branch_requested.emit(hash_value)
		ID_CREATE_TAG:
			if not hash_value.is_empty():
				create_tag_requested.emit(hash_value)
		_:
			if id >= ID_CHECKOUT_BRANCH_BASE and id < ID_COPY_HASH:
				var branch_idx := id - ID_CHECKOUT_BRANCH_BASE
				if branch_idx >= 0 and branch_idx < _branch_refs.size():
					checkout_requested.emit(String(_branch_refs[branch_idx]))
			elif id >= SUB_ID_BASE:
				_route_submenu_id(id)


func _route_submenu_id(id: int) -> void:
	var slot := (id - SUB_ID_BASE) / SUB_SLOT_SIZE
	var action := (id - SUB_ID_BASE) % SUB_SLOT_SIZE
	if slot < 0 or slot >= _branch_slots.size():
		return
	var slot_info: Dictionary = _branch_slots[slot]
	var branch_name := String(slot_info.get("name", ""))
	if branch_name.is_empty():
		return
	if action == SUB_CHECKOUT:
		checkout_requested.emit(branch_name)
	elif action == SUB_RENAME:
		branch_rename_requested.emit(branch_name)
	elif action == SUB_DELETE:
		branch_delete_requested.emit(branch_name)
	elif action >= SUB_PUSH_BASE:
		var push_targets: Array = slot_info.get("remotes", [])
		var remote_idx := action - SUB_PUSH_BASE
		if remote_idx >= 0 and remote_idx < push_targets.size():
			branch_push_requested.emit(branch_name, String(push_targets[remote_idx]))
