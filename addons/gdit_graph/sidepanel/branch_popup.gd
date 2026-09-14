# Branch switcher popup for the Source Control side panel.
#
# Floating branch/tag picker opened by clicking the branch label in the
# status bar: a search field on top (filters branches and tags, and doubles
# as the new-branch name), "Create new branch" / "Create new branch from..."
# / "Checkout detached HEAD" actions, then Local branches, Remote branches
# and Tags sections. "Create new branch from..." flips the popup into a
# source-picking mode with the same search and lists; picking a row creates
# the sanitized name from that source and checks it out.
#
# The panel (not this popup) performs the git work: checkout_requested /
# create_requested / detach_requested carry the intent, results arrive via
# GitManager.operation_complete.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/branch_popup.gd").
@tool
extends PopupPanel

signal checkout_requested(ref: String, kind: String)
signal create_requested(branch_name: String, source_ref: String)
signal detach_requested()

const SidepanelBranchUtils = preload("res://addons/gdit_graph/sidepanel/version_control_panel_utils.gd")
const GitRefs = preload("res://addons/gdit_graph/git_refs.gd")

const MODE_SWITCH = 0
const MODE_PICK_SOURCE = 1
const MAX_ROWS_PER_SECTION = 50

var _built = false
var _mode = MODE_SWITCH
var _branches = []
var _tags = []
var _pending_name = ""

var _title = null
var _search = null
var _hint = null
var _create_btn = null
var _create_from_btn = null
var _detach_btn = null
var _back_btn = null
var _scroll = null
var _local_label = null
var _local_rows = null
var _remote_label = null
var _remote_rows = null
var _tag_label = null
var _tag_rows = null


func show_switcher(branches: Array, tags: Array) -> void:
	_ensure_built()
	_mode = MODE_SWITCH
	_pending_name = ""
	_branches = branches
	_tags = tags
	_search.text = ""
	_create_btn.visible = true
	_create_from_btn.visible = true
	_detach_btn.visible = true
	_back_btn.visible = false
	_refresh()
	popup_centered(Vector2i(400, 560))
	_search.call_deferred("grab_focus")


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	var box := VBoxContainer.new()
	box.name = "BranchBox"
	box.custom_minimum_size = Vector2(400, 560)
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	# Fill the popup rect so the scroll area absorbs spare height even when
	# the window sizes itself from the minimum size above.
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title = Label.new()
	_title.name = "BranchTitle"
	_title.text = "Checkout branch or tag"
	_title.add_theme_font_size_override("font_size", 14)
	box.add_child(_title)
	_search = LineEdit.new()
	_search.name = "BranchSearch"
	_search.placeholder_text = "Search branches and tags, or type a new branch name"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_search_changed)
	box.add_child(_search)
	_hint = Label.new()
	_hint.name = "BranchHint"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.custom_minimum_size = Vector2(0, 30)
	box.add_child(_hint)
	_create_btn = _make_action_button("CreateBranchButton", "Create new branch")
	_create_btn.pressed.connect(_on_create_pressed)
	box.add_child(_create_btn)
	_create_from_btn = _make_action_button("CreateBranchFromButton", "Create new branch from...")
	_create_from_btn.pressed.connect(_on_create_from_pressed)
	box.add_child(_create_from_btn)
	_detach_btn = _make_action_button("DetachButton", "Checkout detached HEAD")
	_detach_btn.pressed.connect(_on_detach_pressed)
	box.add_child(_detach_btn)
	_back_btn = _make_action_button("BranchBackButton", "Back")
	_back_btn.visible = false
	_back_btn.pressed.connect(_on_back_pressed)
	box.add_child(_back_btn)
	var sep := HSeparator.new()
	sep.name = "BranchSeparator"
	box.add_child(sep)
	_scroll = ScrollContainer.new()
	_scroll.name = "BranchScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	var sections := VBoxContainer.new()
	sections.name = "BranchSections"
	sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sections.add_theme_constant_override("separation", 2)
	_scroll.add_child(sections)
	_local_label = _make_section_label(sections, "LocalLabel")
	_local_rows = _make_rows_box(sections, "LocalRows")
	_remote_label = _make_section_label(sections, "RemoteLabel")
	_remote_rows = _make_rows_box(sections, "RemoteRows")
	_tag_label = _make_section_label(sections, "TagLabel")
	_tag_rows = _make_rows_box(sections, "TagRows")


func _make_action_button(button_name: String, text: String) -> Button:
	var btn := Button.new()
	btn.name = button_name
	btn.text = text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return btn


func _make_section_label(parent: Control, label_name: String) -> Label:
	var label := Label.new()
	label.name = label_name
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	parent.add_child(label)
	return label


func _make_rows_box(parent: Control, box_name: String) -> VBoxContainer:
	var rows := VBoxContainer.new()
	rows.name = box_name
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 0)
	parent.add_child(rows)
	return rows


func _refresh() -> void:
	if not _built:
		return
	var query := ""
	if _search != null:
		query = _search.text
	if _mode == MODE_PICK_SOURCE:
		_title.text = "Create \"%s\" from..." % _pending_name
		_create_btn.visible = false
		_create_from_btn.visible = false
		_detach_btn.visible = false
		_back_btn.visible = true
		_hint.text = "Pick a branch or tag to create \"%s\" from." % _pending_name
		_hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	else:
		_title.text = "Checkout branch or tag"
		_create_btn.visible = true
		_create_from_btn.visible = true
		_detach_btn.visible = true
		_back_btn.visible = false
		_update_hint(query)
	_rebuild_sections(query)
	if _scroll != null:
		_scroll.scroll_vertical = 0


# Inline create guidance: spaces are auto-dashed (shown as "Create as"),
# anything else illegal disables creation with the reason, and an existing
# name points at the row to check out instead.
func _update_hint(query: String) -> void:
	var raw := String(query).strip_edges()
	if raw.is_empty():
		_hint.text = "Type to filter, or type a new branch name (spaces become dashes)."
		_hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		_create_btn.disabled = true
		_create_from_btn.disabled = true
		return
	var clean := SidepanelBranchUtils.sanitize_branch_name(raw)
	var check := GitRefs.validate_branch_name(clean)
	if not bool(check.get("ok", false)):
		_hint.text = String(check.get("reason", "Invalid branch name."))
		_hint.add_theme_color_override("font_color", Color(0.95, 0.45, 0.45))
		_create_btn.disabled = true
		_create_from_btn.disabled = true
		return
	if SidepanelBranchUtils.local_branch_exists(_branches, clean):
		_hint.text = "\"%s\" already exists — pick it below to check out." % clean
		_hint.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2))
		_create_btn.disabled = true
		_create_from_btn.disabled = true
		return
	if clean != raw:
		_hint.text = "Create as \"%s\"." % clean
	else:
		_hint.text = "Create new branch \"%s\" and check out." % clean
	_hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_create_btn.disabled = false
	_create_from_btn.disabled = false


func _rebuild_sections(query: String) -> void:
	var locals: Array = []
	var remotes: Array = []
	for b in _branches:
		var info: Dictionary = b
		if bool(info.get("remote", false)):
			remotes.append(info)
		else:
			locals.append(info)
	_fill_section(_local_label, _local_rows, SidepanelBranchUtils.filter_ref_names(locals, query), "Local branches", "local")
	_fill_section(_remote_label, _remote_rows, SidepanelBranchUtils.filter_ref_names(remotes, query), "Remote branches", "remote")
	_fill_section(_tag_label, _tag_rows, SidepanelBranchUtils.filter_ref_names(_tags, query), "Tags", "tag")


func _fill_section(label: Label, box: VBoxContainer, items: Array, title: String, kind: String) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	label.text = "%s (%d)" % [title, items.size()]
	var shown := 0
	for item in items:
		if shown >= MAX_ROWS_PER_SECTION:
			break
		var info: Dictionary = item
		# Remote rows check out via the short "origin/main" form; local and
		# tag rows use the full name.
		var ref := String(info.get("display", info.get("name", "")))
		if kind == "local":
			ref = String(info.get("name", ""))
		var row_text := ref
		var disabled := false
		if bool(info.get("current", false)):
			row_text = "%s  (current)" % ref
			disabled = true
		_add_row(box, row_text, disabled, ref, kind)
		shown += 1
	if items.is_empty():
		_add_note(box, "No matches.")
	elif items.size() > MAX_ROWS_PER_SECTION:
		_add_note(box, "+%d more — keep typing to narrow down." % (items.size() - MAX_ROWS_PER_SECTION))


func _add_row(box: VBoxContainer, text: String, disabled: bool, ref: String, kind: String) -> void:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.disabled = disabled
	btn.tooltip_text = ref
	if not disabled:
		btn.pressed.connect(_on_row_pressed.bind(ref, kind))
	box.add_child(btn)


func _add_note(box: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	box.add_child(label)


func _create_candidate() -> String:
	if _search == null:
		return ""
	var clean := SidepanelBranchUtils.sanitize_branch_name(_search.text)
	if clean.is_empty():
		return ""
	var check := GitRefs.validate_branch_name(clean)
	if not bool(check.get("ok", false)):
		return ""
	if SidepanelBranchUtils.local_branch_exists(_branches, clean):
		return ""
	return clean


func _on_search_changed(_new_text: String) -> void:
	_refresh()


func _on_row_pressed(ref: String, kind: String) -> void:
	if _mode == MODE_PICK_SOURCE:
		if _pending_name.is_empty() or String(ref).is_empty():
			return
		create_requested.emit(_pending_name, ref)
	else:
		if String(ref).is_empty():
			return
		checkout_requested.emit(ref, kind)
	hide()


func _on_create_pressed() -> void:
	var clean := _create_candidate()
	if clean.is_empty():
		return
	create_requested.emit(clean, "")
	hide()


func _on_create_from_pressed() -> void:
	var clean := _create_candidate()
	if clean.is_empty():
		return
	_pending_name = clean
	_mode = MODE_PICK_SOURCE
	_refresh()
	_search.call_deferred("grab_focus")


func _on_detach_pressed() -> void:
	detach_requested.emit()
	hide()


func _on_back_pressed() -> void:
	_mode = MODE_SWITCH
	_refresh()
	_search.call_deferred("grab_focus")
