# Commit details view (Phase 2: plan sections II row 3, III.B core, V.7).
#
# Expandable bottom section of the graph tab: commit subject/meta/message,
# changed-file list with status letters, inline per-file diff (commit_diff),
# and Open File / Copy Path actions. Pure view — the panel fetches data via
# GraphManager and pushes it here; file/open requests go back out as
# signals so the panel stays the only place that touches git + status.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/commit_details.gd").
@tool
extends VBoxContainer

signal file_selected(path)
signal open_file_requested(path)
signal copy_path_requested(path)

const CommitDiffScript = preload("res://addons/gdit_graph/workpanel/commit_diff.gd")
const DetailsGraphUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")

var subject_label = null
var meta_label = null
var message_view = null
var files_title = null
var files_tree = null
var diff_title = null
var open_button = null
var copy_button = null
var diff_view = null

var _ui_built = false
var _rebuilding = false
var _commit_hash = ""
var _selected_path = ""


func _ready() -> void:
	_build_ui()
	_ui_built = true


func _dim_color() -> Color:
	if has_theme_color("font_disabled_color", "Label"):
		return get_theme_color("font_disabled_color", "Label")
	return Color(0.6, 0.6, 0.6)


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


func _build_ui() -> void:
	if _ui_built:
		return
	subject_label = Label.new()
	subject_label.name = "DetailsSubject"
	subject_label.text = "No commit selected"
	subject_label.add_theme_font_size_override("font_size", 14)
	subject_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(subject_label)

	meta_label = Label.new()
	meta_label.name = "DetailsMeta"
	meta_label.text = ""
	meta_label.add_theme_font_size_override("font_size", 12)
	meta_label.add_theme_color_override("font_color", _dim_color())
	meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(meta_label)

	message_view = RichTextLabel.new()
	message_view.name = "DetailsMessage"
	message_view.bbcode_enabled = true
	message_view.scroll_active = true
	message_view.selection_enabled = true
	message_view.custom_minimum_size = Vector2(0, 44)
	message_view.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	message_view.meta_clicked.connect(_on_message_link)
	add_child(message_view)

	files_title = Label.new()
	files_title.name = "DetailsFilesTitle"
	files_title.text = "Files"
	files_title.add_theme_font_size_override("font_size", 13)
	add_child(files_title)

	files_tree = Tree.new()
	files_tree.name = "DetailsFiles"
	files_tree.columns = 2
	files_tree.column_titles_visible = false
	files_tree.hide_root = true
	files_tree.select_mode = Tree.SELECT_SINGLE
	files_tree.set_column_expand(0, true)
	files_tree.set_column_expand(1, false)
	files_tree.set_column_custom_minimum_width(1, 28)
	files_tree.custom_minimum_size = Vector2(0, 90)
	files_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	files_tree.allow_rmb_select = true
	files_tree.item_selected.connect(_on_file_row_selected)
	add_child(files_tree)

	var diff_row := HBoxContainer.new()
	diff_row.name = "DetailsDiffRow"
	diff_row.add_theme_constant_override("separation", 6)
	diff_title = Label.new()
	diff_title.name = "DetailsDiffTitle"
	diff_title.text = "Diff"
	diff_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_title.add_theme_font_size_override("font_size", 13)
	diff_title.clip_text = true
	diff_row.add_child(diff_title)
	open_button = Button.new()
	open_button.name = "DetailsOpenButton"
	open_button.text = "Open File"
	open_button.tooltip_text = "Open the selected file in the editor"
	open_button.disabled = true
	open_button.pressed.connect(_on_open_pressed)
	diff_row.add_child(open_button)
	copy_button = Button.new()
	copy_button.name = "DetailsCopyButton"
	copy_button.text = "Copy Path"
	copy_button.tooltip_text = "Copy the selected file path to the clipboard"
	copy_button.disabled = true
	copy_button.pressed.connect(_on_copy_pressed)
	diff_row.add_child(copy_button)
	add_child(diff_row)

	diff_view = CommitDiffScript.new()
	diff_view.name = "DetailsDiff"
	diff_view.custom_minimum_size = Vector2(0, 120)
	diff_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(diff_view)


func clear() -> void:
	_commit_hash = ""
	_selected_path = ""
	if not _ui_built:
		return
	subject_label.text = "No commit selected"
	meta_label.text = ""
	message_view.text = ""
	files_title.text = "Files"
	_rebuilding = true
	files_tree.clear()
	_rebuilding = false
	diff_title.text = "Diff"
	open_button.disabled = true
	copy_button.disabled = true
	diff_view.show_message("Select a commit to view its files.")


# Immediate lightweight display from the graph row while details load.
func show_commit(commit: Dictionary) -> void:
	if not _ui_built:
		_build_ui()
		_ui_built = true
	_commit_hash = String(commit.get("hash", ""))
	_selected_path = ""
	var row_subject := String(commit.get("subject", ""))
	subject_label.text = row_subject if not row_subject.is_empty() else "(no subject)"
	meta_label.text = "%s  %s — %s" % [
		String(commit.get("short", "")),
		String(commit.get("author", "")),
		String(commit.get("date", "")),
	]
	message_view.text = ""
	message_view.visible = false
	files_title.text = "Files (loading...)"
	_rebuilding = true
	files_tree.clear()
	_rebuilding = false
	diff_title.text = "Diff"
	open_button.disabled = true
	copy_button.disabled = true
	diff_view.set_loading()


func show_load_error(msg: String) -> void:
	if not _ui_built:
		return
	files_title.text = "Files"
	_rebuilding = true
	files_tree.clear()
	_rebuilding = false
	open_button.disabled = true
	copy_button.disabled = true
	diff_view.show_message(String(msg))


# Full details from GraphManager.commit_details_loaded.
func show_details(details: Dictionary) -> void:
	if not _ui_built:
		return
	_commit_hash = String(details.get("hash", _commit_hash))
	var subject := String(details.get("subject", ""))
	subject_label.text = subject if not subject.is_empty() else "(no subject)"
	var meta_bits := PackedStringArray()
	if String(details.get("short", "")) != "":
		meta_bits.append(String(details.get("short", "")))
	var author_line := String(details.get("author", ""))
	if String(details.get("author_date", "")) != "":
		author_line += "  " + String(details.get("author_date", ""))
	if not author_line.strip_edges().is_empty():
		meta_bits.append(author_line)
	if String(details.get("committer", "")) != "" and String(details.get("committer", "")) != String(details.get("author", "")):
		var committer_line := String(details.get("committer", ""))
		if String(details.get("committer_date", "")) != "":
			committer_line += "  " + String(details.get("committer_date", ""))
		meta_bits.append("Committer: " + committer_line)
	meta_bits.append(_commit_hash)
	meta_label.text = "\n".join(meta_bits)
	var body := String(details.get("body", ""))
	if body.is_empty():
		message_view.text = ""
		message_view.visible = false
	else:
		message_view.visible = true
		message_view.text = DetailsGraphUtils.message_to_bbcode(body)
	_rebuild_files(details.get("files", []))


func _rebuild_files(files: Array) -> void:
	_rebuilding = true
	files_tree.clear()
	var root: TreeItem = files_tree.create_item()
	root.set_selectable(0, false)
	root.set_selectable(1, false)
	for f in files:
		var info: Dictionary = f
		var item: TreeItem = files_tree.create_item(root)
		var path := String(info.get("path", ""))
		item.set_metadata(0, path)
		item.set_text(0, path)
		item.set_tooltip_text(0, _file_tooltip(info))
		var code := String(info.get("status", "M"))
		item.set_text(1, code)
		item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(1, _status_color(code))
	_rebuilding = false
	files_title.text = "Files (%d)" % files.size()
	_selected_path = ""
	open_button.disabled = true
	copy_button.disabled = true
	if files.is_empty():
		diff_title.text = "Diff"
		diff_view.show_message("No files changed in this commit.")
	else:
		# Auto-select the first file so a diff shows immediately, like VSCode.
		# select() emits item_selected, so suppress it and drive the single
		# file_selected emission manually (exactly one diff request).
		var first: TreeItem = root.get_first_child()
		if first != null:
			_rebuilding = true
			first.select(0)
			_rebuilding = false
			_on_file_row_selected()


func _file_tooltip(info: Dictionary) -> String:
	var path := String(info.get("path", ""))
	var old_path := String(info.get("old_path", ""))
	if not old_path.is_empty():
		return "%s -> %s" % [old_path, path]
	return path


func get_selected_path() -> String:
	return _selected_path


func get_commit_hash() -> String:
	return _commit_hash


func _on_file_row_selected() -> void:
	if _rebuilding or files_tree == null:
		return
	var item: TreeItem = files_tree.get_selected()
	if item == null:
		return
	var meta = item.get_metadata(0)
	if meta == null or String(meta).is_empty():
		return
	_selected_path = String(meta)
	diff_title.text = _selected_path
	open_button.disabled = false
	copy_button.disabled = false
	diff_view.set_loading()
	file_selected.emit(_selected_path)


func _on_open_pressed() -> void:
	if not _selected_path.is_empty():
		open_file_requested.emit(_selected_path)


func _on_copy_pressed() -> void:
	if not _selected_path.is_empty():
		copy_path_requested.emit(_selected_path)


func _on_message_link(meta: Variant) -> void:
	var url := String(meta)
	if url.begins_with("http://") or url.begins_with("https://"):
		OS.shell_open(url)
