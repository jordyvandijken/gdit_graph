# Graph tab input dialog readers (Phase 3: branch/tag/stash creation + rename).
#
# Dialog layout moved to workpanel/components/*.tscn (branch/rename/tag/
# stash), built around the shared graph_dialog.gd behavior script. The panel
# owns the instances (creates once, connects `confirmed`) and reads fields
# via the helpers below, which resolve by node name (DialogBox/DialogInput/
# DialogCheck/DialogMessage) — preserved in every scene.
#
# No @tool needed (pure reads) and no class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/graph_dialogs.gd").
extends RefCounted


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
