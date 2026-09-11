# Git Graph main-screen tab content (Phase 1 MVP: plan sections II rows
# 1-2+6, V phase 1; Phase 2: commit details + context actions, V phase 2;
# Phase 3: branch/tag/stash/remote management, V phase 3).
#
# Hosted by plugin.gd in a MarginContainer under the editor main screen
# (top row, like Asset Store / Tasks), so this panel is always laid out at
# tab size. Toolbar (title, Fetch, Refresh, overflow menu) + branch filter,
# the graph_renderer.gd canvas in a ScrollContainer, an expandable
# commit_details.gd section, a Load-more pager, and a status/branch row.
# Click-to-select loads details (files + inline diff); right-click opens
# the branch_menu.gd context menu (checkout / merge / reset / copy, plus
# branch/tag creation and per-branch actions). The overflow (⋯) menu hosts
# stash, tag, and remote management plus pull/push. Find, settings, and
# comparison are Phase 4+ and deliberately absent here.
#
# Owns no threads: all git work runs on the GraphManager worker thread and
# arrives via signals. Never touch UI from the thread.
#
# No class_name (repo convention): instantiated from graph_panel.tscn.
@tool
extends VBoxContainer

const GraphManagerScript = preload("res://addons/gdit_graph/workpanel/graph_manager.gd")
const GraphRendererScript = preload("res://addons/gdit_graph/workpanel/graph_renderer.gd")
const CommitDetailsScript = preload("res://addons/gdit_graph/workpanel/commit_details.gd")
const BranchMenuScript = preload("res://addons/gdit_graph/workpanel/branch_menu.gd")
const GraphDialogsScript = preload("res://addons/gdit_graph/workpanel/graph_dialogs.gd")

# Overflow (⋯) menu item ids. Dynamic sub-item ids encode cache indices;
# routing bounds-checks against the caches (see _on_overflow_id).
const OV_PULL = 1
const OV_PUSH_FIRST = 2
const OV_STASH_PUSH = 3
const OV_TAG_CREATE = 4
const OV_PUSH_BASE = 100
const OV_STASH_APPLY_BASE = 1000
const OV_STASH_POP_BASE = 2000
const OV_STASH_DROP_BASE = 3000
const OV_TAG_CHECKOUT_BASE = 4000
const OV_TAG_DELETE_BASE = 5000
const OV_TAG_PUSH_BASE = 6000
const OV_TAG_PUSH_STRIDE = 10
const OV_REMOTE_FETCH_BASE = 7000
const OV_REMOTE_PRUNE_BASE = 8000
const OV_LIST_CAP = 20
const OV_MAX_TAG_PUSH_REMOTES = 5

const PAGE_LIMIT = 200

var git_manager = null
var _owns_git_manager = false
var _ui_built = false

var _commits = []
var _branches = []
var _head_hash = ""
var _offset = 0
var _loading = false
var _loading_more = false
var _scroll_to_head_pending = false
var _needs_refresh = false
var _current_rev = ""

var title_label = null
var fetch_button = null
var refresh_button = null
var overflow_button = null
var overflow_menu = null
var branch_filter = null
var scroll = null
var renderer = null
var empty_label = null
var load_more_button = null
var details_sep = null
var details_header = null
var details_toggle = null
var details_title = null
var details = null
var commit_menu = null
var confirm_dialog = null
var branch_dialog = null
var rename_dialog = null
var tag_dialog = null
var stash_dialog = null
var status_label = null
var branch_label = null
var _repo_ui = []
var _refresh_debounce = null
var _details_hash = ""
var _diff_path = ""
var _details_collapsed = true
# Generalized destructive-action confirmation: {"kind", ...fields} where
# kind is reset_hard | stash_drop | branch_delete | tag_delete.
var _pending_confirm = {}
var _pending_target_hash = ""
var _pending_branch_old = ""
var _tags = []
var _stashes = []
var _remotes = []
var _pending_tags = []
var _pending_stashes = []
var _pending_remotes = []
var _overflow_nodes = []
var _overflow_build = 0


func set_git_manager(manager) -> void:
	if git_manager == manager:
		return
	_disconnect_git_manager()
	if _owns_git_manager and git_manager != null and git_manager.has_method("shutdown"):
		git_manager.shutdown()
	git_manager = manager
	_owns_git_manager = false
	if _ui_built and git_manager != null:
		_connect_git_manager()
		_check_git()
		if git_manager.is_repo():
			refresh()


func _ensure_git_manager() -> void:
	if git_manager != null:
		return
	var fallback = GraphManagerScript.new()
	fallback.set_repo_path(ProjectSettings.globalize_path("res://"))
	git_manager = fallback
	_owns_git_manager = true
	push_warning("Git Graph: git_manager not assigned, using fallback manager.")


func _connect_git_manager() -> void:
	if git_manager == null:
		return
	if not git_manager.log_loaded.is_connected(_on_log_loaded):
		git_manager.log_loaded.connect(_on_log_loaded)
	if not git_manager.branches_loaded.is_connected(_on_branches_loaded):
		git_manager.branches_loaded.connect(_on_branches_loaded)
	if not git_manager.head_loaded.is_connected(_on_head_loaded):
		git_manager.head_loaded.connect(_on_head_loaded)
	if not git_manager.commit_details_loaded.is_connected(_on_commit_details_loaded):
		git_manager.commit_details_loaded.connect(_on_commit_details_loaded)
	if not git_manager.commit_diff_loaded.is_connected(_on_commit_diff_loaded):
		git_manager.commit_diff_loaded.connect(_on_commit_diff_loaded)
	if not git_manager.tags_loaded.is_connected(_on_tags_loaded):
		git_manager.tags_loaded.connect(_on_tags_loaded)
	if not git_manager.stashes_loaded.is_connected(_on_stashes_loaded):
		git_manager.stashes_loaded.connect(_on_stashes_loaded)
	if not git_manager.remotes_loaded.is_connected(_on_remotes_loaded):
		git_manager.remotes_loaded.connect(_on_remotes_loaded)
	if not git_manager.operation_complete.is_connected(_on_operation_complete):
		git_manager.operation_complete.connect(_on_operation_complete)


func _disconnect_git_manager() -> void:
	if git_manager == null:
		return
	if git_manager.log_loaded.is_connected(_on_log_loaded):
		git_manager.log_loaded.disconnect(_on_log_loaded)
	if git_manager.branches_loaded.is_connected(_on_branches_loaded):
		git_manager.branches_loaded.disconnect(_on_branches_loaded)
	if git_manager.head_loaded.is_connected(_on_head_loaded):
		git_manager.head_loaded.disconnect(_on_head_loaded)
	if git_manager.commit_details_loaded.is_connected(_on_commit_details_loaded):
		git_manager.commit_details_loaded.disconnect(_on_commit_details_loaded)
	if git_manager.commit_diff_loaded.is_connected(_on_commit_diff_loaded):
		git_manager.commit_diff_loaded.disconnect(_on_commit_diff_loaded)
	if git_manager.tags_loaded.is_connected(_on_tags_loaded):
		git_manager.tags_loaded.disconnect(_on_tags_loaded)
	if git_manager.stashes_loaded.is_connected(_on_stashes_loaded):
		git_manager.stashes_loaded.disconnect(_on_stashes_loaded)
	if git_manager.remotes_loaded.is_connected(_on_remotes_loaded):
		git_manager.remotes_loaded.disconnect(_on_remotes_loaded)
	if git_manager.operation_complete.is_connected(_on_operation_complete):
		git_manager.operation_complete.disconnect(_on_operation_complete)


func _connect_filesystem_signals() -> void:
	if not Engine.is_editor_hint():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.connect(_on_filesystem_changed)


func _disconnect_filesystem_signals() -> void:
	if not Engine.is_editor_hint():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	if fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.disconnect(_on_filesystem_changed)


func _ready() -> void:
	_build_ui()
	_ui_built = true
	_ensure_git_manager()
	_connect_git_manager()
	_connect_filesystem_signals()
	_check_git()
	if git_manager != null and git_manager.is_repo():
		refresh()


func _exit_tree() -> void:
	_disconnect_filesystem_signals()
	_disconnect_git_manager()
	if _owns_git_manager and git_manager != null and git_manager.has_method("shutdown"):
		git_manager.shutdown()
		git_manager = null
		_owns_git_manager = false


func _enter_tree() -> void:
	_connect_git_manager()
	_connect_filesystem_signals()
	_check_git()
	if _ui_built and git_manager != null and git_manager.is_repo() and _commits.is_empty() and not _loading:
		refresh()


func _make_toolbar_button(button_name: String, glyph: String, tip: String) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = glyph
	button.tooltip_text = tip
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	return button


func _build_ui() -> void:
	var toolbar := HBoxContainer.new()
	toolbar.name = "GraphToolbar"
	title_label = Label.new()
	title_label.name = "GraphTitle"
	title_label.text = "Git Graph"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_size_override("font_size", 13)
	toolbar.add_child(title_label)
	fetch_button = _make_toolbar_button("GraphFetchButton", "⇄", "Fetch from remote")
	fetch_button.pressed.connect(_on_fetch)
	toolbar.add_child(fetch_button)
	refresh_button = _make_toolbar_button("GraphRefreshButton", "↻", "Refresh graph")
	refresh_button.pressed.connect(_on_refresh_button)
	toolbar.add_child(refresh_button)
	overflow_button = _make_toolbar_button("GraphOverflowButton", "⋯", "More actions (stash, tags, remotes, pull/push)")
	overflow_button.pressed.connect(_on_overflow_pressed)
	toolbar.add_child(overflow_button)
	overflow_menu = PopupMenu.new()
	overflow_menu.name = "GraphOverflowMenu"
	overflow_menu.about_to_popup.connect(_on_overflow_about_to_popup)
	overflow_menu.id_pressed.connect(_on_overflow_id)
	overflow_button.add_child(overflow_menu)
	add_child(toolbar)
	# The toolbar stays visible even without a repo (Refresh re-checks),
	# so it is not part of _repo_ui.

	var filter_row := HBoxContainer.new()
	filter_row.name = "GraphFilterRow"
	filter_row.add_theme_constant_override("separation", 6)
	var filter_label := Label.new()
	filter_label.name = "GraphFilterLabel"
	filter_label.text = "Branch:"
	filter_row.add_child(filter_label)
	branch_filter = OptionButton.new()
	branch_filter.name = "GraphBranchFilter"
	branch_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	branch_filter.clip_text = true
	branch_filter.item_selected.connect(_on_branch_filter_selected)
	filter_row.add_child(branch_filter)
	add_child(filter_row)
	_repo_ui.append(filter_row)

	scroll = ScrollContainer.new()
	scroll.name = "GraphScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 3.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_repo_ui.append(scroll)
	renderer = GraphRendererScript.new()
	renderer.name = "GraphCanvas"
	renderer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	renderer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	renderer.commit_selected.connect(_on_commit_selected)
	renderer.commit_context_requested.connect(_on_commit_context)
	scroll.add_child(renderer)

	# Inline empty state (centered message) for non-repos: a main-screen tab
	# cannot collapse like a dock, so the message replaces the graph area
	# instead of hiding the whole panel.
	empty_label = Label.new()
	empty_label.name = "GraphEmptyLabel"
	empty_label.text = "Not a Git repository."
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	empty_label.add_theme_font_size_override("font_size", 14)
	empty_label.add_theme_color_override("font_color", Color.GRAY)
	empty_label.visible = false
	add_child(empty_label)

	load_more_button = Button.new()
	load_more_button.name = "GraphLoadMore"
	load_more_button.text = "Load more"
	load_more_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_more_button.visible = false
	load_more_button.pressed.connect(_on_load_more)
	add_child(load_more_button)
	# Not in _repo_ui: _check_git shows every repo row, but Load-more is
	# only visible when a full page arrived (see _on_log_loaded).

	# --- Commit details section (Phase 2): expandable, shares vertical
	# space with the graph canvas. Hidden until the first selection so the
	# graph gets full height on open.
	details_sep = HSeparator.new()
	details_sep.name = "GraphDetailsSeparator"
	add_child(details_sep)
	_repo_ui.append(details_sep)
	details_header = HBoxContainer.new()
	details_header.name = "GraphDetailsHeader"
	details_toggle = _make_toolbar_button("GraphDetailsToggle", "▸", "Collapse section")
	details_toggle.pressed.connect(_on_toggle_details)
	details_header.add_child(details_toggle)
	details_title = Label.new()
	details_title.name = "GraphDetailsTitle"
	details_title.text = "Commit Details"
	details_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_header.add_child(details_title)
	add_child(details_header)
	_repo_ui.append(details_header)
	details = CommitDetailsScript.new()
	details.name = "GraphDetails"
	details.custom_minimum_size = Vector2(0, 220)
	details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details.size_flags_stretch_ratio = 2.0
	details.visible = false
	details.file_selected.connect(_on_details_file_selected)
	details.open_file_requested.connect(_on_open_file_requested)
	details.copy_path_requested.connect(_on_copy_path_requested)
	add_child(details)
	commit_menu = BranchMenuScript.new()
	commit_menu.name = "GraphCommitMenu"
	commit_menu.checkout_requested.connect(_on_menu_checkout)
	commit_menu.merge_requested.connect(_on_menu_merge)
	commit_menu.reset_requested.connect(_on_menu_reset)
	commit_menu.copy_hash_requested.connect(_on_menu_copy_hash)
	commit_menu.copy_message_requested.connect(_on_menu_copy_message)
	commit_menu.create_branch_requested.connect(_on_menu_create_branch)
	commit_menu.create_tag_requested.connect(_on_menu_create_tag)
	commit_menu.branch_rename_requested.connect(_on_menu_branch_rename)
	commit_menu.branch_delete_requested.connect(_on_menu_branch_delete)
	commit_menu.branch_push_requested.connect(_on_menu_branch_push)
	add_child(commit_menu)
	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.name = "GraphConfirmDialog"
	confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	add_child(confirm_dialog)
	branch_dialog = GraphDialogsScript.make_branch_dialog()
	branch_dialog.name = "GraphBranchDialog"
	branch_dialog.confirmed.connect(_on_branch_dialog_confirmed)
	add_child(branch_dialog)
	rename_dialog = GraphDialogsScript.make_rename_dialog()
	rename_dialog.name = "GraphRenameDialog"
	rename_dialog.confirmed.connect(_on_rename_dialog_confirmed)
	add_child(rename_dialog)
	tag_dialog = GraphDialogsScript.make_tag_dialog()
	tag_dialog.name = "GraphTagDialog"
	tag_dialog.confirmed.connect(_on_tag_dialog_confirmed)
	add_child(tag_dialog)
	stash_dialog = GraphDialogsScript.make_stash_dialog()
	stash_dialog.name = "GraphStashDialog"
	stash_dialog.confirmed.connect(_on_stash_dialog_confirmed)
	add_child(stash_dialog)

	var sep := HSeparator.new()
	sep.name = "GraphSeparator"
	add_child(sep)
	status_label = Label.new()
	status_label.name = "GraphStatus"
	status_label.text = "Ready"
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.add_theme_color_override("font_color", Color.GRAY)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(status_label)
	var branch_row := HBoxContainer.new()
	branch_row.name = "GraphBranchRow"
	branch_label = Label.new()
	branch_label.name = "GraphBranchLabel"
	branch_label.text = "-"
	branch_label.add_theme_font_size_override("font_size", 13)
	branch_row.add_child(branch_label)
	add_child(branch_row)

	_refresh_debounce = Timer.new()
	_refresh_debounce.name = "GraphRefreshDebounce"
	_refresh_debounce.wait_time = 0.5
	_refresh_debounce.one_shot = true
	_refresh_debounce.timeout.connect(_on_refresh_debounce_timeout)
	add_child(_refresh_debounce)
	visibility_changed.connect(_on_visibility_changed)


func _check_git() -> void:
	if git_manager == null:
		return
	if status_label == null or branch_label == null:
		return
	if not git_manager.is_git_available():
		branch_label.text = "-"
		_set_status("Git not found. Please install Git.", true)
		_set_repo_ui_visible(false)
		load_more_button.visible = false
		_set_empty_text("Git not found. Please install Git.")
		return
	if not git_manager.is_repo():
		branch_label.text = "-"
		_set_status("Not a Git repository.", false)
		_set_repo_ui_visible(false)
		load_more_button.visible = false
		_set_empty_text("Not a Git repository.")
		return
	branch_label.text = git_manager.get_branch()
	_set_repo_ui_visible(true)


func _set_empty_text(text: String) -> void:
	if empty_label != null and is_instance_valid(empty_label):
		(empty_label as Label).text = text


func _set_repo_ui_visible(visible: bool) -> void:
	for control in _repo_ui:
		if is_instance_valid(control):
			(control as Control).visible = visible
	if not visible and load_more_button != null and is_instance_valid(load_more_button):
		load_more_button.visible = false
	if empty_label != null and is_instance_valid(empty_label):
		empty_label.visible = not visible
	_apply_details_visibility()


func _apply_details_visibility() -> void:
	if details == null or not is_instance_valid(details):
		return
	# The header row follows repo gating; the body additionally follows the
	# collapse toggle (see _on_toggle_details / _on_commit_selected).
	details.visible = details_header.visible and not _details_collapsed
	if details_toggle != null and is_instance_valid(details_toggle):
		details_toggle.text = "▸" if _details_collapsed else "▾"


func _on_toggle_details() -> void:
	_details_collapsed = not _details_collapsed
	_apply_details_visibility()


func _set_status(text: String, is_error: bool) -> void:
	if status_label == null:
		return
	status_label.text = text
	if is_error:
		status_label.add_theme_color_override("font_color", Color.RED)
	else:
		status_label.add_theme_color_override("font_color", Color.GRAY)


func _set_busy(busy: bool) -> void:
	_loading = busy
	if refresh_button != null:
		refresh_button.disabled = busy
	if fetch_button != null:
		fetch_button.disabled = busy


# Full reload: first page of the log plus branches, HEAD, and the Phase 3
# auxiliary lists (tags/stashes/remotes feed the overflow menu and the
# row-menu branch submenus). All are fast local reads on the one worker
# thread; details/diff loads are never triggered from here.
func refresh() -> void:
	if git_manager == null:
		return
	_check_git()
	if not git_manager.is_repo():
		return
	_offset = 0
	_loading_more = false
	_scroll_to_head_pending = true
	_set_busy(true)
	_set_status("Loading commits...", false)
	git_manager.get_log(PAGE_LIMIT, 0, _current_rev)
	git_manager.get_branches(true)
	git_manager.get_head()
	git_manager.get_tags()
	git_manager.get_stashes()
	git_manager.get_remotes()


func _on_refresh_button() -> void:
	refresh()


func _on_refresh_debounce_timeout() -> void:
	if visible and git_manager != null and git_manager.is_repo() and not _loading:
		_needs_refresh = false
		refresh()


func _on_visibility_changed() -> void:
	if visible and _needs_refresh and git_manager != null and git_manager.is_repo() and not _loading:
		_needs_refresh = false
		refresh()


func _on_filesystem_changed() -> void:
	_needs_refresh = true
	if _refresh_debounce != null and is_instance_valid(_refresh_debounce):
		_refresh_debounce.start()


func _on_load_more() -> void:
	if git_manager == null or _loading:
		return
	_loading_more = true
	_set_busy(true)
	_set_status("Loading more commits...", false)
	git_manager.get_log(PAGE_LIMIT, _offset, _current_rev)


func _on_fetch() -> void:
	if git_manager == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	if not git_manager.has_remote():
		_set_status("Error: no git remote configured.", true)
		return
	_set_busy(true)
	_set_status("Fetching...", false)
	git_manager.fetch()


func _on_branch_filter_selected(index: int) -> void:
	if branch_filter == null:
		return
	var label: String = branch_filter.get_item_text(index)
	if index == 0:
		_current_rev = ""
	else:
		_current_rev = _rev_for_branch_label(label)
	refresh()


# The filter shows display names; map back to something `git log` accepts.
func _rev_for_branch_label(label: String) -> String:
	for b in _branches:
		var info: Dictionary = b
		if String(info.get("name", "")) == label:
			if bool(info.get("detached", false)):
				return "HEAD"
			return label
	return label


func _on_log_loaded(commits: Array) -> void:
	if _loading_more:
		_commits.append_array(commits)
	else:
		_commits = commits
	_offset = _commits.size()
	_loading_more = false
	_renderer_commit_list()
	_set_busy(false)
	load_more_button.visible = commits.size() >= PAGE_LIMIT
	if _commits.is_empty():
		_set_status("No commits yet.", false)
	else:
		_set_status("Loaded %d commits." % _commits.size(), false)
	if _scroll_to_head_pending:
		_try_scroll_to_head()


func _renderer_commit_list() -> void:
	if renderer != null and is_instance_valid(renderer):
		renderer.set_commits(_commits)
		renderer.set_head(_head_hash)


func _on_branches_loaded(branches: Array) -> void:
	_branches = branches
	_rebuild_branch_filter()


# Auxiliary lists arrive via signals but only commit to the caches on the
# matching operation_complete success: a failed load emits an empty list,
# which must not wipe a good cache (e.g. a transient git lock hiccup).
func _on_tags_loaded(tags: Array) -> void:
	_pending_tags = tags


func _on_stashes_loaded(stashes: Array) -> void:
	_pending_stashes = stashes


func _on_remotes_loaded(remotes: Array) -> void:
	_pending_remotes = remotes


func _rebuild_branch_filter() -> void:
	if branch_filter == null:
		return
	var previous := ""
	if branch_filter.item_count > 0 and branch_filter.selected >= 0:
		previous = branch_filter.get_item_text(branch_filter.selected)
	branch_filter.clear()
	branch_filter.add_item("All branches")
	var select := 0
	var found := previous.is_empty() or previous == "All branches"
	for b in _branches:
		var info: Dictionary = b
		var label := String(info.get("name", ""))
		if label.is_empty():
			continue
		branch_filter.add_item(label)
		if label == previous:
			select = branch_filter.item_count - 1
			found = true
	if not found:
		# Previously selected branch is gone (deleted upstream): fall back
		# to All instead of keeping a rev that would fail the next load.
		_current_rev = ""
		select = 0
	branch_filter.selected = select


func _on_head_loaded(hash_value: String) -> void:
	_head_hash = String(hash_value)
	if renderer != null and is_instance_valid(renderer):
		renderer.set_head(_head_hash)
	if _scroll_to_head_pending:
		_try_scroll_to_head()


func _try_scroll_to_head() -> void:
	if _head_hash.is_empty() or renderer == null or not is_instance_valid(renderer):
		return
	if not is_instance_valid(scroll) or _commits.is_empty():
		return
	_scroll_to_head_pending = false
	await get_tree().process_frame
	if not is_instance_valid(scroll) or not is_instance_valid(renderer):
		return
	var idx: int = renderer.index_of_hash(_head_hash)
	if idx == -1:
		return
	var view_h := maxf(scroll.size.y - 8.0, renderer.ROW_H * 3.0)
	scroll.scroll_vertical = maxi(0, int(renderer.row_y(idx) - view_h * 0.5 + renderer.ROW_H * 0.5))


func _on_commit_selected(commit: Dictionary) -> void:
	_details_hash = String(commit.get("hash", ""))
	_diff_path = ""
	_set_status(
		"%s  %s — %s, %s" % [
			String(commit.get("short", "")),
			String(commit.get("subject", "")),
			String(commit.get("author", "")),
			String(commit.get("date", "")),
		],
		false
	)
	# First selection opens the details section; later selections reuse it.
	_details_collapsed = false
	_apply_details_visibility()
	if details_title != null and is_instance_valid(details_title):
		details_title.text = "Commit Details — %s" % String(commit.get("short", ""))
	if details != null and is_instance_valid(details):
		details.show_commit(commit)
	if git_manager != null and not _details_hash.is_empty():
		git_manager.get_commit_details(_details_hash)


func _on_commit_details_loaded(loaded: Dictionary) -> void:
	if details == null or not is_instance_valid(details):
		return
	# Stale guard: the user may have clicked elsewhere while this was loading.
	if String(loaded.get("hash", "")) != _details_hash:
		return
	details.show_details(loaded)
	# The details view auto-selects its first file, which fires
	# file_selected and drives the first diff load (see
	# _on_details_file_selected).


func _on_details_file_selected(path: String) -> void:
	if git_manager == null or _details_hash.is_empty():
		return
	_diff_path = String(path)
	git_manager.get_commit_diff(_details_hash, _diff_path)


func _on_commit_diff_loaded(result: Dictionary) -> void:
	if details == null or not is_instance_valid(details):
		return
	if String(result.get("hash", "")) != _details_hash:
		return
	if String(result.get("path", "")) != _diff_path:
		return
	details.diff_view.set_diff(String(result.get("diff", "")), bool(result.get("truncated", false)))


func _on_commit_context(commit: Dictionary) -> void:
	if commit_menu == null or not is_instance_valid(commit_menu):
		return
	var current := "-"
	if branch_label != null and is_instance_valid(branch_label):
		current = branch_label.text
	commit_menu.popup_for_commit(commit, current, _branches, _remotes)


# --- Phase 2 context-menu actions ---

func _on_menu_checkout(ref: String) -> void:
	if git_manager == null:
		return
	_set_busy(true)
	_set_status("Checking out %s..." % ref, false)
	git_manager.checkout_ref(ref)


func _on_menu_merge(ref: String) -> void:
	if git_manager == null:
		return
	_set_busy(true)
	_set_status("Merging %s..." % ref, false)
	git_manager.merge_ref(ref)


func _on_menu_reset(commit_hash: String, mode: String) -> void:
	if git_manager == null:
		return
	if String(mode) == "hard":
		# Hard reset discards index + worktree changes: confirm first, like
		# the side panel's discard dialog. Soft/mixed keep the worktree.
		_ask_confirm("reset_hard", "Hard-reset the current branch to %s? Index and working-tree changes will be lost. This cannot be undone." % commit_hash.left(8), {"hash": commit_hash, "mode": mode})
		return
	_do_reset(commit_hash, mode)


# Shared destructive-action confirmation. Stores the pending payload and
# shows the dialog; _on_confirm_dialog_confirmed routes by kind.
func _ask_confirm(kind: String, prompt: String, fields: Dictionary) -> void:
	_pending_confirm = {"kind": kind}
	for key in fields:
		_pending_confirm[key] = fields[key]
	if confirm_dialog != null and is_instance_valid(confirm_dialog):
		confirm_dialog.dialog_text = prompt
		confirm_dialog.popup_centered()


func _on_confirm_dialog_confirmed() -> void:
	if _pending_confirm.is_empty() or git_manager == null:
		return
	var pending: Dictionary = _pending_confirm
	_pending_confirm = {}
	match String(pending.get("kind", "")):
		"reset_hard":
			_do_reset(String(pending.get("hash", "")), String(pending.get("mode", "mixed")))
		"stash_drop":
			_do_stash_drop(int(pending.get("index", 0)))
		"branch_delete":
			_do_branch_delete(String(pending.get("name", "")))
		"tag_delete":
			_do_tag_delete(String(pending.get("name", "")))


func _do_reset(commit_hash: String, mode: String) -> void:
	if commit_hash.is_empty():
		return
	_set_busy(true)
	_set_status("Resetting (%s) to %s..." % [mode, commit_hash.left(8)], false)
	git_manager.reset_ref(commit_hash, mode)


# --- Phase 3 row-menu actions (branch/tag) ---

func _on_menu_create_branch(commit_hash: String) -> void:
	if git_manager == null or String(commit_hash).is_empty():
		return
	_pending_target_hash = String(commit_hash)
	if branch_dialog != null and is_instance_valid(branch_dialog):
		GraphDialogsScript.clear_inputs(branch_dialog)
		branch_dialog.popup_centered()


func _on_branch_dialog_confirmed() -> void:
	if git_manager == null or branch_dialog == null or _pending_target_hash.is_empty():
		return
	var ref_name := GraphDialogsScript.line_text(branch_dialog, "DialogInput")
	if ref_name.is_empty():
		return
	_set_busy(true)
	_set_status("Creating branch '%s'..." % ref_name, false)
	git_manager.create_branch(ref_name, _pending_target_hash)


func _on_menu_create_tag(commit_hash: String) -> void:
	if git_manager == null or String(commit_hash).is_empty():
		return
	_pending_target_hash = String(commit_hash)
	_open_tag_dialog()


func _open_tag_dialog() -> void:
	if tag_dialog != null and is_instance_valid(tag_dialog):
		GraphDialogsScript.clear_inputs(tag_dialog)
		tag_dialog.popup_centered()


func _on_tag_dialog_confirmed() -> void:
	if git_manager == null or tag_dialog == null or _pending_target_hash.is_empty():
		return
	var ref_name := GraphDialogsScript.line_text(tag_dialog, "DialogInput")
	if ref_name.is_empty():
		return
	var annotated := GraphDialogsScript.checked(tag_dialog, "DialogCheck")
	var note := GraphDialogsScript.line_text(tag_dialog, "DialogMessage")
	_set_busy(true)
	_set_status("Creating tag '%s'..." % ref_name, false)
	git_manager.create_tag(ref_name, _pending_target_hash, annotated, note)


func _on_menu_branch_rename(old_name: String) -> void:
	if git_manager == null or String(old_name).is_empty():
		return
	_pending_branch_old = String(old_name)
	if rename_dialog != null and is_instance_valid(rename_dialog):
		GraphDialogsScript.clear_inputs(rename_dialog)
		rename_dialog.dialog_text = "Rename branch '%s' to:" % _pending_branch_old
		rename_dialog.popup_centered()


func _on_rename_dialog_confirmed() -> void:
	if git_manager == null or rename_dialog == null or _pending_branch_old.is_empty():
		return
	var new_name := GraphDialogsScript.line_text(rename_dialog, "DialogInput")
	if new_name.is_empty() or new_name == _pending_branch_old:
		return
	_set_busy(true)
	_set_status("Renaming branch '%s'..." % _pending_branch_old, false)
	git_manager.rename_branch(_pending_branch_old, new_name)


func _on_menu_branch_delete(branch_name: String) -> void:
	if git_manager == null or String(branch_name).is_empty():
		return
	# Safe delete (-d) refuses unmerged branches inside git; the confirm
	# here guards the ref removal itself (recoverable via reflog, but
	# annoying to lose).
	_ask_confirm("branch_delete", "Delete branch '%s'? Commits reachable only from it become harder to find." % branch_name, {"name": String(branch_name)})


func _do_branch_delete(branch_name: String) -> void:
	if branch_name.is_empty():
		return
	_set_busy(true)
	_set_status("Deleting branch '%s'..." % branch_name, false)
	git_manager.delete_branch(branch_name)


func _on_menu_branch_push(branch_name: String, remote: String) -> void:
	if git_manager == null:
		return
	if String(branch_name).is_empty() or String(remote).is_empty():
		return
	_set_busy(true)
	_set_status("Pushing '%s' to '%s'..." % [branch_name, remote], false)
	git_manager.push_ref(branch_name, remote)


func _do_tag_delete(tag_name: String) -> void:
	if tag_name.is_empty():
		return
	_set_busy(true)
	_set_status("Deleting tag '%s'..." % tag_name, false)
	git_manager.delete_tag(tag_name)


func _do_stash_drop(index: int) -> void:
	_set_busy(true)
	_set_status("Dropping stash@{%d}..." % maxi(index, 0), false)
	git_manager.stash_drop(index)


func _on_menu_copy_hash(commit_hash: String) -> void:
	DisplayServer.clipboard_set(String(commit_hash))
	_set_status("Copied commit hash.", false)


func _on_menu_copy_message(message: String) -> void:
	DisplayServer.clipboard_set(String(message))
	_set_status("Copied commit subject.", false)


func _on_open_file_requested(repo_path: String) -> void:
	if String(repo_path).is_empty() or not Engine.is_editor_hint():
		return
	# The file is opened at its worktree state (like the side panel): when
	# the selected commit is old, the content may differ from the diff.
	var res_path := "res://" + String(repo_path)
	if ResourceLoader.exists(res_path):
		var res := ResourceLoader.load(res_path)
		if res != null:
			EditorInterface.edit_resource(res)
			return
	EditorInterface.get_file_system_dock().navigate_to_path(res_path)


func _on_copy_path_requested(repo_path: String) -> void:
	DisplayServer.clipboard_set(String(repo_path))
	_set_status("Copied path: %s" % repo_path, false)


# Checkout/merge/reset rewrite files on disk, but open editor tabs keep
# stale in-memory text until a rescan. Reload the tabs AND rescan so the
# new content shows immediately (mirrors the side panel helper).
func _reload_editor_after_disk_change() -> void:
	if not Engine.is_editor_hint():
		return
	var se := EditorInterface.get_script_editor()
	if se != null:
		se.reload_open_files()
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null or fs.is_scanning():
		return
	fs.scan()


# --- Phase 3 overflow (⋯) menu: pull/push, stash, tags, remotes ---

func _remote_names() -> Array:
	var names: Array = []
	for r in _remotes:
		var info: Dictionary = r
		var remote_name := String(info.get("name", ""))
		if not remote_name.is_empty() and not names.has(remote_name):
			names.append(remote_name)
	return names


func _current_branch_name() -> String:
	if branch_label != null and is_instance_valid(branch_label):
		return String(branch_label.text)
	return "-"


func _on_overflow_pressed() -> void:
	if overflow_menu == null or not is_instance_valid(overflow_menu):
		return
	overflow_menu.position = DisplayServer.mouse_get_position()
	overflow_menu.popup()


# Rebuilt on every open from the refresh caches (cheap, synchronous — no
# git calls here). Dynamic submenu nodes are recreated each time; the
# previous set is freed first (safe: the menu is not visible yet).
func _on_overflow_about_to_popup() -> void:
	if overflow_menu == null:
		return
	overflow_menu.clear()
	for node in _overflow_nodes:
		if is_instance_valid(node):
			(node as Node).queue_free()
	_overflow_nodes = []
	_overflow_build += 1
	if git_manager == null or not git_manager.is_repo():
		overflow_menu.add_item("Not a Git repository.", -1)
		overflow_menu.set_item_disabled(0, true)
		return
	_add_overflow_push_pull()
	overflow_menu.add_separator()
	_add_overflow_stash_menu()
	_add_overflow_tags_menu()
	_add_overflow_remotes_menu()


func _add_overflow_push_pull() -> void:
	overflow_menu.add_item("Pull", OV_PULL)
	var current := _current_branch_name()
	var detached := current.is_empty() or current == "-" or current == "HEAD" or current == "unknown"
	var remote_names := _remote_names()
	if detached:
		overflow_menu.add_item("Push (detached HEAD)", -1)
		overflow_menu.set_item_disabled(overflow_menu.item_count - 1, true)
	elif remote_names.is_empty():
		overflow_menu.add_item("Push (no git remote configured)", -1)
		overflow_menu.set_item_disabled(overflow_menu.item_count - 1, true)
	elif remote_names.size() == 1:
		overflow_menu.add_item("Push '%s' to '%s'" % [current, String(remote_names[0])], OV_PUSH_FIRST)
	else:
		var sub := _make_overflow_submenu("OverflowPushSubmenu")
		for ri in range(remote_names.size()):
			sub.add_item("Push '%s' to '%s'" % [current, String(remote_names[ri])], OV_PUSH_BASE + ri)
		overflow_menu.add_submenu_item("Push '%s'" % current, sub.name)


func _make_overflow_submenu(node_name: String) -> PopupMenu:
	var sub := PopupMenu.new()
	# Build counter suffix: the previous build's nodes are queue_free'd but
	# still siblings until frame end, so fresh names must not collide with
	# theirs (submenu lookup is by name).
	sub.name = "%s#%d" % [node_name, _overflow_build]
	sub.id_pressed.connect(_on_overflow_id)
	overflow_menu.add_child(sub)
	_overflow_nodes.append(sub)
	return sub


func _stash_label(info: Dictionary) -> String:
	var idx := int(info.get("index", 0))
	var message := String(info.get("message", "")).strip_edges()
	if message.is_empty():
		message = String(info.get("raw", ""))
	if message.length() > 44:
		message = message.left(44) + "…"
	return "stash@{%d}: %s" % [idx, message]


func _add_overflow_stash_menu() -> void:
	overflow_menu.add_item("Stash changes...", OV_STASH_PUSH)
	var sub := _make_overflow_submenu("OverflowStashesSubmenu")
	if _stashes.is_empty():
		sub.add_item("No stashes", -1)
		sub.set_item_disabled(0, true)
	var shown := 0
	for s in _stashes:
		if shown >= OV_LIST_CAP:
			break
		var info: Dictionary = s
		var idx := int(info.get("index", shown))
		var entry := _make_overflow_submenu("OverflowStash%dSubmenu" % idx)
		entry.add_item("Apply (keep stash)", OV_STASH_APPLY_BASE + idx)
		entry.add_item("Pop (apply + drop)", OV_STASH_POP_BASE + idx)
		entry.add_item("Drop...", OV_STASH_DROP_BASE + idx)
		sub.add_submenu_item(_stash_label(info), entry.name)
		shown += 1
	if _stashes.size() > shown:
		sub.add_item("(+%d more)" % (_stashes.size() - shown), -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	overflow_menu.add_submenu_item("Stashes (%d)" % _stashes.size(), sub.name)


func _add_overflow_tags_menu() -> void:
	var sub := _make_overflow_submenu("OverflowTagsSubmenu")
	sub.add_item("Create tag at selected commit...", OV_TAG_CREATE)
	if _details_hash.is_empty():
		sub.set_item_disabled(0, true)
	if not _tags.is_empty():
		sub.add_separator()
	var remote_names := _remote_names()
	var shown := 0
	for t in _tags:
		if shown >= OV_LIST_CAP:
			break
		var info: Dictionary = t
		var tag_name := String(info.get("name", ""))
		if tag_name.is_empty():
			continue
		var entry := _make_overflow_submenu("OverflowTag%dSubmenu" % shown)
		entry.add_item("Checkout '%s'" % tag_name, OV_TAG_CHECKOUT_BASE + shown)
		entry.add_item("Delete '%s'..." % tag_name, OV_TAG_DELETE_BASE + shown)
		for ri in range(mini(remote_names.size(), OV_MAX_TAG_PUSH_REMOTES)):
			entry.add_item("Push to '%s'" % String(remote_names[ri]), OV_TAG_PUSH_BASE + shown * OV_TAG_PUSH_STRIDE + ri)
		sub.add_submenu_item(tag_name, entry.name)
		shown += 1
	if _tags.is_empty():
		sub.add_item("No tags", -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	elif _tags.size() > shown:
		sub.add_item("(+%d more)" % (_tags.size() - shown), -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	overflow_menu.add_submenu_item("Tags (%d)" % _tags.size(), sub.name)


func _add_overflow_remotes_menu() -> void:
	var sub := _make_overflow_submenu("OverflowRemotesSubmenu")
	if _remotes.is_empty():
		sub.add_item("No git remotes configured", -1)
		sub.set_item_disabled(0, true)
	var shown := 0
	for r in _remotes:
		if shown >= OV_LIST_CAP:
			break
		var info: Dictionary = r
		var remote_name := String(info.get("name", ""))
		if remote_name.is_empty():
			continue
		sub.add_item("Fetch from '%s'" % remote_name, OV_REMOTE_FETCH_BASE + shown)
		sub.add_item("Fetch (prune) from '%s'" % remote_name, OV_REMOTE_PRUNE_BASE + shown)
		shown += 1
	overflow_menu.add_submenu_item("Remotes (%d)" % _remotes.size(), sub.name)


func _stash_info(index: int) -> Dictionary:
	for s in _stashes:
		var info: Dictionary = s
		if int(info.get("index", -1)) == index:
			return info
	return {}


func _tag_name_at(index: int) -> String:
	if index < 0 or index >= _tags.size():
		return ""
	return String((_tags[index] as Dictionary).get("name", ""))


func _remote_name_at(index: int) -> String:
	var remote_names := _remote_names()
	if index < 0 or index >= remote_names.size():
		return ""
	return String(remote_names[index])


func _on_overflow_id(id: int) -> void:
	if git_manager == null:
		return
	match id:
		OV_PULL:
			_do_pull()
		OV_PUSH_FIRST:
			_do_push_current(_remote_name_at(0))
		OV_STASH_PUSH:
			if stash_dialog != null and is_instance_valid(stash_dialog):
				GraphDialogsScript.clear_inputs(stash_dialog)
				stash_dialog.popup_centered()
		OV_TAG_CREATE:
			if not _details_hash.is_empty():
				_pending_target_hash = _details_hash
				_open_tag_dialog()
		_:
			if id >= OV_PUSH_BASE and id < OV_STASH_APPLY_BASE:
				_do_push_current(_remote_name_at(id - OV_PUSH_BASE))
			elif id >= OV_STASH_APPLY_BASE and id < OV_STASH_POP_BASE:
				_do_stash_apply(id - OV_STASH_APPLY_BASE)
			elif id >= OV_STASH_POP_BASE and id < OV_STASH_DROP_BASE:
				_do_stash_pop(id - OV_STASH_POP_BASE)
			elif id >= OV_STASH_DROP_BASE and id < OV_TAG_CHECKOUT_BASE:
				_do_stash_drop_ask(id - OV_STASH_DROP_BASE)
			elif id >= OV_TAG_CHECKOUT_BASE and id < OV_TAG_DELETE_BASE:
				_do_tag_checkout(_tag_name_at(id - OV_TAG_CHECKOUT_BASE))
			elif id >= OV_TAG_DELETE_BASE and id < OV_TAG_PUSH_BASE:
				_do_tag_delete_ask(_tag_name_at(id - OV_TAG_DELETE_BASE))
			elif id >= OV_TAG_PUSH_BASE and id < OV_REMOTE_FETCH_BASE:
				var slot := id - OV_TAG_PUSH_BASE
				_do_tag_push(_tag_name_at(slot / OV_TAG_PUSH_STRIDE), _remote_name_at(slot % OV_TAG_PUSH_STRIDE))
			elif id >= OV_REMOTE_FETCH_BASE and id < OV_REMOTE_PRUNE_BASE:
				_do_fetch_remote(_remote_name_at(id - OV_REMOTE_FETCH_BASE), false)
			elif id >= OV_REMOTE_PRUNE_BASE:
				_do_fetch_remote(_remote_name_at(id - OV_REMOTE_PRUNE_BASE), true)


func _do_pull() -> void:
	if git_manager == null or not git_manager.is_repo():
		return
	if not git_manager.has_remote():
		_set_status("Error: no git remote configured.", true)
		return
	_set_busy(true)
	_set_status("Pulling...", false)
	git_manager.pull()


func _do_push_current(remote: String) -> void:
	if git_manager == null or remote.is_empty():
		return
	var current := _current_branch_name()
	if current.is_empty() or current == "-" or current == "HEAD" or current == "unknown":
		_set_status("Error: cannot push while HEAD is detached.", true)
		return
	_set_busy(true)
	_set_status("Pushing '%s' to '%s'..." % [current, remote], false)
	git_manager.push_ref(current, remote)


func _do_stash_apply(index: int) -> void:
	if _stash_info(index).is_empty():
		return
	_set_busy(true)
	_set_status("Applying stash@{%d}..." % index, false)
	git_manager.stash_apply(index)


func _do_stash_pop(index: int) -> void:
	if _stash_info(index).is_empty():
		return
	_set_busy(true)
	_set_status("Popping stash@{%d}..." % index, false)
	git_manager.stash_pop(index)


func _do_stash_drop_ask(index: int) -> void:
	if _stash_info(index).is_empty():
		return
	# Dropping discards the stashed changes permanently.
	_ask_confirm("stash_drop", "Drop stash@{%d}? The stashed changes will be lost. This cannot be undone." % index, {"index": index})


func _do_tag_checkout(tag_name: String) -> void:
	if tag_name.is_empty():
		return
	_set_busy(true)
	_set_status("Checking out tag '%s'..." % tag_name, false)
	git_manager.checkout_ref(tag_name)


func _do_tag_delete_ask(tag_name: String) -> void:
	if tag_name.is_empty():
		return
	_ask_confirm("tag_delete", "Delete tag '%s'? This removes the local tag." % tag_name, {"name": tag_name})


func _do_tag_push(tag_name: String, remote: String) -> void:
	if tag_name.is_empty() or remote.is_empty():
		return
	_set_busy(true)
	_set_status("Pushing tag '%s' to '%s'..." % [tag_name, remote], false)
	git_manager.push_ref(tag_name, remote)


func _do_fetch_remote(remote: String, prune: bool) -> void:
	if remote.is_empty():
		return
	_set_busy(true)
	_set_status("Fetching from '%s'%s..." % [remote, " (prune)" if prune else ""], false)
	git_manager.fetch_remote(remote, prune)


func _on_stash_dialog_confirmed() -> void:
	if git_manager == null or stash_dialog == null:
		return
	var note := GraphDialogsScript.line_text(stash_dialog, "DialogInput")
	_set_busy(true)
	_set_status("Stashing changes...", false)
	git_manager.stash_push(note)


func _is_phase3_mutation(action: String) -> bool:
	return action in [
		"graph_branch_create", "graph_branch_delete", "graph_branch_rename",
		"graph_tag_create", "graph_tag_delete",
		"graph_stash_push", "graph_stash_apply", "graph_stash_pop", "graph_stash_drop",
		"graph_push", "graph_fetch",
	]


func _phase3_success_message(result: Dictionary) -> String:
	var action := String(result.get("action", ""))
	match action:
		"graph_branch_create":
			return "Created branch '%s'." % String(result.get("name", ""))
		"graph_branch_delete":
			return "Deleted branch '%s'." % String(result.get("name", ""))
		"graph_branch_rename":
			return "Renamed branch '%s' to '%s'." % [String(result.get("old", "")), String(result.get("new", ""))]
		"graph_tag_create":
			return "Created tag '%s'." % String(result.get("name", ""))
		"graph_tag_delete":
			return "Deleted tag '%s'." % String(result.get("name", ""))
		"graph_stash_push":
			return "Stashed changes."
		"graph_stash_apply":
			return "Applied %s." % String(result.get("ref", "stash"))
		"graph_stash_pop":
			return "Popped %s." % String(result.get("ref", "stash"))
		"graph_stash_drop":
			return "Dropped %s." % String(result.get("ref", "stash"))
		"graph_push":
			return "Pushed '%s' to '%s'." % [String(result.get("ref", "")), String(result.get("remote", ""))]
		"graph_fetch":
			return "Fetched from '%s'." % String(result.get("remote", ""))
	return "Done."


func _on_operation_complete(result: Dictionary) -> void:
	var action := String(result.get("action", ""))
	if action == "fetch":
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
		else:
			refresh()
		return
	if action == "pull":
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
		else:
			_set_status("Pulled successfully!", false)
			_reload_editor_after_disk_change()
			refresh()
		return
	# Auxiliary list loads commit their pending caches only on success, so
	# a failed load never wipes a good list (see _on_tags_loaded etc.).
	if action == "graph_tags":
		if not result.has("error"):
			_tags = _pending_tags
		_pending_tags = []
		return
	if action == "graph_stashes":
		if not result.has("error"):
			_stashes = _pending_stashes
		_pending_stashes = []
		return
	if action == "graph_remotes":
		if not result.has("error"):
			_remotes = _pending_remotes
		_pending_remotes = []
		return
	if _is_phase3_mutation(action):
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
			return
		_set_status(_phase3_success_message(result), false)
		# Stash push/apply/pop rewrite tracked files like checkout does.
		if action == "graph_stash_push" or action == "graph_stash_apply" or action == "graph_stash_pop":
			_reload_editor_after_disk_change()
		refresh()
		return
	if action == "graph_checkout" or action == "graph_merge" or action == "graph_reset":
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
			return
		var done_label := {"graph_checkout": "Checked out", "graph_merge": "Merged", "graph_reset": "Reset"}
		var ref := String(result.get("ref", result.get("hash", "")))
		_set_status("%s %s." % [String(done_label.get(action, "Done")), ref], false)
		_reload_editor_after_disk_change()
		refresh()
		return
	if action == "graph_details":
		if result.has("error") and String(result.get("hash", "")) == _details_hash:
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
			if details != null and is_instance_valid(details):
				details.show_load_error("Failed to load commit details.")
		return
	if action == "graph_diff":
		if result.has("error") and String(result.get("hash", "")) == _details_hash and String(result.get("path", "")) == _diff_path:
			if details != null and is_instance_valid(details):
				details.diff_view.show_message("Failed to load diff: %s" % String(result.get("error", "Unknown error")))
		return
	if not action.begins_with("graph_"):
		return
	# log_loaded arrives just before this; only surface hard failures.
	if result.has("error"):
		if action == "graph_log" and not _commits.is_empty():
			return
		_set_busy(false)
		_loading_more = false
		_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
