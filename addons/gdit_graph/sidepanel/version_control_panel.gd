@tool
extends VBoxContainer

# No class_name (repo convention, AGENTS.md #253): this panel is instantiated
# from version_control_panel.tscn and never referenced by type.
#
# Member fields are intentionally UNTYPED. Godot reparses a long-lived @tool
# script whenever it is saved, and a member whose declared type disagrees
# with the type stored by the previous shape crashes the instance
# (AGENTS.md #242/#244/#245). Local `:=` inference inside functions is safe:
# those never outlive a frame.

# DIP: duck-typed GitOperations contract (see git_operations.gd), not the
# concrete GitManager class — any manager with the required methods and
# signals works here. Intentionally untyped.
var git_manager = null
var _owns_git_manager = false
var _ui_built = false

var unstaged_files = []
var staged_files = []
var selected_unstaged = PackedStringArray()
var selected_staged = PackedStringArray()

var tree_unstaged = null
var tree_staged = null
var staged_menu = null
var changes_menu = null
var discard_dialog = null
var _staged_menu_paths = PackedStringArray()
var _changes_menu_paths = PackedStringArray()
var _discard_paths = PackedStringArray()
var _discard_untracked_paths = PackedStringArray()
var _hover_tree = null
var _hover_item = null
var _hover_hit = []
var _hover_pill = null
var _staged_overlay = null
var _changes_overlay = null
var commit_message = null
var branch_label = null
var status_label = null
var changes_title = null
var staged_title = null
var stage_all_button = null
var unstage_all_button = null
var commit_button = null
var init_button = null
var pull_button = null
var push_button = null
var fetch_button = null
var git_actions_button = null
var git_actions_menu = null
var ignore_dialog = null
var ignore_text = null
var remote_dialog = null
var _pending_push_after_remote_add = {}
var _remotes_manage_pending = false
# Pending create-and-push recovery ({remote, branch, host, owner, repo}):
# a push failed with "repository not found" and the failing remote is
# being resolved (remote list, CLI probe) or created server-side.
var _pending_host_create = {}
# A `git remote -v` listing issued to resolve the failing remote for the
# create flow above (not for the Remotes... manager — see
# _remotes_manage_pending).
var _remotes_resolve_for_create = false
var staged_toggle = null
var changes_toggle = null
var staged_badge = null
var changes_badge = null
var staged_empty_label = null
var changes_empty_label = null
var commit_options_button = null
var commit_options_menu = null
var branch_popup = null
var _branches_cache = []
var _tags_cache = []
var _branch_load_pending = {}
var _repo_ui = []
var _staged_collapsed = false
var _changes_collapsed = false
var _commit_and_push = false
# Bumped by every _set_status() write; a pending delayed reset only fires when
# the epoch is unchanged (nothing newer claimed the label).
var _status_epoch = 0
var commit_message_history = PackedStringArray()
var _signoff_enabled = false
var _history_recall_index = -1
var _pending_commit_after_stage = {}
const COMMIT_HISTORY_MAX := 20
var log_buffer = PackedStringArray()
var log_text = null
var log_box = null
var _log_collapsed = true
const LOG_MAX := 200

# get_branch() sentinel for a repo with no commits yet (rev-parse fails).
const UNBORN_BRANCH := "unknown"
const UNBORN_BRANCH_LABEL := "(no commits yet)"

# Item ids of the "..." all-git-actions menu. Named (not positional): the
# menu interleaves separators, and the id is what id_pressed routes on.
const ID_PULL := 0
const ID_FETCH := 1
const ID_PUSH := 2
const ID_STAGE_ALL := 3
const ID_UNSTAGE_ALL := 4
const ID_RECALL := 5
const ID_SIGNOFF := 6
const ID_DEBUG_LOG := 7
const ID_EDIT_IGNORE := 8
const ID_REMOTES := 9
# Remote ops: toolbar buttons AND the menu entries must lock together, or a
# second op can start while one is in flight.
const REMOTE_MENU_IDS := [ID_PULL, ID_FETCH, ID_PUSH]

const RemoteDialogScene = preload("res://addons/gdit_graph/sidepanel/components/remote_dialog.tscn")
const RemoteUrls = preload("res://addons/gdit_graph/sidepanel/remote_url_utils.gd")
const SidepanelUtils = preload("res://addons/gdit_graph/sidepanel/version_control_panel_utils.gd")
const BranchPopupScript = preload("res://addons/gdit_graph/sidepanel/branch_popup.gd")
const GitRefs = preload("res://addons/gdit_graph/git_refs.gd")
const FileStatus = preload("res://addons/gdit_graph/file_status.gd")
const EditorUtils = preload("res://addons/gdit_graph/editor_utils.gd")
const GitOperations = preload("res://addons/gdit_graph/git_operations.gd")

# Phase 1 scene components: structure lives in .tscn, behavior stays here.
# Component scenes: toolbar_button, badge, file_tree, section_header, empty_state_label.
const ToolbarButtonScene = preload("res://addons/gdit_graph/components/toolbar_button.tscn")
const BadgeScene = preload("res://addons/gdit_graph/sidepanel/components/badge.tscn")
const FileTreeScene = preload("res://addons/gdit_graph/sidepanel/components/file_tree.tscn")
const SectionHeaderScene = preload("res://addons/gdit_graph/sidepanel/components/section_header.tscn")
const EmptyStateLabelScene = preload("res://addons/gdit_graph/sidepanel/components/empty_state_label.tscn")

# Phase 2 composite sections: commit box, status area, and dialogs.
# Scene files: commit_section, status_section, discard_dialog, ignore_dialog.
const CommitSectionScene = preload("res://addons/gdit_graph/sidepanel/components/commit_section.tscn")
const StatusSectionScene = preload("res://addons/gdit_graph/sidepanel/components/status_section.tscn")
const DiscardDialogScene = preload("res://addons/gdit_graph/sidepanel/components/discard_dialog.tscn")
const IgnoreDialogScene = preload("res://addons/gdit_graph/sidepanel/components/ignore_dialog.tscn")

# Phase 3 one-offs: header bar and debug-log viewer. (Init Git stays in
# code: a single 6-line button with no repeated structure.)
const HeaderBarScene = preload("res://addons/gdit_graph/sidepanel/components/header_bar.tscn")
const LogBoxScene = preload("res://addons/gdit_graph/sidepanel/components/log_box.tscn")


func set_git_manager(manager) -> void:
	if git_manager == manager:
		return
	# Validate methods AND signals: a manager that only satisfies the method
	# list still hard-errors on the first `manager.<signal>.connect(...)`,
	# so warn AND keep the previous manager instead of swapping in a broken
	# one (previously it warned and connected anyway).
	if not GitOperations.is_compatible(manager, GitOperations.SIDE_PANEL_METHODS, GitOperations.BASE_SIGNALS):
		push_warning("Git: manager does not satisfy the GitOperations side-panel contract (methods %s, signals %s); keeping the previous manager." % [
			", ".join(GitOperations.missing_methods(manager, GitOperations.SIDE_PANEL_METHODS)),
			", ".join(GitOperations.missing_signals(manager, GitOperations.BASE_SIGNALS)),
		])
		return
	_disconnect_git_manager()
	if _owns_git_manager and _manager_usable():
		git_manager.shutdown()
	git_manager = manager
	_owns_git_manager = false
	if _ui_built and git_manager != null:
		_connect_git_manager()
		_check_git()
		if git_manager.is_repo():
			git_manager.refresh_status()


func _ensure_git_manager() -> void:
	if git_manager != null:
		return
	# Standalone fallback (panel opened as its own scene — including as the
	# project's main scene — or instantiated without plugin injection):
	# build an owned manager so the panel still works. Silent by design
	# (verbose only); the plugin injects the shared manager before _ready
	# in the normal dock path, replacing this fallback on arrival.
	git_manager = GitOperations.create_default_manager(ProjectSettings.globalize_path("res://"))
	_owns_git_manager = true
	print_verbose("Git: no manager injected, using owned fallback manager.")


func _connect_git_manager() -> void:
	if git_manager == null:
		return
	if not git_manager.status_changed.is_connected(_on_status_changed):
		git_manager.status_changed.connect(_on_status_changed)
	if not git_manager.operation_complete.is_connected(_on_operation_complete):
		git_manager.operation_complete.connect(_on_operation_complete)
	# is_repo()/get_branch()/has_remote() read a cache the manager refreshes
	# on its worker; re-run the environment gate when it lands.
	if git_manager.has_signal("env_changed") and not git_manager.env_changed.is_connected(_on_env_changed):
		git_manager.env_changed.connect(_on_env_changed)


func _on_env_changed() -> void:
	_check_git()
	if git_manager != null and git_manager.is_repo():
		git_manager.refresh_status()


# False when the stored manager reference cannot be used (null, freed, or
# a non-object left behind by a failed live script reload — method calls on
# those raise "Nonexistent function ... in base ''"). Teardown and manager
# swaps go through here instead of touching git_manager directly, so a
# stale reference can never crash them.
func _manager_usable() -> bool:
	if git_manager == null or not is_instance_valid(git_manager):
		return false
	if not (git_manager is Object):
		return false
	return (git_manager as Object).has_method("shutdown")


func _disconnect_git_manager() -> void:
	if not _manager_usable():
		return
	if git_manager.status_changed.is_connected(_on_status_changed):
		git_manager.status_changed.disconnect(_on_status_changed)
	if git_manager.operation_complete.is_connected(_on_operation_complete):
		git_manager.operation_complete.disconnect(_on_operation_complete)
	if git_manager.has_signal("env_changed") and git_manager.env_changed.is_connected(_on_env_changed):
		git_manager.env_changed.disconnect(_on_env_changed)


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


func _on_filesystem_changed() -> void:
	_log("filesystem_changed signal fired.")
	if git_manager == null:
		return
	if not git_manager.is_repo():
		return
	git_manager.refresh_status()


# Editor mechanics live in editor_utils.gd (shared with the graph tab); the
# panel keeps its debug-log reporting by passing its logger through.
func _reload_editor_after_disk_change() -> void:
	EditorUtils.reload_editor_after_disk_change(Callable(self, "_log"))


func _ready() -> void:
	_build_ui()
	_ui_built = true
	_ensure_git_manager()
	_connect_git_manager()
	_check_git()
	if git_manager != null and git_manager.is_repo():
		git_manager.refresh_status()
	_connect_filesystem_signals()
	_log("Panel ready.")


func _exit_tree() -> void:
	_disconnect_filesystem_signals()
	_disconnect_git_manager()
	if _owns_git_manager:
		if _manager_usable():
			git_manager.shutdown()
		git_manager = null
		_owns_git_manager = false


func _enter_tree() -> void:
	# No _check_git()/refresh here: _enter_tree runs before _ready, so the
	# labels do not exist yet and both calls would be no-ops. _ready owns
	# the initial gate; this hook only re-attaches the signal wiring.
	_connect_git_manager()
	_connect_filesystem_signals()
	_log("Panel re-entered tree.")


func _check_git() -> void:
	if git_manager == null:
		return
	if status_label == null or branch_label == null:
		return
	# The repo/branch/remote snapshot is resolved on the manager's worker.
	# Until the first one lands the cache reads false, which would paint
	# "Not a Git repository" for a frame: show a neutral state instead.
	if git_manager.has_method("env_ready") and not git_manager.env_ready():
		_set_status("Checking git...")
		return
	if not git_manager.is_git_available():
		branch_label.text = "-"
		_set_status("Git not found. Please install Git.")
		name = "Git"
		_set_repo_ui_visible(false)
		_set_empty_visible(false)
		return
	if not git_manager.is_repo():
		branch_label.text = "-"
		_set_status("Not a Git repository.")
		name = "Git"
		_set_repo_ui_visible(false)
		_set_empty_visible(true)
		if init_button != null:
			init_button.disabled = false
		return
	# A fresh `git init` has no HEAD yet, so `rev-parse --abbrev-ref HEAD`
	# fails and get_branch() reports UNBORN_BRANCH. Say so instead of
	# showing "unknown" (and a commit placeholder naming it).
	var reported: String = git_manager.get_branch()
	var unborn := reported == UNBORN_BRANCH
	branch_label.text = UNBORN_BRANCH_LABEL if unborn else reported
	if commit_message != null and not unborn:
		commit_message.placeholder_text = "Message (Ctrl+Enter to commit on \"%s\")" % reported
	# Persistent no-remote affordance: with commits to publish but no remote
	# configured, say so instead of "Ready" so the setup path is visible
	# without attempting a push first.
	if git_manager.has_remote():
		_set_status("Ready")
	else:
		_set_status("No git remote — Push will offer to add one (Remotes... in the ... menu manages them).")
	_set_repo_ui_visible(true)
	_set_empty_visible(false)
	_update_remote_buttons()


func _set_empty_visible(visible: bool) -> void:
	if init_button != null and is_instance_valid(init_button):
		init_button.visible = visible


func _set_repo_ui_visible(visible: bool) -> void:
	for control in _repo_ui:
		if is_instance_valid(control):
			(control as Control).visible = visible
	if visible:
		_apply_section_visibility()


func _on_init_repo() -> void:
	if git_manager == null or init_button == null:
		return
	init_button.disabled = true
	_set_status("Initializing repository...")
	git_manager.init_repo()


func _make_file_tree(tree_name: String) -> Tree:
	# Structure lives in file_tree.tscn; the scene script applies the column
	# config in _ready (column expand/width need method calls, not settable
	# in .tscn).
	var tree = FileTreeScene.instantiate()
	tree.name = tree_name
	return tree


func _make_toolbar_button(button_name: String, glyph: String, tip: String) -> Button:
	# Shared scene (also used by the graph tab); setup() applies glyph + tip.
	var button = ToolbarButtonScene.instantiate()
	button.name = button_name
	button.setup(glyph, tip)
	return button


# Transparent layer stacked on top of a file tree. The Tree paints its own
# items over anything drawn in its `draw` signal, so hover pills must live
# on this child overlay (children render after their parent). It ignores the
# mouse, so all input still reaches the tree; coordinates match the tree 1:1.
func _make_hover_overlay(tree: Tree, staged: bool) -> Control:
	var overlay := Control.new()
	overlay.name = "StagedHoverOverlay" if staged else "ChangesHoverOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.add_child(overlay)
	overlay.draw.connect(_on_hover_overlay_draw.bind(overlay, tree, staged))
	return overlay


func _hover_overlay_for(tree: Tree) -> Control:
	if tree == tree_staged:
		return _staged_overlay
	if tree == tree_unstaged:
		return _changes_overlay
	return null


func _redraw_hover(tree: Tree) -> void:
	var overlay := _hover_overlay_for(tree)
	if overlay != null and is_instance_valid(overlay):
		overlay.queue_redraw()


func _make_badge(badge_name: String) -> Label:
	# Pill style lives in badge.tscn / badge.gd.
	var badge = BadgeScene.instantiate()
	badge.name = badge_name
	return badge


func _get_file_icon(path: String) -> Texture2D:
	var candidates := PackedStringArray(["File"])
	match path.get_extension().to_lower():
		"gd":
			candidates = PackedStringArray(["Script", "File"])
		"tscn", "scn", "res", "tres":
			candidates = PackedStringArray(["PackedScene", "File"])
		"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "exr", "hdr":
			candidates = PackedStringArray(["Image", "File"])
		"wav", "ogg", "mp3", "flac":
			candidates = PackedStringArray(["AudioStreamWAV", "File"])
		"md", "txt", "cfg", "ini", "json", "yml", "yaml", "toml", "import", "godot":
			candidates = PackedStringArray(["TextFile", "File"])
	for icon_name in candidates:
		if has_theme_icon(icon_name, "EditorIcons"):
			return get_theme_icon(icon_name, "EditorIcons")
	return null


func _dim_color() -> Color:
	if has_theme_color("font_disabled_color", "Label"):
		return get_theme_color("font_disabled_color", "Label")
	return Color(0.55, 0.55, 0.55)


func _disable_row(item: TreeItem) -> void:
	for col in range(3):
		item.set_selectable(col, false)


func _add_file_row(tree: Tree, parent: TreeItem, path: String, code: String) -> void:
	var parts := SidepanelUtils.split_display_path(path)
	var item := tree.create_item(parent)
	item.set_metadata(0, path)
	var icon := _get_file_icon(path)
	if icon != null:
		item.set_icon(0, icon)
	item.set_text(0, parts[0])
	item.set_tooltip_text(0, path)
	item.set_text(1, parts[1])
	item.set_tooltip_text(1, parts[1])
	item.set_custom_color(1, _dim_color())
	var display := SidepanelUtils.status_display(code)
	item.set_text(2, display)
	item.set_text_alignment(2, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_custom_color(2, FileStatus.status_color(code))


func _build_ui() -> void:
	# --- Scrollable content: the dock keeps the user's size no matter how
	# much content loads — overflow scrolls inside the panel instead of
	# forcing the dock taller. Only the status section below stays pinned.
	var content_scroll := ScrollContainer.new()
	content_scroll.name = "ContentScroll"
	# No height floor: the scroll must never claim dock space on enable —
	# the status row below defines the whole minimum, and content is
	# always one scroll away. The user's split owns the height.
	content_scroll.custom_minimum_size = Vector2(0, 0)
	content_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(content_scroll)
	var content_box := VBoxContainer.new()
	content_box.name = "ContentBox"
	content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.add_child(content_box)
	# --- Header bar ("Source Control" + quick actions, like the mock) ---
	var header_bar = HeaderBarScene.instantiate()
	header_bar.name = "HeaderBar"
	content_box.add_child(header_bar)
	pull_button = header_bar.get_node("HeaderPullButton")
	fetch_button = header_bar.get_node("HeaderFetchButton")
	push_button = header_bar.get_node("HeaderPushButton")
	var refresh_toolbar_btn = header_bar.get_node("RefreshButton")
	git_actions_button = header_bar.get_node("GitActionsButton")
	git_actions_menu = header_bar.get_node("GitActionsButton/GitActionsMenu")
	pull_button.pressed.connect(_on_pull)
	fetch_button.pressed.connect(_on_fetch)
	push_button.pressed.connect(_on_push)
	refresh_toolbar_btn.pressed.connect(_on_refresh)
	git_actions_button.pressed.connect(_on_git_actions)
	# The menu is the PopupMenu already parented to GitActionsButton in
	# header_bar.tscn (fetched above), so only its ITEMS are filled here.
	git_actions_menu.add_item("Pull", ID_PULL)
	git_actions_menu.add_item("Fetch", ID_FETCH)
	git_actions_menu.add_item("Push", ID_PUSH)
	git_actions_menu.add_item("Remotes...", ID_REMOTES)
	git_actions_menu.add_separator()
	git_actions_menu.add_item("Stage All", ID_STAGE_ALL)
	git_actions_menu.add_item("Unstage All", ID_UNSTAGE_ALL)
	git_actions_menu.add_separator()
	git_actions_menu.add_item("Recall last commit message", ID_RECALL)
	git_actions_menu.add_check_item("Sign off (--signoff)", ID_SIGNOFF)
	git_actions_menu.add_check_item("Debug log", ID_DEBUG_LOG)
	git_actions_menu.add_separator()
	git_actions_menu.add_item("Edit .gitignore", ID_EDIT_IGNORE)
	# Match on item id (not position): separators shift indices, so
	# index_pressed would misroute every item below a separator.
	git_actions_menu.id_pressed.connect(_on_git_action_selected)
	_repo_ui.append(header_bar)

	# --- Commit section (top, like VSCode) ---
	var commit_box = CommitSectionScene.instantiate()
	commit_box.name = "CommitBox"
	content_box.add_child(commit_box)
	commit_message = commit_box.get_node("CommitMessage")
	commit_button = commit_box.get_node("CommitRow/CommitButton")
	commit_options_button = commit_box.get_node("CommitRow/CommitOptionsButton")
	commit_options_menu = commit_box.get_node("CommitRow/CommitOptionsButton/CommitOptionsMenu")
	commit_message.gui_input.connect(_on_commit_message_gui_input)
	commit_button.disabled = true
	commit_button.pressed.connect(_on_commit)
	commit_options_button.pressed.connect(_on_commit_options)
	commit_options_menu.index_pressed.connect(_on_commit_option_selected)
	# Amend lives in the commit options menu, Sign off in the ⋯ git actions menu.
	_repo_ui.append(commit_box)
	_hover_pill = StyleBoxFlat.new()
	_hover_pill.bg_color = Color(0.23, 0.24, 0.27)
	_hover_pill.set_corner_radius_all(4)
	_hover_pill.content_margin_left = 8.0
	_hover_pill.content_margin_right = 8.0
	_hover_pill.content_margin_top = 2.0
	_hover_pill.content_margin_bottom = 2.0

	# --- Staged Changes section (first, like the mock) ---
	var staged_header = SectionHeaderScene.instantiate()
	staged_header.name = "StagedHeader"
	content_box.add_child(staged_header)
	staged_header.setup("Staged Changes", "Unstage All")
	staged_toggle = staged_header.get_node("Toggle")
	staged_title = staged_header.get_node("Title")
	unstage_all_button = staged_header.get_node("Action")
	staged_badge = staged_header.get_node("Badge")
	staged_toggle.pressed.connect(_on_toggle_staged)
	unstage_all_button.disabled = true
	unstage_all_button.pressed.connect(_on_unstage_all)
	_repo_ui.append(staged_header)

	tree_staged = _make_file_tree("StagedTree")
	tree_staged.item_selected.connect(_on_staged_selected)
	tree_staged.item_activated.connect(_on_unstage)
	tree_staged.gui_input.connect(_on_file_tree_gui_input.bind(tree_staged, true))
	tree_staged.mouse_exited.connect(_on_file_tree_mouse_exited)
	_staged_overlay = _make_hover_overlay(tree_staged, true)
	content_box.add_child(tree_staged)
	_repo_ui.append(tree_staged)
	staged_empty_label = EmptyStateLabelScene.instantiate()
	staged_empty_label.name = "StagedEmptyLabel"
	staged_empty_label.text = "No staged changes"
	content_box.add_child(staged_empty_label)
	_repo_ui.append(staged_empty_label)
	staged_menu = PopupMenu.new()
	staged_menu.name = "StagedMenu"
	staged_menu.index_pressed.connect(_on_staged_menu_selected)
	add_child(staged_menu)

	var sep_sections := HSeparator.new()
	sep_sections.name = "SectionsSeparator"
	content_box.add_child(sep_sections)
	_repo_ui.append(sep_sections)

	# --- Changes section ---
	var changes_header = SectionHeaderScene.instantiate()
	changes_header.name = "ChangesHeader"
	content_box.add_child(changes_header)
	changes_header.setup("Changes", "Stage All")
	changes_toggle = changes_header.get_node("Toggle")
	changes_title = changes_header.get_node("Title")
	stage_all_button = changes_header.get_node("Action")
	changes_badge = changes_header.get_node("Badge")
	changes_toggle.pressed.connect(_on_toggle_changes)
	stage_all_button.disabled = true
	stage_all_button.pressed.connect(_on_stage_all)
	_repo_ui.append(changes_header)

	tree_unstaged = _make_file_tree("UnstagedTree")
	tree_unstaged.item_selected.connect(_on_unstaged_selected)
	tree_unstaged.item_activated.connect(_on_stage)
	tree_unstaged.gui_input.connect(_on_file_tree_gui_input.bind(tree_unstaged, false))
	tree_unstaged.mouse_exited.connect(_on_file_tree_mouse_exited)
	_changes_overlay = _make_hover_overlay(tree_unstaged, false)
	content_box.add_child(tree_unstaged)
	_repo_ui.append(tree_unstaged)
	changes_empty_label = EmptyStateLabelScene.instantiate()
	changes_empty_label.name = "ChangesEmptyLabel"
	changes_empty_label.text = "No changes"
	content_box.add_child(changes_empty_label)
	_repo_ui.append(changes_empty_label)
	changes_menu = PopupMenu.new()
	changes_menu.name = "ChangesMenu"
	changes_menu.index_pressed.connect(_on_changes_menu_selected)
	add_child(changes_menu)
	discard_dialog = DiscardDialogScene.instantiate()
	discard_dialog.name = "DiscardDialog"
	discard_dialog.confirmed.connect(_on_discard_confirmed)
	add_child(discard_dialog)

	# --- Debug log (collapsible, hidden by default; toggle via header) ---
	var log_view = LogBoxScene.instantiate()
	log_view.name = "LogBox"
	content_box.add_child(log_view)
	log_box = log_view
	log_text = log_view.get_node("LogText")
	log_view.clear_pressed.connect(_on_log_clear)

	# --- Empty state: Init Git gets its own row, never the status bar ---
	init_button = Button.new()
	init_button.name = "InitButton"
	init_button.text = "Init Git"
	init_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	init_button.visible = false
	init_button.pressed.connect(_on_init_repo)
	content_box.add_child(init_button)
	# No bottom spacer: the status section below the scroll stays pinned by
	# layout, and spare space inside the scroll simply shows nothing.
	# --- Status bar (bottom): branch only; message row above, buttons elsewhere ---
	var sep_bottom := HSeparator.new()
	sep_bottom.name = "SeparatorBottom"
	add_child(sep_bottom)
	_repo_ui.append(sep_bottom)
	# --- Status / error row (full width above the branch row; folds when narrow) ---
	var status_section = StatusSectionScene.instantiate()
	status_section.name = "StatusSection"
	add_child(status_section)
	status_label = status_section.get_node("StatusLabel")
	branch_label = status_section.get_node("StatusBar/BranchLabel")
	branch_label.gui_input.connect(_on_branch_label_gui_input)
	_build_ignore_dialog()
	_build_remote_dialog()
	branch_popup = BranchPopupScript.new()
	branch_popup.name = "BranchPopup"
	add_child(branch_popup)
	branch_popup.checkout_requested.connect(_on_branch_checkout_requested)
	branch_popup.create_requested.connect(_on_branch_create_requested)
	branch_popup.detach_requested.connect(_on_branch_detach_requested)


func _build_ignore_dialog() -> void:
	# Structure lives in ignore_dialog.tscn; file IO stays here.
	var dialog = IgnoreDialogScene.instantiate()
	dialog.name = "IgnoreDialog"
	add_child(dialog)
	ignore_dialog = dialog
	ignore_text = dialog.get_node("IgnoreBox/IgnoreText")
	dialog.save_pressed.connect(_on_ignore_save)
	dialog.cancel_pressed.connect(_on_ignore_cancel)


func _build_remote_dialog() -> void:
	# Structure lives in remote_dialog.tscn; git calls stay here, the
	# dialog only owns the form layout and forwards intents as signals.
	var dialog = RemoteDialogScene.instantiate()
	dialog.name = "RemoteDialog"
	add_child(dialog)
	remote_dialog = dialog
	dialog.add_requested.connect(_on_remote_add_requested)
	dialog.save_requested.connect(_on_remote_save_requested)
	dialog.remove_requested.connect(_on_remote_remove_requested)
	dialog.new_repo_requested.connect(_on_remote_new_repo_requested)
	dialog.create_requested.connect(_on_host_create_requested)
	dialog.retry_requested.connect(_on_host_retry_requested)


# True when the current branch can be pushed (a repo with commits). A fresh
# `git init` has no HEAD yet, so Add & Push is meaningless there — the
# dialog still allows adding the remote, pushing comes after the first
# commit.
func _can_push_now() -> bool:
	if git_manager == null or not git_manager.is_repo():
		return false
	return git_manager.get_branch() != UNBORN_BRANCH


# Pull/Fetch need a remote to talk to; Push instead opens the remotes
# dialog when none is configured (the publish flow). Called from _check_git
# and after remote ops complete — never while an op is in flight (the
# _set_remote_enabled(false) lock owns the buttons then).
func _update_remote_buttons() -> void:
	if git_manager == null:
		return
	var missing: bool = git_manager.is_repo() and not git_manager.has_remote()
	if pull_button != null:
		pull_button.disabled = missing
	if fetch_button != null:
		fetch_button.disabled = missing
	if push_button != null:
		push_button.tooltip_text = "Add a remote and publish" if missing else "Push to remote"
	if git_actions_menu != null and is_instance_valid(git_actions_menu):
		git_actions_menu.set_item_disabled(ID_PULL, missing)
		git_actions_menu.set_item_disabled(ID_FETCH, missing)


func _on_refresh() -> void:
	if git_manager == null:
		return
	_check_git()
	if not git_manager.is_repo():
		return
	_log("Manual refresh requested.")
	git_manager.refresh_status()


# Debug log: ring buffer of the last LOG_MAX lines, shown in the collapsible
# in-dock viewer (toggled from the "..." menu).
func _log(msg: String) -> void:
	var line := "[%s] %s" % [Time.get_time_string_from_system(), msg]
	log_buffer.append(line)
	while log_buffer.size() > LOG_MAX:
		log_buffer.remove_at(0)
	_update_log_view()


func _update_log_view() -> void:
	# Only rebuild the (up to LOG_MAX line) text while the viewer is open.
	if _log_collapsed or log_text == null or not is_instance_valid(log_text):
		return
	log_text.text = "\n".join(log_buffer)


func _on_log_toggle() -> void:
	_log_collapsed = not _log_collapsed
	if log_box != null and is_instance_valid(log_box):
		log_box.visible = not _log_collapsed
		if not _log_collapsed:
			_update_log_view()
	if git_actions_menu != null and is_instance_valid(git_actions_menu):
		git_actions_menu.set_item_checked(ID_DEBUG_LOG, not _log_collapsed)


func _on_log_clear() -> void:
	log_buffer = PackedStringArray()
	_update_log_view()


func _set_remote_enabled(enabled: bool) -> void:
	if pull_button != null:
		pull_button.disabled = not enabled
	if fetch_button != null:
		fetch_button.disabled = not enabled
	if push_button != null:
		push_button.disabled = not enabled
	# The menu entries drive the same ops, so they lock with the buttons.
	if git_actions_menu != null and is_instance_valid(git_actions_menu):
		for id in REMOTE_MENU_IDS:
			git_actions_menu.set_item_disabled(id, not enabled)


# Shared status reporting (DRY): "info" is gray, "ok" green, "error" red.
# Also bumps _status_epoch, so a pending _reset_status_after_delay() from an
# earlier message can tell that the label has since moved on.
func _set_status(text: String, kind: String = "info") -> void:
	_status_epoch += 1
	if status_label == null:
		return
	status_label.text = text
	match kind:
		"error":
			status_label.add_theme_color_override("font_color", Color.RED)
		"ok":
			status_label.add_theme_color_override("font_color", Color.GREEN)
		_:
			status_label.add_theme_color_override("font_color", Color.GRAY)


# Shared pre-flight for pull/fetch (DRY): null manager, non-repo, and
# missing-remote checks with status reporting. Push has its own path: with
# no remote it opens the remotes dialog (publish flow) instead of erroring.
# The checks live in editor_utils.guard_remote_op (shared with the graph
# tab); this wrapper only adapts the panel's (text, kind) status signature
# and re-runs _check_git on a non-repo. True means proceed.
func _guard_remote_op() -> bool:
	if git_manager != null and not git_manager.is_repo():
		_check_git()
	return EditorUtils.guard_remote_op(git_manager, func(text: String, is_error: bool) -> void:
		_set_status(text, "error" if is_error else "info")
	)


func _on_pull() -> void:
	if not _guard_remote_op():
		return
	_set_remote_enabled(false)
	_set_status("Pulling...")
	git_manager.pull()


func _on_fetch() -> void:
	if not _guard_remote_op():
		return
	_set_remote_enabled(false)
	_set_status("Fetching...")
	git_manager.fetch()


func _on_git_actions() -> void:
	if git_actions_menu == null:
		return
	git_actions_menu.set_item_checked(ID_SIGNOFF, _signoff_enabled)
	git_actions_menu.set_item_checked(ID_DEBUG_LOG, not _log_collapsed)
	git_actions_menu.set_item_disabled(ID_RECALL, commit_message_history.is_empty())
	git_actions_menu.position = DisplayServer.mouse_get_position()
	git_actions_menu.popup()


func _on_git_action_selected(index: int) -> void:
	match index:
		ID_PULL:
			_on_pull()
		ID_FETCH:
			_on_fetch()
		ID_PUSH:
			_on_push()
		ID_REMOTES:
			_on_remotes_menu()
		ID_STAGE_ALL:
			_on_stage_all()
		ID_UNSTAGE_ALL:
			_on_unstage_all()
		ID_RECALL:
			_recall_last_commit_message()
		ID_SIGNOFF:
			_signoff_enabled = not _signoff_enabled
			if git_actions_menu != null:
				git_actions_menu.set_item_checked(ID_SIGNOFF, _signoff_enabled)
		ID_DEBUG_LOG:
			_on_log_toggle()
		ID_EDIT_IGNORE:
			_on_edit_ignore()


func _on_push() -> void:
	if git_manager == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	# No remote: offer to add one (publish flow) instead of erroring.
	if not git_manager.has_remote():
		_open_remote_add(true)
		return
	_set_remote_enabled(false)
	_set_status("Pushing...")
	git_manager.push()


# Open the remotes dialog in add mode. with_push_intent records that the
# user came from Push / Commit & Push, so "Add & Push" finishes the job.
func _open_remote_add(with_push_intent: bool) -> void:
	if remote_dialog == null or git_manager == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	_pending_push_after_remote_add = {"push": with_push_intent}
	_set_status("No git remote — add one to publish.")
	remote_dialog.show_add(_can_push_now())


# Open the remotes dialog in manager mode (list + add/edit/remove).
func _on_remotes_menu() -> void:
	if git_manager == null or remote_dialog == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	_remotes_manage_pending = true
	_set_status("Loading remotes...")
	git_manager.list_remotes()


func _on_remote_add_requested(remote_name: String, url: String, push_after: bool) -> void:
	if git_manager == null:
		return
	# Record the explicit choice: plain "Add" must NOT push afterwards,
	# even when the dialog was opened from Push / Commit & Push.
	_pending_push_after_remote_add = {"remote": remote_name, "push": push_after}
	if remote_dialog != null:
		remote_dialog.hide()
	_set_remote_enabled(false)
	_set_status("Adding remote \"%s\"..." % remote_name)
	git_manager.add_remote(remote_name, url)


func _on_remote_save_requested(remote_name: String, url: String) -> void:
	if git_manager == null:
		return
	if remote_dialog != null:
		remote_dialog.hide()
	_set_remote_enabled(false)
	_set_status("Updating remote \"%s\"..." % remote_name)
	git_manager.set_remote_url(remote_name, url)


func _on_remote_remove_requested(remote_name: String) -> void:
	if git_manager == null:
		return
	if remote_dialog != null:
		remote_dialog.hide()
	_set_remote_enabled(false)
	_set_status("Removing remote \"%s\"..." % remote_name)
	git_manager.remove_remote(remote_name)


func _on_remote_new_repo_requested(host_id: String) -> void:
	var page := RemoteUrls.new_repo_page(host_id)
	if page.is_empty():
		return
	OS.shell_open(page)
	_set_status("Create the empty repo on %s, then paste its URL above." % RemoteUrls.host_display_name(host_id))


# Branch switcher: clicking the branch label loads branches/tags, then the
# popup handles search, create, and checkout intents (see branches.md).
func _on_branch_label_gui_input(event: InputEvent) -> void:
	if branch_label == null or git_manager == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			accept_event()
			_open_branch_switcher()


func _open_branch_switcher() -> void:
	if git_manager == null or branch_popup == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	_branch_load_pending = {"branches": false, "tags": false}
	_set_status("Loading branches...")
	git_manager.list_branches()
	git_manager.list_tags()


func _on_branch_checkout_requested(ref: String, kind: String) -> void:
	if git_manager == null or String(ref).strip_edges().is_empty():
		return
	_set_status("Checking out %s..." % ref)
	if kind == "remote":
		git_manager.checkout_remote(ref)
	else:
		git_manager.checkout_ref(ref)


func _on_branch_create_requested(branch_name: String, source_ref: String) -> void:
	if git_manager == null:
		return
	var clean := SidepanelUtils.sanitize_branch_name(branch_name)
	if clean.is_empty():
		return
	if String(source_ref).strip_edges().is_empty():
		_set_status("Creating and checking out \"%s\"..." % clean)
	else:
		_set_status("Creating \"%s\" from %s..." % [clean, source_ref])
	git_manager.create_and_checkout_branch(clean, String(source_ref))


func _on_branch_detach_requested() -> void:
	if git_manager == null:
		return
	_set_status("Detaching HEAD...")
	git_manager.checkout_detached()


func _on_branch_list_result(result: Dictionary) -> void:
	var action := String(result.get("action", ""))
	if result.has("error"):
		_branch_load_pending = {}
		_set_status("Error: %s" % result.get("error", "Unknown error"), "error")
		return
	if action == "branch_list":
		_branches_cache = GitRefs.parse_branches(String(result.get("text", "")))
		_branch_load_pending["branches"] = true
	elif action == "tag_list":
		_tags_cache = GitRefs.parse_tags(String(result.get("text", "")))
		_branch_load_pending["tags"] = true
	if bool(_branch_load_pending.get("branches", false)) and bool(_branch_load_pending.get("tags", false)):
		_branch_load_pending = {}
		_set_status("Ready")
		if branch_popup != null:
			branch_popup.show_switcher(_branches_cache, _tags_cache)


func _on_branch_op_result(result: Dictionary) -> void:
	var action := String(result.get("action", ""))
	var ref := String(result.get("ref", ""))
	if result.has("error"):
		# Checking out a remote whose local branch already exists fails in
		# git ("already exists"): fall back to checking out the local one.
		if action == "checkout_track" and "already exists" in String(result.get("error", "")):
			var local := SidepanelUtils.remote_tracking_local_name(ref)
			_set_status("Local branch exists, checking out \"%s\"..." % local)
			git_manager.checkout_ref(local)
			return
		_set_status("Error: %s" % result.get("error", "Unknown error"), "error")
		return
	match action:
		"checkout", "checkout_track":
			_set_status("Checked out \"%s\"." % ref, "ok")
		"branch_create_checkout":
			var start := String(result.get("start", ""))
			if start.is_empty():
				_set_status("Created and checked out \"%s\"." % ref, "ok")
			else:
				_set_status("Created \"%s\" from %s and checked out." % [ref, start], "ok")
		"detach":
			_set_status("Detached HEAD (worktree kept).", "ok")
	# Refresh the branch label directly: _check_git() would reset the status
	# line to "Ready" and wipe the success message above.
	if git_manager != null:
		var branch: String = git_manager.get_branch()
		branch_label.text = branch
		if commit_message != null:
			commit_message.placeholder_text = "Message (Ctrl+Enter to commit on \"%s\")" % branch
	# Checkout / create / detach rewrite the worktree: reload open tabs so
	# the editor shows the switched content immediately.
	_reload_editor_after_disk_change()
	if git_manager != null:
		git_manager.refresh_status()


func _on_edit_ignore() -> void:
	if status_label == null or ignore_dialog == null or ignore_text == null:
		return
	var ignore_path := ProjectSettings.globalize_path("res://.gitignore")
	if not FileAccess.file_exists(ignore_path):
		var created := FileAccess.open(ignore_path, FileAccess.WRITE)
		if created == null:
			_set_status("Error: cannot create .gitignore", "error")
			return
		created.close()
	var reader := FileAccess.open(ignore_path, FileAccess.READ)
	if reader == null:
		_set_status("Error: cannot read .gitignore", "error")
		return
	ignore_text.text = reader.get_as_text()
	reader.close()
	ignore_dialog.popup_centered()


func _on_ignore_save() -> void:
	if ignore_dialog == null or ignore_text == null:
		return
	var ignore_path := ProjectSettings.globalize_path("res://.gitignore")
	var writer := FileAccess.open(ignore_path, FileAccess.WRITE)
	if writer == null:
		_set_status("Error: cannot write .gitignore", "error")
		return
	writer.store_string(ignore_text.text)
	writer.close()
	ignore_dialog.hide()
	_set_status("Saved .gitignore")
	if git_manager != null and git_manager.is_repo():
		git_manager.refresh_status()


func _on_ignore_cancel() -> void:
	if ignore_dialog != null:
		ignore_dialog.hide()


func _on_status_changed(files: Array) -> void:
	var parts := SidepanelUtils.split_status_files(files)
	staged_files = parts["staged"]
	unstaged_files = parts["unstaged"]
	_log("status: %d staged, %d unstaged." % [staged_files.size(), unstaged_files.size()])
	_update_tree()
	_update_dirty_badge()


func _update_dirty_badge() -> void:
	var dirty: bool = not unstaged_files.is_empty() or not staged_files.is_empty()
	name = "Git (*)" if dirty else "Git"


func _update_tree() -> void:
	if tree_unstaged == null or tree_staged == null:
		return
	tree_unstaged.clear()
	tree_staged.clear()
	# clear() frees every TreeItem, so any stored selection now points at
	# rows that are no longer listed: drop the path caches too, or the next
	# activate/menu would stage or discard files the tree does not show.
	selected_unstaged.clear()
	selected_staged.clear()
	# clear() frees every TreeItem, so drop hover refs before rebuilding.
	_hover_tree = null
	_hover_item = null
	_hover_hit = []

	# With hide_root=true the first top-level item is hidden, so create an
	# explicit (empty) root and parent every file row under it. Otherwise the
	# first file becomes the hidden root and never renders (a single changed
	# file shows an empty tree).
	var root_unstaged: TreeItem = tree_unstaged.create_item()
	_disable_row(root_unstaged)
	var root_staged: TreeItem = tree_staged.create_item()
	_disable_row(root_staged)

	if changes_title:
		changes_title.text = "Changes"
	if staged_title:
		staged_title.text = "Staged Changes"
	if changes_badge:
		changes_badge.text = "%d" % unstaged_files.size()
	if staged_badge:
		staged_badge.text = "%d" % staged_files.size()

	for f in unstaged_files:
		# Show the worktree (unstaged) code: " M" -> "M", "??" -> "U".
		var ucode: String = f["status"].right(1)
		if ucode == " ":
			ucode = f["status"].left(1)
		_add_file_row(tree_unstaged, root_unstaged, f["path"], ucode)

	for f in staged_files:
		# Show the index (staged) code: "AM" -> "A".
		var scode: String = f["status"].left(1)
		if scode == " ":
			scode = f["status"].right(1)
		_add_file_row(tree_staged, root_staged, f["path"], scode)

	if commit_button:
		commit_button.disabled = staged_files.is_empty()
		if staged_files.is_empty():
			commit_button.text = "Commit"
		else:
			commit_button.text = "Commit (%d)" % staged_files.size()
	if stage_all_button:
		stage_all_button.disabled = unstaged_files.is_empty()
	if unstage_all_button:
		unstage_all_button.disabled = staged_files.is_empty()
	_refresh_section_visibility()


func _on_unstaged_selected() -> void:
	selected_unstaged = _get_selected_items(tree_unstaged)


func _on_staged_selected() -> void:
	selected_staged = _get_selected_items(tree_staged)


func _get_selected_items(tree: Tree) -> PackedStringArray:
	var selected := PackedStringArray()
	var item: TreeItem = tree.get_next_selected(null)
	while item != null:
		# Full repo-relative paths are stored as row metadata (column 0 shows
		# only the file name, column 1 the directory, like the mock). Never
		# rebuild a path from display text: a row without metadata is not a
		# file row (the synthetic root, or an unknown item) and is skipped.
		var meta = item.get_metadata(0)
		if meta != null and not String(meta).is_empty():
			selected.append(String(meta))
		item = tree.get_next_selected(item)
	return selected


func _stage_paths(paths: PackedStringArray) -> void:
	if paths.is_empty() or git_manager == null:
		return
	git_manager.stage_files(paths)


func _unstage_paths(paths: PackedStringArray) -> void:
	if paths.is_empty() or git_manager == null:
		return
	git_manager.unstage_files(paths)


func _on_stage() -> void:
	_stage_paths(selected_unstaged)
	selected_unstaged.clear()


func _on_unstage() -> void:
	_unstage_paths(selected_staged)
	selected_staged.clear()


func _on_stage_all() -> void:
	if unstaged_files.is_empty() or git_manager == null:
		return
	var paths := PackedStringArray()
	for f in unstaged_files:
		paths.append(f["path"])
	_stage_paths(paths)


func _on_unstage_all() -> void:
	if staged_files.is_empty() or git_manager == null:
		return
	var paths := PackedStringArray()
	for f in staged_files:
		paths.append(f["path"])
	_unstage_paths(paths)


func _on_file_tree_gui_input(event: InputEvent, tree: Tree, staged: bool) -> void:
	if tree == null:
		return
	if event is InputEventMouseMotion:
		_update_hover(tree, (event as InputEventMouseMotion).position)
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		if _handle_hover_click(mb.position):
			accept_event()
			return
		return
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return
	var item := tree.get_item_at_position(mb.position)
	if item == null:
		return
	var meta = item.get_metadata(0)
	if meta == null or String(meta).is_empty():
		return
	var hovered := String(meta)
	if staged:
		_staged_menu_paths = SidepanelUtils.menu_targets(hovered, selected_staged)
		_show_staged_menu()
	else:
		_changes_menu_paths = SidepanelUtils.menu_targets(hovered, selected_unstaged)
		_show_changes_menu()


func _update_hover(tree: Tree, pos: Vector2) -> void:
	var item: TreeItem = null
	if tree != null:
		var found := tree.get_item_at_position(pos)
		if found != null:
			var meta = found.get_metadata(0)
			if meta != null and not String(meta).is_empty():
				item = found
	if item != _hover_item or tree != _hover_tree:
		if _hover_tree != null and is_instance_valid(_hover_tree) and _hover_tree != tree:
			_redraw_hover(_hover_tree)
		_hover_tree = tree
		_hover_item = item
		_hover_hit = []
		if tree != null:
			_redraw_hover(tree)


func _clear_hover() -> void:
	if _hover_tree != null and is_instance_valid(_hover_tree):
		_redraw_hover(_hover_tree)
	_hover_tree = null
	_hover_item = null
	_hover_hit = []


func _on_file_tree_mouse_exited() -> void:
	_clear_hover()


# Paints VSCode-style inline action buttons on the hovered row and rebuilds
# the click hit-rects, so scroll/resize stay correct (draw runs on each).
# Drawing happens on the overlay child, which renders above the tree's items.
func _on_hover_overlay_draw(overlay: Control, tree: Tree, staged: bool) -> void:
	if overlay == null or tree != _hover_tree or _hover_item == null or not is_instance_valid(_hover_item):
		return
	var path := String(_hover_item.get_metadata(0))
	if path.is_empty():
		return
	var actions: Array = ["unstage"] if staged else ["stage", "discard"]
	_draw_hover_buttons(overlay, tree, staged, path, actions)


func _draw_hover_buttons(overlay: Control, tree: Tree, staged: bool, path: String, actions: Array) -> void:
	# Clear the hit-rects FIRST: every early return below means "no buttons
	# drawn this pass", so stale rects must not survive into _handle_hover_click
	# (a click on empty space below a scrolled-away row would fire an action).
	_hover_hit = []
	if actions.is_empty() or _hover_pill == null:
		return
	var row := tree.get_item_area_rect(_hover_item, 0)
	if row.size.y <= 0.0 or row.position.y + row.size.y < 0.0 or row.position.y > tree.size.y:
		return
	var font := tree.get_theme_font("font")
	var font_size := tree.get_theme_font_size("font_size")
	var font_color := tree.get_theme_color("font_color")
	# Solid (opaque) chip slightly elevated from the row background, resolved
	# from the tree's own panel style so it fits any editor theme.
	var base := Color(0.16, 0.17, 0.2)
	if tree.has_theme_stylebox("panel"):
		var panel_sb := tree.get_theme_stylebox("panel")
		if panel_sb is StyleBoxFlat:
			base = (panel_sb as StyleBoxFlat).bg_color
	var pill_bg := base.lerp(font_color, 0.14)
	pill_bg.a = 1.0
	_hover_pill.bg_color = pill_bg
	var labels := {"stage": "Stage", "unstage": "Unstage", "discard": "Discard"}
	var x := overlay.size.x - 6.0
	var cy := row.position.y + row.size.y * 0.5
	for i in range(actions.size() - 1, -1, -1):
		var action := String(actions[i])
		var label := String(labels.get(action, action))
		var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 16.0
		var h := minf(row.size.y - 4.0, float(font_size) + 10.0)
		var rect := Rect2(x - w, cy - h * 0.5, w, h)
		overlay.draw_style_box(_hover_pill, rect)
		var ty := rect.position.y + (rect.size.y - font.get_height(font_size)) * 0.5 + font.get_ascent(font_size)
		overlay.draw_string(font, Vector2(rect.position.x + 8.0, ty), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, font_color)
		_hover_hit.append({"rect": rect, "action": action, "path": path, "staged": staged})
		x = rect.position.x - 4.0


func _handle_hover_click(pos: Vector2) -> bool:
	for h in _hover_hit:
		if (h["rect"] as Rect2).has_point(pos):
			var action := String(h["action"])
			var path := String(h["path"])
			_clear_hover()
			match action:
				"stage":
					_stage_paths(PackedStringArray([path]))
				"unstage":
					_unstage_paths(PackedStringArray([path]))
				"discard":
					_ask_discard_changes(PackedStringArray([path]))
			return true
	return false


func _show_staged_menu() -> void:
	if staged_menu == null or _staged_menu_paths.is_empty():
		return
	staged_menu.clear()
	staged_menu.add_item("Open File", 0)
	staged_menu.add_item("Unstage Changes", 1)
	staged_menu.position = DisplayServer.mouse_get_position()
	staged_menu.popup()


func _show_changes_menu() -> void:
	if changes_menu == null or _changes_menu_paths.is_empty():
		return
	changes_menu.clear()
	changes_menu.add_item("Open File", 0)
	changes_menu.add_item("Stage Changes", 1)
	changes_menu.add_item("Discard Changes", 2)
	changes_menu.position = DisplayServer.mouse_get_position()
	changes_menu.popup()


func _on_staged_menu_selected(index: int) -> void:
	if _staged_menu_paths.is_empty():
		return
	match index:
		0:
			_open_file_in_editor(_staged_menu_paths[0])
		1:
			_unstage_paths(_staged_menu_paths)
	_staged_menu_paths = PackedStringArray()


func _on_changes_menu_selected(index: int) -> void:
	if _changes_menu_paths.is_empty():
		return
	match index:
		0:
			_open_file_in_editor(_changes_menu_paths[0])
		1:
			_stage_paths(_changes_menu_paths)
		2:
			_ask_discard_changes(_changes_menu_paths)
	_changes_menu_paths = PackedStringArray()


func _ask_discard_changes(paths: PackedStringArray) -> void:
	if paths.is_empty() or git_manager == null:
		return
	var tracked := PackedStringArray()
	var untracked := PackedStringArray()
	for p in paths:
		if SidepanelUtils.is_untracked(p, unstaged_files):
			if SidepanelUtils.is_safe_repo_relative(p):
				untracked.append(p)
			else:
				push_warning("Git: refusing to delete suspicious path: %s" % p)
		else:
			tracked.append(p)
	if tracked.is_empty() and untracked.is_empty():
		return
	_discard_paths = tracked
	_discard_untracked_paths = untracked
	_log("Discard asked: tracked=[%s] untracked=[%s]" % [", ".join(tracked), ", ".join(untracked)])
	if discard_dialog != null:
		if tracked.is_empty():
			if untracked.size() == 1:
				discard_dialog.dialog_text = "Delete untracked file \"%s\"? This cannot be undone." % untracked[0]
			else:
				discard_dialog.dialog_text = "Delete %d untracked files? This cannot be undone." % untracked.size()
		elif untracked.is_empty():
			if tracked.size() == 1:
				discard_dialog.dialog_text = "Discard changes in \"%s\"? This cannot be undone." % tracked[0]
			else:
				discard_dialog.dialog_text = "Discard changes in %d files? This cannot be undone." % tracked.size()
		else:
			discard_dialog.dialog_text = "Discard changes in %d files and delete %d untracked files? This cannot be undone." % [tracked.size(), untracked.size()]
		discard_dialog.popup_centered()


func _on_discard_confirmed() -> void:
	if git_manager == null:
		return
	var tracked: PackedStringArray = _discard_paths
	var untracked: PackedStringArray = _discard_untracked_paths
	_discard_paths = PackedStringArray()
	_discard_untracked_paths = PackedStringArray()
	if tracked.is_empty() and untracked.is_empty():
		return
	var all := PackedStringArray()
	all.append_array(tracked)
	all.append_array(untracked)
	_set_status("Discarding changes...")
	_log("Discard confirmed: revert=[%s] clean=[%s]" % [", ".join(tracked), ", ".join(untracked)])
	if not tracked.is_empty():
		_log("git restore --source=HEAD --staged --worktree -- %s" % ", ".join(tracked))
		git_manager.revert_changes(tracked)
	if not untracked.is_empty():
		_log("git clean -fd -- %s" % ", ".join(untracked))
		git_manager.discard_untracked(untracked)


func _open_file_in_editor(repo_path: String) -> void:
	EditorUtils.open_file_in_editor(repo_path)


func _on_commit(push_after: bool = false, stage_first: bool = false, force_amend: bool = false) -> void:
	if commit_message == null or git_manager == null:
		return
	var msg: String = commit_message.text.strip_edges()
	if msg.is_empty():
		return
	var amend_on := force_amend
	var signoff_on: bool = _signoff_enabled
	if stage_first and not unstaged_files.is_empty():
		var paths := PackedStringArray()
		for f in unstaged_files:
			paths.append(f["path"])
		_pending_commit_after_stage = {
			"message": msg,
			"amend": amend_on,
			"signoff": signoff_on,
			"push_after": push_after,
		}
		git_manager.stage_files(paths)
		return
	_dispatch_commit(msg, amend_on, signoff_on, push_after)


func _dispatch_commit(msg: String, amend_on: bool, signoff_on: bool, push_after: bool) -> void:
	_commit_and_push = push_after
	commit_message_history = SidepanelUtils.remember_message(commit_message_history, msg, COMMIT_HISTORY_MAX)
	_history_recall_index = -1
	git_manager.commit(msg, amend_on, signoff_on)
	if commit_message != null:
		commit_message.text = ""


# Last-message recall: the ⋯ menu restores the newest message, Ctrl+Down in
# the message box cycles older. Replaces the old CommitTopRow history button.
func _recall_last_commit_message() -> void:
	if commit_message == null or commit_message_history.is_empty():
		return
	_history_recall_index = 0
	commit_message.text = commit_message_history[0]
	commit_message.grab_focus()


func _recall_history_step() -> void:
	if commit_message == null or commit_message_history.is_empty():
		return
	_history_recall_index += 1
	if _history_recall_index < 0 or _history_recall_index >= commit_message_history.size():
		_history_recall_index = 0
	commit_message.text = commit_message_history[_history_recall_index]
	commit_message.grab_focus()


func _on_commit_message_gui_input(event: InputEvent) -> void:
	if commit_message == null:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.ctrl_pressed:
			if key.keycode == KEY_DOWN:
				accept_event()
				_recall_history_step()
			elif key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
				if commit_button == null or not commit_button.disabled:
					accept_event()
					_on_commit()


func _on_commit_options() -> void:
	if commit_options_menu != null:
		commit_options_menu.position = DisplayServer.mouse_get_position()
		commit_options_menu.popup()


func _on_commit_option_selected(index: int) -> void:
	match index:
		1:
			_on_commit(true)
		2:
			_on_commit(false, true)
		3:
			_on_commit(false, false, true)
		_:
			_on_commit()


func _push_after_commit() -> void:
	_commit_and_push = false
	if git_manager == null or status_label == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	if not git_manager.has_remote():
		_set_status("Committed. No git remote — add one to push.", "error")
		_open_remote_add(true)
		return
	_set_remote_enabled(false)
	_set_status("Committed. Pushing...")
	git_manager.push()


# Routes a finished `git remote -v` listing: it backs an explicit
# Remotes... open (show the manager), refreshes an already-open dialog
# after an add/update/remove, or resolves the failing remote for the
# create-and-push recovery flow (see _remotes_resolve_for_create).
func _on_remote_list_result(result: Dictionary) -> void:
	if remote_dialog == null:
		_remotes_manage_pending = false
		_remotes_resolve_for_create = false
		return
	if result.has("error"):
		_remotes_manage_pending = false
		_remotes_resolve_for_create = false
		_pending_host_create = {}
		_set_status("Error: %s" % result.get("error", "Unknown error"), "error")
		return
	var remotes := RemoteUrls.parse_remote_verbose(String(result.get("text", "")))
	if _remotes_resolve_for_create:
		_remotes_resolve_for_create = false
		_resolve_host_for_create(remotes)
		return
	if _remotes_manage_pending:
		_remotes_manage_pending = false
		_set_status("Ready")
		remote_dialog.show_manage(remotes, _can_push_now())
	elif remote_dialog.visible:
		remote_dialog.set_remotes(remotes)
	else:
		# The dialog was closed while the listing was in flight: leave no
		# stale "Loading remotes..." behind.
		_set_status("Ready")


func _on_remote_op_result(result: Dictionary) -> void:
	var action := String(result.get("action", ""))
	var remote_name := String(result.get("remote", ""))
	_set_remote_enabled(true)
	_update_remote_buttons()
	if result.has("error"):
		var message := String(result.get("error", "Unknown error"))
		# Adding a name that already exists is recoverable in place: open
		# the manager so the user can point it at the new URL via Save.
		if action == "remote_add" and "already exists" in message:
			_pending_push_after_remote_add = {}
			_set_status("Error: remote \"%s\" already exists — pick it in Remotes... and Save the new URL." % remote_name, "error")
			_on_remotes_menu()
			return
		_pending_push_after_remote_add = {}
		_set_status("Error: %s" % message, "error")
		return
	match action:
		"remote_add":
			# The env snapshot (has_remote) re-resolves on the worker;
			# refresh the list view too when the manager is open.
			if remote_dialog != null and remote_dialog.visible:
				git_manager.list_remotes()
			if not _pending_push_after_remote_add.is_empty() and bool(_pending_push_after_remote_add.get("push", false)):
				var target: String = String(_pending_push_after_remote_add.get("remote", remote_name))
				_pending_push_after_remote_add = {}
				_push_upstream_now(target)
				return
			_pending_push_after_remote_add = {}
			_set_status("Remote \"%s\" added." % remote_name, "ok")
		"remote_set_url":
			_pending_push_after_remote_add = {}
			if remote_dialog != null and remote_dialog.visible:
				git_manager.list_remotes()
			_set_status("Remote \"%s\" updated." % remote_name, "ok")
		"remote_remove":
			_pending_push_after_remote_add = {}
			if remote_dialog != null and remote_dialog.visible:
				git_manager.list_remotes()
			_check_git()
			_set_status("Remote \"%s\" removed." % remote_name, "ok")


# Push the current branch to a just-added remote, setting it as upstream
# so later bare pushes work. When the branch cannot be determined (a repo
# with no commits yet), pushing is impossible — say so instead.
# action_label names the step that just finished ("Remote added.",
# "Repo created.") so the in-flight status reads correctly for both
# callers.
func _push_upstream_now(remote_name: String, action_label: String = "Remote added.") -> void:
	if git_manager == null:
		_pending_push_after_remote_add = {}
		return
	var branch: String = git_manager.get_branch()
	if branch == UNBORN_BRANCH or branch.strip_edges().is_empty():
		_pending_push_after_remote_add = {}
		_set_status("Remote added. Commit first, then push.", "ok")
		return
	_set_remote_enabled(false)
	_set_status("%s Pushing %s to \"%s\"..." % [action_label, branch, remote_name])
	git_manager.push_upstream(remote_name, branch)


# A push failed because the remote repository doesn't exist server-side.
# Stash the failing remote, resolve its URL to host/owner/repo via a
# remote listing, then probe the host CLI before showing the
# create-and-push dialog — one read-only round trip at a time.
func _on_repo_not_found(result: Dictionary) -> void:
	if git_manager == null or remote_dialog == null:
		_set_status("Error: %s" % String(result.get("error", "Unknown error")), "error")
		return
	_pending_host_create = {"remote": String(result.get("remote", "origin"))}
	_remotes_resolve_for_create = true
	_set_status("Remote repository not found — checking \"%s\"..." % String(_pending_host_create.get("remote", "origin")))
	git_manager.list_remotes()


# Second hop of the recovery: match the failing remote name to its URL,
# parse host/owner/repo, and probe the host CLI (or skip straight to
# browser guidance for hosts without one).
func _resolve_host_for_create(remotes: Array) -> void:
	if git_manager == null or remote_dialog == null or _pending_host_create.is_empty():
		_pending_host_create = {}
		_set_status("Ready")
		return
	var target := String(_pending_host_create.get("remote", ""))
	var url := ""
	for r in remotes:
		var info: Dictionary = r
		if String(info.get("name", "")) == target:
			url = String(info.get("fetch_url", info.get("push_url", "")))
			break
	if url.is_empty():
		_pending_host_create = {}
		_set_status("Error: remote \"%s\" is gone — add it again via Remotes..." % target, "error")
		return
	var parts: Dictionary = RemoteUrls.parse_host_parts(url)
	var host := String(parts.get("host", "custom"))
	_pending_host_create["host"] = host
	_pending_host_create["owner"] = String(parts.get("owner", ""))
	_pending_host_create["repo"] = String(parts.get("repo", ""))
	_pending_host_create["host_display"] = RemoteUrls.host_display_name(host)
	if host == "github" or host == "gitlab":
		_set_status("Checking for %s..." % ("gh" if host == "github" else "glab"))
		git_manager.check_host_cli(host)
		return
	# Bitbucket, custom, or unrecognized URLs: no helper CLI exists, so
	# the browser + "Push again" path is the whole flow.
	_show_create_dialog({"supported": false, "available": false, "authed": false})


# Third hop: the CLI probe landed — show the create dialog with the full
# picture (the one-click button only appears when the CLI is present AND
# authed; see remote_dialog.show_create).
func _on_host_cli_check_result(result: Dictionary) -> void:
	if remote_dialog == null or _pending_host_create.is_empty():
		_pending_host_create = {}
		return
	if String(result.get("host", "")) != String(_pending_host_create.get("host", "")):
		return
	_show_create_dialog({
		"supported": true,
		"available": bool(result.get("available", false)),
		"authed": bool(result.get("authed", false)),
	})


func _show_create_dialog(cli: Dictionary) -> void:
	if remote_dialog == null or _pending_host_create.is_empty():
		_pending_host_create = {}
		_set_status("Ready")
		return
	_set_status("Remote repository not found — create it to push.")
	remote_dialog.show_create(_pending_host_create, cli)


func _on_host_create_requested(is_private: bool) -> void:
	if git_manager == null or _pending_host_create.is_empty():
		return
	var pending: Dictionary = _pending_host_create
	if remote_dialog != null:
		remote_dialog.hide()
	_set_remote_enabled(false)
	_set_status("Creating \"%s/%s\" on %s..." % [String(pending.get("owner", "")), String(pending.get("repo", "")), String(pending.get("host_display", "the host"))])
	git_manager.create_host_repo(String(pending.get("host", "")), String(pending.get("owner", "")), String(pending.get("repo", "")), is_private)


# "Push again" from the create dialog: the user created the repo in the
# browser (or fixed access) and wants the failed push retried now.
func _on_host_retry_requested() -> void:
	if git_manager == null or _pending_host_create.is_empty():
		return
	var target := String(_pending_host_create.get("remote", ""))
	_pending_host_create = {}
	if remote_dialog != null:
		remote_dialog.hide()
	_push_upstream_now(target, "Pushing")


func _on_host_create_result(result: Dictionary) -> void:
	_set_remote_enabled(true)
	_update_remote_buttons()
	if result.has("error"):
		# Keep the recovery open: re-show the create dialog with the CLI
		# output attached, so a taken name or denied creation can be
		# addressed without re-pressing Push first.
		var message := String(result.get("error", "Unknown error"))
		_set_status("Error creating repository: %s" % message, "error")
		if remote_dialog != null and not _pending_host_create.is_empty():
			remote_dialog.show_create(_pending_host_create, {"supported": true, "available": true, "authed": true})
			remote_dialog.show_error(message)
		else:
			_pending_host_create = {}
		return
	var target := String(result.get("remote", _pending_host_create.get("remote", "origin")))
	_pending_host_create = {}
	_push_upstream_now(target, "Repo created.")


func _on_toggle_staged() -> void:
	_staged_collapsed = not _staged_collapsed
	_apply_section_visibility()


func _on_toggle_changes() -> void:
	_changes_collapsed = not _changes_collapsed
	_apply_section_visibility()


func _apply_section_visibility() -> void:
	_refresh_section_visibility()
	if staged_toggle != null:
		staged_toggle.text = "▸" if _staged_collapsed else "▾"
	if changes_toggle != null:
		changes_toggle.text = "▸" if _changes_collapsed else "▾"


# A section shows its file tree when it has files and its empty-state label
# otherwise; collapsing hides both (sidepanel spec rows 4-7).
func _refresh_section_visibility() -> void:
	if tree_staged != null and is_instance_valid(tree_staged):
		var staged_visible: bool = not _staged_collapsed and not staged_files.is_empty()
		tree_staged.visible = staged_visible
		tree_staged.size_flags_vertical = Control.SIZE_EXPAND_FILL if staged_visible else 0
		tree_staged.custom_minimum_size = Vector2(0, 80) if staged_visible else Vector2(0, 0)
	if staged_empty_label != null and is_instance_valid(staged_empty_label):
		staged_empty_label.visible = not _staged_collapsed and staged_files.is_empty()
	if tree_unstaged != null and is_instance_valid(tree_unstaged):
		var unstaged_visible: bool = not _changes_collapsed and not unstaged_files.is_empty()
		tree_unstaged.visible = unstaged_visible
		tree_unstaged.size_flags_vertical = Control.SIZE_EXPAND_FILL if unstaged_visible else 0
		tree_unstaged.custom_minimum_size = Vector2(0, 80) if unstaged_visible else Vector2(0, 0)
	if changes_empty_label != null and is_instance_valid(changes_empty_label):
		changes_empty_label.visible = not _changes_collapsed and unstaged_files.is_empty()


func _on_operation_complete(result: Dictionary) -> void:
	if status_label == null:
		return
	var action := String(result.get("action", ""))
	var op_msg := "op complete: action=%s exit_code=%s" % [action, str(result.get("exit_code", "?"))]
	if result.has("error"):
		op_msg += " error=%s" % str(result.get("error", ""))
	_log(op_msg)
	# An internal status refresh is not a user operation. Every mutating op
	# ends with refresh_status(), so letting this through the chain below
	# would fall into the final else and wipe the message the user just got
	# ("Committed successfully!", "Pulled successfully!", branch switcher...).
	if action == "status":
		return
	if action == "init":
		if init_button != null:
			init_button.disabled = false
		_check_git()
		if result.has("error"):
			_set_status("Error: %s" % result.get("error", "Unknown error"), "error")
		elif git_manager != null and git_manager.is_repo():
			_set_status("Repository initialized!", "ok")
			git_manager.refresh_status()
		return
	if action == "pull" or action == "push" or action == "fetch" or action == "push_upstream":
		_set_remote_enabled(true)
		_update_remote_buttons()
		if result.has("error"):
			# The remote repo doesn't exist server-side: offer to create
			# it instead of dumping the raw host error on the user.
			if (action == "push" or action == "push_upstream") and bool(result.get("repo_not_found", false)):
				_on_repo_not_found(result)
				return
			_pending_push_after_remote_add = {}
			_set_status("Error: %s" % result.get("error", "Unknown error"), "error")
		elif action == "pull":
			_set_status("Pulled successfully!", "ok")
			# Pull can rewrite tracked files on disk (fast-forward): refresh
			# the editor so open tabs reload instead of showing stale content.
			_reload_editor_after_disk_change()
		elif action == "fetch":
			_set_status("Fetched successfully!", "ok")
		else:
			_pending_push_after_remote_add = {}
			# A transparent no-upstream retry sets tracking up behind the
			# scenes — say so, so the one-time setup is visible, not magic.
			if bool(result.get("upstream_set", false)):
				_set_status("Pushed successfully! (now tracking \"%s\".)" % String(result.get("remote", "origin")), "ok")
			else:
				_set_status("Pushed successfully!", "ok")
		return
	if action == "remote_list":
		_on_remote_list_result(result)
		return
	if action == "remote_add" or action == "remote_set_url" or action == "remote_remove":
		_on_remote_op_result(result)
		return
	if action == "host_cli_check":
		_on_host_cli_check_result(result)
		return
	if action == "host_repo_create":
		_on_host_create_result(result)
		return
	# Branch switcher results (list/checkout/create/detach) are routed to
	# their own handlers so the generic "Ready" fallthrough below never
	# clobbers their status messages.
	if action == "branch_list" or action == "tag_list":
		_on_branch_list_result(result)
		return
	if action == "checkout" or action == "checkout_track" or action == "branch_create_checkout" or action == "detach":
		_on_branch_op_result(result)
		return
	# A "Commit & Stage" first stages everything, then commits once the stage
	# op lands. The stage op already triggered a status refresh; the commit
	# reads the on-disk index directly, so it is safe to dispatch now.
	if action == "stage" and not _pending_commit_after_stage.is_empty():
		var pending: Dictionary = _pending_commit_after_stage
		_pending_commit_after_stage = {}
		if result.get("exit_code", 0) != 0:
			_commit_and_push = false
			_set_status("Error: staging before commit failed.", "error")
			return
		var pmsg := String(pending.get("message", ""))
		if pmsg.strip_edges().is_empty():
			return
		_dispatch_commit(pmsg, bool(pending.get("amend", false)), bool(pending.get("signoff", false)), bool(pending.get("push_after", false)))
		return
	# A successful revert/clean rewrote files on disk: refresh the editor so
	# open tabs reload the reverted content immediately instead of showing
	# stale text until the next focus regain. Falls through to "Ready" below.
	if result.get("exit_code", 0) == 0 and not result.has("error"):
		if action == "revert" or action == "clean":
			_reload_editor_after_disk_change()
	if result.has("error"):
		_commit_and_push = false
		_pending_commit_after_stage = {}
		_set_status("Error: %s" % result.get("error", "Unknown error"), "error")
	elif action == "commit" and result.get("exit_code", 0) == 0:
		if _commit_and_push:
			_push_after_commit()
			return
		_set_status("Committed successfully!", "ok")
		_reset_status_after_delay()
	else:
		_set_status("Ready")


# Fade a success message back to "Ready" after a beat. Epoch-guarded so a
# later op (or a second commit) that already wrote the label is not clobbered
# by this timer, and tree-guarded because the panel can be freed while the
# timer is pending (plugin disable / editor close).
func _reset_status_after_delay(seconds: float = 3.0) -> void:
	var epoch: int = _status_epoch
	await get_tree().create_timer(seconds).timeout
	if not is_inside_tree() or epoch != _status_epoch:
		return
	if status_label == null or not is_instance_valid(status_label):
		return
	_set_status("Ready")
