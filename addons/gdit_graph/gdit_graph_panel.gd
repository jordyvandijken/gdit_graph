@tool
extends VBoxContainer
class_name VersionControlPanel

signal stage_requested(paths: PackedStringArray)
signal unstage_requested(paths: PackedStringArray)
signal commit_requested(message: String)
signal discard_requested(paths: PackedStringArray)

var git_manager: GitManager
var _owns_git_manager: bool = false
var _ui_built: bool = false

var unstaged_files: Array = []
var staged_files: Array = []
var selected_unstaged: PackedStringArray = []
var selected_staged: PackedStringArray = []

var tree_unstaged: Tree
var tree_staged: Tree
var staged_menu: PopupMenu
var changes_menu: PopupMenu
var discard_dialog: ConfirmationDialog
var _staged_menu_paths: PackedStringArray = []
var _changes_menu_paths: PackedStringArray = []
var _discard_paths: PackedStringArray = []
var _discard_untracked_paths: PackedStringArray = []
var _hover_tree: Tree
var _hover_item: TreeItem
var _hover_hit: Array = []
var _hover_pill: StyleBoxFlat
var _staged_overlay: Control
var _changes_overlay: Control
var commit_message: TextEdit
var branch_label: Label
var status_label: Label
var changes_title: Label
var staged_title: Label
var stage_all_button: Button
var unstage_all_button: Button
var commit_button: Button
var init_button: Button
var pull_button: Button
var push_button: Button
var fetch_button: Button
var git_actions_button: Button
var git_actions_menu: PopupMenu
var ignore_dialog: PopupPanel
var ignore_text: TextEdit
var staged_toggle: Button
var changes_toggle: Button
var staged_badge: Label
var changes_badge: Label
var staged_empty_label: Label
var changes_empty_label: Label
var commit_options_button: Button
var commit_options_menu: PopupMenu
var _repo_ui: Array = []
var _staged_collapsed: bool = false
var _changes_collapsed: bool = false
var _commit_and_push: bool = false
var commit_message_history: PackedStringArray = []
var _signoff_enabled: bool = false
var _history_recall_index: int = -1
var _pending_commit_after_stage: Dictionary = {}
const COMMIT_HISTORY_MAX := 20
var log_buffer: PackedStringArray = []
var log_text: TextEdit
var log_box: VBoxContainer
var _log_collapsed: bool = true
const LOG_MAX := 200


func set_git_manager(manager: GitManager) -> void:
	if git_manager == manager:
		return
	_disconnect_git_manager()
	if _owns_git_manager and git_manager != null:
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
	var fallback := GitManager.new()
	fallback.set_repo_path(ProjectSettings.globalize_path("res://"))
	git_manager = fallback
	_owns_git_manager = true
	push_warning("Version Control: git_manager not assigned, using fallback manager.")


func _connect_git_manager() -> void:
	if git_manager == null:
		return
	if not git_manager.status_changed.is_connected(_on_status_changed):
		git_manager.status_changed.connect(_on_status_changed)
	if not git_manager.operation_complete.is_connected(_on_operation_complete):
		git_manager.operation_complete.connect(_on_operation_complete)


func _disconnect_git_manager() -> void:
	if git_manager == null:
		return
	if git_manager.status_changed.is_connected(_on_status_changed):
		git_manager.status_changed.disconnect(_on_status_changed)
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


func _on_filesystem_changed() -> void:
	_log("filesystem_changed signal fired.")
	if git_manager == null:
		return
	if not git_manager.is_repo():
		return
	git_manager.refresh_status()


# Discarding (revert/clean) and pulling rewrite files on disk, but open
# editor tabs keep stale in-memory text until a rescan. Reload the tabs AND
# rescan so the reverted content shows immediately instead of lingering
# until the next editor focus regain (VSCode parity).
func _reload_editor_after_disk_change() -> void:
	if not Engine.is_editor_hint():
		_log("editor refresh skipped: not in editor.")
		return
	var se := EditorInterface.get_script_editor()
	if se != null:
		_log("editor refresh: reloading open script tabs from disk.")
		se.reload_open_files()
	else:
		_log("editor refresh: no script editor.")
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		_log("editor refresh: no filesystem for scan.")
		return
	if fs.is_scanning():
		_log("editor refresh: scan skipped (already scanning).")
		return
	_log("editor refresh: calling EditorFileSystem.scan().")
	fs.scan()


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
	if _owns_git_manager and git_manager != null:
		git_manager.shutdown()
		git_manager = null
		_owns_git_manager = false


func _enter_tree() -> void:
	_connect_git_manager()
	_connect_filesystem_signals()
	_check_git()
	if git_manager != null and git_manager.is_repo():
		git_manager.refresh_status()
	_log("Panel re-entered tree.")


func _check_git() -> void:
	if git_manager == null:
		return
	if status_label == null or branch_label == null:
		return
	if not git_manager.is_git_available():
		branch_label.text = "-"
		status_label.text = "Git not found. Please install Git."
		name = "Version Control"
		_set_repo_ui_visible(false)
		_set_empty_visible(false)
		return
	if not git_manager.is_repo():
		branch_label.text = "-"
		status_label.text = "Not a Git repository."
		status_label.add_theme_color_override("font_color", Color.GRAY)
		name = "Version Control"
		_set_repo_ui_visible(false)
		_set_empty_visible(true)
		if init_button != null:
			init_button.disabled = false
		return
	var branch := git_manager.get_branch()
	branch_label.text = branch
	if commit_message != null:
		commit_message.placeholder_text = "Message (Ctrl+Enter to commit on \"%s\")" % branch
	status_label.text = "Ready"
	_set_repo_ui_visible(true)
	_set_empty_visible(false)


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
	status_label.text = "Initializing repository..."
	git_manager.init_repo()


func _make_spacer(spacer_name: String) -> Control:
	var spacer := Control.new()
	spacer.name = spacer_name
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _make_file_tree(tree_name: String) -> Tree:
	var tree := Tree.new()
	tree.name = tree_name
	# Three columns like the sidepanel mock (design/Sidepanel.png; rows
	# documented in design/sidepanel/staged.md and design/sidepanel/changes.md):
	# file name (+ icon), muted directory, narrow right-aligned status letter.
	tree.columns = 3
	tree.column_titles_visible = false
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_MULTI
	tree.set_column_expand(0, true)
	tree.set_column_expand(1, true)
	tree.set_column_expand(2, false)
	tree.set_column_custom_minimum_width(2, 28)
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.custom_minimum_size = Vector2(0, 120)
	return tree


func _make_toolbar_button(button_name: String, glyph: String, tip: String) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = glyph
	button.tooltip_text = tip
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
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
	var badge := Label.new()
	badge.name = badge_name
	badge.text = "0"
	badge.tooltip_text = "Changed file count"
	var pill := StyleBoxFlat.new()
	pill.bg_color = Color(1, 1, 1, 0.14)
	pill.set_corner_radius_all(9)
	pill.content_margin_left = 8.0
	pill.content_margin_right = 8.0
	pill.content_margin_top = 1.0
	pill.content_margin_bottom = 1.0
	badge.add_theme_stylebox_override("normal", pill)
	return badge


func _style_commit_button() -> void:
	if commit_button == null:
		return
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("0e639c")
	normal.set_corner_radius_all(3)
	normal.content_margin_top = 6.0
	normal.content_margin_bottom = 6.0
	commit_button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("1177bb")
	commit_button.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color("0b4f7e")
	commit_button.add_theme_stylebox_override("pressed", pressed)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(1, 1, 1, 0.08)
	commit_button.add_theme_stylebox_override("disabled", disabled)
	commit_button.add_theme_color_override("font_color", Color.WHITE)
	commit_button.add_theme_color_override("font_hover_color", Color.WHITE)
	commit_button.add_theme_color_override("font_pressed_color", Color.WHITE)
	commit_button.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.35))


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


func _split_display_path(path: String) -> PackedStringArray:
	var dir := path.get_base_dir()
	if dir == "." or dir.is_empty():
		dir = ""
	return PackedStringArray([path.get_file(), dir])


func _status_display(code: String) -> String:
	if code == "?":
		return "U"
	return code


func _status_color(code: String) -> Color:
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


func _dim_color() -> Color:
	if has_theme_color("font_disabled_color", "Label"):
		return get_theme_color("font_disabled_color", "Label")
	return Color(0.55, 0.55, 0.55)


func _disable_row(item: TreeItem) -> void:
	for col in range(3):
		item.set_selectable(col, false)


func _add_file_row(tree: Tree, parent: TreeItem, path: String, code: String) -> void:
	var parts := _split_display_path(path)
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
	var display := _status_display(code)
	item.set_text(2, display)
	item.set_text_alignment(2, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_custom_color(2, _status_color(code))


func _build_ui() -> void:
	# --- Header bar ("Source Control" + quick actions, like the mock) ---
	var header_bar := HBoxContainer.new()
	header_bar.name = "HeaderBar"
	var header_title := Label.new()
	header_title.name = "HeaderTitle"
	header_title.text = "Source Control"
	header_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_title.add_theme_font_size_override("font_size", 13)
	header_bar.add_child(header_title)
	pull_button = _make_toolbar_button("HeaderPullButton", "↓", "Pull from remote")
	pull_button.pressed.connect(_on_pull)
	header_bar.add_child(pull_button)
	fetch_button = _make_toolbar_button("HeaderFetchButton", "⇄", "Fetch from remote")
	fetch_button.pressed.connect(_on_fetch)
	header_bar.add_child(fetch_button)
	push_button = _make_toolbar_button("HeaderPushButton", "↑", "Push to remote")
	push_button.pressed.connect(_on_push)
	header_bar.add_child(push_button)
	var refresh_toolbar_btn := _make_toolbar_button("RefreshButton", "↻", "Refresh")
	refresh_toolbar_btn.pressed.connect(_on_refresh)
	header_bar.add_child(refresh_toolbar_btn)
	git_actions_button = _make_toolbar_button("GitActionsButton", "⋯", "More git actions (pull, fetch, push, stage, .gitignore)")
	git_actions_button.pressed.connect(_on_git_actions)
	header_bar.add_child(git_actions_button)
	git_actions_menu = PopupMenu.new()
	git_actions_menu.name = "GitActionsMenu"
	git_actions_menu.add_item("Pull", 0)
	git_actions_menu.add_item("Fetch", 1)
	git_actions_menu.add_item("Push", 2)
	git_actions_menu.add_separator()
	git_actions_menu.add_item("Stage All", 3)
	git_actions_menu.add_item("Unstage All", 4)
	git_actions_menu.add_separator()
	git_actions_menu.add_item("Recall last commit message", 5)
	git_actions_menu.add_check_item("Sign off (--signoff)", 6)
	git_actions_menu.add_check_item("Debug log", 7)
	git_actions_menu.add_separator()
	git_actions_menu.add_item("Edit .gitignore", 8)
	# Match on item id (not position): separators shift indices, so
	# index_pressed would misroute every item below a separator.
	git_actions_menu.id_pressed.connect(_on_git_action_selected)
	git_actions_button.add_child(git_actions_menu)
	add_child(header_bar)
	_repo_ui.append(header_bar)

	# --- Commit section (top, like VSCode) ---
	var commit_box := VBoxContainer.new()
	commit_box.name = "CommitBox"
	commit_message = TextEdit.new()
	commit_message.name = "CommitMessage"
	commit_message.placeholder_text = "Message"
	commit_message.custom_minimum_size = Vector2(0, 64)
	commit_message.gui_input.connect(_on_commit_message_gui_input)
	commit_box.add_child(commit_message)
	var commit_row := HBoxContainer.new()
	commit_row.name = "CommitRow"
	commit_row.add_theme_constant_override("separation", 4)
	commit_button = Button.new()
	commit_button.name = "CommitButton"
	commit_button.text = "Commit"
	commit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_button.disabled = true
	commit_button.pressed.connect(_on_commit)
	_style_commit_button()
	commit_row.add_child(commit_button)
	commit_options_button = Button.new()
	commit_options_button.name = "CommitOptionsButton"
	commit_options_button.text = "▾"
	commit_options_button.tooltip_text = "Commit options"
	commit_options_button.pressed.connect(_on_commit_options)
	commit_row.add_child(commit_options_button)
	commit_options_menu = PopupMenu.new()
	commit_options_menu.name = "CommitOptionsMenu"
	commit_options_menu.add_item("Commit", 0)
	commit_options_menu.add_item("Commit & Push", 1)
	commit_options_menu.add_item("Commit & Stage", 2)
	commit_options_menu.add_item("Commit (Amend)", 3)
	commit_options_menu.index_pressed.connect(_on_commit_option_selected)
	commit_options_button.add_child(commit_options_menu)
	commit_box.add_child(commit_row)
	# Amend lives in the commit options menu, Sign off in the ⋯ git actions menu.
	add_child(commit_box)
	_repo_ui.append(commit_box)
	_hover_pill = StyleBoxFlat.new()
	_hover_pill.bg_color = Color(0.23, 0.24, 0.27)
	_hover_pill.set_corner_radius_all(4)
	_hover_pill.content_margin_left = 8.0
	_hover_pill.content_margin_right = 8.0
	_hover_pill.content_margin_top = 2.0
	_hover_pill.content_margin_bottom = 2.0

	# --- Staged Changes section (first, like the mock) ---
	var staged_header := HBoxContainer.new()
	staged_header.name = "StagedHeader"
	staged_toggle = _make_toolbar_button("StagedToggle", "▾", "Collapse section")
	staged_toggle.pressed.connect(_on_toggle_staged)
	staged_header.add_child(staged_toggle)
	staged_title = Label.new()
	staged_title.name = "StagedTitle"
	staged_title.text = "Staged Changes"
	staged_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	staged_header.add_child(staged_title)
	unstage_all_button = Button.new()
	unstage_all_button.name = "UnstageAllButton"
	unstage_all_button.text = "Unstage All"
	unstage_all_button.disabled = true
	unstage_all_button.pressed.connect(_on_unstage_all)
	staged_header.add_child(unstage_all_button)
	staged_badge = _make_badge("StagedBadge")
	staged_header.add_child(staged_badge)
	add_child(staged_header)
	_repo_ui.append(staged_header)

	tree_staged = _make_file_tree("StagedTree")
	tree_staged.item_selected.connect(_on_staged_selected)
	tree_staged.item_activated.connect(_on_unstage)
	tree_staged.gui_input.connect(_on_file_tree_gui_input.bind(tree_staged, true))
	tree_staged.mouse_exited.connect(_on_file_tree_mouse_exited)
	_staged_overlay = _make_hover_overlay(tree_staged, true)
	add_child(tree_staged)
	_repo_ui.append(tree_staged)
	staged_empty_label = Label.new()
	staged_empty_label.name = "StagedEmptyLabel"
	staged_empty_label.text = "No staged changes"
	staged_empty_label.add_theme_color_override("font_color", Color.GRAY)
	staged_empty_label.visible = false
	add_child(staged_empty_label)
	_repo_ui.append(staged_empty_label)
	staged_menu = PopupMenu.new()
	staged_menu.name = "StagedMenu"
	staged_menu.index_pressed.connect(_on_staged_menu_selected)
	add_child(staged_menu)

	var sep_sections := HSeparator.new()
	sep_sections.name = "SectionsSeparator"
	add_child(sep_sections)
	_repo_ui.append(sep_sections)

	# --- Changes section ---
	var changes_header := HBoxContainer.new()
	changes_header.name = "ChangesHeader"
	changes_toggle = _make_toolbar_button("ChangesToggle", "▾", "Collapse section")
	changes_toggle.pressed.connect(_on_toggle_changes)
	changes_header.add_child(changes_toggle)
	changes_title = Label.new()
	changes_title.name = "ChangesTitle"
	changes_title.text = "Changes"
	changes_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	changes_header.add_child(changes_title)
	stage_all_button = Button.new()
	stage_all_button.name = "StageAllButton"
	stage_all_button.text = "Stage All"
	stage_all_button.disabled = true
	stage_all_button.pressed.connect(_on_stage_all)
	changes_header.add_child(stage_all_button)
	changes_badge = _make_badge("ChangesBadge")
	changes_header.add_child(changes_badge)
	add_child(changes_header)
	_repo_ui.append(changes_header)

	tree_unstaged = _make_file_tree("UnstagedTree")
	tree_unstaged.item_selected.connect(_on_unstaged_selected)
	tree_unstaged.item_activated.connect(_on_stage)
	tree_unstaged.gui_input.connect(_on_file_tree_gui_input.bind(tree_unstaged, false))
	tree_unstaged.mouse_exited.connect(_on_file_tree_mouse_exited)
	_changes_overlay = _make_hover_overlay(tree_unstaged, false)
	add_child(tree_unstaged)
	_repo_ui.append(tree_unstaged)
	changes_empty_label = Label.new()
	changes_empty_label.name = "ChangesEmptyLabel"
	changes_empty_label.text = "No changes"
	changes_empty_label.add_theme_color_override("font_color", Color.GRAY)
	changes_empty_label.visible = false
	add_child(changes_empty_label)
	_repo_ui.append(changes_empty_label)
	changes_menu = PopupMenu.new()
	changes_menu.name = "ChangesMenu"
	changes_menu.index_pressed.connect(_on_changes_menu_selected)
	add_child(changes_menu)
	discard_dialog = ConfirmationDialog.new()
	discard_dialog.name = "DiscardDialog"
	discard_dialog.dialog_text = "Discard changes? This cannot be undone."
	discard_dialog.confirmed.connect(_on_discard_confirmed)
	add_child(discard_dialog)

	# --- Debug log (collapsible, hidden by default; toggle via header) ---
	log_box = VBoxContainer.new()
	log_box.name = "LogBox"
	log_box.visible = false
	var log_header := HBoxContainer.new()
	log_header.name = "LogHeader"
	var log_title := Label.new()
	log_title.name = "LogTitle"
	log_title.text = "Debug Log (last 200 lines)"
	log_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_title.add_theme_font_size_override("font_size", 12)
	log_header.add_child(log_title)
	var log_clear_btn := Button.new()
	log_clear_btn.name = "LogClearButton"
	log_clear_btn.text = "Clear"
	log_clear_btn.pressed.connect(_on_log_clear)
	log_header.add_child(log_clear_btn)
	log_box.add_child(log_header)
	log_text = TextEdit.new()
	log_text.name = "LogText"
	log_text.editable = false
	log_text.custom_minimum_size = Vector2(0, 120)
	log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.add_child(log_text)
	add_child(log_box)

	# --- Empty state: Init Git gets its own row, never the status bar ---
	init_button = Button.new()
	init_button.name = "InitButton"
	init_button.text = "Init Git"
	init_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	init_button.visible = false
	init_button.pressed.connect(_on_init_repo)
	add_child(init_button)
	# Spacer fills spare vertical space so the status/branch rows stay pinned to the bottom.
	var spacer := Control.new()
	spacer.name = "BottomSpacer"
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(spacer)
	# --- Status bar (bottom): branch only; message row above, buttons elsewhere ---
	var sep_bottom := HSeparator.new()
	sep_bottom.name = "SeparatorBottom"
	add_child(sep_bottom)
	_repo_ui.append(sep_bottom)
	# --- Status / error row (full width above the branch row; folds when narrow) ---
	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "Ready"
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.add_theme_color_override("font_color", Color.GRAY)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(status_label)
	var status_bar := HBoxContainer.new()
	status_bar.name = "StatusBar"
	branch_label = Label.new()
	branch_label.name = "BranchLabel"
	branch_label.text = "-"
	branch_label.add_theme_font_size_override("font_size", 13)
	status_bar.add_child(branch_label)
	add_child(status_bar)
	_build_ignore_dialog()


func _build_ignore_dialog() -> void:
	ignore_dialog = PopupPanel.new()
	ignore_dialog.name = "IgnoreDialog"
	var box := VBoxContainer.new()
	box.name = "IgnoreBox"
	box.custom_minimum_size = Vector2(420, 320)
	var title := Label.new()
	title.name = "IgnoreTitle"
	title.text = "res://.gitignore"
	box.add_child(title)
	ignore_text = TextEdit.new()
	ignore_text.name = "IgnoreText"
	ignore_text.placeholder_text = "One pattern per line, e.g. *.tmp"
	ignore_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(ignore_text)
	var row := HBoxContainer.new()
	row.name = "IgnoreRow"
	row.add_child(_make_spacer("IgnoreSpacer"))
	var save_btn := Button.new()
	save_btn.name = "IgnoreSaveButton"
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_ignore_save)
	row.add_child(save_btn)
	var cancel_btn := Button.new()
	cancel_btn.name = "IgnoreCancelButton"
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_on_ignore_cancel)
	row.add_child(cancel_btn)
	box.add_child(row)
	ignore_dialog.add_child(box)
	add_child(ignore_dialog)


func _on_refresh() -> void:
	if git_manager == null:
		return
	_check_git()
	if not git_manager.is_repo():
		return
	_log("Manual refresh requested.")
	git_manager.refresh_status()


# Debug log: ring buffer of the last LOG_MAX lines, mirrored to the Godot
# Output panel and to the collapsible in-dock viewer (header "≡" toggle).
func _log(msg: String) -> void:
	var line := "[%s] %s" % [Time.get_time_string_from_system(), msg]
	log_buffer.append(line)
	while log_buffer.size() > LOG_MAX:
		log_buffer.remove_at(0)
	print("[VersionControl] ", line)
	_update_log_view()


func _update_log_view() -> void:
	if log_text == null or not is_instance_valid(log_text):
		return
	log_text.text = "\n".join(log_buffer)


func _on_log_toggle() -> void:
	_log_collapsed = not _log_collapsed
	if log_box != null and is_instance_valid(log_box):
		log_box.visible = not _log_collapsed
		if not _log_collapsed:
			_update_log_view()
	if git_actions_menu != null and is_instance_valid(git_actions_menu):
		git_actions_menu.set_item_checked(git_actions_menu.get_item_index(7), not _log_collapsed)


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


func _on_pull() -> void:
	if git_manager == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	if not git_manager.has_remote():
		status_label.text = "Error: no git remote configured."
		status_label.add_theme_color_override("font_color", Color.RED)
		return
	_set_remote_enabled(false)
	status_label.text = "Pulling..."
	git_manager.pull()


func _on_fetch() -> void:
	if git_manager == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	if not git_manager.has_remote():
		status_label.text = "Error: no git remote configured."
		status_label.add_theme_color_override("font_color", Color.RED)
		return
	_set_remote_enabled(false)
	status_label.text = "Fetching..."
	git_manager.fetch()


func _on_git_actions() -> void:
	if git_actions_menu == null:
		return
	git_actions_menu.set_item_checked(git_actions_menu.get_item_index(6), _signoff_enabled)
	git_actions_menu.set_item_checked(git_actions_menu.get_item_index(7), not _log_collapsed)
	git_actions_menu.set_item_disabled(git_actions_menu.get_item_index(5), commit_message_history.is_empty())
	git_actions_menu.popup()


func _on_git_action_selected(index: int) -> void:
	match index:
		0:
			_on_pull()
		1:
			_on_fetch()
		2:
			_on_push()
		3:
			_on_stage_all()
		4:
			_on_unstage_all()
		5:
			_recall_last_commit_message()
		6:
			_signoff_enabled = not _signoff_enabled
			if git_actions_menu != null:
				git_actions_menu.set_item_checked(git_actions_menu.get_item_index(6), _signoff_enabled)
		7:
			_on_log_toggle()
		8:
			_on_edit_ignore()


func _on_push() -> void:
	if git_manager == null:
		return
	if not git_manager.is_repo():
		_check_git()
		return
	if not git_manager.has_remote():
		status_label.text = "Error: no git remote configured."
		status_label.add_theme_color_override("font_color", Color.RED)
		return
	_set_remote_enabled(false)
	status_label.text = "Pushing..."
	git_manager.push()


func _on_edit_ignore() -> void:
	if status_label == null or ignore_dialog == null or ignore_text == null:
		return
	var ignore_path := ProjectSettings.globalize_path("res://.gitignore")
	if not FileAccess.file_exists(ignore_path):
		var created := FileAccess.open(ignore_path, FileAccess.WRITE)
		if created == null:
			status_label.text = "Error: cannot create .gitignore"
			status_label.add_theme_color_override("font_color", Color.RED)
			return
		created.close()
	var reader := FileAccess.open(ignore_path, FileAccess.READ)
	if reader == null:
		status_label.text = "Error: cannot read .gitignore"
		status_label.add_theme_color_override("font_color", Color.RED)
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
		status_label.text = "Error: cannot write .gitignore"
		status_label.add_theme_color_override("font_color", Color.RED)
		return
	writer.store_string(ignore_text.text)
	writer.close()
	ignore_dialog.hide()
	status_label.text = "Saved .gitignore"
	status_label.add_theme_color_override("font_color", Color.GRAY)
	if git_manager != null and git_manager.is_repo():
		git_manager.refresh_status()


func _on_ignore_cancel() -> void:
	if ignore_dialog != null:
		ignore_dialog.hide()


func _on_status_changed(files: Array) -> void:
	unstaged_files.clear()
	staged_files.clear()
	for f in files:
		var s: String = f["status"]
		var first: String = s.left(1)
		var second: String = s.right(1)
		if first == "?":
			unstaged_files.append(f)
		else:
			var staged: bool = first != " "
			var unstaged: bool = second != " "
			if staged:
				staged_files.append(f)
			if unstaged and not staged:
				unstaged_files.append(f)
			elif unstaged and staged:
				unstaged_files.append(f)
	_log("status: %d staged, %d unstaged." % [staged_files.size(), unstaged_files.size()])
	_update_tree()
	_update_dirty_badge()


func _update_dirty_badge() -> void:
	var dirty := not unstaged_files.is_empty() or not staged_files.is_empty()
	name = "Version Control (*)" if dirty else "Version Control"


func _update_tree() -> void:
	if tree_unstaged == null or tree_staged == null:
		return
	tree_unstaged.clear()
	tree_staged.clear()
	# clear() frees every TreeItem, so drop hover refs before rebuilding.
	_hover_tree = null
	_hover_item = null
	_hover_hit = []

	# With hide_root=true the first top-level item is hidden, so create an
	# explicit (empty) root and parent every file row under it. Otherwise the
	# first file becomes the hidden root and never renders (a single changed
	# file shows an empty tree).
	var root_unstaged := tree_unstaged.create_item()
	_disable_row(root_unstaged)
	var root_staged := tree_staged.create_item()
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
		# only the file name, column 1 the directory, like the mock).
		var meta = item.get_metadata(0)
		if meta != null and not String(meta).is_empty():
			selected.append(String(meta))
		else:
			var dir := item.get_text(1)
			if dir.is_empty():
				selected.append(item.get_text(0))
			else:
				selected.append(dir.path_join(item.get_text(0)))
		item = tree.get_next_selected(item)
	return selected


func _stage_paths(paths: PackedStringArray) -> void:
	if paths.is_empty() or git_manager == null:
		return
	stage_requested.emit(paths)
	git_manager.stage_files(paths)


func _unstage_paths(paths: PackedStringArray) -> void:
	if paths.is_empty() or git_manager == null:
		return
	unstage_requested.emit(paths)
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
		_staged_menu_paths = _menu_targets(hovered, selected_staged)
		_show_staged_menu()
	else:
		_changes_menu_paths = _menu_targets(hovered, selected_unstaged)
		_show_changes_menu()


# If the right-clicked row is part of a multi-selection, act on the whole
# selection (like VSCode); otherwise act on the hovered row alone.
func _menu_targets(hovered: String, selected: PackedStringArray) -> PackedStringArray:
	if selected.size() > 1 and hovered in selected:
		return selected
	return PackedStringArray([hovered])


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
	_hover_hit = []
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


# Discarding an untracked file deletes it from disk, so as a safety net only
# plain repo-relative paths are accepted (never absolute paths or `..`).
func _is_safe_repo_relative(path: String) -> bool:
	if path.is_empty() or path.is_absolute_path() or path.begins_with("~"):
		return false
	for part in path.split("/"):
		if part == "..":
			return false
	return true


func _is_untracked(path: String) -> bool:
	for f in unstaged_files:
		if String(f.get("path", "")) == path:
			return String(f.get("status", "")).strip_edges() == "??"
	return false


func _ask_discard_changes(paths: PackedStringArray) -> void:
	if paths.is_empty() or git_manager == null:
		return
	var tracked := PackedStringArray()
	var untracked := PackedStringArray()
	for p in paths:
		if _is_untracked(p):
			if _is_safe_repo_relative(p):
				untracked.append(p)
			else:
				push_warning("Version Control: refusing to delete suspicious path: %s" % p)
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
	var tracked := _discard_paths
	var untracked := _discard_untracked_paths
	_discard_paths = PackedStringArray()
	_discard_untracked_paths = PackedStringArray()
	if tracked.is_empty() and untracked.is_empty():
		return
	var all := PackedStringArray()
	all.append_array(tracked)
	all.append_array(untracked)
	discard_requested.emit(all)
	if status_label != null:
		status_label.text = "Discarding changes..."
	_log("Discard confirmed: revert=[%s] clean=[%s]" % [", ".join(tracked), ", ".join(untracked)])
	if not tracked.is_empty():
		_log("git restore --source=HEAD --staged --worktree -- %s" % ", ".join(tracked))
		git_manager.revert_changes(tracked)
	if not untracked.is_empty():
		_log("git clean -fd -- %s" % ", ".join(untracked))
		git_manager.discard_untracked(untracked)


func _open_file_in_editor(repo_path: String) -> void:
	if repo_path.is_empty() or not Engine.is_editor_hint():
		return
	var res_path := "res://" + repo_path
	if ResourceLoader.exists(res_path):
		var res := ResourceLoader.load(res_path)
		if res != null:
			EditorInterface.edit_resource(res)
			return
	EditorInterface.get_file_system_dock().navigate_to_path(res_path)


func _on_commit(push_after: bool = false, stage_first: bool = false, force_amend: bool = false) -> void:
	if commit_message == null or git_manager == null:
		return
	var msg := commit_message.text.strip_edges()
	if msg.is_empty():
		return
	var amend_on := force_amend
	var signoff_on := _signoff_enabled
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
		stage_requested.emit(paths)
		git_manager.stage_files(paths)
		return
	_dispatch_commit(msg, amend_on, signoff_on, push_after)


func _dispatch_commit(msg: String, amend_on: bool, signoff_on: bool, push_after: bool) -> void:
	commit_requested.emit(msg)
	_commit_and_push = push_after
	_remember_commit_message(msg)
	_history_recall_index = -1
	git_manager.commit(msg, amend_on, signoff_on)
	if commit_message != null:
		commit_message.text = ""


func _remember_commit_message(msg: String) -> void:
	var cleaned := msg.strip_edges()
	if cleaned.is_empty():
		return
	commit_message_history.erase(cleaned)
	commit_message_history.insert(0, cleaned)
	while commit_message_history.size() > COMMIT_HISTORY_MAX:
		commit_message_history.resize(COMMIT_HISTORY_MAX)


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
		status_label.text = "Committed. Error: no git remote configured for push."
		status_label.add_theme_color_override("font_color", Color.RED)
		return
	_set_remote_enabled(false)
	status_label.text = "Committed. Pushing..."
	git_manager.push()


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
		var staged_visible := not _staged_collapsed and not staged_files.is_empty()
		tree_staged.visible = staged_visible
		tree_staged.size_flags_vertical = Control.SIZE_EXPAND_FILL if staged_visible else 0
		tree_staged.custom_minimum_size = Vector2(0, 120) if staged_visible else Vector2(0, 0)
	if staged_empty_label != null and is_instance_valid(staged_empty_label):
		staged_empty_label.visible = not _staged_collapsed and staged_files.is_empty()
	if tree_unstaged != null and is_instance_valid(tree_unstaged):
		var unstaged_visible := not _changes_collapsed and not unstaged_files.is_empty()
		tree_unstaged.visible = unstaged_visible
		tree_unstaged.size_flags_vertical = Control.SIZE_EXPAND_FILL if unstaged_visible else 0
		tree_unstaged.custom_minimum_size = Vector2(0, 120) if unstaged_visible else Vector2(0, 0)
	if changes_empty_label != null and is_instance_valid(changes_empty_label):
		changes_empty_label.visible = not _changes_collapsed and unstaged_files.is_empty()


func _on_operation_complete(result: Dictionary) -> void:
	if status_label == null:
		return
	var op_msg := "op complete: action=%s exit_code=%s" % [str(result.get("action", "?")), str(result.get("exit_code", "?"))]
	if result.has("error"):
		op_msg += " error=%s" % str(result.get("error", ""))
	_log(op_msg)
	if result.get("action") == "init":
		if init_button != null:
			init_button.disabled = false
		_check_git()
		if result.has("error"):
			status_label.text = "Error: %s" % result.get("error", "Unknown error")
			status_label.add_theme_color_override("font_color", Color.RED)
		elif git_manager != null and git_manager.is_repo():
			status_label.text = "Repository initialized!"
			status_label.add_theme_color_override("font_color", Color.GREEN)
			git_manager.refresh_status()
		return
	if result.get("action") == "pull" or result.get("action") == "push" or result.get("action") == "fetch":
		_set_remote_enabled(true)
		if result.has("error"):
			status_label.text = "Error: %s" % result.get("error", "Unknown error")
			status_label.add_theme_color_override("font_color", Color.RED)
		elif result.get("action") == "pull":
			status_label.text = "Pulled successfully!"
			status_label.add_theme_color_override("font_color", Color.GREEN)
			# Pull can rewrite tracked files on disk (fast-forward): refresh
			# the editor so open tabs reload instead of showing stale content.
			_reload_editor_after_disk_change()
		elif result.get("action") == "fetch":
			status_label.text = "Fetched successfully!"
			status_label.add_theme_color_override("font_color", Color.GREEN)
		else:
			status_label.text = "Pushed successfully!"
			status_label.add_theme_color_override("font_color", Color.GREEN)
		return
	# A "Commit & Stage" first stages everything, then commits once the stage
	# op lands. The stage op already triggered a status refresh; the commit
	# reads the on-disk index directly, so it is safe to dispatch now.
	if result.get("action") == "stage" and not _pending_commit_after_stage.is_empty():
		var pending := _pending_commit_after_stage
		_pending_commit_after_stage = {}
		if result.get("exit_code", 0) != 0:
			_commit_and_push = false
			status_label.text = "Error: staging before commit failed."
			status_label.add_theme_color_override("font_color", Color.RED)
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
		var completed := String(result.get("action", ""))
		if completed == "revert" or completed == "clean":
			_reload_editor_after_disk_change()
	if result.has("error"):
		_commit_and_push = false
		_pending_commit_after_stage = {}
		status_label.text = "Error: %s" % result.get("error", "Unknown error")
		status_label.add_theme_color_override("font_color", Color.RED)
	elif result.get("action") == "commit" and result.get("exit_code", 0) == 0:
		if _commit_and_push:
			_push_after_commit()
			return
		status_label.text = "Committed successfully!"
		status_label.add_theme_color_override("font_color", Color.GREEN)
		await get_tree().create_timer(3.0).timeout
		if not is_instance_valid(status_label):
			return
		status_label.text = "Ready"
		status_label.add_theme_color_override("font_color", Color.GRAY)
	else:
		status_label.text = "Ready"
		status_label.add_theme_color_override("font_color", Color.GRAY)
