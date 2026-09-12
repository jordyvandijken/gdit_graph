# Find widget (Phase 4: plan sections II row 1, III.H, V.16).
#
# Slim search field embedded in the graph toolbar (always visible, between
# the title and the Fetch button). Pure view: every keystroke emits
# search_changed and the panel filters its already-loaded commits via
# GraphUtils.filter_commit_indices (no git round-trip, instant on large
# pages). No close button (nothing to hide); the match counter and prev/next
# buttons step through the matches (Enter / Shift+Enter do the same from
# the keyboard), and Escape clears the query.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/find_widget.gd").
@tool
extends HBoxContainer

signal search_changed(query, scope)
signal navigate_prev
signal navigate_next

const SCOPES = ["All", "Message", "Author", "Hash", "Branch", "Tag"]

var search_field = null
var scope_button = null
var count_label = null
var prev_button = null
var next_button = null
var _ui_built = false


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	if _ui_built:
		return
	_ui_built = true
	add_theme_constant_override("separation", 6)
	search_field = LineEdit.new()
	search_field.name = "FindSearch"
	search_field.placeholder_text = "Search commits (message, author, hash, branch, tag)"
	search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_field.clear_button_enabled = true
	search_field.text_changed.connect(_on_text_changed)
	search_field.gui_input.connect(_on_field_gui_input)
	add_child(search_field)
	scope_button = OptionButton.new()
	scope_button.name = "FindScope"
	for s in SCOPES:
		scope_button.add_item(s)
	scope_button.item_selected.connect(_on_scope_selected)
	add_child(scope_button)
	count_label = Label.new()
	count_label.name = "FindCount"
	count_label.text = ""
	count_label.add_theme_font_size_override("font_size", 12)
	add_child(count_label)
	prev_button = Button.new()
	prev_button.name = "FindPrev"
	prev_button.text = "↑"
	prev_button.tooltip_text = "Previous match (Shift+Enter)"
	prev_button.flat = true
	prev_button.focus_mode = Control.FOCUS_NONE
	prev_button.disabled = true
	prev_button.pressed.connect(func() -> void: navigate_prev.emit())
	add_child(prev_button)
	next_button = Button.new()
	next_button.name = "FindNext"
	next_button.text = "↓"
	next_button.tooltip_text = "Next match (Enter)"
	next_button.flat = true
	next_button.focus_mode = Control.FOCUS_NONE
	next_button.disabled = true
	next_button.pressed.connect(func() -> void: navigate_next.emit())
	add_child(next_button)


func get_query() -> String:
	if search_field != null and is_instance_valid(search_field):
		return search_field.text
	return ""


func get_scope() -> String:
	if scope_button != null and is_instance_valid(scope_button) and scope_button.item_count > 0:
		return scope_button.get_item_text(scope_button.selected).to_lower()
	return "all"


func set_result_count(current: int, total: int) -> void:
	if count_label == null or not is_instance_valid(count_label):
		return
	if total <= 0:
		count_label.text = "No matches" if not get_query().strip_edges().is_empty() else ""
	else:
		count_label.text = "%d/%d" % [current, total]
	var has := total > 0
	if prev_button != null and is_instance_valid(prev_button):
		prev_button.disabled = not has
	if next_button != null and is_instance_valid(next_button):
		next_button.disabled = not has


func focus_search() -> void:
	if search_field != null and is_instance_valid(search_field) and search_field.is_inside_tree():
		search_field.grab_focus()
		search_field.select_all()


func clear() -> void:
	if search_field != null and is_instance_valid(search_field):
		search_field.set_block_signals(true)
		search_field.text = ""
		search_field.set_block_signals(false)
	set_result_count(0, 0)


func open_widget() -> void:
	visible = true
	focus_search()


func set_query(text: String) -> void:
	if search_field != null and is_instance_valid(search_field):
		search_field.set_block_signals(true)
		search_field.text = String(text)
		search_field.set_block_signals(false)


func set_scope(scope: String) -> void:
	if scope_button == null or not is_instance_valid(scope_button):
		return
	var want := String(scope).strip_edges().to_lower()
	for i in range(scope_button.item_count):
		if scope_button.get_item_text(i).to_lower() == want:
			scope_button.set_block_signals(true)
			scope_button.selected = i
			scope_button.set_block_signals(false)
			return


func _on_text_changed(_new_text: String) -> void:
	search_changed.emit(get_query(), get_scope())


func _on_scope_selected(_index: int) -> void:
	search_changed.emit(get_query(), get_scope())
	focus_search()


func _on_field_gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if key.keycode == KEY_ESCAPE:
			# Always-visible toolbar search: Escape clears the query instead
			# of hiding. When already empty, let the event bubble so the
			# panel can close the comparison view.
			if not get_query().strip_edges().is_empty():
				accept_event()
				search_field.text = ""
				set_result_count(0, 0)
				search_changed.emit("", get_scope())
		elif key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
			accept_event()
			if key.shift_pressed:
				navigate_prev.emit()
			else:
				navigate_next.emit()
