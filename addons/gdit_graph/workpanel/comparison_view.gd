# Two-commit comparison view (Phase 4: plan sections II row 4, III.C, V.17).
#
# Expandable section below Commit Details: header with the A/B short hashes,
# a swap button and a close button; a file Tree (path + status, same shape
# as commit_details) and the shared commit_diff.gd inline diff renderer.
# Pure view — the panel fetches `git diff --name-status A B` and
# `git diff A B -- path` via GraphManager and pushes results here; open/copy
# requests go back out as signals so the panel stays the only place that
# touches git + status.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/comparison_view.gd").
@tool
extends VBoxContainer

signal file_selected(path)
signal open_file_requested(path)
signal copy_path_requested(path)
signal closed
signal swap_requested

const CompareDiffScript = preload("res://addons/gdit_graph/workpanel/commit_diff.gd")
const FileStatus = preload("res://addons/gdit_graph/file_status.gd")

var title_label = null
var subtitle_label = null
var swap_button = null
var close_button = null
var files_title = null
var files_tree = null
var open_button = null
var copy_button = null
var diff_view = null

var _ui_built = false
var _rebuilding = false
var _hash_a = ""
var _hash_b = ""
var _selected_path = ""
# Merge-base short hash for the subtitle (plan section I get_merge_base).
# Set by the panel after show_comparison via set_merge_base.
var _merge_base = ""


func _ready() -> void:
	_build_ui()
	_ui_built = true


func _build_ui() -> void:
	if _ui_built:
		return
	var header := HBoxContainer.new()
	header.name = "CompareHeader"
	title_label = Label.new()
	title_label.name = "CompareTitle"
	title_label.text = "Compare"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_size_override("font_size", 13)
	header.add_child(title_label)
	swap_button = Button.new()
	swap_button.name = "CompareSwap"
	swap_button.text = "⇄"
	swap_button.tooltip_text = "Swap A and B"
	swap_button.flat = true
	swap_button.focus_mode = Control.FOCUS_NONE
	swap_button.pressed.connect(func() -> void: swap_requested.emit())
	header.add_child(swap_button)
	close_button = Button.new()
	close_button.name = "CompareClose"
	close_button.text = "×"
	close_button.tooltip_text = "Close comparison (Escape)"
	close_button.flat = true
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(_on_close)
	header.add_child(close_button)
	add_child(header)
	subtitle_label = Label.new()
	subtitle_label.name = "CompareSubtitle"
	subtitle_label.text = ""
	subtitle_label.add_theme_font_size_override("font_size", 12)
	add_child(subtitle_label)
	files_title = Label.new()
	files_title.name = "CompareFilesTitle"
	files_title.text = "Files"
	files_title.add_theme_font_size_override("font_size", 13)
	add_child(files_title)
	files_tree = Tree.new()
	files_tree.name = "CompareFiles"
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
	diff_row.name = "CompareDiffRow"
	open_button = Button.new()
	open_button.name = "CompareOpenButton"
	open_button.text = "Open File"
	open_button.tooltip_text = "Open the selected file in the editor (worktree state)"
	open_button.disabled = true
	open_button.pressed.connect(_on_open_pressed)
	diff_row.add_child(open_button)
	copy_button = Button.new()
	copy_button.name = "CompareCopyButton"
	copy_button.text = "Copy Path"
	copy_button.tooltip_text = "Copy the selected file path to the clipboard"
	copy_button.disabled = true
	copy_button.pressed.connect(_on_copy_pressed)
	diff_row.add_child(copy_button)
	add_child(diff_row)
	diff_view = CompareDiffScript.new()
	diff_view.name = "CompareDiff"
	diff_view.custom_minimum_size = Vector2(0, 120)
	diff_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(diff_view)


func get_pair() -> Array:
	return [_hash_a, _hash_b]


func get_selected_path() -> String:
	return _selected_path


func is_open() -> bool:
	return visible and not _hash_a.is_empty() and not _hash_b.is_empty()


# Merge-base display (plan section I get_merge_base). The panel resolves the
# base synchronously after show_comparison; empty clears the suffix.
func set_merge_base(base_short: String) -> void:
	_merge_base = String(base_short).strip_edges()
	_update_subtitle()


func _update_subtitle() -> void:
	if subtitle_label == null or not is_instance_valid(subtitle_label):
		return
	if _hash_a.is_empty() or _hash_b.is_empty():
		return
	var base := ""
	if not _merge_base.is_empty():
		base = "   (merge base %s)" % _merge_base
	subtitle_label.text = "%s  ...  %s%s" % [_hash_a, _hash_b, base]


func show_comparison(hash_a: String, hash_b: String, short_a: String, short_b: String) -> void:
	if not _ui_built:
		_build_ui()
		_ui_built = true
	_hash_a = String(hash_a)
	_hash_b = String(hash_b)
	_selected_path = ""
	_merge_base = ""
	var sa := short_a if not String(short_a).is_empty() else _hash_a.left(8)
	var sb := short_b if not String(short_b).is_empty() else _hash_b.left(8)
	title_label.text = "Compare %s ↔ %s" % [sa, sb]
	_update_subtitle()
	files_title.text = "Files (loading...)"
	_rebuilding = true
	files_tree.clear()
	_rebuilding = false
	open_button.disabled = true
	copy_button.disabled = true
	diff_view.set_loading()
	visible = true


func show_files(files: Array) -> void:
	if not _ui_built:
		return
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
		var old_path := String(info.get("old_path", ""))
		item.set_tooltip_text(0, ("%s -> %s" % [old_path, path]) if not old_path.is_empty() else path)
		var code := String(info.get("status", "M"))
		item.set_text(1, code)
		item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(1, FileStatus.status_color(code))
	_rebuilding = false
	files_title.text = "Files (%d)" % files.size()
	_selected_path = ""
	open_button.disabled = true
	copy_button.disabled = true
	if files.is_empty():
		diff_view.show_message("No files differ between these commits.")
	else:
		var first: TreeItem = root.get_first_child()
		if first != null:
			_rebuilding = true
			first.select(0)
			_rebuilding = false
			_on_file_row_selected()


func show_files_error(msg: String) -> void:
	if not _ui_built:
		return
	files_title.text = "Files"
	diff_view.show_message(String(msg))


func set_diff(diff_text: String, _truncated: bool = false) -> void:
	if diff_view != null and is_instance_valid(diff_view):
		diff_view.set_diff(String(diff_text), _truncated)


func show_diff_message(msg: String) -> void:
	if diff_view != null and is_instance_valid(diff_view):
		diff_view.show_message(String(msg))


func clear() -> void:
	_hash_a = ""
	_hash_b = ""
	_selected_path = ""
	_merge_base = ""
	if not _ui_built:
		return
	title_label.text = "Compare"
	subtitle_label.text = ""
	files_title.text = "Files"
	_rebuilding = true
	files_tree.clear()
	_rebuilding = false
	open_button.disabled = true
	copy_button.disabled = true
	diff_view.show_message("Ctrl+click two commits to compare them.")


func close_view() -> void:
	clear()
	visible = false
	closed.emit()


func _on_close() -> void:
	close_view()


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
