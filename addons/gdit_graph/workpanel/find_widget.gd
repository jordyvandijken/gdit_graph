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
# Layout lives in components/find_widget.tscn (prev/next reuse the shared
# toolbar_button scene); this script binds those nodes, fills the scope
# list, and owns the search behavior below.
#
# No class_name (repo convention): loaded via find_widget.tscn.
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
	_bind_nodes()


func _bind_nodes() -> void:
	if _ui_built:
		return
	_ui_built = true
	search_field = get_node_or_null("FindSearch")
	scope_button = get_node_or_null("FindScope")
	count_label = get_node_or_null("FindCount")
	prev_button = get_node_or_null("FindPrev")
	next_button = get_node_or_null("FindNext")
	if scope_button != null:
		for s in SCOPES:
			scope_button.add_item(s)
		scope_button.item_selected.connect(_on_scope_selected)
	if search_field != null:
		search_field.text_changed.connect(_on_text_changed)
		search_field.gui_input.connect(_on_field_gui_input)
	if prev_button != null:
		prev_button.pressed.connect(func() -> void: navigate_prev.emit())
	if next_button != null:
		next_button.pressed.connect(func() -> void: navigate_next.emit())


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
