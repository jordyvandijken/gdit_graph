# Graph tab input dialogs (Phase 3: branch/tag/stash creation + rename).
#
# Static factories returning configured ConfirmationDialogs. The panel owns
# the instances (creates once, connects `confirmed`, reads fields via the
# readers below). OK starts disabled until the required name validates via
# GitRefs.is_valid_ref_name (plugin root, shared with the side panel); git
# itself is the final arbiter and its errors surface through
# operation_complete.
#
# No @tool needed (pure construction; the only callback is a lambda) and
# no class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/graph_dialogs.gd").
extends RefCounted

const GitRefs = preload("res://addons/gdit_graph/git_refs.gd")


static func line_text(dialog: ConfirmationDialog, node_name: String) -> String:
	var box: VBoxContainer = dialog.get_node_or_null("DialogBox") as VBoxContainer
	if box == null:
		return ""
	var field: LineEdit = box.get_node_or_null(node_name) as LineEdit
	if field == null:
		return ""
	return field.text.strip_edges()


static func checked(dialog: ConfirmationDialog, node_name: String) -> bool:
	var box: VBoxContainer = dialog.get_node_or_null("DialogBox") as VBoxContainer
	if box == null:
		return false
	var toggle: CheckBox = box.get_node_or_null(node_name) as CheckBox
	if toggle == null:
		return false
	return toggle.button_pressed


static func clear_inputs(dialog: ConfirmationDialog) -> void:
	var box: VBoxContainer = dialog.get_node_or_null("DialogBox") as VBoxContainer
	if box == null:
		return
	for child in box.get_children():
		if child is LineEdit:
			(child as LineEdit).text = ""


static func _base_dialog(title_text: String, ok_text: String) -> ConfirmationDialog:
	var dialog := ConfirmationDialog.new()
	dialog.title = title_text
	dialog.ok_button_text = ok_text
	var box := VBoxContainer.new()
	box.name = "DialogBox"
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 6)
	dialog.add_child(box)
	return dialog


static func _add_label(box: VBoxContainer, label_text: String) -> void:
	var label := Label.new()
	label.text = label_text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(label)


static func _add_input(box: VBoxContainer, input_name: String, placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.name = input_name
	field.placeholder_text = placeholder
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.custom_minimum_size = Vector2(320, 0)
	box.add_child(field)
	return field


# OK is enabled only while `is_ok` says the current inputs are submittable.
# Wired at build time so every dialog validates live. The OK button is
# resolved lazily (AcceptDialog buttons are only guaranteed once the
# dialog is in the tree): about_to_popup sets the initial state, and
# text_changed only fires from user typing in a shown dialog.
static func _gate_ok(dialog: ConfirmationDialog, field: LineEdit, is_ok: Callable) -> void:
	var refresh := func() -> void:
		var ok := dialog.get_ok_button()
		if ok != null:
			ok.disabled = not bool(is_ok.call())
	refresh.call()
	field.text_changed.connect(func(_new_text: String) -> void:
		refresh.call()
	)
	dialog.about_to_popup.connect(func() -> void:
		refresh.call()
	)


static func make_branch_dialog() -> ConfirmationDialog:
	var dialog := _base_dialog("Create Branch", "Create")
	_add_label(dialog.get_node("DialogBox") as VBoxContainer, "Create a new branch at the selected commit.")
	var field := _add_input(dialog.get_node("DialogBox") as VBoxContainer, "DialogInput", "Branch name, e.g. feature/my-work")
	_gate_ok(dialog, field, func() -> bool:
		return GitRefs.is_valid_ref_name(field.text)
	)
	return dialog


static func make_rename_dialog() -> ConfirmationDialog:
	var dialog := _base_dialog("Rename Branch", "Rename")
	_add_label(dialog.get_node("DialogBox") as VBoxContainer, "Rename the branch (works on the current branch too).")
	var field := _add_input(dialog.get_node("DialogBox") as VBoxContainer, "DialogInput", "New branch name")
	_gate_ok(dialog, field, func() -> bool:
		return GitRefs.is_valid_ref_name(field.text)
	)
	return dialog


static func make_tag_dialog() -> ConfirmationDialog:
	var dialog := _base_dialog("Create Tag", "Create")
	var box := dialog.get_node("DialogBox") as VBoxContainer
	_add_label(box, "Create a tag at the selected commit.")
	var field := _add_input(box, "DialogInput", "Tag name, e.g. v1.2.0")
	var toggle := CheckBox.new()
	toggle.name = "DialogCheck"
	toggle.text = "Annotated tag (stores tagger, date, and message)"
	toggle.button_pressed = true
	box.add_child(toggle)
	var message := _add_input(box, "DialogMessage", "Tag message (defaults to the tag name)")
	message.text = ""
	message.editable = toggle.button_pressed
	toggle.toggled.connect(func(pressed: bool) -> void:
		message.editable = pressed
	)
	_gate_ok(dialog, field, func() -> bool:
		return GitRefs.is_valid_ref_name(field.text)
	)
	return dialog


static func make_stash_dialog() -> ConfirmationDialog:
	var dialog := _base_dialog("Stash Changes", "Stash")
	var box := dialog.get_node("DialogBox") as VBoxContainer
	_add_label(box, "Stash tracked modifications (like `git stash push`). Untracked files are left alone.")
	_add_input(box, "DialogInput", "Stash message (optional)")
	return dialog
