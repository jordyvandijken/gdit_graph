@tool
extends VBoxContainer
class_name VersionControlPanel

signal stage_requested(paths: PackedStringArray)
signal unstage_requested(paths: PackedStringArray)
signal commit_requested(message: String)

var git_manager: GitManager
var _owns_git_manager: bool = false
var _ui_built: bool = false

var unstaged_files: Array = []
var staged_files: Array = []
var selected_unstaged: PackedStringArray = []
var selected_staged: PackedStringArray = []

var tree_unstaged: Tree
var tree_staged: Tree
var commit_message: TextEdit
var branch_label: Label
var status_label: Label
var changes_title: Label
var staged_title: Label
var stage_button: Button
var unstage_button: Button
var stage_all_button: Button
var unstage_all_button: Button
var commit_button: Button
var init_button: Button
var pull_button: Button
var push_button: Button
var ignore_button: Button
var ignore_dialog: PopupPanel
var ignore_text: TextEdit
var _repo_ui: Array = []


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


func _ready() -> void:
	_build_ui()
	_ui_built = true
	_ensure_git_manager()
	_connect_git_manager()
	_check_git()
	if git_manager != null and git_manager.is_repo():
		git_manager.refresh_status()


func _exit_tree() -> void:
	_disconnect_git_manager()
	if _owns_git_manager and git_manager != null:
		git_manager.shutdown()
		git_manager = null
		_owns_git_manager = false


func _check_git() -> void:
	if git_manager == null:
		return
	if status_label == null or branch_label == null:
		return
	if not git_manager.is_git_available():
		branch_label.text = "Branch: -"
		status_label.text = "Git not found. Please install Git."
		name = "Version Control"
		_set_repo_ui_visible(false)
		if init_button != null:
			init_button.visible = false
		return
	if not git_manager.is_repo():
		branch_label.text = "Branch: -"
		status_label.text = "Not a Git repository."
		status_label.add_theme_color_override("font_color", Color.GRAY)
		name = "Version Control"
		_set_repo_ui_visible(false)
		if init_button != null:
			init_button.visible = true
			init_button.disabled = false
		return
	var branch := git_manager.get_branch()
	branch_label.text = "Branch: %s" % branch
	status_label.text = "Ready"
	_set_repo_ui_visible(true)
	if init_button != null:
		init_button.visible = false


func _set_repo_ui_visible(visible: bool) -> void:
	for control in _repo_ui:
		if is_instance_valid(control):
			(control as Control).visible = visible


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
	tree.columns = 2
	tree.column_titles_visible = false
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_MULTI
	tree.set_column_custom_minimum_width(0, 32)
	tree.set_column_expand(1, true)
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.custom_minimum_size = Vector2(0, 120)
	return tree


func _build_ui() -> void:
	# --- Commit section (top, like VSCode) ---
	var commit_box := VBoxContainer.new()
	commit_box.name = "CommitBox"
	commit_message = TextEdit.new()
	commit_message.name = "CommitMessage"
	commit_message.placeholder_text = "Message"
	commit_message.custom_minimum_size = Vector2(0, 64)
	commit_box.add_child(commit_message)
	var commit_row := HBoxContainer.new()
	commit_row.name = "CommitRow"
	commit_row.add_child(_make_spacer("CommitSpacer"))
	commit_button = Button.new()
	commit_button.name = "CommitButton"
	commit_button.text = "Commit"
	commit_button.disabled = true
	commit_button.pressed.connect(_on_commit)
	commit_row.add_child(commit_button)
	commit_box.add_child(commit_row)
	add_child(commit_box)
	_repo_ui.append(commit_box)
	var sep_top := HSeparator.new()
	sep_top.name = "SeparatorTop"
	add_child(sep_top)
	_repo_ui.append(sep_top)

	# --- Changes section ---
	var changes_header := HBoxContainer.new()
	changes_header.name = "ChangesHeader"
	changes_title = Label.new()
	changes_title.name = "ChangesTitle"
	changes_title.text = "Changes"
	changes_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	changes_header.add_child(changes_title)
	stage_all_button = Button.new()
	stage_all_button.name = "StageAllButton"
	stage_all_button.text = "Stage All Changes"
	stage_all_button.disabled = true
	stage_all_button.pressed.connect(_on_stage_all)
	changes_header.add_child(stage_all_button)
	add_child(changes_header)
	_repo_ui.append(changes_header)

	tree_unstaged = _make_file_tree("UnstagedTree")
	tree_unstaged.item_selected.connect(_on_unstaged_selected)
	tree_unstaged.item_activated.connect(_on_stage)
	add_child(tree_unstaged)
	_repo_ui.append(tree_unstaged)
	stage_button = Button.new()
	stage_button.name = "StageButton"
	stage_button.text = "Stage Selected"
	stage_button.disabled = true
	stage_button.pressed.connect(_on_stage)
	add_child(stage_button)
	_repo_ui.append(stage_button)

	# --- Staged Changes section ---
	var staged_header := HBoxContainer.new()
	staged_header.name = "StagedHeader"
	staged_title = Label.new()
	staged_title.name = "StagedTitle"
	staged_title.text = "Staged Changes"
	staged_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	staged_header.add_child(staged_title)
	unstage_all_button = Button.new()
	unstage_all_button.name = "UnstageAllButton"
	unstage_all_button.text = "Unstage All Changes"
	unstage_all_button.disabled = true
	unstage_all_button.pressed.connect(_on_unstage_all)
	staged_header.add_child(unstage_all_button)
	add_child(staged_header)
	_repo_ui.append(staged_header)

	tree_staged = _make_file_tree("StagedTree")
	tree_staged.item_selected.connect(_on_staged_selected)
	tree_staged.item_activated.connect(_on_unstage)
	add_child(tree_staged)
	_repo_ui.append(tree_staged)
	unstage_button = Button.new()
	unstage_button.name = "UnstageButton"
	unstage_button.text = "Unstage Selected"
	unstage_button.disabled = true
	unstage_button.pressed.connect(_on_unstage)
	add_child(unstage_button)
	_repo_ui.append(unstage_button)

	# --- Status bar (bottom) ---
	var sep_bottom := HSeparator.new()
	sep_bottom.name = "SeparatorBottom"
	add_child(sep_bottom)
	_repo_ui.append(sep_bottom)
	var status_bar := HBoxContainer.new()
	status_bar.name = "StatusBar"
	branch_label = Label.new()
	branch_label.name = "BranchLabel"
	branch_label.text = "Branch: -"
	branch_label.add_theme_font_size_override("font_size", 14)
	status_bar.add_child(branch_label)
	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "Ready"
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.add_theme_color_override("font_color", Color.GRAY)
	status_bar.add_child(status_label)
	status_bar.add_child(_make_spacer("StatusSpacer"))
	init_button = Button.new()
	init_button.name = "InitButton"
	init_button.text = "Init Git"
	init_button.visible = false
	init_button.pressed.connect(_on_init_repo)
	status_bar.add_child(init_button)
	pull_button = Button.new()
	pull_button.name = "PullButton"
	pull_button.text = "Pull"
	pull_button.pressed.connect(_on_pull)
	status_bar.add_child(pull_button)
	_repo_ui.append(pull_button)
	push_button = Button.new()
	push_button.name = "PushButton"
	push_button.text = "Push"
	push_button.pressed.connect(_on_push)
	status_bar.add_child(push_button)
	_repo_ui.append(push_button)
	ignore_button = Button.new()
	ignore_button.name = "IgnoreButton"
	ignore_button.text = ".gitignore"
	ignore_button.pressed.connect(_on_edit_ignore)
	status_bar.add_child(ignore_button)
	_repo_ui.append(ignore_button)
	var refresh_btn := Button.new()
	refresh_btn.name = "RefreshButton"
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(_on_refresh)
	status_bar.add_child(refresh_btn)
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
	git_manager.refresh_status()


func _set_pull_push_enabled(enabled: bool) -> void:
	if pull_button != null:
		pull_button.disabled = not enabled
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
	_set_pull_push_enabled(false)
	status_label.text = "Pulling..."
	git_manager.pull()


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
	_set_pull_push_enabled(false)
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

	# With hide_root=true the first top-level item is hidden, so create an
	# explicit (empty) root and parent every file row under it. Otherwise the
	# first file becomes the hidden root and never renders (a single changed
	# file shows an empty tree).
	var root_unstaged := tree_unstaged.create_item()
	root_unstaged.set_selectable(0, false)
	root_unstaged.set_selectable(1, false)
	var root_staged := tree_staged.create_item()
	root_staged.set_selectable(0, false)
	root_staged.set_selectable(1, false)

	if changes_title:
		changes_title.text = "Changes (%d)" % unstaged_files.size()
	if staged_title:
		staged_title.text = "Staged Changes (%d)" % staged_files.size()

	var status_colors := {
		"M": Color(0.9, 0.7, 0.1),
		"A": Color(0.2, 0.8, 0.2),
		"D": Color(0.9, 0.2, 0.2),
		"R": Color(0.2, 0.5, 0.9),
		"C": Color(0.2, 0.5, 0.9),
		"?": Color(0.2, 0.8, 0.2),
	}

	for f in unstaged_files:
		var item := tree_unstaged.create_item(root_unstaged)
		# Show the worktree (unstaged) code: " M" -> "M", "??" -> "?".
		var ucode: String = f["status"].right(1)
		if ucode == " ":
			ucode = f["status"].left(1)
		item.set_text(0, ucode)
		item.set_text(1, f["path"])
		item.set_tooltip_text(1, f["path"])
		var sc: Color = status_colors.get(ucode, Color.WHITE)
		item.set_custom_color(0, sc)
		item.set_custom_color(1, sc)

	for f in staged_files:
		var item := tree_staged.create_item(root_staged)
		# Show the index (staged) code: "AM" -> "A".
		var scode: String = f["status"].left(1)
		if scode == " ":
			scode = f["status"].right(1)
		item.set_text(0, scode)
		item.set_text(1, f["path"])
		item.set_tooltip_text(1, f["path"])
		var sc := status_colors.get(scode, Color.WHITE)
		item.set_custom_color(0, sc)
		item.set_custom_color(1, sc)

	if commit_button:
		commit_button.disabled = staged_files.is_empty()
	if stage_all_button:
		stage_all_button.disabled = unstaged_files.is_empty()
	if unstage_all_button:
		unstage_all_button.disabled = staged_files.is_empty()


func _on_unstaged_selected() -> void:
	selected_unstaged = _get_selected_items(tree_unstaged)
	stage_button.disabled = selected_unstaged.is_empty()


func _on_staged_selected() -> void:
	selected_staged = _get_selected_items(tree_staged)
	unstage_button.disabled = selected_staged.is_empty()


func _get_selected_items(tree: Tree) -> PackedStringArray:
	var selected := PackedStringArray()
	var item: TreeItem = tree.get_next_selected(null)
	while item != null:
		selected.append(item.get_text(1))
		item = tree.get_next_selected(item)
	return selected


func _on_stage() -> void:
	if selected_unstaged.is_empty() or git_manager == null:
		return
	stage_requested.emit(selected_unstaged)
	git_manager.stage_files(selected_unstaged)
	selected_unstaged.clear()


func _on_unstage() -> void:
	if selected_staged.is_empty() or git_manager == null:
		return
	unstage_requested.emit(selected_staged)
	git_manager.unstage_files(selected_staged)
	selected_staged.clear()


func _on_stage_all() -> void:
	if unstaged_files.is_empty() or git_manager == null:
		return
	var paths := PackedStringArray()
	for f in unstaged_files:
		paths.append(f["path"])
	stage_requested.emit(paths)
	git_manager.stage_files(paths)


func _on_unstage_all() -> void:
	if staged_files.is_empty() or git_manager == null:
		return
	var paths := PackedStringArray()
	for f in staged_files:
		paths.append(f["path"])
	unstage_requested.emit(paths)
	git_manager.unstage_files(paths)


func _on_commit() -> void:
	if commit_message == null or git_manager == null:
		return
	var msg := commit_message.text.strip_edges()
	if msg.is_empty():
		return
	commit_requested.emit(msg)
	git_manager.commit(msg)
	commit_message.text = ""


func _on_operation_complete(result: Dictionary) -> void:
	if status_label == null:
		return
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
	if result.get("action") == "pull" or result.get("action") == "push":
		_set_pull_push_enabled(true)
		if result.has("error"):
			status_label.text = "Error: %s" % result.get("error", "Unknown error")
			status_label.add_theme_color_override("font_color", Color.RED)
		elif result.get("action") == "pull":
			status_label.text = "Pulled successfully!"
			status_label.add_theme_color_override("font_color", Color.GREEN)
		else:
			status_label.text = "Pushed successfully!"
			status_label.add_theme_color_override("font_color", Color.GREEN)
		return
	if result.has("error"):
		status_label.text = "Error: %s" % result.get("error", "Unknown error")
		status_label.add_theme_color_override("font_color", Color.RED)
	elif result.get("action") == "commit" and result.get("exit_code", 0) == 0:
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
