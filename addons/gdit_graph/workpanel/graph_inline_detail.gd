# Inline commit detail panel: sits in the gap the graph_renderer reserves
# between the selected commit row and the next one (child of the renderer
# canvas, so it scrolls with the rows). The left spacer stays transparent
# so the branch lanes drawn by the renderer remain visible; the commit
# details card fills the remaining columns. Height auto-sizes to content
# (see desired_height); the panel positions and sizes this control.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/graph_inline_detail.gd").
@tool
extends Control

signal file_selected(path)
signal open_file_requested(path)
signal copy_path_requested(path)
signal review_toggled(commit_hash, path, reviewed)
signal closed

const InlineDetailsScript = preload("res://addons/gdit_graph/workpanel/commit_details.gd")

const MIN_HEIGHT = 300.0
const MAX_HEIGHT = 640.0

var details = null

var _ui_built = false
var _lane_px = 120.0
var _spacer = null
var _title_label = null


func _ready() -> void:
	_build_ui()
	_ui_built = true


func _build_ui() -> void:
	if _ui_built:
		return
	var hbox := HBoxContainer.new()
	hbox.name = "InlineDetailBox"
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 0)
	add_child(hbox)
	# Transparent gutter: the renderer's lane lines show through here.
	_spacer = Control.new()
	_spacer.name = "InlineDetailGutter"
	_spacer.custom_minimum_size = Vector2(maxf(_lane_px, 0.0), 0)
	_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(_spacer)
	var card := PanelContainer.new()
	card.name = "InlineDetailCard"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _card_style())
	hbox.add_child(card)
	var vbox := VBoxContainer.new()
	vbox.name = "InlineDetailVBox"
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)
	var header := HBoxContainer.new()
	header.name = "InlineDetailHeader"
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)
	_title_label = Label.new()
	_title_label.name = "InlineDetailTitle"
	_title_label.text = "Commit Details"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.clip_text = true
	_title_label.add_theme_font_size_override("font_size", 13)
	header.add_child(_title_label)
	var close_button := Button.new()
	close_button.name = "InlineDetailClose"
	close_button.text = "×"
	close_button.tooltip_text = "Close details"
	close_button.flat = true
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(_on_close_pressed)
	header.add_child(close_button)
	details = InlineDetailsScript.new()
	details.name = "InlineCommitDetails"
	details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details.file_selected.connect(_on_details_file_selected)
	details.open_file_requested.connect(_on_details_open_file_requested)
	details.copy_path_requested.connect(_on_details_copy_path_requested)
	details.review_toggled.connect(_on_details_review_toggled)
	vbox.add_child(details)


func _card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.18, 0.97)
	sb.border_color = Color(0.35, 0.65, 1.0, 0.9)
	sb.set_border_width_all(0)
	sb.border_width_left = 2
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


func _ensure_built() -> void:
	if not _ui_built:
		_build_ui()
		_ui_built = true


func set_lane_width(px: float) -> void:
	_lane_px = maxf(float(px), 0.0)
	if _spacer != null and is_instance_valid(_spacer):
		_spacer.custom_minimum_size = Vector2(_lane_px, 0)


func set_title(title_text: String) -> void:
	_ensure_built()
	if _title_label != null and is_instance_valid(_title_label):
		_title_label.text = String(title_text)


func apply_settings(settings: Dictionary) -> void:
	_ensure_built()
	if details != null and is_instance_valid(details):
		details.apply_settings(settings)


# Immediate lightweight display from the graph row while details load.
func show_commit(commit: Dictionary) -> void:
	_ensure_built()
	set_title("Commit Details — %s" % String(commit.get("short", "")))
	details.show_commit(commit)
	visible = true


func show_uncommitted(file_count: int = 0) -> void:
	_ensure_built()
	set_title("Commit Details — Uncommitted Changes")
	details.show_uncommitted(file_count)
	visible = true


# Full details from GraphManager.commit_details_loaded.
func show_details(loaded: Dictionary) -> void:
	_ensure_built()
	details.show_details(loaded)


func show_load_error(msg: String) -> void:
	_ensure_built()
	details.show_load_error(msg)


# Auto-size estimate from the loaded content: header + subject/meta +
# message body (when present) + file list + diff view, clamped so the
# panel never clips the content minimum nor grows past the max.
func desired_height() -> float:
	if details == null or not is_instance_valid(details):
		return 360.0
	var h := 34.0 + 30.0 + 46.0
	if details.message_view != null and is_instance_valid(details.message_view) and details.message_view.visible:
		var body := String(details._last_body)
		var body_lines := body.count("\n") + 1
		h += clampf(float(body_lines) * 19.0 + 16.0, 44.0, 120.0)
	var files: Array = details._last_files
	if files.is_empty():
		h += 24.0 + 60.0
	else:
		h += 24.0 + clampf(float(files.size()) * 26.0 + 12.0, 90.0, 170.0)
	h += 32.0
	if String(details._selected_path).is_empty():
		h += 60.0
	else:
		var diff_text := ""
		if details.diff_view != null and is_instance_valid(details.diff_view):
			diff_text = String(details.diff_view.text)
		var diff_lines := diff_text.count("\n") + 1
		h += clampf(float(diff_lines) * 16.5 + 24.0, 120.0, 300.0)
	h += 20.0
	var min_h: float = 42.0 + details.get_combined_minimum_size().y
	h = maxf(h, minf(min_h + 34.0, MAX_HEIGHT))
	return clampf(h, MIN_HEIGHT, MAX_HEIGHT)


func _on_close_pressed() -> void:
	closed.emit()


func _on_details_file_selected(path: String) -> void:
	file_selected.emit(path)


func _on_details_open_file_requested(path: String) -> void:
	open_file_requested.emit(path)


func _on_details_copy_path_requested(path: String) -> void:
	copy_path_requested.emit(path)


func _on_details_review_toggled(commit_hash: String, path: String, reviewed: bool) -> void:
	review_toggled.emit(commit_hash, path, reviewed)
